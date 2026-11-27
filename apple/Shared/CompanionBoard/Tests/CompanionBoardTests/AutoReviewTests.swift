import XCTest
@testable import CompanionBoard

private let project = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// A board with one task waiting in Review, its last run finished with
/// these check results.
private func reviewing(checks: [CheckResult]?) -> (Board, UUID) {
    var board = Board(project: project, now: t0)
    let item = board.add(title: "Work", acceptance: ["It builds"], status: .review, by: .person, now: t0)
    board.update(item.id, now: t0) { task in
        task.runs = [WorkRun(conversation: UUID(), model: ModelChoice(engine: "ollama", model: "qwen3-coder:30b"),
                             modelLabel: "Qwen", startedAt: t0, endedAt: t0, outcome: .succeeded, checks: checks)]
    }
    return (board, item.id)
}

private let passed = CheckResult(name: "App builds", command: "bash build.sh check", outcome: .passed)
private let failed = CheckResult(name: "App builds", command: "bash build.sh check", outcome: .failed, exitCode: 1)

final class AutoReviewTests: XCTestCase {
    func testANewBoardReviewsByItself() {
        XCTAssertTrue(Board(project: project, now: t0).settings.autoReview)
        XCTAssertTrue(BoardSettings().autoReview)
        // A board saved before the setting existed has it on as well.
        let saved = try! JSONDecoder().decode(BoardSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(saved.autoReview)
    }

    func testItApprovesOnlyWorkWhoseChecksPassed() {
        let (good, goodID) = reviewing(checks: [passed])
        XCTAssertEqual(AutoReview.decide(good.item(goodID)!, on: good, verdict: .approved)?.decision, .approve)

        // Failed checks go back, whatever the review said.
        let (bad, badID) = reviewing(checks: [passed, failed])
        XCTAssertEqual(AutoReview.decide(bad.item(badID)!, on: bad, verdict: .approved)?.decision, .sendBack)

        // No checks ran, so nothing shows it builds: the owner decides.
        let (none, noneID) = reviewing(checks: nil)
        XCTAssertEqual(AutoReview.decide(none.item(noneID)!, on: none, verdict: .approved)?.decision, .askOwner)
        let (empty, emptyID) = reviewing(checks: [])
        XCTAssertEqual(AutoReview.decide(empty.item(emptyID)!, on: empty, verdict: .approved)?.decision, .askOwner)
    }

    func testCredentialFilesGoToTheOwner() {
        let (board, id) = reviewing(checks: [passed])
        let decision = AutoReview.decide(board.item(id)!, on: board, verdict: .approved, changed: ["config/.env"])
        XCTAssertEqual(decision?.decision, .askOwner)
    }

    func testEveryDecisionWritesALogEntry() {
        for (checks, verdict) in [([passed], Review.Verdict.approved), ([failed], .approved), (nil, .approved)] {
            var (board, id) = reviewing(checks: checks)
            let key = board.item(id)!.key
            let decision = AutoReview.decide(board.item(id)!, on: board, verdict: verdict)!
            let entry = board.decide(id, decision, by: "Strong model", now: t0)
            XCTAssertEqual(board.decisions.count, 1)
            XCTAssertEqual(board.decisions.last, entry)
            XCTAssertEqual(entry?.task, key)
            XCTAssertEqual(entry?.decision, decision.decision)
            XCTAssertFalse(entry?.reason.isEmpty ?? true)
            XCTAssertEqual(entry?.model, "Strong model")
            XCTAssertEqual(entry?.date, t0)
        }
    }

    func testApprovedWorkIsDoneAndSentBackWorkIsToDo() {
        var (good, goodID) = reviewing(checks: [passed])
        good.decide(goodID, AutoReview.decide(good.item(goodID)!, on: good, verdict: .approved)!, by: "M", now: t0)
        XCTAssertEqual(good.item(goodID)?.status, .done)

        var (bad, badID) = reviewing(checks: [failed])
        bad.decide(badID, AutoReview.decide(bad.item(badID)!, on: bad, verdict: .approved)!, by: "M", now: t0)
        XCTAssertEqual(bad.item(badID)?.status, .todo)
    }

    func testARunMissingUncommittedWorkIsHeldOnce() {
        var board = Board(project: project, now: t0)
        board.settings.autopilot = true
        let item = board.add(title: "Work", by: .person, now: t0)
        board.update(item.id, now: t0) { task in
            task.runs = [WorkRun(conversation: UUID(), model: ModelChoice(engine: "ollama", model: "q"), modelLabel: "Q",
                                 startedAt: t0, endedAt: t0, outcome: .failed,
                                 report: "Build failed: Theme.swift is uncommitted in your folder.", ending: .itself)]
        }
        let held = AutoReview.hold(board.item(item.id)!, on: board)
        XCTAssertEqual(held?.decision, .hold)
        board.decide(item.id, held!, by: "Board", now: t0)
        XCTAssertNil(AutoReview.hold(board.item(item.id)!, on: board))
        XCTAssertFalse(board.autopilotMayStart(board.item(item.id)!))
        XCTAssertFalse(board.mayCarryOn(board.item(item.id)!))
    }

    func testTheLogSurvivesSaving() throws {
        var (board, id) = reviewing(checks: [passed])
        board.decide(id, AutoDecision(.askOwner, reason: "Needs you."), by: "M", now: t0)
        let read = try JSONDecoder().decode(Board.self, from: JSONEncoder().encode(board))
        XCTAssertEqual(read.decisions, board.decisions)
    }
}