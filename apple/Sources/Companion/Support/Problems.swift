import Foundation

/// One error or warning the build reported, at a place in a file.
struct Problem: Identifiable, Hashable {
    enum Severity: String {
        case error, warning, note
    }

    let file: String      // absolute path
    let line: Int         // 1-based
    let column: Int       // 1-based, 0 when not given
    let severity: Severity
    let message: String

    var id: String { "\(file):\(line):\(column):\(severity.rawValue):\(message)" }
}

/// The Problems list: the project's build is run, and the errors and
/// warnings it prints are read into places in files, the way an editor's
/// "problem matchers" do. Which build to run is worked out from the files
/// in the folder (Package.swift, Cargo.toml, go.mod, tsconfig.json...),
/// so it works for any language with a compiler that prints
/// `file:line:column: error: message`.
@MainActor
final class ProblemsModel: ObservableObject {
    static let shared = ProblemsModel()

    /// Everything there is to list: what the language servers say about
    /// the files they have open, and the last build's word on the rest.
    @Published private(set) var problems: [Problem] = []
    private var built: [Problem] = []
    private var live: [String: [Problem]] = [:]
    /// The folder the problems are for; another folder's are not shown.
    @Published private(set) var root = ""
    @Published private(set) var running = false
    /// The build run last, and how it ended, for the status bar.
    @Published private(set) var lastCommand = ""
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastOK = true
    /// Said when there is nothing to list: no build found, or the reason
    /// it could not run.
    @Published private(set) var note = ""

    private var task: Task<Void, Never>?

    var errors: Int { problems.filter { $0.severity == .error }.count }
    var warnings: Int { problems.filter { $0.severity == .warning }.count }

    /// The problems in one file, for marking its lines in the editor.
    func marks(in file: String) -> [Int: Problem.Severity] {
        var result: [Int: Problem.Severity] = [:]
        for problem in problems where problem.file == file && problem.severity != .note {
            // An error on a line outranks a warning on it.
            if result[problem.line] != .error { result[problem.line] = problem.severity }
        }
        return result
    }

    /// The build to run in a folder, or nil when none is recognised. A
    /// `.companion/build` file, if present, holds the command to use.
    static func buildCommand(in root: String) -> String? {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: (root as NSString).appendingPathComponent(name)) }
        let custom = (root as NSString).appendingPathComponent(".companion/build")
        if let text = try? String(contentsOfFile: custom, encoding: .utf8) {
            let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !command.isEmpty { return command }
        }
        if has("Package.swift") { return "swift build" }
        if has("Cargo.toml") { return "cargo build --message-format short" }
        if has("go.mod") { return "go vet ./..." }
        if has("tsconfig.json") { return "npx --no-install tsc --noEmit --pretty false" }
        if has("Makefile") { return "make" }
        return nil
    }

    /// Runs the build in the folder and reads what it reports.
    func run(in folder: String) {
        guard !folder.isEmpty else { return }
        guard let command = Self.buildCommand(in: folder) else {
            use(folder)
            built = []
            recount()
            note = "No build found here. Put the command to run in .companion/build to use one."
            return
        }
        task?.cancel()
        use(folder)
        running = true
        note = ""
        lastCommand = command
        task = Task { @MainActor in
            let result = await Shell.run(command, in: folder, timeout: 900)
            guard !Task.isCancelled else { return }
            OutputLog.shared.append("Build", command: command, ok: result.ok, "$ \(command)  (\(result.ok ? "ok" : "failed"))\n\(result.output)")
            built = Self.parse(result.output, root: folder)
            recount()
            lastOK = result.ok
            lastRun = Date()
            running = false
            if problems.isEmpty {
                note = result.ok
                    ? "No problems. \(command) finished cleanly."
                    : "\(command) failed without naming a place in a file:\n" + String(result.output.suffix(1_500))
            }
        }
    }

    func stop() {
        task?.cancel()
        running = false
    }

    /// What a language server says about one of its open files now. It
    /// stands in for the build's word on that file until the next build.
    func setLive(_ found: [Problem], for file: String, root folder: String) {
        use(folder)
        live[file] = found
        recount()
    }

    /// Another folder: the last one's problems are not this one's.
    private func use(_ folder: String) {
        guard folder != root else { return }
        root = folder
        built = []
        live = [:]
    }

    private func recount() {
        let merged = built.filter { live[$0.file] == nil } + live.values.flatMap { $0 }
        problems = merged.sorted {
            if $0.severity != $1.severity { return $0.severity == .error }
            if $0.file != $1.file { return $0.file < $1.file }
            return $0.line < $1.line
        }
    }

    // MARK: Reading the build's output

    /// `path:line:col: error: message` (Swift, clang, gcc, Go, Rust short).
    private static let colon = try! NSRegularExpression(
        pattern: #"^(.+?):(\d+):(?:(\d+):)?\s*(fatal error|error|warning|note)(?:\[[^\]]*\])?:\s*(.+)$"#,
        options: [.anchorsMatchLines])
    /// `path(line,col): error TS1234: message` (TypeScript, MSBuild).
    private static let paren = try! NSRegularExpression(
        pattern: #"^(.+?)\((\d+),(\d+)\):\s*(error|warning)\s*[A-Z]*\d*:\s*(.+)$"#,
        options: [.anchorsMatchLines])
    /// `file.go:line:col: message`: Go names no severity; all are errors.
    private static let goLine = try! NSRegularExpression(
        pattern: #"^(.+?\.go):(\d+):(?:(\d+):)?\s*()(.+)$"#,
        options: [.anchorsMatchLines])

    static func parse(_ output: String, root: String) -> [Problem] {
        var seen = Set<String>()
        // Places already named by a pattern with a severity, so the Go one
        // does not list them a second time.
        var places = Set<String>()
        var found: [Problem] = []
        let text = output as NSString
        let whole = NSRange(location: 0, length: text.length)
        for regex in [colon, paren, goLine] {
            for match in regex.matches(in: output, range: whole) {
                func group(_ i: Int) -> String {
                    let range = match.range(at: i)
                    return range.location == NSNotFound ? "" : text.substring(with: range)
                }
                var file = group(1).trimmingCharacters(in: .whitespaces)
                // Lines a build prints about itself ("error: ...") have no place.
                guard !file.isEmpty, !file.contains(" error"), let line = Int(group(2)) else { continue }
                if !file.hasPrefix("/") { file = (root as NSString).appendingPathComponent(file) }
                file = (file as NSString).standardizingPath
                guard FileManager.default.fileExists(atPath: file) else { continue }
                let kind = group(4).lowercased()
                let severity: Problem.Severity = kind.isEmpty || kind.contains("error")
                    ? .error : (kind == "warning" ? .warning : .note)
                let problem = Problem(file: file, line: line, column: Int(group(3)) ?? 0,
                                      severity: severity, message: group(5).trimmingCharacters(in: .whitespaces))
                let place = "\(file):\(line):\(problem.column)"
                if regex === goLine, places.contains(place) { continue }
                places.insert(place)
                // Compilers repeat themselves (once per target); keep each once.
                if seen.insert(problem.id).inserted { found.append(problem) }
            }
        }
        // Errors first, then by file and line, as an editor lists them.
        return found.sorted {
            if $0.severity != $1.severity { return $0.severity == .error }
            if $0.file != $1.file { return $0.file < $1.file }
            return $0.line < $1.line
        }
    }
}
