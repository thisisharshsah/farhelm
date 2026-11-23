import Foundation

/// A command the board runs on a task's work before the work is reviewed:
/// a build, the tests, a linter. A project's checks are the person's,
/// written in its folder as `.companion/checks.json` (`Checks.file`), next
/// to the `.companion/build` and `.companion/tasks.json` the app reads:
///
/// ```json
/// {
///   "checks": [
///     { "name": "Tests", "run": "swift test", "when": ["Sources", "Tests", "Package.swift"] },
///     { "name": "App builds", "run": "bash build.sh check", "timeout": 1800 }
///   ]
/// }
/// ```
///
/// `run` is a command for the person's login shell, run in the project's
/// folder inside the task's own copy. `when` keeps a check to work that
/// changed something under one of its paths, written from the project's
/// folder the way a task's paths are (`Leases`): a folder covers what is
/// in it, and a check without `when` covers all work. `timeout` is in
/// seconds. `name` is what the board calls it; the command, when left out.
public struct Check: Codable, Equatable, Sendable {
    public var name: String
    public var run: String
    public var when: [String]
    public var timeout: TimeInterval

    /// How long a check may run when its entry does not say.
    public static let defaultTimeout: TimeInterval = 900
    /// The shortest and the longest time a check is given, whatever its
    /// entry says.
    public static let timeouts: ClosedRange<TimeInterval> = 10...7_200
    /// The most of a command a check's name takes, when it has no name.
    public static let nameLength = 60

    public init(name: String = "", run: String, when: [String] = [], timeout: TimeInterval? = nil) {
        let command = run.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = named.isEmpty ? String(command.prefix(Self.nameLength)) : named
        self.run = command
        self.when = Leases.list(when)
        self.timeout = min(max(timeout ?? Self.defaultTimeout, Self.timeouts.lowerBound), Self.timeouts.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case name, run, when, timeout
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // One path may be written on its own, without a list around it.
        var when: [String] = []
        if let paths = try? values.decodeIfPresent([String].self, forKey: .when) {
            when = paths
        } else if let path = try? values.decodeIfPresent(String.self, forKey: .when) {
            when = [path]
        }
        self.init(name: try values.decodeIfPresent(String.self, forKey: .name) ?? "",
                  run: try values.decode(String.self, forKey: .run),
                  when: when,
                  timeout: try values.decodeIfPresent(TimeInterval.self, forKey: .timeout))
    }
}

/// What one check found on a task's work.
public struct CheckResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case passed
        case failed
        /// It was still running when its time was up, and was stopped.
        case timedOut = "timed_out"
        /// It could not be run: its command did not start, or the checks
        /// file could not be read.
        case notRun = "not_run"
    }

    public var name: String
    /// The command it ran; "" when nothing was run.
    public var command: String
    public var outcome: Outcome
    /// What the command exited with, when it came to an end by itself.
    public var exitCode: Int32?
    public var seconds: Double
    /// The end of what it printed, where a failure says why; for a check
    /// that could not be run, why not.
    public var output: String
    /// The errors it named at places in files, each as
    /// "Sources/App.swift:12:5: error: cannot find 'x' in scope", with the
    /// path from the project's folder.
    public var problems: [String]

    public init(name: String, command: String, outcome: Outcome, exitCode: Int32? = nil, seconds: Double = 0,
                output: String = "", problems: [String] = []) {
        self.name = name
        self.command = command
        self.outcome = outcome
        self.exitCode = exitCode
        self.seconds = seconds
        self.output = output
        self.problems = problems
    }

    public var passed: Bool { outcome == .passed }
}

/// Reading a project's checks, choosing the ones a task's work calls for,
/// and saying what they found: to the review, which is given it as
/// evidence the agent cannot talk its way past; to the run that takes a
/// task up again; and to the person.
///
/// The checks file is read from the project's own folder, the person's
/// checkout, never from the task's copy, so a task cannot change how its
/// own work is checked. Work whose checks did not all pass is never
/// approved without a person (`letThrough`).
public enum Checks {
    /// Where a project's checks are written, from its folder.
    public static let file = ".companion/checks.json"
    /// The most errors kept from a check that failed, and the most of what
    /// it printed that the review is given.
    public static let problemLimit = 12
    public static let evidenceLength = 2_500

    /// Why a checks file could not be read, in words for the person.
    public struct Unreadable: Error, Equatable, Sendable {
        public var reason: String

        public init(reason: String) {
            self.reason = reason
        }
    }

    private struct File: Decodable {
        var checks: [Check]
    }

    /// The checks a checks file holds: `{"checks": [...]}`, or the list on
    /// its own.
    public static func read(_ data: Data) throws -> [Check] {
        let decoder = JSONDecoder()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Unreadable(reason: "it is empty") }
        let checks: [Check]
        do {
            if text.hasPrefix("[") {
                checks = try decoder.decode([Check].self, from: data)
            } else {
                checks = try decoder.decode(File.self, from: data).checks
            }
        } catch let error as DecodingError {
            throw Unreadable(reason: words(for: error))
        } catch {
            throw Unreadable(reason: error.localizedDescription)
        }
        if let blank = checks.firstIndex(where: { $0.run.isEmpty }) {
            throw Unreadable(reason: "checks[\(blank)] has no command in \"run\"")
        }
        return checks
    }

    /// Where in the file reading stopped, and why.
    static func words(for error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? "it is not valid JSON" : "\(place(context.codingPath)) could not be read"
        case .keyNotFound(let key, let context):
            return "\(place(context.codingPath + [key])) is missing"
        case .typeMismatch(_, let context):
            return "\(place(context.codingPath)) has the wrong type"
        case .valueNotFound(_, let context):
            return "\(place(context.codingPath)) has no value"
        @unknown default:
            return "it could not be read"
        }
    }

    /// A place in the file as a person finds it there: "checks[1].run".
    private static func place(_ path: [CodingKey]) -> String {
        var text = ""
        for key in path {
            if let index = key.intValue {
                text += "[\(index)]"
            } else {
                text += (text.isEmpty ? "" : ".") + key.stringValue
            }
        }
        return text.isEmpty ? "the file" : text
    }

    /// The checks that cover work which changed `changed` (paths from the
    /// project's folder), in the order they are written. Work that changed
    /// nothing has nothing to check.
    public static func due(_ checks: [Check], changed: [String]) -> [Check] {
        guard !changed.isEmpty else { return [] }
        return checks.filter { check in
            check.when.isEmpty || check.when.contains { path in changed.contains { Leases.overlap(path, $0) } }
        }
    }

    /// Whether work whose checks came to `results` may be approved without
    /// a person: none of them failed, ran out of time or could not be run.
    /// A project with no checks (nil), and work none of them covers, are
    /// let through: what the review makes of them decides.
    public static func letThrough(_ results: [CheckResult]?) -> Bool {
        results?.allSatisfy(\.passed) ?? true
    }

    /// How a check went, for the person: "passed in 41 s", "failed (exit 1)
    /// after 3 min 12 s".
    public static func status(_ result: CheckResult) -> String {
        let time = duration(result.seconds)
        switch result.outcome {
        case .passed:
            return "passed in \(time)"
        case .failed:
            return "failed" + (result.exitCode.map { " (exit \($0))" } ?? "") + " after \(time)"
        case .timedOut:
            return "was stopped after \(time): it ran out of time"
        case .notRun:
            let why = lastLines(result.output, 1)
            return "could not be run" + (why.isEmpty ? "" : ": " + why)
        }
    }

    /// A time as a person says it: "41 s", "3 min 12 s", "1 h 5 min".
    public static func duration(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded()))
        if whole < 60 { return "\(whole) s" }
        if whole < 3_600 {
            return "\(whole / 60) min" + (whole % 60 == 0 ? "" : " \(whole % 60) s")
        }
        let minutes = (whole % 3_600) / 60
        return "\(whole / 3_600) h" + (minutes == 0 ? "" : " \(minutes) min")
    }

    /// What the review is told of the checks: how each went, and for one
    /// that did not pass, the errors it named and the end of what it printed.
    public static func evidence(_ results: [CheckResult]?) -> String {
        guard let results else {
            return "No checks are set up for this project (\(file)). Judge from the commands the agent ran, and do not take its word that something builds or passes where none of them shows it."
        }
        guard !results.isEmpty else { return "None of the project's checks cover what this work changed." }
        return results.map { result -> String in
            let command = result.command.isEmpty || result.command == result.name ? "" : " (`\(result.command)`)"
            var text = "- [\(result.passed ? "passed" : "FAILED")] \(result.name)\(command): \(status(result))"
            guard !result.passed else { return text }
            if !result.problems.isEmpty {
                text += "\n  Errors it named:\n"
                    + result.problems.prefix(problemLimit).map { "    " + $0 }.joined(separator: "\n")
            }
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty {
                text += "\n  The end of what it printed:\n"
                    + String(output.suffix(evidenceLength)).split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "    \($0)" }.joined(separator: "\n")
            }
            return text
        }.joined(separator: "\n")
    }

    /// What did not pass, in a few lines, for the notes a run that takes
    /// the task up again reads. "" when everything passed.
    public static func digest(_ results: [CheckResult], limit: Int = 1_200) -> String {
        let failed = results.filter { !$0.passed }
        guard !failed.isEmpty else { return "" }
        let text = failed.map { result -> String in
            let command = result.command.isEmpty || result.command == result.name ? "" : " (`\(result.command)`)"
            var line = "\(result.name)\(command) \(status(result))"
            let detail = result.problems.isEmpty
                ? lastLines(result.output, 4)
                : result.problems.prefix(5).joined(separator: "; ")
            if !detail.isEmpty, result.outcome != .notRun { line += ": " + detail }
            return line
        }.joined(separator: "\n")
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    /// The last lines of a command's output that say something, joined.
    static func lastLines(_ output: String, _ count: Int) -> String {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(count)
            .joined(separator: " / ")
    }

    /// A first checks file for a project, for the person to make their
    /// own: what the file holds, in its own words, and the build the app
    /// found in the folder (`build`) as its one check, when it found one.
    public static func starter(build: String?) -> String {
        let about = "Commands Companion runs in a task's own copy after a run of it finishes, before it is reviewed. run: the command, run in this folder in the copy. when: paths from this folder; the check runs only for work that changed something under one of them (leave it out to run it for all work). timeout: seconds (\(Int(Check.defaultTimeout)) when left out). Work whose checks fail is never approved without you."
        var lines = ["{", "  \"about\": \(quoted(about)),", "  \"checks\": ["]
        if let build, !build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("    { \"name\": \"Build\", \"run\": \(quoted(build)) }")
        }
        lines += ["  ]", "}", ""]
        return lines.joined(separator: "\n")
    }

    /// Text as a JSON string.
    private static func quoted(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(text), let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return json
    }
}

extension WorkingCopy {
    /// A path from the copy's top as a path from the project's folder:
    /// "apple/Sources/App.swift" is "Sources/App.swift" for a project that
    /// is the "apple" folder of its repository. A path outside the
    /// project's folder stays as it was.
    public func fromProject(_ path: String) -> String {
        let inside = subfolder.isEmpty ? "" : subfolder + "/"
        return inside.isEmpty || !path.hasPrefix(inside) ? path : String(path.dropFirst(inside.count))
    }
}

extension Board {
    /// What the project's checks found on a finished run's work, kept with
    /// that run. False when the task or the run is not there any more.
    @discardableResult
    public mutating func recordChecks(_ id: UUID, run: UUID, _ results: [CheckResult], now: Date) -> Bool {
        guard let index = allItems.firstIndex(where: { $0.id == id }),
              let place = allItems[index].runs.firstIndex(where: { $0.id == run }) else { return false }
        allItems[index].runs[place].checks = results
        allItems[index].updatedAt = now
        updatedAt = now
        let item = allItems[index]
        let failed = results.filter { !$0.passed }
        if !results.isEmpty {
            let text = failed.isEmpty
                ? "\(item.key) passed its checks: " + results.map(\.name).joined(separator: ", ")
                : "\(item.key) did not pass " + failed.map(\.name).joined(separator: ", ")
            log(text, by: .run, item: item.number, now: now)
        }
        return true
    }
}
