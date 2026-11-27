import CompanionBoard
import SwiftUI

// The models a picker can offer, as the searchable picker lists them: one
// builder for the chat, the task cards and the supervisor, so they group,
// sort and badge alike. Grouped by where they run (this Mac, a subscription,
// an API, in that order), each row with badges for where it runs, what it
// costs and, when it lacks them, native tool calls.

@MainActor
enum ModelChoices {
    /// What a picker row stands for.
    struct Choice {
        let engine: EngineCatalog.Engine
        let model: String
    }

    struct Listing {
        var sections: [SelectionSection<String>]
        var choices: [String: Choice]
        /// The row of the engine and model that answer now.
        var current: String?
    }

    /// A model as every picker lists it, before it is grouped.
    struct Entry {
        let id: String
        let profile: ModelProfile
        var title: String
        var detail: [String]
        var symbol: String?
        var keywords: [String]
    }

    private struct Source {
        let place: ModelProfile.Place
        let title: String
        let symbol: String
        let origin: SelectionBadge
    }

    /// In the order they are listed.
    private static let sources = [
        Source(place: .local, title: "On this Mac", symbol: "lock",
               origin: SelectionBadge("Local", symbol: "lock", tone: .positive)),
        Source(place: .api, title: "API", symbol: "cloud",
               origin: SelectionBadge("API", symbol: "cloud", tone: .info)),
        Source(place: .account, title: "Your accounts", symbol: "person",
               origin: SelectionBadge("Account", symbol: "person", tone: .neutral)),
    ]

    static func choiceID(_ engine: EngineCatalog.Engine, _ model: String) -> String {
        engine.id + "\u{1F}" + model
    }

    static func cost(_ profile: ModelProfile) -> SelectionBadge {
        switch profile.place {
        case .local: return SelectionBadge("Free", tone: .positive)
        case .account: return SelectionBadge("In your plan", tone: .neutral)
        case .api: return SelectionBadge("Billed by use", tone: .caution)
        }
    }

    /// One row for an engine and model: its name, what is said beside it
    /// and what is left of a plan. `extra` goes at the end of the line.
    static func entry(id: String, engine choice: EngineChoice, profile: ModelProfile,
                      extra: [String] = [], symbol: String? = nil) -> Entry {
        let engine = EngineCatalog.Engine(kind: choice.kind, tool: choice.tool, models: [])
        var detail = [EngineCatalog.name(engine)]
        if let note = EngineCatalog.note(engine, choice.model) { detail.append(note) }
        // What is left of the plan, for a tool that says.
        if choice.kind == .subscription, choice.model.isEmpty, let tool = choice.tool,
           let left = CLIAgents.shared.limitsLine(for: tool) {
            detail.append(left)
        }
        return Entry(id: id, profile: profile, title: EngineCatalog.title(engine, choice.model),
                     detail: detail + extra, symbol: symbol ?? choice.kind.icon,
                     keywords: [choice.kind.shortName, choice.model, profile.tier.title])
    }

    /// The groups and rows of a list, whatever order the entries come in:
    /// groups in a fixed order, rows in the order given.
    static func sections(_ entries: [Entry]) -> [SelectionSection<String>] {
        sources.compactMap { source in
            let items = entries.filter { $0.profile.place == source.place }.map { entry -> SelectionItem<String> in
                var badges = [source.origin, cost(entry.profile)]
                if !entry.profile.tools {
                    badges.append(SelectionBadge("No native tool calls", symbol: "wrench", tone: .caution))
                }
                return SelectionItem(id: entry.id, title: entry.title,
                                     subtitle: entry.detail.joined(separator: " \u{00B7} "),
                                     symbol: entry.symbol, badges: badges, keywords: entry.keywords)
            }
            return items.isEmpty ? nil : SelectionSection(id: source.place.rawValue, title: source.title,
                                                          symbol: source.symbol, items: items)
        }
    }

    /// The chat's own listing. `engines` is a parameter so a test can run
    /// this exact path on a fixed set of models.
    static func listing(engines given: [EngineCatalog.Engine]? = nil) -> Listing {
        let engines = given ?? EngineCatalog.engines
        var choices: [String: Choice] = [:]
        var current: String?
        var entries: [Entry] = []
        for engine in engines {
            for model in engine.models {
                let id = choiceID(engine, model)
                guard choices[id] == nil else { continue }
                choices[id] = Choice(engine: engine, model: model)
                if EngineCatalog.inUse(engine), EngineCatalog.current(engine) == model { current = id }
                let asked = EngineChoice(kind: engine.kind, tool: engine.tool, model: model)
                entries.append(entry(id: id, engine: asked, profile: ModelRoster.profile(of: asked, id: id)))
            }
        }
        return Listing(sections: sections(entries), choices: choices, current: current)
    }
}