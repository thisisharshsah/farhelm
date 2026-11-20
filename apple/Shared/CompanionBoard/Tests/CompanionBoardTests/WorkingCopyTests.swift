import XCTest
@testable import CompanionBoard

private let project = UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let model = ModelChoice(engine: "anthropic", model: "m")

private func minutes(_ count: Double) -> Date { t0.addingTimeInterval(count * 60) }

private func attempt(in chat: UUID, at minute: Double = 0) -> WorkRun {
    WorkRun(conversation: chat, model: model, modelLabel: "M", startedAt: minutes(minute))
}

/// Not `copy`: inside a test case that name is NSObject's own method.
private func workingCopy(for item: WorkItem, at minute: Double = 0) -> WorkingCopy {
    WorkingCopy(folder: "/copies/app/\(item.key.lowercased())", subfolder: "apple",
                branch: WorkingCopy.branch(for: item, taken: []), base: "main", baseCommit: "abc1234",
                madeAt: minutes(minute))
}

final class WorkingCopyTests: XCTestCase {
    // MARK: Names

    func testATitleBecomesWordsABranchCanCarry() {
        XCTAssertEqual(WorkingCopy.slug("Add the login form"), "add-the-login-form")
        XCTAssertEqual(WorkingCopy.slug("Fix: crash when É is typed!"), "fix-crash-when-e-is-typed")
        XCTAssertEqual(WorkingCopy.slug("  --Café__au   lait--  "), "cafe-au-lait")
        XCTAssertEqual(WorkingCopy.slug("v2.0 of the API"), "v2-0-of-the-api")
        XCTAssertNil(WorkingCopy.slug("日本語のタスク"))
        XCTAssertNil(WorkingCopy.slug("   "))
    }

    func testALongTitleIsCutAfterAWholeWord() {
        let slug = WorkingCopy.slug("Move every setting of the app into one window with tabs and search")
        XCTAssertEqual(slug, "move-every-setting-of-the-app-into-one")
        XCTAssertLessThanOrEqual(slug?.count ?? 0, WorkingCopy.slugLimit)
        // One word longer than the limit is cut to it.
        let word = String(repeating: "a", count: 60)
        XCTAssertEqual(WorkingCopy.slug(word), String(repeating: "a", count: WorkingCopy.slugLimit))
    }

    func testABranchIsNamedAfterItsTaskAndNeverTakesOneInUse() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Add the login form", by: .person, now: t0)
        XCTAssertEqual(WorkingCopy.branch(for: item, taken: []), "task/t-1-add-the-login-form")
        XCTAssertEqual(WorkingCopy.branch(for: item, taken: ["task/t-1-add-the-login-form"]),
                       "task/t-1-add-the-login-form-2")
        XCTAssertEqual(WorkingCopy.branch(for: item, taken: ["task/t-1-add-the-login-form",
                                                               "task/t-1-add-the-login-form-2"]),
                       "task/t-1-add-the-login-form-3")
        // A Mac's disk does not tell "Task" from "task".
        XCTAssertEqual(WorkingCopy.branch(for: item, taken: ["TASK/T-1-Add-The-Login-Form"]),
                       "task/t-1-add-the-login-form-2")
        // A repository with a branch named "task" has no room for "task/...".
        XCTAssertEqual(WorkingCopy.branch(for: item, taken: ["task"], flat: true), "task-t-1-add-the-login-form")
        let bare = board.add(title: "日本語", by: .person, now: t0)
        XCTAssertEqual(WorkingCopy.branch(for: bare, taken: []), "task/t-2")
    }

    func testACopysFolderIsNamedAfterItsTask() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        XCTAssertEqual(WorkingCopy.folderName(for: item, taken: []), "t-1")
        XCTAssertEqual(WorkingCopy.folderName(for: item, taken: ["t-1", "t-1-2"]), "t-1-3")
    }

    func testRunsStartInTheProjectsFolderInsideTheCopy() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        var made = workingCopy(for: item)
        XCTAssertEqual(made.directory, "/copies/app/t-1/apple")
        made.subfolder = ""
        XCTAssertEqual(made.directory, "/copies/app/t-1")
    }

    // MARK: When a copy is made

    func testATaskGetsACopyForItsFirstRunAndANewOneAfterItsLastIsClosed() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        XCTAssertTrue(board.settings.copyPerTask)
        XCTAssertTrue(board.needsCopy(item))
        board.setCopy(item.id, workingCopy(for: item), by: .person, now: t0)
        XCTAssertFalse(board.needsCopy(board.item(item.id)!))
        board.copyDiscarded(item.id, by: .person, now: minutes(1))
        XCTAssertTrue(board.needsCopy(board.item(item.id)!))
        board.setCopy(item.id, workingCopy(for: item, at: 2), by: .person, now: minutes(2))
        board.copyMerged(item.id, commit: "def5678", now: minutes(3))
        XCTAssertTrue(board.needsCopy(board.item(item.id)!))
    }

    func testATaskThatWorkedInTheFolderGoesOnWorkingThere() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        board.beginRun(item.id, attempt(in: UUID()), by: .person, now: t0)
        XCTAssertFalse(board.needsCopy(board.item(item.id)!))
        // And with copies switched off, nobody gets one.
        let fresh = board.add(title: "Other", by: .person, now: t0)
        board.settings.copyPerTask = false
        XCTAssertFalse(board.needsCopy(fresh))
    }

    // MARK: Who lets its work be merged

    func testApprovingLetsItsWorkBeMergedAndAskingForChangesDoesNot() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        board.setCopy(item.id, workingCopy(for: item), by: .person, now: t0)
        let chat = UUID()
        board.beginRun(item.id, attempt(in: chat), by: .person, now: t0)
        board.endRun(in: chat, outcome: .succeeded, report: "Done.", now: minutes(5))
        XCTAssertTrue(board.waitingToMerge.isEmpty)
        board.review(item.id, Review(verdict: .changesRequested, notes: "Add a test.", by: "Claude", date: minutes(6)),
                     now: minutes(6))
        XCTAssertNil(board.item(item.id)?.workingCopy?.approvedBy)
        XCTAssertEqual(board.item(item.id)?.status, .todo)

        let again = UUID()
        board.beginRun(item.id, attempt(in: again, at: 7), by: .autopilot, now: minutes(7))
        board.endRun(in: again, outcome: .succeeded, report: "Done.", now: minutes(9))
        board.review(item.id, Review(verdict: .approved, notes: "", by: "Claude", date: minutes(10)), now: minutes(10))
        XCTAssertEqual(board.item(item.id)?.status, .done)
        XCTAssertEqual(board.item(item.id)?.workingCopy?.approvedBy, "Claude")
        XCTAssertEqual(board.waitingToMerge.map(\.id), [item.id])
        XCTAssertFalse(board.mergeWaitsOnPerson(board.item(item.id)!))
    }

    func testAPersonCallingItDoneLetsItBeMergedAndTakingItBackUndoesThat() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        board.setCopy(item.id, workingCopy(for: item), by: .person, now: t0)
        board.move(item.id, to: .done, by: .person, now: minutes(1))
        XCTAssertEqual(board.item(item.id)?.workingCopy?.approvedBy, "You")
        board.move(item.id, to: .todo, by: .person, now: minutes(2))
        XCTAssertNil(board.item(item.id)?.workingCopy?.approvedBy)
        XCTAssertTrue(board.waitingToMerge.isEmpty)
    }

    func testARunBeginningTakesBackWhatWasApproved() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        board.setCopy(item.id, workingCopy(for: item), by: .person, now: t0)
        board.move(item.id, to: .done, by: .person, now: minutes(1))
        // The person takes the chat up again.
        board.beginRun(item.id, attempt(in: UUID(), at: 2), by: .person, now: minutes(2))
        XCTAssertNil(board.item(item.id)?.workingCopy?.approvedBy)
        XCTAssertEqual(board.item(item.id)?.status, .inProgress)
    }

    func testTheSupervisorCannotMergeWorkNobodyApproved() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        board.setCopy(item.id, workingCopy(for: item), by: .person, now: t0)
        let chat = UUID()
        board.beginRun(item.id, attempt(in: chat), by: .person, now: t0)
        board.endRun(in: chat, outcome: .succeeded, report: "Done.", now: minutes(5))
        let summary = board.apply([.move(ref: "T-1", .done)], model: { _ in nil }, now: minutes(6))
        XCTAssertEqual(summary.moved, 0)
        XCTAssertEqual(summary.problems.count, 1)
        XCTAssertEqual(board.item(item.id)?.status, .review)
        // A review that approves it is what lets it through.
        board.review(item.id, Review(verdict: .approved, notes: "", by: "Claude", date: minutes(7)), now: minutes(7))
        XCTAssertEqual(board.item(item.id)?.status, .done)
        XCTAssertEqual(board.waitingToMerge.map(\.id), [item.id])
        // Taken out of Done, it is taken back: moving it there again is refused.
        board.move(item.id, to: .review, by: .person, now: minutes(8))
        XCTAssertNil(board.item(item.id)?.workingCopy?.approvedBy)
        XCTAssertEqual(board.apply([.move(ref: "T-1", .done)], model: { _ in nil }, now: minutes(9)).moved, 0)
        // A task without a copy is moved as before.
        let plain = board.add(title: "Plain", by: .person, now: t0)
        XCTAssertEqual(board.apply([.move(ref: plain.key, .done)], model: { _ in nil }, now: minutes(10)).moved, 1)
    }

    // MARK: How a merge comes out

    func testAMergedCopyIsClosed() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        board.setCopy(item.id, workingCopy(for: item), by: .person, now: t0)
        board.move(item.id, to: .done, by: .person, now: minutes(1))
        XCTAssertTrue(board.copyMerged(item.id, commit: "def5678", now: minutes(2)))
        let closed = board.item(item.id)?.workingCopy
        XCTAssertEqual(closed?.state, .merged)
        XCTAssertEqual(closed?.mergeCommit, "def5678")
        XCTAssertEqual(closed?.closedAt, minutes(2))
        XCTAssertTrue(board.waitingToMerge.isEmpty)
        XCTAssertEqual(board.activity.last?.text, "Merged T-1 into main (def5678)")
        XCTAssertEqual(board.activity.last?.actor, .person)
        // A closed copy is not merged twice.
        XCTAssertFalse(board.copyMerged(item.id, commit: "def5678", now: minutes(3)))
    }

    func testAMergeHeldBackWaitsForThePersonToTryAgain() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        board.setCopy(item.id, workingCopy(for: item), by: .person, now: t0)
        board.move(item.id, to: .done, by: .person, now: minutes(1))
        board.copyHeld(item.id, problem: "Your folder has changes to App.swift that are not committed.", now: minutes(2))
        XCTAssertTrue(board.waitingToMerge.isEmpty)
        XCTAssertTrue(board.mergeWaitsOnPerson(board.item(item.id)!))
        XCTAssertTrue(board.mergeAgain(item.id, now: minutes(3)))
        XCTAssertNil(board.item(item.id)?.workingCopy?.problem)
        XCTAssertEqual(board.waitingToMerge.map(\.id), [item.id])
        // Only a done task's work is merged.
        let other = board.add(title: "Other", by: .person, now: t0)
        board.setCopy(other.id, workingCopy(for: other), by: .person, now: t0)
        XCTAssertFalse(board.mergeAgain(other.id, now: minutes(4)))
    }

    func testConflictsSendTheTaskBackToSettleThem() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        board.setCopy(item.id, workingCopy(for: item), by: .person, now: t0)
        let chat = UUID()
        board.beginRun(item.id, attempt(in: chat), by: .person, now: t0)
        board.endRun(in: chat, outcome: .succeeded, report: "Done.", now: minutes(5))
        board.review(item.id, Review(verdict: .approved, notes: "", by: "Claude", date: minutes(6)), now: minutes(6))
        XCTAssertTrue(board.copyConflicts(item.id, files: ["App.swift", "Board.swift"], now: minutes(7)))
        let task = board.item(item.id)!
        XCTAssertEqual(task.status, .todo)
        XCTAssertEqual(task.workingCopy?.conflicts, ["App.swift", "Board.swift"])
        XCTAssertNil(task.workingCopy?.approvedBy)
        XCTAssertTrue(task.workingCopy?.isOpen ?? false)
        XCTAssertEqual(task.notes.last?.author, "Git")
        XCTAssertTrue(task.notes.last?.text.contains("App.swift, Board.swift") ?? false)
        // The supervisor approved it, so the move back is under its name.
        XCTAssertEqual(board.activity.last?.actor, .supervisor)
        XCTAssertFalse(board.needsCopy(task))
        // Merged at last, the conflicts are behind it.
        board.move(item.id, to: .done, by: .person, now: minutes(8))
        board.copyMerged(item.id, commit: "0a1b2c3", now: minutes(9))
        XCTAssertEqual(board.item(item.id)?.workingCopy?.conflicts, [])
    }

    func testThrowingAwayAReviewedTaskSendsItBack() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        board.setCopy(item.id, workingCopy(for: item), by: .person, now: t0)
        let chat = UUID()
        board.beginRun(item.id, attempt(in: chat), by: .person, now: t0)
        board.endRun(in: chat, outcome: .succeeded, report: "Done.", now: minutes(5))
        XCTAssertEqual(board.item(item.id)?.status, .review)
        XCTAssertTrue(board.copyDiscarded(item.id, by: .person, now: minutes(6)))
        XCTAssertEqual(board.item(item.id)?.status, .todo)
        XCTAssertEqual(board.item(item.id)?.workingCopy?.state, .discarded)
        // Its next run is told the work before it is gone.
        XCTAssertEqual(board.item(item.id)?.notes.last?.author, "Git")
        XCTAssertFalse(board.copyDiscarded(item.id, by: .person, now: minutes(7)))
        // One in To do stays there.
        let other = board.add(title: "Other", by: .person, now: t0)
        board.setCopy(other.id, workingCopy(for: other), by: .person, now: t0)
        board.copyDiscarded(other.id, by: .person, now: minutes(8))
        XCTAssertEqual(board.item(other.id)?.status, .todo)
    }

    func testACopyWhoseBranchIsGoneIsLetGo() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        board.setCopy(item.id, workingCopy(for: item), by: .person, now: t0)
        XCTAssertTrue(board.copyLost(item.id, now: minutes(1)))
        XCTAssertEqual(board.item(item.id)?.workingCopy?.state, .discarded)
        XCTAssertTrue(board.needsCopy(board.item(item.id)!))
    }

    func testRemovingATaskSaysItsBranchIsKept() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        board.setCopy(item.id, workingCopy(for: item), by: .person, now: t0)
        board.remove(item.id, by: .person, now: minutes(1))
        XCTAssertEqual(board.activity.last?.text, "Removed T-1: Work. Its work is kept on branch task/t-1-work")
    }

    // MARK: Where its chat is listed

    func testAChatWhoseWorkWaitsToBeMergedIsListed() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        board.setCopy(item.id, workingCopy(for: item), by: .person, now: t0)
        let chat = UUID()
        board.beginRun(item.id, attempt(in: chat), by: .person, now: t0)
        board.endRun(in: chat, outcome: .succeeded, report: "Done.", now: minutes(5))
        board.review(item.id, Review(verdict: .approved, notes: "", by: "You", date: minutes(6)), now: minutes(6))
        let seen = ChatShelf.Chat(id: chat, purpose: .task(item.id), lastActivity: minutes(6))
        XCTAssertEqual(ChatShelf.spot(of: seen, board: board, now: minutes(6)),
                       ChatShelf.Spot(place: .running, task: item.id))
        board.copyHeld(item.id, problem: "Changes of yours are in the way.", now: minutes(7))
        XCTAssertEqual(ChatShelf.spot(of: seen, board: board, now: minutes(7)),
                       ChatShelf.Spot(place: .needsYou, task: item.id, need: .merge))
        board.mergeAgain(item.id, now: minutes(8))
        board.copyMerged(item.id, commit: "abc", now: minutes(9))
        XCTAssertEqual(ChatShelf.spot(of: seen, board: board, now: minutes(9)),
                       ChatShelf.Spot(place: .archived, task: item.id))
    }

    // MARK: Saved and read back

    func testACopyIsSavedAndReadBackAndOlderDataStillLoads() throws {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        board.setCopy(item.id, workingCopy(for: item), by: .person, now: t0)
        board.copyHeld(item.id, problem: "In the way.", now: minutes(1))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let read = try decoder.decode(Board.self, from: encoder.encode(board))
        XCTAssertEqual(read.item(item.id)?.workingCopy, board.item(item.id)?.workingCopy)

        // A copy saved with only what names it.
        let bare = """
        {"folder":"/copies/t-1","branch":"task/t-1","base":"main"}
        """
        let old = try decoder.decode(WorkingCopy.self, from: Data(bare.utf8))
        XCTAssertEqual(old.state, .open)
        XCTAssertEqual(old.subfolder, "")
        XCTAssertEqual(old.conflicts, [])
        XCTAssertEqual(old.directory, "/copies/t-1")

        // A board from before copies: tasks have none, and boards give one.
        let json = """
        {"project":"00000000-0000-0000-0000-0000000000CC",
         "settings":{"autopilot":true},
         "items":[{"id":"00000000-0000-0000-0000-000000000001","number":1,"title":"Old task"}]}
        """
        let older = try decoder.decode(Board.self, from: Data(json.utf8))
        XCTAssertNil(older.items.first?.workingCopy)
        XCTAssertTrue(older.settings.copyPerTask)
        // A copy from before the board had a branch of its own.
        XCTAssertNil(old.target)
        XCTAssertEqual(old.settleTries, 0)
    }

    func testTheBoardHasABranchOfItsOwnForEachOfThePersonsBranches() {
        XCTAssertEqual(WorkingCopy.boardBranch(for: "main"), "companion/main")
        XCTAssertEqual(WorkingCopy.boardBranch(for: "feature/login"), "companion/feature/login")
        // A repository with a branch named "companion" has no room for "companion/...".
        XCTAssertEqual(WorkingCopy.boardBranch(for: "feature/login", flat: true), "companion-feature-login")
        XCTAssertTrue(WorkingCopy.isBoardBranch("companion/main"))
        XCTAssertFalse(WorkingCopy.isBoardBranch("main"))
        XCTAssertFalse(WorkingCopy.isBoardBranch("companion-app"))
    }

    func testConflictsThatComeBackTooOftenWaitForThePerson() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        board.setCopy(item.id, workingCopy(for: item), by: .person, now: t0)
        for round in 0..<BoardRules.settleLimit {
            board.move(item.id, to: .done, by: .person, now: minutes(Double(round)))
            XCTAssertTrue(board.copyConflicts(item.id, files: ["App.swift"], now: minutes(Double(round))))
            XCTAssertEqual(board.item(item.id)?.status, .todo)
            XCTAssertNil(board.item(item.id)?.workingCopy?.problem)
        }
        board.move(item.id, to: .done, by: .person, now: minutes(10))
        XCTAssertTrue(board.copyConflicts(item.id, files: ["App.swift"], now: minutes(11)))
        let task = board.item(item.id)!
        XCTAssertEqual(task.status, .done)
        XCTAssertTrue(task.workingCopy?.problem?.contains("App.swift") ?? false)
        XCTAssertTrue(board.mergeWaitsOnPerson(task))
        XCTAssertTrue(board.waitingToMerge.isEmpty)
    }
}
