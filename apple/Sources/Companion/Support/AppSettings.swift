import Foundation
import Combine

enum LLMProviderKind: String, CaseIterable, Identifiable {
    case farhelm, anthropic, openai, ollama

    var id: String { rawValue }

    var label: String {
        switch self {
        case .farhelm: return "Farhelm (local gateway)"
        case .anthropic: return "Claude (Anthropic API)"
        case .openai: return "OpenAI API"
        case .ollama: return "Local (Ollama)"
        }
    }
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
    @Published var ollamaURL: String { didSet { d.set(ollamaURL, forKey: "ollamaURL") } }
    @Published var farhelmURL: String { didSet { d.set(farhelmURL, forKey: "farhelmURL") } }
    @Published var farhelmModel: String { didSet { d.set(farhelmModel, forKey: "farhelmModel") } }
    @Published var panelStyle: PanelStyle { didSet { d.set(panelStyle.rawValue, forKey: "panelStyle") } }
    @Published var panelDarkness: Double { didSet { d.set(panelDarkness, forKey: "panelDarkness") } }
    @Published var captureMic: Bool { didSet { d.set(captureMic, forKey: "captureMic") } }
    @Published var captureSystemAudio: Bool { didSet { d.set(captureSystemAudio, forKey: "captureSystemAudio") } }
    @Published var separateMicVoices: Bool { didSet { d.set(separateMicVoices, forKey: "separateMicVoices") } }
    @Published var micSensitivity: MicSensitivity { didSet { d.set(micSensitivity.rawValue, forKey: "micSensitivity") } }
    @Published var asrEnglishOnly: Bool { didSet { d.set(asrEnglishOnly, forKey: "asrEnglishOnly") } }
    @Published var polishTranscript: Bool { didSet { d.set(polishTranscript, forKey: "polishTranscript") } }
    /// The context window local models (Farhelm, Ollama) are loaded with.
    @Published var localContextTokens: Int { didSet { d.set(localContextTokens, forKey: "localContextTokens") } }
    @Published var rememberAcross: Bool { didSet { d.set(rememberAcross, forKey: "rememberAcross") } }
    @Published var keepNotes: Bool { didSet { d.set(keepNotes, forKey: "keepNotes") } }
    @Published var hideFromScreenShare: Bool { didSet { d.set(hideFromScreenShare, forKey: "hideFromScreenShare") } }
    @Published var autoSuggest: Bool { didSet { d.set(autoSuggest, forKey: "autoSuggest") } }
    @Published var replyToQuestionsOnly: Bool { didSet { d.set(replyToQuestionsOnly, forKey: "replyToQuestionsOnly") } }
    @Published var sessionMode: SessionMode { didSet { d.set(sessionMode.rawValue, forKey: "sessionMode") } }
    @Published var setupDismissed: Bool { didSet { d.set(setupDismissed, forKey: "setupDismissed") } }
    /// The monitor screen answers read. 0 follows the mouse pointer.
    @Published var screenDisplayID: Int { didSet { d.set(screenDisplayID, forKey: "screenDisplayID") } }
    /// Seconds between looks at the screen while watching it.
    @Published var screenWatchInterval: Int { didSet { d.set(screenWatchInterval, forKey: "screenWatchInterval") } }
    /// Programs the agent may run without asking ("always allow").
    @Published var agentAllowed: [String] { didSet { d.set(agentAllowed, forKey: "agentAllowed") } }
    /// The letter that, with Cmd+Shift, opens the panel ready to type.
    @Published var askHotKey: String {
        didSet {
            d.set(askHotKey, forKey: "askHotKey")
            HotKeys.registerAsk(letter: askHotKey)
        }
    }
    /// Commands that only read run without asking.
    @Published var agentAutoApproveReads: Bool { didSet { d.set(agentAutoApproveReads, forKey: "agentAutoApproveReads") } }
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
        ollamaURL = d.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434"
        farhelmURL = d.string(forKey: "farhelmURL") ?? "http://127.0.0.1:7842/p/companion"
        farhelmModel = d.string(forKey: "farhelmModel") ?? ""
        panelStyle = PanelStyle(rawValue: d.string(forKey: "panelStyle") ?? "") ?? .frosted
        panelDarkness = d.object(forKey: "panelDarkness") as? Double ?? 0.3
        captureMic = d.object(forKey: "captureMic") as? Bool ?? true
        captureSystemAudio = d.object(forKey: "captureSystemAudio") as? Bool ?? true
        separateMicVoices = d.object(forKey: "separateMicVoices") as? Bool ?? false
        micSensitivity = MicSensitivity(rawValue: d.string(forKey: "micSensitivity") ?? "") ?? .medium
        asrEnglishOnly = d.object(forKey: "asrEnglishOnly") as? Bool ?? false
        polishTranscript = d.object(forKey: "polishTranscript") as? Bool ?? true
        localContextTokens = d.object(forKey: "localContextTokens") as? Int ?? 32_000
        rememberAcross = d.object(forKey: "rememberAcross") as? Bool ?? true
        keepNotes = d.object(forKey: "keepNotes") as? Bool ?? true
        hideFromScreenShare = d.object(forKey: "hideFromScreenShare") as? Bool ?? true
        autoSuggest = d.object(forKey: "autoSuggest") as? Bool ?? true
        replyToQuestionsOnly = d.object(forKey: "replyToQuestionsOnly") as? Bool ?? true
        sessionMode = SessionMode.current
        setupDismissed = d.bool(forKey: "setupDismissed")
        screenDisplayID = d.integer(forKey: "screenDisplayID")
        screenWatchInterval = d.object(forKey: "screenWatchInterval") as? Int ?? 3
        agentAllowed = d.stringArray(forKey: "agentAllowed") ?? []
        askHotKey = d.string(forKey: "askHotKey") ?? "K"
        agentAutoApproveReads = d.object(forKey: "agentAutoApproveReads") as? Bool ?? true
        agentDirectory = d.string(forKey: "agentDirectory") ?? NSHomeDirectory()
        voiceCommands = d.object(forKey: "voiceCommands") as? Bool ?? true
        autoScreenWatch = d.object(forKey: "autoScreenWatch") as? Bool ?? false
        userDetails = ContextStore.shared.loadDetails()
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
