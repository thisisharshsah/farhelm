import Combine
import Foundation

/// One task the agent is working on, in one chat. Every chat can have its
/// own: each keeps its own record of what it did, its plan, its status, its
/// question or approval waiting on you, and its own shell, so tasks in
/// different chats run side by side without touching each other.
@MainActor
final class AgentJob: ObservableObject, Identifiable {
    let id = UUID()
    /// The chat it works in, and the turn that shows it.
    let chatID: UUID
    let turnID: UUID
    let task: String
    /// Where it starts, and the chat's repository ("" when it has none),
    /// as they were when it started: switching chats never moves it.
    let startDirectory: String
    let repository: String

    /// Its own shell: commands from different chats never share one.
    let shell = AgentShell()

    @Published var status: String?
    @Published var pendingApproval: AgentProposal?
    @Published var pendingQuestion: AgentQuestion?
    @Published var isPlanning = false
    @Published var isActing = false
    /// Waiting for the mouse and keyboard while another chat's task uses them.
    @Published var waitingForScreen = false

    var approval: CheckedContinuation<AgentDecision, Never>?
    var questionAnswer: CheckedContinuation<String?, Never>?
    var run: Task<Void, Never>?

    /// What it has done, newest last, and what each line was for.
    @Published var log: [String] = [] {
        didSet {
            guard log.count > oldValue.count, let why = currentWhy else { return }
            for index in oldValue.count..<log.count { whys[index] = why }
        }
    }
    var currentWhy: String?
    var whys: [Int: String] = [:]
    /// A question's choices, by its log line.
    var asks: [Int: [String]] = [:]
    /// A write or edit: the file, lines added and taken out, its length.
    var changes: [Int: (path: String, added: Int, removed: Int, lines: Int)] = [:]
    /// The end of each command's output, by its log line.
    var outputs: [Int: String] = [:]
    /// What the model has been told so far, results included.
    var context: [String] = []
    var plan: [PlanItem] = []
    /// What it last told the user.
    var lastReport = ""
    /// An inline edit's file, shown side by side once done.
    var inlineReviewPath: String?
    /// It holds the mouse and keyboard.
    var holdsScreen = false

    init(chatID: UUID, turnID: UUID, task: String, startDirectory: String, repository: String) {
        self.chatID = chatID
        self.turnID = turnID
        self.task = task
        self.startDirectory = startDirectory
        self.repository = repository
    }

    /// Ends whatever it waits on, as a no.
    func releaseWaits() {
        approval?.resume(returning: .deny)
        approval = nil
        pendingApproval = nil
        questionAnswer?.resume(returning: nil)
        questionAnswer = nil
        pendingQuestion = nil
    }
}

/// The mouse and keyboard, one task at a time: a task that clicks or types
/// holds them until it is done with that work, and others that need them
/// wait their turn. Shell, file and browser work never waits here.
@MainActor
final class ScreenTurns {
    static let shared = ScreenTurns()

    private(set) var holder: UUID?
    private var queue: [(id: UUID, resume: CheckedContinuation<Bool, Never>)] = []

    /// Waits until this task holds the screen. False if it was cancelled
    /// while waiting.
    func acquire(_ job: AgentJob) async -> Bool {
        if holder == job.id { return true }
        if holder == nil {
            holder = job.id
            job.holdsScreen = true
            return true
        }
        job.waitingForScreen = true
        defer { job.waitingForScreen = false }
        let granted: Bool = await withCheckedContinuation { (resume: CheckedContinuation<Bool, Never>) in
            self.queue.append((job.id, resume))
        }
        if granted { job.holdsScreen = true }
        return granted
    }

    /// Lets the next task have it.
    func release(_ job: AgentJob) {
        // Still waiting: take it out of the line.
        if let index = queue.firstIndex(where: { $0.id == job.id }) {
            queue.remove(at: index).resume.resume(returning: false)
        }
        guard holder == job.id else { return }
        job.holdsScreen = false
        if queue.isEmpty {
            holder = nil
        } else {
            let next = queue.removeFirst()
            holder = next.id
            next.resume.resume(returning: true)
        }
    }
}
