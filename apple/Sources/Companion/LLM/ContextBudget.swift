import Foundation

/// How much a request may carry, sized to the engine in use and to how
/// urgent the task is.
///
/// Every limit on prompt size comes from here, so supporting a model with a
/// bigger window, or a new kind of task, is a change in this one file.
///
/// Two things bound a request. The model's context window is the hard limit.
/// Within it, each task has a ceiling chosen for speed: a live reply has to
/// start within a second or two, so it stays small even when the model could
/// take far more, while the notes written after a conversation can use most
/// of the window. Local models read a long prompt much more slowly than
/// hosted ones, so their ceilings are lower.
struct ContextBudget {
    enum Task {
        /// A reply drafted while someone is talking. Speed first.
        case liveReply
        /// A typed question.
        case ask
        /// An answer about what is on screen.
        case screen
        /// Notes, recheck and other work nobody is waiting on.
        case longForm
    }

    /// Tokens the model accepts in one request.
    let window: Int
    /// A hosted API engine, which reads long prompts quickly.
    let hosted: Bool

    /// Hosted models' windows. Conservative defaults per provider; a model
    /// known to take more can be given its own line.
    private static let hostedWindows: [(prefix: String, tokens: Int)] = [
        ("claude", 200_000),
        ("gpt", 128_000),
        ("o", 128_000)
    ]

    /// The window sizes offered for local models.
    static let localChoices = [8_000, 16_000, 32_000, 64_000, 128_000]

    @MainActor
    static var current: ContextBudget {
        let settings = AppSettings.shared
        switch settings.provider {
        case .anthropic:
            return ContextBudget(window: hostedWindow(settings.anthropicModel, fallback: 200_000), hosted: true)
        case .openai:
            return ContextBudget(window: hostedWindow(settings.openAIModel, fallback: 128_000), hosted: true)
        case .farhelm, .ollama:
            return ContextBudget(window: max(settings.localContextTokens, 4_000), hosted: false)
        }
    }

    private static func hostedWindow(_ model: String, fallback: Int) -> Int {
        let name = model.lowercased()
        return hostedWindows.first { name.hasPrefix($0.prefix) }?.tokens ?? fallback
    }

    /// Characters per token, rounded down so estimates err on the safe side.
    private static let charactersPerToken = 3.5
    /// Instructions, the pinned details, notes and earlier answers.
    private static let fixedCharacters = 6_000

    /// Tokens of input the task may use.
    func inputTokens(_ task: Task) -> Int {
        // Leave room for the answer and for the estimate being off.
        let room = Int(Double(window) * 0.7)
        let ceiling: Int
        switch task {
        case .liveReply: ceiling = hosted ? 10_000 : 6_000
        case .ask, .screen: ceiling = hosted ? 40_000 : 14_000
        case .longForm: ceiling = hosted ? 150_000 : 60_000
        }
        return max(3_000, min(ceiling, room))
    }

    /// Characters left for the parts that vary in size.
    private func flexible(_ task: Task) -> Int {
        max(4_000, Int(Double(inputTokens(task)) * Self.charactersPerToken) - Self.fixedCharacters)
    }

    /// Passages from the user's details, files and memories.
    func knowledgeCharacters(_ task: Task) -> Int {
        let share: Double
        switch task {
        case .liveReply: share = 0.55
        case .ask: share = 0.60
        case .screen: share = 0.35
        case .longForm: share = 0.10
        }
        return Int(Double(flexible(task)) * share)
    }

    /// The conversation transcript.
    func transcriptCharacters(_ task: Task) -> Int {
        let share: Double
        switch task {
        case .liveReply: share = 0.45
        case .ask: share = 0.40
        case .screen: share = 0.25
        case .longForm: share = 0.85
        }
        return Int(Double(flexible(task)) * share)
    }

    /// Transcript lines worth passing along (a line averages about 140 characters).
    func transcriptLines(_ task: Task) -> Int {
        max(20, transcriptCharacters(task) / 140)
    }

    /// Text read off the screen.
    var screenCharacters: Int {
        min(60_000, Int(Double(flexible(.screen)) * 0.40))
    }

    /// The longest answer the model may write, in tokens.
    func answerTokens(_ task: Task) -> Int {
        switch task {
        case .liveReply: return 500
        case .ask, .screen: return hosted ? 2_000 : 1_200
        case .longForm: return hosted ? 3_000 : 2_000
        }
    }

    /// For Settings: what this engine gets, in plain words.
    var summary: String {
        func thousands(_ tokens: Int) -> String { "\(tokens / 1000)k" }
        return "Model window \(thousands(window)) tokens. Companion sends up to about \(thousands(inputTokens(.liveReply))) for a live reply, \(thousands(inputTokens(.ask))) for a typed or screen question, and \(thousands(inputTokens(.longForm))) for notes and recheck."
    }
}
