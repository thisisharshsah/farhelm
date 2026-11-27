import XCTest
@testable import Companion
import CompanionBoard

final class ReviewAdviceTests: XCTestCase {
    private let model = ModelChoice(engine: "local", model: "test")
    private let chat = UUID()

    private func makeRun(checks: [CheckResult]? = nil,
                         verdict: Review.Verdict? = nil,
                         notes: String = "") -> WorkRun {
        var r = WorkRun(conversation: chat, model: model, modelLabel: "Test", startedAt: Date(),
                        outcome: .succeeded, checks: checks)
        if let verdict {
            r.advice = Review(verdict: verdict, notes: notes, by: "supervisor", date: Date())
        }
        return r
    }

    private func passed(_ name: String) -> CheckResult {
        CheckResult(name: name, command: "swift test", outcome: .passed)
    }

    private func failed(_ name: String) -> CheckResult {
        CheckResult(name: name, command: "swift test", outcome: .failed, exitCode: 1)
    }

    private func timedOut(_ name: String) -> CheckResult {
        CheckResult(name: name, command: "swift test", outcome: .timedOut)
    }

    private func notRun(_ name: String) -> CheckResult {
        CheckResult(name: name, command: "swift test", outcome: .notRun)
    }

    // MARK: Core invariant: nil or failed/unrun checks never produce Approve

    func testNilChecksGivesNoRecommendation() {
        let r = makeRun(checks: nil, verdict: .approved)
        XCTAssertNil(r.runRecommendation(),
                     "nil checks must produce no recommendation, even if advice says approved")
    }

    func testFailedCheckPreventsApprove() {
        let r = makeRun(checks: [passed("Build"), failed("Tests")], verdict: .approved)
        let rec = r.runRecommendation()
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.action, .askForChanges, "failed check must never yield Approve")
    }

    func testTimedOutCheckPreventsApprove() {
        let r = makeRun(checks: [passed("Build"), timedOut("Tests")])
        let rec = r.runRecommendation()
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.action, .askForChanges, "timed-out check must never yield Approve")
    }

    func testNotRunCheckPreventsApprove() {
        let r = makeRun(checks: [notRun("Build")])
        let rec = r.runRecommendation()
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.action, .askForChanges, "not-run check must never yield Approve")
    }

    func testPassingChecksWithApprovedAdviceRecommendsApprove() {
        let r = makeRun(checks: [passed("Build"), passed("Tests")], verdict: .approved, notes: "Looks good.")
        let rec = r.runRecommendation()
        XCTAssertEqual(rec?.action, .approve)
        XCTAssertEqual(rec?.reason, "Looks good.")
    }

    func testPassingChecksWithChangesRequestedRecommendsAskForChanges() {
        let r = makeRun(checks: [passed("Build")], verdict: .changesRequested, notes: "Missing tests.")
        let rec = r.runRecommendation()
        XCTAssertEqual(rec?.action, .askForChanges)
        XCTAssertEqual(rec?.reason, "Missing tests.")
    }

    func testFailingChecksOverrideApprovedVerdict() {
        let r = makeRun(checks: [failed("Build")], verdict: .approved)
        XCTAssertEqual(r.runRecommendation()?.action, .askForChanges,
                       "failing checks override supervisor approval")
    }

    func testPassingChecksNoAdviceRecommendsApprove() {
        let r = makeRun(checks: [passed("Build"), passed("Tests")])
        XCTAssertEqual(r.runRecommendation()?.action, .approve)
    }

    func testEmptyChecksNoAdviceRecommendsApprove() {
        let r = makeRun(checks: [])
        let rec = r.runRecommendation()
        XCTAssertEqual(rec?.action, .approve)
        XCTAssertFalse(rec?.reason.isEmpty ?? true)
    }
}