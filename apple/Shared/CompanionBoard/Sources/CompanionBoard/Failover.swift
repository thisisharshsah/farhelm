import Foundation

/// What is done when the model a project's supervisor is asked of cannot
/// answer for now: it is out of its limit, asked too often, overloaded,
/// or out of reach. That model is rested for a while, and the next model
/// that can be asked answers instead (`order`); once the rest is over,
/// the chosen model is asked again. The same pattern as a circuit
/// breaker with a failover list.
///
/// Plain rules, with no clock and no network of their own: the app
/// hands in what the model answered and the time.
public enum Failover {
    /// Why a model cannot be asked for now.
    public enum Trouble: String, Equatable, Sendable {
        /// Its plan, quota or credit is used up.
        case limit
        /// Too many requests in a short time.
        case rate
        /// Its service is overloaded or down for a moment.
        case busy
        /// It cannot be reached: a model on this Mac that is not running,
        /// or no network.
        case unreachable

        /// How long it is rested when what it answered does not say.
        public var rest: TimeInterval {
            switch self {
            case .limit: return 3_600
            case .rate, .busy: return 120
            case .unreachable: return 300
            }
        }

        /// In words that finish "Claude Code is ...".
        public var words: String {
            switch self {
            case .limit: return "out of its limit"
            case .rate: return "rate limited"
            case .busy: return "overloaded"
            case .unreachable: return "out of reach"
            }
        }
    }

    /// Words that say a plan, quota or credit is used up. Read before the
    /// words for rates: "insufficient_quota" comes with a rate's status.
    private static let limitWords = [
        "usage limit", "hit your limit", "limit reached", "quota", "credit balance", "out of credits",
        "billing", "plan limit", "weekly limit", "payment required"
    ]
    /// The same in the words tools use now, with the limit's name in the
    /// middle: "You've reached your Fable limit", "hit your Opus limit".
    private static let limitPhrase = #"\b(reached|hit) (your|the) [a-z0-9 .\-]{0,40}limit"#
    private static let rateWords = ["rate limit", "rate_limit", "ratelimit", "too many requests", "resource_exhausted"]
    private static let busyWords = [
        "overloaded", "over capacity", "at capacity", "temporarily unavailable", "service unavailable"
    ]
    private static let unreachableWords = [
        "not reachable", "cannot reach", "could not connect", "cannot connect", "connection refused",
        "connection was lost", "appears to be offline", "not connected to the internet", "hostname could not be found",
        "timed out"
    ]

    /// What an error from a model comes to: why it cannot be asked for
    /// now, and until when. nil for an error another model would meet as
    /// well (a request that is wrong, a key that is refused): that one is
    /// shown, and no other model is asked. `status` is the HTTP status
    /// when there was one; `message` is what came with the error.
    public static func trouble(status: Int?, message: String, now: Date) -> (trouble: Trouble, until: Date)? {
        let text = message.lowercased()
        let found: Trouble
        if limitWords.contains(where: { text.contains($0) }) || status == 402
            || text.range(of: limitPhrase, options: .regularExpression) != nil {
            found = .limit
        } else if rateWords.contains(where: { text.contains($0) }) || status == 429 {
            found = .rate
        } else if busyWords.contains(where: { text.contains($0) }) || [502, 503, 504, 529].contains(status ?? 0) {
            found = .busy
        } else if unreachableWords.contains(where: { text.contains($0) }) {
            found = .unreachable
        } else {
            return nil
        }
        // A tool that says when it starts over, as "…limit reached|1767225600".
        if let back = resetTime(in: message), back > now {
            return (found, back)
        }
        return (found, now.addingTimeInterval(found.rest))
    }

    /// A time since 1970 written after a bar, the way a tool names when
    /// its limit starts over; nil when there is none.
    static func resetTime(in message: String) -> Date? {
        guard let bar = message.lastIndex(of: "|") else { return nil }
        let digits = message[message.index(after: bar)...].prefix { $0.isNumber }
        guard digits.count >= 9, digits.count <= 13, let stamp = Double(digits) else { return nil }
        return Date(timeIntervalSince1970: digits.count > 10 ? stamp / 1_000 : stamp)
    }

    /// The models to ask, in turn, when `chosen` cannot answer. First
    /// those as strong as it, the ones with no charge per token (on this
    /// Mac, or under a subscription) before those billed by use, each in
    /// the order they are listed; then the weaker ones, strongest first.
    /// The chosen one and any in `resting` (by `ModelChoice.key`) are
    /// left out. A chosen model that is not listed counts as balanced.
    public static func order(after chosen: ModelChoice, among profiles: [ModelProfile],
                             resting: Set<String>) -> [ModelProfile] {
        let wanted = profiles.first(where: { $0.choice == chosen })?.tier ?? .balanced
        let others = profiles.enumerated().filter { entry in
            entry.element.choice != chosen && !resting.contains(entry.element.choice.key)
        }
        let ranked = others.sorted { left, right in
            let first = left.element
            let second = right.element
            let firstAble = first.tier >= wanted
            let secondAble = second.tier >= wanted
            if firstAble != secondAble { return firstAble }
            if !firstAble, first.tier != second.tier { return first.tier > second.tier }
            let firstBilled = first.place == .api
            let secondBilled = second.place == .api
            if firstBilled != secondBilled { return !firstBilled }
            return left.offset < right.offset
        }
        return ranked.map { $0.element }
    }

    /// The model a task's run is started with by itself while the one it
    /// was given rests: the first of `order` that is as able as `chosen`
    /// and, when `chosen` has no charge per token, has none either. So a
    /// model that stands in never makes the work weaker, and never starts
    /// spending by use that nobody chose. nil when there is none: the
    /// task waits for its own model.
    public static func standIn(for chosen: ModelProfile, among profiles: [ModelProfile],
                               resting: Set<String>) -> ModelProfile? {
        order(after: chosen.choice, among: profiles, resting: resting).first { profile in
            profile.tier >= chosen.tier && (chosen.place == .api || profile.place != .api)
        }
    }

    // MARK: A subscription's windows

    /// The model a window of a subscription's plan counts alone, as the
    /// tool names the window: "seven_day_opus" is the week's limit for
    /// Opus. nil for a window of the whole plan ("five_hour", "seven_day",
    /// "primary").
    public static func windowModel(_ window: String) -> String? {
        let id = window.lowercased()
        for length in ["five_hour_", "seven_day_"] where id.hasPrefix(length) && id.count > length.count {
            return id.dropFirst(length.count).replacingOccurrences(of: "_", with: " ")
        }
        return nil
    }

    /// Whether a window of a subscription's plan that is used up keeps
    /// one of the tool's models from answering. A window of the whole
    /// plan keeps every model. A window of one model keeps the model it
    /// names: one that `names` mention (its id, the tool's name for it,
    /// what the tool says of it), and the tool's own pick while nothing
    /// is known of what that is (`names` all empty). A window naming a
    /// model that none of the tool's models is said to be (`toolNames`)
    /// is taken as the whole plan's, since what it keeps cannot be told.
    public static func window(_ window: String, keeps names: [String], toolNames: [String]) -> Bool {
        guard let model = windowModel(window) else { return true }
        func mentions(_ text: String) -> Bool { text.lowercased().contains(model) }
        guard toolNames.contains(where: mentions) else { return true }
        return names.contains(where: mentions) || names.allSatisfy { $0.isEmpty }
    }
}
