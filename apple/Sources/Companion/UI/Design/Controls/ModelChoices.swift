import SwiftUI

// The models a chat can answer with, as the searchable picker lists them:
// grouped by where they run (this Mac, an API, an account), each with badges
// for its source and cost. A model's context window and tool-call support are
// not known to the app, so no badge claims them.

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

    private struct Source {
        let place: String
        let title: String
        let symbol: String
        let origin: SelectionBadge
        let cost: SelectionBadge
    }

    /// In the order they are listed.
    private static let sources = [
        Source(place: "local", title: "On this Mac", symbol: "lock",
               origin: SelectionBadge("Local", symbol: "lock", tone: .positive),
               cost: SelectionBadge("Free", tone: .positive)),
        Source(place: "api", title: "API", symbol: "cloud",
               origin: SelectionBadge("API", symbol: "cloud", tone: .info),
               cost: SelectionBadge("Billed by use", tone: .caution)),
        Source(place: "account", title: "Your accounts", symbol: "person",
               origin: SelectionBadge("Account", symbol: "person", tone: .neutral),
               cost: SelectionBadge("In your plan", tone: .neutral)),
    ]

    static func choiceID(_ engine: EngineCatalog.Engine, _ model: String) -> String {
        engine.id + "\u{1F}" + model
    }

    static func listing() -> Listing {
        let engines = EngineCatalog.engines
        var choices: [String: Choice] = [:]
        var current: String?
        var sections: [SelectionSection<String>] = []
        for source in sources {
            var items: [SelectionItem<String>] = []
            for engine in engines where EngineCatalog.place(engine) == source.place {
                let name = EngineCatalog.name(engine)
                for model in engine.models {
                    let id = choiceID(engine, model)
                    guard choices[id] == nil else { continue }
                    choices[id] = Choice(engine: engine, model: model)
                    if EngineCatalog.inUse(engine), EngineCatalog.current(engine) == model { current = id }
                    var detail = [name]
                    if let note = EngineCatalog.note(engine, model) { detail.append(note) }
                    // What is left of the plan, for a tool that says.
                    if engine.kind == .subscription, model.isEmpty, let tool = engine.tool,
                       let left = CLIAgents.shared.limitsLine(for: tool) {
                        detail.append(left)
                    }
                    items.append(SelectionItem(
                        id: id, title: EngineCatalog.title(engine, model),
                        subtitle: detail.joined(separator: " \u{00B7} "), symbol: engine.kind.icon,
                        badges: [source.origin, source.cost],
                        keywords: [engine.kind.shortName, model]))
                }
            }
            if !items.isEmpty {
                sections.append(SelectionSection(id: source.place, title: source.title,
                                                 symbol: source.symbol, items: items))
            }
        }
        return Listing(sections: sections, choices: choices, current: current)
    }
}