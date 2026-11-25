import SwiftUI

// Sample data for the board mock-ups of T-56 (docs/design/board-concepts.md).
// Nothing here reads a real board, so a picture never shows anyone's own
// work. Role titles follow ADR 0016's proposals; the model names (m1 to m4)
// are stand-ins, since the registry's names are the owner's to choose.

/// How a task stands, as its pill says it. Finer than the board's columns:
/// a task in progress can be working, waiting for the person or stuck.
enum MockState: String, CaseIterable, Identifiable {
    case working = "Working"
    case waiting = "Waiting for you"
    case review = "Review"
    case stuck = "Stuck"
    case done = "Done"

    var id: String { rawValue }

    /// The five fixed state colors and no others. Working takes the accent,
    /// so the look's purple always means work that is moving; the other four
    /// are system tones, which follow light, dark and Increase Contrast.
    var tone: Design.Tone {
        switch self {
        case .working: .accent
        case .waiting: .caution
        case .review: .info
        case .stuck: .critical
        case .done: .positive
        }
    }

    /// A shape for every state as well as a color, so a pill still reads
    /// for someone who cannot tell the colors apart.
    var symbol: String {
        switch self {
        case .working: "arrow.triangle.2.circlepath"
        case .waiting: "hand.raised.fill"
        case .review: "eye.fill"
        case .stuck: "exclamationmark.triangle.fill"
        case .done: "checkmark.circle.fill"
        }
    }

    /// Counted as in progress by the battery: the run is going, paused on a
    /// question or finished and waiting for its review.
    var isMoving: Bool { self == .working || self == .waiting || self == .review }
}

/// The board's five columns (`WorkStatus` in CompanionBoard), repeated here
/// so the mock-ups build without the board package.
enum MockColumn: String, CaseIterable, Identifiable {
    case backlog = "Backlog"
    case todo = "To do"
    case inProgress = "In progress"
    case review = "Review"
    case done = "Done"

    var id: String { rawValue }
}

struct MockSpecialist: Identifiable {
    let id: String
    let role: String
    /// Its number among specialists of one role, or nil for the only one.
    let seat: Int?
    let model: String
    /// Its share of the sprint's token plan.
    let tokensPlan: Int

    var title: String { seat.map { "\(role) \($0)" } ?? role }
}

struct MockTask: Identifiable {
    let id: String
    let title: String
    let column: MockColumn
    let state: MockState?
    let role: String?
    let model: String?
    /// The specialist holding it, or the one that finished it.
    let specialist: String?
    let estimate: Int?
    let used: Int
    let sprint: String

    var overEstimate: Bool { estimate.map { used > $0 } ?? false }
}

struct MockSprint: Identifiable {
    let id: String
    let name: String
    let dates: String
    let active: Bool
    let tokensPlan: Int?
}

enum MockBoard {
    static let name = "Glass board"

    static let specialists: [MockSpecialist] = [
        MockSpecialist(id: "mac-1", role: "Mac engineer", seat: 1, model: "m2", tokensPlan: 120_000),
        MockSpecialist(id: "mac-2", role: "Mac engineer", seat: 2, model: "m2", tokensPlan: 80_000),
        MockSpecialist(id: "designer", role: "Designer", seat: nil, model: "m4", tokensPlan: 60_000),
        MockSpecialist(id: "qa", role: "QA", seat: nil, model: "m3", tokensPlan: 60_000),
        MockSpecialist(id: "writer", role: "Writer", seat: nil, model: "m1", tokensPlan: 60_000),
    ]

    static let sprints: [MockSprint] = [
        MockSprint(id: "s4", name: "Sprint 4", dates: "Nov 24 to Dec 5", active: true, tokensPlan: 400_000),
        MockSprint(id: "backlog", name: "Backlog", dates: "Not in a sprint yet", active: false, tokensPlan: nil),
    ]

    static let tasks: [MockTask] = [
        MockTask(id: "T-62", title: "Group the table by sprint", column: .inProgress, state: .working,
                 role: "Mac engineer", model: "m2", specialist: "mac-1", estimate: 60_000, used: 41_000, sprint: "s4"),
        MockTask(id: "T-63", title: "Battery bar for sprints and specialists", column: .inProgress, state: .stuck,
                 role: "Mac engineer", model: "m2", specialist: "mac-2", estimate: 40_000, used: 95_000, sprint: "s4"),
        MockTask(id: "T-65", title: "Board rules as sentences", column: .inProgress, state: .waiting,
                 role: "Writer", model: "m1", specialist: "writer", estimate: 20_000, used: 12_000, sprint: "s4"),
        MockTask(id: "T-69", title: "Tests for the automatic run limit", column: .inProgress, state: .working,
                 role: "QA", model: "m3", specialist: "qa", estimate: 30_000, used: 18_000, sprint: "s4"),
        MockTask(id: "T-61", title: "Status pills on board cards", column: .review, state: .review,
                 role: "Designer", model: "m4", specialist: "designer", estimate: 40_000, used: 36_000, sprint: "s4"),
        MockTask(id: "T-64", title: "Workload view", column: .todo, state: nil,
                 role: "Mac engineer", model: "m2", specialist: nil, estimate: 80_000, used: 0, sprint: "s4"),
        MockTask(id: "T-67", title: "Task chat in the side panel", column: .todo, state: nil,
                 role: "Mac engineer", model: "m2", specialist: nil, estimate: 70_000, used: 0, sprint: "s4"),
        MockTask(id: "T-60", title: "Specialist chip on cards", column: .done, state: .done,
                 role: "Mac engineer", model: "m2", specialist: "mac-1", estimate: 30_000, used: 27_000, sprint: "s4"),
        MockTask(id: "T-66", title: "Snapshot target for mock-ups", column: .done, state: .done,
                 role: "QA", model: "m3", specialist: "qa", estimate: 25_000, used: 22_000, sprint: "s4"),
        MockTask(id: "T-68", title: "Board concepts write-up", column: .done, state: .done,
                 role: "Writer", model: "m1", specialist: "writer", estimate: 30_000, used: 18_000, sprint: "s4"),
        MockTask(id: "T-70", title: "Timeline of runs", column: .backlog, state: nil,
                 role: "Mac engineer", model: nil, specialist: nil, estimate: 90_000, used: 0, sprint: "backlog"),
        MockTask(id: "T-71", title: "Sprint report in the Project Manager's chat", column: .backlog, state: nil,
                 role: "Writer", model: nil, specialist: nil, estimate: 20_000, used: 0, sprint: "backlog"),
        MockTask(id: "T-72", title: "The board on iPhone", column: .backlog, state: nil,
                 role: nil, model: nil, specialist: nil, estimate: nil, used: 0, sprint: "backlog"),
        MockTask(id: "T-73", title: "Move cards between sprints", column: .backlog, state: nil,
                 role: "Mac engineer", model: nil, specialist: nil, estimate: 50_000, used: 0, sprint: "backlog"),
    ]

    static var active: MockSprint { sprints[0] }

    static func tasks(in sprint: MockSprint) -> [MockTask] {
        tasks.filter { $0.sprint == sprint.id }
    }

    static func task(_ id: String) -> MockTask {
        tasks.first { $0.id == id } ?? tasks[0]
    }

    static func running(_ specialist: MockSpecialist) -> [MockTask] {
        tasks.filter { $0.specialist == specialist.id && $0.column == .inProgress }
    }

    /// Ready tasks wait for a role, not a person: any free specialist of the
    /// role takes the next one (ADR 0016, section 2).
    static func queued(for role: String) -> [MockTask] {
        tasks.filter { $0.role == role && $0.column == .todo }
    }

    static func sprintTasks(of specialist: MockSpecialist) -> [MockTask] {
        tasks.filter { $0.specialist == specialist.id && $0.sprint == active.id }
    }

    static func used(by specialist: MockSpecialist) -> Int {
        sprintTasks(of: specialist).map(\.used).reduce(0, +)
    }

    static var sprintUsed: Int { tasks(in: active).map(\.used).reduce(0, +) }

    /// One run per specialist, as ADR 0016 section 4 sets it.
    static var runLimit: Int { specialists.count }

    static var runningCount: Int { specialists.filter { !running($0).isEmpty }.count }

    static func symbol(for role: String?) -> String {
        switch role {
        case "Mac engineer": "laptopcomputer"
        case "Designer": "paintpalette"
        case "QA": "checkmark.seal"
        case "Writer": "text.alignleft"
        default: "questionmark.circle"
        }
    }
}

extension Int {
    /// Tokens as people say them: 41k.
    var tokenText: String { self >= 1000 ? "\(self / 1000)k" : "\(self)" }
}