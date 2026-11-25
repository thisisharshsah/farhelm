import XCTest
@testable import CompanionBoard

private let project = UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let gigabyte: UInt64 = 1 << 30
/// A Mac with room to spare: 10 idle cores and 32 GB free.
private let roomy = RunLimit.Mac(cores: 10, load: 0, freeMemory: 32 * gigabyte)

final class RunLimitTests: XCTestCase {

    // MARK: - The limit

    func testMacRoomIsTheSmallerOfProcessorsAndMemory() {
        XCTAssertEqual(RunLimit.macRoom(RunLimit.Mac(cores: 8, load: 2, freeMemory: 4 * gigabyte)), 4)
        XCTAssertEqual(RunLimit.macRoom(RunLimit.Mac(cores: 4, load: 3, freeMemory: 16 * gigabyte)), 2)
        XCTAssertEqual(RunLimit.macRoom(RunLimit.Mac(cores: 4, load: 6, freeMemory: 16 * gigabyte)), 0)
    }

    func testMoreThanFourBoardRunsStartOnARoomyMac() {
        let slots = RunLimit.slots(RunLimit.Inputs(mac: roomy, ready: Array(repeating: nil, count: 6)))
        XCTAssertEqual(slots.limit, 6)
        XCTAssertEqual(slots.forBoards, 6)
        XCTAssertEqual(slots.reason, "Nothing running, room for 6 more")
    }

    func testAPlanAtItsLimitHoldsBackOnlyItsOwnTasks() {
        let codex = RunLimit.Plan(group: "codex", name: "Codex", used: 1, running: 0)
        let slots = RunLimit.slots(RunLimit.Inputs(mac: roomy, plans: [codex],
                                                   ready: ["codex", "codex", nil, "other"]))
        XCTAssertEqual(slots.limit, 2)
    }

    func testAPlanNearlyUsedTakesOneRunAtATime() {
        let plan = RunLimit.Plan(group: "claude", name: "Claude Code", used: 0.95, running: 0)
        let slots = RunLimit.slots(RunLimit.Inputs(mac: roomy, plans: [plan], ready: ["claude", "claude", "claude"]))
        XCTAssertEqual(slots.limit, 1)
        XCTAssertTrue(slots.reason.contains("Claude Code nearly at its limit"))
    }

    func testTheReasonNamesThePlanAndTheBlockedTasks() {
        let codex = RunLimit.Plan(group: "codex", name: "Codex", used: 1, running: 1)
        let slots = RunLimit.slots(RunLimit.Inputs(mac: roomy, plans: [codex], chats: 1, boardRuns: 3,
                                                   ready: ["codex", "codex"], blocked: 2))
        XCTAssertEqual(slots.limit, 4)
        XCTAssertEqual(slots.forBoards, 3)
        XCTAssertEqual(slots.free(boardRuns: 3), 0)
        XCTAssertEqual(slots.reason, "4 running: Codex at its limit, 2 tasks blocked")
    }

    func testABusyMacStillRunsOneWhenNothingRuns() {
        let busy = RunLimit.Mac(cores: 4, load: 4, freeMemory: 8 * gigabyte)
        let slots = RunLimit.slots(RunLimit.Inputs(mac: busy, ready: [nil, nil, nil]))
        XCTAssertEqual(slots.limit, 1)
        XCTAssertEqual(slots.reason, "Nothing running: the Mac's processors are busy")
    }

    func testRunsGoingOnKeepTheirSlotsAndChatsComeFirst() {
        let busy = RunLimit.Mac(cores: 2, load: 8, freeMemory: gigabyte / 2)
        let slots = RunLimit.slots(RunLimit.Inputs(mac: busy, chats: 3, boardRuns: 2, ready: [nil]))
        // Nothing more fits, but nothing going on is counted out.
        XCTAssertEqual(slots.limit, 5)
        // The owner's chats hold their slots; board runs get the rest.
        XCTAssertEqual(slots.forBoards, 2)
        XCTAssertEqual(slots.free(boardRuns: 2), 0)
    }

    func testTheLimitNeverPassesTheMost() {
        let slots = RunLimit.slots(RunLimit.Inputs(mac: RunLimit.Mac(cores: 64, load: 0, freeMemory: 256 * gigabyte),
                                                   ready: Array(repeating: nil, count: 40)))
        XCTAssertEqual(slots.limit, RunLimit.most)
        XCTAssertTrue(slots.reason.contains("\(RunLimit.most) is the most at once"))
    }

    func testTheCostCeilingOnlyLowersTheRoom() {
        XCTAssertEqual(RunLimit.boardRoom(free: 5, running: 1, ceiling: nil), 5)
        XCTAssertEqual(RunLimit.boardRoom(free: 5, running: 1, ceiling: 3), 2)
        XCTAssertEqual(RunLimit.boardRoom(free: 1, running: 0, ceiling: 3), 1)
        XCTAssertEqual(RunLimit.boardRoom(free: 4, running: 3, ceiling: 2), 0)
    }

    // MARK: - The queue

    func testTheQueueStartsTheMostPressingFirstThenTheLowerNumber() {
        var board = Board(project: project, now: t0)
        let low = board.add(title: "Low", priority: .low, by: .person, now: t0)
        let urgent = board.add(title: "Urgent", priority: .urgent, by: .person, now: t0)
        let medium = board.add(title: "Medium", priority: .medium, by: .person, now: t0)
        let urgentLater = board.add(title: "Urgent later", priority: .urgent, by: .person, now: t0)
        let high = board.add(title: "High", priority: .high, by: .person, now: t0)
        let order = RunLimit.queueOrder([low, medium, high, urgentLater, urgent]).map(\.number)
        XCTAssertEqual(order, [urgent.number, urgentLater.number, high.number, medium.number, low.number])
    }

    func testOnlyAsManyAsThereAreSlotsArePicked() {
        var board = Board(project: project, now: t0)
        _ = board.add(title: "A", priority: .low, by: .person, now: t0)
        let b = board.add(title: "B", priority: .high, by: .person, now: t0)
        let c = board.add(title: "C", priority: .urgent, by: .person, now: t0)
        let picked = RunLimit.pick(board.ready, on: board, slots: 2)
        XCTAssertEqual(picked.map(\.item.number), [c.number, b.number])
        XCTAssertTrue(picked.allSatisfy { $0.seat == .anyone })
    }

    func testOneRunPerSpecialist() {
        var board = Board(project: project, now: t0)
        board.addRole(TeamRole(key: "swift", title: "Swift engineer", kinds: [.feature], createdAt: t0),
                      by: .person, now: t0)
        board.addRole(TeamRole(key: "writer", title: "Writer", kinds: [.docs], createdAt: t0),
                      by: .person, now: t0)
        let s1 = board.addSpecialist(role: "swift", by: .person, now: t0)!
        let s2 = board.addSpecialist(role: "swift", by: .person, now: t0)!
        let w1 = board.addSpecialist(role: "writer", by: .person, now: t0)!
        let first = board.add(title: "Swift 1", priority: .urgent, role: "swift", by: .person, now: t0)
        let second = board.add(title: "Swift 2", priority: .high, role: "swift", by: .person, now: t0)
        _ = board.add(title: "Swift 3", priority: .high, role: "swift", by: .person, now: t0)
        let docs = board.add(title: "Docs", priority: .low, role: "writer", by: .person, now: t0)

        let picked = RunLimit.pick(board.ready, on: board, slots: 8)
        // Two Swift engineers take the two most pressing Swift tasks; the
        // third waits for one of them, and the writer is not held up.
        XCTAssertEqual(picked.map(\.item.number), [first.number, second.number, docs.number])
        XCTAssertEqual(picked.map(\.seat), [.specialist(s1.id), .specialist(s2.id), .specialist(w1.id)])
    }

    func testABusySpecialistIsNotGivenASecondRun() {
        var board = Board(project: project, now: t0)
        board.addRole(TeamRole(key: "swift", title: "Swift engineer", kinds: [.feature], createdAt: t0),
                      by: .person, now: t0)
        let only = board.addSpecialist(role: "swift", by: .person, now: t0)!
        let running = board.add(title: "Running", role: "swift", by: .person, now: t0)
        let waiting = board.add(title: "Waiting", role: "swift", by: .person, now: t0)
        board.beginRun(running.id, WorkRun(conversation: UUID(), model: ModelChoice(engine: "test", model: "m1"),
                                           modelLabel: "M1", startedAt: t0, specialist: only.id),
                       by: .person, now: t0)
        XCTAssertEqual(RunLimit.seat(for: board.item(waiting.id)!, on: board), .busy)
        XCTAssertTrue(RunLimit.pick(board.ready, on: board, slots: 4).isEmpty)
    }
}