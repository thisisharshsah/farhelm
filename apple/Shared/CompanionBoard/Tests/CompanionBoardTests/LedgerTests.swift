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

    /// Three subscriptions, each free and as strong as the others.
    private func account(_ id: String, _ tool: String) -> ModelProfile {
        ModelProfile(id: id, choice: ModelChoice(engine: "subscription", tool: tool, model: ""), name: tool,
                     place: .account, window: 200_000, tier: .strong, tools: true, group: "subscription|" + tool)
    }

    func testWorkIsSpreadAcrossModelsThatAreEquallyGoodForIt() {
        let claude = account("m1", "claude"), codex = account("m2", "codex"), gemini = account("m3", "gemini")
        let all = [claude, codex, gemini]
        // Nothing given out yet: the first, by name.
        XCTAssertEqual(ModelRouting.suggest(for: task(.design), among: all)?.profile.id, "m1")
        // Then the one with the least work.
        XCTAssertEqual(ModelRouting.suggest(for: task(.design), among: all,
                                            busy: [claude.group: 2, codex.group: 1])?.profile.id, "m3")
        XCTAssertEqual(ModelRouting.suggest(for: task(.design), among: all,
                                            busy: [claude.group: 1, gemini.group: 1])?.profile.id, "m2")
        // Spreading never outweighs cost: a cheaper model takes small work however busy it is.
        XCTAssertEqual(ModelRouting.suggest(for: task(.docs, estimate: 8_000), among: [local, haiku],
                                            busy: [local.group: 9])?.profile.id, "m1")
    }

    func testAModelWhosePriceIsNotSetIsNotTakenForFree() {
        let unpriced = ModelProfile(id: "m9", choice: ModelChoice(engine: "openai", model: "a-model"), name: "A model",
                                    place: .api, window: 200_000, tier: .strong, tools: true)
        XCTAssertFalse(unpriced.priceKnown)
        // A subscription, as strong and known to cost nothing per token, comes first.
        XCTAssertEqual(ModelRouting.suggest(for: task(.design), among: [unpriced, account("m1", "claude")])?.profile.id,
                       "m1")
        // Between two billed models, the one with a price comes first.
        XCTAssertEqual(ModelRouting.suggest(for: task(.design), among: [unpriced, opus])?.profile.id, "m3")
        // On this Mac with a price set (an engine passing requests on), its price is said.
        let passed = ModelProfile(id: "m8", choice: ModelChoice(engine: "farhelm", model: "claude-sonnet-5-5"),
                                  name: "Farhelm · Claude Sonnet", place: .local, inputPrice: 2, outputPrice: 10,
                                  window: 200_000, tier: .balanced, tools: true)
        XCTAssertTrue(passed.line.contains("$2 in, $10 out"))
        XCTAssertTrue(local.line.contains("free"))
    }

    func testTheModelThatDidBetterOnTheBoardComesFirst() {
        let claude = account("m1", "claude"), codex = account("m2", "codex")
        let poor = TrackRecord(runs: 4, approved: 1, sentBack: 3)
        let good = TrackRecord(runs: 3, approved: 3)
        XCTAssertEqual(poor.standing, 1)
        XCTAssertEqual(good.standing, 4)
        XCTAssertEqual(TrackRecord(runs: 2, approved: 2).standing, 2)
        // A better record beats the name order, and comes before spreading the work.
        XCTAssertEqual(ModelRouting.suggest(for: task(.design), among: [claude, codex],
                                            busy: [codex.group: 2],
                                            records: [claude.choice.key: poor, codex.choice.key: good])?.profile.id,
                       "m2")
        // Too few runs to tell: neither favored nor held back.
        XCTAssertEqual(ModelRouting.suggest(for: task(.design), among: [claude, codex],
                                            records: [codex.choice.key: TrackRecord(runs: 1, approved: 1)])?.profile.id,
                       "m1")
    }

    func testRecordsAreKeptFromFinishedRunsThatSaySomethingAboutTheModel() {
        let start = Date(timeIntervalSince1970: 0)
        let a = ModelChoice(engine: "subscription", tool: "claude", model: "")
        let b = ModelChoice(engine: "subscription", tool: "codex", model: "")
        func ran(_ model: ModelChoice, _ outcome: WorkRun.Outcome, _ verdict: Review.Verdict? = nil,
                 ending: WorkRun.Ending? = .itself, report: String? = nil) -> WorkRun {
            WorkRun(conversation: UUID(), model: model, modelLabel: "", startedAt: start, endedAt: start,
                    outcome: outcome, report: report,
                    review: verdict.map { Review(verdict: $0, notes: "", by: "M", date: start) }, ending: ending)
        }
        let item = WorkItem(number: 1, title: "Work", runs: [
            ran(a, .succeeded, .approved),
            ran(a, .succeeded, .changesRequested),
            ran(b, .failed),
            // Out of its limit: nothing about the work.
            ran(b, .failed, report: "Claude Code: You've hit your limit · resets 3pm"),
            // Stopped by a person, and one still running: not counted.
            ran(b, .stopped, ending: .person),
            ran(a, .running, ending: nil),
        ], createdAt: start)
        let records = ModelRouting.records(of: [item])
        XCTAssertEqual(records[a.key], TrackRecord(runs: 2, approved: 1, sentBack: 1, failed: 0))
        XCTAssertEqual(records[b.key], TrackRecord(runs: 1, approved: 0, sentBack: 0, failed: 1))
    }

    func testOpenTasksAreCountedByWhatSharesALimit() {
        let sonnet = ModelProfile(id: "m1", choice: ModelChoice(engine: "subscription", tool: "claude", model: "sonnet"),
                                  name: "Claude Code · Sonnet", place: .account, window: 200_000, tier: .balanced,
                                  tools: true, group: "subscription|claude")
        let opusCode = ModelProfile(id: "m2", choice: ModelChoice(engine: "subscription", tool: "claude", model: "opus"),
                                    name: "Claude Code · Opus", place: .account, window: 200_000, tier: .strong,
                                    tools: true, group: "subscription|claude")
        let start = Date(timeIntervalSince1970: 0)
        func given(_ number: Int, _ model: ModelChoice, _ status: WorkStatus) -> WorkItem {
            WorkItem(number: number, title: "Work", status: status,
                     assignment: Assignment(model: model, label: "", reason: "", source: .rule, accepted: false,
                                            date: start),
                     createdAt: start)
        }
        let items = [given(1, sonnet.choice, .todo), given(2, opusCode.choice, .inProgress),
                     given(3, sonnet.choice, .done), given(4, ModelChoice(engine: "gone", model: "x"), .todo)]
        // Two open tasks on one plan; done work and models no longer set up are not counted.
        XCTAssertEqual(ModelRouting.busy(of: [sonnet, opusCode], items: items), ["subscription|claude": 2])
        // A model with no group of its own named is a group by itself.
        XCTAssertEqual(local.group, local.choice.key)
    }

    func testWithNothingStrongEnoughTheStrongestIsChosenAndSaid() {
        let found = ModelRouting.suggest(for: task(.research), among: [local, haiku])
        XCTAssertEqual(found?.profile.id, "m1")
        XCTAssertTrue(found?.reason.contains("strongest") ?? false)
        XCTAssertNil(ModelRouting.suggest(for: task(.docs), among: []))
    }
}
