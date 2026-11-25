import Foundation

/// The parts of a task a supervisor may set or change. Anything left nil
/// stays as it is.
public struct ItemPatch: Equatable, Sendable {
    public var title: String?
    public var details: String?
    public var acceptance: [String]?
    public var status: WorkStatus?
    public var priority: WorkPriority?
    public var kind: WorkKind?
    /// The phase it belongs to; an empty name takes it out of its phase.
    public var milestone: String?
    /// The tasks it waits on, as they were written ("T-3", "3", or the
    /// label of a task added in the same reply).
    public var dependsOn: [String]?
    public var estimateTokens: Int?
    /// The model proposed for it, by its name in the list the supervisor
    /// was given, and why.
    public var model: String?
    public var reason: String?
    /// The files and folders it is planned to change (`WorkItem.paths`).
    public var paths: [String]?

    public init(title: String? = nil, details: String? = nil, acceptance: [String]? = nil, status: WorkStatus? = nil,
                priority: WorkPriority? = nil, kind: WorkKind? = nil, milestone: String? = nil,
                dependsOn: [String]? = nil, estimateTokens: Int? = nil, model: String? = nil, reason: String? = nil,
                paths: [String]? = nil) {
        self.title = title
        self.details = details
        self.acceptance = acceptance
        self.status = status
        self.priority = priority
        self.kind = kind
        self.milestone = milestone
        self.dependsOn = dependsOn
        self.estimateTokens = estimateTokens
        self.model = model
        self.reason = reason
        self.paths = paths
    }
}

/// One change a supervisor asks for. A model writes these, so they are
/// requests, not commands: `Board.apply` checks each against the board's
/// rules and says which it could not carry out.
public enum BoardOperation: Equatable, Sendable {
    /// Words the goal being worked toward: for the first time, or better.
    case setGoal(String)
    /// Turns the board to a new goal. The goal before it is kept, with
    /// its tasks, in the project's history; with `bringUnfinished` the
    /// tasks it left open come along.
    case newGoal(String, bringUnfinished: Bool)
    /// A new task. `label` is a name of the supervisor's own for it, so
    /// later operations in the same reply can refer to it.
    case add(label: String?, ItemPatch)
    case update(ref: String, ItemPatch)
    case move(ref: String, WorkStatus)
    case assign(ref: String, model: String, reason: String)
    case note(ref: String, String)
    case remove(ref: String)
    /// Stops the run going on in a task, and says why. The board only
    /// records it (`ChangeSummary.stopping`): ending the agent is the
    /// app's, the same way a person's Stop on the card ends it.
    case stop(ref: String, reason: String)
    case setBudget(Budget)

    var startsGoal: Bool {
        if case .newGoal = self { return true }
        return false
    }
}

/// What a set of operations did to the board.
public struct ChangeSummary: Equatable, Sendable {
    public var added = 0
    public var updated = 0
    public var moved = 0
    public var assigned = 0
    public var noted = 0
    public var removed = 0
    /// The goal being worked toward was worded, or worded anew.
    public var goalChanged = false
    /// The board turned to a new goal.
    public var goalStarted = false
    public var budgetChanged = false
    /// What could not be done, and why, in plain words.
    public var problems: [String] = []
    /// The tasks that were added or changed.
    public var touched: [UUID] = []
    /// The tasks whose run the supervisor asked to stop. Their runs are
    /// still going when `apply` returns; the app stops each one.
    public var stopping: [UUID] = []

    public init() {}

    public var isEmpty: Bool {
        added + updated + moved + assigned + noted + removed + stopping.count == 0
            && !goalChanged && !goalStarted && !budgetChanged
    }

    /// "Added 6 tasks, suggested a model for 6 and moved 1."
    public var sentence: String {
        func tasks(_ count: Int) -> String { count == 1 ? "1 task" : "\(count) tasks" }
        var parts: [String] = []
        if goalStarted { parts.append("started a new goal") }
        if goalChanged { parts.append("set the goal") }
        if added > 0 { parts.append("added \(tasks(added))") }
        if updated > 0 { parts.append("updated \(tasks(updated))") }
        if moved > 0 { parts.append("moved \(tasks(moved))") }
        if assigned > 0 { parts.append("suggested a model for \(tasks(assigned))") }
        if noted > 0 { parts.append("left \(noted == 1 ? "a note" : "\(noted) notes")") }
        if removed > 0 { parts.append("removed \(tasks(removed))") }
        if !stopping.isEmpty { parts.append("stopped \(stopping.count == 1 ? "a run" : "\(stopping.count) runs")") }
        if budgetChanged { parts.append("set the budget") }
        guard !parts.isEmpty else { return "" }
        let text = parts.count == 1 ? parts[0]
            : parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        return text.prefix(1).uppercased() + String(text.dropFirst()) + "."
    }
}

extension Board {
    /// The most operations taken from one reply, and the most tasks a
    /// board holds: a model that runs away cannot flood the board.
    public static let operationLimit = 80
    public static let itemLimit = 300

    /// A task of the goal being worked toward, by its number. A
    /// supervisor works on that goal: the tasks of earlier goals are the
    /// project's history, and not its to change.
    private func shown(_ number: Int) -> WorkItem? {
        item(number: number).flatMap { $0.goal == currentGoal ? $0 : nil }
    }

    /// A task by the name a supervisor uses for it: "T-3", "t3", "#3",
    /// "3", or (from `labels`) its own label for one it has just added.
    func item(ref: String, labels: [String: Int] = [:]) -> WorkItem? {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = labels[trimmed.lowercased()] { return shown(number) }
        var digits = trimmed.lowercased()
        for prefix in ["task-", "task ", "task", "#", "t-", "t"] where digits.hasPrefix(prefix) {
            digits = String(digits.dropFirst(prefix.count))
            break
        }
        guard let number = Int(digits.trimmingCharacters(in: .whitespaces)) else { return nil }
        return shown(number)
    }

    /// Carries out a supervisor's operations, in order, under the board's
    /// rules. `model` turns the name a supervisor gave a model into the
    /// model itself and its name as shown, or nil when there is none by
    /// that name. Nothing here trusts the operations: unknown tasks and
    /// models are skipped and reported, limits are kept, a task with a
    /// run going on is not removed, waits that would make a circle are
    /// left out, and only the tasks of the goal being worked toward can
    /// be changed.
    @discardableResult
    public mutating func apply(_ operations: [BoardOperation], by actor: BoardActor = .supervisor,
                               author: String = "Supervisor",
                               model: (String) -> (choice: ModelChoice, label: String)?,
                               now: Date) -> ChangeSummary {
        var summary = ChangeSummary()
        var labels: [String: Int] = [:]
        // What each task waits on is settled last, once every task named
        // in this reply exists.
        var waits: [(id: UUID, refs: [String])] = []
        if operations.count > Self.operationLimit {
            summary.problems.append("Only the first \(Self.operationLimit) of \(operations.count) changes were made.")
        }

        func touch(_ id: UUID) {
            if !summary.touched.contains(id) { summary.touched.append(id) }
        }

        /// Proposes a model for a task. False when there is no such model.
        func propose(_ name: String, _ reason: String?, for id: UUID) -> Bool {
            guard let found = model(name) else {
                summary.problems.append("No model is called \"\(name)\".")
                return false
            }
            // A choice a person made stands until they change it.
            if let current = item(id)?.assignment, current.source == .person, current.accepted { return false }
            let assignment = Assignment(model: found.choice, label: found.label,
                                        reason: String((reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)),
                                        source: .supervisor, accepted: false, date: now)
            return assign(id, assignment, by: actor, now: now)
        }

        // A new goal is turned to before anything else is done, wherever
        // in the reply it was written: the tasks added with it are its own.
        let taken = Array(operations.prefix(Self.operationLimit))
        let ordered = taken.filter { $0.startsGoal } + taken.filter { !$0.startsGoal }
        var turned = false

        for operation in ordered {
            switch operation {
            case .setGoal(let text):
                // A supervisor words a goal; it does not take its words away.
                guard !BoardRules.goal(text).isEmpty, setGoal(text, by: actor, now: now) else { continue }
                summary.goalChanged = true

            case .newGoal(let text, let bring):
                guard !turned else {
                    summary.problems.append("Only one new goal can be started at a time; the second was left out.")
                    continue
                }
                let before = currentGoal
                guard startGoal(text, bringUnfinished: bring, by: actor, now: now) != nil else {
                    summary.problems.append("A new goal had no words and was left out.")
                    continue
                }
                turned = true
                // A goal that was never said has only been said now.
                if currentGoal == before { summary.goalChanged = true } else { summary.goalStarted = true }

            case .setBudget(let budget):
                guard budget != self.budget else { continue }
                self.budget = budget
                log("Set the budget", by: actor, now: now)
                summary.budgetChanged = true

            case .add(let label, let patch):
                guard items.count < Self.itemLimit else {
                    summary.problems.append("The board is full (\(Self.itemLimit) tasks); nothing more was added.")
                    continue
                }
                guard let title = patch.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    summary.problems.append("A new task had no title and was left out.")
                    continue
                }
                // A supervisor plans work; it does not declare it done.
                let status = patch.status.flatMap { $0 == .done || $0 == .review ? nil : $0 } ?? .todo
                let made = add(title: title, details: patch.details ?? "", acceptance: patch.acceptance ?? [],
                               status: status, priority: patch.priority ?? .medium, kind: patch.kind ?? .feature,
                               milestone: patch.milestone, estimateTokens: patch.estimateTokens,
                               paths: patch.paths ?? [], by: actor, now: now)
                summary.added += 1
                touch(made.id)
                if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !label.isEmpty {
                    labels[label] = made.number
                }
                if let refs = patch.dependsOn, !refs.isEmpty { waits.append((made.id, refs)) }
                if let name = patch.model, propose(name, patch.reason, for: made.id) { summary.assigned += 1 }

            case .update(let ref, let patch):
                guard let found = item(ref: ref, labels: labels) else {
                    summary.problems.append("There is no task \(ref) to update.")
                    continue
                }
                var changed = false
                update(found.id, now: now) { item in
                    if let title = patch.title, !title.isEmpty, title != item.title { item.title = title; changed = true }
                    if let details = patch.details, details != item.details { item.details = details; changed = true }
                    if let acceptance = patch.acceptance {
                        let lines = BoardRules.lines(acceptance)
                        if lines != item.acceptance { item.acceptance = lines; changed = true }
                    }
                    if let priority = patch.priority, priority != item.priority { item.priority = priority; changed = true }
                    if let kind = patch.kind, kind != item.kind { item.kind = kind; changed = true }
                    if let milestone = patch.milestone {
                        let name = BoardRules.name(milestone)
                        if name != item.milestone { item.milestone = name; changed = true }
                    }
                    if let estimate = patch.estimateTokens, estimate > 0, estimate != item.estimateTokens {
                        item.estimateTokens = estimate
                        changed = true
                    }
                    if let paths = patch.paths {
                        let kept = Leases.list(paths)
                        if kept != item.paths { item.paths = kept; changed = true }
                    }
                }
                if let refs = patch.dependsOn { waits.append((found.id, refs)) }
                if let status = patch.status, status != found.status, moveForSupervisor(found.id, to: status, by: actor,
                                                                                         now: now, into: &summary) {
                    summary.moved += 1
                }
                if let name = patch.model, propose(name, patch.reason, for: found.id) { summary.assigned += 1 }
                if changed {
                    summary.updated += 1
                    log("Updated \(found.key)", by: actor, item: found.number, now: now)
                }
                touch(found.id)

            case .move(let ref, let status):
                guard let found = item(ref: ref, labels: labels) else {
                    summary.problems.append("There is no task \(ref) to move.")
                    continue
                }
                guard found.status != status else { continue }
                if moveForSupervisor(found.id, to: status, by: actor, now: now, into: &summary) {
                    summary.moved += 1
                    touch(found.id)
                }

            case .assign(let ref, let name, let reason):
                guard let found = item(ref: ref, labels: labels) else {
                    summary.problems.append("There is no task \(ref) to give a model.")
                    continue
                }
                if propose(name, reason, for: found.id) {
                    summary.assigned += 1
                    touch(found.id)
                }

            case .note(let ref, let text):
                guard let found = item(ref: ref, labels: labels) else {
                    summary.problems.append("There is no task \(ref) to leave a note on.")
                    continue
                }
                if note(found.id, String(text.prefix(2_000)), author: author, now: now) {
                    summary.noted += 1
                    touch(found.id)
                }

            case .remove(let ref):
                guard let found = item(ref: ref, labels: labels) else {
                    summary.problems.append("There is no task \(ref) to remove.")
                    continue
                }
                // Work that was done on a task is part of the record: a
                // task with runs is kept, in the backlog, not deleted.
                guard found.runs.isEmpty else {
                    summary.problems.append("\(found.key) has runs, so it was kept. Move it to the backlog instead.")
                    continue
                }
                if remove(found.id, by: actor, now: now) { summary.removed += 1 }

            case .stop(let ref, let reason):
                guard let found = item(ref: ref, labels: labels) else {
                    summary.problems.append("There is no task \(ref) to stop.")
                    continue
                }
                guard found.activeRun != nil else {
                    summary.problems.append("\(found.key) has no run going on, so there was nothing to stop.")
                    continue
                }
                guard !summary.stopping.contains(found.id) else { continue }
                // The reason stays on the task, so the person (and the
                // next run) can read why it was cut short.
                let why = String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
                _ = note(found.id, why.isEmpty ? "Stopped the run." : "Stopped the run: \(why)", author: author, now: now)
                log("Asked to stop the run on \(found.key)", by: actor, item: found.number, now: now)
                summary.stopping.append(found.id)
                touch(found.id)
            }
        }

        for wait in waits {
            var numbers: [Int] = []
            for ref in wait.refs {
                if let found = item(ref: ref, labels: labels) {
                    numbers.append(found.number)
                } else {
                    summary.problems.append("\(item(wait.id)?.key ?? "A task") waits on \(ref), which is not a task here.")
                }
            }
            let refused = setDependencies(wait.id, to: numbers, now: now)
            if !refused.isEmpty, let key = item(wait.id)?.key {
                let names = refused.map { "T-\($0)" }.joined(separator: ", ")
                summary.problems.append("\(key) cannot wait on \(names): that would make a circle.")
            }
        }
        return summary
    }

    /// A move a supervisor asked for. It may plan and re-plan, send work
    /// back, and close what a person or a review has already passed; it
    /// may not pull a task out from under a run.
    private mutating func moveForSupervisor(_ id: UUID, to status: WorkStatus, by actor: BoardActor, now: Date,
                                            into summary: inout ChangeSummary) -> Bool {
        guard let found = item(id) else { return false }
        if found.activeRun != nil, status != .inProgress {
            summary.problems.append("\(found.key) has a run going on, so it stays in progress until the run ends.")
            return false
        }
        // Done merges a task's own copy into the project's branch, which
        // only an approval lets happen: a review's, or a person's.
        if status == .done, let copy = found.workingCopy, copy.isOpen, copy.approvedBy == nil {
            summary.problems.append("\(found.key) works on a branch of its own, which is merged only once its work is approved, so it was not moved to done.")
            return false
        }
        return move(id, to: status, by: actor, now: now)
    }
}
