import Combine
import CompanionBoard
import Foundation

/// Who gave the answer a task was waiting for.
enum Answerer: Equatable {
    case person
    /// The project's supervisor, in the person's place: its model as
    /// shown, and the reason it gave.
    case supervisor(String, reason: String)

    /// For the record of what the agent did: who let a step run.
    var record: String {
        switch self {
        case .person: return "you"
        case .supervisor(let model, _): return "the supervisor (\(model)), in your place"
        }
    }
}

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
    /// When a wait in place ends: the time left is counted down where it
    /// shows, so the status does not change (and redraw) every second.
    @Published var statusUntil: Date?
    @Published var pendingApproval: AgentProposal?
    @Published var pendingQuestion: AgentQuestion?
    /// What the project's supervisor recommends for the approval or the
    /// question it waits on, in a project that is run from a board. On a
    /// board set to take its answer, what it recommends is the answer.
    @Published var advice: ReviewAdvice?
    @Published var isPlanning = false
    @Published var isActing = false
    /// Waiting for the mouse and keyboard while another chat's task uses them.
    @Published var waitingForScreen = false

    var approval: CheckedContinuation<AgentDecision, Never>?
    /// What the person wrote while it worked, for the agent's next round.
    /// A wait in progress ends early when something arrives here.
    var inbox: [String] = []
    /// Hosts a sign-in terminal was opened for in this task, so it opens once.
    var signInOpened: Set<String> = []
    /// A terminal beside the chat was opened in this task for the person.
    var terminalOpened = false
    var questionAnswer: CheckedContinuation<String?, Never>?
    var run: Task<Void, Never>?
    /// Who answered what it last waited on. It is set with the answer and
    /// read once, by the task as it carries on (`takeAnswerer`).
    private(set) var answerer: Answerer = .person
    /// How many times in a row the supervisor has carried a long task on
    /// when it checked in. After two, the check-in is the person's.
    var carriedOn = 0
    /// How it came to an end, where that is known as it happens: a no to
    /// a step, a stop at its check-in. Otherwise it is told when it ends
    /// (`howItEnded`).
    var ending: WorkRun.Ending?

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
    /// Who answered a question when it was not the person, by its log line.
    var answeredBy: [Int: String] = [:]
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
    /// The engine and model it works with when that is not the one in
    /// use: a run from a board works with the model its task was given.
    var engine: EngineChoice?
    /// How it ended, once it reported: true when it failed. nil while it
    /// runs, and when it was stopped before it reported.
    var endedFailed: Bool?

    init(chatID: UUID, turnID: UUID, task: String, startDirectory: String, repository: String) {
        self.chatID = chatID
        self.turnID = turnID
        self.task = task
        self.startDirectory = startDirectory
        self.repository = repository
    }

    /// The project's supervisor is answering what it waits on, in the
    /// person's place: it is being asked, or has answered and the task
    /// is about to carry on with its answer.
    var supervisorAnswering: Bool {
        guard let advice, advice.answers,
              advice.subject == pendingApproval?.id || advice.subject == pendingQuestion?.id else { return false }
        switch advice.state {
        case .asking, .given: return true
        case .left, .nothing: return false
        }
    }

    /// It waits on the person: for a yes or an answer that nobody is
    /// giving in their place.
    var waitsOnPerson: Bool {
        (pendingApproval != nil || pendingQuestion != nil) && !supervisorAnswering
    }

    /// Answers the steps it waits on, for someone other than the person
    /// at the card. False when it waits on none.
    @discardableResult
    func settle(_ decision: AgentDecision, by answerer: Answerer) -> Bool {
        guard let waiting = approval else { return false }
        approval = nil
        self.answerer = answerer
        waiting.resume(returning: decision)
        return true
    }

    /// Answers the question it waits on, the same way.
    @discardableResult
    func settle(answer: String, by answerer: Answerer) -> Bool {
        guard let waiting = questionAnswer else { return false }
        questionAnswer = nil
        self.answerer = answerer
        waiting.resume(returning: answer)
        return true
    }

    /// Who answered what it waited on. The next answer is the person's
    /// again, unless it is given otherwise.
    func takeAnswerer() -> Answerer {
        let last = answerer
        answerer = .person
        return last
    }

    /// A step was refused, or the task was told to stop where it asked:
    /// by the person, or by the supervisor in their place.
    func declined(by answerer: Answerer) {
        ending = answerer == Answerer.person ? WorkRun.Ending.person : WorkRun.Ending.supervisor
    }

    /// How it came to an end: what was noted as it happened; by itself
    /// when it reported; otherwise it was stopped from outside before it
    /// reported, by the person (or by quitting, when every task is
    /// stopped at once).
    func howItEnded(stoppingAll: Bool) -> WorkRun.Ending {
        if let ending { return ending }
        if endedFailed != nil { return WorkRun.Ending.itself }
        return stoppingAll ? WorkRun.Ending.quit : WorkRun.Ending.person
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
