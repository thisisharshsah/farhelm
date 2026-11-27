import XCTest
@testable import Companion
import CompanionBoard

@MainActor
final class ModelChoicesTests: XCTestCase {
    private func profile(_ id: String, place: ModelProfile.Place, tools: Bool = true) -> ModelProfile {
        ModelProfile(id: id, choice: ModelChoice(engine: "x", tool: nil, model: id), name: id, place: place,
                     inputPrice: place == .api ? 3 : 0, outputPrice: place == .api ? 15 : 0,
                     window: 100_000, tier: .balanced, tools: tools)
    }

    private func entry(_ id: String, place: ModelProfile.Place, tools: Bool = true) -> ModelChoices.Entry {
        ModelChoices.Entry(id: id, profile: profile(id, place: place, tools: tools), title: id,
                           detail: [], symbol: nil, keywords: [])
    }

    // The chat and the board both build rows through `ModelChoices.sections`,
    // so the same models come out grouped and ordered alike.
    func testGroupsKeepTheChatsOrderAndLabels() {
        let sections = ModelChoices.sections([
            entry("a", place: .api), entry("b", place: .account), entry("c", place: .local),
        ])
        XCTAssertEqual(sections.map(\.id), ["local", "api", "account"])
        XCTAssertEqual(sections.map(\.title), ["On this Mac", "API", "Your accounts"])
    }

    func testRowsKeepTheOrderGivenWithinAGroup() {
        let sections = ModelChoices.sections([
            entry("a", place: .api), entry("c", place: .local), entry("b", place: .api),
        ])
        XCTAssertEqual(sections.last?.items.map(\.id), ["a", "b"])
    }

    // The chat's path end to end (`ModelChoices.listing`, then the picker's
    // own `ModelPicker.rows`) against the board's listing of the same models.
    func testBoardPickerRowsMatchTheChatPickerRowsForTheSameModels() {
        let engines = [
            EngineCatalog.Engine(kind: .anthropic, tool: nil, models: ["claude-opus-5-5", "claude-haiku-5-5"]),
            EngineCatalog.Engine(kind: .farhelm, tool: nil, models: ["local-a"]),
            EngineCatalog.Engine(kind: .openai, tool: nil, models: ["gpt-x"]),
        ]
        let chat = ModelChoices.listing(engines: engines)
        let roster = engines.flatMap { engine in
            engine.models.map { EngineChoice(kind: engine.kind, tool: engine.tool, model: $0) }
        }.enumerated().map { index, choice in
            ModelRoster.Entry(profile: ModelRoster.profile(of: choice, id: "m\(index + 1)"), engine: choice)
        }
        let board = BoardModelChoices.listing(roster, advised: nil, current: nil)

        let chatRows = ModelPicker.rows(chat)
        let boardRows = ModelPicker.rows(board)
        XCTAssertFalse(chatRows.isEmpty)
        XCTAssertEqual(boardRows.map(\.title), chatRows.map(\.title))
        XCTAssertEqual(boardRows.map(\.place), chatRows.map(\.place))
        XCTAssertEqual(board.sections.map(\.id), chat.sections.map(\.id))
        XCTAssertEqual(board.sections.flatMap(\.items).map(\.badges), chat.sections.flatMap(\.items).map(\.badges))
    }

    func testBadgesNameSourceCostAndMissingToolCalls() {
        let items = ModelChoices.sections([
            entry("l", place: .local, tools: false), entry("p", place: .api),
        ]).flatMap(\.items)
        XCTAssertEqual(items.first { $0.id == "l" }?.badges.map(\.text), ["Local", "Free", "No native tool calls"])
        XCTAssertEqual(items.first { $0.id == "p" }?.badges.map(\.text), ["API", "Billed by use"])
    }
}