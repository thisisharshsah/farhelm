import Foundation

/// A board run that was going on when the app stopped.
public struct CrashRun: Codable, Equatable, Sendable {
    /// The project's name.
    public var project: String
    /// The task's key and title: "T-7", "Sign the builds".
    public var task: String
    public var title: String
    /// The model the run was working with, as shown.
    public var model: String

    public init(project: String, task: String, title: String, model: String) {
        self.project = project
        self.task = task
        self.title = title
        self.model = model
    }
}

/// What the app was doing, written down as it goes so that it is already
/// on disk when the app stops: nothing can be asked of an app that has
/// crashed. It holds names and counts, never what a chat says.
public struct CrashContext: Codable, Equatable, Sendable {
    public var appVersion: String
    public var build: String
    /// Where the app was started from: two builds can be on one Mac (the
    /// person's and a board task's), and a report has to say which.
    public var bundlePath: String
    public var launchedAt: Date
    /// When this was last written.
    public var updatedAt: Date
    /// One line in plain words: the side in use, the chat in front, how
    /// many agents were at work.
    public var activity: String
    public var runs: [CrashRun]

    public init(appVersion: String, build: String, bundlePath: String, launchedAt: Date, updatedAt: Date,
                activity: String, runs: [CrashRun]) {
        self.appVersion = appVersion
        self.build = build
        self.bundlePath = bundlePath
        self.launchedAt = launchedAt
        self.updatedAt = updatedAt
        self.activity = activity
        self.runs = runs
    }

    /// The same apart from when it was written, so it is written again
    /// only when something changed.
    public func sameState(as other: CrashContext) -> Bool {
        var mine = self
        mine.updatedAt = other.updatedAt
        return mine == other
    }
}

/// One crash, kept in Companion's folder under crashes/.
public struct CrashRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// An exception nobody caught.
        case exception
        /// A fatal signal: a bad memory access, a failed Swift check, an abort.
        case signal
        /// What macOS reported afterwards (MetricKit).
        case diagnostic
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    /// What stopped it, in a line: "SIGSEGV (bad memory access)", or an
    /// exception's name and reason.
    public var reason: String
    /// The thread that crashed, where it is known.
    public var thread: String?
    /// The stack of the thread that crashed, innermost frame first.
    public var stack: [String]
    public var context: CrashContext?
    /// When the person answered the line about it (dismissed it, or made
    /// it a task). nil while they have not been told.
    public var answeredAt: Date?
    /// The board task made from it: "T-12".
    public var task: String?

    public init(id: UUID = UUID(), date: Date, kind: Kind, reason: String, thread: String? = nil,
                stack: [String], context: CrashContext?, answeredAt: Date? = nil, task: String? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.reason = reason
        self.thread = thread
        self.stack = stack
        self.context = context
        self.answeredAt = answeredAt
        self.task = task
    }

    /// The most frames kept of one stack: enough to see the cause, and a
    /// runaway recursion does not fill the disk.
    public static let frameLimit = 200

    /// The file it is kept in: sorted by name is sorted by time.
    public var fileName: String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        return "\(format.string(from: date))-\(kind.rawValue)-\(id.uuidString.prefix(8)).json"
    }

    /// macOS reports a crash a second time, later, through MetricKit.
    /// One that this record already covers adds nothing to tell the
    /// person: it is kept, and not announced again. MetricKit dates a
    /// crash only by the stretch of time it reports on (kept as the
    /// report's `launchedAt` to its `date`), so this record covers it
    /// when it falls in that stretch, give or take `seconds`.
    public func covers(_ report: CrashRecord, within seconds: TimeInterval = 120) -> Bool {
        let from = min(report.context?.launchedAt ?? report.date, report.date)
        return date >= from.addingTimeInterval(-seconds) && date <= report.date.addingTimeInterval(seconds)
    }

    /// Of `records`, the one the person is told about at launch: the
    /// newest not yet answered. A report from macOS is passed over when a
    /// record made by the app itself covers the same crash.
    public static func toTell(among records: [CrashRecord]) -> CrashRecord? {
        let own = records.filter { $0.kind != .diagnostic }
        return records
            .filter { $0.answeredAt == nil }
            .filter { record in
                record.kind != .diagnostic || !own.contains { $0.covers(record) }
            }
            .max { $0.date < $1.date }
    }

    // MARK: As a board task

    /// The task's title: what stopped the app, short enough for a card.
    public var taskTitle: String {
        let what = reason.split(separator: "\n").first.map(String.init) ?? reason
        let short = what.count > 70 ? String(what.prefix(69)) + "…" : what
        return "Companion quit unexpectedly: \(short)"
    }

    /// What the agent that works on the task reads. `file` is where the
    /// whole record is kept.
    public func taskDetails(file: String) -> String {
        var lines = ["Companion stopped on \(Self.stamp(date)).", "", "What stopped it: \(reason)"]
        if let thread, !thread.isEmpty { lines.append("Thread: \(thread)") }
        if let context {
            lines.append("Version: \(context.appVersion) (\(context.build)), started from \(context.bundlePath)")
            lines.append("What it was doing: \(context.activity)")
        }
        lines += ["", "The whole report, with the stack, is in the note on this task and in:", file, "",
                  "Find the cause from the stack, fix it, and add a test that would have caught it."]
        return lines.joined(separator: "\n")
    }

    /// The whole record as text a person can read: the note on the task.
    public var report: String {
        var lines = ["Crash report, \(Self.stamp(date))", "Kind: \(kind.rawValue)", "What stopped it: \(reason)"]
        if let thread, !thread.isEmpty { lines.append("Thread: \(thread)") }
        if let context {
            lines.append("Version: \(context.appVersion) (\(context.build))")
            lines.append("Started from: \(context.bundlePath)")
            lines.append("Running since: \(Self.stamp(context.launchedAt))")
            lines.append("What it was doing (as of \(Self.stamp(context.updatedAt))): \(context.activity)")
            if context.runs.isEmpty {
                lines.append("Board runs going on: none")
            } else {
                lines.append("Board runs going on:")
                for run in context.runs {
                    lines.append("- \(run.project) \(run.task) \(run.title) (\(run.model))")
                }
            }
        } else {
            lines.append("What it was doing: not known (nothing was written down before it stopped)")
        }
        lines.append("")
        lines.append(stack.isEmpty ? "Stack: none was captured" : "Stack, innermost first:")
        lines += stack
        return lines.joined(separator: "\n")
    }

    private static func stamp(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return format.string(from: date)
    }
}

/// What the signal handler leaves behind. A handler may only call what is
/// safe inside a signal, so it writes a few plain lines and nothing else:
///
///     signal 11
///     time 1795000000
///     main 1
///     0   Companion   0x0000000100003f20 main + 32
///
/// The record is made from it the next time the app starts.
public enum CrashNote {
    public struct Parsed: Equatable, Sendable {
        public var signal: Int32
        public var date: Date?
        public var onMainThread: Bool?
        public var frames: [String]
    }

    /// Reads a note. nil when it holds no signal: the file is there from
    /// the start of every launch, and empty unless the app crashed.
    public static func parse(_ text: String) -> Parsed? {
        var signal: Int32?
        var date: Date?
        var main: Bool?
        var frames: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if signal == nil, line.hasPrefix("signal ") {
                signal = Int32(line.dropFirst(7))
            } else if date == nil, frames.isEmpty, line.hasPrefix("time "), let seconds = TimeInterval(line.dropFirst(5)) {
                date = Date(timeIntervalSince1970: seconds)
            } else if main == nil, frames.isEmpty, line.hasPrefix("main ") {
                main = line.dropFirst(5) == "1"
            } else if frames.count < CrashRecord.frameLimit {
                frames.append(line)
            }
        }
        guard let signal else { return nil }
        return Parsed(signal: signal, date: date, onMainThread: main, frames: frames)
    }

    /// A signal's name with what it usually means, for a person.
    public static func name(of signal: Int32) -> String {
        switch signal {
        case 4: return "SIGILL (an instruction that cannot run)"
        case 5: return "SIGTRAP (a failed check in Swift: a precondition, a forced unwrap of nil, a continuation resumed twice)"
        case 6: return "SIGABRT (the app or a library aborted)"
        case 8: return "SIGFPE (an arithmetic error)"
        case 10: return "SIGBUS (a bad memory access)"
        case 11: return "SIGSEGV (a bad memory access)"
        case 12: return "SIGSYS (a system call that is not allowed)"
        default: return "signal \(signal)"
        }
    }

    /// The record of a note. `context` is what the app had written down
    /// about itself before it stopped; `fallback` is used for the time
    /// when the note has none.
    public static func record(_ parsed: Parsed, context: CrashContext?, fallback: Date) -> CrashRecord {
        // The handler's own frames come first; they say nothing about the cause.
        let frames = parsed.frames.filter { !$0.contains("crashkit_") && !$0.contains("_sigtramp") }
        let thread = parsed.onMainThread.map { $0 ? "the main thread" : "a background thread" }
        return CrashRecord(date: parsed.date ?? fallback, kind: .signal, reason: name(of: parsed.signal),
                           thread: thread, stack: frames, context: context)
    }
}
