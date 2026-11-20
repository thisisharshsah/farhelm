import Foundation

/// Something a project is to achieve. A board works toward one goal at a
/// time and shows that goal's tasks. The goals before it are kept, each
/// with its tasks and the time it was worked toward, as the project's
/// history, and any of them can be gone back to.
public struct BoardGoal: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// The goal being worked toward. A board has exactly one.
        case active
        /// Left with every one of its tasks done.
        case reached
        /// Left with work still open, or with nothing planned for it.
        case setAside = "set_aside"

        public var title: String {
            switch self {
            case .active: return "Active"
            case .reached: return "Reached"
            case .setAside: return "Set aside"
            }
        }
    }

    /// A stretch of time a goal was the one being worked toward. It has
    /// no end while the goal still is.
    public struct Span: Codable, Equatable, Sendable {
        public var start: Date
        public var end: Date?

        public init(start: Date, end: Date? = nil) {
            self.start = start
            self.end = end
        }
    }

    public var id: UUID
    /// Its number on this board, counted up from 1: G-2.
    public var number: Int
    /// What is to be achieved, in a sentence or two. Empty until it is said.
    public var text: String
    public var status: Status
    /// When it was worked toward, oldest first: more than one stretch
    /// when it was gone back to.
    public var spans: [Span]

    /// A goal that is worked toward from `startedAt` on.
    public init(id: UUID = UUID(), number: Int, text: String, startedAt: Date) {
        self.id = id
        self.number = number
        self.text = text
        status = .active
        spans = [Span(start: startedAt)]
    }

    /// The name it goes by: "G-2".
    public var key: String { "G-\(number)" }

    public var isActive: Bool { status == .active }

    /// When work toward it first began.
    public var startedAt: Date? { spans.first?.start }

    /// When it was last left, or nil while it is being worked toward.
    public var closedAt: Date? { isActive ? nil : spans.last?.end }

    private enum CodingKeys: String, CodingKey {
        case id, number, text, status, spans
    }

    /// Read field by field, so a goal saved before a field existed, or
    /// with a status this version does not know, still loads.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        number = try values.decodeIfPresent(Int.self, forKey: .number) ?? 1
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        let saved = try values.decodeIfPresent(String.self, forKey: .status) ?? ""
        status = Status(rawValue: saved) ?? .setAside
        spans = try values.decodeIfPresent([Span].self, forKey: .spans) ?? []
    }

    /// It becomes the goal being worked toward.
    mutating func open(at now: Date) {
        status = .active
        if spans.isEmpty || spans.last?.end != nil { spans.append(Span(start: now)) }
    }

    /// It stops being the goal being worked toward.
    mutating func close(_ status: Status, at now: Date) {
        self.status = status
        if let last = spans.indices.last, spans[last].end == nil { spans[last].end = now }
    }
}

// MARK: - A board's goals

extension Board {
    /// The goal being worked toward.
    public var current: BoardGoal {
        goals.first(where: { $0.id == currentGoal }) ?? goals.last
            ?? BoardGoal(id: currentGoal, number: 1, text: "", startedAt: createdAt)
    }

    /// What the project is to achieve now, in a sentence or two. Empty
    /// until it is said.
    public var goal: String { current.text }

    /// The goals before this one, the one left last first.
    public var earlierGoals: [BoardGoal] {
        goals.filter { $0.id != currentGoal }.sorted { left, right in
            let leftEnd = left.closedAt ?? Date.distantPast
            let rightEnd = right.closedAt ?? Date.distantPast
            return leftEnd != rightEnd ? leftEnd > rightEnd : left.number > right.number
        }
    }

    /// A goal's tasks, in the order they were made.
    public func items(of goal: UUID) -> [WorkItem] {
        allItems.filter { $0.goal == goal }.sorted { $0.number < $1.number }
    }

    /// How many of a goal's tasks are done, and how many it has.
    public func progress(of goal: UUID) -> (done: Int, all: Int) {
        var done = 0
        var all = 0
        for item in allItems where item.goal == goal {
            all += 1
            if item.status == .done { done += 1 }
        }
        return (done, all)
    }

    /// The tasks of the goal being worked toward that are not done yet.
    public var unfinished: [WorkItem] { items.filter { $0.status != .done } }

    /// Every task of the goal being worked toward is done, and it has some.
    public var goalReached: Bool {
        let tasks = items
        return !tasks.isEmpty && tasks.allSatisfy { $0.status == .done }
    }

    /// Says what the goal being worked toward is: for the first time, or
    /// in better words. The goal stays the same goal. Returns false when
    /// the words are the ones it has.
    @discardableResult
    public mutating func setGoal(_ text: String, by actor: BoardActor, now: Date) -> Bool {
        let text = BoardRules.goal(text)
        guard let index = goals.firstIndex(where: { $0.id == currentGoal }), goals[index].text != text else {
            return false
        }
        goals[index].text = text
        log(text.isEmpty ? "Cleared the goal" : "Set the goal", by: actor, now: now)
        return true
    }

    /// The goal at `index` stops being worked toward. It is kept as
    /// reached when it has tasks and every one is done, otherwise as set
    /// aside. Returns how it was kept.
    private mutating func leave(_ index: Int, now: Date) -> BoardGoal.Status {
        let id = goals[index].id
        let tasks = allItems.filter { $0.goal == id }
        let done = !tasks.isEmpty && tasks.allSatisfy({ $0.status == .done })
        let status: BoardGoal.Status = done ? .reached : .setAside
        goals[index].close(status, at: now)
        return status
    }

    /// Turns the board to a new goal. The goal before it is kept with its
    /// tasks (see `leave`), and the board then shows the new goal's
    /// tasks: none, or with `bringUnfinished` the ones the goal before
    /// left open, which move to the new goal. A goal that was never said
    /// and has no tasks has nothing to keep: it simply becomes this one.
    /// Returns the goal now worked toward, or nil when `text` says nothing.
    @discardableResult
    public mutating func startGoal(_ text: String, bringUnfinished: Bool = false, by actor: BoardActor,
                                   now: Date) -> BoardGoal? {
        let text = BoardRules.goal(text)
        guard !text.isEmpty, let index = goals.firstIndex(where: { $0.id == currentGoal }) else { return nil }
        let before = goals[index]
        let stillOpen = Set(unfinished.map(\.id))
        if before.text.isEmpty, !allItems.contains(where: { $0.goal == before.id }) {
            goals[index].text = text
            log("Set the goal", by: actor, now: now)
            return goals[index]
        }
        let kept = leave(index, now: now)
        let goal = BoardGoal(number: (goals.map(\.number).max() ?? 0) + 1, text: text, startedAt: now)
        goals.append(goal)
        currentGoal = goal.id
        var brought = 0
        if bringUnfinished {
            for place in allItems.indices where stillOpen.contains(allItems[place].id) {
                allItems[place].goal = goal.id
                allItems[place].updatedAt = now
                brought += 1
            }
        }
        var line = "Started \(goal.key); \(before.key) was \(kept == .reached ? "reached" : "set aside")"
        if brought > 0 { line += ", and \(brought == 1 ? "1 open task" : "\(brought) open tasks") came along" }
        log(line, by: actor, now: now)
        return goal
    }

    /// Goes back to an earlier goal: it is worked toward again, with its
    /// tasks as they were left, and the goal left for it is kept the way
    /// a new goal would keep it. Returns false when there is no such
    /// earlier goal.
    @discardableResult
    public mutating func resumeGoal(_ id: UUID, by actor: BoardActor, now: Date) -> Bool {
        guard id != currentGoal, goals.contains(where: { $0.id == id }),
              let present = goals.firstIndex(where: { $0.id == currentGoal }) else { return false }
        if goals[present].text.isEmpty, !allItems.contains(where: { $0.goal == currentGoal }) {
            // Nothing was said or planned for it: there is nothing to keep.
            goals.remove(at: present)
        } else {
            _ = leave(present, now: now)
        }
        guard let index = goals.firstIndex(where: { $0.id == id }) else { return false }
        goals[index].open(at: now)
        currentGoal = id
        log("Went back to \(goals[index].key)", by: actor, now: now)
        return true
    }

    /// Takes an earlier goal out of the history. Only one with no tasks
    /// can go: work that was planned or done is part of the record.
    @discardableResult
    public mutating func removeGoal(_ id: UUID, by actor: BoardActor, now: Date) -> Bool {
        guard id != currentGoal, let index = goals.firstIndex(where: { $0.id == id }),
              !allItems.contains(where: { $0.goal == id }) else { return false }
        let gone = goals.remove(at: index)
        log("Removed \(gone.key), which had no tasks", by: actor, now: now)
        return true
    }

    // MARK: What each goal cost

    /// The goal the board was working toward at a moment: the one it had
    /// turned to last by then. Before the first of them, the first.
    public func goalID(at date: Date) -> UUID {
        var found: (start: Date, id: UUID)?
        for goal in goals {
            for span in goal.spans where span.start <= date {
                if let known = found, known.start > span.start { continue }
                found = (span.start, goal.id)
            }
        }
        return found?.id ?? goals.min(by: { $0.number < $1.number })?.id ?? currentGoal
    }

    /// What each goal used; together they are everything in the ledger.
    /// A request made for a task counts toward the goal the task is
    /// under. Any other (the supervisor's planning, talk in the project's
    /// chats) counts toward the goal the board was working toward when
    /// it was made.
    public func usageByGoal(_ ledger: Ledger) -> [UUID: UsageTotal] {
        var ofTask: [UUID: UUID] = [:]
        var ofChat: [UUID: UUID] = [:]
        for item in allItems {
            guard let goal = item.goal else { continue }
            ofTask[item.id] = goal
            for chat in item.conversations { ofChat[chat] = goal }
        }
        var sums: [UUID: UsageTotal] = [:]
        for entry in ledger.entries {
            let goal = entry.workItem.flatMap { ofTask[$0] }
                ?? entry.conversation.flatMap { ofChat[$0] }
                ?? goalID(at: entry.date)
            sums[goal, default: UsageTotal()].add(entry)
        }
        return sums
    }
}
