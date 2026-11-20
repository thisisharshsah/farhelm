import Foundation

/// What one request to an engine used, with whom it was for. The app
/// keeps these as they happen; the ledger adds them up.
public struct UsageEntry: Equatable, Sendable {
    public var date: Date
    /// The chat the request was made in.
    public var conversation: UUID?
    /// The board task it worked on, when a run made it.
    public var workItem: UUID?
    public var project: UUID?
    public var engine: String
    public var model: String
    /// What it was for: "Agent", "Supervisor", "Review".
    public var purpose: String
    /// Input billed in full, input read from the engine's cache, input
    /// written to it, and output, in tokens.
    public var input: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var output: Int
    /// What it cost at the prices in effect, in dollars.
    public var cost: Double
    /// Counted by the engine; otherwise estimated from the text's length.
    public var exact: Bool
    public var seconds: Double

    public init(date: Date, conversation: UUID? = nil, workItem: UUID? = nil, project: UUID? = nil,
                engine: String, model: String, purpose: String, input: Int, cacheRead: Int = 0, cacheWrite: Int = 0,
                output: Int, cost: Double = 0, exact: Bool = true, seconds: Double = 0) {
        self.date = date
        self.conversation = conversation
        self.workItem = workItem
        self.project = project
        self.engine = engine
        self.model = model
        self.purpose = purpose
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
        self.cost = cost
        self.exact = exact
        self.seconds = seconds
    }

    public var tokens: Int { input + cacheRead + cacheWrite + output }
}

/// Requests added up.
public struct UsageTotal: Equatable, Sendable {
    public var requests = 0
    public var input = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var output = 0
    public var cost = 0.0
    public var seconds = 0.0
    /// How many of the requests were estimated, not counted by the engine.
    public var estimated = 0

    public init() {}

    public var tokens: Int { input + cacheRead + cacheWrite + output }
    /// Everything that went in: full-price, cached and written to cache.
    public var inputTokens: Int { input + cacheRead + cacheWrite }
    public var isEmpty: Bool { requests == 0 }
    /// Every request was counted by its engine.
    public var isExact: Bool { estimated == 0 }

    public mutating func add(_ entry: UsageEntry) {
        requests += 1
        input += entry.input
        cacheRead += entry.cacheRead
        cacheWrite += entry.cacheWrite
        output += entry.output
        cost += entry.cost
        seconds += entry.seconds
        if !entry.exact { estimated += 1 }
    }

    public mutating func add(_ other: UsageTotal) {
        requests += other.requests
        input += other.input
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
        output += other.output
        cost += other.cost
        seconds += other.seconds
        estimated += other.estimated
    }
}

/// One line of a breakdown: a name and what was used under it.
public struct UsageLine: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var total: UsageTotal

    public init(id: String, name: String, total: UsageTotal) {
        self.id = id
        self.name = name
        self.total = total
    }
}

/// Every request made for a project, added up the ways a person asks
/// about cost: in all, per chat, per task, per model, per purpose, per day.
public struct Ledger: Equatable, Sendable {
    public let entries: [UsageEntry]
    public let total: UsageTotal

    public init(_ entries: [UsageEntry]) {
        self.entries = entries
        var sum = UsageTotal()
        for entry in entries { sum.add(entry) }
        total = sum
    }

    private func grouped<Key: Hashable>(by key: (UsageEntry) -> Key?) -> [Key: UsageTotal] {
        var sums: [Key: UsageTotal] = [:]
        for entry in entries {
            guard let name = key(entry) else { continue }
            sums[name, default: UsageTotal()].add(entry)
        }
        return sums
    }

    /// Lines with the most tokens first; equal ones in name order, so the
    /// list never shuffles between two looks at it.
    private static func ranked(_ lines: [UsageLine]) -> [UsageLine] {
        lines.sorted { ($1.total.tokens, $0.name) < ($0.total.tokens, $1.name) }
    }

    /// What each chat used.
    public var byConversation: [UUID: UsageTotal] {
        grouped { entry -> UUID? in entry.conversation }
    }

    /// What each task used: every request filed under it.
    public var byWorkItem: [UUID: UsageTotal] {
        grouped { entry -> UUID? in entry.workItem }
    }

    /// What some chats used together.
    public func total(of conversations: Set<UUID>) -> UsageTotal {
        var sum = UsageTotal()
        for entry in entries {
            if let chat = entry.conversation, conversations.contains(chat) { sum.add(entry) }
        }
        return sum
    }

    /// What one run used: the requests made in its chat while it ran.
    /// A task's runs share one chat, so the time tells them apart.
    public func total(of run: WorkRun, now: Date) -> UsageTotal {
        let end = run.endedAt ?? now
        var sum = UsageTotal()
        for entry in entries where entry.conversation == run.conversation
            && entry.date >= run.startedAt && entry.date <= end {
            sum.add(entry)
        }
        return sum
    }

    /// What a task used: requests filed under it, and requests made in
    /// its runs' chats that were not filed under any task.
    public func total(of item: WorkItem) -> UsageTotal {
        let chats = Set(item.conversations)
        var sum = UsageTotal()
        for entry in entries {
            if entry.workItem == item.id {
                sum.add(entry)
            } else if entry.workItem == nil, let chat = entry.conversation, chats.contains(chat) {
                sum.add(entry)
            }
        }
        return sum
    }

    /// What each model used, most first. `name` gives a model's name as
    /// shown, from its engine and its own name.
    public func byModel(name: (_ engine: String, _ model: String) -> String) -> [UsageLine] {
        struct ModelKey: Hashable {
            let engine: String
            let model: String
        }
        let sums = grouped { entry -> ModelKey? in ModelKey(engine: entry.engine, model: entry.model) }
        return Self.ranked(sums.map { key, total in
            UsageLine(id: key.engine + "|" + key.model, name: name(key.engine, key.model), total: total)
        })
    }

    /// What each kind of work used, most first.
    public var byPurpose: [UsageLine] {
        let sums = grouped { entry -> String? in entry.purpose }
        return Self.ranked(sums.map { UsageLine(id: $0.key, name: $0.key, total: $0.value) })
    }

    /// What was used each day, oldest first.
    public func byDay(calendar: Calendar) -> [(day: Date, total: UsageTotal)] {
        let sums = grouped { entry -> Date? in calendar.startOfDay(for: entry.date) }
        return sums.map { (day: $0.key, total: $0.value) }.sorted { $0.day < $1.day }
    }

    /// The share of the spend that went on supervising (planning,
    /// reviews, reports) and not on the work itself, 0 to 1.
    public func overheadShare(purposes: Set<String>) -> Double {
        guard total.tokens > 0 else { return 0 }
        let overhead = entries.reduce(0) { $0 + (purposes.contains($1.purpose) ? $1.tokens : 0) }
        return Double(overhead) / Double(total.tokens)
    }
}

/// Where spending stands against a budget.
public enum BudgetState: Equatable, Sendable {
    /// No budget is set.
    case none
    /// Within it. The share used, 0 to 1.
    case within(Double)
    /// Most of it is used (four fifths or more).
    case near(Double)
    /// All of it is used, or more.
    case over(Double)

    /// The share of the budget used, when one is set.
    public var fraction: Double? {
        switch self {
        case .none: return nil
        case .within(let share), .near(let share), .over(let share): return share
        }
    }

    public var isOver: Bool {
        if case .over = self { return true }
        return false
    }
}

extension Budget {
    /// The share at which a budget counts as nearly used.
    public static let nearShare = 0.8

    /// Where spending stands. With both limits set, the one closer to
    /// being used up decides.
    public func state(spent: UsageTotal) -> BudgetState {
        var shares: [Double] = []
        if let tokens, tokens > 0 { shares.append(Double(spent.tokens) / Double(tokens)) }
        if let dollars, dollars > 0 { shares.append(spent.cost / dollars) }
        guard let share = shares.max() else { return .none }
        if share >= 1 { return .over(share) }
        if share >= Self.nearShare { return .near(share) }
        return .within(share)
    }

    /// Whether an estimate still fits in what is left of the token limit.
    public func fits(estimate tokens: Int, spent: UsageTotal) -> Bool {
        guard let limit = self.tokens, limit > 0 else { return true }
        return spent.tokens + max(tokens, 0) <= limit
    }
}
