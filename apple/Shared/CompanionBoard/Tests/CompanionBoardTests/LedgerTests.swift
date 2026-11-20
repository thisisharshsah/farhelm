import XCTest
@testable import CompanionBoard

private let day = Date(timeIntervalSince1970: 1_800_000_000)

private func entry(_ tokens: Int, chat: UUID? = nil, item: UUID? = nil, model: String = "sonnet",
                   purpose: String = "Agent", cost: Double = 0, exact: Bool = true, after hours: Double = 0) -> UsageEntry {
    UsageEntry(date: day.addingTimeInterval(hours * 3_600), conversation: chat, workItem: item, engine: "anthropic",
               model: model, purpose: purpose, input: tokens / 2, output: tokens - tokens / 2, cost: cost, exact: exact)
}

final class LedgerTests: XCTestCase {
    func testEveryTokenIsCountedOnceUnderEachHeading() {
        let chatA = UUID(), chatB = UUID(), task = UUID()
        let ledger = Ledger([
            entry(1_000, chat: chatA, item: task, cost: 0.10),
            entry(500, chat: chatA, purpose: "Supervisor", cost: 0.05, exact: false),
            entry(2_000, chat: chatB, model: "haiku", cost: 0.02, after: 30),
        ])
        XCTAssertEqual(ledger.total.tokens, 3_500)
        XCTAssertEqual(ledger.total.requests, 3)
        XCTAssertEqual(ledger.total.estimated, 1)
        XCTAssertEqual(ledger.total.cost, 0.17, accuracy: 1e-9)
        XCTAssertEqual(ledger.byConversation[chatA]?.tokens, 1_500)
        XCTAssertEqual(ledger.byConversation[chatB]?.tokens, 2_000)
        XCTAssertEqual(ledger.byWorkItem[task]?.tokens, 1_000)
        XCTAssertEqual(ledger.total(of: [chatA, chatB]).tokens, 3_500)
        XCTAssertEqual(ledger.byModel { _, model in model }.map(\.name), ["haiku", "sonnet"])
        XCTAssertEqual(ledger.byPurpose.map(\.name), ["Agent", "Supervisor"])
        XCTAssertEqual(ledger.byPurpose.reduce(0) { $0 + $1.total.tokens }, ledger.total.tokens)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(ledger.byDay(calendar: calendar).map(\.total.tokens), [1_500, 2_000])
        XCTAssertEqual(ledger.overheadShare(purposes: ["Supervisor"]), 500.0 / 3_500.0, accuracy: 1e-9)
    }

    func testATaskCountsItsRunsChatsButNothingFiledUnderAnotherTask() {
        let chat = UUID()
        var item = WorkItem(number: 1, title: "Work", createdAt: day)
        item.runs = [WorkRun(conversation: chat, model: ModelChoice(engine: "anthropic", model: "sonnet"),
                             modelLabel: "Sonnet", startedAt: day)]
        let other = UUID()
        let ledger = Ledger([
            entry(1_000, chat: chat, item: item.id),
            // Made in the run's chat before usage was filed by task.
            entry(400, chat: chat),
            // The same chat, but filed under another task.
            entry(900, chat: chat, item: other),
            entry(700, chat: UUID(), item: item.id),
        ])
        XCTAssertEqual(ledger.total(of: item).tokens, 2_100)
    }

    func testABudgetIsJudgedByTheLimitClosestToBeingUsedUp() {
        var spent = UsageTotal()
        spent.add(entry(400_000, cost: 9.5))
        XCTAssertEqual(Budget().state(spent: spent), .none)
        XCTAssertEqual(Budget(tokens: 1_000_000).state(spent: spent), .within(0.4))
        XCTAssertEqual(Budget(tokens: 1_000_000, dollars: 10).state(spent: spent), .near(0.95))
        XCTAssertTrue(Budget(tokens: 300_000).state(spent: spent).isOver)
        XCTAssertTrue(Budget(tokens: 500_000).fits(estimate: 100_000, spent: spent))
        XCTAssertFalse(Budget(tokens: 500_000).fits(estimate: 100_001, spent: spent))
        XCTAssertTrue(Budget(dollars: 1).fits(estimate: 10_000_000, spent: spent))
    }
}

final class ModelRoutingTests: XCTestCase {
    private let local = ModelProfile(id: "m1", choice: ModelChoice(engine: "ollama", model: "qwen3-coder:30b"),
                                     name: "Ollama · qwen3-coder:30b", place: .local, window: 32_000,
                                     tier: .balanced, tools: false)
    private let haiku = ModelProfile(id: "m2", choice: ModelChoice(engine: "anthropic", model: "claude-haiku-5-5"),
                                     name: "Claude · Haiku 5.5", place: .api, inputPrice: 0.1, outputPrice: 0.5,
                                     window: 200_000, tier: .light, tools: true)
    private let opus = ModelProfile(id: "m3", choice: ModelChoice(engine: "anthropic", model: "claude-opus-5-5"),
                                    name: "Claude · Opus 5.5", place: .api, inputPrice: 4, outputPrice: 20,
                                    window: 200_000, tier: .strong, tools: true)

    private func task(_ kind: WorkKind, estimate: Int? = nil, priority: WorkPriority = .medium) -> WorkItem {
        WorkItem(number: 1, title: "Work", priority: priority, kind: kind, estimateTokens: estimate,
                 createdAt: Date(timeIntervalSince1970: 0))
    }

    func testModelsAreSizedByTheirNames() {
        XCTAssertEqual(ModelRouting.tier(ofModelNamed: "claude-haiku-5-5"), .light)
        XCTAssertEqual(ModelRouting.tier(ofModelNamed: "gpt-4o-mini"), .light)
        XCTAssertEqual(ModelRouting.tier(ofModelNamed: "claude-sonnet-5-5"), .balanced)
        XCTAssertEqual(ModelRouting.tier(ofModelNamed: "qwen3-coder:30b"), .balanced)
        XCTAssertEqual(ModelRouting.tier(ofModelNamed: "claude-opus-5-5"), .strong)
        XCTAssertEqual(ModelRouting.tier(ofModelNamed: "gemini-2.5-pro"), .strong)
        XCTAssertEqual(ModelRouting.tier(ofModelNamed: "gemini-2.5-flash"), .light)
        XCTAssertEqual(ModelRouting.tier(ofModelNamed: "llama3.1:8b"), .light)
        XCTAssertEqual(ModelRouting.tier(ofModelNamed: "gpt-oss-120b"), .strong)
    }

    func testTheLeastCostlyModelThatIsStrongEnoughIsChosen() {
        let all = [local, haiku, opus]
        // Small work: the free local model is strong enough.
        XCTAssertEqual(ModelRouting.suggest(for: task(.docs, estimate: 8_000), among: all)?.profile.id, "m1")
        // Everyday work: still the local model, which is balanced and free.
        XCTAssertEqual(ModelRouting.suggest(for: task(.feature, estimate: 30_000), among: all)?.profile.id, "m1")
        // Wide or delicate work wants the strongest.
        XCTAssertEqual(ModelRouting.suggest(for: task(.design), among: all)?.profile.id, "m3")
        // Too big for the local window: on to one that can hold it.
        XCTAssertEqual(ModelRouting.suggest(for: task(.docs, estimate: 100_000), among: all)?.profile.id, "m2")
    }

    func testWithNothingStrongEnoughTheStrongestIsChosenAndSaid() {
        let found = ModelRouting.suggest(for: task(.research), among: [local, haiku])
        XCTAssertEqual(found?.profile.id, "m1")
        XCTAssertTrue(found?.reason.contains("strongest") ?? false)
        XCTAssertNil(ModelRouting.suggest(for: task(.docs), among: []))
    }
}
