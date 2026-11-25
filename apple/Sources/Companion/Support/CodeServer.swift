import CEFKit
import Darwin
import Foundation
import Security

/// VS Code in code mode: code-server (VS Code's open-source core as a local
/// server, inside Companion.app) run on this Mac and shown in a Chromium
/// page, so VS Code's extensions work as in VS Code, from Open VSX.
///
/// It listens only on 127.0.0.1, on a port of its own, behind a password
/// made fresh each launch and handed over in its environment, never on
/// its command line. Its settings and extensions are Companion's own (in
/// Companion's folder), not the person's VS Code's. It is started as
/// Companion's own process: the editor, its terminal and its extensions are
/// the person's tools, with the folders the person let Companion reach.
@MainActor
final class CodeServer: ObservableObject {
    static let shared = CodeServer()

    /// The editor code mode uses: VS Code, or Companion's own.
    static let editorKey = "codeEditor"

    enum State: Equatable {
        case stopped
        case starting
        case ready(port: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    /// The editor's page, kept across chats so VS Code is not reloaded
    /// each time code mode shows, and the folder it has open.
    private(set) var page: ChromiumTab?
    private(set) var folder: String?
    /// The editor is on screen: keys pressed in it are its own (Cmd+P,
    /// Cmd+Shift+P, Cmd+B), not Companion's commands.
    var showing = false
    /// The password the editor asks for once per launch (filled in by
    /// Companion, never shown).
    private(set) var password = ""
    private var process: Process?

    /// code-server's launcher inside this build of Companion.
    static var launcher: URL? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/CodeServer/bin/code-server")
        return FileManager.default.isExecutableFile(atPath: path.path) ? path : nil
    }

    /// VS Code can run: this build carries it, and Chromium to show it.
    static var isAvailable: Bool { launcher != nil && Chromium.isAvailable }

    /// Code mode shows VS Code: it can run, and it was not turned off.
    static var chosen: Bool {
        isAvailable && (UserDefaults.standard.object(forKey: editorKey) as? Bool ?? true)
    }

    private var home: URL { ContextStore.shared.baseDir.appendingPathComponent("vscode", isDirectory: true) }

    /// The address that opens a folder in the editor.
    func address(for folder: String) -> URL? {
        guard case .ready(let port) = state else { return nil }
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = "127.0.0.1"
        parts.port = port
        parts.path = "/"
        if !folder.isEmpty { parts.queryItems = [URLQueryItem(name: "folder", value: folder)] }
        return parts.url
    }

    /// Starts it, once; returns when it answers, or failed.
    func start() async {
        switch state {
        case .ready, .starting: return
        default: break
        }
        guard let launcher = Self.launcher else {
            state = .failed("This build has no VS Code. bash build.sh fetches it.")
            return
        }
        state = .starting
        guard let port = Self.freePort() else {
            state = .failed("No port was free for VS Code.")
            return
        }
        let fm = FileManager.default
        let data = home.appendingPathComponent("data"), extensions = home.appendingPathComponent("extensions")
        try? fm.createDirectory(at: data, withIntermediateDirectories: true)
        try? fm.createDirectory(at: extensions, withIntermediateDirectories: true)
        // Its own config file, so the person's own code-server settings
        // (if any) are not read or changed.
        let config = home.appendingPathComponent("config.yaml")
        try? "auth: password\n".write(to: config, atomically: true, encoding: .utf8)
        password = Self.secret()
        Self.writeDefaults(in: data)
        Self.installBridge(into: extensions)
        try? fm.createDirectory(at: bridgeDir.appendingPathComponent("inbox"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: bridgeDir.appendingPathComponent("outbox"), withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = launcher
        process.arguments = [
            "--bind-addr", "127.0.0.1:\(port)",
            "--auth", "password",
            "--config", config.path,
            "--user-data-dir", data.path,
            "--extensions-dir", extensions.path,
            "--disable-telemetry",
            "--disable-update-check",
            "--disable-getting-started-override",
            "--disable-workspace-trust",
            "--ignore-last-opened",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PASSWORD"] = password
        environment["COMPANION_BRIDGE_DIR"] = bridgeDir.path
        environment.removeValue(forKey: "HASHED_PASSWORD")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let log = home.appendingPathComponent("code-server.log")
        fm.createFile(atPath: log.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: log)
        process.standardOutput = handle ?? FileHandle.nullDevice
        process.standardError = handle ?? FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            Task { @MainActor in
                guard let self, self.process === ended else { return }
                self.process = nil
                self.state = .failed("VS Code stopped (exit \(status)). Its log is in \(log.path).")
            }
        }
        do {
            try process.run()
        } catch {
            state = .failed("VS Code could not start: \(error.localizedDescription)")
            return
        }
        self.process = process
        // Ready when its health check answers.
        let health = URL(string: "http://127.0.0.1:\(port)/healthz")!
        for _ in 0..<120 {
            if let (_, response) = try? await URLSession.shared.data(from: health),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                state = .ready(port: port)
                return
            }
            if self.process == nil { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        stop()
        state = .failed("VS Code did not start in time. Its log is in \(log.path).")
    }

    /// Shows a folder in the editor: the page is made once, then sent to
    /// the folder asked for.
    func open(_ folder: String) {
        guard let url = address(for: folder), folder != self.folder || page == nil else { return }
        self.folder = folder
        if let page {
            page.load(url)
        } else {
            page = ChromiumTab.standalone(url.absoluteString)
        }
        objectWillChange.send()
    }

    /// Stops it (Companion quitting, or the editor turned off).
    func stop() {
        page?.stopLoading()
        page = nil
        folder = nil
        guard let process else { return }
        self.process = nil
        if process.isRunning {
            kill(-process.processIdentifier, SIGTERM)
            process.terminate()
        }
        state = .stopped
    }

    /// The login page's script: the password typed in for the person.
    func signInScript() -> String {
        let data = (try? JSONSerialization.data(withJSONObject: password, options: [.fragmentsAllowed])) ?? Data("\"\"".utf8)
        return """
        (() => {
          const field = document.querySelector('input[name="password"], input[type="password"]');
          if (!field) return false;
          field.value = \(String(decoding: data, as: UTF8.self));
          const form = field.form || document.querySelector('form');
          if (form) { form.requestSubmit ? form.requestSubmit() : form.submit(); }
          return true;
        })()
        """
    }

    /// VS Code's settings for life inside Companion, set once: no chat of
    /// its own (Companion's is beside it), no welcome page, Companion's dark
    /// look. Only settings not already there are added, and only the first
    /// time; after that the file is the person's.
    // MARK: Companion's extension inside VS Code

    /// Where Companion and its extension in VS Code hand requests to each
    /// other, as whole JSON files (an inbox and an outbox).
    var bridgeDir: URL { home.appendingPathComponent("bridge", isDirectory: true) }

    static let bridgeID = "companion.companion-bridge"
    static let bridgeVersion = "0.1.0"

    /// Puts the extension from this build in VS Code's extensions folder and
    /// lists it there, so VS Code loads it like one installed from Open VSX.
    private static func installBridge(into extensions: URL) {
        let fm = FileManager.default
        guard let source = Bundle.main.resourceURL?
            .appendingPathComponent("VSCodeExtension/companion-bridge", isDirectory: true),
              fm.fileExists(atPath: source.path) else { return }
        let folder = "\(bridgeID)-\(bridgeVersion)"
        let target = extensions.appendingPathComponent(folder, isDirectory: true)
        try? fm.removeItem(at: target)
        try? fm.copyItem(at: source, to: target)
        // VS Code loads what extensions.json lists.
        let registry = extensions.appendingPathComponent("extensions.json")
        var entries = (try? JSONSerialization.jsonObject(with: Data(contentsOf: registry))) as? [[String: Any]] ?? []
        entries.removeAll { (($0["identifier"] as? [String: Any])?["id"] as? String)?.lowercased() == bridgeID }
        entries.append([
            "identifier": ["id": bridgeID],
            "version": bridgeVersion,
            "location": ["$mid": 1, "path": target.path, "scheme": "file"],
            "relativeLocation": folder,
        ])
        if let data = try? JSONSerialization.data(withJSONObject: entries) { try? data.write(to: registry) }
    }

    /// Hands a request to the extension and waits for its answer, or nil
    /// when VS Code is not running or did not answer in time.
    func bridge(_ request: [String: Any], timeout: TimeInterval = 8) async -> [String: Any]? {
        guard case .ready = state else { return nil }
        let id = UUID().uuidString
        var request = request
        request["id"] = id
        let inbox = bridgeDir.appendingPathComponent("inbox/\(id).json")
        let answer = bridgeDir.appendingPathComponent("outbox/\(id).json")
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        let temporary = inbox.appendingPathExtension("tmp")
        guard (try? data.write(to: temporary)) != nil,
              (try? FileManager.default.moveItem(at: temporary, to: inbox)) != nil else { return nil }
        let until = Date().addingTimeInterval(timeout)
        while Date() < until {
            if let reply = try? Data(contentsOf: answer) {
                try? FileManager.default.removeItem(at: answer)
                return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        // Not taken up: the request is withdrawn.
        try? FileManager.default.removeItem(at: inbox)
        return nil
    }

    private static func writeDefaults(in data: URL) {
        let user = data.appendingPathComponent("User", isDirectory: true)
        let file = user.appendingPathComponent("settings.json")
        // Bumped when the defaults grow, so a new one reaches an editor set
        // up before it; what the person set themselves is still kept.
        let marker = user.appendingPathComponent(".companion-defaults-2")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try? FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        var settings: [String: Any] = [:]
        if let existing = try? Data(contentsOf: file) {
            // A file with comments (VS Code allows them) is left as it is.
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                FileManager.default.createFile(atPath: marker.path, contents: nil)
                return
            }
            settings = parsed
        }
        let defaults: [String: Any] = [
            "chat.disableAIFeatures": true,
            "chat.commandCenter.enabled": false,
            "workbench.startupEditor": "none",
            "workbench.tips.enabled": false,
            "security.workspace.trust.enabled": false,
            "workbench.colorTheme": "Default Dark Modern",
            "window.commandCenter": false,
            "telemetry.telemetryLevel": "off",
            "update.mode": "none",
            "extensions.autoUpdate": true,
            // Inside Companion the editor is one pane of the panel: no
            // title bar of its own, no layout buttons, and no empty AI
            // side bar where the chat would be (Companion is the chat).
            "window.customTitleBarVisibility": "never",
            "workbench.layoutControl.enabled": false,
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "workbench.auxiliaryActivityBar.location": "hidden",
            "window.menuBarVisibility": "compact",
        ]
        settings.merge(defaults) { mine, _ in mine }
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        if let json = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: file)
        }
    }

    private static func secret() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// A port nothing listens on now, chosen by the system.
    private static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else { return nil }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
