import Foundation

/// The debugger: breakpoints in the editor, then the program run under
/// lldb-dap (the Debug Adapter Protocol server that comes with Xcode, the
/// same protocol VS Code speaks), stopping at them to show the call stack
/// and the variables, and stepping from there.
///
/// What to run comes from `.companion/launch.json` ({"program": ...,
/// "args": [...], "cwd": ..., "build": ...}), else a "program" in
/// `.vscode/launch.json`, else the folder's own build: a Swift package's
/// executable or a Cargo crate's binary, built in debug first.
@MainActor
final class DebugModel: ObservableObject {
    static let shared = DebugModel()

    enum State: Equatable {
        case idle, building, starting, running
        case stopped(String)
        case ended(String)
    }

    struct Frame: Identifiable, Hashable {
        let id: Int
        let name: String
        let path: String?
        let line: Int
    }

    struct Variable: Identifiable, Hashable {
        let name: String
        let value: String
        let type: String
        /// Non-zero when it has members to open.
        let reference: Int
        var id: String { "\(name)#\(reference)#\(value)" }
    }

    @Published private(set) var state = State.idle
    /// Lines with a breakpoint, by file (lines from 1).
    @Published private(set) var breakpoints: [String: Set<Int>] = [:]
    @Published private(set) var frames: [Frame] = []
    @Published private(set) var selectedFrame: Int?
    /// The variables of the selected frame, by scope ("Locals"...).
    @Published private(set) var scopes: [(name: String, variables: [Variable])] = []
    /// Members of variables that were opened, by reference.
    @Published private(set) var members: [Int: [Variable]] = [:]
    /// Where it is stopped, to mark in the editor.
    @Published private(set) var location: (path: String, line: Int)?
    @Published private(set) var console = ""
    @Published private(set) var program = ""

    var active: Bool {
        switch state {
        case .building, .starting, .running, .stopped: return true
        default: return false
        }
    }

    var isStopped: Bool {
        if case .stopped = state { return true }
        return false
    }

    private var adapter: DebugAdapter?
    private var thread = 0
    private var root = ""
    private var buildTask: Task<Void, Never>?

    // MARK: Breakpoints

    func toggle(_ path: String, line: Int) {
        var lines = breakpoints[path] ?? []
        if lines.contains(line) { lines.remove(line) } else { lines.insert(line) }
        breakpoints[path] = lines.isEmpty ? nil : lines
        if let adapter, active { Task { await adapter.setBreakpoints(path, lines: lines) } }
    }

    func clearBreakpoints() {
        let files = Array(breakpoints.keys)
        breakpoints = [:]
        if let adapter, active {
            Task { for file in files { await adapter.setBreakpoints(file, lines: []) } }
        }
    }

    // MARK: What to run

    struct Launch {
        var program: String
        var args: [String] = []
        var cwd: String
        var build: String?
    }

    /// The program to debug in a folder, or why there is none.
    static func launch(in root: String) -> Result<Launch, LaunchProblem> {
        func path(_ name: String) -> String { (root as NSString).appendingPathComponent(name) }
        func absolute(_ value: String) -> String {
            let expanded = value.replacingOccurrences(of: "${workspaceFolder}", with: root)
            return expanded.hasPrefix("/") ? expanded : path(expanded)
        }
        func json(_ name: String) -> [String: Any]? {
            guard let text = try? String(contentsOfFile: path(name), encoding: .utf8) else { return nil }
            // launch.json allows comment lines.
            let cleaned = text.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            return (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any]
        }
        if let own = json(".companion/launch.json"), let program = own["program"] as? String {
            return .success(Launch(program: absolute(program), args: own["args"] as? [String] ?? [],
                                   cwd: absolute(own["cwd"] as? String ?? "."), build: own["build"] as? String))
        }
        if let code = json(".vscode/launch.json"),
           let config = (code["configurations"] as? [[String: Any]])?.first(where: { $0["program"] is String }),
           let program = config["program"] as? String {
            return .success(Launch(program: absolute(program), args: config["args"] as? [String] ?? [],
                                   cwd: absolute(config["cwd"] as? String ?? "."), build: nil))
        }
        if let manifest = try? String(contentsOfFile: path("Package.swift"), encoding: .utf8) {
            let pattern = #"(?:\.executable\(\s*name:\s*|\.executableTarget\(\s*name:\s*)"([^"]+)""#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: manifest, range: NSRange(manifest.startIndex..., in: manifest)),
                  let range = Range(match.range(at: 1), in: manifest) else {
                return .failure(.noProgram("This package has no executable to run."))
            }
            return .success(Launch(program: path(".build/debug/" + manifest[range]), cwd: root, build: "swift build"))
        }
        if let cargo = try? String(contentsOfFile: path("Cargo.toml"), encoding: .utf8) {
            let pattern = #"(?m)^\s*name\s*=\s*"([^"]+)""#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: cargo, range: NSRange(cargo.startIndex..., in: cargo)),
                  let range = Range(match.range(at: 1), in: cargo) else {
                return .failure(.noProgram("Could not find the crate's name in Cargo.toml."))
            }
            return .success(Launch(program: path("target/debug/" + cargo[range]), cwd: root, build: "cargo build"))
        }
        return .failure(.noProgram("Nothing to debug found here. Add .companion/launch.json with {\"program\": \"path/to/binary\", \"args\": [], \"build\": \"make\"}."))
    }

    enum LaunchProblem: Error {
        case noProgram(String)
    }

    // MARK: Running

    func start(in folder: String) {
        if isStopped { resume(); return }
        guard !active else { return }
        root = folder
        console = ""
        frames = []
        scopes = []
        members = [:]
        location = nil
        let launch: Launch
        switch Self.launch(in: folder) {
        case .success(let found): launch = found
        case .failure(.noProgram(let why)):
            state = .ended(why)
            return
        }
        program = (launch.program as NSString).lastPathComponent
        buildTask = Task { @MainActor in
            if let build = launch.build {
                state = .building
                write("$ \(build)\n")
                let built = await Shell.run(build, in: folder, timeout: 900)
                OutputLog.shared.append("Debug", command: build, ok: built.ok, "$ \(build)\n\(built.output)")
                guard !Task.isCancelled, state == .building else { return }
                guard built.ok else {
                    write(String(built.output.suffix(4000)))
                    state = .ended("The build failed. The Output tab has it, with Fix.")
                    return
                }
            }
            guard FileManager.default.isExecutableFile(atPath: launch.program) else {
                state = .ended("\(launch.program) is not there or cannot run.")
                return
            }
            state = .starting
            guard let command = await DebugAdapter.find(in: folder) else {
                state = .ended("lldb-dap was not found. It comes with Xcode 16 or later (xcrun --find lldb-dap).")
                return
            }
            let adapter = DebugAdapter(command: command, root: folder)
            adapter.onEvent = { [weak model = self] event, body in model?.handle(event, body) }
            self.adapter = adapter
            guard await adapter.start() else {
                self.adapter = nil
                state = .ended("lldb-dap could not be started.")
                return
            }
            let ok = await adapter.launch(program: launch.program, args: launch.args, cwd: launch.cwd,
                                          breakpoints: breakpoints)
            if ok, state == .starting { state = .running }
            if !ok {
                state = .ended("The program could not be launched under the debugger.")
                stopAdapter()
            }
        }
    }

    private func write(_ text: String) {
        console += text
        if console.count > 200_000 { console = String(console.suffix(200_000)) }
    }

    private func handle(_ event: String, _ body: [String: Any]) {
        switch event {
        case "stopped":
            thread = body["threadId"] as? Int ?? thread
            let reason = body["reason"] as? String ?? "paused"
            state = .stopped(reason == "breakpoint" ? "At a breakpoint" : "Paused (\(reason))")
            Task { await loadStack() }
        case "continued":
            state = .running
            location = nil
        case "output":
            if let text = body["output"] as? String, body["category"] as? String != "telemetry" { write(text) }
        case "exited":
            if let code = body["exitCode"] as? Int { write("\nExited with code \(code).\n") }
        case "terminated":
            finish("Ended")
        default:
            break
        }
    }

    private func loadStack() async {
        guard let adapter else { return }
        frames = await adapter.stackTrace(thread: thread)
        // The first frame with source code is where to look.
        let top = frames.first { $0.path != nil } ?? frames.first
        if let top { await select(top) }
    }

    /// Shows a frame: its line in the editor and its variables.
    func select(_ frame: Frame) async {
        guard let adapter else { return }
        selectedFrame = frame.id
        if let path = frame.path {
            location = (path, frame.line)
            let app = AppState.shared
            if app.workspace.openPath == path {
                app.workspace.reveal = WorkspaceModel.Reveal(line: frame.line)
            } else {
                if app.workspace.dirty { app.workspace.save(conversation: app.conversation.id) }
                app.workspace.open(path, line: frame.line)
            }
            app.workspace.showPanel(.debug)
        }
        members = [:]
        var found: [(name: String, variables: [Variable])] = []
        for scope in await adapter.scopes(frame: frame.id) where !scope.expensive {
            found.append((scope.name, await adapter.variables(scope.reference)))
        }
        scopes = found
    }

    /// Opens a variable's members.
    func expand(_ variable: Variable) {
        guard variable.reference > 0, let adapter, members[variable.reference] == nil else { return }
        Task { members[variable.reference] = await adapter.variables(variable.reference) }
    }

    func collapse(_ variable: Variable) {
        members[variable.reference] = nil
    }

    func resume() { step("continue") }
    func stepOver() { step("next") }
    func stepIn() { step("stepIn") }
    func stepOut() { step("stepOut") }

    private func step(_ command: String) {
        guard isStopped, let adapter else { return }
        state = .running
        location = nil
        Task { await adapter.request(command, ["threadId": thread]) }
    }

    func pause() {
        guard state == .running, let adapter else { return }
        Task { await adapter.request("pause", ["threadId": thread]) }
    }

    /// Evaluates an expression in the selected frame, for the console.
    func evaluate(_ expression: String) {
        guard let adapter, isStopped else {
            write("> \(expression)\nThe program has to be stopped to evaluate.\n")
            return
        }
        write("> \(expression)\n")
        Task {
            let result = await adapter.evaluate(expression, frame: selectedFrame)
            write(result + "\n")
        }
    }

    func stop() {
        buildTask?.cancel()
        if state == .building { state = .ended("Stopped"); return }
        guard let adapter else { finish("Stopped"); return }
        Task {
            await adapter.request("disconnect", ["terminateDebuggee": true], timeout: 5)
            finish("Stopped")
        }
    }

    func restart() {
        let folder = root
        stop()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            start(in: folder)
        }
    }

    private func finish(_ why: String) {
        stopAdapter()
        if active || state == .idle { state = .ended(why) }
        location = nil
        frames = []
        scopes = []
        members = [:]
    }

    private func stopAdapter() {
        adapter?.stop()
        adapter = nil
    }
}

/// One debug adapter process, spoken to in the Debug Adapter Protocol: JSON
/// messages over its standard input and output, each with a Content-Length
/// header, as the language servers are.
@MainActor
final class DebugAdapter {
    let command: [String]
    let root: String
    var onEvent: ((String, [String: Any]) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var seq = 1
    private var waiting: [Int: CheckedContinuation<[String: Any]?, Never>] = [:]
    private var initialized: CheckedContinuation<Void, Never>?
    private var isInitialized = false

    init(command: [String], root: String) {
        self.command = command
        self.root = root
    }

    /// lldb-dap from Xcode, or the older lldb-vscode.
    static func find(in folder: String) async -> [String]? {
        for probe in ["xcrun --find lldb-dap", "command -v lldb-dap", "xcrun --find lldb-vscode"] {
            let found = await Shell.run(probe + " 2>/dev/null", in: folder, timeout: 15)
            let path = found.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if found.ok, !path.isEmpty, !path.contains("\n") { return [path] }
        }
        return nil
    }

    func start() async -> Bool {
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.received(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.onEvent?("terminated", [:]) }
        }
        do { try process.run() } catch { return false }
        self.process = process
        input = stdin.fileHandleForWriting
        let answer = await request("initialize", [
            "clientID": "companion", "clientName": "Companion", "adapterID": "lldb-dap",
            "linesStartAt1": true, "columnsStartAt1": true, "pathFormat": "path",
            "supportsVariableType": true, "supportsRunInTerminalRequest": false
        ], timeout: 20)
        return answer?["success"] as? Bool == true
    }

    func stop() {
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
    }

    /// Launches the program, sets the breakpoints once the adapter is ready
    /// for them, and lets it run.
    func launch(program: String, args: [String], cwd: String, breakpoints: [String: Set<Int>]) async -> Bool {
        // The launch is answered only after configuration is done, so it is
        // sent and waited for alongside.
        async let launched = request("launch", ["program": program, "args": args, "cwd": cwd,
                                                "stopOnEntry": false], timeout: 60)
        if !isInitialized {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                initialized = done
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    self.initialized?.resume()
                    self.initialized = nil
                }
            }
        }
        for (file, lines) in breakpoints { await setBreakpoints(file, lines: lines) }
        _ = await request("configurationDone", [:], timeout: 15)
        return (await launched)?["success"] as? Bool == true
    }

    func setBreakpoints(_ path: String, lines: Set<Int>) async {
        _ = await request("setBreakpoints", [
            "source": ["path": path, "name": (path as NSString).lastPathComponent],
            "breakpoints": lines.sorted().map { ["line": $0] }
        ], timeout: 10)
    }

    func stackTrace(thread: Int) async -> [DebugModel.Frame] {
        let answer = await request("stackTrace", ["threadId": thread, "startFrame": 0, "levels": 40], timeout: 10)
        let list = (answer?["body"] as? [String: Any])?["stackFrames"] as? [[String: Any]] ?? []
        return list.compactMap { frame in
            guard let id = frame["id"] as? Int else { return nil }
            let path = (frame["source"] as? [String: Any])?["path"] as? String
            return DebugModel.Frame(id: id, name: frame["name"] as? String ?? "?",
                                    path: path.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil },
                                    line: frame["line"] as? Int ?? 0)
        }
    }

    func scopes(frame: Int) async -> [(name: String, reference: Int, expensive: Bool)] {
        let answer = await request("scopes", ["frameId": frame], timeout: 10)
        let list = (answer?["body"] as? [String: Any])?["scopes"] as? [[String: Any]] ?? []
        return list.compactMap { scope in
            guard let reference = scope["variablesReference"] as? Int else { return nil }
            return (scope["name"] as? String ?? "Scope", reference, scope["expensive"] as? Bool ?? false)
        }
    }

    func variables(_ reference: Int) async -> [DebugModel.Variable] {
        let answer = await request("variables", ["variablesReference": reference], timeout: 10)
        let list = (answer?["body"] as? [String: Any])?["variables"] as? [[String: Any]] ?? []
        return list.prefix(500).map { item in
            DebugModel.Variable(name: item["name"] as? String ?? "?", value: item["value"] as? String ?? "",
                                type: item["type"] as? String ?? "", reference: item["variablesReference"] as? Int ?? 0)
        }
    }

    func evaluate(_ expression: String, frame: Int?) async -> String {
        var arguments: [String: Any] = ["expression": expression, "context": "repl"]
        if let frame { arguments["frameId"] = frame }
        let answer = await request("evaluate", arguments, timeout: 20)
        if answer?["success"] as? Bool == true {
            return (answer?["body"] as? [String: Any])?["result"] as? String ?? ""
        }
        return answer?["message"] as? String ?? "Could not evaluate that."
    }

    // MARK: Messages

    @discardableResult
    func request(_ command: String, _ arguments: [String: Any], timeout: Double = 10) async -> [String: Any]? {
        let id = seq
        seq += 1
        return await withCheckedContinuation { (done: CheckedContinuation<[String: Any]?, Never>) in
            waiting[id] = done
            send(["seq": id, "type": "request", "command": command, "arguments": arguments])
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let late = self.waiting.removeValue(forKey: id) { late.resume(returning: nil) }
            }
        }
    }

    private func send(_ message: [String: Any]) {
        guard let input, let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        do { try input.write(contentsOf: data) } catch { stop() }
    }

    private func received(_ data: Data) {
        buffer.append(data)
        let separator = Data("\r\n\r\n".utf8)
        while let headerEnd = buffer.range(of: separator) {
            let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            var length = 0
            for line in header.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
            let start = headerEnd.upperBound
            guard buffer.distance(from: start, to: buffer.endIndex) >= length else { return }
            let end = buffer.index(start, offsetBy: length)
            let body = buffer[start..<end]
            buffer = Data(buffer[end...])
            if let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] { handle(message) }
        }
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "response":
            if let id = message["request_seq"] as? Int { waiting.removeValue(forKey: id)?.resume(returning: message) }
        case "event":
            let event = message["event"] as? String ?? ""
            if event == "initialized" {
                isInitialized = true
                initialized?.resume()
                initialized = nil
                return
            }
            onEvent?(event, message["body"] as? [String: Any] ?? [:])
        case "request":
            // Requests from the adapter (running in a terminal): declined.
            if let id = message["seq"] as? Int {
                send(["seq": seq, "type": "response", "request_seq": id, "success": false,
                      "command": message["command"] ?? "", "message": "Not supported"])
                seq += 1
            }
        default:
            break
        }
    }
}
