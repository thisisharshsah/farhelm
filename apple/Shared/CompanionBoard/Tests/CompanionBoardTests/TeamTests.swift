import XCTest
@testable import CompanionBoard

private let project = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func minutes(_ count: Double) -> Date { t0.addingTimeInterval(count * 60) }
private func choice(_ model: String) -> ModelChoice { ModelChoice(engine: "test", model: model) }

final class TeamTests: XCTestCase {

    // MARK: - Specialist never runs two tasks at once

    func testASpecialistNeverRunsTwoTasksAtOnce() {
        var board = Board(project: project, now: t0)
        let role = TeamRole(key: "swift", title: "Swift engineer",
                            kinds: [.feature, .bug], createdAt: t0)
        board.addRole(role, by: .person, now: t0)
        let spec = board.addSpecialist(role: "swift", by: .person, now: t0)!

        let a = board.add(title: "Task A", role: "swift", by: .person, now: t0)
        _ = board.add(title: "Task B", role: "swift", by: .person, now: t0)

        let chatA = UUID()
        let runA = WorkRun(conversation: chatA, model: choice("m1"), modelLabel: "M1",
                           startedAt: minutes(1), specialist: spec.id)
        board.beginRun(a.id, runA, by: .person, now: minutes(1))

        // The specialist is busy: freeSpecialist returns nil, so a
        // second task of this role cannot start.
        XCTAssertNil(board.freeSpecialist(for: "swift"),
                     "A specialist with an active run must not be free")

        // After the run ends, the specialist is free again.
        board.endRun(in: chatA, outcome: .succeeded, report: "Done.", now: minutes(5))
        XCTAssertNotNil(board.freeSpecialist(for: "swift"),
                        "A specialist whose run ended must be free again")
    }

    func testTwoSpecialistsRunTwoTasksInParallel() {
        var board = Board(project: project, now: t0)
        board.settings.teamLimit = 4
        let role = TeamRole(key: "swift", title: "Swift engineer",
                            kinds: [.feature], createdAt: t0)
        board.addRole(role, by: .person, now: t0)
        let s1 = board.addSpecialist(role: "swift", by: .person, now: t0)!
        let s2 = board.addSpecialist(role: "swift", by: .person, now: t0)!

        let a = board.add(title: "Task A", role: "swift", by: .person, now: t0)
        let b = board.add(title: "Task B", role: "swift", by: .person, now: t0)

        let chatA = UUID()
        board.beginRun(a.id, WorkRun(conversation: chatA, model: choice("m1"),
                                     modelLabel: "M1", startedAt: t0, specialist: s1.id),
                       by: .person, now: t0)

        // s1 is busy, s2 is free.
        let free = board.freeSpecialist(for: "swift")
        XCTAssertEqual(free?.id, s2.id)

        let chatB = UUID()
        board.beginRun(b.id, WorkRun(conversation: chatB, model: choice("m1"),
                                     modelLabel: "M1", startedAt: minutes(1), specialist: s2.id),
                       by: .person, now: minutes(1))

        // Both busy: no free specialist.
        XCTAssertNil(board.freeSpecialist(for: "swift"))

        // Both tasks are in progress.
        XCTAssertEqual(board.running.count, 2)
    }

    // MARK: - Role routing

    func testRoutingByPathCoverage() {
        let roles = [
            TeamRole(key: "swift", title: "Swift", kinds: [.feature],
                     paths: ["apple/Sources", "apple/Shared"], createdAt: t0),
            TeamRole(key: "web", title: "Web", kinds: [.feature],
                     paths: ["web/src"], createdAt: t0),
        ]
        let items: [WorkItem] = []

        let swiftTask = WorkItem(number: 1, title: "Fix login",
                                 paths: ["apple/Sources/Login.swift"],
                                 createdAt: t0)
        XCTAssertEqual(TeamRouting.role(for: swiftTask, among: roles, items: items), "swift")

        let webTask = WorkItem(number: 2, title: "Fix CSS",
                                paths: ["web/src/app.css"],
                                createdAt: t0)
        XCTAssertEqual(TeamRouting.role(for: webTask, among: roles, items: items), "web")
    }

    func testRoutingByKindWhenNoPathMatch() {
        let roles = [
            TeamRole(key: "writer", title: "Writer", kinds: [.docs],
                     createdAt: t0),
            TeamRole(key: "dev", title: "Dev", kinds: [.feature, .bug],
                     createdAt: t0),
        ]
        let docsTask = WorkItem(number: 1, title: "Write README", kind: .docs,
                                createdAt: t0)
        XCTAssertEqual(TeamRouting.role(for: docsTask, among: roles, items: []), "writer")
    }

    func testRoutingReturnsNilWhenNoRoleScores() {
        let roles = [
            TeamRole(key: "swift", title: "Swift", kinds: [.feature],
                     paths: ["apple/"], createdAt: t0),
        ]
        let task = WorkItem(number: 1, title: "Research", kind: .research,
                            paths: ["docs/notes.md"], createdAt: t0)
        XCTAssertNil(TeamRouting.role(for: task, among: roles, items: []))
    }

    // MARK: - Team management

    func testCannotAddMoreSpecialistsThanTeamLimit() {
        var board = Board(project: project, now: t0)
        board.settings.teamLimit = 2
        let role = TeamRole(key: "dev", title: "Dev", kinds: [.feature], createdAt: t0)
        board.addRole(role, by: .person, now: t0)
        XCTAssertNotNil(board.addSpecialist(role: "dev", by: .person, now: t0))
        XCTAssertNotNil(board.addSpecialist(role: "dev", by: .person, now: t0))
        XCTAssertNil(board.addSpecialist(role: "dev", by: .person, now: t0),
                     "Team at its limit: no more specialists")
    }

    func testCannotRetireSpecialistWithActiveRun() {
        var board = Board(project: project, now: t0)
        let role = TeamRole(key: "dev", title: "Dev", kinds: [.feature], createdAt: t0)
        board.addRole(role, by: .person, now: t0)
        let spec = board.addSpecialist(role: "dev", by: .person, now: t0)!

        let task = board.add(title: "Work", role: "dev", by: .person, now: t0)
        let chat = UUID()
        board.beginRun(task.id, WorkRun(conversation: chat, model: choice("m1"),
                                        modelLabel: "M1", startedAt: t0, specialist: spec.id),
                       by: .person, now: t0)

        XCTAssertFalse(board.retireSpecialist(id: spec.id, by: .person, now: minutes(1)),
                       "Cannot retire a specialist with an active run")

        board.endRun(in: chat, outcome: .succeeded, report: "Done.", now: minutes(5))
        XCTAssertTrue(board.retireSpecialist(id: spec.id, by: .person, now: minutes(6)))
    }

    func testCannotRetireRoleWithOpenTasks() {
        var board = Board(project: project, now: t0)
        let role = TeamRole(key: "dev", title: "Dev", kinds: [.feature], createdAt: t0)
        board.addRole(role, by: .person, now: t0)
        _ = board.addSpecialist(role: "dev", by: .person, now: t0)
        _ = board.add(title: "Open task", role: "dev", by: .person, now: t0)

        XCTAssertFalse(board.retireRole(key: "dev", by: .person, now: t0),
                       "Cannot retire a role with open tasks")
    }

    func testIdleSpecialists() {
        var board = Board(project: project, now: t0)
        let role = TeamRole(key: "dev", title: "Dev", kinds: [.feature], createdAt: t0)
        board.addRole(role, by: .person, now: t0)
        _ = board.addSpecialist(role: "dev", by: .person, now: t0)
        _ = board.addSpecialist(role: "dev", by: .person, now: t0)

        let after24h = t0.addingTimeInterval(TeamRules.idleInterval + 60)
        let idle = board.idleSpecialists(now: after24h)
        XCTAssertEqual(idle.count, 2, "Both idle: no tasks and no runs for 24+ hours")
    }

    // MARK: - Migration

    func testV2BoardMigratesToV3WithGeneralist() {
        // A minimal v2 board as JSON.
        let v2JSON = """
        {
            "version": 2,
            "project": "00000000-0000-0000-0000-0000000000BB",
            "goals": [{"id": "00000000-0000-0000-0000-000000000001", "number": 1, "text": "Ship v1",
                        "startedAt": 0, "isActive": true}],
            "currentGoal": "00000000-0000-0000-0000-000000000001",
            "items": [
                {"id": "00000000-0000-0000-0000-000000000010", "number": 1, "title": "Build login",
                 "status": "todo", "createdAt": 0}
            ],
            "nextNumber": 2,
            "settings": {"parallel": 2},
            "createdAt": 0, "updatedAt": 0
        }
        """

        let data = Data(v2JSON.utf8)
        let board = try! JSONDecoder().decode(Board.self, from: data)

        XCTAssertEqual(board.version, 3)
        XCTAssertEqual(board.roles.count, 1)
        XCTAssertEqual(board.roles.first?.key, "generalist")
        XCTAssertEqual(board.roles.first?.isActive, true)
        XCTAssertEqual(board.specialists.count, 2, "parallel was 2, so 2 specialists")
        XCTAssertEqual(board.settings.teamLimit, 2)

        // Every task got the Generalist role.
        XCTAssertTrue(board.allItems.allSatisfy { $0.role == "generalist" })
        // The original task is intact.
        XCTAssertEqual(board.allItems.first?.title, "Build login")
        XCTAssertEqual(board.allItems.first?.status, .todo)
    }

    func testV2BoardWithNoSettingsMigratesWithDefaults() {
        let v2JSON = """
        {
            "version": 2,
            "project": "00000000-0000-0000-0000-0000000000BB",
            "goals": [{"id": "00000000-0000-0000-0000-000000000001", "number": 1, "text": "",
                        "startedAt": 0, "isActive": true}],
            "currentGoal": "00000000-0000-0000-0000-000000000001",
            "items": [],
            "nextNumber": 1,
            "createdAt": 0, "updatedAt": 0
        }
        """

        let board = try! JSONDecoder().decode(Board.self, from: Data(v2JSON.utf8))
        XCTAssertEqual(board.version, 3)
        XCTAssertEqual(board.roles.count, 1)
        XCTAssertEqual(board.specialists.count, BoardSettings.defaultParallel)
    }

    // MARK: - Overrun ending

    func testOverrunRunIsNotCarriedOn() {
        var board = Board(project: project, now: t0)
        let role = TeamRole(key: "dev", title: "Dev", kinds: [.feature], createdAt: t0)
        board.addRole(role, by: .person, now: t0)
        _ = board.addSpecialist(role: "dev", by: .person, now: t0)

        let task = board.add(title: "Big task", role: "dev", by: .person, now: t0)
        let chat = UUID()
        board.beginRun(task.id, WorkRun(conversation: chat, model: choice("m1"),
                                        modelLabel: "M1", startedAt: t0),
                       by: .person, now: t0)
        board.endRun(in: chat, outcome: .stopped, report: "Over estimate.",
                     ending: .overrun, now: minutes(10))

        XCTAssertFalse(board.mayCarryOn(board.item(task.id)!),
                       "An overrun run must not be carried on")
    }
}