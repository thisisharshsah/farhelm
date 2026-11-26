import XCTest
@testable import CompanionBoard

private let project = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func choice(_ model: String) -> ModelChoice { ModelChoice(engine: "anthropic", model: model) }

/// A task with one run going on, set up to carry the given tokens and
/// signals: enough for the loop detector to look at, without the rest of
/// the board machinery getting in the way.
private func makeTask(estimate: Int?, tokens: Int?, signals: RunSignals,
                      title: String = "Loop") -> WorkItem {
    var board = Board(project: project, now: t0)
    let item = board.add(title: title, estimateTokens: estimate, by: .person, now: t0)
    let run = WorkRun(conversation: UUID(), model: choice("m"), modelLabel: "M", startedAt: t0,
                      tokens: tokens, signals: signals)
    board.beginRun(item.id, run, by: .person, now: t0)
    return board.item(item.id)!
}

final class LoopDetectionTests: XCTestCase {
    func testAHealthyRunIsNotFlagged() {
        let task = makeTask(estimate: 40_000, tokens: 10_000,
                            signals: RunSignals(reads: ["src/a.swift": 1], repeatedFailingEdits: 1))
        XCTAssertNil(LoopDetection.flag(for: task))
    }

    func testARunOverThreeTimesItsEstimateIsFlaggedAsOverrun() {
        let task = makeTask(estimate: 20_000, tokens: 80_000, signals: RunSignals())
        let flag = LoopDetection.flag(for: task)
        XCTAssertEqual(flag?.kind, .overrun)
        XCTAssertTrue(flag?.reason.contains("80k") ?? false, flag?.reason ?? "")
        XCTAssertTrue(flag?.reason.contains("3x") ?? false, flag?.reason ?? "")
    }

    func testARunReadingTheSameFileOverAndOverIsFlagged() {
        let task = makeTask(estimate: 40_000, tokens: 5_000,
                            signals: RunSignals(reads: ["src/x.swift": LoopDetection.repeatedReadsLimit,
                                                        "src/other.swift": 1]))
        let flag = LoopDetection.flag(for: task)
        XCTAssertEqual(flag?.kind, .repeatedReads)
        XCTAssertTrue(flag?.reason.contains("src/x.swift") ?? false, flag?.reason ?? "")
    }

    func testARunRetryingTheSameFailingEditIsFlagged() {
        let task = makeTask(estimate: 40_000, tokens: 5_000,
                            signals: RunSignals(lastFailingEditKey: "compile: missing semicolon",
                                                repeatedFailingEdits: LoopDetection.repeatedEditsLimit))
        let flag = LoopDetection.flag(for: task)
        XCTAssertEqual(flag?.kind, .repeatedEdits)
        XCTAssertTrue(flag?.reason.contains("failing edits") ?? false, flag?.reason ?? "")
    }

    func testARunThatFellBackAndLoopsIsFlaggedAsFallbackLooping() {
        let task = makeTask(estimate: 40_000, tokens: 5_000,
                            signals: RunSignals(reads: ["src/z.swift": LoopDetection.repeatedReadsLimit],
                                                fellBack: true))
        let flag = LoopDetection.flag(for: task)
        XCTAssertEqual(flag?.kind, .fallbackLooping)
        XCTAssertTrue(flag?.reason.contains("fell back") ?? false, flag?.reason ?? "")
    }

    func testFellBackAloneIsNotEnoughToFlagARun() {
        let task = makeTask(estimate: 40_000, tokens: 5_000,
                            signals: RunSignals(fellBack: true))
        XCTAssertNil(LoopDetection.flag(for: task))
    }

    func testSignalsRecordReadsAndEditsAsTheRunGoes() {
        var signals = RunSignals()
        signals.recordRead("src/x.swift")
        signals.recordRead("src/x.swift")
        signals.recordRead("src/x.swift")
        XCTAssertEqual(signals.reads["src/x.swift"], 3)
        // A successful edit clears what reads piled up; the next read starts over.
        signals.recordEdit("src/x.swift", succeeded: true)
        XCTAssertEqual(signals.reads, [:])
        // Failing edits with the same error pile up, a new error starts over.
        signals.recordEdit("src/x.swift", succeeded: false, errorKey: "missing semicolon")
        signals.recordEdit("src/x.swift", succeeded: false, errorKey: "missing semicolon")
        XCTAssertEqual(signals.repeatedFailingEdits, 2)
        signals.recordEdit("src/x.swift", succeeded: false, errorKey: "undeclared identifier")
        XCTAssertEqual(signals.repeatedFailingEdits, 1)
    }

    /// Reads, failing edits and a fallback fed through the board's live-run
    /// entry points land on the run going on and flip the flag the detector
    /// reports. This is what the app calls from `AgentTools` and `Advanced`.
    func testLiveRunEventsFlowIntoTheRunsSignals() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Live", by: .person, now: t0)
        let chat = UUID()
        board.beginRun(item.id, WorkRun(conversation: chat, model: choice("m"), modelLabel: "M", startedAt: t0),
                       by: .person, now: t0)
        // Three reads of the same file with no edit between flag the run.
        for _ in 0..<LoopDetection.repeatedReadsLimit {
            XCTAssertTrue(board.recordRead("src/x.swift", in: chat))
        }
        XCTAssertEqual(board.item(item.id)?.activeRun?.signals.reads["src/x.swift"],
                       LoopDetection.repeatedReadsLimit)
        XCTAssertEqual(LoopDetection.flag(for: board.item(item.id)!)?.kind, .repeatedReads)
        // A successful edit clears the pile and the detector goes quiet.
        XCTAssertTrue(board.recordEdit("src/x.swift", in: chat, succeeded: true))
        XCTAssertEqual(board.item(item.id)?.activeRun?.signals.reads, [:])
        XCTAssertNil(LoopDetection.flag(for: board.item(item.id)!))
        // Failing edits with the same error pile up and flag the run.
        for _ in 0..<LoopDetection.repeatedEditsLimit {
            XCTAssertTrue(board.recordEdit("src/x.swift", in: chat, succeeded: false,
                                            errorKey: "compile: missing semicolon"))
        }
        XCTAssertEqual(board.item(item.id)?.activeRun?.signals.repeatedFailingEdits,
                       LoopDetection.repeatedEditsLimit)
        XCTAssertEqual(LoopDetection.flag(for: board.item(item.id)!)?.kind, .repeatedEdits)
        // A fallback on a flagged run turns the flag into fallback-looping.
        XCTAssertTrue(board.markFellBack(in: chat))
        XCTAssertTrue(board.item(item.id)?.activeRun?.signals.fellBack ?? false)
        XCTAssertEqual(LoopDetection.flag(for: board.item(item.id)!)?.kind, .fallbackLooping)
        // A chat with no run going on drops the signal: nothing to flag.
        XCTAssertFalse(board.recordRead("src/other.swift", in: UUID()))
    }
}