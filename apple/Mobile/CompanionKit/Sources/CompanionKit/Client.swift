import CompanionLink
import Foundation

/// What went wrong talking to the Mac, in words for the screen.
public enum CompanionError: LocalizedError, Sendable {
    case unreachable(String)
    case unpaired
    case server(Int)
    /// Something only the Mac itself may do, such as raising access.
    case onlyOnMac
    /// Not reachable directly, and the relay said why not.
    case away(String, String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let name):
            return "Can't reach \(name). Check that Companion is open on it with the app connection on. Away from its Wi-Fi, turn on Reach this Mac from anywhere in Settings > Remote on the Mac and pair again."
        case .unpaired:
            return "This Mac no longer knows this device. Pair again from Settings > Remote on the Mac."
        case .server(let code):
            return "The Mac answered with an error (\(code))."
        case .onlyOnMac:
            return "Do this on the Mac itself. From here, access can only be lowered."
        case .away(let name, let why):
            return "Can't reach \(name) through the relay. \(why)"
        }
    }
}

/// The Mac's chat list.
public struct ChatList: Codable, Sendable {
    public var current: String
    public var chats: [ChatSummary]
}

/// Talks to Companion on one Mac, by one route: straight to an address on
/// its network, or through its relay. `connect` finds the route that works,
/// and every request below goes the same way on either.
public struct CompanionClient: Sendable {
    /// How the Mac is reached.
    public enum Route: Sendable, Equatable {
        /// Straight to this address: its name or address on the network, or
        /// its Tailscale address, in plain HTTP (a Mac from before `local`).
        case direct(String)
        /// Straight to this address, sealed as through the relay: the Mac
        /// serves the relay's protocol on its network (`/link`).
        case local(String)
        /// Through the relay, sealed end to end.
        case relay
    }

    public let mac: PairedMac
    public let route: Route
    private let link: LinkEndpoint?

    /// The address in use, when the Mac is reached directly.
    public var host: String? {
        switch route {
        case .direct(let host), .local(let host): return host
        case .relay: return nil
        }
    }

    public init(mac: PairedMac, host: String) {
        self.mac = mac
        route = .direct(host)
        link = nil
    }

    init(mac: PairedMac, link: LinkEndpoint) {
        self.mac = mac
        route = .relay
        self.link = link
    }

    init(mac: PairedMac, host: String, link: LinkEndpoint) {
        self.mac = mac
        route = .local(host)
        self.link = link
    }

    /// For asking where the sealed way in is: brief, since a Mac that is not
    /// on this network must not hold up the rest.
    private static let probe: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

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

    /// Finds a route to the Mac and returns a client on it, with what the
    /// Mac says about itself. Its addresses are tried first, all at once
    /// (the one that worked last wins a tie); away from its network, its
    /// relay, dialed a moment later so a Mac close by never waits on it.
    public static func connect(to mac: PairedMac) async throws -> (CompanionClient, MacInfo) {
        let hosts = mac.hostsToTry
        var away: Task<Result<(CompanionClient, MacInfo), Error>, Never>?
        if mac.reachableAway {
            away = Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if Task.isCancelled { return .failure(CancellationError()) }
                return await viaRelay(mac)
            }
        }

        // Sealed on this network first: the relay's protocol, served by the
        // Mac itself (security review, H1). A Mac from before it, or a
        // pairing without the key, is asked the plain way below.
        if let key = mac.key.flatMap({ LinkKey(text: $0) }) {
            let ports = await withTaskGroup(of: (Int, Int?).self) { group in
                for (index, host) in hosts.enumerated() {
                    group.addTask { (index, await linkPort(of: mac, at: host)) }
                }
                var all: [(Int, Int?)] = []
                for await answer in group { all.append(answer) }
                return all.sorted { $0.0 < $1.0 }
            }
            for (index, port) in ports {
                guard let port else { continue }
                if let reached = await viaLocalLink(mac, host: hosts[index], port: port, key: key) {
                    away?.cancel()
                    await RelayLinks.shared.stopAll()
                    return reached
                }
            }
        }

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
            // Close by: the relay is not needed.
            away?.cancel()
            await RelayLinks.shared.stopAll()
            return (CompanionClient(mac: mac, host: hosts[best.0]), info)
        }
        if answers.contains(where: { $0.2 }) {
            away?.cancel()
            throw CompanionError.unpaired
        }
        guard let away else { throw CompanionError.unreachable(mac.name) }
        let outcome = await away.value
        switch outcome {
        case .success(let reached):
            return reached
        case .failure(let error):
            if let error = error as? CompanionError { throw error }
            let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw CompanionError.away(mac.name, why)
        }
    }

    /// The port of the Mac's sealed way in at `host`, or nil when it has
    /// none (a Mac from before it) or does not answer there.
    private static func linkPort(of mac: PairedMac, at host: String) async -> Int? {
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = host
        parts.port = mac.port
        parts.path = "/link"
        guard let url = parts.url,
              let (data, response) = try? await probe.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = object["port"] as? Int, (1...65_535).contains(port) else { return nil }
        return port
    }

    /// The Mac at `host` through its sealed way in: connected, and answering.
    private static func viaLocalLink(_ mac: PairedMac, host: String, port: Int,
                                     key: LinkKey) async -> (CompanionClient, MacInfo)? {
        var parts = URLComponents()
        parts.scheme = "ws"
        parts.host = host
        parts.port = port
        guard let url = parts.url else { return nil }
        let link = await LocalLinks.shared.endpoint(for: mac, at: url, key: key)
        do {
            try await link.waitUntilConnected(timeout: 5)
            let client = CompanionClient(mac: mac, host: host, link: link)
            let info: MacInfo = try await client.get("/info", timeout: 8)
            return (client, info)
        } catch {
            await LocalLinks.shared.stopAll()
            return nil
        }
    }

    /// The Mac through its relay: connected, and answering.
    private static func viaRelay(_ mac: PairedMac) async -> Result<(CompanionClient, MacInfo), Error> {
        guard let link = await RelayLinks.shared.endpoint(for: mac) else {
            return .failure(CompanionError.unreachable(mac.name))
        }
        do {
            try await link.waitUntilConnected(timeout: 12)
        } catch {
            return .failure(error)
        }
        do {
            let client = CompanionClient(mac: mac, link: link)
            let info: MacInfo = try await client.get("/info", timeout: 15)
            return .success((client, info))
        } catch LinkError.timedOut {
            // On the relay, but the Mac did not answer: Companion is closed
            // on it, or the Mac is asleep.
            return .failure(CompanionError.away(mac.name, "Check that Companion is open on it and the Mac is awake."))
        } catch {
            return .failure(error)
        }
    }

    // MARK: Requests

    /// A URL on the Mac, for a direct route.
    func url(_ path: String, _ extra: [URLQueryItem] = []) -> URL {
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = host
        parts.port = mac.port
        parts.path = path
        parts.queryItems = [URLQueryItem(name: "token", value: mac.token)] + extra
        return parts.url!
    }

    /// One request, by whichever route this client has: the body and the
    /// HTTP status. Through the relay, the pairing key stands in for the
    /// pairing code.
    private func exchange(_ method: String, _ path: String, _ extra: [URLQueryItem] = [], body: Data = Data(),
                          type: String = "text/plain; charset=utf-8", session: URLSession = normal,
                          timeout: TimeInterval = 20) async throws -> (Data, Int) {
        switch route {
        case .direct:
            var request = URLRequest(url: url(path, extra))
            request.httpMethod = method
            if method == "GET" {
                let (data, response) = try await session.data(for: request)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? 200)
            }
            request.setValue(type, forHTTPHeaderField: "Content-Type")
            if timeout > 20 { request.timeoutInterval = timeout }
            let (data, response) = try await session.upload(for: request, from: body)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 200)
        case .relay, .local:
            guard let link else { throw CompanionError.unreachable(mac.name) }
            var query: [String: String] = [:]
            for item in extra { query[item.name] = item.value ?? "" }
            let answer = try await link.request(LinkRequest(method: method, path: path, query: query, body: body),
                                                timeout: timeout)
            return (answer.body, answer.status)
        }
    }

    private func get<T: Decodable>(_ path: String, _ extra: [URLQueryItem] = [], session: URLSession = normal,
                                   timeout: TimeInterval = 20) async throws -> T {
        let (data, status) = try await exchange("GET", path, extra, session: session, timeout: timeout)
        try Self.check(status)
        return try Self.decoder.decode(T.self, from: data)
    }

    private func post(_ path: String, body: String = "", _ extra: [URLQueryItem] = []) async throws {
        let (_, status) = try await exchange("POST", path, extra, body: Data(body.utf8))
        try Self.check(status)
    }

    private static func check(_ status: Int) throws {
        if status == 401 { throw CompanionError.unpaired }
        if status == 403 { throw CompanionError.onlyOnMac }
        if !(200..<300).contains(status) { throw CompanionError.server(status) }
    }

    public func chats() async throws -> ChatList { try await get("/chats") }
    public func projects() async throws -> [ProjectSummary] {
        let list: ProjectList = try await get("/projects")
        return list.projects
    }
    /// One project's chats, newest first.
    public func projectChats(_ id: String) async throws -> ProjectChats {
        try await get("/project/chats", [URLQueryItem(name: "id", value: id)])
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
        let (body, status) = try await exchange("POST", "/attach", [URLQueryItem(name: "name", value: name)], body: data,
                                                type: "application/octet-stream", timeout: 120)
        try Self.check(status)
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

    /// The picture of a turn in the open chat (a look at the screen).
    public func image(turn id: String) async throws -> Data {
        let (data, status) = try await exchange("GET", "/image", [URLQueryItem(name: "id", value: id)], timeout: 60)
        try Self.check(status)
        return data
    }

    /// The open chat as it changes: the whole of it first, then what
    /// changes. Ends when the connection does.
    public func updates() -> AsyncThrowingStream<FeedUpdate, Error> {
        switch route {
        case .direct: return directUpdates()
        case .relay, .local: return relayUpdates()
        }
    }

    private func directUpdates() -> AsyncThrowingStream<FeedUpdate, Error> {
        let request = URLRequest(url: url("/events"))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await Self.feed.bytes(for: request)
                    try Self.check((response as? HTTPURLResponse)?.statusCode ?? 200)
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

    /// The same events through the relay: the Mac sends a full snapshot
    /// when this device subscribes, then what changes.
    private func relayUpdates() -> AsyncThrowingStream<FeedUpdate, Error> {
        let link = link
        let name = mac.name
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let link else {
                    continuation.finish(throwing: CompanionError.unreachable(name))
                    return
                }
                do {
                    for try await event in await link.events() {
                        if let update = try? Self.decoder.decode(FeedUpdate.self, from: event) {
                            continuation.yield(update)
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
