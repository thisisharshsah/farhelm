import AppKit
import CompanionBoard
import CrashKit
import Foundation
import MetricKit
import os

/// Where crashes are kept: Companion's folder, under crashes/. One JSON
/// file per crash, never deleted by the app, beside two working files: the
/// signal handler's note and what the app last wrote down about itself.
/// Nothing here is tied to the main thread: an uncaught exception is
/// recorded from whichever thread threw it.
enum CrashFiles {
    static let folder = ContextStore.shared.baseDir.appendingPathComponent("crashes", isDirectory: true)
    /// What the signal handler writes (CrashKit). Emptied at every launch,
    /// after the last launch's has been read.
    static let note = folder.appendingPathComponent("signal.note")
    /// What the app was doing, kept up to date while it runs.
    static let context = folder.appendingPathComponent("context.json")

    private static let log = Logger(subsystem: "com.harshsah.companion", category: "crashes")

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Readable as it is: a person may open the file.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func prepare() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    static func file(of record: CrashRecord) -> URL {
        folder.appendingPathComponent(record.fileName)
    }

    @discardableResult
    static func save(_ record: CrashRecord) -> Bool {
        do {
            try encoder().encode(record).write(to: file(of: record), options: .atomic)
            return true
        } catch {
            log.error("a crash record could not be saved: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Every crash kept, oldest first. A file that cannot be read is
    /// passed over and left where it is.
    static func records() -> [CrashRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != context.lastPathComponent }
            .compactMap { file in
                (try? Data(contentsOf: file)).flatMap { try? decoder().decode(CrashRecord.self, from: $0) }
            }
            .sorted { $0.date < $1.date }
    }

    static func readContext() -> CrashContext? {
        (try? Data(contentsOf: context)).flatMap { try? decoder().decode(CrashContext.self, from: $0) }
    }

    static func write(_ value: CrashContext) {
        try? encoder().encode(value).write(to: context, options: .atomic)
    }
}

/// What the app last knew about itself, readable from any thread: the
/// uncaught exception handler runs wherever the exception was thrown and
/// cannot ask the main thread for anything.
private final class LatestContext: @unchecked Sendable {
    static let shared = LatestContext()
    private let lock = NSLock()
    private var value: CrashContext?

    func set(_ new: CrashContext) {
        lock.lock()
        value = new
        lock.unlock()
    }

    func get() -> CrashContext? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// The handler that was there before Companion's, called after it.
private var earlierExceptionHandler: (@convention(c) (NSException) -> Void)?

/// Keeps every crash: an exception nobody caught, a fatal signal, and what
/// macOS reports afterwards (MetricKit). Each is saved under crashes/ with
/// its time, the app's version, the stack, what the app was doing and the
/// board runs going on. At the next launch the newest one not yet answered
/// is offered as one line (`CrashNotice`), with a button that makes it a
/// task on the board.
///
/// A crashed app can do very little, so the work is split: while it runs,
/// the app writes down what it is doing every few seconds; a signal handler
/// (CrashKit, in C) adds only the signal and the stack; the record is put
/// together from the two when the app next starts.
@MainActor
final class CrashRecorder: ObservableObject {
    static let shared = CrashRecorder()

    /// The crash from an earlier launch that the person has not answered.
    @Published private(set) var toTell: CrashRecord?
    /// A word about what the button did, shown in the line for a moment.
    @Published private(set) var said: String?

    private let launchedAt = Date()
    private var started = false
    private var timer: Timer?
    private var written: CrashContext?
    private var subscriber: DiagnosticSubscriber?
    private let log = Logger(subsystem: "com.harshsah.companion", category: "crashes")

    /// How often what the app is doing is written down. A crash report is
    /// at most this far behind; the file is written only when it changed.
    private static let every: TimeInterval = 5

    private init() {}

    /// Called once, first thing at launch, before anything that could crash.
    func start() {
        guard !started else { return }
        started = true
        CrashFiles.prepare()
        collectLastLaunch()

        // From here on a fatal signal leaves a note. Arming empties the
        // note's file, which is why last launch's was read first.
        if crashkit_arm(CrashFiles.note.path) != 0 {
            log.error("the crash note could not be opened, so fatal signals are not recorded")
        }
        earlierExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            CrashRecorder.caught(exception)
            earlierExceptionHandler?(exception)
        }

        // Before the app has anything to say about itself, the record
        // still names the version and that it was starting.
        note(activity: "Starting", runs: [])
        let timer = Timer(timeInterval: Self.every, repeats: true) { _ in
            Task { @MainActor in CrashRecorder.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let subscriber = DiagnosticSubscriber()
        MXMetricManager.shared.add(subscriber)
        self.subscriber = subscriber

        toTell = CrashRecord.toTell(among: CrashFiles.records())
    }

    /// Chromium sets signal handlers of its own when it starts. Companion's
    /// are put back, here and on every tick.
    func rearm() {
        crashkit_rearm()
    }

    /// Makes the record of a signal that ended the last launch, from the
    /// handler's note and the context that launch left.
    private func collectLastLaunch() {
        guard let text = try? String(contentsOf: CrashFiles.note, encoding: .utf8),
              let parsed = CrashNote.parse(text) else { return }
        let before = CrashFiles.readContext()
        let record = CrashNote.record(parsed, context: before, fallback: before?.updatedAt ?? Date())
        // The note is emptied only by arming, after this: were the record
        // not saved, nothing else would hold the crash.
        CrashFiles.save(record)
    }

    // MARK: What the app is doing

    private func tick() {
        crashkit_rearm()
        let app = AppState.shared
        var parts = ["\(app.mode.title) side", app.panelVisible ? "panel showing" : "panel hidden"]
        let title = app.conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { parts.append("in the chat \"\(title)\"") }
        let agents = app.jobs.count
        parts.append(agents == 0 ? "no agent at work" : (agents == 1 ? "1 agent at work" : "\(agents) agents at work"))
        if app.isListening { parts.append("listening") }

        var runs: [CrashRun] = []
        for (projectID, board) in BoardStore.shared.boards {
            let name = app.projects.first { $0.id == projectID }?.name ?? "A project"
            for item in board.running {
                runs.append(CrashRun(project: name, task: item.key, title: item.title,
                                     model: item.activeRun?.modelLabel ?? ""))
            }
        }
        runs.sort { ($0.project, $0.task) < ($1.project, $1.task) }
        note(activity: parts.joined(separator: ", "), runs: runs)
    }

    private func note(activity: String, runs: [CrashRun]) {
        let info = Bundle.main.infoDictionary
        let context = CrashContext(appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
                                   build: info?["CFBundleVersion"] as? String ?? "unknown",
                                   bundlePath: Bundle.main.bundlePath, launchedAt: launchedAt, updatedAt: Date(),
                                   activity: activity, runs: runs)
        if let written, written.sameState(as: context) { return }
        written = context
        LatestContext.shared.set(context)
        CrashFiles.write(context)
    }

    // MARK: An uncaught exception

    /// Runs on the thread that threw, just before the app aborts. The
    /// process is still whole here (unlike inside a signal), so the record
    /// is written at once, complete.
    nonisolated private static func caught(_ exception: NSException) {
        let reason = [exception.name.rawValue, exception.reason ?? ""].filter { !$0.isEmpty }.joined(separator: ": ")
        let record = CrashRecord(date: Date(), kind: .exception, reason: reason,
                                 thread: Thread.isMainThread ? "the main thread" : "a background thread",
                                 stack: Array(exception.callStackSymbols.prefix(CrashRecord.frameLimit)),
                                 context: LatestContext.shared.get())
        // The abort that follows would be recorded a second time as a
        // signal; one record of one crash is enough.
        if CrashFiles.save(record) { crashkit_disarm() }
    }

    // MARK: Answering the line

    /// Where a crash's task goes: the project in view, else the one whose
    /// board was open last, else the first there is.
    var project: Project? {
        AppState.shared.currentProject ?? Advanced.shared.lastProject ?? AppState.shared.projects.first
    }

    /// The file a record is kept in.
    func file(of record: CrashRecord) -> URL {
        CrashFiles.file(of: record)
    }

    /// Makes the crash a task on the project's board, with the report in
    /// a note on it, and stops telling about it.
    func addToBoard() {
        guard let record = toTell, let project else { return }
        let key = Advanced.shared.addTask(from: record, file: file(of: record).path, in: project.id)
        guard let key else {
            say("It could not be added to the board. The report is in \(CrashFiles.folder.path)")
            return
        }
        answer(task: key)
        say("Added to \(project.name)'s board as \(key)")
    }

    /// The person has seen it and wants nothing done. The record stays.
    func dismiss() {
        answer(task: nil)
    }

    /// Every crash not yet answered is answered with this one: after a
    /// run of crashes the person is asked once, not once per launch.
    private func answer(task: String?) {
        guard let told = toTell else { return }
        let now = Date()
        for var record in CrashFiles.records() where record.answeredAt == nil {
            record.answeredAt = now
            if record.id == told.id { record.task = task }
            CrashFiles.save(record)
        }
        toTell = nil
    }

    private func say(_ text: String) {
        said = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if self?.said == text { self?.said = nil }
        }
    }
}

/// macOS's own account of a crash, delivered some time after the launch
/// that follows it. It is kept beside the app's record: it has the stacks
/// of crashes the handlers could not see (the app killed for memory, a
/// crash before they were armed). Called on a queue of MetricKit's.
private final class DiagnosticSubscriber: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                var what: [String] = []
                if let type = crash.exceptionType { what.append("exception type \(type)") }
                if let code = crash.exceptionCode { what.append("code \(code)") }
                if let signal = crash.signal { what.append(CrashNote.name(of: signal.int32Value)) }
                if let reason = crash.terminationReason, !reason.isEmpty { what.append(reason) }
                // MetricKit gives the day the crash fell in, not its moment:
                // the end of the stretch it reports on is the closest it has.
                let context = CrashContext(appVersion: crash.applicationVersion,
                                           build: crash.metaData.applicationBuildVersion,
                                           bundlePath: Bundle.main.bundlePath, launchedAt: payload.timeStampBegin,
                                           updatedAt: payload.timeStampEnd,
                                           activity: "not known (reported by macOS afterwards)", runs: [])
                let record = CrashRecord(date: payload.timeStampEnd, kind: .diagnostic,
                                         reason: what.isEmpty ? "A crash reported by macOS" : what.joined(separator: ", "),
                                         stack: Self.frames(of: crash.callStackTree), context: context)
                CrashFiles.save(record)
            }
        }
    }

    /// The crashed thread's frames out of MetricKit's tree, one line each:
    /// the binary, the address and how far into the binary it is.
    private static func frames(of tree: MXCallStackTree) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: tree.jsonRepresentation()) as? [String: Any],
              let stacks = json["callStacks"] as? [[String: Any]] else { return [] }
        let crashed = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
        var lines: [String] = []
        var next = (crashed?["callStackRootFrames"] as? [[String: Any]])?.first
        while let frame = next, lines.count < CrashRecord.frameLimit {
            let binary = frame["binaryName"] as? String ?? "?"
            let address = (frame["address"] as? NSNumber)?.uint64Value ?? 0
            let offset = (frame["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0
            lines.append("\(lines.count) \(binary) 0x\(String(address, radix: 16)) + \(offset)")
            next = (frame["subFrames"] as? [[String: Any]])?.first
        }
        return lines
    }
}
