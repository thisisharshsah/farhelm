import Foundation

/// A model a task could be given to, with what matters for choosing:
/// where it runs, what it costs, how much it can hold and how capable it is.
public struct ModelProfile: Equatable, Identifiable, Sendable {
    /// Where a model runs, which decides what using it costs.
    public enum Place: String, Sendable {
        /// On this Mac: no charge per token.
        case local
        /// Through a subscription: no charge per token, but a plan's limits.
        case account
        /// Through an API: charged per token.
        case api
    }

    /// How capable a model is, in three steps.
    public enum Tier: Int, Comparable, Sendable {
        /// Small and fast: short, well-specified work.
        case light = 1
        /// A good all-rounder.
        case balanced = 2
        /// The strongest: ambiguous, wide or delicate work.
        case strong = 3

        public static func < (left: Tier, right: Tier) -> Bool { left.rawValue < right.rawValue }

        public var title: String {
            switch self {
            case .light: return "Light"
            case .balanced: return "Balanced"
            case .strong: return "Strong"
            }
        }
    }

    /// A short name for the list a supervisor is given: "m1", "m2".
    public var id: String
    public var choice: ModelChoice
    /// The name as shown: "Claude · Sonnet 5.5".
    public var name: String
    public var place: Place
    /// Dollars per million tokens in and out; zero when unknown or free.
    public var inputPrice: Double
    public var outputPrice: Double
    /// Tokens it takes in one request.
    public var window: Int
    public var tier: Tier
    /// It calls tools natively, which agent work goes better with.
    public var tools: Bool
    /// What shares its limits: the models of one subscription share its
    /// plan. Work is spread across groups (`ModelRouting.busy`). By
    /// default each model is a group of its own.
    public var group: String

    public init(id: String, choice: ModelChoice, name: String, place: Place, inputPrice: Double = 0,
                outputPrice: Double = 0, window: Int, tier: Tier, tools: Bool, group: String? = nil) {
        self.id = id
        self.choice = choice
        self.name = name
        self.place = place
        self.inputPrice = inputPrice
        self.outputPrice = outputPrice
        self.window = window
        self.tier = tier
        self.tools = tools
        self.group = group ?? choice.key
    }

    /// What a task of this many tokens would cost here, in dollars, taking
    /// a quarter of it as output (agent work reads far more than it writes).
    public func cost(ofTokens tokens: Int) -> Double {
        let out = Double(tokens) * 0.25
        return ((Double(tokens) - out) * inputPrice + out * outputPrice) / 1_000_000
    }

    /// Whether what it costs is known: for a model billed per token, only
    /// once its price is set; on this Mac or a subscription, always.
    public var priceKnown: Bool { place != .api || inputPrice > 0 || outputPrice > 0 }

    /// One line for the supervisor: "m2 | Claude · Sonnet 5.5 | api | balanced | $2 in, $10 out per 1M | 200k window".
    public var line: String {
        let price: String
        switch place {
        case .local:
            // An engine on this Mac can pass requests on to a model that
            // is billed (Farhelm to a cloud model): its price says so.
            price = inputPrice == 0 && outputPrice == 0
                ? "free (runs on this Mac)"
                : "$\(Self.short(inputPrice)) in, $\(Self.short(outputPrice)) out per 1M tokens (through this Mac)"
        case .account: price = "subscription (no charge per token, plan limits apply)"
        case .api:
            price = inputPrice == 0 && outputPrice == 0
                ? "price not set"
                : "$\(Self.short(inputPrice)) in, $\(Self.short(outputPrice)) out per 1M tokens"
        }
        return "\(id) | \(name) | \(place.rawValue) | \(tier.title.lowercased()) | \(price) | \(window / 1_000)k window"
            + (tools ? "" : " | no native tool calls")
    }

    private static func short(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

/// How a model has done on a board's work: its finished runs, and how
/// the reviews of them went. Runs that failed because the model could not
/// answer (its limit, say: `Board.modelFailed`) and runs a person or the
/// supervisor stopped say nothing about the model, and are left out.
public struct TrackRecord: Equatable, Sendable {
    public var runs: Int
    public var approved: Int
    public var sentBack: Int
    public var failed: Int

    public init(runs: Int = 0, approved: Int = 0, sentBack: Int = 0, failed: Int = 0) {
        self.runs = runs
        self.approved = approved
        self.sentBack = sentBack
        self.failed = failed
    }

    /// How many judged runs (approved, sent back or failed) it takes
    /// before a record counts.
    public static let enough = 3

    /// The share of its judged runs that were approved, once there are
    /// `enough` of them; nil before.
    public var approvalRate: Double? {
        let judged = approved + sentBack + failed
        return judged >= Self.enough ? Double(approved) / Double(judged) : nil
    }

    /// The record in five steps, 0 (none approved) to 4 (all), for
    /// comparing models; a model with too few runs to tell is in the
    /// middle, so it is neither favored nor held back.
    public var standing: Int {
        approvalRate.map { min(4, Int($0 * 4)) } ?? 2
    }

    /// For the supervisor: "6 runs: 4 approved, 1 sent back, 1 failed".
    public var line: String {
        "\(runs) run\(runs == 1 ? "" : "s"): \(approved) approved, \(sentBack) sent back, \(failed) failed"
    }
}

/// Choosing a model for a task by rule, with no model asked: what is used
/// when the supervisor names none, and what a suggestion is checked
/// against. The rule is the one a careful lead follows: the least costly
/// model that is strong enough for the work, and among models that are
/// equally good for it, the one with the least work already given to it.
public enum ModelRouting {
    /// How many open tasks (not done) are given to each group of models
    /// (`ModelProfile.group`), among the models that can be asked. Tasks
    /// given to a model that is no longer set up are not counted.
    public static func busy(of profiles: [ModelProfile], items: [WorkItem]) -> [String: Int] {
        var groups: [ModelChoice: String] = [:]
        for profile in profiles where groups[profile.choice] == nil {
            groups[profile.choice] = profile.group
        }
        var counts: [String: Int] = [:]
        for item in items where item.status != .done {
            guard let model = item.assignment?.model, let group = groups[model] else { continue }
            counts[group, default: 0] += 1
        }
        return counts
    }

    /// How capable a model is, judged from its name. Makers name their
    /// models by size, so the name is a fair first guess; anything not
    /// recognised counts as balanced.
    public static func tier(ofModelNamed name: String) -> ModelProfile.Tier {
        let text = name.lowercased()
        // The name in its parts: "gemini-2.5-pro" is gemini, 2, 5, pro
        // (so the "mini" inside "gemini" is not taken for a size).
        let words = Set(text.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
        // An open model's size in billions of parameters: "30b", "8b".
        let sizes = words.compactMap { word -> Double? in
            guard word.hasSuffix("b"), word.count > 1 else { return nil }
            return Double(word.dropLast())
        }
        let light: Set<String> = ["haiku", "mini", "nano", "flash", "lite", "small", "tiny", "instant", "fast"]
        let strong: Set<String> = ["opus", "fable", "mythos", "ultra", "pro", "max", "large", "reasoner", "thinking",
                                   "o3", "o4"]
        if !words.isDisjoint(with: light) || sizes.contains(where: { $0 < 10 }) { return .light }
        if !words.isDisjoint(with: strong) || text.contains("gpt-5") || sizes.contains(where: { $0 >= 70 }) {
            return .strong
        }
        return .balanced
    }

    /// How capable a model a task wants: by its kind, how much it matters
    /// and how big it is expected to be.
    public static func demand(of item: WorkItem) -> ModelProfile.Tier {
        var score: Int
        switch item.kind {
        case .docs, .chore, .test: score = 1
        case .bug, .refactor, .feature, .ops: score = 2
        case .research, .design: score = 3
        }
        let estimate = item.estimateTokens ?? 0
        if estimate >= 120_000 { score += 1 } else if estimate > 0, estimate <= 12_000 { score -= 1 }
        if item.priority == .urgent { score += 1 }
        if item.acceptance.count >= 6 { score += 1 }
        return ModelProfile.Tier(rawValue: min(max(score, 1), 3)) ?? .balanced
    }

    /// Each model's record on these tasks (`TrackRecord`), by
    /// `ModelChoice.key`.
    public static func records(of items: [WorkItem]) -> [String: TrackRecord] {
        var found: [String: TrackRecord] = [:]
        for item in items {
            for run in item.runs where !run.isRunning {
                // Stopped by a person or the supervisor, or failed for want
                // of an answer: nothing about how the model works.
                if run.ending == .person || run.ending == .supervisor || Board.modelFailed(run) { continue }
                var record = found[run.model.key] ?? TrackRecord()
                record.runs += 1
                if run.outcome == .failed { record.failed += 1 }
                if let review = run.review {
                    if review.verdict == .approved { record.approved += 1 } else { record.sentBack += 1 }
                }
                found[run.model.key] = record
            }
        }
        return found
    }

    /// The model for a task, and why, in a line a person can read. nil
    /// only when there are no models to choose from. `busy` is how many
    /// open tasks each group of models has already (`busy(of:items:)`):
    /// among models equally good for the task, the least busy is chosen,
    /// so the work is spread rather than all given to the first by name.
    /// `records` is how each model has done on the board's work
    /// (`records(of:)`): between models equally fit and costly, the one
    /// whose work was approved more often comes first.
    public static func suggest(for item: WorkItem, among profiles: [ModelProfile], busy: [String: Int] = [:],
                               records: [String: TrackRecord] = [:])
        -> (profile: ModelProfile, reason: String)? {
        guard !profiles.isEmpty else { return nil }
        let wanted = demand(of: item)
        let estimate = max(item.estimateTokens ?? 30_000, 1)
        // A task has to fit in the model's window with room to work.
        let roomy = profiles.filter { $0.window >= min(estimate / 2, 60_000) }
        let pool = roomy.isEmpty ? profiles : roomy
        let able = pool.filter { $0.tier >= wanted }
        // Nothing strong enough: the strongest there is.
        guard !able.isEmpty else {
            guard let best = pool.max(by: { ($0.tier, -$0.outputPrice) < ($1.tier, -$1.outputPrice) }) else { return nil }
            return (best, "\(wanted.title) work, and \(best.name) is the strongest model set up.")
        }
        // Among those strong enough: one whose cost is known before one
        // billed at a price not set (never taken for free), the least
        // cost, then tools, then the closest fit (no stronger than
        // needed), then the better record on this board, then the least
        // work already given to it, then on this Mac, then by name.
        let chosen = able.min { left, right in
            if left.priceKnown != right.priceKnown { return left.priceKnown }
            let costs = (left.cost(ofTokens: estimate), right.cost(ofTokens: estimate))
            if costs.0 != costs.1 { return costs.0 < costs.1 }
            if left.tools != right.tools { return left.tools }
            if left.tier != right.tier { return left.tier < right.tier }
            let standings = (records[left.choice.key]?.standing ?? 2, records[right.choice.key]?.standing ?? 2)
            if standings.0 != standings.1 { return standings.0 > standings.1 }
            let loads = (busy[left.group] ?? 0, busy[right.group] ?? 0)
            if loads.0 != loads.1 { return loads.0 < loads.1 }
            if left.place != right.place { return left.place == .local }
            return left.name < right.name
        }
        guard let chosen else { return nil }
        let size = wanted == .light ? "Small, well-specified work"
            : (wanted == .balanced ? "Everyday work" : "Wide or delicate work")
        let cost: String
        switch chosen.place {
        case .local: cost = "runs on this Mac at no charge"
        case .account: cost = "is covered by a subscription"
        case .api: cost = "is the least costly API model that is strong enough"
        }
        return (chosen, "\(size): \(chosen.name) \(cost).")
    }
}
