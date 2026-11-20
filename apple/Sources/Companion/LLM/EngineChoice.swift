import CompanionBoard
import Foundation

/// One engine and one of its models, as something that can be asked: the
/// engine that answers now, or any other that is set up.
///
/// Advanced mode gives each task to a model of its own, so "the engine" is
/// no longer only the one chosen in the chat box. Everything that needs an
/// engine's key, address, name or cost gets it here, from one place, for
/// the engine in use and for any other alike.
struct EngineChoice: Equatable {
    var kind: LLMProviderKind
    /// The subscription tool (an adapter's id), or the service of More
    /// services (a `CompatibleService` id), for those kinds.
    var tool: String?
    /// The model, or "" to leave the pick to the engine.
    var model: String

    init(kind: LLMProviderKind, tool: String? = nil, model: String) {
        self.kind = kind
        self.tool = tool
        self.model = model
    }

    /// From a choice as a board keeps it. nil when the engine is not one
    /// this build knows.
    init?(_ choice: ModelChoice) {
        guard let kind = LLMProviderKind(rawValue: choice.engine) else { return nil }
        self.init(kind: kind, tool: choice.tool, model: choice.model)
    }

    /// The choice as a board keeps it.
    var choice: ModelChoice {
        ModelChoice(engine: kind.rawValue, tool: tool, model: model)
    }

    /// The engine and model that answer now (the chat box's choice).
    @MainActor
    static var inUse: EngineChoice {
        let settings = AppSettings.shared
        switch settings.provider {
        case .farhelm: return EngineChoice(kind: .farhelm, model: settings.farhelmModel)
        case .anthropic: return EngineChoice(kind: .anthropic, model: settings.anthropicModel)
        case .openai: return EngineChoice(kind: .openai, model: settings.openAIModel)
        case .ollama: return EngineChoice(kind: .ollama, model: settings.ollamaModel)
        case .apple: return EngineChoice(kind: .apple, model: "")
        case .compatible:
            let service = settings.compatibleService
            return EngineChoice(kind: .compatible, tool: service.id, model: settings.model(for: service))
        case .subscription:
            return EngineChoice(kind: .subscription, tool: settings.cliAgent, model: settings.cliModel)
        }
    }

    /// The service behind a More services choice.
    private var service: CompatibleService {
        CompatibleService.choices.first { $0.id == tool } ?? CompatibleService.choices[0]
    }

    /// The name as shown, in the form a chat turn's label takes, so the
    /// engine's logo is drawn beside it: "Claude · Sonnet 5.5".
    @MainActor
    var label: String {
        let engine = EngineCatalog.Engine(kind: kind, tool: tool, models: [])
        return "\(EngineCatalog.name(engine)) · \(EngineCatalog.title(engine, model))"
    }

    /// What a request to this engine needs: its key, its address and the
    /// names it goes by. Throws, in words for the user, when something it
    /// needs is not set up.
    @MainActor
    func config() throws -> LLMConfig {
        let settings = AppSettings.shared
        let env = ProcessInfo.processInfo.environment
        switch kind {
        case .farhelm:
            let key = Keychain.read("farhelm") ?? env["FARHELM_API_KEY"] ?? ""
            guard !key.isEmpty else {
                throw LLMError.notConfigured("Add your Farhelm client key in Settings. One-time setup on this Mac: farhelm clients add companion")
            }
            return LLMConfig(kind: .farhelm, apiKey: key, model: model, baseURL: settings.farhelmURL)
        case .anthropic:
            let key = Keychain.read("anthropic") ?? env["ANTHROPIC_API_KEY"] ?? ""
            guard !key.isEmpty else {
                throw LLMError.notConfigured("Add an Anthropic API key in Settings (the gear > Engine), or switch to another provider.")
            }
            return LLMConfig(kind: .anthropic, apiKey: key, model: model, baseURL: "")
        case .openai:
            let key = Keychain.read("openai") ?? env["OPENAI_API_KEY"] ?? ""
            guard !key.isEmpty else {
                throw LLMError.notConfigured("Add an OpenAI API key in Settings, or switch to another provider.")
            }
            return LLMConfig(kind: .openai, apiKey: key, model: model, baseURL: "")
        case .ollama:
            return LLMConfig(kind: .ollama, apiKey: "", model: model, baseURL: settings.ollamaURL)
        case .apple:
            if let reason = AppleModel.unavailableReason { throw LLMError.notConfigured(reason) }
            // It has one model, named for the usage records.
            return LLMConfig(kind: .apple, apiKey: "", model: AppleModel.modelName, baseURL: "")
        case .compatible:
            let service = self.service
            let key = Keychain.read(service.keyAccount) ?? service.keyVariable.flatMap { env[$0] } ?? ""
            if service.keyRequired, key.isEmpty {
                throw LLMError.notConfigured("Add your \(service.name) API key in Settings (the gear > Engine), or switch to another engine.")
            }
            guard !model.isEmpty else {
                throw LLMError.notConfigured("Choose a \(service.name) model in Settings (the gear > Engine).")
            }
            let address = settings.address(for: service)
            guard !service.address(address).isEmpty else {
                throw LLMError.notConfigured("Set \(service.name)'s address in Settings (the gear > Engine).")
            }
            var config = LLMConfig(kind: .compatible, apiKey: key, model: model, baseURL: address)
            config.service = service.id
            return config
        case .subscription:
            // The tool holds the sign-in. `model` names the tool here and
            // `baseURL` carries the model it is asked for, if any.
            return LLMConfig(kind: .subscription, apiKey: "", model: tool ?? settings.cliAgent, baseURL: model)
        }
    }

    /// The same without its key, for the questions that need no key: how
    /// much the model holds, where it runs.
    @MainActor
    private var keyless: LLMConfig {
        let settings = AppSettings.shared
        switch kind {
        case .farhelm: return LLMConfig(kind: .farhelm, apiKey: "", model: model, baseURL: settings.farhelmURL)
        case .ollama: return LLMConfig(kind: .ollama, apiKey: "", model: model, baseURL: settings.ollamaURL)
        case .apple: return LLMConfig(kind: .apple, apiKey: "", model: AppleModel.modelName, baseURL: "")
        case .compatible:
            var config = LLMConfig(kind: .compatible, apiKey: "", model: model, baseURL: settings.address(for: service))
            config.service = service.id
            return config
        case .subscription:
            return LLMConfig(kind: .subscription, apiKey: "", model: tool ?? settings.cliAgent, baseURL: model)
        case .anthropic, .openai:
            return LLMConfig(kind: kind, apiKey: "", model: model, baseURL: "")
        }
    }

    /// Tokens the model takes in one request.
    @MainActor
    var window: Int { ContextBudget.of(keyless).window }

    /// The effort chosen for this model in the chat box, in the form the
    /// engines take, or nil for the model's own. (A subscription tool
    /// reads its effort from the settings itself.)
    @MainActor
    var effort: String? {
        let key: String
        switch kind {
        // Neither takes an effort from here: a tool reads its own, and
        // Apple's on-device model takes none.
        case .subscription, .apple: return nil
        case .compatible: key = "\(kind.rawValue)|\(tool ?? "")|\(model)"
        case .farhelm, .anthropic, .openai, .ollama: key = "\(kind.rawValue)|\(model)"
        }
        guard let saved = AppSettings.shared.efforts[key],
              Effort.allCases.compactMap(\.wire).contains(saved) else { return nil }
        return saved
    }

    /// Whether what is sent stays on this Mac (or its network).
    @MainActor
    var runsHere: Bool {
        switch kind {
        case .farhelm, .ollama, .apple: return true
        case .compatible: return service.runsLocally(at: AppSettings.shared.address(for: service))
        case .anthropic, .openai, .subscription: return false
        }
    }

    /// An engine billed by use through its API: not a subscription, and
    /// not one on this Mac. (`AppSettings.engineBilledByUse`, for any engine.)
    @MainActor
    var billedByUse: Bool {
        switch kind {
        case .anthropic, .openai: return true
        case .compatible: return !runsHere
        case .farhelm, .ollama, .apple, .subscription: return false
        }
    }

    /// Whether it calls tools natively, which agent work goes better with.
    var callsTools: Bool {
        switch kind {
        case .anthropic, .openai, .farhelm: return true
        case .compatible: return service.tools
        case .ollama, .apple, .subscription: return false
        }
    }

    /// The names its usage is recorded under (see `LLMConfig.usageEngine`
    /// and `LLM.stream`): a subscription's usage is kept under its tool.
    var usageNames: (engine: String, model: String) {
        switch kind {
        case .compatible: return (service.id, model)
        case .subscription: return (kind.rawValue, tool ?? "")
        case .apple: return (kind.rawValue, AppleModel.modelName)
        case .farhelm, .anthropic, .openai, .ollama: return (kind.rawValue, model)
        }
    }
}
