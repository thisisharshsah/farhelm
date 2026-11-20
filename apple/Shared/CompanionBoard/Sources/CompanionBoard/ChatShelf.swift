import Foundation

/// Where a project's chats are listed: the supervisor's on top, then the
/// tasks that wait on the person, the tasks being worked on, the person's
/// own chats, and the rest put away.
///
/// A task has one chat, which all its runs share (`WorkItem.chat`). It
/// follows its task: listed while the task waits on someone or is being
/// worked on (its approved work being merged counts), and put away once
/// the task is done, shelved in the backlog, under an earlier goal or
/// taken off the board. The person's own chats
/// stay where they are whatever runs in them (so a chat being used never
/// jumps), and fold away after `idle` unused. Plain rules, with the time
/// handed in.
public enum ChatShelf {
    /// Where a chat is listed.
    public enum Place: String, Equatable, Sendable, CaseIterable {
        /// The project's supervisor's chat, pinned on top.
        case supervisor
        /// A task's chat whose task waits on the person.
        case needsYou
        /// A task's chat whose task is being worked on, or will be by itself.
        case running
        /// One of the person's own chats, used lately.
        case mine
        /// One of the person's own chats, not used for a while.
        case older
        /// Put away: its task is done, shelved, under an earlier goal or
        /// off the board; it is an earlier run's chat from before a task's
        /// runs shared one; or the person archived it.
        case archived
    }

    /// What a task waits on the person for.
    public enum Need: String, Equatable, Sendable {
        /// An agent's question, or a step it needs a yes for.
        case answer
        /// A finished run, to approve or send back.
        case review
        /// The review asked for changes, and nothing will start them by itself.
        case redo
        /// A run stopped before the task was done, and nothing will take
        /// it up by itself.
        case stopped
        /// The task is done, but its work could not be merged: something
        /// only the person can settle stands in the way.
        case merge
    }

    /// What a chat was made for, when it was made for a board.
    public enum Purpose: Equatable, Sendable {
        case supervisor
        case task(UUID?)
    }

    /// A chat, as these rules need it.
    public struct Chat: Equatable, Sendable {
        public var id: UUID
        /// What it was made for; nil for one of the person's own.
        public var purpose: Purpose?
        public var lastActivity: Date
        /// The person archived it.
        public var archived: Bool
        /// An agent's task is going on in it.
        public var working: Bool
        /// That task waits on the person: a question, or a step that needs a yes.
        public var waiting: Bool

        public init(id: UUID, purpose: Purpose? = nil, lastActivity: Date, archived: Bool = false,
                    working: Bool = false, waiting: Bool = false) {
            self.id = id
            self.purpose = purpose
            self.lastActivity = lastActivity
            self.archived = archived
            self.working = working
            self.waiting = waiting
        }
    }

    /// Where a chat is listed, with its task and what the task waits on.
    public struct Spot: Equatable, Sendable {
        public var place: Place
        /// The task whose chat it is.
        public var task: UUID?
        /// For a task that waits on the person: what for.
        public var need: Need?

        public init(place: Place, task: UUID? = nil, need: Need? = nil) {
            self.place = place
            self.task = task
            self.need = need
        }
    }

    /// How long one of the person's own chats goes unused before it is
    /// folded into Older.
    public static let idle: TimeInterval = 14 * 86_400

    /// Where a chat of a project is listed. `board` is the project's
    /// board, when it has one; `reviewing` the tasks whose finished run
    /// the supervisor is checking right now.
    public static func spot(of chat: Chat, board: Board?, reviewing: Set<UUID> = [], now: Date) -> Spot {
        if let board, board.supervisorChat == chat.id { return Spot(place: .supervisor) }
        if let board, let item = board.item(runIn: chat.id) {
            return spot(ofTaskChat: chat, item: item, board: board, reviewing: reviewing)
        }
        // What waits on the person is never put away.
        if chat.waiting { return Spot(place: chat.purpose == nil ? .mine : .needsYou, need: .answer) }
        if let purpose = chat.purpose {
            // Made for the board, which no longer knows it: its task was
            // taken off, or the supervisor has a newer chat.
            if chat.working { return Spot(place: .running) }
            if case .task(let task) = purpose { return Spot(place: .archived, task: task) }
            return Spot(place: .archived)
        }
        if chat.working { return Spot(place: .mine) }
        if chat.archived { return Spot(place: .archived) }
        return Spot(place: now.timeIntervalSince(chat.lastActivity) > idle ? .older : .mine)
    }

    private static func spot(ofTaskChat chat: Chat, item: WorkItem, board: Board, reviewing: Set<UUID>) -> Spot {
        let task = item.id
        // What waits on the person, and what is going on, come first,
        // wherever the task stands.
        if chat.waiting { return Spot(place: .needsYou, task: task, need: .answer) }
        if chat.working || item.activeRun?.conversation == chat.id || reviewing.contains(task) {
            return Spot(place: .running, task: task)
        }
        // A chat of one of its earlier runs: its own chat is a newer one.
        guard item.chat == chat.id else { return Spot(place: .archived, task: task) }
        // Approved work that is not merged yet, under whichever goal: it
        // is being merged, or waits on the person to be.
        if board.mergeWaitsOnPerson(item) { return Spot(place: .needsYou, task: task, need: .merge) }
        if board.waitingToMerge.contains(where: { $0.id == task }) { return Spot(place: .running, task: task) }
        guard item.goal == board.currentGoal else { return Spot(place: .archived, task: task) }
        switch item.status {
        case .done, .backlog:
            return Spot(place: .archived, task: task)
        case .review:
            return Spot(place: .needsYou, task: task, need: .review)
        case .todo, .inProgress:
            if board.movesOnByItself(item) { return Spot(place: .running, task: task) }
            let redo = item.runs.last?.review?.verdict == .changesRequested
            return Spot(place: .needsYou, task: task, need: redo ? .redo : .stopped)
        }
    }
}
