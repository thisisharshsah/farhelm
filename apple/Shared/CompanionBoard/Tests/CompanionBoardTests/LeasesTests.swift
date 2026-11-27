import XCTest
@testable import CompanionBoard

private let project = UUID(uuidString: "00000000-0000-0000-0000-0000000000DD")!
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let model = ModelChoice(engine: "anthropic", model: "m")

private func minutes(_ count: Double) -> Date { t0.addingTimeInterval(count * 60) }

private func attempt(in chat: UUID) -> WorkRun {
    WorkRun(conversation: chat, model: model, modelLabel: "M", startedAt: t0)
}

private func workingCopy(for item: WorkItem) -> WorkingCopy {
    WorkingCopy(folder: "/copies/\(item.key.lowercased())", branch: WorkingCopy.branch(for: item, taken: []),
                base: "companion/main", baseCommit: "abc1234", madeAt: t0, target: "main")
}

final class LeasesTests: XCTestCase {
    func testPathsAreComparedAsADiskComparesThem() {
        XCTAssertEqual(Leases.normal("./Sources/App/"), "sources/app")
        XCTAssertEqual(Leases.normal("/Sources//App/Login.swift"), "sources/app/login.swift")
        XCTAssertEqual(Leases.normal("Sources\\App"), "sources/app")
        // A wildcard ends the part that can be told.
        XCTAssertEqual(Leases.normal("Sources/App/*.swift"), "sources/app")
        XCTAssertEqual(Leases.normal("**/*.ts"), "")
        XCTAssertEqual(Leases.normal("."), "")
    }

    func testAPathOverlapsWhatIsInsideItAndNothingBeside() {
        XCTAssertTrue(Leases.overlap("Sources/App", "Sources/App/Login.swift"))
        XCTAssertTrue(Leases.overlap("sources/app/login.swift", "Sources/App/"))
        XCTAssertTrue(Leases.overlap("README.md", "./readme.md"))
        XCTAssertFalse(Leases.overlap("Sources/App", "Sources/AppKit/View.swift"))
        XCTAssertFalse(Leases.overlap("docs/a.md", "docs/b.md"))
        // The whole project overlaps everything.
        XCTAssertTrue(Leases.overlap(".", "docs/a.md"))
    }

    func testAListIsKeptTidyWithoutTheSamePathTwice() {
        XCTAssertEqual(Leases.list([" ./src/a.ts ", "src/A.ts", "", "docs/"]), ["src/a.ts", "docs/"])
        XCTAssertEqual(Leases.list(Array(repeating: "x", count: 3) + (1...60).map { "f\($0)" }).count, Leases.pathLimit)
    }

    func testTwoTasksMeetWhereTheirPathsOverlapAndUnknownMeetsEverything() {
        XCTAssertEqual(Leases.meeting(["src/auth/"], ["docs/", "src/auth/login.ts"]), "src/auth/")
        XCTAssertNil(Leases.meeting(["src/auth/"], ["src/billing/"]))
        XCTAssertEqual(Leases.meeting([], ["src/billing/"]), "")
        XCTAssertEqual(Leases.meeting(["src/auth/"], []), "")
    }

    func testARunningTaskKeepsAnotherOnTheSameFilesWaitingButNotOneElsewhere() {
        var board = Board(project: project, now: t0)
        let auth = board.add(title: "Sign-in", paths: ["src/auth/"], by: .person, now: t0)
        let login = board.add(title: "Login page", paths: ["src/auth/login.ts"], by: .person, now: t0)
        let billing = board.add(title: "Invoices", paths: ["src/billing/"], by: .person, now: t0)
        let vague = board.add(title: "Tidy up", by: .person, now: t0)
        board.beginRun(auth.id, attempt(in: UUID()), by: .person, now: t0)
        XCTAssertEqual(board.leaseHolder(for: board.item(login.id)!, changed: [:])?.holder.id, auth.id)
        XCTAssertEqual(board.leaseHolder(for: board.item(login.id)!, changed: [:])?.path, "src/auth/login.ts")
        XCTAssertNil(board.leaseHolder(for: board.item(billing.id)!, changed: [:]))
        // A task that does not say where it works runs alone.
        XCTAssertEqual(board.leaseHolder(for: board.item(vague.id)!, changed: [:])?.path, "")
        // Being started counts as running.
        XCTAssertEqual(board.leaseHolder(for: board.item(billing.id)!, changed: [:], starting: [vague.id])?.holder.id,
                       vague.id)
    }

    func testWorkNotMergedYetHoldsWhatItChanged() {
        var board = Board(project: project, now: t0)
        let first = board.add(title: "First", paths: ["src/a/"], by: .person, now: t0)
        let second = board.add(title: "Second", paths: ["src/b/"], by: .person, now: t0)
        board.setCopy(first.id, workingCopy(for: first), by: .person, now: t0)
        let chat = UUID()
        board.beginRun(first.id, attempt(in: chat), by: .person, now: t0)
        board.endRun(in: chat, outcome: .succeeded, report: "Done.", now: minutes(1))
        // In Review, with what it changed known: that is what it holds.
        XCTAssertEqual(board.leaseHolder(for: board.item(second.id)!, changed: [first.id: ["src/b/util.ts"]])?.holder.id,
                       first.id)
        XCTAssertNil(board.leaseHolder(for: board.item(second.id)!, changed: [first.id: ["src/a/x.ts"]]))
        // Not known yet: what it was planned to change.
        XCTAssertNil(board.leaseHolder(for: board.item(second.id)!, changed: [:]))
        // A copy with nothing in it holds nothing.
        XCTAssertNil(board.held(by: board.item(first.id)!, changed: []))
        // Merged, it holds nothing at all.
        board.review(first.id, Review(verdict: .approved, notes: "", by: "Claude", date: minutes(2)), now: minutes(2))
        board.copyMerged(first.id, commit: "def5678", now: minutes(3))
        XCTAssertNil(board.leaseHolder(for: board.item(second.id)!, changed: [first.id: ["src/b/util.ts"]]))
    }

    func testATaskWaitsForWhatItDependsOnToBeMergedNotOnlyDone() {
        var board = Board(project: project, now: t0)
        let base = board.add(title: "Base", by: .person, now: t0)
        let next = board.add(title: "Next", dependsOn: [base.number], by: .person, now: t0)
        board.setCopy(base.id, workingCopy(for: base), by: .person, now: t0)
        board.move(base.id, to: .done, by: .person, now: minutes(1))
        XCTAssertEqual(board.blockers(of: board.item(next.id)!).map(\.id), [base.id])
        XCTAssertFalse(board.ready.contains { $0.id == next.id })
        board.copyMerged(base.id, commit: "def5678", now: minutes(2))
        XCTAssertTrue(board.blockers(of: board.item(next.id)!).isEmpty)
        XCTAssertTrue(board.ready.contains { $0.id == next.id })
    }

    func testTheSupervisorSaysWhereEachTaskWorks() {
        var board = Board(project: project, now: t0)
        let summary = board.apply([
            .add(label: "a", ItemPatch(title: "Sign-in", paths: ["src/auth/", "src/auth/"])),
        ], model: { _ in nil }, now: t0)
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(board.item(number: 1)?.paths, ["src/auth/"])
        board.apply([.update(ref: "T-1", ItemPatch(paths: ["src/auth/", "tests/auth/"]))], model: { _ in nil }, now: t0)
        XCTAssertEqual(board.item(number: 1)?.paths, ["src/auth/", "tests/auth/"])
        // Read from what a model writes.
        let reply = SupervisorReply.parse("""
        Planned.
        ```board
        {"operations":[{"op":"add","ref":"a","title":"Billing","paths":["src/billing/"]}]}
        ```
        """)
        guard case .add(_, let patch)? = reply.operations.first else { return XCTFail("No task was read.") }
        XCTAssertEqual(patch.paths, ["src/billing/"])
    }

    func testSupervisorModeStartsWorkAsAutopilotDoes() {
        var settings = BoardSettings()
        XCTAssertFalse(settings.startsWorkByItself)
        settings.followsAdvice = true
        XCTAssertTrue(settings.startsWorkByItself)
        settings = BoardSettings(autopilot: true)
        XCTAssertTrue(settings.startsWorkByItself)
    }

    func testARunWhoseModelCouldNotAnswerIsNotHeldAgainstItsTask() {
        var board = Board(project: project, now: t0)
        board.settings.autopilot = true
        let item = board.add(title: "Work", details: "Do the work.", by: .person, now: t0)
        let chat = UUID()
        for minute in [0.0, 2.0] {
            board.beginRun(item.id, WorkRun(conversation: chat, model: model, modelLabel: "M", startedAt: minutes(minute)),
                           by: .autopilot, now: minutes(minute))
            board.endRun(in: chat, outcome: .failed, report: "Claude Code: You've reached your Fable limit",
                         ending: .itself, now: minutes(minute + 1))
        }
        XCTAssertTrue(Board.modelFailed(board.item(item.id)!.runs[0]))
        XCTAssertEqual(board.failuresInARow(of: board.item(item.id)!), 0)
        XCTAssertTrue(board.autopilotMayStart(board.item(item.id)!))
        // A run that failed on its own still counts.
        board.beginRun(item.id, WorkRun(conversation: chat, model: model, modelLabel: "M", startedAt: minutes(4)),
                       by: .autopilot, now: minutes(4))
        board.endRun(in: chat, outcome: .failed, report: "The build failed.", ending: .itself, now: minutes(5))
        XCTAssertEqual(board.failuresInARow(of: board.item(item.id)!), 1)
    }
}
