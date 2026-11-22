import Combine
import Foundation
import Network
#if canImport(AppKit)
import AppKit
import CoreImage
#endif
import SystemConfiguration

/// A remote session: a small web server on the Mac so a phone on the same
/// network can watch this conversation and send messages to it.
///
/// It is dependency-free. The server speaks just enough HTTP/1.1 to serve
/// one page, stream the conversation as it changes (Server-Sent Events),
/// and take a message back. Everything a phone sends goes through the very
/// same `send` and `stopAgent` the chat box uses, so the remote is never a
/// second way in with rules of its own.
///
/// Security: the phone must present a secret pairing code, kept in the
/// Keychain so a phone added to the Home Screen keeps working after the
/// Mac restarts, and replaced (cutting every phone off) with "New code".
/// The server answers only on the local network; away from it, the app
/// reaches the Mac through `RemoteRelay`, sealed end to end, and its
/// requests are answered here by the same `handle`. Approving what the
/// agent wants to do (Allow / Deny) stays on the Mac; the phone can send
/// messages, answer the agent's questions, and stop it, nothing more.
@MainActor
final class RemoteServer: ObservableObject {
    static let shared = RemoteServer()

    @Published private(set) var running = false
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var lastError: String?

    /// The secret a phone must carry. Regenerated every time the server starts.
    private(set) var token = ""

    private var listener: NWListener?
    /// Every open connection's receive buffer, by connection.
    private var buffers: [ObjectIdentifier: Data] = [:]
    /// The connections left open to stream the conversation.
    private var feeds: [ObjectIdentifier: NWConnection] = [:]
    private var pump: Task<Void, Never>?
    /// What each feed was last sent, per turn, so a tick sends only the
    /// turns that changed (a streaming reply is one turn, not the chat).
    private var lastTurns: [String: String] = [:]
    private var lastOrder: [String] = []
    private var lastMeta = ""
    private var lastPing = Date()
    /// Something the phone shows may have changed since the last tick. The
    /// conversation is turned into JSON only then (and every few seconds
    /// regardless), not three times a second while nothing happens: for a
    /// long chat that was real work for the Mac while it sat idle.
    private var dirty = true
    private var lastFullCheck = Date()
    private var changeWatch: Set<AnyCancellable> = []
    /// Connections whose request has not arrived in full yet.
    private var pending: Set<ObjectIdentifier> = []
    /// Where each connection comes from, to count wrong codes by address.
    private var peers: [ObjectIdentifier: String] = [:]
    /// Wrong pairing codes by address (security review, L6): past
    /// `wrongCodeLimit` within `wrongCodeWindow`, that address is refused
    /// until the window has passed.
    private var wrongCodes: [String: (count: Int, since: Date)] = [:]

    /// What a request may be (security review, M1). The head is judged
    /// before any body is waited for.
    private static let headerLimit = 16 * 1024
    private static let bodyLimit = 1_000_000
    private static let attachmentLimit = 40_000_000
    private static let connectionLimit = 32
    /// How long a request may take to arrive in full.
    private static let requestDeadline: TimeInterval = 120
    /// High enough that a page still trying an old code after "New code"
    /// never locks out its own phone; low enough to make guessing hopeless.
    private static let wrongCodeLimit = 1_000
    private static let wrongCodeWindow: TimeInterval = 600

    /// The port it tries first; if taken, the system picks a free one.
    private let preferredPort: UInt16 = 7345

    private init() {}

    // MARK: On and off

    /// Whether the remote session is on, remembered across launches.
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "remoteEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "remoteEnabled")
            if newValue { start() } else { stop() }
        }
    }

    /// Starts the server if it is meant to be on. Called at launch.
    func startIfEnabled() {
        if enabled { start() }
    }

    func start() {
        guard listener == nil else { return }
        lastError = nil
        token = Self.storedToken()
        // The way in from away, whatever becomes of the local listener.
        RemoteRelay.shared.start()
        // The apps' sealed way in on this network.
        LocalLink.shared.start()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let chosen = NWEndpoint.Port(rawValue: preferredPort)
        do {
            let listener = try NWListener(using: parameters, on: chosen ?? .any)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            advertise(listener)
            listener.start(queue: .global(qos: .userInitiated))
            startPump()
        } catch {
            // The preferred port was taken or refused: let the system choose.
            retryOnAnyPort(after: error)
        }
    }

    private func retryOnAnyPort(after first: Error) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters, on: .any)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            advertise(listener)
            listener.start(queue: .global(qos: .userInitiated))
            startPump()
        } catch {
            lastError = error.localizedDescription
            running = false
        }
    }

    func stop() {
        RemoteRelay.shared.stop()
        LocalLink.shared.stop()
        pump?.cancel()
        pump = nil
        for connection in feeds.values { connection.cancel() }
        feeds = [:]
        buffers = [:]
        listener?.cancel()
        listener = nil
        running = false
        port = 0
    }

    // MARK: Found by the Companion app

    /// The Bonjour type the iPhone, iPad and Watch apps look for.
    static let serviceType = "_companion._tcp"

    /// This Mac's lasting id, so an app that paired with it knows it again
    /// whatever its address or name.
    static var macID: String {
        let key = "remoteMacID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    /// The Mac's name as people know it ("Harsh's MacBook Pro").
    /// (Looked up once: it can take a moment.)
    static let macName: String = Host.current().localizedName ?? "Mac"

    /// Announces the server on the local network under the Mac's name, with
    /// its id. The pairing code is never announced.
    private func advertise(_ listener: NWListener) {
        let txt = NWTXTRecord(["id": Self.macID, "v": "1"])
        listener.service = NWListener.Service(name: Self.macName, type: Self.serviceType, domain: nil,
                                              txtRecord: txt)
    }

    /// Every address an app may reach this Mac at, best first: its local
    /// name, its address on the Wi-Fi, and its Tailscale address, which
    /// works from anywhere when the phone is on the same tailnet.
    var hosts: [String] {
        var hosts: [String] = []
        if let name = Self.localName() { hosts.append(name) }
        if let ip = Self.lanAddress() { hosts.append(ip) }
        if let tail = Self.tailscaleAddress() { hosts.append(tail) }
        return hosts
    }

    /// The link the Companion app pairs with (as a QR code): this Mac's id
    /// and name, where it can be reached, and the pairing code; and, while
    /// it can be reached from anywhere, its relay and the key that seals
    /// what goes through it. The key is in this code and nowhere else.
    var appLink: String? {
        let away = RemoteRelay.shared.pairing
        guard running, port != 0, !hosts.isEmpty || away != nil else { return nil }
        var parts = URLComponents()
        parts.scheme = "companion"
        parts.host = "pair"
        var items = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "id", value: Self.macID),
            URLQueryItem(name: "name", value: Self.macName),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "hosts", value: hosts.joined(separator: ",")),
            URLQueryItem(name: "token", value: token),
        ]
        if let away {
            items.append(URLQueryItem(name: "relay", value: away.relay))
        }
        // The pairing's key, relay or not: on this network too the apps seal
        // what they send with it (`LocalLink`).
        items.append(URLQueryItem(name: "key", value: RemoteRelay.shared.key.text))
        parts.queryItems = items
        return parts.url?.absoluteString
    }

    /// The Mac's Tailscale address (100.64.0.0/10), when Tailscale is on.
    static func tailscaleAddress() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var pointer = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // 100.64.0.0/10: the shared address space Tailscale uses.
            guard ip & 0xFFC0_0000 == 0x6440_0000 else { continue }
            let a = (ip >> 24) & 0xFF, b = (ip >> 16) & 0xFF, c = (ip >> 8) & 0xFF, d = ip & 0xFF
            return "\(a).\(b).\(c).\(d)"
        }
        return nil
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            running = true
            port = listener?.port?.rawValue ?? 0
            lastError = nil
        case .failed(let error):
            lastError = error.localizedDescription
            running = false
            stop()
        case .cancelled:
            running = false
        default:
            break
        }
    }

    // MARK: Addresses the phone can reach

    /// The link to open on a phone, token and all, or nil until it is ready.
    var address: String? {
        guard running, port != 0 else { return nil }
        // The Mac's Bonjour name stays the same when its IP address changes,
        // so a phone that saved the link keeps reaching it.
        if let name = Self.localName() { return "http://\(name):\(port)/#\(token)" }
        return ipLink
    }

    /// The same link by IP address, for a phone that cannot look up `.local`
    /// names (some Android browsers).
    var ipLink: String? {
        guard running, port != 0, let ip = Self.lanAddress() else { return nil }
        return "http://\(ip):\(port)/#\(token)"
    }

    /// "Harshs-MacBook-Pro.local", or nil when the Mac has no local name.
    static func localName() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
        return name + ".local"
    }

    /// The Mac's address on the local network, for the link above.
    static func lanAddress() -> String? {
        var result: String?
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var pointer = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            // Wi-Fi and wired come first; skip bridges and virtual adapters.
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(current.pointee.ifa_addr.pointee.sa_len)
            if getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if name == "en0" { return ip }   // the usual Wi-Fi: prefer it
                if result == nil { result = ip }
            }
        }
        return result
    }

    private static let tokenAccount = "remotePairingCode"

    /// The pairing code kept from before, or a new one if there is none.
    private static func storedToken() -> String {
        if let kept = Keychain.read(tokenAccount), !kept.isEmpty { return kept }
        let made = freshToken()
        Keychain.write(made, account: tokenAccount)
        return made
    }

    /// A new pairing code: every phone that had the old one is cut off and
    /// has to scan again.
    func newCode() {
        token = Self.freshToken()
        Keychain.write(token, account: Self.tokenAccount)
        for connection in feeds.values { connection.cancel() }
        feeds = [:]
        // The relay's key goes with it: a device cut off here is cut off there.
        RemoteRelay.shared.newKey()
        LocalLink.shared.restart()
        objectWillChange.send()
    }

    private static func freshToken() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<10).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        // This Mac and its own network only: the server says it answers
        // there, and now it does. A full house waits for a slot.
        guard Self.isNearby(connection.endpoint), buffers.count < Self.connectionLimit else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        buffers[id] = Data()
        pending.insert(id)
        if case let .hostPort(host, _) = connection.endpoint { peers[id] = "\(host)" }
        // A request not in full by then is dropped, so slow connections
        // cannot hold every slot.
        Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(Self.requestDeadline))
            guard let self, let connection, self.pending.contains(id) else { return }
            connection.cancel()
        }
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                Task { @MainActor in self?.drop(id) }
            } else if case .failed = state {
                Task { @MainActor in self?.drop(id) }
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receive(on: connection, id: id)
    }

    private func drop(_ id: ObjectIdentifier) {
        buffers[id] = nil
        feeds[id] = nil
        pending.remove(id)
        peers[id] = nil
    }

    private func receive(on connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty, self.buffers[id] != nil {
                    // In place: a copy of the buffer for every piece made a
                    // large upload slow, on the main thread.
                    self.buffers[id]?.append(data)
                    switch self.takeRequest(id: id) {
                    case .complete(let request):
                        self.pending.remove(id)
                        self.route(request, on: connection, id: id)
                        return   // routing decides whether to keep reading
                    case .refused(let status, let reason):
                        self.pending.remove(id)
                        self.buffers[id] = nil
                        self.send(status: status, body: reason, on: connection)
                        return
                    case .waiting:
                        break
                    }
                }
                if error != nil || done {
                    connection.cancel()
                    self.drop(id)
                } else {
                    self.receive(on: connection, id: id)
                }
            }
        }
    }

    /// One parsed request: method, path, query and body.
    private struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var body: String
        /// The body as it came (a file the phone sends).
        var data: Data
    }

    /// What became of what a connection has sent so far.
    private enum Taken {
        /// Not all there yet.
        case waiting
        case complete(Request)
        /// Refused before the rest is read: a status line and a reason.
        case refused(String, String)
    }

    /// Pulls a whole request out of the buffer once it has arrived.
    ///
    /// What can be judged from the head is judged before the body is waited
    /// for (security review, M1): the head's size, a length that is missing
    /// its sense or over the route's cap, and the pairing code. So a caller
    /// without the code cannot make this Mac hold a large body, or stop it
    /// with a length that does not add up.
    private func takeRequest(id: ObjectIdentifier) -> Taken {
        guard let buffer = buffers[id] else { return .waiting }
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > Self.headerLimit
                ? .refused("431 Request Header Fields Too Large", "Too large.") : .waiting
        }
        let bad = Taken.refused("400 Bad Request", "Bad request.")
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard headerData.count <= Self.headerLimit,
              let header = String(data: headerData, encoding: .utf8) else { return bad }
        let lines = header.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").components(separatedBy: " ")
        guard parts.count >= 2 else { return bad }
        let method = parts[0]
        let target = parts[1]

        var lengths: Set<String> = []
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == "content-length" {
                lengths.insert(pair[1])
            }
        }
        guard lengths.count <= 1 else { return bad }
        let contentLength = lengths.first.map { Int($0) ?? -1 } ?? 0
        guard contentLength >= 0 else { return bad }

        var path = target
        var query: [String: String] = [:]
        if let mark = target.firstIndex(of: "?") {
            path = String(target[..<mark])
            let queryString = String(target[target.index(after: mark)...])
            for pair in queryString.components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 {
                    query[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                }
            }
        }
        // The code before the body: without it, nothing more is read.
        if !Self.isPublic(path) {
            let peer = peers[id] ?? ""
            if tooManyWrongCodes(from: peer) {
                return .refused("429 Too Many Requests", "Too many wrong codes. Try again in a few minutes.")
            }
            guard !token.isEmpty, Self.sameCode(query["token"] ?? "", token) else {
                noteWrongCode(from: peer)
                return .refused("401 Unauthorized", "Pair this device again.")
            }
        }
        let cap = path == "/attach" ? Self.attachmentLimit : Self.bodyLimit
        guard contentLength <= cap else { return .refused("413 Payload Too Large", "Too large.") }

        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else { return .waiting }
        let bodyData = buffer[bodyStart..<buffer.index(bodyStart, offsetBy: contentLength)]
        buffers[id] = Data()   // request taken; buffer cleared
        return .complete(Request(method: method, path: path, query: query,
                                 body: String(data: bodyData, encoding: .utf8) ?? "", data: Data(bodyData)))
    }

    /// What answers without the pairing code: the pages, and what iOS needs
    /// to add them to the Home Screen. What they show is asked for with it.
    private static func isPublic(_ path: String) -> Bool {
        ["/", "/index.html", "/web", "/glass", "/manifest.json", "/icon.png", "/link"].contains(path)
    }

    /// The pairing code compared in the same time whatever it holds.
    private static func sameCode(_ given: String, _ expected: String) -> Bool {
        let given = Array(given.utf8), expected = Array(expected.utf8)
        guard given.count == expected.count else { return false }
        return zip(given, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func tooManyWrongCodes(from peer: String) -> Bool {
        guard let entry = wrongCodes[peer] else { return false }
        if Date().timeIntervalSince(entry.since) > Self.wrongCodeWindow {
            wrongCodes[peer] = nil
            return false
        }
        return entry.count >= Self.wrongCodeLimit
    }

    private func noteWrongCode(from peer: String) {
        let now = Date()
        if let entry = wrongCodes[peer], now.timeIntervalSince(entry.since) <= Self.wrongCodeWindow {
            wrongCodes[peer] = (entry.count + 1, entry.since)
        } else {
            wrongCodes[peer] = (1, now)
        }
    }

    /// Whether a connection comes from this Mac or its own network: loopback,
    /// private and link-local addresses, the shared range that VPNs such as
    /// Tailscale use, or an address on one of this Mac's own networks (a
    /// campus network may give out public addresses).
    static func isNearby(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            let bytes = [UInt8](address.rawValue)
            return isNearby(v4: bytes) || localNetworks().v4.contains { $0.holds(bytes) }
        case .ipv6(let address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 16 else { return false }
            // An IPv4 address written as IPv6 (::ffff:a.b.c.d).
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                let v4 = Array(bytes[12..<16])
                return isNearby(v4: v4) || localNetworks().v4.contains { $0.holds(v4) }
            }
            if address == .loopback { return true }
            if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return true }   // fe80::/10
            if bytes[0] & 0xfe == 0xfc { return true }                     // fc00::/7
            return localNetworks().v6.contains(Data(bytes[0..<8]))
        default:
            return false
        }
    }

    private static func isNearby(v4 bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (127, _), (10, _), (192, 168), (169, 254), (172, 16...31), (100, 64...127): return true
        default: return false
        }
    }

    /// An IPv4 network this Mac is on: its address and mask, byte by byte.
    private struct Network {
        let address: [UInt8]
        let mask: [UInt8]

        func holds(_ other: [UInt8]) -> Bool {
            other.count == 4 && (0..<4).allSatisfy { other[$0] & mask[$0] == address[$0] & mask[$0] }
        }
    }

    /// The networks of this Mac's own interfaces: IPv4 subnets (none wider
    /// than a /8, so an odd interface cannot let everyone in) and the /64
    /// prefixes of its IPv6 addresses.
    private static func localNetworks() -> (v4: [Network], v6: Set<Data>) {
        var v4: [Network] = []
        var v6: Set<Data> = []
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return (v4, v6) }
        defer { freeifaddrs(first) }
        var cursor = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            if address.pointee.sa_family == UInt8(AF_INET), let mask = entry.pointee.ifa_netmask {
                var ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let network = Network(address: withUnsafeBytes(of: &ip) { Array($0) },
                                      mask: withUnsafeBytes(of: &netmask) { Array($0) })
                if network.mask.first == 0xff { v4.append(network) }
            } else if address.pointee.sa_family == UInt8(AF_INET6) {
                var ip = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let bytes = withUnsafeBytes(of: &ip) { Data($0) }
                v6.insert(Data(bytes.prefix(8)))
            }
        }
        return (v4, v6)
    }

    // MARK: Routing

    private func route(_ request: Request, on connection: NWConnection, id: ObjectIdentifier) {
        // The page itself is public; everything with data needs the token.
        if request.path == "/" || request.path == "/index.html" {
            send(html: Self.page, on: connection)
            return
        }
        // The browser's page and the glasses' page are public like the one
        // above; what they show is asked for with the pairing code.
        if request.path == "/web" || request.path == "/glass" {
            let glass = request.path == "/glass" || request.query["glass"] == "1"
            send(html: glass ? Self.glassPage : Self.webPage, on: connection)
            return
        }
        // Where the apps' sealed way in listens (`LocalLink`). They ask
        // before anything else, so nothing they send here carries the code.
        if request.path == "/link" {
            send(json: Self.json(["port": Int(LocalLink.shared.port), "v": 1]), on: connection)
            return
        }
        // What iOS needs to add the page to the Home Screen as an app.
        if request.path == "/manifest.json" {
            respond(status: "200 OK", type: "application/manifest+json", body: Data(Self.manifest.utf8), on: connection)
            return
        }
        if request.path == "/icon.png" {
            if let png = Self.iconPNG() {
                respond(status: "200 OK", type: "image/png", body: png, on: connection)
            } else {
                send(status: "404 Not Found", body: "", on: connection)
            }
            return
        }

        let given = request.query["token"] ?? ""
        guard !token.isEmpty, Self.sameCode(given, token) else {
            send(status: "401 Unauthorized", body: "Pair this device again.", on: connection)
            return
        }

        if request.method == "GET", request.path == "/events" {
            openFeed(connection, id: id)
            return
        }
        Task { @MainActor in
            let reply = await self.handle(request)
            self.respond(status: Self.statusLine(reply.status), type: reply.type, body: reply.body, on: connection)
        }
    }

    /// A request that came through the relay. It was sealed with the
    /// pairing's key, which proves it comes from a paired device, so it
    /// carries no pairing code; the feed comes by subscription there, not
    /// from `/events`.
    func answerRelayed(method: String, path: String, query: [String: String],
                       body: Data) async -> (status: Int, type: String, body: Data) {
        let request = Request(method: method, path: path, query: query,
                              body: String(data: body, encoding: .utf8) ?? "", data: body)
        let reply = await handle(request)
        return (reply.status, reply.type, reply.body)
    }

    /// What a request is answered with, however it came.
    private struct Reply {
        var status: Int
        var type: String
        var body: Data

        static func json(_ text: String) -> Reply {
            Reply(status: 200, type: "application/json", body: Data(text.utf8))
        }

        static func text(_ status: Int, _ text: String) -> Reply {
            Reply(status: status, type: "text/plain; charset=utf-8", body: Data(text.utf8))
        }

        static var ok: Reply { json("{\"ok\":true}") }
    }

    private static func statusLine(_ status: Int) -> String {
        switch status {
        case 200: return "200 OK"
        case 401: return "401 Unauthorized"
        case 404: return "404 Not Found"
        case 413: return "413 Payload Too Large"
        case 422: return "422 Unprocessable Entity"
        case 500: return "500 Internal Server Error"
        default: return "\(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)"
        }
    }

    /// Everything the app can ask, whether over the local network or
    /// through the relay: one set of rules for both.
    private func handle(_ request: Request) async -> Reply {
        switch (request.method, request.path) {
        case ("GET", "/state"):
            return .json(snapshotJSON())
        case ("POST", "/say"):
            // With the files the phone attached for it (`files=id,id`).
            let text = request.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let files = (request.query["files"] ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            if !text.isEmpty { AppState.shared.send(text, files: files) }
            return .ok
        case ("POST", "/attach"):
            // A photo or file from the phone: kept on this Mac and attached
            // to the open chat, for the message that is sent with it.
            let name = Self.safeFileName(request.query["name"] ?? "Attachment")
            guard !request.data.isEmpty, request.data.count <= 40_000_000 else {
                return .text(413, "Too large.")
            }
            let folder = ContextStore.shared.baseDir.appendingPathComponent("From phone", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(name)")
            do {
                try request.data.write(to: url)
            } catch {
                return .text(500, "Could not keep it.")
            }
            guard let id = await AppState.shared.attachFromPhone(url) else {
                return .text(422, "Could not read it.")
            }
            return .json(Self.json(["id": id.uuidString, "name": name]))
        case ("POST", "/screen"):
            // A look at this Mac's screen, answered in the chat (with the
            // question, when one is sent).
            let question = request.body.trimmingCharacters(in: .whitespacesAndNewlines)
            AppState.shared.answerScreenNow(question: question.isEmpty ? nil : question)
            return .ok
        case ("POST", "/edit"):
            // A message sent again, changed: {"id", "text", "choice"} where
            // choice is "", "fork", "rewindCode" or "forkAndRewind".
            if let object = try? JSONSerialization.jsonObject(with: request.data) as? [String: Any],
               let raw = object["id"] as? String, let id = UUID(uuidString: raw),
               let text = object["text"] as? String {
                let choice: AppState.GoBack? = switch (object["choice"] as? String) ?? "" {
                case "fork": .fork
                case "rewindCode": .rewindCode
                case "forkAndRewind": .forkAndRewind
                default: nil
                }
                AppState.shared.editMessage(id, to: text, choice)
            }
            return .ok
        case ("POST", "/stop"):
            let app = AppState.shared
            if app.agentHere { app.stopAgent() } else { app.stopReply() }
            return .ok
        case ("GET", "/models"):
            // The engines and their models, as the Mac's model picker lists them.
            let engines = EngineCatalog.engines.map { engine -> [String: Any] in
                ["id": engine.id,
                 "name": EngineCatalog.name(engine),
                 "place": EngineCatalog.place(engine),
                 "inUse": EngineCatalog.inUse(engine),
                 "current": EngineCatalog.current(engine),
                 "models": engine.models.map { model -> [String: Any] in
                     ["id": model,
                      "title": model.isEmpty ? "Default" : EngineCatalog.title(engine, model),
                      "note": EngineCatalog.note(engine, model) ?? ""]
                 }]
            }
            return .json(Self.json(["engines": engines]))
        case ("POST", "/model"):
            // {"engine": id, "model": model}: the engine and model that answer.
            if let object = try? JSONSerialization.jsonObject(with: request.data) as? [String: Any],
               let id = object["engine"] as? String, let model = object["model"] as? String,
               let engine = EngineCatalog.engines.first(where: { $0.id == id }),
               engine.models.contains(model) {
                EngineCatalog.choose(engine, model)
            }
            return .ok
        case ("POST", "/access"):
            // Manual, Auto (edits) or Auto (full access), for this chat. From
            // here it only comes down: raising it is decided at the Mac, where
            // its approvals are (security review, C1).
            let raw = request.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let access = AgentAccess(rawValue: raw) else { return .ok }
            guard access.reach <= AppState.shared.agentAccess.reach else {
                return .text(403, "Raise access on the Mac.")
            }
            AppState.shared.setAgentAccess(access)
            return .ok
        case ("POST", "/effort"):
            // A level the engine takes, or "" to leave it to the model.
            let level = request.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let settings = AppSettings.shared
            if level.isEmpty || settings.effortLevels.contains(level) { settings.chosenEffort = level }
            return .ok
        case ("POST", "/queued"):
            // A waiting message: "now <id>", "cancel <id>" or "restore <id>".
            let parts = request.body.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            let app = AppState.shared
            if parts.count == 2, let id = UUID(uuidString: String(parts[1])) {
                switch parts[0] {
                case "now": app.sendQueuedNow(id)
                case "cancel": app.setQueuedVoid(id, true)
                case "restore": app.setQueuedVoid(id, false)
                default: break
                }
            }
            return .ok
        case ("GET", "/info"):
            // What an app needs to keep reaching this Mac: its addresses
            // and its relay change, its id does not.
            return .json(Self.json(["id": Self.macID, "name": Self.macName, "port": Int(port),
                                    "hosts": hosts, "relay": RemoteRelay.shared.advertised, "api": 1]))
        case ("GET", "/image"):
            // Only the picture of a turn in the open chat, looked up by the
            // turn, so no path from the phone ever reaches the disk.
            let app = AppState.shared
            if let raw = request.query["id"], let id = UUID(uuidString: raw),
               let file = app.conversation.turns.first(where: { $0.id == id })?.imageFile,
               let data = try? Data(contentsOf: app.store.imageURL(conversation: app.conversation.id, file: file)) {
                let type = file.lowercased().hasSuffix(".png") ? "image/png" : "image/jpeg"
                return Reply(status: 200, type: type, body: data)
            }
            return .text(404, "")
        case ("GET", "/chats"):
            return .json(chatsJSON())
        case ("GET", "/projects"):
            return .json(projectsJSON())
        case ("GET", "/project/chats"):
            // One project's chats (`id` is the project's), for a browser.
            if let raw = request.query["id"], let id = UUID(uuidString: raw), let json = projectChatsJSON(id) {
                return .json(json)
            }
            return .text(404, "No such project.")
        case ("POST", "/open"):
            let raw = request.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = UUID(uuidString: raw) { AppState.shared.openConversation(id) }
            return .ok
        case ("POST", "/new"):
            AppState.shared.newConversation()
            return .ok
        default:
            return .text(404, "No such thing here.")
        }
    }

    // MARK: The live feed

    private func openFeed(_ connection: NWConnection, id: ObjectIdentifier) {
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream\r
        Cache-Control: no-cache\r
        Connection: keep-alive\r
        Access-Control-Allow-Origin: *\r
        \r

        """
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        feeds[id] = connection
        // The phone gets the whole conversation the moment it joins; after
        // that, only what changes.
        let (meta, turns) = snapshotParts()
        pushToFeed(connection, event: message(meta: meta, order: turns.map { $0.id }, changed: turns.map { $0.json }, full: true))
    }

    private func startPump() {
        pump?.cancel()
        lastTurns = [:]
        lastOrder = []
        lastMeta = ""
        dirty = true
        changeWatch = []
        AppState.shared.objectWillChange
            .sink { [weak self] _ in self?.dirty = true }
            .store(in: &changeWatch)
        AppSettings.shared.objectWillChange
            .sink { [weak self] _ in self?.dirty = true }
            .store(in: &changeWatch)
        pump = Task { @MainActor in
            while !Task.isCancelled {
                broadcastIfChanged()
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
    }

    private func broadcastIfChanged() {
        let relay = RemoteRelay.shared
        let local = LocalLink.shared
        guard !feeds.isEmpty || relay.listening || local.listening else { return }
        // A comment line now and then keeps idle connections open, and a
        // phone that has gone away is found out when the send fails.
        if Date().timeIntervalSince(lastPing) > 15 {
            lastPing = Date()
            for connection in feeds.values { write(": ping\n\n", to: connection) }
        }
        // Nothing may have changed: then there is nothing to work out, but
        // once every few seconds it is looked at anyway, for anything that
        // changes without saying so.
        guard dirty || Date().timeIntervalSince(lastFullCheck) > 3 else { return }
        dirty = false
        lastFullCheck = Date()
        let (meta, turns) = snapshotParts()
        let order = turns.map { $0.id }
        let changed = turns.filter { lastTurns[$0.id] != $0.json }
        guard meta != lastMeta || order != lastOrder || !changed.isEmpty else { return }
        lastMeta = meta
        lastOrder = order
        lastTurns = Dictionary(turns.map { ($0.id, $0.json) }, uniquingKeysWith: { $1 })
        let event = message(meta: meta, order: order, changed: changed.map { $0.json }, full: false)
        for connection in feeds.values { pushToFeed(connection, event: event) }
        relay.publish(event)
        local.publish(event)
    }

    private func pushToFeed(_ connection: NWConnection, event json: String) {
        // Each line of the payload is its own `data:` line, per the format.
        let payload = json.components(separatedBy: "\n").map { "data: \($0)" }.joined(separator: "\n")
        write(payload + "\n\n", to: connection)
    }

    private func write(_ text: String, to connection: NWConnection) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
            // The phone is gone: closing it takes it off the list of feeds.
            if error != nil { connection.cancel() }
        })
    }

    /// One message for the phone: the chat's state, the order of its turns,
    /// and the turns that changed (all of them when `full`).
    private func message(meta: String, order: [String], changed: [String], full: Bool) -> String {
        let ids = (try? JSONSerialization.data(withJSONObject: order)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "{\"full\":\(full),\"meta\":\(meta),\"order\":\(ids),\"changed\":[\(changed.joined(separator: ","))]}"
    }

    // MARK: Snapshot of the conversation

    /// The whole conversation, as a feed event: what a device that just
    /// subscribed through the relay is sent first.
    func snapshotEvent() -> String { snapshotJSON() }

    /// The whole conversation as one JSON object, for `/state`.
    private func snapshotJSON() -> String {
        let (meta, turns) = snapshotParts()
        return message(meta: meta, order: turns.map { $0.id }, changed: turns.map { $0.json }, full: true)
    }

    private static func json(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// The chat's state, and each recent turn as its own JSON.
    private func snapshotParts() -> (meta: String, turns: [(id: String, json: String)]) {
        let app = AppState.shared
        // When this chat last changed a file, looked up once for every turn.
        let lastChange = ChangeStore.shared.lastChange(of: app.conversation.id)
        let turns: [(id: String, json: String)] = app.conversation.turns.suffix(60).map { turn in
            let id = turn.id.uuidString
            return (id, Self.json([
                "id": id,
                "me": turn.prompt,
                "reply": turn.answer,
                "model": turn.model,
                "error": turn.error ?? "",
                "image": turn.imageFile != nil,
                "streaming": app.streamingTurns.contains(turn.id),
                "working": turn.steps?.isEmpty == false,
                "date": turn.date.timeIntervalSince1970,
                // What the agent did, briefly, for the app's work list.
                "steps": (turn.steps ?? []).filter { $0.kind != .think }.suffix(40).map {
                    ["kind": $0.kind.rawValue, "title": String($0.title.prefix(300)), "failed": $0.failed,
                     "why": $0.why ?? "", "output": String(($0.output ?? "").suffix(600))]
                },
                "plan": (turn.plan ?? []).map { ["text": $0.text, "state": $0.state.rawValue] },
                "suggestions": turn.suggestions ?? [],
                // Files changed since this message, so editing it offers
                // to fork the chat or put them back.
                "canRewind": !turn.prompt.isEmpty && lastChange.map { $0 >= turn.date } == true
            ]))
        }
        var root: [String: Any] = [
            "chat": app.conversation.id.uuidString,
            "title": app.conversation.title,
            "status": app.statusLine,
            "agentRunning": app.agentHere,
            "agentStatus": app.agentStatus ?? "",
            "replying": app.replyStreamingHere,
            "mac": Self.macName,
            // The chat box's controls, as on the Mac.
            "model": app.engineLabel,
            "effort": AppSettings.shared.chosenEffort,
            "efforts": AppSettings.shared.effortLevels,
            "access": app.agentAccess.rawValue,
            // Messages sent while the agent works, waiting for it.
            "queued": app.queuedHere.map { ["id": $0.id.uuidString, "text": $0.text, "void": $0.void] }
        ]
        if let question = app.pendingQuestion {
            root["question"] = question.question
            root["options"] = question.options
        }
        if app.pendingApproval != nil {
            // The phone is told the agent is waiting, but approving stays on
            // the Mac, so it offers no Allow button for it.
            root["awaitingApproval"] = true
        }
        return (Self.json(root), turns)
    }

    /// The recent conversations, newest first, for the phone's chat list.
    private func chatsJSON() -> String {
        let app = AppState.shared
        app.refreshHistory()
        let list: [[String: Any]] = app.history.prefix(40).map { summary in
            ["id": summary.id.uuidString,
             "title": summary.title,
             "date": summary.updatedAt.timeIntervalSince1970,
             "turns": summary.turnCount,
             // A task running in it, and whether it waits on you.
             "running": app.jobs[summary.id] != nil,
             "waiting": app.chatsWaiting.contains(summary.id)]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["current": app.conversation.id.uuidString,
                                                                 "chats": list])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// The projects, in the sidebar's order, each with its newest chat, for
    /// the phone's Projects list. A project with no chats is listed too,
    /// with no chat and its own creation date.
    private func projectsJSON() -> String {
        let app = AppState.shared
        // Every saved chat, not the sidebar's search results.
        let chats = app.store.list()
        let list: [[String: Any]] = app.projects.map { project in
            let latest = chats.first { $0.projectID == project.id }
            return ["id": project.id.uuidString,
                    "name": project.name,
                    "folder": project.folder.map { $0 as Any } ?? NSNull(),
                    "chatID": latest.map { $0.id.uuidString as Any } ?? NSNull(),
                    "chatTitle": latest.map { $0.title as Any } ?? NSNull(),
                    "chats": chats.filter { $0.projectID == project.id }.count,
                    "updatedAt": (latest?.updatedAt ?? project.createdAt).timeIntervalSince1970]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["projects": list])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// One project's saved chats, newest first, each in the shape `/chats`
    /// gives, with the project's name and folder. Nil when the project is
    /// not on the list.
    private func projectChatsJSON(_ id: UUID) -> String? {
        let app = AppState.shared
        guard let project = app.projects.first(where: { $0.id == id }) else { return nil }
        // Every saved chat, not the sidebar's search results.
        let list: [[String: Any]] = app.store.list().filter { $0.projectID == id }.prefix(60).map { summary in
            ["id": summary.id.uuidString,
             "title": summary.title,
             "date": summary.updatedAt.timeIntervalSince1970,
             "turns": summary.turnCount,
             "running": app.jobs[summary.id] != nil,
             "waiting": app.chatsWaiting.contains(summary.id)]
        }
        let root: [String: Any] = ["id": project.id.uuidString,
                                   "name": project.name,
                                   "folder": project.folder.map { $0 as Any } ?? NSNull(),
                                   "current": app.conversation.id.uuidString,
                                   "chats": list]
        return Self.json(root)
    }

    /// A file name from the phone, safe to put on disk.
    static func safeFileName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
        let cleaned = String(raw.unicodeScalars.filter { allowed.contains($0) }).trimmingCharacters(in: .whitespaces)
        let name = cleaned.replacingOccurrences(of: "..", with: ".")
        return name.isEmpty ? "Attachment" : String(name.prefix(80))
    }

    /// The app's own icon as a PNG, for the Home Screen.
    private static func iconPNG() -> Data? {
        #if canImport(AppKit)
        let size = NSSize(width: 180, height: 180)
        let image = NSImage(size: size)
        image.lockFocus()
        NSApp.applicationIconImage?.draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }

    private static let manifest = """
    {"name":"Companion","short_name":"Companion","start_url":"/","display":"standalone",
     "background_color":"#0e0f13","theme_color":"#0e0f13",
     "icons":[{"src":"/icon.png","sizes":"180x180","type":"image/png"}]}
    """

    // MARK: Plain responses

    private func send(html: String, on connection: NWConnection) {
        respond(status: "200 OK", type: "text/html; charset=utf-8", body: Data(html.utf8), on: connection)
    }

    private func send(json: String, on connection: NWConnection) {
        respond(status: "200 OK", type: "application/json", body: Data(json.utf8), on: connection)
    }

    private func send(status: String, body: String, on connection: NWConnection) {
        respond(status: status, type: "text/plain; charset=utf-8", body: Data(body.utf8), on: connection)
    }

    private func respond(status: String, type: String, body: Data, on connection: NWConnection) {
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: \(type)\r
        Content-Length: \(body.count)\r
        Access-Control-Allow-Origin: *\r
        Connection: close\r
        \r

        """
        var data = Data(header.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: The QR code for the link

    #if canImport(AppKit)
    /// A QR image of a string, for showing the link where a phone can read it.
    static func qrImage(for string: String, size: CGFloat = 180) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
    #endif

    // MARK: The phone's page

    /// The whole web app, one self-contained page. It reads the token from
    /// the link's `#`, streams the conversation, and posts messages back.
    static let page = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <title>Companion</title>
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="apple-mobile-web-app-title" content="Companion">
    <meta name="theme-color" content="#0e0f13">
    <link rel="manifest" href="/manifest.json">
    <link rel="apple-touch-icon" href="/icon.png">
    <style>
      :root { color-scheme: dark; --bg:#0e0f13; --card:#1a1c22; --line:#2a2d36;
              --ink:#eef0f5; --dim:#9aa0ad; --accent:#8b7cf6; --me:#232733; --mint:#4fd1a6; }
      * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
      body { margin:0; background:var(--bg); color:var(--ink);
             font:15px/1.5 -apple-system,system-ui,sans-serif;
             padding-top: env(safe-area-inset-top); }
      header { position:sticky; top:0; background:rgba(14,15,19,.9);
               backdrop-filter:blur(12px); border-bottom:1px solid var(--line);
               padding:12px max(16px,env(safe-area-inset-left)) 12px max(16px,env(safe-area-inset-right));
               display:flex; align-items:center; gap:10px; }
      header b { font-size:15px; font-weight:600; }
      header .status { color:var(--dim); font-size:12px; margin-left:auto; }
      main { padding:14px max(16px,env(safe-area-inset-left)) 120px max(16px,env(safe-area-inset-right));
             display:flex; flex-direction:column; gap:14px; }
      .turn { display:flex; flex-direction:column; gap:8px; }
      .me { align-self:flex-end; max-width:85%; background:var(--me); color:var(--ink);
            padding:9px 13px; border-radius:16px 16px 4px 16px; white-space:pre-wrap; }
      .reply { align-self:flex-start; max-width:92%; white-space:pre-wrap; }
      .reply .model { color:var(--dim); font-size:11px; margin-bottom:4px;
                      text-transform:uppercase; letter-spacing:.4px; }
      .err { color:#ff8080; }
      .dots::after { content:'...'; animation:blink 1.2s steps(4,end) infinite; }
      @keyframes blink { 0%{opacity:.3} 50%{opacity:1} 100%{opacity:.3} }
      .ask { align-self:flex-start; background:var(--card); border:1px solid var(--accent);
             border-radius:12px; padding:10px 13px; color:var(--ink); }
      .ask .label { color:var(--accent); font-size:11px; text-transform:uppercase;
                    letter-spacing:.4px; margin-bottom:4px; }
      footer { position:fixed; left:0; right:0; bottom:0; background:rgba(14,15,19,.94);
               backdrop-filter:blur(12px); border-top:1px solid var(--line);
               padding:10px max(12px,env(safe-area-inset-left))
                       calc(10px + env(safe-area-inset-bottom)) max(12px,env(safe-area-inset-right));
               display:flex; gap:8px; align-items:flex-end; }
      textarea { flex:1; resize:none; background:var(--card); color:var(--ink);
                 border:1px solid var(--line); border-radius:14px; padding:10px 13px;
                 font:15px/1.4 inherit; max-height:120px; }
      button { border:0; border-radius:14px; padding:0 16px; height:42px; font-weight:600;
               font-size:15px; background:var(--accent); color:#fff; }
      button.stop { background:#e2556a; }
      button:disabled { opacity:.4; }
      .note { color:var(--dim); font-size:12px; text-align:center; padding:20px; }
      .shot { max-width:100%; border-radius:10px; border:1px solid var(--line); margin-bottom:6px; display:block; }
      .reply pre { background:var(--card); border:1px solid var(--line); border-radius:10px;
                   padding:10px; overflow-x:auto; font:12.5px/1.45 ui-monospace,Menlo,monospace;
                   white-space:pre; margin:6px 0; }
      .reply code { font:13px ui-monospace,Menlo,monospace; background:var(--card);
                    padding:1px 5px; border-radius:5px; }
      .opts { display:flex; flex-wrap:wrap; gap:8px; margin-top:8px; }
      .opts button { height:34px; font-size:14px; background:var(--me); border:1px solid var(--accent); }
      header .icon { background:none; height:32px; width:32px; padding:0; font-size:20px;
                     color:var(--ink); }
      #drawer { position:fixed; inset:0; background:rgba(0,0,0,.5); display:none; z-index:5; }
      #drawer.open { display:block; }
      #drawer .sheet { position:absolute; top:0; bottom:0; left:0; width:min(320px,85%);
                       background:var(--bg); border-right:1px solid var(--line); overflow-y:auto;
                       padding:calc(12px + env(safe-area-inset-top)) 12px 20px max(12px,env(safe-area-inset-left)); }
      .chat { padding:10px 12px; border-radius:10px; cursor:pointer; }
      .chat.on { background:var(--me); }
      .chat .t { font-size:14px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
      .chat .d { color:var(--dim); font-size:11px; }
      .sheet button.new { width:100%; margin-bottom:10px; }
    </style>
    </head>
    <body>
      <header><button class="icon" id="menu" aria-label="Chats">&#9776;</button><b id="title">Companion</b><span class="status" id="status">connecting...</span></header>
      <div id="drawer"><div class="sheet"><button class="new" id="newchat">New chat</button><div id="chats"></div></div></div>
      <main id="log"><div class="note" id="empty">Waiting for the conversation...</div></main>
      <footer>
        <textarea id="box" rows="1" placeholder="Message" autocapitalize="sentences"></textarea>
        <button id="send">Send</button>
      </footer>
    <script>
      // The code comes in the link's #; it is kept so the Home Screen app
      // still knows it when opened without one.
      let token = location.hash.slice(1);
      try { if(token) localStorage.setItem('companionToken', token); else token = localStorage.getItem('companionToken') || ''; } catch(_){}
      const log = document.getElementById('log');
      const statusEl = document.getElementById('status');
      const box = document.getElementById('box');
      const sendBtn = document.getElementById('send');
      let agentRunning = false;

      function esc(s){ return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
      // Just enough formatting to read: code blocks, inline code, bold.
      function fmt(s){
        const parts = s.split('```');
        return parts.map((p,i) => {
          if(i % 2 === 1){ return '<pre>'+esc(p.replace(/^[a-zA-Z0-9_+-]*\\n/,''))+'</pre>'; }
          return esc(p).replace(/`([^`]+)`/g,'<code>$1</code>').replace(/\\*\\*([^*]+)\\*\\*/g,'<b>$1</b>');
        }).join('');
      }
      async function post(path, body){ return fetch(path+'?token='+token,{method:'POST',body:body||''}); }

      // The turns as they stand, by id; each message brings only the ones
      // that changed, plus the order they go in.
      let turnsById = {};
      function apply(msg){
        if(msg.full) turnsById = {};
        for(const t of msg.changed) turnsById[t.id] = t;
        const state = msg.meta;
        state.turns = msg.order.map(id => turnsById[id]).filter(Boolean);
        const keep = {}; for(const t of state.turns) keep[t.id] = t; turnsById = keep;
        render(state);
      }

      function render(state){
        const nearBottom = window.innerHeight + window.scrollY >= document.body.scrollHeight - 200;
        statusEl.textContent = state.status || 'Ready';
        agentRunning = state.agentRunning;
        sendBtn.textContent = agentRunning ? 'Stop' : 'Send';
        sendBtn.classList.toggle('stop', agentRunning);
        document.title = state.title ? 'Companion - ' + state.title : 'Companion';
        document.getElementById('title').textContent = state.title || 'Companion';
        currentChat = state.chat;
        let html = '';
        for(const t of state.turns){
          html += '<div class="turn">';
          if(t.image) html += '<img class="shot" loading="lazy" src="/image?token='+token+'&id='+t.id+'">';
          if(t.me) html += '<div class="me">'+esc(t.me)+'</div>';
          let body = fmt(t.reply);
          if(!t.reply && t.streaming) body = '<span class="dots"></span>';
          else if(t.streaming) body += '<span class="dots"></span>';
          if(t.error) html += '<div class="reply err">'+esc(t.error)+'</div>';
          else html += '<div class="reply"><div class="model">'+esc(t.model||'')+'</div>'+body+'</div>';
          html += '</div>';
        }
        if(state.question){
          html += '<div class="ask"><div class="label">It is asking</div>'+esc(state.question);
          if(state.options && state.options.length){
            html += '<div class="opts">' + state.options.map(o => '<button data-say="'+esc(o)+'">'+esc(o)+'</button>').join('') + '</div>';
          }
          html += '</div>';
        }
        if(state.awaitingApproval) html += '<div class="ask"><div class="label">Waiting on the Mac</div>Approve what the agent wants to do on the Mac itself.</div>';
        log.innerHTML = html || '<div class="note">No messages yet. Say something below.</div>';
        if(nearBottom) window.scrollTo(0, document.body.scrollHeight);
      }

      function connect(){
        const source = new EventSource('/events?token='+token);
        source.onmessage = e => { try { apply(JSON.parse(e.data)); } catch(_){} };
        source.onerror = () => { statusEl.textContent='reconnecting...'; };
        source.onopen = () => { statusEl.textContent='Ready'; };
      }

      let currentChat = '';
      async function send(){
        if(agentRunning){ await post('/stop'); return; }
        const text = box.value.trim();
        if(!text) return;
        box.value=''; box.style.height='auto';
        await post('/say', text);
      }

      // Tapping one of the agent's offered answers sends it.
      log.addEventListener('click', e => {
        const b = e.target.closest('button[data-say]');
        if(b) post('/say', b.getAttribute('data-say'));
      });

      // The list of chats, slid in from the left.
      const drawer = document.getElementById('drawer');
      async function openDrawer(){
        drawer.classList.add('open');
        try {
          const r = await fetch('/chats?token='+token); const data = await r.json();
          document.getElementById('chats').innerHTML = data.chats.map(c =>
            '<div class="chat'+(c.id===data.current?' on':'')+'" data-id="'+c.id+'"><div class="t">'+esc(c.title)+'</div>'+
            '<div class="d">'+new Date(c.date*1000).toLocaleString([], {month:'short',day:'numeric',hour:'numeric',minute:'2-digit'})+'</div></div>').join('');
        } catch(_){}
      }
      document.getElementById('menu').onclick = openDrawer;
      drawer.addEventListener('click', async e => {
        const c = e.target.closest('.chat');
        if(c){ await post('/open', c.getAttribute('data-id')); drawer.classList.remove('open'); window.scrollTo(0,0); return; }
        if(e.target === drawer) drawer.classList.remove('open');
      });
      document.getElementById('newchat').onclick = async () => { await post('/new'); drawer.classList.remove('open'); };

      sendBtn.onclick = send;
      box.addEventListener('input', () => { box.style.height='auto'; box.style.height=Math.min(box.scrollHeight,120)+'px'; });
      box.addEventListener('keydown', e => { if(e.key==='Enter' && !e.shiftKey){ e.preventDefault(); send(); } });
      if(!token){ log.innerHTML='<div class="note">This link is missing its pairing code. Scan the code in Companion > Settings > Remote again.</div>'; }
      else connect();
    </script>
    </body>
    </html>
    """
}
