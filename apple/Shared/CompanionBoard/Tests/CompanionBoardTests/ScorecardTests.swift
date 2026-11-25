import XCTest
@testable import CompanionBoard

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func minutes(_ count: Double) -> Date { t0.addingTimeInterval(count * 60) }

private func choice(_ model: String) -> ModelChoice { ModelChoice(engine: "test", model: model) }

final class ScorecardTests: XCTestCase {

    // MARK: - Scorecard updates on run outcomes

    func testScorecardUpdatesWhenRunIsApproved() {
        let item = WorkItem(
            number: 1, title: "Build login", estimateTokens: 10_000,
            runs: [
                WorkRun(conversation: UUID(), model: choice("m1"), modelLabel: "M1",
                        startedAt: t0, endedAt: minutes(5), outcome: .succeeded,
                        review: Review(verdict: .approved, notes: "", by: "Supervisor", date: minutes(6)),
                        ending: .itself,
                        checks: [CheckResult(name: "Tests", command: "swift test", outcome: .passed)],
                        tokens: 9_000),
            ],
            createdAt: t0, role: "eng"
        )

        let cards = Scorecard.of(items: [item])
        let key = Scorecard.Key(role: "eng", modelKey: choice("m1").key)
        let card = cards[key]!

        XCTAssertEqual(card.judgedRuns, 1)
        XCTAssertEqual(card.firstReviewApproved, 1)
        XCTAssertEqual(card.firstReviewTotal, 1)
        XCTAssertEqual(card.checksPassing, 1)
        XCTAssertEqual(card.checksTotal, 1)
        XCTAssertEqual(card.tokenRatios.count, 1)
        XCTAssertEqual(card.tokenRatios[0], 0.9, accuracy: 0.01)
    }

    func testScorecardUpdatesWhenRunIsSentBack() {
        let item = WorkItem(
            number: 1, title: "Build login", estimateTokens: 10_000,
            runs: [
                WorkRun(conversation: UUID(), model: choice("m1"), modelLabel: "M1",
                        startedAt: t0, endedAt: minutes(5), outcome: .succeeded,
                        review: Review(verdict: .changesRequested, notes: "Missing tests.",
                                       by: "Supervisor", date: minutes(6)),
                        ending: .itself,
                        checks: [CheckResult(name: "Tests", command: "swift test", outcome: .failed,
                                             exitCode: 1)],
                        tokens: 15_000),
            ],
            createdAt: t0, role: "eng"
        )

        let cards = Scorecard.of(items: [item])
        let key = Scorecard.Key(role: "eng", modelKey: choice("m1").key)
        let card = cards[key]!

        XCTAssertEqual(card.judgedRuns, 1)
        XCTAssertEqual(card.firstReviewApproved, 0)
        XCTAssertEqual(card.changesAskedCount, 1)
        XCTAssertEqual(card.checksPassing, 0)
        XCTAssertEqual(card.checksTotal, 1)
        XCTAssertEqual(card.tokenRatios[0], 1.5, accuracy: 0.01)
    }

    func testScorecardUpdatesWhenRunFails() {
        let item = WorkItem(
            number: 1, title: "Build login",
            runs: [
                WorkRun(conversation: UUID(), model: choice("m1"), modelLabel: "M1",
                        startedAt: t0, endedAt: minutes(5), outcome: .failed,
                        ending: .itself),
            ],
            createdAt: t0, role: "eng"
        )

        let cards = Scorecard.of(items: [item])
        let key = Scorecard.Key(role: "eng", modelKey: choice("m1").key)
        let card = cards[key]!

        XCTAssertEqual(card.judgedRuns, 1)
        XCTAssertEqual(card.firstReviewApproved, 0)
        XCTAssertEqual(card.firstReviewTotal, 1)
    }

    // MARK: - Skips inappropriate runs

    func testPersonStoppedRunsAreNotCounted() {
        let item = WorkItem(
            number: 1, title: "Work",
            runs: [
                WorkRun(conversation: UUID(), model: choice("m1"), modelLabel: "M1",
                        startedAt: t0, endedAt: minutes(5), outcome: .stopped,
                        ending: .person),
            ],
            createdAt: t0, role: "eng"
        )
        let cards = Scorecard.of(items: [item])
        XCTAssertTrue(cards.isEmpty)
    }

    // MARK: - Score calculation

    func testNeutralScoreIsAboutPointSix() {
        let neutral = Scorecard.neutral
        XCTAssertEqual(neutral.rawScore, Scorecard.neutralScore, accuracy: 0.05)
    }

    func testPerfectScoreIsOne() {
        let card = Scorecard(
            role: "eng", modelKey: "m1",
            judgedRuns: 10,
            firstReviewApproved: 10, firstReviewTotal: 10,
            changesAskedCount: 0, totalReviews: 10,
            checksPassing: 10, checksTotal: 10,
            tokenRatios: [1.0, 1.1, 0.9, 1.0, 1.0]
        )
        XCTAssertEqual(card.rawScore, 1.0, accuracy: 0.01)
    }

    func testTokenFitFallsToZeroAtThreeX() {
        let card = Scorecard(tokenRatios: [3.0])
        XCTAssertEqual(card.tokenFit, 0.0, accuracy: 0.01)
    }

    func testTokenFitIsOneAtOrBelowOneTwoX() {
        let card = Scorecard(tokenRatios: [1.0, 1.1, 1.2])
        XCTAssertEqual(card.tokenFit, 1.0, accuracy: 0.01)
    }

    func testPoorPairDetection() {
        let poor = Scorecard(judgedRuns: 5, firstReviewApproved: 0, firstReviewTotal: 5,
                             changesAskedCount: 5, totalReviews: 5,
                             checksPassing: 0, checksTotal: 5)
        XCTAssertTrue(poor.isPoor)

        let fine = Scorecard(judgedRuns: 5, firstReviewApproved: 4, firstReviewTotal: 5,
                             changesAskedCount: 1, totalReviews: 5,
                             checksPassing: 5, checksTotal: 5,
                             tokenRatios: [1.0])
        XCTAssertFalse(fine.isPoor)
    }

    // MARK: - Blending

    func testBlendingWithPrior() {
        var card = Scorecard(judgedRuns: 5, firstReviewApproved: 5, firstReviewTotal: 5,
                             changesAskedCount: 0, totalReviews: 5,
                             checksPassing: 5, checksTotal: 5,
                             tokenRatios: [1.0])
        let prior = Scorecard.neutral
        let blended = card.blended(with: prior)
        // 5 runs: about 2/7 own, 5/7 prior (between enough=3 and full=10).
        XCTAssertTrue(blended > prior.rawScore)
        XCTAssertTrue(blended < card.rawScore)

        // With enough but not full, should be between own and prior.
        card.judgedRuns = Scorecard.full
        let full = card.blended(with: prior)
        XCTAssertEqual(full, card.rawScore, accuracy: 0.01)
    }

    func testBelowEnoughReturnsOnlyPrior() {
        let card = Scorecard(judgedRuns: 2, firstReviewApproved: 2, firstReviewTotal: 2)
        let prior = Scorecard.neutral
        XCTAssertEqual(card.blended(with: prior), prior.rawScore, accuracy: 0.01)
    }

    // MARK: - Multi-role, multi-model

    func testScorecardsAreSplitByRoleAndModel() {
        let items = [
            WorkItem(number: 1, title: "A", runs: [
                WorkRun(conversation: UUID(), model: choice("m1"), modelLabel: "M1",
                        startedAt: t0, endedAt: minutes(5), outcome: .succeeded,
                        review: Review(verdict: .approved, notes: "", by: "S", date: minutes(6)),
                        ending: .itself),
            ], createdAt: t0, role: "mac-eng"),
            WorkItem(number: 2, title: "B", runs: [
                WorkRun(conversation: UUID(), model: choice("m1"), modelLabel: "M1",
                        startedAt: t0, endedAt: minutes(5), outcome: .succeeded,
                        review: Review(verdict: .changesRequested, notes: "No.", by: "S", date: minutes(6)),
                        ending: .itself),
            ], createdAt: t0, role: "writer"),
        ]
        let cards = Scorecard.of(items: items)
        XCTAssertEqual(cards.count, 2)
        let macKey = Scorecard.Key(role: "mac-eng", modelKey: choice("m1").key)
        let writerKey = Scorecard.Key(role: "writer", modelKey: choice("m1").key)
        XCTAssertEqual(cards[macKey]?.firstReviewApproved, 1)
        XCTAssertEqual(cards[writerKey]?.firstReviewApproved, 0)
    }

    // MARK: - Overrun ending counted

    func testOverrunEndingCountedInScorecard() {
        let item = WorkItem(
            number: 1, title: "Long task",
            runs: [
                WorkRun(conversation: UUID(), model: choice("m1"), modelLabel: "M1",
                        startedAt: t0, endedAt: minutes(60), outcome: .stopped,
                        ending: .overrun),
            ],
            createdAt: t0, role: "eng"
        )
        let cards = Scorecard.of(items: [item])
        let key = Scorecard.Key(role: "eng", modelKey: choice("m1").key)
        XCTAssertEqual(cards[key]?.failedOverrun, 1)
    }
}