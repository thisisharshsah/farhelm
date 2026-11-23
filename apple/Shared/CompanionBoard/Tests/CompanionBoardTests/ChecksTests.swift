import XCTest
@testable import CompanionBoard

private let project = UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func data(_ text: String) -> Data { Data(text.utf8) }

private func result(_ name: String, _ outcome: CheckResult.Outcome, output: String = "",
                    problems: [String] = []) -> CheckResult {
    CheckResult(name: name, command: "make \(name.lowercased())", outcome: outcome,
                exitCode: outcome == .failed ? 1 : (outcome == .passed ? 0 : nil), seconds: 192,
                output: output, problems: problems)
}

final class ChecksTests: XCTestCase {
    func testAChecksFileIsReadWithWhatItLeavesOutFilledIn() throws {
        let checks = try Checks.read(data("""
        {
          "about": "Read by people, passed over by the app.",
          "checks": [
            { "run": "  swift test  " },
            { "name": "App builds", "run": "bash build.sh check", "when": "./apple/", "timeout": 99999 },
            { "name": "Lint", "run": "make lint", "when": ["Sources", "Sources/", "Tests"], "timeout": 1 }
          ]
        }
        """))
        XCTAssertEqual(checks.count, 3)
        XCTAssertEqual(checks[0], Check(name: "swift test", run: "swift test", when: [], timeout: Check.defaultTimeout))
        XCTAssertEqual(checks[1].when, ["apple/"])
        XCTAssertEqual(checks[1].timeout, Check.timeouts.upperBound)
        // The same folder written twice is kept once.
        XCTAssertEqual(checks[2].when, ["Sources", "Tests"])
        XCTAssertEqual(checks[2].timeout, Check.timeouts.lowerBound)
    }

    func testAListOnItsOwnIsAChecksFileToo() throws {
        XCTAssertEqual(try Checks.read(data(#"[{"run": "make test"}]"#)).map(\.run), ["make test"])
    }

    func testAChecksFileThatCannotBeReadSaysWhereAndWhy() {
        func reason(_ text: String) -> String {
            do {
                _ = try Checks.read(data(text))
                return ""
            } catch let unreadable as Checks.Unreadable {
                return unreadable.reason
            } catch {
                return "\(error)"
            }
        }
        XCTAssertEqual(reason(""), "it is empty")
        XCTAssertEqual(reason("{ checks: }"), "it is not valid JSON")
        XCTAssertEqual(reason(#"{"tests": []}"#), "checks is missing")
        XCTAssertEqual(reason(#"{"checks": [{"run": "make"}, {"name": "No command"}]}"#), "checks[1].run is missing")
        XCTAssertEqual(reason(#"{"checks": [{"run": "make", "timeout": "15m"}]}"#), "checks[0].timeout has the wrong type")
        XCTAssertEqual(reason(#"{"checks": [{"run": "   "}]}"#), "checks[0] has no command in \"run\"")
    }

    func testACheckRunsForWorkThatChangedSomethingUnderItsPaths() {
        let board = Check(name: "Board", run: "swift test --package-path Shared/Board", when: ["Shared/Board"])
        let app = Check(name: "App", run: "bash build.sh check", when: ["Sources/", "Package.swift"])
        let all = Check(name: "Everything", run: "make check")
        let checks = [board, app, all]
        XCTAssertEqual(Checks.due(checks, changed: ["Shared/Board/Sources/Rules.swift"]).map(\.name),
                       ["Board", "Everything"])
        XCTAssertEqual(Checks.due(checks, changed: ["Package.swift", "README.md"]).map(\.name), ["App", "Everything"])
        // A Mac's disk does not tell case apart, and neither do the paths.
        XCTAssertEqual(Checks.due(checks, changed: ["shared/board/Tests/RulesTests.swift"]).map(\.name),
                       ["Board", "Everything"])
        // "Shared/Boards" is another folder than "Shared/Board".
        XCTAssertEqual(Checks.due(checks, changed: ["Shared/Boards/x.swift"]).map(\.name), ["Everything"])
        // Work that changed nothing has nothing to check.
        XCTAssertEqual(Checks.due(checks, changed: []), [])
    }

    func testOnlyWorkWhoseChecksAllPassedIsLetThroughWithoutAPerson() {
        XCTAssertTrue(Checks.letThrough(nil))
        XCTAssertTrue(Checks.letThrough([]))
        XCTAssertTrue(Checks.letThrough([result("Tests", .passed)]))
        XCTAssertFalse(Checks.letThrough([result("Tests", .passed), result("Build", .failed)]))
        XCTAssertFalse(Checks.letThrough([result("Build", .timedOut)]))
        XCTAssertFalse(Checks.letThrough([result(Checks.file, .notRun)]))
    }

    func testTheReviewIsToldWhatFailedWhereAndWhatItPrinted() {
        let text = Checks.evidence([
            result("Tests", .passed),
            result("Build", .failed, output: "Compiling\nerror: build stopped\n",
                   problems: ["Sources/App.swift:12:5: error: cannot find 'x' in scope"]),
        ])
        XCTAssertTrue(text.contains("- [passed] Tests (`make tests`): passed in 3 min 12 s"), text)
        XCTAssertTrue(text.contains("- [FAILED] Build (`make build`): failed (exit 1) after 3 min 12 s"), text)
        XCTAssertTrue(text.contains("    Sources/App.swift:12:5: error: cannot find 'x' in scope"), text)
        XCTAssertTrue(text.contains("    error: build stopped"), text)
        XCTAssertTrue(Checks.evidence(nil).contains(Checks.file))
        XCTAssertEqual(Checks.evidence([]), "None of the project's checks cover what this work changed.")
    }

    func testWhatFailedIsSummedUpForTheRunThatTakesTheTaskUpAgain() {
        XCTAssertEqual(Checks.digest([result("Tests", .passed)]), "")
        let digest = Checks.digest([
            result("Tests", .passed),
            result("Build", .failed, output: "a\nb\n\nlast words\n", problems: ["App.swift:3: error: nope"]),
            result("Lint", .failed, output: "one\ntwo\n"),
        ])
        XCTAssertEqual(digest, """
        Build (`make build`) failed (exit 1) after 3 min 12 s: App.swift:3: error: nope
        Lint (`make lint`) failed (exit 1) after 3 min 12 s: one / two
        """)
        XCTAssertEqual(Checks.digest([result("Build", .failed, output: String(repeating: "x", count: 5_000))],
                                     limit: 200).count, 200)
    }

    func testTimesReadTheWayAPersonSaysThem() {
        XCTAssertEqual(Checks.duration(41.4), "41 s")
        XCTAssertEqual(Checks.duration(180), "3 min")
        XCTAssertEqual(Checks.duration(192), "3 min 12 s")
        XCTAssertEqual(Checks.duration(3_900), "1 h 5 min")
    }

    func testWhatTheChecksFoundIsKeptWithTheRunTheyChecked() {
        var board = Board(project: project, now: t0)
        let item = board.add(title: "Work", by: .person, now: t0)
        let run = WorkRun(conversation: UUID(), model: ModelChoice(engine: "anthropic", model: "sonnet"),
                          modelLabel: "Sonnet", startedAt: t0)
        board.beginRun(item.id, run, by: .person, now: t0)
        XCTAssertFalse(board.recordChecks(item.id, run: UUID(), [], now: t0))
        XCTAssertTrue(board.recordChecks(item.id, run: run.id, [result("Tests", .passed), result("Build", .failed)],
                                         now: t0))
        XCTAssertEqual(board.item(item.id)?.runs.last?.checks?.map(\.outcome), [.passed, .failed])
        XCTAssertEqual(board.activity.last?.text, "T-1 did not pass Build")
        // A run kept before checks were, and one kept with them, both load.
        let saved = try? JSONEncoder().encode(board.item(item.id)?.runs.last)
        let loaded = saved.flatMap { try? JSONDecoder().decode(WorkRun.self, from: $0) }
        XCTAssertEqual(loaded?.checks?.count, 2)
        var plain = run
        plain.checks = nil
        let old = try? JSONEncoder().encode(plain)
        XCTAssertNotNil(old.flatMap { try? JSONDecoder().decode(WorkRun.self, from: $0) })
    }

    func testAPathInACopyIsReadFromTheProjectsFolder() {
        let copy = WorkingCopy(folder: "/copies/t-1", subfolder: "apple", branch: "task/t-1", base: "main",
                               baseCommit: "", madeAt: t0)
        XCTAssertEqual(copy.fromProject("apple/Sources/App.swift"), "Sources/App.swift")
        XCTAssertEqual(copy.fromProject("README.md"), "README.md")
        XCTAssertEqual(copy.fromProject("applesauce/x"), "applesauce/x")
    }

    func testAStarterFileReadsBackAsTheChecksItWrites() throws {
        XCTAssertEqual(try Checks.read(data(Checks.starter(build: "swift build"))),
                       [Check(name: "Build", run: "swift build")])
        XCTAssertEqual(try Checks.read(data(Checks.starter(build: nil))), [])
        // A command with quotes and slashes is written so it reads back the same.
        let command = #"echo "a/b" \ done"#
        XCTAssertEqual(try Checks.read(data(Checks.starter(build: command))).first?.run, command)
    }
}

final class ReviewDiffTests: XCTestCase {
    private func file(_ path: String, lines: Int) -> String {
        var text = "diff --git a/\(path) b/\(path)\nindex 1111111..2222222 100644\n--- a/\(path)\n+++ b/\(path)\n@@ -1,1 +1,\(lines) @@\n"
        for number in 0..<lines { text += "+line \(number) of \(path)\n" }
        return text
    }

    func testADiffThatFitsIsGivenAsItIs() {
        let diff = file("Sources/A.swift", lines: 3) + file("Sources/B.swift", lines: 2)
        XCTAssertEqual(ReviewDiff.fit(diff, limit: 10_000), ReviewDiff.Fitted(text: diff, cut: []))
    }

    func testEveryFileIsNamedAndSmallOnesAreShownWholeBeforeALargeOne() {
        let small = file("Sources/Small.swift", lines: 5)
        let large = file("Sources/Large.swift", lines: 400)
        let lock = file("Package.resolved", lines: 60)
        let fitted = ReviewDiff.fit(large + lock + small, limit: 3_000)
        XCTAssertLessThanOrEqual(fitted.text.count, 3_000)
        // Shown whole.
        XCTAssertTrue(fitted.text.contains(small))
        // Named, with how much changed, and as much of it as fits.
        XCTAssertTrue(fitted.text.contains("diff --git a/Sources/Large.swift b/Sources/Large.swift"))
        XCTAssertTrue(fitted.text.contains("+line 0 of Sources/Large.swift"))
        XCTAssertTrue(fitted.text.contains("[the rest of its changes are left out]"))
        // What tools write comes last: only named.
        XCTAssertTrue(fitted.text.contains("diff --git a/Package.resolved b/Package.resolved\n[its changes are left out: +60 -0 lines]"))
        XCTAssertEqual(fitted.cut, ["Sources/Large.swift", "Package.resolved"])
        // The files keep the diff's order.
        let order = ["Large.swift", "Package.resolved", "Small.swift"].compactMap { fitted.text.range(of: $0)?.lowerBound }
        XCTAssertEqual(order, order.sorted())
    }

    func testAFilesPathIsFoundForNewDeletedAndBinaryFiles() {
        let parts = ReviewDiff.parts(of: """
        warning: something the shell said
        diff --git a/New File.txt b/New File.txt
        new file mode 100644
        --- /dev/null
        +++ b/New File.txt\t
        @@ -0,0 +1 @@
        +hello
        diff --git a/Old.swift b/Old.swift
        deleted file mode 100644
        --- a/Old.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git a/logo.png b/logo.png
        Binary files a/logo.png and b/logo.png differ

        """)
        XCTAssertEqual(parts.map(\.path), ["New File.txt", "Old.swift", "logo.png"])
        XCTAssertEqual(parts.map(\.added), [1, 0, 0])
        XCTAssertEqual(parts.map(\.removed), [0, 1, 0])
    }

    func testLockFilesAndMinifiedFilesAreToldApart() {
        XCTAssertTrue(ReviewDiff.isLowSignal("web/pnpm-lock.yaml"))
        XCTAssertTrue(ReviewDiff.isLowSignal("Cargo.lock"))
        XCTAssertTrue(ReviewDiff.isLowSignal("static/app.min.js"))
        XCTAssertFalse(ReviewDiff.isLowSignal("Sources/Lock.swift"))
    }
}
