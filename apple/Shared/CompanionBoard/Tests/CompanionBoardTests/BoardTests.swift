import XCTest
@testable import CompanionBoard

private let project = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func minutes(_ count: Double) -> Date { t0.addingTimeInterval(count * 60) }

private func choice(_ model: String) -> ModelChoice { ModelChoice(engine: "anthropic", model: model) }

/// A list of two models, by the names a supervisor would use.
private func models(_ name: String) -> (choice: ModelChoice, label: String)? {
    switch name {
    case "m1": return (ModelChoice(engine: "ollama", model: "qwen3-coder:30b"), "Ollama · qwen3-coder:30b")
    case "m2": return (choice("claude-sonnet-5-5"), "Claude · Sonnet 5.5")
    default: return nil
    }
}

final class BoardTests: XCTestCase {
    func testTasksAreNumberedAndNeverReuseANumber() {
        var board = Board(project: project, now: t0)
        let first = board.add(title: "One", by: .person, now: t0)
        let second = board.add(title: "Two", by: .person, now: t0)
        XCTAssertEqual([first.key, second.key], ["T-1", "T-2"])
        board.remove(second.id, by: .person, now: t0)
        XCTAssertEqual(board.add(title: "Three", by: .person, now: t0).key, "T-3")
    }

    func testATitleIsOneLineAndNeverEmpty() {
        var board = Board(project: project, now: t0)
        XCTAssertEqual(board.add(title: "  First line\nsecond line ", by: .person, now: t0).title, "First line")
        XCTAssertEqual(board.add(title: "   ", by: .person, now: t0).title, "Untitled task")
    }

    func testACardWithAnEmptyOrBlankTitleIsFlaggedUnnamed() {
        let empty = WorkItem(number: 1, title: "", createdAt: t0)
        XCTAssertTrue(BoardRules.isUnnamed(empty))
        let blank = WorkItem(number: 2, title: "   \n ", createdAt: t0)
        XCTAssertTrue(BoardRules.isUnnamed(blank))
        let named = WorkItem(number: 3, title: "Fix the bug", createdAt: t0)
        XCTAssertFalse(BoardRules.isUnnamed(named))
    }

    func testWhyBlockedNamesNoTitleThenNoDetails() {
        var board = Board(project: project, now: t0)
        let blank = board.add(title: "   ", by: .person, now: t0)
        XCTAssertEqual(BoardRules.whyBlocked(blank), "\(blank.key) has no title yet. Give it one, then it can run.")

        let named = board.add(title: "Fix the thing", by: .person, now: t0)
        XCTAssertEqual(BoardRules.whyBlocked(named),
                       "\(named.key) has no details yet. Say what the agent should do, then it can run.")

        board.update(named.id, now: t0) { $0.details = "Write the fix." }
        XCTAssertNil(BoardRules.whyBlocked(board.item(named.id)!))
    }

    func testAutopilotWillNotStartANamedTaskThatHasNoDetails() {
        var board = Board(project: project, now: t0)
        board.settings.autopilot = true
        let item = board.add(title: "Fix the thing", by: .person, now: t0)
        XCTAssertFalse(board.autopilotMayStart(board.item(item.id)!))
        XCTAssertFalse(board.movesOnByItself(board.item(item.id)!))

        board.update(item.id, now: t0) { $0.details = "Write the fix." }
        XCTAssertTrue(board.autopilotMayStart(board.item(item.id)!))
    }

    func testMovingKeepsWhenWorkStartedAndFinished() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        board.move(item.id, to: .inProgress, by: .person, now: minutes(1))
        board.move(item.id, to: .done, by: .person, now: minutes(5))
        XCTAssertEqual(board.item(item.id)?.startedAt, minutes(1))
        XCTAssertEqual(board.item(item.id)?.finishedAt, minutes(5))
        // Reopened: it is no longer finished, and it started when it first did.
        board.move(item.id, to: .todo, by: .person, now: minutes(6))
        XCTAssertNil(board.item(item.id)?.finishedAt)
        XCTAssertEqual(board.item(item.id)?.startedAt, minutes(1))
    }

    func testDroppingATaskAboveAnotherPutsItThere() {
        var board = Board(project: project, now: t0)
        let a = board.add(title: "A", by: .person, now: t0)
        let b = board.add(title: "B", by: .person, now: t0)
        let c = board.add(title: "C", by: .person, now: t0)
        board.move(c.id, to: .todo, above: a.id, by: .person, now: t0)
        XCTAssertEqual(board.items(in: .todo).map(\.title), ["C", "A", "B"])
        board.move(a.id, to: .todo, above: nil, by: .person, now: t0)
        XCTAssertEqual(board.items(in: .todo).map(\.title), ["C", "B", "A"])
        _ = b
    }

    func testOnlyTasksWithNothingToWaitOnAreReadyMostPressingFirst() {
        var board = Board(project: project, now: t0)
        let base = board.add(title: "Base", by: .person, now: t0)
        let next = board.add(title: "Next", priority: .urgent, dependsOn: [base.number], by: .person, now: t0)
        let side = board.add(title: "Side", priority: .high, by: .person, now: t0)
        _ = board.add(title: "Later", status: .backlog, by: .person, now: t0)
        XCTAssertEqual(board.ready.map(\.title), ["Side", "Base"])
        board.move(base.id, to: .done, by: .person, now: t0)
        XCTAssertEqual(board.ready.map(\.title), ["Next", "Side"])
        XCTAssertTrue(board.blockers(of: board.item(next.id)!).isEmpty)
        _ = side
    }

    func testWaitsThatWouldMakeACircleAreRefused() {
        var board = Board(project: project, now: t0)
        let a = board.add(title: "A", by: .person, now: t0)
        let b = board.add(title: "B", dependsOn: [a.number], by: .person, now: t0)
        let c = board.add(title: "C", dependsOn: [b.number], by: .person, now: t0)
        // A waiting on C would be A -> C -> B -> A.
        XCTAssertEqual(board.setDependencies(a.id, to: [c.number, a.number, 99], now: t0), [c.number, a.number, 99])
        XCTAssertEqual(board.item(a.id)?.dependsOn, [])
        XCTAssertEqual(board.setDependencies(c.id, to: [a.number, b.number], now: t0), [])
        XCTAssertEqual(board.item(c.id)?.dependsOn, [a.number, b.number])
    }

    func testRemovingATaskFreesWhatWaitedOnIt() {
        var board = Board(project: project, now: t0)
        let a = board.add(title: "A", by: .person, now: t0)
        let b = board.add(title: "B", dependsOn: [a.number], by: .person, now: t0)
        board.remove(a.id, by: .person, now: t0)
        XCTAssertEqual(board.item(b.id)?.dependsOn, [])
    }

    func testARunMovesItsTaskAsItGoes() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        let chat = UUID()
        board.beginRun(item.id, WorkRun(conversation: chat, model: choice("m"), modelLabel: "M", startedAt: minutes(1)),
                       by: .person, now: minutes(1))
        XCTAssertEqual(board.item(item.id)?.status, .inProgress)
        XCTAssertEqual(board.running.map(\.id), [item.id])
        XCTAssertTrue(board.ready.isEmpty)

        let ended = board.endRun(in: chat, outcome: .succeeded, report: "Done.", now: minutes(9))
        XCTAssertEqual(ended?.run.outcome, .succeeded)
        XCTAssertEqual(ended?.run.endedAt, minutes(9))
        XCTAssertEqual(board.item(item.id)?.status, .review)
        XCTAssertNil(board.item(item.id)?.activeRun)
        // The same chat ending again changes nothing.
        XCTAssertNil(board.endRun(in: chat, outcome: .failed, report: nil, now: minutes(10)))
    }

    func testAFailedOrStoppedRunSendsTheTaskBackToToDo() {
        for outcome in [WorkRun.Outcome.failed, .stopped] {
            var board = Board(project: project, now: t0)
            let item = board.add(title: "Work", by: .person, now: t0)
            let chat = UUID()
            board.beginRun(item.id, WorkRun(conversation: chat, model: choice("m"), modelLabel: "M", startedAt: t0),
                           by: .person, now: t0)
            board.endRun(in: chat, outcome: outcome, report: nil, now: minutes(2))
            XCTAssertEqual(board.item(item.id)?.status, .todo)
        }
    }

    func testATaskMovedByHandWhileItRanStaysWhereItWasPut() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        let chat = UUID()
        board.beginRun(item.id, WorkRun(conversation: chat, model: choice("m"), modelLabel: "M", startedAt: t0),
                       by: .person, now: t0)
        board.move(item.id, to: .backlog, by: .person, now: minutes(1))
        board.endRun(in: chat, outcome: .succeeded, report: nil, now: minutes(2))
        XCTAssertEqual(board.item(item.id)?.status, .backlog)
    }

    func testAReviewClosesTheTaskOrSendsItBackWithNotes() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", status: .review, by: .person, now: t0)
        board.review(item.id, Review(verdict: .changesRequested, notes: "Tests are missing.", by: "Supervisor",
                                     date: minutes(1)), now: minutes(1))
        XCTAssertEqual(board.item(item.id)?.status, .todo)
        XCTAssertEqual(board.item(item.id)?.notes.last?.text, "Review: Tests are missing.")
        board.review(item.id, Review(verdict: .approved, notes: "", by: "You", date: minutes(2)), now: minutes(2))
        XCTAssertEqual(board.item(item.id)?.status, .done)
    }

    func testARecommendedReviewMovesNothing() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        let chat = UUID()
        board.beginRun(item.id, WorkRun(conversation: chat, model: choice("m"), modelLabel: "M", startedAt: t0),
                       by: .person, now: t0)
        board.endRun(in: chat, outcome: .succeeded, report: "Done.", now: minutes(5))
        XCTAssertTrue(board.recommend(item.id, Review(verdict: .changesRequested, notes: "A test fails.",
                                                      by: "Supervisor", date: minutes(6)), now: minutes(6)))
        XCTAssertEqual(board.item(item.id)?.status, .review)
        XCTAssertEqual(board.item(item.id)?.runs.last?.advice?.verdict, .changesRequested)
        XCTAssertNil(board.item(item.id)?.runs.last?.review)
    }

    func testWhatTheSupervisorPickedStaysWhenAPersonChoosesAnother() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        board.apply([.assign(ref: "T-1", model: "m1", reason: "Small.")], model: models, now: t0)
        board.assign(item.id, Assignment(model: choice("claude-opus-5-5"), label: "Claude · Opus 5.5", reason: "",
                                         source: .person, accepted: true, date: t0), by: .person, now: t0)
        XCTAssertEqual(board.item(item.id)?.assignment?.label, "Claude · Opus 5.5")
        XCTAssertEqual(board.item(item.id)?.suggestion?.label, "Ollama · qwen3-coder:30b")
    }

    func testOnlyARunThatStoppedByItselfIsCarriedOnWithoutThePerson() {
        var board = Board(project: project, now: t0)
        let chat = UUID()
        func attempt(carriesOn: Bool? = nil) -> WorkRun {
            WorkRun(conversation: chat, model: choice("m"), modelLabel: "M", startedAt: t0, carriesOn: carriesOn)
        }
        // It failed by itself: the supervisor may say "continue".
        let failed = board.add(title: "Failed", by: .person, now: t0)
        board.beginRun(failed.id, attempt(), by: .person, now: t0)
        board.endRun(in: chat, outcome: .failed, report: "The model timed out.", ending: .itself, now: minutes(1))
        XCTAssertTrue(board.mayCarryOn(board.item(failed.id)!))
        // Carried on twice in a row and failed again: now it waits for a person.
        for minute in [2.0, 4.0] {
            board.beginRun(failed.id, attempt(carriesOn: true), by: .supervisor, now: minutes(minute))
            board.endRun(in: chat, outcome: .failed, report: "", ending: .itself, now: minutes(minute + 1))
        }
        XCTAssertEqual(board.carryOns(of: board.item(failed.id)!), BoardRules.carryOnLimit)
        XCTAssertFalse(board.mayCarryOn(board.item(failed.id)!))
        // Started by a person again, the count starts again.
        board.beginRun(failed.id, attempt(), by: .person, now: minutes(6))
        board.endRun(in: chat, outcome: .failed, report: "", ending: .itself, now: minutes(7))
        XCTAssertTrue(board.mayCarryOn(board.item(failed.id)!))

        // What a person stopped, or was refused, is theirs to take up again.
        for ending in [WorkRun.Ending.person, .supervisor] {
            let other = UUID()
            let item = board.add(title: "Halted", by: .person, now: t0)
            board.beginRun(item.id, WorkRun(conversation: other, model: choice("m"), modelLabel: "M", startedAt: t0),
                           by: .person, now: t0)
            board.endRun(in: other, outcome: ending == .person ? .stopped : .failed, report: "", ending: ending,
                         now: minutes(1))
            XCTAssertEqual(board.item(item.id)?.runs.last?.ending, ending)
            XCTAssertFalse(board.mayCarryOn(board.item(item.id)!))
        }

        // A task moved since the run left it is where the person wants it.
        board.move(failed.id, to: .backlog, by: .person, now: minutes(8))
        XCTAssertFalse(board.mayCarryOn(board.item(failed.id)!))
        XCTAssertEqual(board.stoppedHalfway.map(\.title), [])
    }

    func testARunTheAppQuitUnderIsCarriedOnHoweverOftenThatHappens() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Long work", by: .person, now: t0)
        let chat = UUID()
        for round in 0..<4 {
            board.beginRun(item.id, WorkRun(conversation: chat, model: choice("m"), modelLabel: "M",
                                            startedAt: minutes(Double(round)), carriesOn: round > 0),
                           by: round == 0 ? .person : .supervisor, now: minutes(Double(round)))
            // The app starts again with nothing running.
            XCTAssertEqual(board.closeLostRuns(except: [], now: minutes(Double(round) + 0.5)), 1)
            XCTAssertEqual(board.item(item.id)?.runs.last?.ending, .quit)
            XCTAssertTrue(board.mayCarryOn(board.item(item.id)!))
        }
        XCTAssertEqual(board.stoppedHalfway.map(\.title), ["Long work"])
    }

    func testARunSavedBeforeItWasKeptWhatCutItShortIsToldApartByItsReport() throws {
        // Found cut off when the app next started: nothing was ever reported.
        let lost = """
        {"id":"00000000-0000-0000-0000-000000000009","conversation":"00000000-0000-0000-0000-00000000000A",
         "model":{"engine":"anthropic","model":"m"},"modelLabel":"M","startedAt":"2027-01-15T08:00:00Z",
         "outcome":"stopped"}
        """
        // Stopped by a person while the app ran: it has a report, if only an empty one.
        let stopped = """
        {"id":"00000000-0000-0000-0000-00000000000B","conversation":"00000000-0000-0000-0000-00000000000C",
         "model":{"engine":"anthropic","model":"m"},"modelLabel":"M","startedAt":"2027-01-15T08:00:00Z",
         "outcome":"stopped","report":""}
        """
        // Failed: nobody can tell whether a step was refused.
        let failed = """
        {"id":"00000000-0000-0000-0000-00000000000D","conversation":"00000000-0000-0000-0000-00000000000E",
         "model":{"engine":"anthropic","model":"m"},"modelLabel":"M","startedAt":"2027-01-15T08:00:00Z",
         "outcome":"failed","report":"Not run, as you declined: Run: git push."}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var board = Board(project: project, now: t0)
        var answers: [Bool] = []
        for json in [lost, stopped, failed] {
            let run = try decoder.decode(WorkRun.self, from: Data(json.utf8))
            XCTAssertNil(run.ending)
            XCTAssertNil(run.carriesOn)
            let item = board.add(title: "Old", by: .person, now: t0)
            board.update(item.id, now: t0) { $0.runs = [run] }
            answers.append(board.mayCarryOn(board.item(item.id)!))
        }
        XCTAssertEqual(answers, [true, false, false])
    }

    func testRunsCutOffByQuittingAreClosedAndTheirTasksGoBack() {
        var board = Board(project: project, now: t0)
        let lost = board.add(title: "Lost", by: .person, now: t0)
        let live = board.add(title: "Live", by: .person, now: t0)
        let lostChat = UUID(), liveChat = UUID()
        board.beginRun(lost.id, WorkRun(conversation: lostChat, model: choice("m"), modelLabel: "M", startedAt: t0),
                       by: .person, now: t0)
        board.beginRun(live.id, WorkRun(conversation: liveChat, model: choice("m"), modelLabel: "M", startedAt: t0),
                       by: .person, now: t0)
        XCTAssertEqual(board.closeLostRuns(except: [liveChat], now: minutes(30)), 1)
        XCTAssertEqual(board.item(lost.id)?.status, .todo)
        XCTAssertEqual(board.item(lost.id)?.runs.last?.outcome, .stopped)
        XCTAssertEqual(board.item(live.id)?.status, .inProgress)
    }

    func testTheHistoryKeepsOnlyItsNewestLines() {
        var board = Board(project: project, now: t0)
        for index in 0..<(Board.activityLimit + 25) {
            board.log("Line \(index)", by: .person, now: t0)
        }
        XCTAssertEqual(board.activity.count, Board.activityLimit)
        XCTAssertEqual(board.activity.last?.text, "Line \(Board.activityLimit + 24)")
    }

    func testABoardSavedWithFewerFieldsStillLoads() throws {
        let json = """
        {"project":"00000000-0000-0000-0000-0000000000AA",
         "items":[{"id":"00000000-0000-0000-0000-000000000001","number":4,"title":"Old task"}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let board = try decoder.decode(Board.self, from: Data(json.utf8))
        XCTAssertEqual(board.items.first?.status, .todo)
        XCTAssertEqual(board.items.first?.priority, .medium)
        // The next number is past every number in use, whatever was saved.
        XCTAssertEqual(board.nextNumber, 5)
        XCTAssertTrue(board.settings.reviewGate)
        XCTAssertFalse(board.settings.autopilot)
        // Nobody answers in the person's place unless they said so.
        XCTAssertFalse(board.settings.followsAdvice)
        XCTAssertFalse(board.settings.supervisorAnswers)
    }

    func testTheSupervisorOnlyAnswersWhereItAlsoRecommends() {
        var settings = BoardSettings()
        XCTAssertFalse(settings.supervisorAnswers)
        settings.followsAdvice = true
        XCTAssertTrue(settings.supervisorAnswers)
        // With no recommendation there is nothing to take.
        settings.advice = false
        XCTAssertFalse(settings.supervisorAnswers)
    }

    func testABoardSurvivesBeingSavedAndLoaded() throws {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", details: "Do it.", acceptance: ["It works"], priority: .high,
                             kind: .bug, milestone: "Phase 1", estimateTokens: 20_000, by: .supervisor, now: t0)
        board.assign(item.id, Assignment(model: choice("claude-sonnet-5-5"), label: "Claude · Sonnet 5.5",
                                         reason: "Everyday work.", source: .supervisor, accepted: false, date: t0),
                     by: .supervisor, now: t0)
        board.budget = Budget(tokens: 1_000_000, dollars: 20)
        board.settings.followsAdvice = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Board.self, from: encoder.encode(board)), board)
    }

    func testStatusesAreReadAsPeopleWriteThem() {
        XCTAssertEqual(WorkStatus(loose: "In Progress"), .inProgress)
        XCTAssertEqual(WorkStatus(loose: "in-progress"), .inProgress)
        XCTAssertEqual(WorkStatus(loose: "to do"), .todo)
        XCTAssertEqual(WorkStatus(loose: "Completed"), .done)
        XCTAssertNil(WorkStatus(loose: "someday maybe"))
        XCTAssertEqual(WorkPriority(loose: "P0"), .urgent)
        XCTAssertEqual(WorkKind(loose: "Bug fix"), .bug)
    }
}

final class OperationTests: XCTestCase {
    func testAPlanIsAddedWithItsWaitsAndModels() {
        var board = Board(project: project, now: t0)
        let summary = board.apply([
            .setGoal("Ship sign-in"),
            .add(label: "a", ItemPatch(title: "Design the form", kind: .design, model: "m2", reason: "Open-ended.")),
            // It waits on a task added later in the same reply.
            .add(label: "b", ItemPatch(title: "Build the form", dependsOn: ["a", "c"], estimateTokens: 40_000, model: "m1")),
            .add(label: "c", ItemPatch(title: "Write the API", status: .backlog)),
        ], model: models, now: t0)
        XCTAssertEqual(summary.added, 3)
        XCTAssertEqual(summary.assigned, 2)
        XCTAssertTrue(summary.goalChanged)
        XCTAssertTrue(summary.problems.isEmpty)
        XCTAssertEqual(board.goal, "Ship sign-in")
        XCTAssertEqual(board.item(number: 2)?.dependsOn, [1, 3])
        XCTAssertEqual(board.item(number: 1)?.assignment?.label, "Claude · Sonnet 5.5")
        XCTAssertEqual(board.item(number: 1)?.assignment?.accepted, false)
        XCTAssertEqual(board.item(number: 3)?.status, .backlog)
        XCTAssertEqual(summary.sentence, "Set the goal, added 3 tasks and suggested a model for 2 tasks.")
    }

    func testWhatCannotBeDoneIsSkippedAndSaid() {
        var board = Board(project: project, now: t0)
        let kept = board.add(title: "Has a run", by: .person, now: t0)
        board.beginRun(kept.id, WorkRun(conversation: UUID(), model: choice("m"), modelLabel: "M", startedAt: t0),
                       by: .person, now: t0)
        let summary = board.apply([
            .move(ref: "T-9", .done),
            .assign(ref: "T-1", model: "m7", reason: ""),
            .remove(ref: "T-1"),
            .move(ref: "T-1", .backlog),
            .add(label: nil, ItemPatch(title: "  ")),
        ], model: models, now: t0)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.problems.count, 5)
        XCTAssertEqual(board.items.count, 1)
        XCTAssertEqual(board.item(kept.id)?.status, .inProgress)
    }

    func testASupervisorCannotAddWorkAsAlreadyDone() {
        var board = Board(project: project, now: t0)
        board.apply([.add(label: nil, ItemPatch(title: "Claimed done", status: .done))], model: models, now: t0)
        XCTAssertEqual(board.items.first?.status, .todo)
    }

    func testAModelAPersonChoseIsNotReplaced() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        board.assign(item.id, Assignment(model: choice("claude-opus-5-5"), label: "Claude · Opus 5.5", reason: "",
                                         source: .person, accepted: true, date: t0), by: .person, now: t0)
        let summary = board.apply([.assign(ref: "1", model: "m1", reason: "Cheaper.")], model: models, now: t0)
        XCTAssertEqual(summary.assigned, 0)
        XCTAssertEqual(board.item(item.id)?.assignment?.label, "Claude · Opus 5.5")
    }

    func testTasksAreFoundByTheNamesASupervisorUses() {
        var board = Board(project: project, now: t0)
        board.add(title: "One", by: .person, now: t0)
        for ref in ["T-1", "t1", "#1", "1", " Task 1 ", "task-1"] {
            XCTAssertEqual(board.item(ref: ref)?.number, 1, ref)
        }
        XCTAssertNil(board.item(ref: "T-2"))
        XCTAssertNil(board.item(ref: "one"))
    }

    func testARunawayReplyCannotFloodTheBoard() {
        var board = Board(project: project, now: t0)
        let many = (0..<(Board.operationLimit + 40)).map { BoardOperation.add(label: nil, ItemPatch(title: "Task \($0)")) }
        let summary = board.apply(many, model: models, now: t0)
        XCTAssertEqual(summary.added, Board.operationLimit)
        XCTAssertEqual(summary.problems.count, 1)
    }

    func testTheSupervisorMayStopAFlaggedRunAndTheTaskWaitsForThePerson() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Looping", by: .person, now: t0)
        let idle = board.add(title: "Idle", by: .person, now: t0)
        // The task has a working copy of its own: stopping must leave
        // the branch and the work on it, so the next run picks it up.
        let copy = WorkingCopy(folder: "/copies/app/t-1", subfolder: "apple",
                               branch: "task/t-1-looping", base: "companion/main",
                               baseCommit: "abc1234", madeAt: t0)
        board.setCopy(item.id, copy, by: .person, now: t0)
        // A run only the board has flagged can be stopped by the
        // supervisor: here, three reads of the same file in a row.
        let flagged = RunSignals(reads: ["src/thing.swift": LoopDetection.repeatedReadsLimit])
        let chat = UUID()
        board.beginRun(item.id, WorkRun(conversation: chat, model: choice("m"), modelLabel: "M", startedAt: t0,
                                        signals: flagged), by: .person, now: t0)
        let summary = board.apply([.stop(ref: "T-1", reason: "It keeps reading the same file."),
                                   .stop(ref: "T-2", reason: "Nothing to stop."), .stop(ref: "T-9", reason: "")],
                                  model: models, now: minutes(1))
        XCTAssertEqual(summary.stopping, [item.id])
        XCTAssertEqual(summary.problems.count, 2)
        XCTAssertEqual(summary.sentence, "Stopped a run.")
        XCTAssertEqual(board.item(item.id)?.notes.last?.text, "Stopped the run: It keeps reading the same file.")
        XCTAssertTrue(board.item(idle.id)?.notes.isEmpty ?? false)
        // The board only notes it: the run goes on until the app ends it.
        XCTAssertNotNil(board.item(item.id)?.activeRun)

        board.endRun(in: chat, outcome: .stopped, report: "", ending: .supervisor, now: minutes(2))
        XCTAssertEqual(board.item(item.id)?.status, .todo)
        XCTAssertEqual(board.item(item.id)?.runs.last?.ending, .supervisor)
        // The task's working copy, and the branch on it, are left alone:
        // the next run picks the branch up and goes on from the work.
        XCTAssertEqual(board.item(item.id)?.workingCopy?.state, .open)
        XCTAssertEqual(board.item(item.id)?.workingCopy?.branch, "task/t-1-looping")
        // Stopped by the supervisor, it is not carried on without the person.
        XCTAssertFalse(board.mayCarryOn(board.item(item.id)!))
    }

    func testTheBoardRefusesToStopARunThatIsNotFlagged() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Healthy", by: .person, now: t0)
        let chat = UUID()
        // A run with nothing on its signals is not looping, so the board
        // refuses to stop it even when the supervisor asks.
        board.beginRun(item.id, WorkRun(conversation: chat, model: choice("m"), modelLabel: "M", startedAt: t0),
                       by: .person, now: t0)
        let summary = board.apply([.stop(ref: "T-1", reason: "A hunch.")], model: models, now: minutes(1))
        XCTAssertTrue(summary.stopping.isEmpty)
        XCTAssertEqual(summary.problems.count, 1)
        XCTAssertTrue(summary.problems[0].contains("not flagged as looping"))
        XCTAssertEqual(board.item(item.id)?.notes.last?.text,
                       "Not stopped: its run is not flagged as looping.")
        XCTAssertNotNil(board.item(item.id)?.activeRun)
    }

    /// A task with one finished run, waiting in Review, whose checks came
    /// to `checks` (nil: none ran).
    private func reviewed(_ title: String, on board: inout Board, checks: [CheckResult]?) -> WorkItem {
        let item = board.add(title: title, by: .person, now: t0)
        let chat = UUID()
        board.beginRun(item.id, WorkRun(conversation: chat, model: choice("m"), modelLabel: "M", startedAt: t0),
                       by: .person, now: t0)
        board.endRun(in: chat, outcome: .succeeded, report: "Did \(title).", ending: .itself, now: minutes(1))
        if let checks, let run = board.item(item.id)?.runs.last {
            board.recordChecks(item.id, run: run.id, checks, now: minutes(1))
        }
        return board.item(item.id)!
    }

    private func check(_ outcome: CheckResult.Outcome) -> CheckResult {
        CheckResult(name: "Build", command: "bash build.sh check", outcome: outcome,
                    exitCode: outcome == .failed ? 1 : 0, seconds: 40)
    }

    func testTheSupervisorApprovesOnlyReviewTasksWhoseChecksPassed() {
        var board = Board(project: project, now: t0)
        let passed = reviewed("Passed", on: &board, checks: [check(.passed)])
        let failed = reviewed("Failed", on: &board, checks: [check(.passed), check(.failed)])
        let unchecked = reviewed("Unchecked", on: &board, checks: nil)
        let waiting = board.add(title: "Not started", by: .person, now: t0)
        XCTAssertEqual(passed.status, .review)

        let summary = board.apply([.approve(ref: "T-1"), .approve(ref: "T-1"), .approve(ref: "T-2"),
                                   .approve(ref: "T-3"), .approve(ref: "T-4"), .approve(ref: "T-9")],
                                  model: models, now: minutes(2))
        XCTAssertEqual(summary.approving, [passed.id])
        XCTAssertEqual(summary.problems.count, 4)
        XCTAssertEqual(summary.sentence, "Asked to approve 1 task.")
        // The board only records it: the approval itself is the app's,
        // through the card's Approve, once the merge is known not to conflict.
        XCTAssertEqual(board.item(passed.id)?.status, .review)
        // Refused, the reason is on the task and it stays in Review.
        for refused in [failed, unchecked] {
            XCTAssertEqual(board.item(refused.id)?.status, .review)
            XCTAssertTrue(board.item(refused.id)?.notes.last?.text.hasPrefix("Not approved: ") ?? false)
        }
        XCTAssertTrue(board.item(failed.id)?.notes.last?.text.contains("Build failed (exit 1)") ?? false)
        XCTAssertEqual(board.item(waiting.id)?.status, .todo)

        // The card's Approve, which the app calls for it, closes it.
        board.review(passed.id, Review(verdict: .approved, notes: "", by: "Supervisor", date: minutes(3)), now: minutes(3))
        XCTAssertEqual(board.item(passed.id)?.status, .done)
    }

    func testTheSupervisorDeletesJunkButNeverUnmergedWorkTheOwnerDidNotName() {
        var board = Board(project: project, now: t0)
        let idle = board.add(title: "Idle", by: .person, now: t0)
        let junk = reviewed("Junk", on: &board, checks: [check(.failed)])
        let kept = reviewed("Kept", on: &board, checks: [check(.passed)])
        for item in [junk, kept] {
            board.setCopy(item.id, WorkingCopy(folder: "/copies/\(item.key.lowercased())",
                                               branch: "task/\(item.key.lowercased())", base: "companion/main",
                                               baseCommit: "abc", madeAt: t0), by: .run, now: t0)
        }
        let running = board.add(title: "Running", by: .person, now: t0)
        board.beginRun(running.id, WorkRun(conversation: UUID(), model: choice("m"), modelLabel: "M", startedAt: t0),
                       by: .person, now: t0)

        let named = Board.named(in: "T-2 is junk, throw it away.")
        XCTAssertEqual(named, [2])
        let summary = board.apply([.delete(ref: "T-1", reason: "Not needed."), .delete(ref: "T-2", reason: "Junk."),
                                   .delete(ref: "T-3", reason: ""), .delete(ref: "T-4", reason: "")],
                                  named: named, model: models, now: minutes(2))
        // Nothing unmerged on T-1, and the owner named T-2; T-3's branch and
        // T-4's run are not merged, and nobody named them.
        XCTAssertEqual(summary.deleting, [idle.id, junk.id])
        XCTAssertEqual(summary.problems.count, 2)
        XCTAssertTrue(board.item(kept.id)?.notes.last?.text.hasPrefix("Not deleted: its work on task/t-3") ?? false)
        XCTAssertTrue(board.item(running.id)?.notes.last?.text.hasPrefix("Not deleted: a run is going on") ?? false)

        // The app takes it off; what its run did stays in the history.
        board.remove(junk.id, by: .supervisor, now: minutes(3))
        XCTAssertNil(board.item(junk.id))
        let history = board.activity.map(\.text)
        XCTAssertTrue(history.contains("T-2's run 1 of 1, with M: finished. Did Junk."), "\(history)")
        XCTAssertTrue(history.contains("Asked to delete T-2: Junk."))
        XCTAssertTrue(history.contains { $0.hasPrefix("Removed T-2: Junk. Its work is kept on branch task/t-2") })
    }

    func testTheTasksAPersonNamesAreReadFromTheirWords() {
        XCTAssertEqual(Board.named(in: "Delete T-3, t4, #5 and task 6 as junk; keep the 2 others at T-12."),
                       [3, 4, 5, 6, 12])
        XCTAssertEqual(Board.named(in: "Throw the last one away, it costs 30 dollars."), [])
    }
}
