import CompanionBoard
import Foundation

/// How the board writes what a request cost. A subscription run (Claude
/// Code, Codex) is paid for by the plan, so it has no dollar cost to show:
/// it keeps its tokens and reads "Covered by plan". Dollars are only
/// those of models billed per token, and totals add only those.
enum BoardCost {
    static let coveredText = "Covered by plan"

    /// A subscription's usage is kept under its own engine name
    /// (`EngineChoice.usageNames`).
    static func isPlan(_ entry: UsageEntry) -> Bool {
        entry.engine == LLMProviderKind.subscription.rawValue
    }

    /// Whether everything in a total ran on a plan.
    static func isCovered(_ total: UsageTotal, covered: UsageTotal) -> Bool {
        total.requests > 0 && covered.requests >= total.requests
    }

    /// The dollars of a total that were really billed.
    static func real(_ total: UsageTotal, covered: UsageTotal) -> Double {
        max(0, total.cost - covered.cost)
    }

    /// A total's cost as shown: "Covered by plan" when all of it ran on a
    /// plan, otherwise the dollars of the per-token part.
    static func text(_ total: UsageTotal, covered: UsageTotal) -> String {
        isCovered(total, covered: covered) ? coveredText : Money.text(real(total, covered: covered))
    }

    /// The same for a whole ledger.
    static func text(_ ledger: Ledger) -> String {
        text(ledger.total, covered: ledger.plan.total)
    }

    /// An average over some tasks: "$0.40 each", or the plan's words.
    static func each(_ total: UsageTotal, covered: UsageTotal, count: Int) -> String {
        if isCovered(total, covered: covered) { return coveredText.lowercased() }
        return "\(Money.text(real(total, covered: covered) / Double(max(count, 1)))) each"
    }
}

extension Ledger {
    /// The requests that ran on a subscription.
    var plan: Ledger { Ledger(entries.filter(BoardCost.isPlan)) }
}