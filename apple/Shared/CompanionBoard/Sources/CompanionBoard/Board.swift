import Foundation

/// The most a project's work may cost. Either limit may be left out.
public struct Budget: Codable, Equatable, Sendable {
    /// Tokens, counting input, cached input and output alike.
    public var tokens: Int?
    public var dollars: Double?

    public init(tokens: Int? = nil, dollars: Double? = nil) {
        self.tokens = tokens
        self.dollars = dollars
    }

    public var isSet: Bool { (tokens ?? 0) > 0 || (dollars ?? 0) > 0 }
}

/// How a project's board is run.
public struct BoardSettings: Codable, Equatable, Sendable {
    /// The supervisor starts tasks that are ready, without being asked.
    public var autopilot: Bool
    /// What used to be the board's own Runs at Once. Runs no longer
    /// follow it: how many go on at once is the app's limit, set from
    /// what is free (`RunLimit`). It is kept so boards saved before still
    /// read, and it sized the team when a board first had one.
    public var parallel: Int
    /// An optional ceiling on this board's runs at once, to keep its cost
    /// down; nil leaves it to the app's limit. It only ever lowers it.
    public var runCeiling: Int?
    /// A finished run is checked against the task before it can be done.
    public var reviewGate: Bool
    /// The most tasks wanted in progress at once, or nil for no limit.
    public var wipLimit: Int?
    /// How much a run does without asking (the app's own access levels),
    /// or nil to follow the setting for new chats.
    public var runAccess: String?
    /// Wherever a person is asked to choose (a step that needs a yes, an
    /// agent's question, a task waiting in Review), the supervisor says
    /// which answer it recommends. Each time is a request to its model.
    public var advice: Bool
    /// The most specialists the board may have (Team Size).
    public var teamLimit: Int

    /// The answer the supervisor recommends is taken as the person's,
    /// wherever its answer may be (see `Delegation`): it is not waited
    /// for the person to pick it. Off until switched on, per project.
    /// It needs `advice`: what is not recommended cannot be taken.
    public var followsAdvice: Bool
    /// Each task's runs work in a copy of the repository of the task's
    /// own, on a branch of its own, and its work is merged into the
    /// project's branch once it is approved (`WorkingCopy`). On unless
    /// switched off. Where the project's folder is not in a git
    /// repository with a commit on a branch, runs work in the folder.
    public var copyPerTask: Bool

    /// Runs at once on a new board: as many as the app runs at once by
    /// default, so work spread across models goes on side by side.
    public static let defaultParallel = 3

    public init(autopilot: Bool = false, parallel: Int = BoardSettings.defaultParallel, reviewGate: Bool = true,
                wipLimit: Int? = nil, runCeiling: Int? = nil,
                runAccess: String? = nil, advice: Bool = true, followsAdvice: Bool = false,
                copyPerTask: Bool = true, teamLimit: Int = TeamRules.defaultTeamLimit) {
        self.autopilot = autopilot
        self.parallel = parallel
        self.reviewGate = reviewGate
        self.wipLimit = wipLimit
        self.runCeiling = runCeiling.flatMap { $0 > 0 ? $0 : nil }
        self.runAccess = runAccess
        self.advice = advice
        self.followsAdvice = followsAdvice
        self.copyPerTask = copyPerTask
        self.teamLimit = teamLimit
    }

    /// The supervisor answers in the person's place: it recommends, and
    /// what it recommends is taken.
    public var supervisorAnswers: Bool { advice && followsAdvice }

    /// Tasks that are ready start without a person: Autopilot is on, or
    /// the supervisor runs the board (it answers in the person's place,
    /// so it also starts the work it planned).
    public var startsWorkByItself: Bool { autopilot || supervisorAnswers }

    private enum CodingKeys: String, CodingKey {
        case autopilot, parallel, reviewGate, wipLimit, runCeiling, runAccess, advice, followsAdvice, copyPerTask
        case teamLimit
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        autopilot = try values.decodeIfPresent(Bool.self, forKey: .autopilot) ?? false
        parallel = try values.decodeIfPresent(Int.self, forKey: .parallel) ?? Self.defaultParallel
        reviewGate = try values.decodeIfPresent(Bool.self, forKey: .reviewGate) ?? true
        wipLimit = try values.decodeIfPresent(Int.self, forKey: .wipLimit)
        runCeiling = try values.decodeIfPresent(Int.self, forKey: .runCeiling).flatMap { $0 > 0 ? $0 : nil }
        runAccess = try values.decodeIfPresent(String.self, forKey: .runAccess)
        advice = try values.decodeIfPresent(Bool.self, forKey: .advice) ?? true
        followsAdvice = try values.decodeIfPresent(Bool.self, forKey: .followsAdvice) ?? false
        copyPerTask = try values.decodeIfPresent(Bool.self, forKey: .copyPerTask) ?? true
        teamLimit = try values.decodeIfPresent(Int.self, forKey: .teamLimit)
            ?? (try values.decodeIfPresent(Int.self, forKey: .parallel) ?? TeamRules.defaultTeamLimit)
    }
}

/// Who changed something on the board.
public enum BoardActor: String, Codable, Sendable {
    case person, supervisor, run, autopilot

    public var title: String {
        switch self {
        case .person: return "You"
        case .supervisor: return "Supervisor"
        case .run: return "Run"
        case .autopilot: return "Autopilot"
        }
    }
}

/// One line of the board's history: who did what, and to which task.
public struct Activity: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var actor: BoardActor
    public var text: String
    /// The task's number, when the line is about one.
    public var item: Int?

    public init(id: UUID = UUID(), date: Date, actor: BoardActor, text: String, item: Int? = nil) {
        self.id = id
        self.date = date
        self.actor = actor
        self.text = text
        self.item = item
    }
}

/// A project's board: its goals, the tasks of each and how they stand,
/// what was done to it and by whom, and how it is run. It works toward one
/// goal at a time and shows that goal's tasks; the goals before it are
/// kept with theirs (see `BoardGoal`). Every change goes through the
/// methods here, which keep its rules (see `BoardRules`) and write its
/// history; the time is handed in, never read from a clock.
public struct Board: Codable, Equatable, Sendable {
    /// The shape this was saved in, for changes to it later.
    public var version: Int
    public var project: UUID
    /// The ids its project had before, when the board was given to
    /// another (see `rehome`): what was asked of a model under them is
    /// still this board's.
    public internal(set) var earlierProjects: [UUID]
    /// Every goal the project has had, oldest first. Never empty: a new
    /// board starts with one that says nothing yet.
    public internal(set) var goals: [BoardGoal]
    /// The goal being worked toward. The board shows its tasks (`items`).
    public internal(set) var currentGoal: UUID
    /// The tasks of every goal, the earlier ones' too.
    public internal(set) var allItems: [WorkItem]
    /// The number the next task gets.
    public var nextNumber: Int
    /// Newest last. Only the latest `Board.activityLimit` are kept.
    public var activity: [Activity]
    public var budget: Budget
    public var settings: BoardSettings
    /// The chat where the supervisor is talked to.
    public var supervisorChat: UUID?
    /// The model that supervises, or nil for the engine in use.
    public var supervisor: ModelChoice?
    /// The roles the project needs.
    public internal(set) var roles: [TeamRole]
    /// The team: each specialist holds one role.
    public internal(set) var specialists: [Specialist]
    public var createdAt: Date
    public var updatedAt: Date

    /// 3: a board has a team of roles and specialists, and a scorecard
    /// per role-model pair.
    public static let currentVersion = 3
    public static let activityLimit = 400

    public init(project: UUID, now: Date) {
        version = Self.currentVersion
        self.project = project
        earlierProjects = []
        let first = BoardGoal(number: 1, text: "", startedAt: now)
        goals = [first]
        currentGoal = first.id
        allItems = []
        nextNumber = 1
        activity = []
        budget = Budget()
        settings = BoardSettings()
        roles = []
        specialists = []
        supervisorChat = nil
        supervisor = nil
        createdAt = now
        updatedAt = now
    }

    private enum CodingKeys: String, CodingKey {
        case version, project, goals, currentGoal, nextNumber, activity, budget, settings, supervisorChat, supervisor
        case createdAt, updatedAt, earlierProjects, roles, specialists
        case allItems = "items"
    }

    /// Where a board of the first shape kept its one goal.
    private enum EarlierKeys: String, CodingKey {
        case goal
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        project = try values.decode(UUID.self, forKey: .project)
        earlierProjects = try values.decodeIfPresent([UUID].self, forKey: .earlierProjects) ?? []
        var tasks = try values.decodeIfPresent([WorkItem].self, forKey: .allItems) ?? []
        let highest = tasks.map(\.number).max() ?? 0
        let next = try values.decodeIfPresent(Int.self, forKey: .nextNumber) ?? 1
        nextNumber = max(next, highest + 1)
        activity = try values.decodeIfPresent([Activity].self, forKey: .activity) ?? []
        budget = try values.decodeIfPresent(Budget.self, forKey: .budget) ?? Budget()
        settings = try values.decodeIfPresent(BoardSettings.self, forKey: .settings) ?? BoardSettings()
        supervisorChat = try values.decodeIfPresent(UUID.self, forKey: .supervisorChat)
        supervisor = try values.decodeIfPresent(ModelChoice.self, forKey: .supervisor)
        let made = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        let changed = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? made
        createdAt = made
        updatedAt = changed

        var known = try values.decodeIfPresent([BoardGoal].self, forKey: .goals) ?? []
        if known.isEmpty {
            // A board of the first shape: the one goal it had is the first.
            let earlier = try decoder.container(keyedBy: EarlierKeys.self)
            let text = try earlier.decodeIfPresent(String.self, forKey: .goal) ?? ""
            known = [BoardGoal(number: 1, text: text, startedAt: made)]
        }
        // Exactly one goal is being worked toward: the one named, or the
        // last one marked so, or the newest.
        let named = try values.decodeIfPresent(UUID.self, forKey: .currentGoal)
        let place = known.firstIndex(where: { $0.id == named })
            ?? known.lastIndex(where: { $0.isActive })
            ?? known.count - 1
        for other in known.indices where other != place && known[other].isActive {
            known[other].close(.setAside, at: changed)
        }
        known[place].open(at: changed)
        // Every task is under a goal there is.
        let ids = Set(known.map(\.id))
        for index in tasks.indices {
            if let goal = tasks[index].goal, ids.contains(goal) { continue }
            tasks[index].goal = known[place].id
        }
        goals = known
        currentGoal = known[place].id

        let savedRoles = try values.decodeIfPresent([TeamRole].self, forKey: .roles) ?? []
        let savedSpecialists = try values.decodeIfPresent([Specialist].self, forKey: .specialists) ?? []
        if savedRoles.isEmpty && saved < 3 {
            let parallel = settings.parallel
            let count = max(1, min(parallel, TeamRules.roleLimit))
            let generalist = TeamRole(key: "generalist", title: "Generalist",
                                      brief: "Takes every kind of work until the PM proposes roles.",
                                      kinds: WorkKind.allCases.map { $0 },
                                      createdAt: made, createdBy: .autopilot)
            roles = [generalist]
            var migrated: [Specialist] = []
            for _ in 0..<count {
                migrated.append(Specialist(role: "generalist", createdAt: made, createdBy: .autopilot))
            }
            specialists = migrated
            settings.teamLimit = count
            for index in tasks.indices where tasks[index].role == nil {
                tasks[index].role = "generalist"
            }
        } else {
            roles = savedRoles
            specialists = savedSpecialists
        }

        allItems = tasks
        version = max(saved, Self.currentVersion)
    }
}

// MARK: - Reading the board

extension Board {
    /// The tasks of the goal being worked toward: what the board shows.
    public var items: [WorkItem] { allItems.filter { $0.goal == currentGoal } }

    /// Nothing was ever said or planned on it: one goal with no words,
    /// and no tasks under any.
    public var isBlank: Bool {
        allItems.isEmpty && goals.count <= 1 && goals.allSatisfy { $0.text.isEmpty }
    }

    /// Nothing was ever planned on it: one goal, with words perhaps, and
    /// no task. Such a board makes way for one that is brought back.
    public var isUnplanned: Bool {
        allItems.isEmpty && goals.count <= 1
    }

    /// A task, under whichever goal.
    public func item(_ id: UUID) -> WorkItem? { allItems.first { $0.id == id } }

    /// A task by its number, under whichever goal: a number is used once
    /// on a board, never once per goal.
    public func item(number: Int) -> WorkItem? { allItems.first { $0.number == number } }

    /// The task a run in this chat belongs to, under whichever goal.
    public func item(runIn conversation: UUID) -> WorkItem? {
        allItems.first { $0.runs.contains { $0.conversation == conversation } }
    }

    /// A column's tasks, top to bottom.
    public func items(in status: WorkStatus) -> [WorkItem] {
        items.filter { $0.status == status }.sorted { ($0.order, $0.number) < ($1.order, $1.number) }
    }

    public func count(in status: WorkStatus) -> Int {
        items.reduce(0) { $0 + ($1.status == status ? 1 : 0) }
    }

    /// The share of the tasks that are done, 0 to 1.
    public var doneFraction: Double {
        let tasks = items
        guard !tasks.isEmpty else { return 0 }
        return Double(tasks.filter { $0.status == .done }.count) / Double(tasks.count)
    }

    /// The plan's phases, in the order their first tasks were made.
    public var milestones: [String] {
        var seen: [String] = []
        for item in items.sorted(by: { $0.number < $1.number }) {
            guard let name = item.milestone, !name.isEmpty, !seen.contains(name) else { continue }
            seen.append(name)
        }
        return seen
    }

    /// The tasks a task still waits on: those it depends on, under the
    /// same goal, that are not done, or are done with their work not yet
    /// merged (their copy is open). A task that waits on another starts
    /// from a base that has that work in it, so it never redoes it or
    /// collides with it.
    public func blockers(of item: WorkItem) -> [WorkItem] {
        item.dependsOn.compactMap { number in
            self.item(number: number).flatMap { other -> WorkItem? in
                let finished = other.status == .done && other.workingCopy?.isOpen != true
                return finished || other.goal != item.goal ? nil : other
            }
        }
    }

    /// The tasks that could start now: in To do, nothing running in them,
    /// and everything they depend on done. Most pressing first.
    public var ready: [WorkItem] {
        items(in: .todo)
            .filter { $0.activeRun == nil && blockers(of: $0).isEmpty }
            .sorted { left, right in
                if left.priority != right.priority { return left.priority > right.priority }
                return (left.order, left.number) < (right.order, right.number)
            }
    }

    /// The tasks with a run going on, under whichever goal: a run that
    /// was going when the board turned to a new goal goes on.
    public var running: [WorkItem] { allItems.filter { $0.activeRun != nil } }

    /// Every chat a run of this board worked in.
    public var runConversations: Set<UUID> {
        Set(allItems.flatMap(\.conversations))
    }

    /// How many of a task's latest runs in a row the supervisor started
    /// to carry on from the run before.
    public func carryOns(of item: WorkItem) -> Int {
        var count = 0
        for run in item.runs.reversed() {
            guard run.carriesOn == true else { break }
            if Self.modelFailed(run) { continue }
            count += 1
        }
        return count
    }

    /// Whether a run failed only because its model could not answer: out
    /// of its limit, rate limited, overloaded or out of reach, as its
    /// report's first line says (`Failover.trouble`). That says nothing
    /// about the task, so such a run is not counted against it: the model
    /// rests, and another stands in or it is tried again once it is back.
    public static func modelFailed(_ run: WorkRun) -> Bool {
        guard run.outcome == .failed else { return false }
        let first = (run.report ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return Failover.trouble(status: nil, message: first, now: run.endedAt ?? run.startedAt) != nil
    }

    /// Whether a task's last run stopped halfway in a way the supervisor
    /// may carry on from by itself, on a board where it answers in the
    /// person's place: the app was quit under the run; or the run failed
    /// by itself, and the supervisor has not carried the task on
    /// `BoardRules.carryOnLimit` times in a row already. A run that a
    /// person stopped, or that was refused a step, is the person's to
    /// take up again; so is a task that was moved since the run left it.
    ///
    /// Runs from before their ending was kept: one the app found cut off
    /// is told by its having no report (a run that ended while the app
    /// ran has one, if only an empty one); one that failed is left to
    /// the person, as nobody can tell whether it was refused a step.
    public func mayCarryOn(_ item: WorkItem) -> Bool {
        guard item.status == .todo, let last = item.runs.last, !last.isRunning else { return false }
        if last.ending == .overrun { return false }
        switch last.outcome {
        case .stopped:
            return last.ending == .quit || (last.ending == nil && last.report == nil)
        case .failed:
            return last.ending == .itself && carryOns(of: item) < BoardRules.carryOnLimit
        case .succeeded, .running:
            return false
        }
    }

    /// How many of a task's latest runs in a row did not finish, leaving
    /// out those whose model could not answer (`modelFailed`).
    public func failuresInARow(of item: WorkItem) -> Int {
        var count = 0
        for run in item.runs.reversed() {
            guard run.outcome == .failed || run.outcome == .stopped else { break }
            if Self.modelFailed(run) { continue }
            count += 1
        }
        return count
    }

    /// How many of a task's latest runs in a row a model's review sent
    /// back with changes asked for. A person's request for changes, or a
    /// run without such a review, ends the count.
    public func sentBackInARow(of item: WorkItem) -> Int {
        var count = 0
        for run in item.runs.reversed() where !run.isRunning {
            guard let review = run.review, review.verdict == .changesRequested, !review.byPerson else { break }
            count += 1
        }
        return count
    }

    /// Whether Autopilot may start a task again, after its earlier runs:
    /// not once its last two runs did not finish, not once the review sent
    /// it back more than `BoardRules.redoLimit` times in a row (it waits
    /// for a person), and not when someone stopped or refused its last run.
    public func autopilotMayStart(_ item: WorkItem) -> Bool {
        if BoardRules.isBlank(item) { return false }
        if let ending = item.runs.last?.ending, ending == .person || ending == .supervisor { return false }
        return failuresInARow(of: item) < 2 && sentBackInARow(of: item) <= BoardRules.redoLimit
    }

    /// Whether a task that is not running will be started without a
    /// person: the supervisor carries it on (on a board where it answers
    /// for the person), or Autopilot starts it (it is ready and may start
    /// again). The budget is not weighed here: Autopilot switches itself
    /// off when it is used up.
    public func movesOnByItself(_ item: WorkItem) -> Bool {
        guard item.activeRun == nil else { return false }
        if settings.supervisorAnswers, mayCarryOn(item) { return true }
        guard settings.startsWorkByItself, item.status == .todo, item.goal == currentGoal, blockers(of: item).isEmpty
        else {
            return false
        }
        return autopilotMayStart(item)
    }

    /// The tasks of the goal being worked toward whose last run stopped
    /// halfway and may be carried on (`mayCarryOn`), the one that
    /// stopped first first.
    public var stoppedHalfway: [WorkItem] {
        func stopped(_ item: WorkItem) -> Date { item.runs.last?.endedAt ?? item.updatedAt }
        return items.filter { mayCarryOn($0) }
            .sorted { (stopped($0), $0.number) < (stopped($1), $1.number) }
    }

    /// Whether more tasks are in progress than the board's limit asks for.
    public var overWipLimit: Bool {
        guard let limit = settings.wipLimit, limit > 0 else { return false }
        return count(in: .inProgress) > limit
    }
}

// MARK: - Changing the board

extension Board {
    private mutating func touch(_ now: Date) { updatedAt = now }

    /// Adds a line to the history, dropping the oldest past the limit.
    public mutating func log(_ text: String, by actor: BoardActor, item: Int? = nil, now: Date) {
        activity.append(Activity(date: now, actor: actor, text: text, item: item))
        if activity.count > Self.activityLimit {
            activity.removeFirst(activity.count - Self.activityLimit)
        }
        touch(now)
    }

    /// Gives the board to another project: one that was taken off the
    /// list and added again is a new project, and its board follows it.
    /// The id it had is kept, so what was spent under it still counts.
    public mutating func rehome(to id: UUID, now: Date) {
        guard id != project else { return }
        if !earlierProjects.contains(project) { earlierProjects.append(project) }
        earlierProjects.removeAll { $0 == id }
        project = id
        log("Brought back to its project", by: .person, now: now)
    }

    /// The place at the foot of a column of a goal's tasks.
    private func lastOrder(in status: WorkStatus, of goal: UUID?) -> Double {
        (allItems.filter { $0.status == status && $0.goal == goal }.map(\.order).max() ?? 0) + 1
    }

    /// Adds a task to the goal being worked toward and gives it the next
    /// number. It goes to the foot of its column.
    @discardableResult
    public mutating func add(title: String, details: String = "", acceptance: [String] = [],
                             status: WorkStatus = .todo, priority: WorkPriority = .medium,
                             kind: WorkKind = .feature, milestone: String? = nil, dependsOn: [Int] = [],
                             estimateTokens: Int? = nil, paths: [String] = [], role: String? = nil,
                             by actor: BoardActor, now: Date) -> WorkItem {
        let number = nextNumber
        nextNumber += 1
        // A new task can only wait on tasks that exist; it cannot be one
        // of them, so no circle can come of this.
        let known = Set(items.map(\.number))
        let assignedRole = role ?? TeamRouting.role(for:
            WorkItem(number: 0, title: title, kind: kind, createdAt: now, goal: currentGoal),
            among: roles, items: allItems)
        var item = WorkItem(number: number, title: BoardRules.title(title), details: details,
                            acceptance: BoardRules.lines(acceptance), status: status, priority: priority, kind: kind,
                            milestone: BoardRules.name(milestone), dependsOn: dependsOn.filter { known.contains($0) },
                            estimateTokens: estimateTokens.flatMap { $0 > 0 ? $0 : nil },
                            createdAt: now, order: lastOrder(in: status, of: currentGoal), goal: currentGoal,
                            role: assignedRole)
        item.paths = Leases.list(paths)
        if status == .inProgress { item.startedAt = now }
        if status == .done { item.finishedAt = now }
        allItems.append(item)
        log("Added \(item.key): \(item.title)", by: actor, item: number, now: now)
        return item
    }

    /// Changes a task in place. The closure sees the task as it is; what
    /// it leaves is what is kept (its number, its identity and the goal
    /// it is under stay as they were). Returns false when there is no
    /// such task.
    @discardableResult
    public mutating func update(_ id: UUID, now: Date, _ change: (inout WorkItem) -> Void) -> Bool {
        guard let index = allItems.firstIndex(where: { $0.id == id }) else { return false }
        var item = allItems[index]
        change(&item)
        item.id = allItems[index].id
        item.number = allItems[index].number
        item.goal = allItems[index].goal
        item.title = BoardRules.title(item.title)
        item.updatedAt = now
        allItems[index] = item
        touch(now)
        return true
    }

    /// Moves a task to a column, at its foot or just above another task.
    /// Moving within a column changes only the order.
    @discardableResult
    public mutating func move(_ id: UUID, to status: WorkStatus, above other: UUID? = nil,
                              by actor: BoardActor, now: Date) -> Bool {
        guard let index = allItems.firstIndex(where: { $0.id == id }) else { return false }
        let from = allItems[index].status
        // A task keeps to the columns of its own goal.
        let goal = allItems[index].goal
        var order = lastOrder(in: status, of: goal)
        if let other, other != id, let target = allItems.first(where: { $0.id == other }), target.status == status,
           target.goal == goal {
            // Halfway between the task above the target and the target.
            let above = allItems
                .filter { $0.status == status && $0.goal == goal && $0.order < target.order && $0.id != id }
                .map(\.order).max()
            order = ((above ?? target.order - 1) + target.order) / 2
        }
        allItems[index].order = order
        allItems[index].updatedAt = now
        guard from != status else {
            touch(now)
            return true
        }
        allItems[index].status = status
        if status == .inProgress, allItems[index].startedAt == nil { allItems[index].startedAt = now }
        if status == .done {
            allItems[index].finishedAt = now
            if allItems[index].startedAt == nil { allItems[index].startedAt = now }
            // A person who calls it done lets its work be merged. Anyone
            // else does that by approving it (`review`).
            if actor == .person { approveCopy(at: index, by: "You") }
        } else {
            allItems[index].finishedAt = nil
            withdrawCopyApproval(at: index)
        }
        log("Moved \(allItems[index].key) from \(from.title) to \(status.title)", by: actor,
            item: allItems[index].number, now: now)
        return true
    }

    /// Takes a task off the board. Tasks that waited on it no longer do.
    @discardableResult
    public mutating func remove(_ id: UUID, by actor: BoardActor, now: Date) -> Bool {
        guard let index = allItems.firstIndex(where: { $0.id == id }) else { return false }
        let gone = allItems.remove(at: index)
        for other in allItems.indices {
            allItems[other].dependsOn.removeAll { $0 == gone.number }
        }
        // Its copy is taken down by the app; its branch, with the work on
        // it, is left in the repository.
        let kept = gone.workingCopy.flatMap { $0.isOpen ? ". Its work is kept on branch \($0.branch)" : nil } ?? ""
        log("Removed \(gone.key): \(gone.title)" + kept, by: actor, item: gone.number, now: now)
        return true
    }

    /// Sets what a task waits on, leaving out anything that is not a task
    /// under the same goal, the task itself, and anything that would make
    /// a circle (a task that waits, through others, on itself can never
    /// start).
    /// Returns the numbers that were left out.
    @discardableResult
    public mutating func setDependencies(_ id: UUID, to numbers: [Int], now: Date) -> [Int] {
        guard let index = allItems.firstIndex(where: { $0.id == id }) else { return numbers }
        let own = allItems[index].number
        var kept: [Int] = []
        var refused: [Int] = []
        let goal = allItems[index].goal
        for number in numbers where !kept.contains(number) {
            let known = item(number: number).map { $0.goal == goal } ?? false
            if number == own || !known
                || BoardRules.reaches(from: number, to: own, in: self, extra: [own: kept]) {
                refused.append(number)
            } else {
                kept.append(number)
            }
        }
        allItems[index].dependsOn = kept
        allItems[index].updatedAt = now
        touch(now)
        return refused
    }

    /// Gives a task to a model.
    @discardableResult
    public mutating func assign(_ id: UUID, _ assignment: Assignment, by actor: BoardActor, now: Date) -> Bool {
        guard let index = allItems.firstIndex(where: { $0.id == id }) else { return false }
        let before = allItems[index].assignment?.model
        allItems[index].assignment = assignment
        // What the supervisor picked stays as its recommendation,
        // whatever a person chooses after.
        if assignment.source == .supervisor { allItems[index].suggestion = assignment }
        allItems[index].updatedAt = now
        if before != assignment.model {
            log("\(assignment.accepted ? "Assigned" : "Suggested") \(assignment.label) for \(allItems[index].key)",
                by: actor, item: allItems[index].number, now: now)
        } else {
            touch(now)
        }
        return true
    }

    /// A person agrees to the model suggested for a task.
    @discardableResult
    public mutating func acceptAssignment(_ id: UUID, now: Date) -> Bool {
        guard let index = allItems.firstIndex(where: { $0.id == id }), allItems[index].assignment != nil else { return false }
        allItems[index].assignment?.accepted = true
        allItems[index].updatedAt = now
        touch(now)
        return true
    }

    /// Adds something said about a task.
    @discardableResult
    public mutating func note(_ id: UUID, _ text: String, author: String, now: Date) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let index = allItems.firstIndex(where: { $0.id == id }) else { return false }
        allItems[index].notes.append(WorkNote(date: now, author: author, text: text))
        allItems[index].updatedAt = now
        touch(now)
        return true
    }

    // MARK: Runs

    /// A run begins: it is kept with the task, which moves to In progress.
    @discardableResult
    public mutating func beginRun(_ id: UUID, _ run: WorkRun, by actor: BoardActor, now: Date) -> Bool {
        guard let index = allItems.firstIndex(where: { $0.id == id }) else { return false }
        // One run at a time per task: an earlier one still marked as
        // running was lost (the app quit), so it is closed first.
        for other in allItems[index].runs.indices where allItems[index].runs[other].isRunning {
            allItems[index].runs[other].outcome = .stopped
            allItems[index].runs[other].endedAt = now
            allItems[index].runs[other].ending = .quit
        }
        allItems[index].runs.append(run)
        // What was approved before is not what this run will leave.
        withdrawCopyApproval(at: index)
        log("Started \(allItems[index].key) with \(run.modelLabel)", by: actor, item: allItems[index].number, now: now)
        if allItems[index].status != .inProgress {
            move(id, to: .inProgress, by: .run, now: now)
        }
        return true
    }

    /// A run ended: its outcome is kept, and the task moves as
    /// `BoardRules.status(after:)` says. Returns the task and the run, or
    /// nil when no running run here works in that chat.
    @discardableResult
    public mutating func endRun(in conversation: UUID, outcome: WorkRun.Outcome, report: String?,
                                ending: WorkRun.Ending? = nil, now: Date) -> (item: WorkItem, run: WorkRun)? {
        for index in allItems.indices {
            guard let place = allItems[index].runs.lastIndex(where: { $0.conversation == conversation && $0.isRunning })
            else { continue }
            allItems[index].runs[place].outcome = outcome
            allItems[index].runs[place].endedAt = now
            allItems[index].runs[place].ending = ending
            allItems[index].runs[place].report = report.map { String($0.prefix(BoardRules.reportLimit)) }
            let taskID = allItems[index].id
            let runID = allItems[index].runs[place].id
            let words: String
            switch outcome {
            case .succeeded: words = "finished"
            case .failed: words = "failed"
            case .stopped: words = "was stopped"
            case .running: words = "is running"
            }
            log("The run on \(allItems[index].key) \(words)", by: .run, item: allItems[index].number, now: now)
            // A task someone moved while it ran stays where they put it.
            if allItems[index].status == .inProgress, let next = BoardRules.status(after: outcome) {
                move(taskID, to: next, by: .run, now: now)
            }
            guard let task = allItems.first(where: { $0.id == taskID }),
                  let run = task.runs.first(where: { $0.id == runID }) else { return nil }
            return (task, run)
        }
        return nil
    }

    /// The check of a finished run: approved, the task is done; with
    /// changes asked for, it goes back to To do with the reviewer's notes.
    @discardableResult
    public mutating func review(_ id: UUID, _ review: Review, now: Date) -> Bool {
        guard let index = allItems.firstIndex(where: { $0.id == id }) else { return false }
        if let last = allItems[index].runs.indices.last {
            allItems[index].runs[last].review = review
        }
        let key = allItems[index].key
        let number = allItems[index].number
        let actor: BoardActor = review.byPerson ? .person : .supervisor
        switch review.verdict {
        case .approved:
            log("\(review.by) approved \(key)", by: actor, item: number, now: now)
            // Approved work in a task's own copy is merged (`waitingToMerge`).
            approveCopy(at: index, by: review.by)
            if allItems[index].status != .done { move(id, to: .done, by: actor, now: now) }
        case .changesRequested:
            log("\(review.by) asked for changes to \(key)", by: actor, item: number, now: now)
            withdrawCopyApproval(at: index)
            if !review.notes.isEmpty {
                note(id, "Review: " + review.notes, author: review.by, now: now)
            }
            if allItems[index].status != .todo { move(id, to: .todo, by: actor, now: now) }
            // Sent back too often in a row, it is not started again by itself.
            if settings.startsWorkByItself, let task = allItems.first(where: { $0.id == id }) {
                let times = sentBackInARow(of: task)
                if times > BoardRules.redoLimit {
                    log("\(key) was sent back \(times) times in a row, so it waits for you", by: actor, item: number, now: now)
                }
            }
        }
        return true
    }

    /// What the supervisor recommends for a task waiting in Review, kept
    /// with its last run. Nothing moves: the person decides.
    @discardableResult
    public mutating func recommend(_ id: UUID, _ review: Review, now: Date) -> Bool {
        guard let index = allItems.firstIndex(where: { $0.id == id }),
              let last = allItems[index].runs.indices.last else { return false }
        allItems[index].runs[last].advice = review
        allItems[index].updatedAt = now
        touch(now)
        return true
    }

    /// Runs still marked as running when the app starts were cut off by
    /// its quitting. They are closed as stopped and their tasks go back
    /// to To do, so nothing stays "running" for ever. Returns how many.
    @discardableResult
    public mutating func closeLostRuns(except live: Set<UUID>, now: Date) -> Int {
        var closed = 0
        for index in allItems.indices {
            for place in allItems[index].runs.indices
            where allItems[index].runs[place].isRunning && !live.contains(allItems[index].runs[place].conversation) {
                allItems[index].runs[place].outcome = .stopped
                allItems[index].runs[place].endedAt = now
                // Nobody stopped it: the app went away under it.
                allItems[index].runs[place].ending = .quit
                closed += 1
            }
        }
        for item in allItems where item.status == .inProgress && item.activeRun == nil && !item.runs.isEmpty
            && item.runs.last?.outcome == .stopped && item.runs.last?.endedAt == now {
            move(item.id, to: .todo, by: .run, now: now)
        }
        return closed
    }
}

/// The board's rules, in one place.
public enum BoardRules {
    /// The most of a run's report that is kept with it.
    public static let reportLimit = 1_200

    /// How many times in a row the supervisor carries a task on by
    /// itself after a run of it stopped halfway. Past that, the task
    /// waits for a person. A run the app quit under does not count: that
    /// was not the task's doing.
    public static let carryOnLimit = 2

    /// How many times a task's work is sent back to settle conflicts with
    /// the branch it goes into before it waits for the person instead.
    public static let settleLimit = 2

    /// How many times in a row a task that a model's review sent back is
    /// started again by itself (by Autopilot, or the supervisor on a board
    /// it runs). Past that, the task waits for a person: a reviewer that
    /// keeps asking for changes would otherwise send it round for ever.
    /// A person's own request for changes is theirs and is not counted.
    public static let redoLimit = 2

    /// The title a task added by a person starts with, before they name it.
    public static let newTaskTitle = "New task"
    /// The title of a task whose title was left empty.
    public static let untitled = "Untitled task"

    /// A task as it was added, before anyone said what it is: its title
    /// is still a placeholder and it has no details and no "done means".
    /// It is never started by itself, nor by hand, since an agent given
    /// it would have nothing to do (a new task in To do was started on
    /// the next pulse, before it could be written).
    public static func isBlank(_ item: WorkItem) -> Bool {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholder = [newTaskTitle, untitled].contains { title.caseInsensitiveCompare($0) == .orderedSame }
        return placeholder && item.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && item.acceptance.isEmpty
    }

    /// Where a task goes when a run on it ends: finished work is looked
    /// at before it is done; work that failed or was stopped is to do
    /// again. (The same rule as Farhelm's `work_items::status_after`.)
    public static func status(after outcome: WorkRun.Outcome) -> WorkStatus? {
        switch outcome {
        case .succeeded: return .review
        case .failed, .stopped: return .todo
        case .running: return nil
        }
    }

    /// A title on one line, of a length a card can show.
    static func title(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? untitled : String(trimmed.prefix(140))
    }

    /// A goal's words, of a length that can be read at a glance.
    static func goal(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_000))
    }

    static func name(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(60))
    }

    static func lines(_ list: [String]) -> [String] {
        list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { String($0.prefix(300)) }
    }

    /// Whether following "waits on" from one task leads to another.
    /// `extra` stands in for the waits of tasks being changed right now.
    static func reaches(from start: Int, to goal: Int, in board: Board, extra: [Int: [Int]] = [:]) -> Bool {
        var seen: Set<Int> = []
        var next = [start]
        while let number = next.popLast() {
            if number == goal { return true }
            guard seen.insert(number).inserted else { continue }
            next.append(contentsOf: extra[number] ?? board.item(number: number)?.dependsOn ?? [])
        }
        return false
    }
}
