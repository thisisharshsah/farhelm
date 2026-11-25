import XCTest
@testable import CompanionBoard

final class SupervisorReplyTests: XCTestCase {
    func testWordsAndABoardBlockAreToldApart() {
        let text = """
        Here is the plan: three tasks, the API first.

        ```board
        {"goal": "Ship sign-in", "operations": [
          {"op": "add", "ref": "a", "title": "Write the API", "priority": "high", "estimate_tokens": "40k",
           "acceptance": ["Returns a token", "Rejects a bad password"], "model": "m2", "reason": "Needs care."},
          {"op": "add", "title": "Build the form", "depends_on": ["a"], "kind": "feature"},
          {"op": "move", "id": "T-4", "status": "In progress"},
          {"op": "note", "id": 4, "text": "Started by hand."},
          {"op": "budget", "tokens": "2m", "dollars": 25}
        ]}
        ```
        """
        let reply = SupervisorReply.parse(text)
        XCTAssertEqual(reply.prose, "Here is the plan: three tasks, the API first.")
        XCTAssertTrue(reply.problems.isEmpty)
        XCTAssertEqual(reply.operations, [
            .setGoal("Ship sign-in"),
            .add(label: "a", ItemPatch(title: "Write the API", acceptance: ["Returns a token", "Rejects a bad password"],
                                      priority: .high, estimateTokens: 40_000, model: "m2", reason: "Needs care.")),
            .add(label: nil, ItemPatch(title: "Build the form", kind: .feature, dependsOn: ["a"])),
            .move(ref: "T-4", .inProgress),
            .note(ref: "4", "Started by hand."),
            .setBudget(Budget(tokens: 2_000_000, dollars: 25)),
        ])
    }

    func testAReplyWithNoBlockIsAllWords() {
        let reply = SupervisorReply.parse("  Nothing needs to change on the board.  ")
        XCTAssertEqual(reply.prose, "Nothing needs to change on the board.")
        XCTAssertTrue(reply.operations.isEmpty)
        XCTAssertTrue(reply.problems.isEmpty)
    }

    func testJSONAsModelsWriteItIsStillRead() {
        // A json fence, a trailing comma, and words after the block.
        let fenced = "Plan below.\n```json\n{\"operations\": [{\"op\": \"remove\", \"id\": \"T-2\"},]}\n```\nSay if it fits."
        let first = SupervisorReply.parse(fenced)
        XCTAssertEqual(first.operations, [.remove(ref: "T-2")])
        XCTAssertEqual(first.prose, "Plan below.\n\nSay if it fits.")

        // No fence at all.
        let bare = "Done.\n{\"operations\": [{\"op\": \"assign\", \"task\": \"T-1\", \"model\": \"m1\", \"why\": \"Small.\"}]}"
        XCTAssertEqual(SupervisorReply.parse(bare).operations, [.assign(ref: "T-1", model: "m1", reason: "Small.")])
        XCTAssertEqual(SupervisorReply.parse(bare).prose, "Done.")

        // A bare list of tasks adds them.
        let tasks = "```board\n{\"tasks\": [{\"title\": \"One\"}, {\"title\": \"Two\", \"status\": \"backlog\"}]}\n```"
        XCTAssertEqual(SupervisorReply.parse(tasks).operations, [
            .add(label: nil, ItemPatch(title: "One")),
            .add(label: nil, ItemPatch(title: "Two", status: .backlog)),
        ])
    }

    func testANewGoalIsReadWithWhetherOpenTasksComeAlong() {
        let text = "On it.\n```board\n{\"operations\": [{\"op\": \"new_goal\", \"goal\": \"Add billing\", \"carry\": true},"
            + " {\"op\": \"new_goal\", \"goal\": \"Later\"}, {\"op\": \"goal\", \"goal\": \"Sharper words\"}]}\n```"
        XCTAssertEqual(SupervisorReply.parse(text).operations, [
            .newGoal("Add billing", bringUnfinished: true),
            .newGoal("Later", bringUnfinished: false),
            .setGoal("Sharper words"),
        ])
        XCTAssertEqual(Loose.bool("Yes"), true)
        XCTAssertEqual(Loose.bool(NSNumber(value: false)), false)
        XCTAssertNil(Loose.bool("perhaps"))
    }

    func testOtherCodeIsLeftForThePersonToRead() {
        let text = "Use this config:\n```json\n{\"name\": \"app\", \"port\": 8080}\n```\nThat is all."
        let reply = SupervisorReply.parse(text)
        XCTAssertTrue(reply.operations.isEmpty)
        XCTAssertEqual(reply.prose, text)

        let swift = "Like so:\n```swift\nlet options = [\n{ print(1) }\n]\n```"
        XCTAssertEqual(SupervisorReply.parse(swift).prose, swift)
    }

    func testABoardBlockThatCannotBeReadIsSaidAndChangesNothing() {
        let reply = SupervisorReply.parse("Plan.\n```board\n{\"operations\": [{\"op\": \"add\", \"title\": \n```")
        XCTAssertTrue(reply.operations.isEmpty)
        XCTAssertEqual(reply.problems.count, 1)
    }

    func testWhileItArrivesTheBlockIsNeverShown() {
        let full = "The plan is ready.\n\n```board\n{\"operations\": []}\n```"
        var shown = ""
        for end in full.indices {
            let visible = SupervisorReply.visible(String(full[...end]))
            // What is shown only ever grows, and never includes the block.
            XCTAssertTrue(visible.hasPrefix(shown) || shown.hasPrefix(visible), "\(visible) | \(shown)")
            XCTAssertFalse(visible.contains("```"), visible)
            XCTAssertFalse(visible.contains("operations"), visible)
            if visible.count > shown.count { shown = visible }
        }
        XCTAssertEqual(shown.trimmingCharacters(in: .whitespacesAndNewlines), "The plan is ready.")
    }

    func testOrdinaryCodeIsShownWhileItArrives() {
        let text = "Run this:\n```sh\nswift build\n```\nThen tell me."
        XCTAssertEqual(SupervisorReply.visible(text), text)
        // The first characters of a fence are held back until it is plain
        // which kind it is.
        XCTAssertEqual(SupervisorReply.visible("Run this:\n``"), "Run this:\n")
        XCTAssertEqual(SupervisorReply.visible("Run this:\n```s"), "Run this:\n```s")
    }

    func testARecommendationIsReadFromItsFirstLine() {
        let words = ["ALLOW", "ALWAYS", "DENY"]
        XCTAssertEqual(Recommendation.parse("ALLOW\nIt only lists files in the project.", among: words),
                       Recommendation(option: 0, reason: "It only lists files in the project."))
        XCTAssertEqual(Recommendation.parse("**Recommendation: deny.** It deletes a folder outside the project.", among: words),
                       Recommendation(option: 2, reason: "It deletes a folder outside the project."))
        XCTAssertEqual(Recommendation.parse("Always allow: git status only reads.", among: words)?.option, 1)
        XCTAssertEqual(Recommendation.parse("Always allow: git status only reads.", among: words)?.reason,
                       "git status only reads.")
        // A question's answers are picked by their number.
        XCTAssertEqual(Recommendation.parse("Option 2. It is easier to undo.", among: ["1", "2", "3"]),
                       Recommendation(option: 1, reason: "It is easier to undo."))
        XCTAssertNil(Recommendation.parse("4", among: ["1", "2", "3"]))
        XCTAssertNil(Recommendation.parse("NONE\nOnly you know which you prefer.", among: ["1", "2"]))
        XCTAssertNil(Recommendation.parse("It depends on what you want.", among: words))
        XCTAssertNil(Recommendation.parse("", among: words))
    }

    func testAnAnswerThatLeavesTheChoiceToThePersonKeepsItsReason() {
        let words = ["ALLOW", "ALWAYS", "DENY"]
        XCTAssertEqual(Recommendation.read("ASK\nIt would push to GitHub, which the task does not call for.", among: words),
                       .left("It would push to GitHub, which the task does not call for."))
        XCTAssertEqual(Recommendation.read("NONE. Only you know which you prefer.", among: ["1", "2"]),
                       .left("Only you know which you prefer."))
        XCTAssertEqual(Recommendation.read("ALLOW\nIt only builds.", among: words),
                       .pick(Recommendation(option: 0, reason: "It only builds.")))
        XCTAssertNil(Recommendation.read("It depends.", among: words))
        // Read for its pick alone, leaving the choice is no pick.
        XCTAssertNil(Recommendation.parse("ASK\nNot sure.", among: words))
    }

    func testNumbersAreReadAsModelsWriteThem() {
        XCTAssertEqual(Loose.int("20k"), 20_000)
        XCTAssertEqual(Loose.int("1.5M tokens"), 1_500_000)
        XCTAssertEqual(Loose.int("12,500"), 12_500)
        XCTAssertEqual(Loose.int(NSNumber(value: 300.4)), 300)
        XCTAssertNil(Loose.int("a lot"))
        XCTAssertEqual(Loose.double("$25"), 25)
        XCTAssertEqual(Loose.list("- one\n- two; three") ?? [], ["one", "two", "three"])
    }

    func testAStopIsReadUnderItsOtherNamesToo() {
        let reply = SupervisorReply.parse("""
        T-3 keeps reading the same file.
        ```board
        {"operations":[{"op":"stop","id":"T-3","reason":"Loops on reads."},{"op":"cancel","id":"T-4"},{"op":"halt","task":"5","why":"Over budget."},{"op":"stop"}]}
        ```
        """)
        XCTAssertEqual(reply.prose, "T-3 keeps reading the same file.")
        XCTAssertEqual(reply.operations, [.stop(ref: "T-3", reason: "Loops on reads."), .stop(ref: "T-4", reason: ""),
                                          .stop(ref: "5", reason: "Over budget.")])
    }

    func testApproveAndDeleteAreTheirOwnOps() {
        let reply = SupervisorReply.parse("""
        T-3 passed its checks; T-5 is the junk you named.
        ```board
        {"operations":[{"op":"approve","id":"T-3"},{"op":"accept","task":"4"},{"op":"approve"},{"op":"delete","id":"T-5","reason":"Junk, as you said."},{"op":"trash","id":"T-6"},{"op":"delete"},{"op":"remove","id":"T-7"}]}
        ```
        """)
        XCTAssertEqual(reply.operations, [.approve(ref: "T-3"), .approve(ref: "4"),
                                          .delete(ref: "T-5", reason: "Junk, as you said."),
                                          .delete(ref: "T-6", reason: ""), .remove(ref: "T-7")])
    }
}
