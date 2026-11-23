import CompanionBoard
import Foundation

/// The models a board's tasks can be given to: every engine that is set
/// up, with each of its models, described the way choosing between them
/// needs (where it runs, what it costs, how much it holds, how capable it
/// is). The supervisor is shown this list and names models by the short
/// names here; the rule that suggests a model without asking one
/// (`ModelRouting`) works from the same list.
@MainActor
enum ModelRoster {
    struct Entry: Identifiable, Equatable {
        let profile: ModelProfile
        let engine: EngineChoice

        var id: String { profile.id }
    }

    /// The most models listed: enough for any real setup, and a bound on
    /// what the supervisor has to read.
    private static let limit = 40

    /// Every model that can be asked now, in the order the model picker
    /// lists them, named m1, m2 and so on.
    static var entries: [Entry] {
        var found: [EngineChoice] = []
        for engine in EngineCatalog.engines {
            for model in engine.models {
                // A service with no model chosen cannot be asked yet.
                if engine.kind == .compatible, model.isEmpty { continue }
                let choice = EngineChoice(kind: engine.kind, tool: engine.tool, model: model)
                if !found.contains(choice) { found.append(choice) }
            }
        }
        return found.prefix(limit).enumerated().map { index, choice in
            Entry(profile: profile(of: choice, id: "m\(index + 1)"), engine: choice)
        }
    }

    /// A model as the routing rules see it.
    static func profile(of engine: EngineChoice, id: String) -> ModelProfile {
        let names = engine.usageNames
        let price = PriceBook.shared.price(engine: names.engine, model: names.model)
        let place: ModelProfile.Place
        if engine.kind == .subscription {
            place = .account
        } else {
            place = engine.runsHere ? .local : .api
        }
        // A subscription tool left to its own pick uses its maker's best.
        let tier = engine.kind == .subscription && engine.model.isEmpty
            ? ModelProfile.Tier.strong
            : ModelRouting.tier(ofModelNamed: engine.model.isEmpty ? engine.label : engine.model)
        // A subscription's tool is an agent of its own, with its own tools
        // (`CLIAgent`), and all its models share one plan's limits.
        let subscription = engine.kind == .subscription
        return ModelProfile(id: id, choice: engine.choice, name: engine.label, place: place,
                            inputPrice: price.input, outputPrice: price.output, window: engine.window,
                            tier: tier, tools: engine.callsTools || subscription,
                            group: subscription ? "\(engine.kind.rawValue)|\(engine.tool ?? "")" : nil)
    }

    /// The entry for a saved choice, when that model can still be asked.
    static func entry(for choice: ModelChoice, in entries: [Entry]) -> Entry? {
        entries.first { $0.profile.choice == choice }
    }

    /// The list as the supervisor reads it, one model a line, each with
    /// how many open tasks its group already has (`ModelRouting.busy`).
    static func lines(_ entries: [Entry], busy: [String: Int] = [:]) -> String {
        entries.map { entry -> String in
            let open = busy[entry.profile.group] ?? 0
            return entry.profile.line + " | " + (open == 1 ? "1 open task" : "\(open) open tasks")
        }.joined(separator: "\n")
    }
}
