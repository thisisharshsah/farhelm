import XCTest
@testable import CompanionBoard

private let project = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func minutes(_ count: Double) -> Date { t0.addingTimeInterval(count * 60) }

private func choice(_ model: String) -> ModelChoice { ModelChoice(engine: "test", model: model) }

final class CleanupTests: XCTestCase {
    func testACardCannotBeSavedWithAnEmptyTitle() {
        var board = Board(project: project, now: t0)
        // Adding with a blank title is refused and said.
        let added = board.apply([.add(label: nil, ItemPatch(title: "   "))], model: { _ in nil }, now: t0)
        XCTAssertEqual(added.added, 0)
        XCTAssertEqual(added.problems, ["A new task had no title and was left out."])
        XCTAssertTrue(board.items.isEmpty)

        // Updating to a blank title is refused: the card keeps the title it had.
        let item = board.add(title: "Real work", by: .person, now: t0)
        board.update(item.id, now: t0) { $0.title = "  \n " }
        XCTAssertEqual(board.item(item.id)?.title, "Real work")
        let updated = board.apply([.update(ref: item.key, ItemPatch(title: " "))], model: { _ in nil }, now: t0)
        XCTAssertEqual(updated.updated, 0)
        XCTAssertEqual(board.item(item.id)?.title, "Real work")
    }

    func testCleanupRemovesAnUntitledCardAndArchivesOneWithRuns() {
        var board = Board(project: project, now: t0)
        // An untitled card with nothing in it and no runs is left through
        // its grace (someone may be writing it), then taken off by itself.
        let blank = board.add(title: BoardRules.newTaskTitle, by: .person, now: t0)
        XCTAssertEqual(board.sweepAbandoned(now: minutes(3)), 0)
        XCTAssertNotNil(board.item(blank.id))
        XCTAssertEqual(board.sweepAbandoned(now: minutes(6)), 1)
        XCTAssertNil(board.item(blank.id))

        // An untitled card with runs is archived by the tidy pass after a
        // supervisor update, never removed: its runs and chat are kept.
        let worked = board.add(title: BoardRules.untitled, by: .person, now: minutes(10))
        let chat = UUID()
        board.beginRun(worked.id, WorkRun(conversation: chat, model: choice("m"), modelLabel: "M",
                                          startedAt: minutes(10)), by: .person, now: minutes(10))
        board.endRun(in: chat, outcome: .failed, report: nil, now: minutes(11))
        let summary = board.apply([], model: { _ in nil }, now: minutes(20))
        XCTAssertEqual(summary.cleaned, ["Archived \(worked.key): it has no title."])
        XCTAssertEqual(summary.archived, [worked.id])
        XCTAssertNotNil(board.item(worked.id)?.archivedAt)
        XCTAssertEqual(board.item(worked.id)?.runs.count, 1)

        // Of two cards that say the same, the earliest stays; the later
        // one, with nothing of its own and no runs, goes.
        let first = board.add(title: "Ship it", by: .person, now: minutes(21))
        let second = board.add(title: "Ship it", by: .person, now: minutes(21))
        let tidied = board.apply([], model: { _ in nil }, now: minutes(22))
        XCTAssertEqual(tidied.cleaned, ["Removed \(second.key): it says the same as T-\(first.number)."])
        XCTAssertNil(board.item(second.id))
        XCTAssertNotNil(board.item(first.id))
    }

    func testArchivedCardsLeaveTheColumnsAndStayInHistory() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Shipped once", by: .person, now: t0)
        let chat = UUID()
        board.beginRun(item.id, WorkRun(conversation: chat, model: choice("m"), modelLabel: "M", startedAt: t0),
                       by: .person, now: t0)
        board.endRun(in: chat, outcome: .succeeded, report: "Done.", now: minutes(1))
        XCTAssertTrue(board.archive(item.id, by: .person, now: minutes(2)))

        // Off every column, but still on the board's record, with its
        // runs, its chat and a history line.
        XCTAssertTrue(board.items.isEmpty)
        for status in WorkStatus.allCases {
            XCTAssertTrue(board.items(in: status).isEmpty, status.title)
        }
        XCTAssertEqual(board.item(item.id)?.runs.count, 1)
        XCTAssertEqual(board.item(item.id)?.chat, chat)
        XCTAssertTrue(board.runConversations.contains(chat))
        XCTAssertTrue(board.activity.map(\.text).contains("Archived \(item.key): Shipped once"))

        // A card with a run going on is never archived.
        let busy = board.add(title: "Busy", by: .person, now: minutes(3))
        board.beginRun(busy.id, WorkRun(conversation: UUID(), model: choice("m"), modelLabel: "M",
                                        startedAt: minutes(3)), by: .person, now: minutes(3))
        XCTAssertFalse(board.archive(busy.id, by: .person, now: minutes(4)))
    }
}