import AppKit
import Combine
import SwiftUI

// MARK: - Tasks

/// Something the project knows how to do: a script, a make target, a build
/// or test command. Run in a terminal of its own, so a server keeps going
/// and Ctrl+C stops it.
struct ProjectTask: Identifiable, Hashable {
    let name: String
    let command: String
    /// Where it came from: "npm", "make", "swift", "tasks.json"...
    let source: String
    var id: String { source + ":" + name }
}

enum TaskCatalog {
    /// The folder's tasks, read from its files. `.companion/tasks.json`
    /// ({"name": "command"}) comes first, for tasks of your own.
    static func find(in root: String) -> [ProjectTask] {
        guard !root.isEmpty else { return [] }
        let fm = FileManager.default
        func path(_ name: String) -> String { (root as NSString).appendingPathComponent(name) }
        func has(_ name: String) -> Bool { fm.fileExists(atPath: path(name)) }
        func read(_ name: String) -> String? { try? String(contentsOfFile: path(name), encoding: .utf8) }
        var tasks: [ProjectTask] = []

        if let data = fm.contents(atPath: path(".companion/tasks.json")),
           let own = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            for (name, command) in own.sorted(by: { $0.key < $1.key }) {
                tasks.append(ProjectTask(name: name, command: command, source: "Companion"))
            }
        }

        // VS Code's own tasks, when the folder has them. Comment lines are
        // dropped first, since the file allows them.
        if let text = read(".vscode/tasks.json") {
            let cleaned = text.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if let data = cleaned.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = object["tasks"] as? [[String: Any]] {
                for item in list {
                    guard let label = item["label"] as? String, let command = item["command"] as? String else { continue }
                    let args = (item["args"] as? [Any])?.compactMap { $0 as? String }.map(Shell.quote) ?? []
                    tasks.append(ProjectTask(name: label, command: ([command] + args).joined(separator: " "), source: "tasks.json"))
                }
            }
        }

        if let data = fm.contents(atPath: path("package.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = object["scripts"] as? [String: Any] {
            let runner = has("pnpm-lock.yaml") ? "pnpm" : (has("yarn.lock") ? "yarn" : (has("bun.lockb") ? "bun run" : "npm run"))
            for name in scripts.keys.sorted() {
                tasks.append(ProjectTask(name: name, command: "\(runner) \(name)", source: runner.components(separatedBy: " ")[0]))
            }
        }

        if let text = read("Makefile") ?? read("makefile") {
            var seen = Set<String>()
            for line in text.components(separatedBy: "\n") {
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("\t"), !line.hasPrefix(" "),
                      !line.hasPrefix("."), !line.contains("="), !line.hasPrefix("#") else { continue }
                // Only plain target names; "%.o" rules and variables are not tasks.
                let names = line[..<colon].split(separator: " ").map(String.init)
                for name in names where name.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) {
                    if seen.insert(name).inserted { tasks.append(ProjectTask(name: name, command: "make \(name)", source: "make")) }
                }
            }
        }

        if has("Package.swift") {
            for (name, command) in [("build", "swift build"), ("run", "swift run"), ("test", "swift test"),
                                    ("build release", "swift build -c release")] {
                tasks.append(ProjectTask(name: name, command: command, source: "swift"))
            }
            if has("build.sh") { tasks.append(ProjectTask(name: "build.sh", command: "bash build.sh", source: "script")) }
        }
        if has("Cargo.toml") {
            for (name, command) in [("build", "cargo build"), ("run", "cargo run"), ("test", "cargo test"), ("clippy", "cargo clippy")] {
                tasks.append(ProjectTask(name: name, command: command, source: "cargo"))
            }
        }
        if has("go.mod") {
            for (name, command) in [("build", "go build ./..."), ("run", "go run ."), ("test", "go test ./..."), ("vet", "go vet ./...")] {
                tasks.append(ProjectTask(name: name, command: command, source: "go"))
            }
        }
        if has("pyproject.toml") || has("pytest.ini") || has("setup.py") {
            tasks.append(ProjectTask(name: "test", command: "python3 -m pytest", source: "python"))
        }
        if !has("Package.swift"), has("build.sh") {
            tasks.append(ProjectTask(name: "build.sh", command: "bash build.sh", source: "script"))
        }
        return tasks
    }
}

/// The Run Task menu: the folder's tasks by where they come from; each
/// runs in a new terminal.
struct RunTaskMenu: View {
    @ObservedObject var model: WorkspaceModel
    @State private var tasks: [ProjectTask] = []

    var body: some View {
        Menu {
            if tasks.isEmpty {
                Text("No tasks found. Add .companion/tasks.json as {\"name\": \"command\"}.")
            }
            ForEach(Array(Set(tasks.map(\.source))).sorted(), id: \.self) { source in
                Section(source) {
                    ForEach(tasks.filter { $0.source == source }) { task in
                        Button {
                            model.run(task)
                        } label: {
                            Text("\(task.name)    \(task.command)")
                        }
                    }
                }
            }
            if let last = model.lastTask {
                Divider()
                Button("Run Again: \(last.name)") { model.run(last) }
            }
        } label: {
            Label("Run Task", systemImage: "play")
                .font(.system(size: 11, weight: .medium))
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Run one of the project's tasks in a new terminal")
        .onAppear { tasks = TaskCatalog.find(in: model.root) }
        .onChange(of: model.root) { _, root in tasks = TaskCatalog.find(in: root) }
        // The list is read again each time the menu is about to open.
        .simultaneousGesture(TapGesture().onEnded { tasks = TaskCatalog.find(in: model.root) })
    }
}

// MARK: - Tests

/// One test and how it went.
struct TestResult: Identifiable, Hashable {
    enum Status { case passed, failed, skipped }
    let name: String
    /// The class, file or package it belongs to.
    let suite: String
    let status: Status
    var id: String { suite + "::" + name }
}

/// The Tests tab: the project's tests run and listed one by one, as an
/// editor's test explorer, from what the test runner prints. Swift (XCTest
/// and Swift Testing), pytest, go test and cargo test are read test by test;
/// any other runner shows how it ended.
@MainActor
final class TestModel: ObservableObject {
    static let shared = TestModel()

    @Published private(set) var results: [TestResult] = []
    @Published private(set) var running = false
    @Published private(set) var root = ""
    @Published private(set) var lastCommand = ""
    @Published private(set) var lastOK = true
    @Published private(set) var lastRun: Date?
    @Published private(set) var output = ""
    @Published private(set) var note = ""
    private var task: Task<Void, Never>?

    var failed: [TestResult] { results.filter { $0.status == .failed } }

    enum Kind { case swift, pytest, go, cargo, npm, other }

    static func kind(in root: String) -> Kind? {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: (root as NSString).appendingPathComponent(name)) }
        if has("Package.swift") { return .swift }
        if has("Cargo.toml") { return .cargo }
        if has("go.mod") { return .go }
        if has("pytest.ini") || has("pyproject.toml") || has("setup.py") || has("tests") { return .pytest }
        if has("package.json") { return .npm }
        return nil
    }

    /// The command that runs every test, or one test when a name is given.
    static func command(_ kind: Kind, only test: TestResult? = nil) -> String {
        switch kind {
        case .swift:
            guard let test else { return "swift test" }
            return "swift test --filter " + Shell.quote(test.suite.isEmpty ? test.name : "\(test.suite)/\(test.name)")
        case .pytest:
            guard let test else { return "python3 -m pytest -rA -q" }
            return "python3 -m pytest -rA -q " + Shell.quote(test.suite + "::" + test.name)
        case .go:
            guard let test else { return "go test -v ./..." }
            return "go test -v -run " + Shell.quote("^\(test.name)$") + " ./..."
        case .cargo:
            guard let test else { return "cargo test" }
            return "cargo test " + Shell.quote(test.name)
        case .npm, .other:
            return "npm test --silent"
        }
    }

    func run(in folder: String, only test: TestResult? = nil) {
        guard !folder.isEmpty else { return }
        guard let kind = Self.kind(in: folder) else {
            root = folder
            results = []
            note = "No tests found to run here (Swift, pytest, Go, Rust or npm)."
            return
        }
        task?.cancel()
        if root != folder { results = [] }
        root = folder
        running = true
        note = ""
        let command = Self.command(kind, only: test)
        lastCommand = command
        task = Task { @MainActor in
            let result = await Shell.run(command, in: folder, timeout: 1200)
            guard !Task.isCancelled else { return }
            OutputLog.shared.append("Tests", command: command, ok: result.ok, "$ \(command)  (\(result.ok ? "ok" : "failed"))\n\(result.output)")
            let found = Self.parse(result.output, kind: kind)
            if test != nil {
                // One test again: it replaces its own row.
                for item in found {
                    if let index = results.firstIndex(where: { $0.id == item.id }) { results[index] = item } else { results.append(item) }
                }
            } else {
                results = found
            }
            output = result.output
            lastOK = result.ok
            lastRun = Date()
            running = false
            if found.isEmpty {
                note = result.ok ? "\(command) passed." : "\(command) failed. The Output tab has what it printed."
            }
        }
    }

    func stop() {
        task?.cancel()
        running = false
    }

    // MARK: Reading the runner's output

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }
    /// Test Case '-[Module.Class testName]' passed (0.001 seconds).
    private static let xctest = regex(#"^Test Case '-\[(?:[\w.]+\.)?(\w+) (\w+)\]' (passed|failed|skipped)"#)
    /// ✔ Test name() passed / ✘ Test name() failed (Swift Testing).
    private static let swiftTesting = regex(#"^\S+\s+Test (\S+?)\(\) (passed|failed|skipped)"#)
    /// PASSED tests/test_x.py::test_name (pytest -rA).
    private static let pytest = regex(#"^(PASSED|FAILED|SKIPPED|ERROR) ([^\s:]+)::(\S+)"#)
    /// --- PASS: TestName (0.00s)
    private static let goTest = regex(#"^\s*--- (PASS|FAIL|SKIP): (\S+)"#)
    /// test module::name ... ok
    private static let cargoTest = regex(#"^test (\S+) \.\.\. (ok|FAILED|ignored)"#)

    static func parse(_ output: String, kind: Kind) -> [TestResult] {
        let text = output as NSString
        let whole = NSRange(location: 0, length: text.length)
        var found: [TestResult] = []
        var seen = Set<String>()
        func add(_ name: String, _ suite: String, _ word: String) {
            let lower = word.lowercased()
            let status: TestResult.Status = lower.hasPrefix("pass") || lower == "ok"
                ? .passed : (lower.hasPrefix("skip") || lower == "ignored" ? .skipped : .failed)
            let result = TestResult(name: name, suite: suite, status: status)
            if seen.insert(result.id).inserted { found.append(result) }
        }
        func each(_ regex: NSRegularExpression, _ body: ([String]) -> Void) {
            for match in regex.matches(in: output, range: whole) {
                body((0..<match.numberOfRanges).map {
                    let range = match.range(at: $0)
                    return range.location == NSNotFound ? "" : text.substring(with: range)
                })
            }
        }
        switch kind {
        case .swift:
            each(xctest) { add($0[2], $0[1], $0[3]) }
            each(swiftTesting) { add($0[1], "", $0[2]) }
        case .pytest:
            each(pytest) { add($0[3], $0[2], $0[1]) }
        case .go:
            each(goTest) { add($0[2], "", $0[1]) }
        case .cargo:
            each(cargoTest) { add($0[1], "", $0[2]) }
        case .npm, .other:
            break
        }
        // Failures first, then by suite and name.
        return found.sorted {
            if ($0.status == .failed) != ($1.status == .failed) { return $0.status == .failed }
            return $0.suite == $1.suite ? $0.name < $1.name : $0.suite < $1.suite
        }
    }
}

struct TestsTab: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: WorkspaceModel
    @ObservedObject private var tests = TestModel.shared

    private var mine: [TestResult] { tests.root == model.root ? tests.results : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if tests.running {
                    LoadingMark(state: .working, size: 14)
                    Text("Running \(tests.lastCommand)")
                        .lineLimit(1)
                } else {
                    Text(summary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if !tests.running, tests.root == model.root, !tests.failed.isEmpty {
                    Button {
                        let names = tests.failed.prefix(12).map { $0.suite.isEmpty ? $0.name : "\($0.suite)::\($0.name)" }
                        app.fixCommand(tests.lastCommand,
                                       output: "Failing: " + names.joined(separator: ", ") + "\n" + tests.output)
                    } label: {
                        Label("Fix", systemImage: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Have the agent find why these tests fail and fix them")
                }
                if tests.running {
                    IconButton("stop.fill", help: "Stop the tests", tint: Theme.rose) { tests.stop() }
                } else {
                    IconButton("play.fill", help: "Run every test", tint: Theme.accent) { tests.run(in: model.root) }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.ink.opacity(0.6))
            .padding(.horizontal, 10)
            .frame(height: 28)
            Rectangle().fill(Theme.ink.opacity(0.07)).frame(height: 1)
            if mine.isEmpty {
                workspaceNote(tests.root == model.root && !tests.note.isEmpty
                              ? tests.note
                              : "Run the tests to list them here, each with how it went. Companion uses swift test, pytest, go test, cargo test or npm test, from the folder.")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(mine) { test in
                            TestRow(test: test) { tests.run(in: model.root, only: test) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var summary: String {
        guard tests.root == model.root, let date = tests.lastRun else { return "Not run yet" }
        let time = date.formatted(date: .omitted, time: .shortened)
        let passed = mine.filter { $0.status == .passed }.count
        let failed = mine.filter { $0.status == .failed }.count
        if mine.isEmpty { return (tests.lastOK ? "Passed" : "Failed") + " · \(time)" }
        return "\(passed) passed, \(failed) failed · \(time)"
    }
}

private struct TestRow: View {
    let test: TestResult
    let again: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: test.status == .passed ? "checkmark.circle.fill"
                  : (test.status == .failed ? "xmark.circle.fill" : "minus.circle"))
                .font(.system(size: 10.5))
                .foregroundStyle(test.status == .passed ? Theme.mint
                                 : (test.status == .failed ? Theme.rose : Theme.ink.opacity(0.45)))
            Text(test.name)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink.opacity(0.9))
                .lineLimit(1)
            if !test.suite.isEmpty {
                Text(test.suite)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if hover {
                IconButton("play", help: "Run this test again", action: again)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(hover ? Theme.ink.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: - Ports

/// A program listening for connections on this Mac.
struct ListeningPort: Identifiable, Hashable {
    let port: Int
    let pid: Int32
    let program: String
    /// "*" for every address, else the one it listens on.
    let address: String
    var id: String { "\(pid):\(port)" }
}

/// The Ports tab: what is listening on this Mac's TCP ports (dev servers,
/// databases), read with lsof, each with Open and Stop.
@MainActor
final class PortsModel: ObservableObject {
    static let shared = PortsModel()

    @Published private(set) var ports: [ListeningPort] = []
    @Published private(set) var loading = false
    @Published var note = ""

    func refresh() {
        guard !loading else { return }
        loading = true
        Task { @MainActor in
            let result = await Shell.run("lsof -nP -iTCP -sTCP:LISTEN -FpcnT", in: NSHomeDirectory(), timeout: 15)
            ports = Self.parse(result.output)
            loading = false
        }
    }

    /// lsof's field output: p<pid>, c<command>, then n<address:port> per socket.
    static func parse(_ output: String) -> [ListeningPort] {
        var found: [ListeningPort] = []
        var seen = Set<String>()
        var pid: Int32 = 0
        var program = ""
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": program = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let address = String(value[..<colon])
                let item = ListeningPort(port: port, pid: pid, program: program, address: address)
                // The same port on IPv4 and IPv6 is one row.
                if seen.insert("\(pid):\(port)").inserted { found.append(item) }
            default: break
            }
        }
        return found.sorted { $0.port < $1.port }
    }

    /// Asks the program to stop (SIGTERM), then looks again.
    func stop(_ item: ListeningPort) {
        if kill(item.pid, SIGTERM) != 0 {
            note = "Could not stop \(item.program) (\(item.pid)): it may belong to another user."
        } else {
            note = "Asked \(item.program) on port \(item.port) to stop."
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            refresh()
        }
    }
}

struct PortsTab: View {
    @ObservedObject private var ports = PortsModel.shared
    @State private var stopping: ListeningPort?
    private let timer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(ports.ports.isEmpty ? "Nothing is listening" : "\(ports.ports.count) listening")
                if ports.loading { LoadingMark(state: .working, size: 12) }
                Spacer(minLength: 4)
                IconButton("arrow.clockwise", help: "Look again") { ports.refresh() }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.ink.opacity(0.6))
            .padding(.horizontal, 10)
            .frame(height: 28)
            Rectangle().fill(Theme.ink.opacity(0.07)).frame(height: 1)
            if !ports.note.isEmpty {
                workspaceNote(ports.note)
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(ports.ports) { item in
                        PortRow(item: item, stop: { stopping = item })
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear { ports.refresh() }
        .onReceive(timer) { _ in ports.refresh() }
        .confirmationDialog(stopping.map { "Stop \($0.program) on port \($0.port)?" } ?? "",
                            isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
                            titleVisibility: .visible) {
            Button("Stop", role: .destructive) {
                if let item = stopping { ports.stop(item) }
                stopping = nil
            }
            Button("Cancel", role: .cancel) { stopping = nil }
        } message: {
            Text("The program is asked to quit, as Ctrl+C would.")
        }
    }
}

private struct PortRow: View {
    let item: ListeningPort
    let stop: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Text(":\(item.port)")
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 52, alignment: .leading)
            Text(item.program)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink.opacity(0.9))
                .lineLimit(1)
            Text(item.address == "*" ? "all addresses · \(item.pid)" : "\(item.address) · \(item.pid)")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink.opacity(0.45))
                .lineLimit(1)
            Spacer(minLength: 4)
            if hover {
                IconButton("safari", help: "Open http://localhost:\(item.port)") {
                    if let url = URL(string: "http://localhost:\(item.port)") { NSWorkspace.shared.open(url) }
                }
                IconButton("doc.on.doc", help: "Copy the address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("http://localhost:\(item.port)", forType: .string)
                }
                IconButton("stop.circle", help: "Stop this program", tint: Theme.rose, action: stop)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(hover ? Theme.ink.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}
