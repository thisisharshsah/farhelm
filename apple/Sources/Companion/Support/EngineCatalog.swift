import Foundation

/// The engines Companion can answer with and their models: what the model
/// picker lists, and what the phone app lists, from one place. Choosing
/// goes through here too, so the Mac and the phone set it the same way.
@MainActor
enum EngineCatalog {
    /// One engine, or, for subscriptions and More services, one tool or
    /// service as an engine of its own.
    struct Engine: Identifiable {
        let kind: LLMProviderKind
        /// The subscription tool (an adapter's id), or the service (a
        /// `CompatibleService` id), for those kinds.
        var tool: String?
        let models: [String]
        var id: String { kind.rawValue + "|" + (tool ?? "") }
    }

    private static var settings: AppSettings { AppSettings.shared }
    private static var agents: CLIAgents { CLIAgents.shared }

    /// An engine is listed when it is the one in use or has what it needs
    /// (a key for the hosted ones; the local ones need none here).
    static func ready(_ kind: LLMProviderKind) -> Bool {
        if kind == settings.provider { return true }
        switch kind {
        case .farhelm: return !(Keychain.read("farhelm") ?? "").isEmpty
        case .anthropic: return !(Keychain.read("anthropic") ?? "").isEmpty
        case .openai: return !(Keychain.read("openai") ?? "").isEmpty
        case .ollama: return true
        case .apple: return AppleModel.unavailableReason == nil
        case .compatible: return !readyServices.isEmpty
        case .subscription: return !agents.installed.isEmpty
        }
    }

    /// The services of More services that can answer: the one in use, and
    /// any other with a model chosen and, where one is needed, a key.
    static var readyServices: [CompatibleService] {
        CompatibleService.choices.filter { service in
            if settings.provider == .compatible, service.id == settings.service { return true }
            guard !settings.model(for: service).isEmpty else { return false }
            return !service.keyRequired || !(Keychain.read(service.keyAccount) ?? "").isEmpty
        }
    }

    static var engines: [Engine] {
        let app = AppState.shared
        return LLMProviderKind.allCases.filter(ready).flatMap { kind -> [Engine] in
            switch kind {
            case .farhelm:
                return [Engine(kind: kind, models: [""] + app.farhelmModels)]
            case .anthropic:
                var list = app.anthropicModels
                if !list.contains(settings.anthropicModel) { list.insert(settings.anthropicModel, at: 0) }
                return [Engine(kind: kind, models: list)]
            case .openai:
                return [Engine(kind: kind, models: [settings.openAIModel])]
            case .ollama:
                return [Engine(kind: kind, models: [settings.ollamaModel])]
            case .apple:
                return [Engine(kind: kind, models: [""])]
            case .compatible:
                return readyServices.map { service in
                    Engine(kind: kind, tool: service.id, models: [settings.model(for: service)])
                }
            case .subscription:
                return agents.installed.map { adapter in
                    var list = agents.models(for: adapter.id)
                    if adapter.id == settings.cliAgent, !list.contains(settings.cliModel) {
                        list.append(settings.cliModel)
                    }
                    return Engine(kind: kind, tool: adapter.id, models: list)
                }
            }
        }
    }

    /// Whether this is the engine (and tool or service) that answers now.
    static func inUse(_ engine: Engine) -> Bool {
        guard settings.provider == engine.kind, let tool = engine.tool else { return settings.provider == engine.kind }
        return tool == (engine.kind == .compatible ? settings.service : settings.cliAgent)
    }

    /// The model this engine would use.
    static func current(_ engine: Engine) -> String {
        switch engine.kind {
        case .farhelm: return settings.farhelmModel
        case .anthropic: return settings.anthropicModel
        case .openai: return settings.openAIModel
        case .ollama: return settings.ollamaModel
        case .apple: return ""
        case .compatible: return settings.serviceModels[engine.tool ?? settings.service] ?? ""
        case .subscription:
            if engine.tool == settings.cliAgent { return settings.cliModel }
            return UserDefaults.standard.string(forKey: "lastModel." + (engine.tool ?? "")) ?? ""
        }
    }

    /// Makes this engine and model the ones that answer.
    static func choose(_ engine: Engine, _ model: String) {
        settings.provider = engine.kind
        switch engine.kind {
        case .farhelm: settings.farhelmModel = model
        case .anthropic: settings.anthropicModel = model
        case .openai: settings.openAIModel = model
        case .ollama: settings.ollamaModel = model
        case .apple: break
        case .compatible:
            settings.service = engine.tool ?? settings.service
            settings.serviceModels[settings.service] = model
        case .subscription:
            settings.cliAgent = engine.tool ?? settings.cliAgent
            settings.cliModel = model
            // Each tool keeps its own model, for its tab in the chat box.
            UserDefaults.standard.set(model, forKey: "lastModel." + settings.cliAgent)
        }
    }

    /// The engine's name as shown.
    static func name(_ engine: Engine) -> String {
        guard let tool = engine.tool else { return engine.kind.shortName }
        if engine.kind == .compatible { return CompatibleService.named(tool)?.name ?? tool }
        return agents.name(of: tool)
    }

    /// A model's name as shown.
    static func title(_ engine: Engine, _ model: String) -> String {
        // A service has no default model to fall back on.
        if engine.kind == .compatible, model.isEmpty { return "No model chosen" }
        if engine.kind == .apple { return AppleModel.modelName }
        guard engine.kind == .subscription else { return ModelName.pretty(model) }
        return agents.title(of: model, for: engine.tool ?? "")
    }

    /// What is said beside a model: who picks the default, or what it is
    /// good at.
    static func note(_ engine: Engine, _ model: String) -> String? {
        let kind = engine.kind
        if kind == .farhelm, model.isEmpty { return "Farhelm picks" }
        if kind == .compatible, model.isEmpty { return "Choose one in Settings" }
        if kind == .apple { return "Free, private, offline" }
        if kind == .subscription, model.isEmpty {
            return agents.version(of: "", for: engine.tool ?? "") ?? "The tool picks"
        }
        guard kind == .anthropic else { return nil }
        if model.contains("haiku") { return "Fastest" }
        if model.contains("sonnet") { return "Balanced" }
        if model.contains("opus") { return "Most capable" }
        return nil
    }

    /// Where it runs, in a word: on this Mac, through an account, or an API.
    static func place(_ engine: Engine) -> String {
        if engine.kind == .subscription { return "account" }
        if engine.kind == .compatible, let service = engine.tool.flatMap(CompatibleService.named) {
            return service.runsLocally(at: settings.address(for: service)) ? "local" : "api"
        }
        return engine.kind.isLocal ? "local" : "api"
    }
}
