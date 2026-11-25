import Foundation

/// How many runs go on at once across the whole app, set from what is
/// free rather than from a number someone picked: the Mac's processors
/// and memory, what is left of each subscription's plan, and how many
/// tasks could really start (not waiting on another task, or on files
/// another one holds). The owner's own chats always get a slot; board
/// runs share what is left, and what does not fit waits in line, most
/// pressing first (`queueOrder`), until a slot frees.
///
/// Plain rules, with no clock and no system calls of their own: the app
/// hands in what it measured.
public enum RunLimit {
    /// What one run is taken to need, so the Mac stays usable. Agent
    /// tools mostly wait on a model, so half a processor and a gigabyte.
    public static let coresPerRun = 0.5
    public static let memoryPerRun: UInt64 = 1 << 30
    /// A bound whatever the Mac says: a quiet machine never starts a
    /// flood of runs that each spend from a plan.
    public static let most = 16
    /// From this share of a plan used, it takes one run at a time, so
    /// what is left is not split between runs that all stop halfway.
    public static let nearlyUsed = 0.9
    /// What a run that waits for a slot shows.
    public static let waitingWords = "Waiting for a free slot"

    /// The Mac as measured just now.
    public struct Mac: Equatable, Sendable {
        public var cores: Int
        /// The load average over the last minute.
        public var load: Double
        /// Memory that can be had without swapping, in bytes.
        public var freeMemory: UInt64

        public init(cores: Int, load: Double, freeMemory: UInt64) {
            self.cores = cores
            self.load = load
            self.freeMemory = freeMemory
        }
    }

    /// A subscription's plan as its tool last reported it.
    public struct Plan: Equatable, Sendable {
        /// What shares the plan (`ModelProfile.group`).
        public var group: String
        /// As shown: "Codex".
        public var name: String
        /// The share used of its fullest window, 0 to 1; nil when the
        /// tool has not said.
        public var used: Double?
        /// Runs going on with it now.
        public var running: Int

        public init(group: String, name: String, used: Double?, running: Int) {
            self.group = group
            self.name = name
            self.used = used
            self.running = running
        }
    }

    public struct Inputs: Equatable, Sendable {
        public var mac: Mac
        public var plans: [Plan]
        /// The owner's own chats with a task going on.
        public var chats: Int
        /// Board runs going on, and tasks whose copy is being readied.
        public var boardRuns: Int
        /// Each task that could start now, by the plan its model is on
        /// (nil for a model on no plan).
        public var ready: [String?]
        /// Tasks in To do that wait on another task or on files another
        /// task holds.
        public var blocked: Int

        public init(mac: Mac, plans: [Plan] = [], chats: Int = 0, boardRuns: Int = 0,
                    ready: [String?] = [], blocked: Int = 0) {
            self.mac = mac
            self.plans = plans
            self.chats = chats
            self.boardRuns = boardRuns
            self.ready = ready
            self.blocked = blocked
        }
    }

    /// The limit as it stands, and why, in a line for the board's header.
    public struct Slots: Equatable, Sendable {
        /// Runs at once across the app now, chats and board runs together.
        public var limit: Int
        /// Of those, how many board runs may hold.
        public var forBoards: Int
        /// "4 running: Codex at its limit, 2 tasks blocked".
        public var reason: String

        public init(limit: Int, forBoards: Int, reason: String) {
            self.limit = limit
            self.forBoards = forBoards
            self.reason = reason
        }

        /// Slots free for board runs beside `boardRuns` going on.
        public func free(boardRuns: Int) -> Int { max(0, forBoards - boardRuns) }
    }

    /// How many more runs the Mac takes now. The runs going on are in
    /// the load already, so this is only the room beside them.
    public static func macRoom(_ mac: Mac) -> Int {
        let cpu = Int(((Double(mac.cores) - mac.load) / coresPerRun).rounded(.down))
        let memory = Int(min(mac.freeMemory / memoryPerRun, UInt64(most)))
        return max(0, min(cpu, memory))
    }

    /// How many more runs a plan takes beside its own, or nil when it
    /// does not hold any back.
    public static func planRoom(_ plan: Plan) -> Int? {
        guard let used = plan.used else { return nil }
        if used >= 1 { return 0 }
        if used >= nearlyUsed { return max(0, 1 - plan.running) }
        return nil
    }

    /// The limit, from what is free and what could start.
    public static func slots(_ inputs: Inputs) -> Slots {
        let running = inputs.chats + inputs.boardRuns
        let mac = macRoom(inputs.mac)
        var room: [String: Int] = [:]
        for plan in inputs.plans {
            guard let left = planRoom(plan) else { continue }
            room[plan.group] = min(room[plan.group] ?? left, left)
        }
        var startable = 0
        for group in inputs.ready {
            guard let group, let left = room[group] else {
                startable += 1
                continue
            }
            if left > 0 {
                startable += 1
                room[group] = left - 1
            }
        }
        var wanted = min(startable, mac)
        // With nothing going on, one run always may: a busy Mac slows
        // the work down, it never stops all of it.
        if running == 0 { wanted = max(wanted, min(1, startable)) }
        // Runs going on are never counted out of their slot.
        let limit = max(1, running, min(most, running + wanted))
        let forBoards = max(0, limit - inputs.chats)

        var parts: [String] = []
        for plan in inputs.plans {
            guard let used = plan.used, used >= nearlyUsed else { continue }
            let words = plan.name + (used >= 1 ? " at its limit" : " nearly at its limit")
            if !parts.contains(words) { parts.append(words) }
        }
        if mac < startable, running + mac < most {
            let cpu = Int(((Double(inputs.mac.cores) - inputs.mac.load) / coresPerRun).rounded(.down))
            let memory = Int(min(inputs.mac.freeMemory / memoryPerRun, UInt64(most)))
            parts.append(cpu <= memory ? "the Mac's processors are busy" : "memory is short on the Mac")
        } else if running + startable > most {
            parts.append("\(most) is the most at once")
        }
        if inputs.blocked > 0 {
            parts.append(inputs.blocked == 1 ? "1 task blocked" : "\(inputs.blocked) tasks blocked")
        }
        let head = running == 0 ? "Nothing running" : "\(running) running"
        let reason: String
        if !parts.isEmpty {
            reason = head + ": " + parts.joined(separator: ", ")
        } else if limit > running {
            reason = head + ", room for \(limit - running) more"
        } else {
            reason = head
        }
        return Slots(limit: limit, forBoards: forBoards, reason: reason)
    }

    /// How many more runs a board may start: the app's free slots, kept
    /// within the board's own cost ceiling when one is set.
    public static func boardRoom(free: Int, running: Int, ceiling: Int?) -> Int {
        guard let ceiling else { return max(0, free) }
        return max(0, min(free, ceiling - running))
    }

    /// The order tasks waiting for a slot start in: urgent, high, medium,
    /// low, and between equals the lower task number first.
    public static func queueOrder(_ items: [WorkItem]) -> [WorkItem] {
        items.sorted { left, right in
            if left.priority != right.priority { return left.priority > right.priority }
            return left.number < right.number
        }
    }

    /// Who takes a task's run.
    public enum Seat: Equatable, Sendable {
        /// Its role has no specialists (a board without a team yet, or a
        /// task without a role): any slot does.
        case anyone
        /// This free specialist of its role.
        case specialist(UUID)
        /// Every specialist of its role is busy: it waits for one.
        case busy
    }

    /// The seat for a task's run, leaving out specialists in `taken`
    /// (given a run in the same pass). A specialist holds one run at a
    /// time (ADR 0016).
    public static func seat(for item: WorkItem, on board: Board, taken: Set<UUID> = []) -> Seat {
        guard let role = item.role else { return .anyone }
        let team = board.activeSpecialists(of: role)
        guard !team.isEmpty else { return .anyone }
        let busy = Set(board.allItems.compactMap { $0.activeRun?.specialist }).union(taken)
        if let free = team.first(where: { !busy.contains($0.id) }) { return .specialist(free.id) }
        return .busy
    }

    /// Which of the tasks that could start take the free slots: the most
    /// pressing first (`queueOrder`), one per free specialist of each
    /// task's role. Specialists in `held` are seated already, for runs
    /// whose copy is being readied.
    public static func pick(_ ready: [WorkItem], on board: Board, slots: Int,
                            held: Set<UUID> = []) -> [(item: WorkItem, seat: Seat)] {
        var picked: [(item: WorkItem, seat: Seat)] = []
        var taken = held
        for item in queueOrder(ready) where picked.count < slots {
            let found = Self.seat(for: item, on: board, taken: taken)
            switch found {
            case .busy: continue
            case .specialist(let id): taken.insert(id)
            case .anyone: break
            }
            picked.append((item, found))
        }
        return picked
    }
}