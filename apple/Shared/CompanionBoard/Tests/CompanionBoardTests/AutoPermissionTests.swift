import XCTest
@testable import CompanionBoard

/// A task's copy, with commands run at its top.
private let taskCopy = Delegation.Place(project: "/Users/me/proj", directory: "/Users/me/proj", home: "/Users/me")

private let on = BoardSettings(auto: true)

private func decide(_ what: Delegation.Step.What, settings: BoardSettings = on,
                    by worker: AutoPermission.Worker? = .taskRun) -> AutoPermission.Decision {
    AutoPermission.decide(Delegation.Step(what), in: taskCopy, settings: settings, by: worker)
}

final class AutoPermissionTests: XCTestCase {
    func testANewBoardStartsWithAutoOff() throws {
        XCTAssertFalse(BoardSettings().auto)
        // A board saved before Auto existed reads with it off.
        let saved = try JSONDecoder().decode(BoardSettings.self, from: Data("{\"autopilot\":true}".utf8))
        XCTAssertFalse(saved.auto)
        XCTAssertEqual(decide(.command("swift build"), settings: BoardSettings()), .notCovered)
    }

    func testAutoIsKeptWithTheBoard() throws {
        let data = try JSONEncoder().encode(on)
        XCTAssertTrue(try JSONDecoder().decode(BoardSettings.self, from: data).auto)
    }

    func testTurningAutoOffMakesThemAskAgain() {
        var settings = on
        XCTAssertEqual(decide(.command("swift test"), settings: settings), .runs)
        settings.auto = false
        XCTAssertEqual(decide(.command("swift test"), settings: settings), .notCovered)
    }

    func testWithAutoOnEveryWorkerEditsRunsBuildsTestsAndCommits() {
        let work: [Delegation.Step.What] = [
            .file("/Users/me/proj/Sources/App.swift"),
            .command("swift build"), .command("bash apple/build.sh check"), .command("swift test"),
            .command("npm test"), .command("cd apple && bash build.sh"), .command("git status"),
            .command("git add -A && git commit -m 'T-1: fix'"), .command("git checkout -b task/t-1-fix"),
            .command("git merge task/t-2-other")
        ]
        for worker in AutoPermission.Worker.allCases {
            for what in work {
                XCTAssertEqual(decide(what, by: worker), .runs, "\(worker) \(what)")
            }
        }
    }

    func testAChatInNoProjectIsNotCovered() {
        XCTAssertEqual(decide(.command("swift build"), by: nil), .notCovered)
    }

    func testAutoReachesNoFurtherThanTheProject() {
        XCTAssertEqual(decide(.command("sudo ls")), .notCovered)
        XCTAssertEqual(decide(.app), .notCovered)
        XCTAssertEqual(decide(.file("/Users/me/other/x.txt")), .notCovered)
    }

    func testMergingIntoMainStillAsks() {
        for text in ["git checkout main", "git switch master", "git merge companion/main",
                     "git push . companion/main:main", "git fetch . companion/main:main", "git branch -f main HEAD",
                     "git update-ref refs/heads/main HEAD", "gh pr merge 12"] {
            let decision = decide(.command(text))
            XCTAssertTrue(decision == .asks(.mergeIntoMain) || decision == .asks(.push), text)
        }
        XCTAssertEqual(decide(.command("git checkout main")), .asks(.mergeIntoMain))
    }

    func testPushingStillAsks() {
        for text in ["git push", "git push origin task/t-1", "git -C apple push --force", "bash -c 'git push'",
                     "swift test && git push origin HEAD"] {
            XCTAssertEqual(decide(.command(text)), .asks(.push), text)
        }
    }

    func testDeletingOutsideTheBoardsCleanupStillAsks() {
        for text in ["rm notes.txt", "rm -rf Sources", "git rm old.swift", "git clean -fd", "find . -name '*.o' -delete",
                     "rm -rf ~/x", "rm $FILE"] {
            XCTAssertEqual(decide(.command(text)), .asks(.deletes), text)
        }
        XCTAssertEqual(decide(.command("rm /tmp/scratch.txt")), .runs)
        XCTAssertEqual(decide(.command("git rm --cached x")), .runs)
        // Taking a task off the board is asked about; other changes are not.
        XCTAssertEqual(AutoPermission.decide(.delete(ref: "T-1", reason: ""), settings: on), .asks(.deletes))
        XCTAssertEqual(AutoPermission.decide(.remove(ref: "T-1"), settings: on), .asks(.deletes))
        XCTAssertEqual(AutoPermission.decide(.note(ref: "T-1", "x"), settings: on), .runs)
    }

    func testKeysAndCredentialsStillAsk() {
        for text in ["cat .env", "security find-generic-password -s x", "export OPENAI_API_KEY=x && npm test",
                     "cp ~/.ssh/id_ed25519 .", "ssh-keygen -t ed25519", "grep token .npmrc"] {
            XCTAssertEqual(decide(.command(text)), .asks(.keys), text)
        }
        XCTAssertEqual(decide(.file("/Users/me/proj/.env.local")), .asks(.keys))
        XCTAssertEqual(AutoPermission.decide(Delegation.Step(.look, namesKeys: true), in: taskCopy, settings: on,
                                             by: .supervisor), .asks(.keys))
    }

    func testTheFourAreOneListWithASentenceEach() {
        XCTAssertEqual(AutoPermission.alwaysAsks, [.mergeIntoMain, .push, .deletes, .keys])
        for kept in AutoPermission.alwaysAsks {
            XCTAssertFalse(kept.sentence.isEmpty)
            XCTAssertFalse(kept.sentence.contains("\u{2014}"))
        }
    }
}