import Foundation

/// What the automatic reviewer decided about a task.
public enum ReviewDecision: String, Codable, CaseIterable, Sendable {
    case approve
    case sendBack = "send_back"
    case reassign
    case askOwner = "ask_owner"
    case hold
    case stopAndReplan = "stop_and_replan"

    /// The word the decision log shows.
    public var title: String {
        switch self {
        case .approve: return "Approved"
        case .sendBack: return "Sent back"
        case .reassign: return "Reassigned"
        case .askOwner: return "Asked you"
        case .hold: return "Held"
        case .stopAndReplan: return "Stopped to re-plan"
        }
    }
}

/// One line of the board's decision log: which task, what was decided,
/// why in one line, by which model, and when.
public struct DecisionEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    /// The task's number.
    public var item: Int
    /// The task's key as it was then: "T-7".
    public var task: String
    public var decision: ReviewDecision
    public var reason: String
    /// The model that decided, as shown.
    public var model: String
    /// The run it was about, so a hold is said once per run.
    public var run: UUID?

    public init(id: UUID = UUID(), date: Date, item: Int, task: String, decision: ReviewDecision, reason: String,
                model: String, run: UUID? = nil) {
        self.id = id
        self.date = date
        self.item = item
        self.task = task
        self.decision = decision
        self.reason = reason
        self.model = model
        self.run = run
    }
}

/// A decision before it is carried out.
public struct AutoDecision: Equatable, Sendable {
    public var decision: ReviewDecision
    /// One line, for the log and the card.
    public var reason: String
    /// What the next run is told, when the work goes back.
    public var notes: String
    /// The model the task goes to, when it is reassigned.
    public var model: ModelProfile?

    public init(_ decision: ReviewDecision, reason: String, notes: String = "", model: ModelProfile? = nil) {
        self.decision = decision
        self.reason = reason
        self.notes = notes
        self.model = model
    }
}

/// The automatic reviewer's rules: what becomes of a finished run when
/// the board reviews by itself (`BoardSettings.autoReview`). They are here,
/// not in a prompt, so no model's answer can widen them: the model only
/// gives a verdict, and these rules decide what follows from it.
public enum AutoReview {
    /// Rounds sent back in a row before the task goes to a stronger model.
    public static let roundsBeforeReassign = BoardRules.redoLimit
    /// The most entries the decision log keeps.
    public static let logLimit = 300

    /// What the reviewer never decides alone. They go to the owner.
    public static let ownerOnly = [
        "Merging the board's branch into your branch",
        "Anything that touches keys or credentials",
        "Deleting or archiving work",
        "Pushing",
    ]

    /// What follows from a review of a task waiting in Review. `verdict` is
    /// the reviewing model's (nil when it gave none that could be read),
    /// `changed` the paths the work changed. nil when there is nothing to
    /// decide: the task is not waiting in Review, or a run is going on.
    ///
    /// Work is approved only when its checks ran and all passed and the
    /// review found Done means met. Without checks nothing shows the work
    /// builds, so it is the owner's, as it is for the supervisor's approve.
    public static func decide(_ item: WorkItem, on board: Board, verdict: Review.Verdict?, notes: String = "",
                              changed: [String] = [], profiles: [ModelProfile] = []) -> AutoDecision? {
        guard item.status == .review, item.activeRun == nil, let run = item.runs.last else { return nil }
        if let path = changed.first(where: touchesCredentials) {
            return AutoDecision(.askOwner, reason: "It changes \(path), which may hold keys or credentials.")
        }
        let results = run.checks ?? []
        let failed = results.filter { !$0.passed }
        if !failed.isEmpty {
            let names = failed.prefix(3).map(\.name).joined(separator: ", ")
            var words = "What the checks found:\n" + Checks.digest(results)
            if !notes.isEmpty { words = notes + "\n" + words }
            return sendBack(item, on: board, reason: "Checks did not pass: \(names).", notes: words,
                            profiles: profiles)
        }
        if results.isEmpty {
            return AutoDecision(.askOwner, reason: "No check ran on its work, so nothing shows that it builds.")
        }
        switch verdict {
        case .approved:
            return AutoDecision(.approve, reason: "Checks passed and Done means is met.")
        case .changesRequested:
            let line = firstLine(notes)
            return sendBack(item, on: board, reason: line.isEmpty ? "Done means is not met yet." : line,
                            notes: notes, profiles: profiles)
        case nil:
            return AutoDecision(.askOwner, reason: "The review gave no clear verdict.")
        }
    }

    /// A run that failed only because the person's branch lacks work they
    /// have not committed: running it again cannot help, so the task is
    /// held, and this is said once per run. nil once it has been said.
    public static func hold(_ item: WorkItem, on board: Board) -> AutoDecision? {
        guard let run = item.runs.last, run.outcome == .failed, !board.isHeld(item),
              blamesUncommittedWork(run.report ?? "") else { return nil }
        return AutoDecision(.hold, reason: "It needs work on your branch that is not committed yet; it waits until you commit it.")
    }

    /// Whether a run's report says it failed for want of work that is in
    /// the person's folder but not committed, so not in the task's copy.
    /// Read from the report's own words: the board cannot see the folder.
    public static func blamesUncommittedWork(_ report: String) -> Bool {
        let text = report.lowercased()
        let missing = ["uncommitted", "not committed", "isn't committed", "is not committed", "never committed"]
        return missing.contains(where: text.contains)
    }

    /// A run past `LoopDetection.tokenMultiple` times its estimate is
    /// stopped and its task re-planned: the plan was wrong, so spending
    /// more on it would not help.
    public static func overrun(_ item: WorkItem) -> AutoDecision? {
        guard let flag = LoopDetection.flag(for: item), flag.kind == .overrun else { return nil }
        return AutoDecision(.stopAndReplan, reason: flag.reason)
    }

    /// The model reviews are asked of: the strongest set up, the cheaper
    /// of equals.
    public static func reviewer(among profiles: [ModelProfile]) -> ModelProfile? {
        profiles.max { rank($0) < rank($1) }
    }

    /// A model stronger than the one a task last ran with, or nil.
    public static func stronger(than item: WorkItem, among profiles: [ModelProfile]) -> ModelProfile? {
        guard let model = item.runs.last?.model ?? item.assignment?.model else { return reviewer(among: profiles) }
        let current = profiles.first { $0.choice == model }?.tier ?? ModelRouting.tier(ofModelNamed: model.model)
        return profiles.filter { $0.tier > current && $0.choice != model }.max { rank($0) < rank($1) }
    }

    /// Whether a path looks like it holds keys or credentials.
    public static func touchesCredentials(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == ".env" || name.hasPrefix(".env.") || name == ".netrc" || name.hasPrefix("id_rsa")
            || name.hasPrefix("id_ed25519") {
            return true
        }
        if [".pem", ".p12", ".key", ".keychain", ".mobileprovision"].contains(where: name.hasSuffix) { return true }
        return ["secret", "credential", "password", "apikey", "api_key"].contains(where: name.contains)
    }

    /// Sent back, unless it was sent back too often: then a stronger model
    /// takes it once, and after that the owner decides.
    private static func sendBack(_ item: WorkItem, on board: Board, reason: String, notes: String,
                                 profiles: [ModelProfile]) -> AutoDecision {
        guard board.sentBackInARow(of: item) >= roundsBeforeReassign else {
            return AutoDecision(.sendBack, reason: reason, notes: notes)
        }
        let reassigned = board.decisions.contains { $0.item == item.number && $0.decision == .reassign }
        if !reassigned, let better = stronger(than: item, among: profiles) {
            return AutoDecision(.reassign, reason: "Sent back \(roundsBeforeReassign) times; \(better.name) takes it. \(reason)",
                                notes: notes, model: better)
        }
        return AutoDecision(.askOwner, reason: "Sent back again after a stronger model tried. \(reason)")
    }

    private static func rank(_ profile: ModelProfile) -> (Int, Int, Double) {
        (profile.tier.rawValue, profile.tools ? 1 : 0, -profile.outputPrice)
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(line.trimmingCharacters(in: .whitespaces).prefix(200))
    }
}

extension Board {
    /// What was decided about a task, oldest first.
    public func decisions(about item: WorkItem) -> [DecisionEntry] {
        decisions.filter { $0.item == item.number }
    }

    /// The task's last run was held for work the person has not committed.
    public func isHeld(_ item: WorkItem) -> Bool {
        guard let run = item.runs.last?.id else { return false }
        return decisions.contains { $0.item == item.number && $0.run == run && $0.decision == .hold }
    }

    /// Carries out a decision and writes it to the decision log. Approving
    /// goes through `review`, so the work is merged into the board's branch
    /// exactly as a person's Approve merges it; nothing here moves the
    /// person's own branch.
    @discardableResult
    public mutating func decide(_ id: UUID, _ decision: AutoDecision, by model: String, now: Date) -> DecisionEntry? {
        guard let item = self.item(id) else { return nil }
        switch decision.decision {
        case .approve:
            review(id, Review(verdict: .approved, notes: decision.reason, by: model, date: now), now: now)
        case .sendBack, .reassign:
            let notes = decision.notes.isEmpty ? decision.reason : decision.notes
            review(id, Review(verdict: .changesRequested, notes: notes, by: model, date: now), now: now)
            if decision.decision == .reassign, let better = decision.model {
                update(id, now: now) { task in
                    task.assignment = Assignment(model: better.choice, label: better.name, reason: decision.reason,
                                                 source: .supervisor, accepted: true, date: now)
                }
            }
        case .askOwner, .hold, .stopAndReplan:
            _ = note(id, "\(decision.decision.title): \(decision.reason)", author: model, now: now)
            log("\(model): \(decision.decision.title.lowercased()) \(item.key)", by: .supervisor, item: item.number,
                now: now)
        }
        let entry = DecisionEntry(date: now, item: item.number, task: item.key, decision: decision.decision,
                                  reason: decision.reason, model: model, run: item.runs.last?.id)
        decisions.append(entry)
        if decisions.count > AutoReview.logLimit { decisions.removeFirst(decisions.count - AutoReview.logLimit) }
        return entry
    }
}