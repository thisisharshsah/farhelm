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
/// It answers only on the local network. Approving what the agent
/// wants to do (Allow / Deny) stays on the Mac; the phone can send
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
            listener.start(queue: .global(qos: .userInitiated))
            startPump()
        } catch {
            lastError = error.localizedDescription
            running = false
        }
    }

    func stop() {
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
        objectWillChange.send()
    }

    private static func freshToken() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<10).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        buffers[id] = Data()
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
    }

    private func receive(on connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty, var buffer = self.buffers[id] {
                    buffer.append(data)
                    self.buffers[id] = buffer
                    if let request = self.takeRequest(id: id) {
                        self.route(request, on: connection, id: id)
                        return   // routing decides whether to keep reading
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
    }

    /// Pulls a whole request out of the buffer once it has arrived, or nil
    /// while it is still coming.
    private func takeRequest(id: ObjectIdentifier) -> Request? {
        guard let buffer = buffers[id],
              let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let target = parts[1]

        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == "content-length" {
                contentLength = Int(pair[1]) ?? 0
            }
        }

        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return nil }   // body still arriving
        let bodyData = buffer[bodyStart..<buffer.index(bodyStart, offsetBy: contentLength)]
        buffers[id] = Data()   // request taken; buffer cleared

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
        return Request(method: method, path: path, query: query,
                       body: String(data: bodyData, encoding: .utf8) ?? "")
    }

    // MARK: Routing

    private func route(_ request: Request, on connection: NWConnection, id: ObjectIdentifier) {
        // The page itself is public; everything with data needs the token.
        if request.path == "/" || request.path == "/index.html" {
            send(html: Self.page, on: connection)
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
        guard !token.isEmpty, given == token else {
            send(status: "401 Unauthorized", body: "Pair this device again.", on: connection)
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/events"):
            openFeed(connection, id: id)
        case ("GET", "/state"):
            send(json: snapshotJSON(), on: connection)
        case ("POST", "/say"):
            let text = request.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { AppState.shared.send(text) }
            send(json: "{\"ok\":true}", on: connection)
        case ("POST", "/stop"):
            AppState.shared.stopAgent()
            send(json: "{\"ok\":true}", on: connection)
        case ("GET", "/image"):
            // Only the picture of a turn in the open chat, looked up by the
            // turn, so no path from the phone ever reaches the disk.
            let app = AppState.shared
            if let raw = request.query["id"], let id = UUID(uuidString: raw),
               let file = app.conversation.turns.first(where: { $0.id == id })?.imageFile,
               let data = try? Data(contentsOf: app.store.imageURL(conversation: app.conversation.id, file: file)) {
                let type = file.lowercased().hasSuffix(".png") ? "image/png" : "image/jpeg"
                respond(status: "200 OK", type: type, body: data, on: connection)
            } else {
                send(status: "404 Not Found", body: "", on: connection)
            }
        case ("GET", "/chats"):
            send(json: chatsJSON(), on: connection)
        case ("POST", "/open"):
            let raw = request.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = UUID(uuidString: raw) { AppState.shared.openConversation(id) }
            send(json: "{\"ok\":true}", on: connection)
        case ("POST", "/new"):
            AppState.shared.newConversation()
            send(json: "{\"ok\":true}", on: connection)
        default:
            send(status: "404 Not Found", body: "No such thing here.", on: connection)
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
        pump = Task { @MainActor in
            while !Task.isCancelled {
                broadcastIfChanged()
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
    }

    private func broadcastIfChanged() {
        guard !feeds.isEmpty else { return }
        // A comment line now and then keeps idle connections open, and a
        // phone that has gone away is found out when the send fails.
        if Date().timeIntervalSince(lastPing) > 15 {
            lastPing = Date()
            for connection in feeds.values { write(": ping\n\n", to: connection) }
        }
        let (meta, turns) = snapshotParts()
        let order = turns.map { $0.id }
        let changed = turns.filter { lastTurns[$0.id] != $0.json }
        guard meta != lastMeta || order != lastOrder || !changed.isEmpty else { return }
        lastMeta = meta
        lastOrder = order
        lastTurns = Dictionary(turns.map { ($0.id, $0.json) }, uniquingKeysWith: { $1 })
        let event = message(meta: meta, order: order, changed: changed.map { $0.json }, full: false)
        for connection in feeds.values { pushToFeed(connection, event: event) }
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
                "working": turn.steps?.isEmpty == false
            ]))
        }
        var root: [String: Any] = [
            "chat": app.conversation.id.uuidString,
            "title": app.conversation.title,
            "status": app.statusLine,
            "agentRunning": app.agentRunning
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
             "turns": summary.turnCount]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["current": app.conversation.id.uuidString,
                                                                 "chats": list])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
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

      function esc(s){ const d=document.createElement('div'); d.textContent=s; return d.innerHTML; }
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
