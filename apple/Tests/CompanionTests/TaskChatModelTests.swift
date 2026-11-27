import XCTest
@testable import Companion
import CompanionBoard

/// A task's chat shows and sends to the model on its card. The picker and
/// every send read the app's settings, so these open task chats through the
/// same lookup `openConversation` uses and then read what those settings say.
@MainActor
final class TaskChatModelTests: XCTestCase {
    private struct Saved {
        let provider: LLMProviderKind
        let farhelm: String, anthropic: String, openAI: String, ollama: String
        let service: String, serviceModels: [String: String]
        let cliAgent: String, cliModel: String
        let lastModel: String?
    }

    private var saved: Saved!

    private var lastModelKey: String { "lastModel." + AppSettings.shared.cliAgent }

    // `EngineCatalog.choose` writes any of these by engine kind, so all of
    // them are put back, not only the ones these tests touch.
    override func setUp() async throws {
        let s = AppSettings.shared
        saved = Saved(provider: s.provider, farhelm: s.farhelmModel, anthropic: s.anthropicModel,
                      openAI: s.openAIModel, ollama: s.ollamaModel, service: s.service,
                      serviceModels: s.serviceModels, cliAgent: s.cliAgent, cliModel: s.cliModel,
                      lastModel: UserDefaults.standard.string(forKey: lastModelKey))
    }

    override func tearDown() async throws {
        let s = AppSettings.shared
        s.provider = saved.provider
        s.farhelmModel = saved.farhelm
        s.anthropicModel = saved.anthropic
        s.openAIModel = saved.openAI
        s.ollamaModel = saved.ollama
        s.service = saved.service
        s.serviceModels = saved.serviceModels
        s.cliAgent = saved.cliAgent
        s.cliModel = saved.cliModel
        if let last = saved.lastModel {
            UserDefaults.standard.set(last, forKey: lastModelKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastModelKey)
        }
    }

    private func entry(_ model: String, id: String) -> ModelRoster.Entry {
        let engine = EngineChoice(kind: .ollama, model: model)
        return ModelRoster.Entry(profile: ModelRoster.profile(of: engine, id: id), engine: engine)
    }

    /// A board with one task per model, each with a run in its own chat,
    /// and the chat that belongs to it.
    private func board(with entries: [ModelRoster.Entry]) -> (Board, [Conversation]) {
        let now = Date()
        var board = Board(project: UUID(), now: now)
        var chats: [Conversation] = []
        for entry in entries {
            let item = board.add(title: "Task for \(entry.engine.model)", by: .person, now: now)
            var chat = Conversation()
            chat.kind = .task
            chat.taskID = item.id
            let model = entry.engine.choice
            board.update(item.id, now: now) {
                $0.assignment = Assignment(model: model, label: model.model, reason: "", source: .person,
                                           accepted: true, date: now)
                $0.runs = [WorkRun(conversation: chat.id, model: model, modelLabel: model.model, startedAt: now)]
            }
            chats.append(chat)
        }
        return (board, chats)
    }

    func testOpeningTaskAThenBShowsEachCardsOwnModel() {
        let roster = [entry("model-a", id: "m1"), entry("model-b", id: "m2")]
        let (board, chats) = board(with: roster)

        XCTAssertTrue(Advanced.showCardModel(for: chats[0], on: board, roster: roster))
        XCTAssertEqual(EngineCatalog.current(EngineCatalog.Engine(kind: .ollama, tool: nil, models: [])), "model-a")
        XCTAssertEqual(EngineChoice.inUse.model, "model-a")

        XCTAssertTrue(Advanced.showCardModel(for: chats[1], on: board, roster: roster))
        XCTAssertEqual(EngineChoice.inUse.model, "model-b")

        // Back to the first: the picker follows the task, not the last pick.
        XCTAssertTrue(Advanced.showCardModel(for: chats[0], on: board, roster: roster))
        XCTAssertEqual(EngineChoice.inUse.model, "model-a")
    }

    func testTheModelAChatSendsToIsItsCardsModel() throws {
        let roster = [entry("model-a", id: "m1"), entry("model-b", id: "m2")]
        let (board, chats) = board(with: roster)
        XCTAssertTrue(Advanced.showCardModel(for: chats[1], on: board, roster: roster))
        // What a send is built from, after the chat was opened.
        XCTAssertEqual(EngineChoice.inUse, roster[1].engine)
        XCTAssertEqual(try EngineChoice.inUse.config().model, "model-b")
    }

    func testACardWhoseModelCannotBeAskedLeavesTheBoxAlone() {
        let roster = [entry("model-a", id: "m1"), entry("model-b", id: "m2")]
        let (board, chats) = board(with: roster)
        Advanced.showCardModel(for: chats[0], on: board, roster: roster)
        // The roster no longer holds task B's model.
        XCTAssertFalse(Advanced.showCardModel(for: chats[1], on: board, roster: [roster[0]]))
        XCTAssertEqual(EngineChoice.inUse.model, "model-a")
    }

    func testAChatThatIsNotATaskChatLeavesTheBoxAlone() {
        let roster = [entry("model-a", id: "m1")]
        let (board, _) = board(with: roster)
        XCTAssertFalse(Advanced.showCardModel(for: Conversation(), on: board, roster: roster))
    }
}