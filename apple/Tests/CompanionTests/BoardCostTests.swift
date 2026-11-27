import XCTest
@testable import Companion
import CompanionBoard

final class BoardCostTests: XCTestCase {
    private func entry(engine: String, cost: Double) -> UsageEntry {
        UsageEntry(date: Date(), engine: engine, model: "m", purpose: "Agent",
                   input: 1000, output: 500, cost: cost)
    }

    func testSubscriptionRunIsCoveredByPlanWithNoDollars() {
        let ledger = Ledger([entry(engine: LLMProviderKind.subscription.rawValue, cost: 1.5)])
        let text = BoardCost.text(ledger)
        XCTAssertEqual(text.lowercased(), "covered by plan")
        XCTAssertFalse(text.contains("$"))
        // Its tokens are kept.
        XCTAssertEqual(ledger.total.tokens, 1500)
    }

    func testPerTokenRunKeepsItsDollarCost() {
        let ledger = Ledger([entry(engine: "anthropic", cost: 0.25)])
        XCTAssertEqual(BoardCost.text(ledger), Money.text(0.25))
    }

    func testTotalsAddOnlyRealDollars() {
        let ledger = Ledger([entry(engine: LLMProviderKind.subscription.rawValue, cost: 1.5),
                             entry(engine: "anthropic", cost: 0.25)])
        XCTAssertEqual(BoardCost.text(ledger), Money.text(0.25))
        XCTAssertEqual(ledger.total.tokens, 3000)
    }
}