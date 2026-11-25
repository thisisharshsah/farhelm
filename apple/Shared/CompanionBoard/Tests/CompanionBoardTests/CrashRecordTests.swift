import XCTest
@testable import CompanionBoard

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func context(runs: [CrashRun] = []) -> CrashContext {
    CrashContext(appVersion: "0.1.0", build: "1", bundlePath: "/Users/someone/farhelm/apple/dist/Companion.app",
                 launchedAt: t0.addingTimeInterval(-600), updatedAt: t0.addingTimeInterval(-3),
                 activity: "Advanced, in the chat \"Board\", 2 agents at work", runs: runs)
}

final class CrashRecordTests: XCTestCase {
    func testAHandlersNoteIsReadWithItsStack() throws {
        let parsed = try XCTUnwrap(CrashNote.parse("""
        signal 5
        time 1800000000
        main 0
        0   Companion    0x0000000100a01000 crashkit_handler + 64
        1   libsystem_platform.dylib 0x000000018f0a0000 _sigtramp + 56
        2   libswift_Concurrency.dylib 0x0000000190000000 CheckedContinuation.resume(throwing:) + 332
        3   Companion    0x0000000100b00000 closure #1 in RelaySocket.ping(timeout:) + 64
        """))
        XCTAssertEqual(parsed.signal, 5)
        XCTAssertEqual(parsed.date, t0)
        XCTAssertEqual(parsed.onMainThread, false)
        XCTAssertEqual(parsed.frames.count, 4)

        let record = CrashNote.record(parsed, context: context(), fallback: t0.addingTimeInterval(900))
        XCTAssertEqual(record.kind, .signal)
        XCTAssertEqual(record.date, t0)
        XCTAssertEqual(record.thread, "a background thread")
        XCTAssertTrue(record.reason.hasPrefix("SIGTRAP"))
        // The handler's own frames are left out: the cause comes first.
        XCTAssertEqual(record.stack.count, 2)
        XCTAssertTrue(record.stack[0].contains("CheckedContinuation.resume"))
    }

    func testAnEmptyNoteIsNoCrash() {
        // The file is opened at every launch and stays empty unless the app crashed.
        XCTAssertNil(CrashNote.parse(""))
        XCTAssertNil(CrashNote.parse("\n\n"))
        XCTAssertNil(CrashNote.parse("time 1800000000\n"))
    }

    func testANoteCutShortStillSaysWhichSignal() throws {
        // Naming the frames can fail in a process that is already broken.
        let parsed = try XCTUnwrap(CrashNote.parse("signal 11\n"))
        let record = CrashNote.record(parsed, context: nil, fallback: t0)
        XCTAssertEqual(record.date, t0)
        XCTAssertTrue(record.reason.hasPrefix("SIGSEGV"))
        XCTAssertNil(record.thread)
        XCTAssertTrue(record.stack.isEmpty)
        XCTAssertTrue(record.report.contains("Stack: none was captured"))
        XCTAssertTrue(record.report.contains("not known"))
    }

    func testARunawayStackIsCut() throws {
        let frames = (0..<5_000).map { "\($0) Companion 0x0000000100000000 again + 4" }
        let parsed = try XCTUnwrap(CrashNote.parse("signal 11\n" + frames.joined(separator: "\n")))
        XCTAssertEqual(parsed.frames.count, CrashRecord.frameLimit)
    }

    func testTheNewestUnansweredCrashIsTheOneTold() {
        let old = CrashRecord(date: t0, kind: .signal, reason: "SIGSEGV", stack: [], context: nil)
        var answered = CrashRecord(date: t0.addingTimeInterval(500), kind: .exception, reason: "NSRangeException",
                                   stack: [], context: nil)
        answered.answeredAt = t0.addingTimeInterval(600)
        XCTAssertEqual(CrashRecord.toTell(among: [old, answered])?.id, old.id)
        let newer = CrashRecord(date: t0.addingTimeInterval(900), kind: .signal, reason: "SIGABRT", stack: [], context: nil)
        XCTAssertEqual(CrashRecord.toTell(among: [old, answered, newer])?.id, newer.id)
        XCTAssertNil(CrashRecord.toTell(among: [answered]))
        XCTAssertNil(CrashRecord.toTell(among: []))
    }

    func testWhatMacOSReportsLaterIsNotASecondCrash() {
        var own = CrashRecord(date: t0, kind: .signal, reason: "SIGSEGV", stack: [], context: nil)
        own.answeredAt = t0.addingTimeInterval(60)
        let same = CrashRecord(date: t0.addingTimeInterval(2), kind: .diagnostic, reason: "EXC_BAD_ACCESS",
                               stack: [], context: nil)
        // The app recorded it and the person answered: macOS's copy is kept, not announced.
        XCTAssertNil(CrashRecord.toTell(among: [own, same]))
        // One the app's own handlers missed is told.
        let missed = CrashRecord(date: t0.addingTimeInterval(4_000), kind: .diagnostic, reason: "EXC_CRASH",
                                 stack: [], context: nil)
        XCTAssertEqual(CrashRecord.toTell(among: [own, same, missed])?.id, missed.id)
    }

    func testAReportForAWholeDayCoversTheCrashInsideIt() {
        var own = CrashRecord(date: t0, kind: .signal, reason: "SIGTRAP", stack: [], context: nil)
        own.answeredAt = t0.addingTimeInterval(60)
        // macOS dates its report by the stretch it reports on, not the moment.
        let day = CrashContext(appVersion: "0.1.0", build: "1", bundlePath: "", launchedAt: t0.addingTimeInterval(-40_000),
                               updatedAt: t0.addingTimeInterval(40_000), activity: "", runs: [])
        let report = CrashRecord(date: t0.addingTimeInterval(40_000), kind: .diagnostic, reason: "EXC_BREAKPOINT",
                                 stack: [], context: day)
        XCTAssertTrue(own.covers(report))
        XCTAssertNil(CrashRecord.toTell(among: [own, report]))
        let before = CrashRecord(date: t0.addingTimeInterval(-90_000), kind: .signal, reason: "SIGTRAP", stack: [], context: nil)
        XCTAssertFalse(before.covers(report))
    }

    func testTheTaskSaysWhatStoppedItAndWhereTheReportIs() {
        let runs = [CrashRun(project: "farhelm", task: "T-39", title: "Sign builds", model: "Sonnet")]
        let record = CrashRecord(date: t0, kind: .signal, reason: CrashNote.name(of: 11), thread: "the main thread",
                                 stack: ["0 Companion 0x1 ChromiumTab.wake() + 264"], context: context(runs: runs))
        XCTAssertEqual(record.taskTitle, "Companion quit unexpectedly: SIGSEGV (a bad memory access)")
        let details = record.taskDetails(file: "/tmp/crashes/\(record.fileName)")
        XCTAssertTrue(details.contains("/tmp/crashes/\(record.fileName)"))
        XCTAssertTrue(details.contains("0.1.0 (1)"))
        XCTAssertTrue(details.contains("2 agents at work"))
        let report = record.report
        XCTAssertTrue(report.contains("- farhelm T-39 Sign builds (Sonnet)"))
        XCTAssertTrue(report.contains("ChromiumTab.wake()"))
        XCTAssertTrue(report.contains("Thread: the main thread"))
    }

    func testALongReasonIsShortenedForTheCard() {
        let record = CrashRecord(date: t0, kind: .exception,
                                 reason: String(repeating: "x", count: 300) + "\nsecond line", stack: [], context: nil)
        XCTAssertLessThanOrEqual(record.taskTitle.count, "Companion quit unexpectedly: ".count + 70)
        XCTAssertFalse(record.taskTitle.contains("second line"))
    }

    func testARecordIsReadBackAsItWasWritten() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = CrashRecord(date: t0, kind: .exception, reason: "NSInvalidArgumentException: nil key",
                                 stack: ["a", "b"], context: context())
        XCTAssertEqual(try decoder.decode(CrashRecord.self, from: encoder.encode(record)), record)
        XCTAssertEqual(record.fileName, "2027-01-15T080000Z-exception-\(record.id.uuidString.prefix(8)).json")
    }

    func testTheContextIsWrittenAgainOnlyWhenSomethingChanged() {
        let first = context()
        var later = first
        later.updatedAt = t0.addingTimeInterval(30)
        XCTAssertTrue(first.sameState(as: later))
        later.activity = "Chat, nothing running"
        XCTAssertFalse(first.sameState(as: later))
    }
}
