import XCTest
@testable import CompanionBoard

private let project = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func hours(_ count: Double) -> Date { t0.addingTimeInterval(count * 3_600) }

private func aRun(in chat: UUID, from start: Date) -> WorkRun {
    WorkRun(conversation: chat, model: ModelChoice(engine: "anthropic", model: "m"), modelLabel: "M", startedAt: start)
}

final class GoalTests: XCTestCase {
    func testANewBoardHasOneGoalThatSaysNothingYet() {
        let board = Board(project: project, now: t0)
        XCTAssertEqual(board.goals.count, 1)
        XCTAssertEqual(board.goal, "")
        XCTAssertEqual(board.current.key, "G-1")
        XCTAssertTrue(board.current.isActive)
        XCTAssertTrue(board.earlierGoals.isEmpty)
        XCTAssertFalse(board.goalReached)
    }

    func testTheFirstGoalIsSaidNotStarted() {
        var board = Board(project: project, now: t0)
        // Nothing was said or planned yet, so there is nothing to keep.
        XCTAssertEqual(board.startGoal("  Ship sign-in ", by: .person, now: hours(1))?.key, "G-1")
        XCTAssertEqual(board.goals.count, 1)
        XCTAssertEqual(board.goal, "Ship sign-in")
        XCTAssertNil(board.startGoal("   ", by: .person, now: hours(2)))
        // Other words for the same goal do not make a second one.
        XCTAssertTrue(board.setGoal("Ship sign-in this month", by: .person, now: hours(3)))
        XCTAssertFalse(board.setGoal("Ship sign-in this month", by: .person, now: hours(3)))
        XCTAssertEqual(board.goals.count, 1)
    }

    func testANewGoalKeepsTheOneBeforeWithItsTasks() {
        var board = Board(project: project, now: t0)
        board.setGoal("Ship sign-in", by: .person, now: t0)
        let built = board.add(title: "Build it", by: .person, now: t0)
        board.move(built.id, to: .done, by: .person, now: hours(1))
        XCTAssertTrue(board.goalReached)

        XCTAssertEqual(board.startGoal("Add billing", by: .person, now: hours(2))?.key, "G-2")
        XCTAssertEqual(board.goal, "Add billing")
        XCTAssertTrue(board.items.isEmpty)
        XCTAssertFalse(board.goalReached)
        XCTAssertEqual(board.earlierGoals.map(\.key), ["G-1"])
        XCTAssertEqual(board.earlierGoals.first?.status, .reached)
        XCTAssertEqual(board.earlierGoals.first?.closedAt, hours(2))
        XCTAssertEqual(board.items(of: board.earlierGoals[0].id).map(\.title), ["Build it"])
        XCTAssertEqual(board.progress(of: board.earlierGoals[0].id).done, 1)
        // Numbers go on across goals: a task's key names it for good.
        XCTAssertEqual(board.add(title: "Price page", by: .person, now: hours(3)).key, "T-2")
        XCTAssertEqual(board.items.map(\.title), ["Price page"])
    }

    func testAGoalLeftWithOpenWorkIsSetAsideAndItsOpenTasksCanComeAlong() {
        var board = Board(project: project, now: t0)
        board.setGoal("Ship sign-in", by: .person, now: t0)
        let done = board.add(title: "Done", by: .person, now: t0)
        board.move(done.id, to: .done, by: .person, now: t0)
        let open = board.add(title: "Open", by: .person, now: t0)
        let waiting = board.add(title: "Waiting", status: .backlog, dependsOn: [open.number, done.number],
                                by: .person, now: t0)
        board.startGoal("Add billing", bringUnfinished: true, by: .person, now: hours(1))
        XCTAssertEqual(board.earlierGoals.first?.status, .setAside)
        XCTAssertEqual(Set(board.items.map(\.title)), ["Open", "Waiting"])
        XCTAssertEqual(board.items(of: board.earlierGoals[0].id).map(\.title), ["Done"])
        // It still waits on the open task that came with it, and not on
        // the finished one that stayed behind.
        XCTAssertEqual(board.blockers(of: board.item(waiting.id)!).map(\.title), ["Open"])
    }

    func testGoingBackToAnEarlierGoalBringsItsTasksBack() {
        var board = Board(project: project, now: t0)
        board.setGoal("First", by: .person, now: t0)
        let task = board.add(title: "Of the first", by: .person, now: t0)
        let second = board.startGoal("Second", by: .person, now: hours(1))
        board.add(title: "Of the second", by: .person, now: hours(1))
        let first = board.earlierGoals[0]

        XCTAssertTrue(board.resumeGoal(first.id, by: .person, now: hours(2)))
        XCTAssertEqual(board.goal, "First")
        XCTAssertEqual(board.items.map(\.id), [task.id])
        XCTAssertEqual(board.current.spans.count, 2)
        XCTAssertNil(board.current.closedAt)
        XCTAssertEqual(board.earlierGoals.count, 1)
        XCTAssertEqual(board.earlierGoals.first?.id, second?.id)
        XCTAssertEqual(board.earlierGoals.first?.status, .setAside)
        // Going back to the goal already worked toward, or to none, does nothing.
        XCTAssertFalse(board.resumeGoal(first.id, by: .person, now: hours(3)))
        XCTAssertFalse(board.resumeGoal(UUID(), by: .person, now: hours(3)))
    }

    func testOnlyAGoalWithNoTasksCanBeRemoved() {
        var board = Board(project: project, now: t0)
        board.setGoal("First", by: .person, now: t0)
        board.add(title: "Work", by: .person, now: t0)
        board.startGoal("Second", by: .person, now: hours(1))
        board.startGoal("Third", by: .person, now: hours(2))
        let first = board.goals[0]
        let second = board.goals[1]
        XCTAssertFalse(board.removeGoal(first.id, by: .person, now: hours(3)))
        XCTAssertFalse(board.removeGoal(board.currentGoal, by: .person, now: hours(3)))
        XCTAssertTrue(board.removeGoal(second.id, by: .person, now: hours(3)))
        XCTAssertEqual(board.goals.map(\.key), ["G-1", "G-3"])
    }

    func testARunGoesOnWhenTheBoardTurnsToANewGoal() {
        var board = Board(project: project, now: t0)
        board.setGoal("First", by: .person, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        let chat = UUID()
        board.beginRun(item.id, aRun(in: chat, from: t0), by: .person, now: t0)
        board.startGoal("Second", by: .person, now: hours(1))
        XCTAssertTrue(board.items.isEmpty)
        XCTAssertEqual(board.running.map(\.id), [item.id])
        XCTAssertEqual(board.item(runIn: chat)?.id, item.id)
        XCTAssertEqual(board.endRun(in: chat, outcome: .succeeded, report: "Done.", now: hours(2))?.item.status, .review)
    }

    func testASupervisorStartsAGoalAndPlansItInOneReply() {
        var board = Board(project: project, now: t0)
        board.setGoal("First", by: .person, now: t0)
        let old = board.add(title: "Old work", by: .person, now: t0)
        let summary = board.apply([
            // Written after its first task: the goal is still turned to first.
            .add(label: "a", ItemPatch(title: "New work")),
            .newGoal("Second", bringUnfinished: false),
            .move(ref: old.key, .backlog),
            .newGoal("Third", bringUnfinished: false),
        ], model: { _ in nil }, now: hours(1))
        XCTAssertTrue(summary.goalStarted)
        XCTAssertFalse(summary.goalChanged)
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(board.goal, "Second")
        XCTAssertEqual(board.items.map(\.title), ["New work"])
        // A task of the goal before is not the supervisor's to move, and
        // one goal is started at a time.
        XCTAssertEqual(board.item(old.id)?.status, .todo)
        XCTAssertEqual(summary.problems.count, 2)
        XCTAssertEqual(summary.sentence, "Started a new goal and added 1 task.")
    }

    func testABoardOfTheFirstShapeBecomesOneGoalWithItsTasks() throws {
        let json = """
        {"project":"00000000-0000-0000-0000-0000000000BB","goal":"Ship sign-in","createdAt":"2027-01-10T08:00:00Z",
         "items":[{"id":"00000000-0000-0000-0000-000000000001","number":1,"title":"Old task"}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var board = try decoder.decode(Board.self, from: Data(json.utf8))
        XCTAssertEqual(board.version, Board.currentVersion)
        XCTAssertEqual(board.goal, "Ship sign-in")
        XCTAssertEqual(board.goals.count, 1)
        XCTAssertEqual(board.items.map(\.title), ["Old task"])
        XCTAssertEqual(board.items.first?.goal, board.currentGoal)

        // From there on it is a board like any other, and is saved as one.
        board.startGoal("Next", bringUnfinished: true, by: .person, now: t0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let again = try decoder.decode(Board.self, from: encoder.encode(board))
        XCTAssertEqual(again, board)
        XCTAssertEqual(again.goals.map(\.status), [.setAside, .active])
        XCTAssertEqual(again.items.map(\.title), ["Old task"])
    }

    func testABoardGivenToAnotherProjectIsStillItself() throws {
        var board = Board(project: project, now: t0)
        XCTAssertTrue(board.isBlank)
        board.setGoal("First", by: .person, now: t0)
        // Words alone are not a plan: such a board still makes way.
        XCTAssertFalse(board.isBlank)
        XCTAssertTrue(board.isUnplanned)
        board.add(title: "Work", by: .person, now: t0)
        XCTAssertFalse(board.isUnplanned)

        let other = UUID()
        board.rehome(to: other, now: hours(1))
        XCTAssertEqual(board.project, other)
        XCTAssertEqual(board.earlierProjects, [project])
        XCTAssertEqual(board.goal, "First")
        XCTAssertEqual(board.items.map(\.title), ["Work"])
        // Given back, it does not list its own project as an earlier one.
        board.rehome(to: project, now: hours(2))
        XCTAssertEqual(board.earlierProjects, [other])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Board.self, from: encoder.encode(board)), board)
    }

    func testEveryRequestCountsTowardOneGoal() {
        var board = Board(project: project, now: t0)
        board.setGoal("First", by: .person, now: t0)
        let a = board.add(title: "A", by: .person, now: t0)
        let chatA = UUID()
        let talk = UUID()
        board.beginRun(a.id, aRun(in: chatA, from: t0), by: .person, now: t0)
        board.endRun(in: chatA, outcome: .succeeded, report: nil, now: hours(1))
        let first = board.currentGoal
        board.startGoal("Second", by: .person, now: hours(10))
        let second = board.currentGoal
        let b = board.add(title: "B", by: .person, now: hours(10))

        func used(_ tokens: Int, at hour: Double, chat: UUID? = nil, item: UUID? = nil,
                  purpose: String = "Agent") -> UsageEntry {
            UsageEntry(date: hours(hour), conversation: chat, workItem: item, engine: "anthropic", model: "sonnet",
                       purpose: purpose, input: tokens, output: 0)
        }
        let ledger = Ledger([
            used(1_000, at: 1, chat: chatA, item: a.id),
            used(500, at: 2, chat: talk, purpose: "Supervisor"),
            // In the run's chat after the board had turned: still the first goal's.
            used(300, at: 11, chat: chatA),
            used(2_000, at: 12, item: b.id),
            used(700, at: 13, chat: talk, purpose: "Supervisor"),
            // Before any goal was worked toward: the first's.
            used(50, at: -1, chat: talk),
        ])
        let byGoal = board.usageByGoal(ledger)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(byGoal[first]?.tokens, 1_850)
        XCTAssertEqual(byGoal[second]?.tokens, 2_700)
        XCTAssertEqual(byGoal.values.reduce(0) { $0 + $1.tokens }, ledger.total.tokens)
    }
}
