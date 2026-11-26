import CompanionBoard
import Darwin
import Foundation

/// Runs a project's own checks (`Checks`, `.companion/checks.json` in its
/// folder) on a task's work: in the task's own copy, once a run of it has
/// finished, before the work is reviewed. The checks that cover what the
/// task changed run one after another, and what each found is kept with
/// the run (`Board.recordChecks`), for the review, the next run and the
/// person.
///
/// The file is read from the project's folder, the person's own checkout,
/// never from the copy, so a task cannot change how its work is checked.
/// Checks go one at a time across the Mac, whichever task they are for:
/// each builds, and two builds at once only make both slower.
@MainActor
final class TaskChecks {
    static let shared = TaskChecks()

    /// The check asked for last: each waits for the one before it.
    private var queue: Task<Void, Never>?

    private init() {}

    /// The checks set up in a project's folder: nil when it has none; why
    /// not, when its checks file cannot be read.
    nonisolated static func setUp(in folder: String) -> Result<[Check], Checks.Unreadable>? {
        let path = (folder as NSString).appendingPathComponent(Checks.file)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let data = FileManager.default.contents(atPath: path) else {
            return .failure(Checks.Unreadable(reason: "it could not be opened"))
        }
        do {
            return .success(try Checks.read(data))
        } catch let unreadable as Checks.Unreadable {
            return .failure(unreadable)
        } catch {
            return .failure(Checks.Unreadable(reason: error.localizedDescription))
        }
    }

    /// Runs the project's checks that cover what a task's copy changed,
    /// and says what they found. nil when the project has no checks set up.
    func run(on copy: WorkingCopy, project folder: String) async -> [CheckResult]? {
        guard let found = Self.setUp(in: folder) else { return nil }
        let checks: [Check]
        switch found {
        case .success(let list):
            checks = list
        case .failure(let unreadable):
            // A checks file read wrong holds work back as a failing check
            // does: the person sees why, and nothing goes through unchecked.
            return [CheckResult(name: Checks.file, command: "", outcome: .notRun,
                                output: "The checks file could not be read: \(unreadable.reason).")]
        }
        guard let changes = await TaskCopies.shared.changes(of: copy) else {
            return [CheckResult(name: "Checks", command: "", outcome: .notRun,
                                output: "What the task changed could not be read from its copy, \(copy.folder).")]
        }
        let due = Checks.due(checks, changed: changes.files.map { copy.fromProject($0.path) })
        var results: [CheckResult] = []
        for check in due {
            results.append(await inTurn(check, in: copy.directory))
        }
        return results
    }

    /// Runs the project's checks that cover these changed files in the
    /// project's own folder, before they are committed there. nil when
    /// the project has no checks that can be read.
    func run(inFolder folder: String, changed: [String]) async -> [CheckResult]? {
        guard case .success(let checks)? = Self.setUp(in: folder) else { return nil }
        var results: [CheckResult] = []
        for check in Checks.due(checks, changed: changed) {
            results.append(await inTurn(check, in: folder))
        }
        return results
    }

    /// Runs a check once the checks asked for before it are done.
    private func inTurn(_ check: Check, in directory: String) async -> CheckResult {
        let before = queue
        let job = Task { @MainActor () -> CheckResult in
            await before?.value
            let ran = await CheckProcess.run(check.run, in: directory, timeout: check.timeout)
            return Self.result(of: check, ran, in: directory)
        }
        queue = Task { @MainActor in _ = await job.value }
        return await job.value
    }

    /// What a check's run comes to, with the errors it named at places in
    /// files read the way the Problems list reads a build.
    private static func result(of check: Check, _ ran: CheckProcess.Ran, in directory: String) -> CheckResult {
        let outcome: CheckResult.Outcome
        if ran.failure != nil {
            outcome = .notRun
        } else if ran.timedOut {
            outcome = .timedOut
        } else {
            outcome = ran.code == 0 ? .passed : .failed
        }
        var problems: [String] = []
        if outcome == .failed || outcome == .timedOut {
            let root = directory.hasSuffix("/") ? directory : directory + "/"
            problems = ProblemsModel.parse(ran.output, root: directory)
                .filter { $0.severity == .error }
                .prefix(Checks.problemLimit)
                .map { problem in
                    let path = problem.file.hasPrefix(root) ? String(problem.file.dropFirst(root.count)) : problem.file
                    let place = problem.column > 0 ? "\(path):\(problem.line):\(problem.column)" : "\(path):\(problem.line)"
                    return "\(place): error: \(problem.message)"
                }
        }
        return CheckResult(name: check.name, command: check.run, outcome: outcome,
                           exitCode: outcome == .failed || outcome == .passed ? ran.code : nil,
                           seconds: ran.seconds, output: ran.output, problems: problems)
    }
}

/// One check's command, run the way the agent's own commands are
/// (`AgentProcess`), since it runs the code the task wrote: not counted as
/// Companion by macOS, so with none of Companion's privacy permissions;
/// with Companion's environment cut down to what a shell expects, so with
/// no provider key; in the person's login shell, so their tools are found;
/// with no input, so nothing waits for an answer; and in a process group
/// of its own, so its time limit stops whatever it started.
enum CheckProcess {
    /// How much of a check's output is kept: its end, where a failure says why.
    static let kept = 12_000
    /// How long a check that ran out of time has to stop before it is killed.
    static let grace: TimeInterval = 10

    struct Ran: Sendable {
        var output: String
        var code: Int32
        var timedOut: Bool
        /// Why it could not be started; nil when it was.
        var failure: String?
        var seconds: Double
    }

    static func run(_ command: String, in directory: String, timeout: TimeInterval) async -> Ran {
        let started = Date()
        let process = AgentProcess()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = AgentProcess.plainEnvironment()
        // What tools take to mean that nobody is watching: no prompts, no
        // colours, no watch mode.
        environment["CI"] = "1"
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = nil

        let tail = OutputTail(limit: CheckProcess.kept)
        let reading = pipe.fileHandleForReading
        reading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                tail.append(chunk)
            }
        }
        // The time limit: asked to stop, then stopped.
        let limit = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, process.isRunning else { return }
            tail.expire()
            process.terminate()
            try? await Task.sleep(nanoseconds: UInt64(CheckProcess.grace * 1_000_000_000))
            let group = process.processIdentifier
            if process.isRunning, group > 0 { kill(-group, SIGKILL) }
        }
        let failure = await withCheckedContinuation { (finished: CheckedContinuation<String?, Never>) in
            process.terminationHandler = { _ in finished.resume(returning: nil) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                finished.resume(returning: error.localizedDescription)
            }
        }
        limit.cancel()
        // A moment for the last of the output to arrive, then stop listening.
        try? await Task.sleep(nanoseconds: 150_000_000)
        reading.readabilityHandler = nil
        return Ran(output: failure.map { "Could not start the command: \($0)" } ?? tail.text,
                   code: failure == nil ? process.terminationStatus : -1,
                   timedOut: tail.expired, failure: failure,
                   seconds: Date().timeIntervalSince(started))
    }

    /// Output as a reader wants it: without the codes that colour a
    /// terminal, and where a tool redrew a line (a progress bar), only what
    /// the line ended as.
    static func clean(_ text: String) -> String {
        let plain = text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        return plain.components(separatedBy: "\n").map { line -> String in
            let ended = line.hasSuffix("\r") ? String(line.dropLast()) : line
            return ended.components(separatedBy: "\r").last ?? ""
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The end of a command's output, kept as it arrives on the reading thread.
private final class OutputTail: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var dropped = false
    private var stopped = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > limit * 2 {
                data = Data(data.suffix(limit))
                dropped = true
            }
        }
    }

    /// It ran out of time.
    func expire() { lock.withLock { stopped = true } }
    var expired: Bool { lock.withLock { stopped } }

    var text: String {
        lock.withLock {
            let cut = dropped || data.count > limit
            let end = data.count > limit ? Data(data.suffix(limit)) : data
            let words = CheckProcess.clean(String(decoding: end, as: UTF8.self))
            return cut ? "[earlier output left out]\n" + words : words
        }
    }
}
