import Foundation

/// What went wrong talking to the Mac, in words for the screen.
public enum CompanionError: LocalizedError, Sendable {
    case unreachable(String)
    case unpaired
    case server(Int)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let name):
            return "Can't reach \(name). Check that Companion is open on it with the app connection on, and that this device is on the same Wi-Fi or Tailscale."
        case .unpaired:
            return "This Mac no longer knows this device. Pair again from Settings > Remote on the Mac."
        case .server(let code):
            return "The Mac answered with an error (\(code))."
        }
    }
}

/// The Mac's chat list.
public struct ChatList: Codable, Sendable {
    public var current: String
    public var chats: [ChatSummary]
}

/// Talks to Companion on one Mac, at one address. `connect` finds the
/// address that answers.
public struct CompanionClient: Sendable {
    public let mac: PairedMac
    public let host: String

    public init(mac: PairedMac, host: String) {
        self.mac = mac
        self.host = host
    }

    private static let quick: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private static let normal: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private static let feed: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // The Mac sends a ping every 15 seconds on a quiet feed.
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 60 * 60 * 24
        return URLSession(configuration: config)
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    /// Tries the Mac's addresses in turn (the one that worked last first)
    /// and returns a client for the first that answers, with what the Mac
    /// says about itself.
    public static func connect(to mac: PairedMac) async throws -> (CompanionClient, MacInfo) {
        // All addresses are tried at once; the first in order that answers wins.
        let hosts = mac.hostsToTry
        let answers = await withTaskGroup(of: (Int, MacInfo?, Bool).self) { group in
            for (index, host) in hosts.enumerated() {
                group.addTask {
                    let client = CompanionClient(mac: mac, host: host)
                    do {
                        let info: MacInfo = try await client.get("/info", session: quick)
                        return (index, info, false)
                    } catch CompanionError.unpaired {
                        return (index, nil, true)
                    } catch {
                        return (index, nil, false)
                    }
                }
            }
            var all: [(Int, MacInfo?, Bool)] = []
            for await answer in group { all.append(answer) }
            return all.sorted { $0.0 < $1.0 }
        }
        if let best = answers.first(where: { $0.1 != nil }), let info = best.1 {
            return (CompanionClient(mac: mac, host: hosts[best.0]), info)
        }
        if answers.contains(where: { $0.2 }) { throw CompanionError.unpaired }
        throw CompanionError.unreachable(mac.name)
    }

    // MARK: Requests

    public func url(_ path: String, _ extra: [URLQueryItem] = []) -> URL {
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = host
        parts.port = mac.port
        parts.path = path
        parts.queryItems = [URLQueryItem(name: "token", value: mac.token)] + extra
        return parts.url!
    }

    private func get<T: Decodable>(_ path: String, session: URLSession = normal) async throws -> T {
        let (data, response) = try await session.data(from: url(path))
        try Self.check(response)
        return try Self.decoder.decode(T.self, from: data)
    }

    private func post(_ path: String, body: String = "", _ extra: [URLQueryItem] = []) async throws {
        var request = URLRequest(url: url(path, extra))
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (_, response) = try await Self.normal.data(for: request)
        try Self.check(response)
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw CompanionError.unpaired }
        if !(200..<300).contains(http.statusCode) { throw CompanionError.server(http.statusCode) }
    }

    public func chats() async throws -> ChatList { try await get("/chats") }
    public func projects() async throws -> [ProjectSummary] {
        let list: ProjectList = try await get("/projects")
        return list.projects
    }
    public func state() async throws -> FeedUpdate { try await get("/state") }
    /// Sends a message to the chat open on the Mac (an answer, while the
    /// agent asks).
    public func say(_ text: String, files: [String] = []) async throws {
        try await post("/say", body: text, files.isEmpty ? [] : [URLQueryItem(name: "files", value: files.joined(separator: ","))])
    }

    /// Sends a photo or file to the Mac, attached to the open chat for the
    /// next message; its id goes with `say`.
    public func attach(_ data: Data, name: String) async throws -> String {
        var request = URLRequest(url: url("/attach", [URLQueryItem(name: "name", value: name)]))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        let (body, response) = try await Self.normal.upload(for: request, from: data)
        try Self.check(response)
        struct Attached: Decodable { var id: String }
        return try Self.decoder.decode(Attached.self, from: body).id
    }

    /// The engines and models the Mac can answer with.
    public func engines() async throws -> [Engine] {
        let list: EngineList = try await get("/models")
        return list.engines
    }

    /// The engine and model that answer, on the Mac.
    public func choose(engine: String, model: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["engine": engine, "model": model])
        try await post("/model", body: String(decoding: body, as: UTF8.self))
    }

    /// A look at the Mac's screen, answered in the chat.
    public func lookAtScreen(_ question: String = "") async throws { try await post("/screen", body: question) }

    /// A message sent again, changed: in place, or "fork", "rewindCode",
    /// "forkAndRewind".
    public func edit(_ turnID: String, to text: String, choice: String = "") async throws {
        let body = try JSONSerialization.data(withJSONObject: ["id": turnID, "text": text, "choice": choice])
        try await post("/edit", body: String(decoding: body, as: UTF8.self))
    }
    /// Stops the agent or the reply being written.
    public func stop() async throws { try await post("/stop") }
    /// Opens a chat on the Mac.
    public func open(_ chatID: String) async throws { try await post("/open", body: chatID) }
    public func newChat() async throws { try await post("/new") }
    /// How much runs without asking in the open chat: manual, autoEdit or full.
    public func setAccess(_ access: String) async throws { try await post("/access", body: access) }
    /// The effort for the model in use ("" leaves it to the model).
    public func setEffort(_ level: String) async throws { try await post("/effort", body: level) }
    /// A waiting message: send it now (stopping the task), cancel or restore it.
    public func queued(_ action: String, _ id: String) async throws { try await post("/queued", body: "\(action) \(id)") }
    public func imageURL(turn id: String) -> URL { url("/image", [URLQueryItem(name: "id", value: id)]) }

    /// The open chat as it changes: the whole of it first, then what
    /// changes. Ends when the connection does.
    public func updates() -> AsyncThrowingStream<FeedUpdate, Error> {
        let request = URLRequest(url: url("/events"))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await Self.feed.bytes(for: request)
                    try Self.check(response)
                    var pending = ""
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        // Each event is one line of JSON; a longer one is
                        // gathered until it reads whole.
                        pending += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if let update = try? Self.decoder.decode(FeedUpdate.self, from: Data(pending.utf8)) {
                            pending = ""
                            continuation.yield(update)
                        } else if pending.count > 4_000_000 {
                            pending = ""
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
