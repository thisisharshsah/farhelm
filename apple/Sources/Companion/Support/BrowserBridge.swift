import AppKit
import Foundation

/// The connection to the user's own Chrome (or Brave, Edge, Chromium):
/// Companion's Chrome extension runs the agent's browser steps in real tabs,
/// so everything Chrome already has keeps working there, iCloud Passwords
/// and passkeys included.
///
/// How it connects: Chrome starts a native messaging host for the
/// extension (a two-line script that hands its input and output to a Unix
/// socket), and Companion listens on that socket. Messages are Chrome's
/// own framing: a 4-byte little-endian length, then JSON.
///
/// The extension never reads or types into password fields; signing in is
/// the user's, with iCloud Passwords.
@MainActor
final class BrowserBridge: ObservableObject {
    static let shared = BrowserBridge()

    /// The extension's fixed id (from the key in its manifest).
    static let extensionID = "eiikkecggfckdlnhdokmnfhpgepdfmbk"
    static let hostName = "com.companion.browser"

    @Published private(set) var connected = false
    @Published private(set) var browser = ""
    @Published var note = ""

    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var client: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<[String: Any]?, Never>] = [:]

    private static var base: URL { ContextStore.shared.baseDir }
    static var socketPath: String { base.appendingPathComponent("browser.sock").path }
    static var extensionFolder: URL { base.appendingPathComponent("ChromeExtension", isDirectory: true) }
    private static var hostScript: URL { base.appendingPathComponent("chrome-host.sh") }

    /// The browsers whose native messaging folders get the host manifest.
    private static let browsers: [(name: String, folder: String)] = [
        ("Chrome", "Google/Chrome"), ("Chrome Beta", "Google/Chrome Beta"), ("Chrome Canary", "Google/Chrome Canary"),
        ("Chromium", "Chromium"), ("Brave", "BraveSoftware/Brave-Browser"), ("Edge", "Microsoft Edge"),
        ("Arc", "Arc/User Data")
    ]

    // MARK: Setting up

    /// Whether the host is in place for at least one browser.
    var installed: Bool {
        FileManager.default.fileExists(atPath: Self.extensionFolder.appendingPathComponent("manifest.json").path)
            && FileManager.default.fileExists(atPath: Self.hostScript.path)
    }

    /// Puts the extension where Chrome can load it, and the native host and
    /// its manifest where each installed Chromium browser looks for them.
    func install() {
        let fm = FileManager.default
        do {
            guard let source = Bundle.main.resourceURL?.appendingPathComponent("ChromeExtension", isDirectory: true),
                  fm.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
                note = "The extension is not in this build of Companion. Rebuild with build.sh."
                return
            }
            try fm.createDirectory(at: Self.extensionFolder, withIntermediateDirectories: true)
            for name in try fm.contentsOfDirectory(atPath: source.path) {
                let target = Self.extensionFolder.appendingPathComponent(name)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: source.appendingPathComponent(name), to: target)
            }
            let script = "#!/bin/sh\n# Companion's Chrome connection: hands Chrome's messages to the Companion app.\nexec /usr/bin/nc -U \"\(Self.socketPath)\"\n"
            try script.write(to: Self.hostScript, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.hostScript.path)
            let manifest: [String: Any] = [
                "name": Self.hostName,
                "description": "Companion: the agent's browser steps",
                "path": Self.hostScript.path,
                "type": "stdio",
                "allowed_origins": ["chrome-extension://\(Self.extensionID)/"]
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            var placed: [String] = []
            for browser in Self.browsers {
                let root = support.appendingPathComponent(browser.folder, isDirectory: true)
                guard fm.fileExists(atPath: root.path) else { continue }
                let hosts = root.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
                try fm.createDirectory(at: hosts, withIntermediateDirectories: true)
                try data.write(to: hosts.appendingPathComponent(Self.hostName + ".json"), options: .atomic)
                placed.append(browser.name)
            }
            note = placed.isEmpty
                ? "No Chrome, Brave, Edge or Chromium was found on this Mac."
                : "Connection set up for \(placed.joined(separator: ", ")). Now load the extension (step 2)."
            start()
        } catch {
            note = "Could not set it up: \(error.localizedDescription)"
        }
    }

    /// Opens the folder to choose in Chrome's "Load unpacked", and Chrome's
    /// extensions page.
    func showExtension() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.extensionFolder])
        let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
        if let chrome, let page = URL(string: "chrome://extensions") {
            NSWorkspace.shared.open([page], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Listening

    /// Listens for the extension. Safe to call more than once.
    func start() {
        guard listener < 0 else { return }
        let path = Self.socketPath
        try? FileManager.default.createDirectory(at: Self.base, withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: address.sun_path) - 1))
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            return
        }
        // Only this user may connect.
        chmod(path, 0o600)
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.accept() }
        }
        source.resume()
        acceptSource = source
    }

    private func accept() {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        // The newest connection is the one in use.
        drop()
        client = fd
        buffer = Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readable() }
        }
        source.resume()
        readSource = source
    }

    private func drop() {
        readSource?.cancel()
        readSource = nil
        if client >= 0 { close(client) }
        client = -1
        connected = false
        for (_, waiter) in waiting { waiter.resume(returning: nil) }
        waiting = [:]
    }

    private func readable() {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let count = read(client, &chunk, chunk.count)
        guard count > 0 else {
            drop()
            return
        }
        buffer.append(contentsOf: chunk[0..<count])
        while buffer.count >= 4 {
            let length = Int(buffer[buffer.startIndex]) | Int(buffer[buffer.startIndex + 1]) << 8
                | Int(buffer[buffer.startIndex + 2]) << 16 | Int(buffer[buffer.startIndex + 3]) << 24
            guard buffer.count >= 4 + length else { return }
            let body = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + 4 + length))
            buffer = Data(buffer.dropFirst(4 + length))
            if let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] { handle(message) }
        }
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "hello":
            connected = true
            let agent = message["agent"] as? String ?? ""
            browser = agent.contains("Edg/") ? "Edge" : (agent.contains("Brave") ? "Brave" : "Chrome")
            note = ""
        case "result":
            if let id = message["id"] as? Int, let waiter = waiting.removeValue(forKey: id) {
                var result = message["result"] as? [String: Any] ?? [:]
                result["ok"] = message["ok"] as? Bool ?? false
                waiter.resume(returning: result)
            }
        default:
            break
        }
    }

    private func write(_ message: [String: Any]) -> Bool {
        guard client >= 0, let body = try? JSONSerialization.data(withJSONObject: message) else { return false }
        var length = UInt32(body.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        let sent = frame.withUnsafeBytes { Darwin.write(client, $0.baseAddress, frame.count) }
        return sent == frame.count
    }

    // MARK: Commands

    /// Runs one command in Chrome and waits for its result.
    func run(_ command: String, _ args: [String: Any] = [:], timeout: Double = 45) async -> [String: Any] {
        guard connected else {
            return ["ok": false, "error": "Chrome is not connected to Companion (Settings > Agent > Chrome sets it up). Until it is: open a page in Chrome with run_command `open -a \"Google Chrome\" \"URL\"`, and ask the user to connect Chrome only if the work needs reading or clicking inside the page."]
        }
        let id = nextID
        nextID += 1
        let answer: [String: Any]? = await withCheckedContinuation { done in
            waiting[id] = done
            guard write(["type": "command", "id": id, "command": command, "args": args]) else {
                waiting.removeValue(forKey: id)?.resume(returning: nil)
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.waiting.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
        return answer ?? ["ok": false, "error": "Chrome did not answer in time."]
    }

    /// A step's result in words, for the agent: a page as its text and its
    /// numbered elements, anything else as what happened.
    static func describe(_ command: String, _ result: [String: Any]) -> (ok: Bool, text: String) {
        guard result["ok"] as? Bool == true else {
            return (false, "FAILED: " + (result["error"] as? String ?? "it did not work"))
        }
        switch command {
        case "read":
            var lines = ["Title: \(result["title"] as? String ?? "")", "URL: \(result["url"] as? String ?? "")", ""]
            lines.append("Text:\n" + (result["text"] as? String ?? ""))
            lines.append("\nElements (use their numbers to click or type):")
            for element in result["elements"] as? [[String: Any]] ?? [] {
                let kind = [element["tag"] as? String ?? "", element["type"] as? String ?? ""].filter { !$0.isEmpty }.joined(separator: ":")
                var line = "[\(element["i"] as? Int ?? 0)] \(kind) \"\(element["label"] as? String ?? "")\""
                if let href = element["href"] as? String, !href.isEmpty { line += " -> \(href)" }
                lines.append(line)
            }
            return (true, lines.joined(separator: "\n"))
        case "downloads":
            let list = (result["downloads"] as? [[String: Any]] ?? []).map {
                "\($0["name"] as? String ?? "") at \($0["path"] as? String ?? "")" + (($0["failed"] as? Bool) == true ? " (failed)" : "")
            }
            return (true, list.isEmpty ? "Nothing has been downloaded in this browser yet." : "Downloaded, newest first:\n" + list.joined(separator: "\n"))
        case "history":
            let list = (result["pages"] as? [[String: Any]] ?? []).map {
                "\($0["title"] as? String ?? "") <\($0["url"] as? String ?? "")>"
            }
            return (true, list.isEmpty ? "No page like that was opened in Companion's browser before." : list.joined(separator: "\n"))
        case "extensions":
            guard result["supported"] as? Bool != false else { return (true, "Extensions need macOS 15.4 or later on this Mac.") }
            var list: [String] = []
            for item in result["extensions"] as? [[String: Any]] ?? [] {
                let name = item["name"] as? String ?? "", version = item["version"] as? String ?? ""
                let state = (item["on"] as? Bool) == true ? "on" : "off", from = item["from"] as? String ?? ""
                let problem = item["problem"] as? String ?? ""
                list.append("\(name) \(version) (\(state), from \(from))" + (problem.isEmpty ? "" : ": \(problem)"))
            }
            return (true, list.isEmpty ? "Companion's browser has no extensions yet." : list.joined(separator: "\n"))
        case "add_extension":
            return (true, result["added"] as? String ?? "Added.")
        case "tabs":
            let tabs = (result["tabs"] as? [[String: Any]] ?? []).map {
                "tab \($0["tab"] as? Int ?? 0)\(($0["active"] as? Bool) == true ? " (active)" : ""): \($0["title"] as? String ?? "") <\($0["url"] as? String ?? "")>"
            }
            return (true, tabs.isEmpty ? "No tabs open." : tabs.joined(separator: "\n"))
        default:
            var text = "Done. Now on: \(result["title"] as? String ?? "") <\(result["url"] as? String ?? "")>"
            if let clicked = result["clicked"] as? String { text = "Clicked \"\(clicked)\". " + text }
            if let typed = result["typed"] as? String { text = "Typed into \(typed). " + text }
            if let files = result["uploaded"] as? [String] { text = "Chose \(files.joined(separator: ", ")) for the file field; submit the form to send them. " + text }
            if let saved = result["downloaded"] as? [String] { text += "\nSaved to this Mac: " + saved.joined(separator: ", ") }
            return (true, text)
        }
    }
}
