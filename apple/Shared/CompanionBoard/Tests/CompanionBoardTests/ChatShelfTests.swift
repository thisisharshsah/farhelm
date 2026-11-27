import XCTest
@testable import CompanionBoard

private let project = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let model = ModelChoice(engine: "anthropic", model: "m")

private func minutes(_ count: Double) -> Date { t0.addingTimeInterval(count * 60) }

private func attempt(in chat: UUID, at minute: Double = 0) -> WorkRun {
    WorkRun(conversation: chat, model: model, modelLabel: "M", startedAt: minutes(minute))
}

final class ChatShelfTests: XCTestCase {
    private let chat = UUID()

    /// Where `chat` is listed, as it stands.
    private func spot(_ board: Board?, waiting: Bool = false, working: Bool = false,
                      purpose: ChatShelf.Purpose? = nil, reviewing: Set<UUID> = [], daysUnused: Double = 0,
                      archived: Bool = false) -> ChatShelf.Spot {
        let seen = ChatShelf.Chat(id: chat, purpose: purpose, lastActivity: t0.addingTimeInterval(-daysUnused * 86_400),
                                  archived: archived, working: working, waiting: waiting)
        return ChatShelf.spot(of: seen, board: board, reviewing: reviewing, now: t0)
    }

    /// A board with one task, run once in `chat` and ended as given.
    private func ended(_ outcome: WorkRun.Outcome, _ ending: WorkRun.Ending, autopilot: Bool = false,
                       answers: Bool = false) -> (board: Board, task: UUID) {
        var board = Board(project: project, now: t0)
        board.settings.autopilot = autopilot
        board.settings.followsAdvice = answers
        let item = board.add(title: "Work", details: "Do the work.", by: .person, now: t0)
        board.beginRun(item.id, attempt(in: chat), by: .person, now: t0)
        board.endRun(in: chat, outcome: outcome, report: "", ending: ending, now: minutes(5))
        return (board, item.id)
    }

    func testTheSupervisorsChatIsPinnedOnTop() {
        var board = Board(project: project, now: t0)
        board.supervisorChat = chat
        XCTAssertEqual(spot(board).place, .supervisor)
    }

    func testThePersonsOwnChatsAreListedByWhenTheyWereUsed() {
        XCTAssertEqual(spot(nil, daysUnused: 1).place, .mine)
        XCTAssertEqual(spot(nil, daysUnused: 15).place, .older)
        XCTAssertEqual(spot(nil, archived: true).place, .archived)
        // One in use stays where it is, however old or put away.
        XCTAssertEqual(spot(nil, working: true, daysUnused: 30, archived: true).place, .mine)
        XCTAssertEqual(spot(nil, waiting: true, daysUnused: 30), ChatShelf.Spot(place: .mine, need: .answer))
    }

    func testATasksChatIsListedWhileItIsWorkedOnOrWaitsOnThePerson() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        board.beginRun(item.id, attempt(in: chat), by: .person, now: t0)
        XCTAssertEqual(spot(board, working: true), ChatShelf.Spot(place: .running, task: item.id))
        XCTAssertEqual(spot(board, waiting: true, working: true),
                       ChatShelf.Spot(place: .needsYou, task: item.id, need: .answer))
        // Finished, it waits in Review for the person, unless the supervisor is checking it.
        board.endRun(in: chat, outcome: .succeeded, report: "Done.", ending: .itself, now: minutes(5))
        XCTAssertEqual(spot(board), ChatShelf.Spot(place: .needsYou, task: item.id, need: .review))
        XCTAssertEqual(spot(board, reviewing: [item.id]).place, .running)
        // Approved, it is put away.
        board.review(item.id, Review(verdict: .approved, notes: "", by: "You", date: minutes(6)), now: minutes(6))
        XCTAssertEqual(spot(board), ChatShelf.Spot(place: .archived, task: item.id))
    }

    func testAStoppedTaskNeedsThePersonUnlessSomethingTakesItUp() {
        XCTAssertEqual(spot(ended(.failed, .itself).board).need, .stopped)
        XCTAssertEqual(spot(ended(.failed, .itself, autopilot: true).board).place, .running)
        XCTAssertEqual(spot(ended(.failed, .itself, answers: true).board).place, .running)
        // Stopped by the person: theirs, whatever else is on.
        let stopped = ended(.stopped, .person, autopilot: true, answers: true)
        XCTAssertEqual(spot(stopped.board), ChatShelf.Spot(place: .needsYou, task: stopped.task, need: .stopped))
    }

    func testChangesAskedForAreARedoForThePersonUnlessAutopilotStartsIt() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", details: "Do the work.", by: .person, now: t0)
        board.beginRun(item.id, attempt(in: chat), by: .person, now: t0)
        board.endRun(in: chat, outcome: .succeeded, report: "Done.", ending: .itself, now: minutes(5))
        board.review(item.id, Review(verdict: .changesRequested, notes: "Add tests.", by: "You", date: minutes(6)),
                     now: minutes(6))
        XCTAssertEqual(spot(board), ChatShelf.Spot(place: .needsYou, task: item.id, need: .redo))
        board.settings.autopilot = true
        XCTAssertEqual(spot(board).place, .running)
    }

    func testShelvedTasksAndEarlierChatsArePutAway() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        let earlier = UUID()
        board.beginRun(item.id, attempt(in: earlier), by: .person, now: t0)
        board.endRun(in: earlier, outcome: .failed, report: "", ending: .itself, now: minutes(1))
        board.beginRun(item.id, attempt(in: chat, at: 2), by: .person, now: minutes(2))
        board.endRun(in: chat, outcome: .failed, report: "", ending: .itself, now: minutes(3))
        // From before a task's runs shared one chat: the latest is its chat.
        XCTAssertEqual(board.item(item.id)?.chat, chat)
        let old = ChatShelf.Chat(id: earlier, lastActivity: t0)
        XCTAssertEqual(ChatShelf.spot(of: old, board: board, now: t0).place, .archived)
        XCTAssertEqual(spot(board).need, .stopped)
        // Shelved in the backlog.
        board.move(item.id, to: .backlog, by: .person, now: minutes(4))
        XCTAssertEqual(spot(board).place, .archived)
        // Under an earlier goal.
        board.move(item.id, to: .todo, by: .person, now: minutes(5))
        board.setGoal("First", by: .person, now: minutes(5))
        board.startGoal("Second", by: .person, now: minutes(6))
        XCTAssertEqual(spot(board).place, .archived)
    }

    func testAChatMadeForTheBoardThatTheBoardNoLongerKnowsIsPutAway() {
        let board = Board(project: project, now: t0)
        let task = UUID()
        XCTAssertEqual(spot(board, purpose: .task(task)), ChatShelf.Spot(place: .archived, task: task))
        XCTAssertEqual(spot(board, purpose: .supervisor).place, .archived)
        XCTAssertEqual(spot(board, working: true, purpose: .task(task)).place, .running)
    }

    func testAutopilotLeavesATaskForAPersonAfterTwoRunsThatDidNotFinish() {
        var board = Board(project: project, now: t0)
        board.settings.autopilot = true
        let item = board.add(title: "Work", by: .person, now: t0)
        for minute in [0.0, 2.0] {
            board.beginRun(item.id, attempt(in: chat, at: minute), by: .autopilot, now: minutes(minute))
            board.endRun(in: chat, outcome: .failed, report: "", ending: .itself, now: minutes(minute + 1))
        }
        XCTAssertEqual(board.failuresInARow(of: board.item(item.id)!), 2)
        XCTAssertFalse(board.autopilotMayStart(board.item(item.id)!))
        XCTAssertFalse(board.movesOnByItself(board.item(item.id)!))
    }

    func testAutopilotLeavesATaskForAPersonOnceTheReviewKeepsSendingItBack() {
        var board = Board(project: project, now: t0)
        board.settings.autopilot = true
        let item = board.add(title: "Work", details: "Do the work.", by: .person, now: t0)
        func sentBack(at minute: Double, by reviewer: String = "M") {
            board.beginRun(item.id, attempt(in: chat, at: minute), by: .autopilot, now: minutes(minute))
            board.endRun(in: chat, outcome: .succeeded, report: "Done.", ending: .itself, now: minutes(minute + 1))
            board.review(item.id, Review(verdict: .changesRequested, notes: "Add tests.", by: reviewer,
                                         date: minutes(minute + 2)), now: minutes(minute + 2))
        }
        // Sent back up to the limit, it is started again by itself.
        for (round, minute) in [0.0, 3.0].enumerated() {
            sentBack(at: minute)
            XCTAssertEqual(board.sentBackInARow(of: board.item(item.id)!), round + 1)
            XCTAssertTrue(board.autopilotMayStart(board.item(item.id)!))
            XCTAssertEqual(spot(board).place, .running)
        }
        // Once more, and it waits for the person, as a redo.
        sentBack(at: 6)
        let held = board.item(item.id)!
        XCTAssertEqual(board.sentBackInARow(of: held), BoardRules.redoLimit + 1)
        XCTAssertFalse(board.autopilotMayStart(held))
        XCTAssertFalse(board.movesOnByItself(held))
        XCTAssertEqual(spot(board), ChatShelf.Spot(place: .needsYou, task: item.id, need: .redo))
        // A person's own request for changes is theirs: the count starts again.
        sentBack(at: 9, by: Review.person)
        XCTAssertEqual(board.sentBackInARow(of: board.item(item.id)!), 0)
        XCTAssertTrue(board.autopilotMayStart(board.item(item.id)!))
    }

    func testABlankNewTaskIsNotStartedUntilItIsWritten() {
        var board = Board(project: project, now: t0)
        board.settings.autopilot = true
        let item = board.add(title: BoardRules.newTaskTitle, status: .todo, by: .person, now: t0)
        XCTAssertTrue(BoardRules.isBlank(board.item(item.id)!))
        XCTAssertFalse(board.autopilotMayStart(board.item(item.id)!))
        XCTAssertFalse(board.movesOnByItself(board.item(item.id)!))
        // An empty title is no better.
        let untitled = board.add(title: "  ", status: .todo, by: .person, now: t0)
        XCTAssertTrue(BoardRules.isBlank(board.item(untitled.id)!))
        // Named, or given details or what done means, it is work.
        var named = board.item(item.id)!
        named.title = "Fix the login timeout"
        XCTAssertFalse(BoardRules.isBlank(named))
        var detailed = board.item(item.id)!
        detailed.details = "The session expires after a minute; it should last a day."
        XCTAssertFalse(BoardRules.isBlank(detailed))
        var accepted = board.item(item.id)!
        accepted.acceptance = ["Sign-in lasts a day"]
        XCTAssertFalse(BoardRules.isBlank(accepted))
    }

    func testOneRunsUseIsWhatItsChatUsedWhileItRan() {
        let shared = UUID()
        func use(_ tokens: Int, at minute: Double) -> UsageEntry {
            UsageEntry(date: minutes(minute), conversation: shared, engine: "anthropic", model: "m", purpose: "Agent",
                       input: tokens, output: 0)
        }
        let ledger = Ledger([use(100, at: 1), use(200, at: 4), use(400, at: 11), use(800, at: 30)])
        let first = WorkRun(conversation: shared, model: model, modelLabel: "M", startedAt: t0, endedAt: minutes(5))
        let second = WorkRun(conversation: shared, model: model, modelLabel: "M", startedAt: minutes(10))
        XCTAssertEqual(ledger.total(of: first, now: minutes(40)).tokens, 300)
        XCTAssertEqual(ledger.total(of: second, now: minutes(20)).tokens, 400)
    }
}
