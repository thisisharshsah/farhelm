import Foundation

/// Where a task stands on the board. The five columns, in order.
public enum WorkStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case backlog
    case todo
    case inProgress = "in_progress"
    case review
    case done

    public var id: String { rawValue }

    /// The column's name as shown.
    public var title: String {
        switch self {
        case .backlog: return "Backlog"
        case .todo: return "To do"
        case .inProgress: return "In progress"
        case .review: return "Review"
        case .done: return "Done"
        }
    }

    /// A status as a person or a model may write it: "In progress",
    /// "in-progress", "doing", "to do", "complete".
    public init?(loose text: String) {
        let word = text.lowercased().filter { $0.isLetter }
        switch word {
        case "backlog", "later", "icebox": self = .backlog
        case "todo", "ready", "next", "planned", "open": self = .todo
        case "inprogress", "doing", "started", "active", "wip", "working": self = .inProgress
        case "review", "inreview", "reviewing", "verify", "qa": self = .review
        case "done", "complete", "completed", "closed", "finished", "shipped": self = .done
        default: return nil
        }
    }
}

/// How much a task matters next to the others.
public enum WorkPriority: String, Codable, CaseIterable, Identifiable, Sendable, Comparable {
    case low, medium, high, urgent

    public var id: String { rawValue }

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// Its place in the order, low to urgent.
    public var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .urgent: return 3
        }
    }

    public static func < (left: WorkPriority, right: WorkPriority) -> Bool { left.rank < right.rank }

    public init?(loose text: String) {
        switch text.lowercased().filter({ $0.isLetter || $0.isNumber }) {
        case "low", "minor", "p3", "p4": self = .low
        case "medium", "normal", "med", "p2": self = .medium
        case "high", "major", "important", "p1": self = .high
        case "urgent", "critical", "blocker", "p0": self = .urgent
        default: return nil
        }
    }
}

/// What kind of work a task is. It helps choose a model for it.
public enum WorkKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case feature, bug, refactor, test, docs, research, design, ops, chore

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .docs: return "Docs"
        case .ops: return "Ops"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    public init?(loose text: String) {
        switch text.lowercased().filter({ $0.isLetter }) {
        case "feature", "feat", "story", "enhancement": self = .feature
        case "bug", "fix", "bugfix", "defect": self = .bug
        case "refactor", "refactoring", "cleanup": self = .refactor
        case "test", "tests", "testing": self = .test
        case "docs", "doc", "documentation", "writing": self = .docs
        case "research", "spike", "investigation", "investigate", "analysis": self = .research
        case "design", "architecture", "ux", "ui": self = .design
        case "ops", "devops", "infra", "infrastructure", "deploy", "release", "ci": self = .ops
        case "chore", "task", "maintenance", "setup": self = .chore
        default: return nil
        }
    }
}

/// An engine and one of its models, under the names the app keeps them:
/// the engine ("anthropic", "ollama", "subscription"), for a subscription
/// tool or one of More services the tool or service ("claude-code",
/// "gemini"), and the model ("" leaves the pick to the engine).
public struct ModelChoice: Codable, Hashable, Sendable {
    public var engine: String
    public var tool: String?
    public var model: String

    public init(engine: String, tool: String? = nil, model: String) {
        self.engine = engine
        self.tool = tool
        self.model = model
    }

    /// One text that names it, for dictionaries and saved settings.
    public var key: String { "\(engine)|\(tool ?? "")|\(model)" }
}

/// The model a task is given to, who proposed it and why.
public struct Assignment: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// The supervisor proposed it, with its reason.
        case supervisor
        /// Worked out from the task's kind and size, without asking a model.
        case rule
        /// A person chose it.
        case person
    }

    public var model: ModelChoice
    /// The model's name as shown when it was assigned.
    public var label: String
    public var reason: String
    public var source: Source
    /// A person agreed to it, or chose it. A suggestion nobody has
    /// answered yet is still used when the task runs.
    public var accepted: Bool
    public var date: Date

    public init(model: ModelChoice, label: String, reason: String, source: Source, accepted: Bool, date: Date) {
        self.model = model
        self.label = label
        self.reason = reason
        self.source = source
        self.accepted = accepted
        self.date = date
    }
}

/// What a check of a finished run concluded.
public struct Review: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        case approved
        case changesRequested = "changes_requested"
    }

    public var verdict: Verdict
    public var notes: String
    /// Who checked: a model's name, or "You".
    public var by: String
    public var date: Date

    /// What `by` says when a person checked it.
    public static let person = "You"

    /// A person checked it, not a model.
    public var byPerson: Bool { by == Self.person }

    public init(verdict: Verdict, notes: String, by: String, date: Date) {
        self.verdict = verdict
        self.notes = notes
        self.by = by
        self.date = date
    }
}

/// One attempt on a task: a chat where an agent worked on it with one
/// model. A task may have none, one, or several (a retry is a new run).
public struct WorkRun: Codable, Identifiable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case running, succeeded, failed, stopped
    }

    /// How a run came to an end, where the app could tell.
    public enum Ending: String, Codable, Sendable {
        /// By itself: it reported that it finished, or failed on its own
        /// (an error, a time limit, rounds without a step).
        case itself
        /// The person stopped it, or said no to a step: theirs to take
        /// up again.
        case person
        /// The supervisor said no in the person's place: the person
        /// reads why.
        case supervisor
        /// The app was quit under it.
        case quit
    }

    public var id: UUID
    /// The chat the run works in. Its tokens are counted from there.
    public var conversation: UUID
    public var model: ModelChoice
    public var modelLabel: String
    public var startedAt: Date
    public var endedAt: Date?
    public var outcome: Outcome
    /// The start of what the agent reported at the end.
    public var report: String?
    /// The check that decided what became of the run's task.
    public var review: Review?
    /// What the supervisor recommends while the task waits in Review for
    /// a person: advice, which moves nothing.
    public var advice: Review?
    /// How it came to an end. nil while it runs, and for runs from
    /// before this was kept.
    public var ending: Ending?
    /// It carries on from the run before it at the supervisor's word:
    /// the same task, taken up where that run stopped. (nil is no.)
    public var carriesOn: Bool?
    /// What the project's checks found on its work, once it finished
    /// (`Checks`): empty when none of them cover what it changed; nil
    /// when none were run (the project has none, or it did not finish).
    public var checks: [CheckResult]?

    public init(id: UUID = UUID(), conversation: UUID, model: ModelChoice, modelLabel: String, startedAt: Date,
                endedAt: Date? = nil, outcome: Outcome = .running, report: String? = nil, review: Review? = nil,
                advice: Review? = nil, ending: Ending? = nil, carriesOn: Bool? = nil, checks: [CheckResult]? = nil) {
        self.id = id
        self.conversation = conversation
        self.model = model
        self.modelLabel = modelLabel
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.report = report
        self.review = review
        self.advice = advice
        self.ending = ending
        self.carriesOn = carriesOn
        self.checks = checks
    }

    public var isRunning: Bool { outcome == .running }
}

/// Something said about a task: by the supervisor, a reviewer or a person.
public struct WorkNote: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var author: String
    public var text: String

    public init(id: UUID = UUID(), date: Date, author: String, text: String) {
        self.id = id
        self.date = date
        self.author = author
        self.text = text
    }
}

/// A task: planned work on a project's board.
public struct WorkItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// Its number on this board, counted up from 1 and never reused: T-7.
    public var number: Int
    public var title: String
    /// What is to be done, as the agent that works on it reads it.
    public var details: String
    /// What has to be true for the task to count as done.
    public var acceptance: [String]
    public var status: WorkStatus
    public var priority: WorkPriority
    public var kind: WorkKind
    /// The phase of the plan it belongs to, when the plan has phases.
    public var milestone: String?
    /// Numbers of the tasks that have to be done first.
    public var dependsOn: [Int]
    /// What the supervisor expects it to take, in tokens.
    public var estimateTokens: Int?
    /// The files and folders it is planned to change, from the project's
    /// folder. No two tasks whose paths overlap run at once (`Leases`);
    /// empty is not known, which keeps it apart from every other task.
    public var paths: [String] = []
    public var assignment: Assignment?
    /// The model the supervisor last picked for it. It stays when a
    /// person chooses another, so the choice still shows what was advised.
    public var suggestion: Assignment? = nil
    public var runs: [WorkRun]
    public var notes: [WorkNote]
    public var createdAt: Date
    public var updatedAt: Date
    /// When work first began, and when it was done.
    public var startedAt: Date?
    public var finishedAt: Date?
    /// The day it is wanted by, when one was set.
    public var dueAt: Date?
    /// Its place in its column: lower is higher up.
    public var order: Double
    /// The goal it is under. The board sets it; see `BoardGoal`.
    public var goal: UUID?
    /// Its own copy of the repository, where its runs work: open while
    /// it is worked on, then merged or thrown away (`WorkingCopy`). nil
    /// until its first run, and for a task that works in the project's
    /// folder.
    public var workingCopy: WorkingCopy? = nil

    public init(id: UUID = UUID(), number: Int, title: String, details: String = "", acceptance: [String] = [],
                status: WorkStatus = .todo, priority: WorkPriority = .medium, kind: WorkKind = .feature,
                milestone: String? = nil, dependsOn: [Int] = [], estimateTokens: Int? = nil,
                assignment: Assignment? = nil, runs: [WorkRun] = [], notes: [WorkNote] = [],
                createdAt: Date, updatedAt: Date? = nil, startedAt: Date? = nil, finishedAt: Date? = nil,
                dueAt: Date? = nil, order: Double = 0, goal: UUID? = nil) {
        self.id = id
        self.number = number
        self.title = title
        self.details = details
        self.acceptance = acceptance
        self.status = status
        self.priority = priority
        self.kind = kind
        self.milestone = milestone
        self.dependsOn = dependsOn
        self.estimateTokens = estimateTokens
        self.assignment = assignment
        self.runs = runs
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.dueAt = dueAt
        self.order = order
        self.goal = goal
    }

    /// The name it goes by: "T-7".
    public var key: String { "T-\(number)" }

    /// The run going on now, if one is.
    public var activeRun: WorkRun? { runs.last { $0.isRunning } }

    /// The chats its runs worked in.
    public var conversations: [UUID] { runs.map(\.conversation) }

    /// The task's chat: the one its runs share, which is its latest run's.
    /// (Tasks run before runs shared a chat have one per run; the latest
    /// is the one that counts.) nil before its first run.
    public var chat: UUID? { runs.last?.conversation }

    private enum CodingKeys: String, CodingKey {
        case id, number, title, details, acceptance, status, priority, kind, milestone, dependsOn, estimateTokens
        case assignment, suggestion, runs, notes, createdAt, updatedAt, startedAt, finishedAt, dueAt, order, goal
        case workingCopy, paths
    }

    /// Read field by field, so a board saved before a field existed still
    /// loads: only what names the task is required.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        number = try values.decode(Int.self, forKey: .number)
        title = try values.decode(String.self, forKey: .title)
        details = try values.decodeIfPresent(String.self, forKey: .details) ?? ""
        acceptance = try values.decodeIfPresent([String].self, forKey: .acceptance) ?? []
        status = try values.decodeIfPresent(WorkStatus.self, forKey: .status) ?? .todo
        priority = try values.decodeIfPresent(WorkPriority.self, forKey: .priority) ?? .medium
        kind = try values.decodeIfPresent(WorkKind.self, forKey: .kind) ?? .feature
        milestone = try values.decodeIfPresent(String.self, forKey: .milestone)
        dependsOn = try values.decodeIfPresent([Int].self, forKey: .dependsOn) ?? []
        estimateTokens = try values.decodeIfPresent(Int.self, forKey: .estimateTokens)
        assignment = try values.decodeIfPresent(Assignment.self, forKey: .assignment)
        suggestion = try values.decodeIfPresent(Assignment.self, forKey: .suggestion)
        runs = try values.decodeIfPresent([WorkRun].self, forKey: .runs) ?? []
        notes = try values.decodeIfPresent([WorkNote].self, forKey: .notes) ?? []
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try values.decodeIfPresent(Date.self, forKey: .finishedAt)
        dueAt = try values.decodeIfPresent(Date.self, forKey: .dueAt)
        order = try values.decodeIfPresent(Double.self, forKey: .order) ?? Double(number)
        goal = try values.decodeIfPresent(UUID.self, forKey: .goal)
        workingCopy = try values.decodeIfPresent(WorkingCopy.self, forKey: .workingCopy)
        paths = try values.decodeIfPresent([String].self, forKey: .paths) ?? []
    }
}
