import Foundation
import Combine

enum LLMProviderKind: String, CaseIterable, Identifiable {
    case farhelm, anthropic, openai, ollama
    /// Any other service that speaks OpenAI's chat completions (Gemini,
    /// OpenRouter, LM Studio, or one of your own), through one adapter;
    /// which one is `AppSettings.service`.
    case compatible
    /// A subscription, through the vendor's own command-line tool.
    case subscription

    var id: String { rawValue }

    var label: String {
        switch self {
        case .farhelm: return "Farhelm (local gateway)"
        case .anthropic: return "Claude (Anthropic API)"
        case .openai: return "OpenAI API"
        case .ollama: return "Local (Ollama)"
        case .compatible: return "More services (Gemini, OpenRouter, LM Studio, your own)"
        case .subscription: return "Subscription (Claude Code, Codex, Antigravity)"
        }
    }
}

/// How hard the model should think before answering. Auto leaves it to the
/// engine's own default.
enum Effort: String, CaseIterable, Identifiable {
    case auto, low, medium, high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// The value engines take, or nil to send nothing.
    var wire: String? { self == .auto ? nil : rawValue }
}

enum MicSensitivity: String, CaseIterable, Identifiable {
    case high, medium, low

    var id: String { rawValue }

    var label: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    /// Minimum RMS for the voice activity detector.
    var vadFloor: Float {
        switch self {
        case .high: return 0.0025
        case .medium: return 0.006
        case .low: return 0.010
        }
    }
}

enum PanelStyle: String, CaseIterable, Identifiable {
    case frosted, clear

    var id: String { rawValue }

    var label: String {
        switch self {
        case .frosted: return "Frosted glass"
        case .clear: return "Clear"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var provider: LLMProviderKind { didSet { d.set(provider.rawValue, forKey: "provider") } }
    @Published var anthropicModel: String { didSet { d.set(anthropicModel, forKey: "anthropicModel") } }
    @Published var openAIModel: String { didSet { d.set(openAIModel, forKey: "openAIModel") } }
    @Published var ollamaModel: String { didSet { d.set(ollamaModel, forKey: "ollamaModel") } }
    /// The subscription tool in use (an adapter's id) and, when one is
    /// named, the model it is asked for. Empty leaves it to the tool.
    @Published var cliAgent: String { didSet { d.set(cliAgent, forKey: "cliAgent") } }
    @Published var cliModel: String { didSet { d.set(cliModel, forKey: "cliModel") } }
    /// The effort that tool is asked for, from its own levels. Empty
    /// leaves it to the tool.
    @Published var cliEffort: String { didSet { d.set(cliEffort, forKey: "cliEffort") } }
    /// The effort chosen for each model, by engine and model. A model
    /// with no entry is left to its own default.
    @Published var efforts: [String: String] { didSet { d.set(efforts, forKey: "efforts") } }
    @Published var ollamaURL: String { didSet { d.set(ollamaURL, forKey: "ollamaURL") } }
    @Published var farhelmURL: String { didSet { d.set(farhelmURL, forKey: "farhelmURL") } }
    @Published var farhelmModel: String { didSet { d.set(farhelmModel, forKey: "farhelmModel") } }
    /// The "More services" engine: the service in use (a `CompatibleService`
    /// id), and each service's model and address (when not its own).
    @Published var service: String { didSet { d.set(service, forKey: "service") } }
    @Published var serviceModels: [String: String] { didSet { d.set(serviceModels, forKey: "serviceModels") } }
    @Published var serviceAddresses: [String: String] { didSet { d.set(serviceAddresses, forKey: "serviceAddresses") } }
    @Published var panelStyle: PanelStyle { didSet { d.set(panelStyle.rawValue, forKey: "panelStyle") } }
    @Published var panelDarkness: Double { didSet { d.set(panelDarkness, forKey: "panelDarkness") } }
    @Published var captureMic: Bool { didSet { d.set(captureMic, forKey: "captureMic") } }
    @Published var captureSystemAudio: Bool { didSet { d.set(captureSystemAudio, forKey: "captureSystemAudio") } }
    @Published var separateMicVoices: Bool { didSet { d.set(separateMicVoices, forKey: "separateMicVoices") } }
    @Published var micSensitivity: MicSensitivity { didSet { d.set(micSensitivity.rawValue, forKey: "micSensitivity") } }
    @Published var asrEnglishOnly: Bool { didSet { d.set(asrEnglishOnly, forKey: "asrEnglishOnly") } }
    /// No longer a choice: always on.
    let polishTranscript = true
    /// The context window local models (Farhelm, Ollama) are loaded with.
    /// What the user means to spend on engines in a month, in dollars. Zero
    /// means no budget is set.
    @Published var monthlyBudget: Double { didSet { d.set(monthlyBudget, forKey: "monthlyBudget") } }
    /// How much thinking typed questions, screen answers and the agent get.
    @Published var effort: Effort { didSet { d.set(effort.rawValue, forKey: "effort") } }
    @Published var localContextTokens: Int { didSet { d.set(localContextTokens, forKey: "localContextTokens") } }
    @Published var rememberAcross: Bool { didSet { d.set(rememberAcross, forKey: "rememberAcross") } }
    @Published var keepNotes: Bool { didSet { d.set(keepNotes, forKey: "keepNotes") } }
    @Published var hideFromScreenShare: Bool { didSet { d.set(hideFromScreenShare, forKey: "hideFromScreenShare") } }
    /// The conversation drawn as one web page (`ChatDocumentPane`), so a
    /// selection runs across messages, code and pictures. Off while it is
    /// read-only and new.
    @Published var chatAsDocument: Bool { didSet { d.set(chatAsDocument, forKey: "chatAsDocument") } }

    /// On and off settings whose default matters to privacy or to what is
    /// still new, read in one place so tests can check them.
    nonisolated static let flagDefaults: [String: Bool] = ["hideFromScreenShare": true, "chatAsDocument": false]

    nonisolated static func flag(_ key: String, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? flagDefaults[key] ?? false
    }
    /// Everything is drawn at its own size; only the conversation's text
    /// changes size (chatTextScale, from Aa). Kept as 1 for the views that
    /// scale pages, code and the terminal by it.
    let contentZoom: Double = 1

    /// How large the conversation's text is, on top of the content zoom:
    /// the messages, the replies and the agent's work list. A little larger
    /// than the rest of the app by default, since it is what is read most.
    @Published var chatTextScale: Double { didSet { d.set(chatTextScale, forKey: "chatTextScale") } }
    /// Replies in a serif, as the Claude app sets them (the Mac's own New
    /// York): easier on long reading. Your messages and code keep theirs.
    /// No longer a choice: always on.
    let replySerif = true

    static let chatTextRange: ClosedRange<Double> = 0.85...1.6
    static let chatTextDefault = 1.12

    /// One step larger (+1) or smaller (-1); 0 goes back to the usual size.
    func chatText(_ step: Int) {
        let next = step == 0 ? Self.chatTextDefault : (chatTextScale + Double(step) * 0.08)
        let rounded = (next * 100).rounded() / 100
        let clamped = min(max(rounded, Self.chatTextRange.lowerBound), Self.chatTextRange.upperBound)
        if clamped != chatTextScale { chatTextScale = clamped }
    }

    /// Commits what the agent changes to git, where the folder is a repository.
    @Published var historyGit: Bool { didSet { d.set(historyGit, forKey: "historyGit") } }
    /// How long one step of an API model (Anthropic, OpenAI) may take before
    /// the agent stops waiting, in minutes; 0 is no limit. Local models and
    /// subscriptions are never cut off.
    @Published var apiStepMinutes: Int { didSet { d.set(apiStepMinutes, forKey: "apiStepMinutes") } }
    /// Shows the orbit on screen where the agent clicks, types or opens.
    /// No longer a choice: always on.
    let agentOrbit = true
    /// Lets answers use where the Mac is (weather here, what is nearby).
    @Published var useLocation: Bool { didSet { d.set(useLocation, forKey: "useLocation") } }
    /// The panel floats above every other window. Off, it behaves like an
    /// ordinary window and other apps can cover it.
    @Published var keepOnTop: Bool { didSet { d.set(keepOnTop, forKey: "keepOnTop") } }
    /// The panel is on every desktop (Space) and over full-screen apps. Off,
    /// it stays on the desktop it was opened on.
    @Published var onAllDesktops: Bool { didSet { d.set(onAllDesktops, forKey: "onAllDesktops") } }
    /// An icon in the menu bar, with a small menu. Off unless asked for.
    @Published var showInMenuBar: Bool { didSet { d.set(showInMenuBar, forKey: "showInMenuBar") } }
    /// An icon in the Dock, like an ordinary app. Off unless asked for.
    @Published var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock") } }
    @Published var autoSuggest: Bool { didSet { d.set(autoSuggest, forKey: "autoSuggest") } }
    /// No longer a choice: always on.
    let replyToQuestionsOnly = true
    @Published var sessionMode: SessionMode { didSet { d.set(sessionMode.rawValue, forKey: "sessionMode") } }
    @Published var setupDismissed: Bool { didSet { d.set(setupDismissed, forKey: "setupDismissed") } }
    /// The monitor screen answers read. 0 follows the mouse pointer.
    @Published var screenDisplayID: Int { didSet { d.set(screenDisplayID, forKey: "screenDisplayID") } }
    /// Seconds between looks at the screen while watching it.
    @Published var screenWatchInterval: Int { didSet { d.set(screenWatchInterval, forKey: "screenWatchInterval") } }
    /// Programs the agent may run without asking ("always allow").
    @Published var agentAllowed: [String] { didSet { d.set(agentAllowed, forKey: "agentAllowed") } }
    /// "dark", "light" or "system".
    @Published var appearance: String {
        didSet {
            d.set(appearance, forKey: "appearance")
            Theme.refresh()
        }
    }
    /// Bumped when the system switches between light and dark, and when the
    /// look's colors are to be drawn again. The colors are worked out anew.
    @Published var themeTick = 0 { didSet { Theme.refresh() } }
    /// The panel's colors and glass. Setting it takes effect at once for
    /// the glass; colors are drawn everywhere after `redrawLook()`.
    @Published var look: Look = LookStore.current {
        didSet {
            LookStore.set(look)
            Theme.refresh()
            // Shared panels read the content glass through the palette, so
            // they are redrawn as colors are.
            if look.content != oldValue.content { themeTick += 1 }
        }
    }

    /// Redraws everything in the look's colors.
    func redrawLook() { themeTick += 1 }
    /// Older setting, kept so a letter chosen before shortcuts became
    /// editable carries over. Shortcuts now live in `Shortcuts`.
    @Published var askHotKey: String {
        didSet { d.set(askHotKey, forKey: "askHotKey") }
    }
    /// Commands that only read run without asking.
    @Published var agentAutoApproveReads: Bool { didSet { d.set(agentAutoApproveReads, forKey: "agentAutoApproveReads") } }
    /// Apps never shown to a model, by bundle identifier, on top of the
    /// password managers Companion always keeps private
    /// (`Redaction.defaultPrivateApps`).
    @Published var privateApps: [String] { didSet { d.set(privateApps, forKey: "privateApps") } }
    /// How much the agent does without asking in a chat that has not been
    /// given its own choice (an `AgentAccess`).
    @Published var agentAccess: String { didSet { d.set(agentAccess, forKey: "agentAccess") } }
    /// How many steps the agent takes on one task before it stops to ask
    /// whether to carry on.
    @Published var agentStepBudget: Int { didSet { d.set(agentStepBudget, forKey: "agentStepBudget") } }
    /// How many chats' tasks run at once.
    @Published var agentMaxTasks: Int { didSet { d.set(agentMaxTasks, forKey: "agentMaxTasks") } }
    /// The folder the agent's shell commands start in.
    @Published var agentDirectory: String { didSet { d.set(agentDirectory, forKey: "agentDirectory") } }
    /// Speech starting with "Companion, ..." is a task for the agent.
    @Published var voiceCommands: Bool { didSet { d.set(voiceCommands, forKey: "voiceCommands") } }
    @Published var autoScreenWatch: Bool { didSet { d.set(autoScreenWatch, forKey: "autoScreenWatch") } }
    @Published var userDetails: String { didSet { ContextStore.shared.saveDetails(userDetails) } }

    private init() {
        provider = LLMProviderKind(rawValue: d.string(forKey: "provider") ?? "") ?? .farhelm
        anthropicModel = d.string(forKey: "anthropicModel") ?? "claude-haiku-5-5"
        openAIModel = d.string(forKey: "openAIModel") ?? "gpt-4o"
        ollamaModel = d.string(forKey: "ollamaModel") ?? "llama3.1:8b"
        cliAgent = d.string(forKey: "cliAgent") ?? "claude-code"
        cliModel = d.string(forKey: "cliModel") ?? ""
        cliEffort = d.string(forKey: "cliEffort") ?? ""
        efforts = d.dictionary(forKey: "efforts") as? [String: String] ?? [:]
        ollamaURL = d.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434"
        farhelmURL = d.string(forKey: "farhelmURL") ?? "http://127.0.0.1:7842/p/companion"
        farhelmModel = d.string(forKey: "farhelmModel") ?? ""
        service = d.string(forKey: "service") ?? CompatibleService.choices[0].id
        serviceModels = d.dictionary(forKey: "serviceModels") as? [String: String] ?? [:]
        serviceAddresses = d.dictionary(forKey: "serviceAddresses") as? [String: String] ?? [:]
        panelStyle = PanelStyle(rawValue: d.string(forKey: "panelStyle") ?? "") ?? .frosted
        panelDarkness = d.object(forKey: "panelDarkness") as? Double ?? 0.3
        captureMic = d.object(forKey: "captureMic") as? Bool ?? true
        captureSystemAudio = d.object(forKey: "captureSystemAudio") as? Bool ?? true
        separateMicVoices = d.object(forKey: "separateMicVoices") as? Bool ?? false
        micSensitivity = MicSensitivity(rawValue: d.string(forKey: "micSensitivity") ?? "") ?? .medium
        asrEnglishOnly = d.object(forKey: "asrEnglishOnly") as? Bool ?? false
        localContextTokens = d.object(forKey: "localContextTokens") as? Int ?? 32_000
        effort = Effort(rawValue: d.string(forKey: "effort") ?? "") ?? .auto
        monthlyBudget = d.double(forKey: "monthlyBudget")
        rememberAcross = d.object(forKey: "rememberAcross") as? Bool ?? true
        keepNotes = d.object(forKey: "keepNotes") as? Bool ?? true
        hideFromScreenShare = Self.flag("hideFromScreenShare", in: d)
        chatAsDocument = Self.flag("chatAsDocument", in: d)
        useLocation = d.bool(forKey: "useLocation")
        // Off for new installs; a value the user has saved is kept.
        historyGit = d.object(forKey: "historyGit") as? Bool ?? false
        apiStepMinutes = d.object(forKey: "apiStepMinutes") as? Int ?? 15
        d.removeObject(forKey: "contentZoom")
        let chatText = d.double(forKey: "chatTextScale")
        chatTextScale = Self.chatTextRange.contains(chatText) ? chatText : Self.chatTextDefault
        showInMenuBar = d.bool(forKey: "showInMenuBar")
        keepOnTop = d.object(forKey: "keepOnTop") as? Bool ?? true
        onAllDesktops = d.object(forKey: "onAllDesktops") as? Bool ?? true
        showInDock = d.bool(forKey: "showInDock")
        autoSuggest = d.object(forKey: "autoSuggest") as? Bool ?? true
        sessionMode = SessionMode.current
        setupDismissed = d.bool(forKey: "setupDismissed")
        screenDisplayID = d.integer(forKey: "screenDisplayID")
        screenWatchInterval = d.object(forKey: "screenWatchInterval") as? Int ?? 3
        agentAllowed = d.stringArray(forKey: "agentAllowed") ?? []
        appearance = d.string(forKey: "appearance") ?? "dark"
        askHotKey = d.string(forKey: "askHotKey") ?? "K"
        agentAutoApproveReads = d.object(forKey: "agentAutoApproveReads") as? Bool ?? true
        privateApps = d.stringArray(forKey: "privateApps") ?? []
        agentAccess = d.string(forKey: "agentAccess") ?? AgentAccess.manual.rawValue
        // Steps before checking in, for API models (0: never). An older
        // setting of 40 was the old default for every engine.
        let budget = d.object(forKey: "agentStepBudget") as? Int ?? 100
        agentStepBudget = budget == 40 ? 100 : budget
        agentMaxTasks = d.object(forKey: "agentMaxTasks") as? Int ?? 3
        agentDirectory = d.string(forKey: "agentDirectory") ?? NSHomeDirectory()
        voiceCommands = d.object(forKey: "voiceCommands") as? Bool ?? true
        autoScreenWatch = d.object(forKey: "autoScreenWatch") as? Bool ?? false
        userDetails = ContextStore.shared.loadDetails()
        // Following the system: redraw when it changes.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil,
                                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.themeTick += 1 }
        }
    }
}

/// Stores the user's background details (used in every prompt) on disk.
/// Extra .md/.txt files dropped into the context folder are included too.
final class ContextStore {
    static let shared = ContextStore()
    let baseDir: URL

    var detailsURL: URL { baseDir.appendingPathComponent("details.md") }
    var contextDir: URL { baseDir.appendingPathComponent("context", isDirectory: true) }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseDir = appSupport.appendingPathComponent("Companion", isDirectory: true)
        try? FileManager.default.createDirectory(at: contextDir, withIntermediateDirectories: true)
    }

    func loadDetails() -> String {
        (try? String(contentsOf: detailsURL, encoding: .utf8)) ?? ""
    }

    func saveDetails(_ text: String) {
        try? text.write(to: detailsURL, atomically: true, encoding: .utf8)
    }

    func combinedDetails(cap: Int = 16000) -> String {
        var parts = [loadDetails()]
        if let files = try? FileManager.default.contentsOfDirectory(at: contextDir, includingPropertiesForKeys: nil) {
            let readable = files
                .filter { ["md", "txt"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in readable {
                if let text = try? String(contentsOf: file, encoding: .utf8) {
                    parts.append("### \(file.lastPathComponent)\n\(text)")
                }
            }
        }
        let joined = parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return String(joined.prefix(cap))
    }
}

// MARK: - More services

extension AppSettings {
    /// The service the "More services" engine uses.
    var compatibleService: CompatibleService {
        CompatibleService.choices.first { $0.id == service } ?? CompatibleService.choices[0]
    }

    /// The model chosen for a service ("" before one is).
    func model(for service: CompatibleService) -> String {
        serviceModels[service.id] ?? ""
    }

    /// The address set for a service, or "" to use its own.
    func address(for service: CompatibleService) -> String {
        serviceAddresses[service.id] ?? ""
    }

    /// Whether what is sent stays on this Mac (or its network).
    var engineRunsHere: Bool {
        switch provider {
        case .farhelm, .ollama: return true
        case .compatible:
            let chosen = compatibleService
            return chosen.runsLocally(at: address(for: chosen))
        case .anthropic, .openai, .subscription: return false
        }
    }

    /// An engine billed by use through its API, where the step limits in
    /// Settings > Usage apply: not a subscription, and not one on this Mac.
    var engineBilledByUse: Bool {
        switch provider {
        case .anthropic, .openai: return true
        case .compatible: return !engineRunsHere
        case .farhelm, .ollama, .subscription: return false
        }
    }
}

// MARK: - Effort, per model

extension AppSettings {
    /// The model in use, as the key its effort is kept under.
    var effortKey: String {
        switch provider {
        case .farhelm: return "\(provider.rawValue)|\(farhelmModel)"
        case .anthropic: return "\(provider.rawValue)|\(anthropicModel)"
        case .openai: return "\(provider.rawValue)|\(openAIModel)"
        case .ollama: return "\(provider.rawValue)|\(ollamaModel)"
        case .compatible: return "\(provider.rawValue)|\(service)|\(model(for: compatibleService))"
        case .subscription: return "\(provider.rawValue)|\(cliAgent)|\(cliModel)"
        }
    }

    /// The effort levels the engine in use takes. A subscription tool has
    /// its own; one with none offers no choice.
    var effortLevels: [String] {
        if provider == .subscription { return CLIAgents.shared.adapter(cliAgent)?.efforts ?? [] }
        return Effort.allCases.compactMap(\.wire)
    }

    /// The effort for the model in use, or empty to leave it to the model.
    /// A level the engine does not take counts as none.
    var chosenEffort: String {
        get {
            let levels = effortLevels
            if let saved = efforts[effortKey] { return levels.contains(saved) ? saved : "" }
            // Before effort was kept per model there was one setting for
            // the tools and one for everything else.
            let earlier = provider == .subscription ? cliEffort : (effort.wire ?? "")
            return levels.contains(earlier) ? earlier : ""
        }
        set { efforts[effortKey] = newValue }
    }

    /// A level as shown: "xhigh" reads "Extra high".
    static func effortLabel(_ level: String) -> String {
        switch level {
        case "": return "Auto"
        case "xhigh": return "Extra high"
        default: return level.prefix(1).uppercased() + level.dropFirst()
        }
    }
}
