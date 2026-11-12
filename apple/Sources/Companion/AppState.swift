import Foundation
import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers
import WebKit
import os

enum Speaker: Hashable {
    case me, them
}

struct TranscriptSegment: Identifiable, Equatable {
    /// Tag of a mic utterance whose speaker hasn't been identified yet.
    static let pendingTag = "…"

    let id: UUID
    let utteranceID: UUID
    var speaker: Speaker
    var tag: String?
    var text: String
    var isFinal: Bool
    var seq: Int
    let timestamp: Date
    /// What was heard before polishing. Non-nil means this line has been
    /// through the polish pass (even if the wording did not change).
    var original: String? = nil
    /// The polish pass decided from context that the automatic speaker label
    /// was wrong and changed it.
    var speakerCorrected = false
    /// Heard on the system-audio channel. Such a line is certainly not the
    /// user, so its speaker is never reassigned to Me.
    var systemAudio = false
    /// Where this was said on the mic stream (samples), and in which
    /// listening session, so its speaker can be rechecked from the audio.
    var micStart: Int?
    var micEnd: Int?
    var micSession = 0
    /// The speaker was settled from the recorded voice by the recheck, so the
    /// text-based pass must not change it.
    var voiceVerified = false
    /// The user set this line's speaker by clicking its badge. No automatic
    /// pass changes it again.
    var speakerByHand = false
}

/// Set by whichever of two racing pieces of work finishes first.
private final class OnceFlag {
    var done = false
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    private let log = Logger(subsystem: "com.harshsah.companion", category: "app")

    // Listening
    @Published var isListening = false
    @Published var statusText = "Ready"
    @Published var modelReady = false
    @Published var segments: [TranscriptSegment] = []
    @Published var lastError: String?
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var voiceEnrolled = false
    @Published var isEnrollingVoice = false
    /// How many public "other people" voices the voice check has learned
    /// from, and the progress line while more are being added.
    @Published var referenceVoices = 0
    @Published var referenceImport: String?
    // Guided voice setup
    @Published var enrollStep = 0
    @Published var enrollStepProgress: Double = 0
    @Published var enrollLevel: Float = 0
    @Published var enrollMessage: String?
    @Published var enrollSucceeded = false

    // Conversation workspace
    @Published var conversation = Conversation()
    @Published var history: [ConversationSummary] = []
    @Published var showHistory = false
    /// The agent's checklist for the task it is on.
    private var agentPlan: [PlanItem] = []
    /// Attachments added since the last message was sent. They show in the
    /// chat box while you write; once sent they live in Details, and stay
    /// available to the chat from there.
    @Published var pendingAttachments: [UUID] = []
    /// The column on the right of the chat: details of the session, or the
    /// browser. nil when it is closed.
    @Published var sidePanel: SidePanelMode?
    /// The right column (the browser or the workspace) has the whole panel,
    /// with the chat out of the way until it is asked for again.
    @Published var sideFull = false
    /// Widths of the columns beside the chat. Dragging a divider changes
    /// them, and they are kept between launches.
    @Published var sidebarWidth: CGFloat = AppState.savedWidth("sidebarWidth", 236)
    @Published var detailsWidth: CGFloat = AppState.savedWidth("detailsWidth", SidePanelMode.details.width)
    @Published var browserWidth: CGFloat = AppState.savedWidth("browserWidth", SidePanelMode.browser.width)
    @Published var workspaceWidth: CGFloat = AppState.savedWidth("workspaceWidth", SidePanelMode.workspace.width)
    /// In code, the chat is a column on the right of the editor; this is
    /// how wide it is.
    @Published var codeChatWidth: CGFloat = AppState.savedWidth("codeChatWidth", 380)

    private static func savedWidth(_ key: String, _ usual: CGFloat) -> CGFloat {
        let saved = UserDefaults.standard.double(forKey: key)
        return saved >= 150 && saved <= 4000 ? CGFloat(saved) : usual
    }

    /// The width the right column has in a mode.
    func width(of mode: SidePanelMode) -> CGFloat {
        switch mode {
        case .details: return detailsWidth
        case .browser: return browserWidth
        case .workspace: return workspaceWidth
        }
    }

    func setWidth(_ width: CGFloat, of mode: SidePanelMode) {
        switch mode {
        case .details: detailsWidth = width
        case .browser: browserWidth = width
        case .workspace: workspaceWidth = width
        }
    }

    /// The workspace beside the chat: files, editor, search, changes, terminal.
    lazy var workspace = WorkspaceModel()
    /// The folder the workspace shows: the one attached to this chat, or
    /// the agent's working folder when none is.
    var workspaceRoot: String { agentStartDirectory }

    func saveColumnWidths() {
        UserDefaults.standard.set(Double(sidebarWidth), forKey: "sidebarWidth")
        UserDefaults.standard.set(Double(detailsWidth), forKey: "detailsWidth")
        UserDefaults.standard.set(Double(workspaceWidth), forKey: "workspaceWidth")
        UserDefaults.standard.set(Double(browserWidth), forKey: "browserWidth")
        UserDefaults.standard.set(Double(codeChatWidth), forKey: "codeChatWidth")
    }
    /// Pages visited, for the suggestions on a new tab. Shared by every
    /// chat's browser.
    private lazy var webHistory = BrowserHistory(directory: ContextStore.shared.baseDir)
    /// The code side of the app is in use, rather than plain chat.
    @Published var codeMode = false
    /// A browser session for each chat that has opened one: its own tabs
    /// and its own sign-ins, apart from every other chat's. Sessions are
    /// kept in memory only, so they all end when the app quits.
    private var webSessions: [UUID: BrowserModel] = [:]
    /// The browser session of the chat that is showing. Its tabs survive
    /// closing the pane and switching to another chat and back.
    var web: BrowserModel {
        if let session = webSessions[conversation.id] { return session }
        let session = BrowserModel(history: webHistory)
        let id = conversation.id
        session.onRunning = { [weak self] running in
            if running { self?.webRunning.insert(id) } else { self?.webRunning.remove(id) }
        }
        webSessions[id] = session
        return session
    }
    /// The chats whose browser session has a page open right now, for the
    /// mark on the browser button and beside the chat in the list.
    @Published private(set) var webRunning = Set<UUID>()
    /// Ends a chat's browser session, when the chat itself goes.
    private func endWebSession(of id: UUID) {
        webSessions.removeValue(forKey: id)?.end()
        webRunning.remove(id)
    }
    /// A question the agent is waiting on, with its choices.
    @Published var pendingQuestion: AgentQuestion?
    private var questionAnswer: CheckedContinuation<String?, Never>?
    /// The sidebar of conversations is pinned open beside the chat.
    @Published var sidebarPinned = false
    /// Settings are shown inside the panel, in place of the conversation.
    @Published var showSettings = false
    /// What the history list is filtered by.
    @Published var historyQuery = ""
    /// The panel is shrunk to a strip with just the newest answer.
    @Published var compact = false
    /// In pill mode, the pill is opened up for now (the pointer is on it).
    @Published var pillExpanded = false
    /// The panel is enlarged to fill most of the screen.
    @Published var zoomed = false
    /// The agent is reading the screen and deciding what to do next.
    @Published var isPlanning = false
    /// What the agent has done on the current task, newest last.
    @Published var agentLog: [String] = []
    /// The task the agent is working on.
    @Published var agentTask: String?
    private var agentRun: Task<Void, Never>?
    /// The chat turn that shows the current task and its outcome.
    private var agentTurnID: UUID?
    /// Bumped to ask the panel to put the cursor in the input box.
    @Published var focusInputRequest = 0
    /// What the agent is doing between steps, for the bar above the input.
    @Published var agentStatus: String?
    /// An agent task is in progress. The one flag the interface goes by:
    /// while it is true there is a Stop button, and when the task ends for
    /// any reason (done, failed, denied, timed out, stopped) it goes false.
    @Published var agentRunning = false
    /// Counts tasks, so a task that was force-stopped cannot touch the
    /// state of the one that came after it.
    private var agentGeneration = 0
    /// Works out next-step suggestions after a task; never blocks a new one.
    private var followUpTask: Task<Void, Never>?
    /// Bumped when a step succeeds or fails, to drive the checkmark and shake.
    @Published var stepSuccesses = 0
    @Published var stepFailures = 0
    /// Steps the agent wants to take, waiting for the user's yes or no.
    @Published var pendingApproval: AgentProposal?
    private var approval: CheckedContinuation<AgentDecision, Never>?
    /// What the model is told has happened so far, results included.
    private var agentContext: [String] = []
    /// What the agent last told the user, so the follow-up does not repeat it.
    private var lastAgentReport = ""
    /// The report from a task that ended before it was complete: what was
    /// done and what is still left. The next task in the same chat is given
    /// it, so "continue" picks up where the work stopped. Nothing resumes
    /// by itself.
    private var unfinishedReport = ""
    /// The end of each command's output, by its place in `agentLog`.
    private var agentOutputs: [Int: String] = [:]

    /// The agent's record for the other prompts, so every answer agrees
    /// with what actually happened: steps done with their results, and the
    /// steps still waiting for a yes.
    private var agentActivity: String {
        var lines = agentContext.suffix(8).map { "Done: \(String($0.prefix(500)))" }
        if let waiting = pendingApproval {
            lines.append(contentsOf: waiting.steps.map { "Waiting for my approval, not run yet: \($0.label)" })
        }
        return lines.joined(separator: "\n")
    }
    /// Companion is typing or pressing keys right now.
    @Published var isActing = false
    /// Why no reply was drafted for what was just heard, in plain words.
    @Published var replyHint: String?
    @Published var draft = ""
    @Published var attachScreen = false
    @Published var streamingTurns: Set<UUID> = []
    /// Automatic replies whose question may still be unfinished. Such a reply
    /// is a draft; it is confirmed once the question is complete.
    @Published var draftTurns: Set<UUID> = []
    /// Answers being re-checked in the background. They stay on screen as
    /// they are, with no "thinking" effect, and change only if the new
    /// version really differs.
    @Published var quietTurns: Set<UUID> = []
    private var lastReadingAt = Date.distantPast
    /// When each answer's text first appeared. Only speech that began after
    /// that can be a reading of it.
    private var answerStartedAt: [UUID: Date] = [:]
    @Published var replySpokenWords = 0
    @Published var screenSpokenWords = 0
    @Published var farhelmModels: [String] = []
    /// Models the Anthropic key can use; suggestions until the list loads.
    @Published var anthropicModels: [String] = ModelCatalog.anthropicSuggestions
    @Published var anthropicModelsStatus: String?
    @Published var hasUnseen = false
    @Published var isSummarizing = false
    @Published var isWritingUp = false
    @Published var notesError: String?
    @Published var isRescanning = false
    @Published var canUndoRescan = false
    /// The transcript line the recheck is looking at right now.
    @Published var rescanningID: UUID?
    /// How far the recheck has got, e.g. "7/40".
    @Published var rescanProgress = ""

    // Windows
    @Published var panelVisible = false {
        didSet { if panelVisible { hasUnseen = false } }
    }
    /// Where the click-through button sits in the panel (from its top
    /// left), so a click on it can be recognised while the panel itself
    /// ignores the mouse.
    var clickThroughButtonFrame: CGRect = .zero
    @Published var clickThrough = false {
        didSet { overlay?.applyClickThrough(clickThrough) }
    }

    var overlay: OverlayController?
    let store = ConversationStore()

    private let transcriber = Transcriber()
    private let speakerID = SpeakerID()
    private let suggester = SuggestionEngine()
    private let mic = MicCapture()
    private let system = SystemAudioCapture()
    private let micChunker = SpeechChunker()
    private let systemChunker = SpeechChunker()
    private var screenWatcher: ScreenWatcher?
    private var partialInFlight: Set<Speaker> = []
    private var tasks: [TurnKind: Task<Void, Never>] = [:]
    private var runningTurn: [TurnKind: UUID] = [:]
    private var activeKind: TurnKind = .reply
    private var spokenCommitted = 0
    private var trackedUtterance: UUID?
    private var autoSuggestWork: Task<Void, Never>?
    private var teardown: Task<Void, Never>?
    private var voiceSessionOutcome: Bool?
    private var enrollTask: Task<Void, Never>?
    private var polishWork: Task<Void, Never>?
    private var isPolishing = false
    /// Last transcript line already folded into the running notes.
    private var lastSummarizedID: UUID?
    /// What the last recheck replaced, so it can be undone.
    private var rescanUndo: (current: [UUID], original: [TranscriptSegment])?
    private var rescanTask: Task<Void, Never>?
    /// The by-voice pass that runs by itself while listening.
    private var voicePassTask: Task<Void, Never>?
    private var voicePassBusy = false
    private var polishBackoffUntil = Date.distantPast
    private var bag = Set<AnyCancellable>()
    /// Last identified voice on the mic, so short or ambiguous utterances can
    /// inherit it instead of defaulting to the user.
    private var lastMicLabel: (speaker: Speaker, tag: String?, at: Date)?
    /// The "their turn" the newest automatic reply belongs to.
    private var lastAutoRunKey: UUID?
    private var lastAutoTurnID: UUID?
    private var lastAutoQuestion = ""
    /// Everything the others said up to this moment is covered by a reply
    /// the user has already started saying.
    private var autoSettledBefore: Date?
    /// The listening session mic lines currently belong to.
    private var micSessionID = 0
    /// After a recheck by voice: what each live label turned out to be, so
    /// the rest of the session uses the same names.
    private var voiceRemap: [String: (speaker: Speaker, tag: String?)] = [:]
    /// Questions already answered automatically, newest last, so the same
    /// question is never generated twice.
    private var answeredQuestions: [(question: String, turnID: UUID)] = []
    /// Lines the recheck has already been through.
    private var recheckedIDs: Set<UUID> = []
    /// The transcript the current write-up was made from.
    private var writeUpSignature: Int?

    private init() {
        wirePipelines()
        AppSettings.shared.$autoScreenWatch
            .removeDuplicates()
            .sink { [weak self] enabled in
                Task { @MainActor in
                    if enabled { self?.startScreenWatcher() } else { self?.stopScreenWatcher() }
                }
            }
            .store(in: &bag)
        AppSettings.shared.$separateMicVoices
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                // Voice separation is set up when listening starts, so apply
                // the change by restarting the session.
                Task { @MainActor in
                    guard let self, self.isListening else { return }
                    self.stop()
                    self.start()
                }
            }
            .store(in: &bag)
        AppSettings.shared.$asrEnglishOnly
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                // A different speech model: reload it by restarting the session.
                Task { @MainActor in
                    guard let self else { return }
                    self.modelReady = false
                    guard self.isListening else {
                        self.preloadSpeechModel()
                        return
                    }
                    self.stop()
                    self.start()
                }
            }
            .store(in: &bag)
        AppSettings.shared.$micSensitivity
            .removeDuplicates()
            .sink { [weak self] level in
                Task { @MainActor in self?.micChunker.vadFloor = level.vadFloor }
            }
            .store(in: &bag)
        Task { @MainActor in
            voiceEnrolled = await speakerID.enrolled()
            referenceVoices = await speakerID.referenceVoiceCount()
        }
        suggester.attachedFiles = { [weak self] in self?.attachments ?? [] }
        suggester.conversationID = { [weak self] in self?.conversation.id }
        suggester.agentActivity = { [weak self] in self?.agentActivity ?? "" }
        // Memories recalled for a request are noted on the conversation
        // they were recalled for.
        KnowledgeIndex.shared.onMemoriesUsed = { [weak self] items in
            guard let self else { return }
            var used = self.conversation.usedMemories ?? []
            for item in items where !used.contains(item.text) {
                used.append(item.text)
            }
            if used != (self.conversation.usedMemories ?? []) {
                self.conversation.usedMemories = Array(used.suffix(30))
            }
        }
        suggester.sourcesUsed = { [weak self] sources in
            guard let self else { return }
            var used = self.conversation.usedSources ?? []
            for source in sources where !used.contains(source) {
                used.append(source)
            }
            if used != (self.conversation.usedSources ?? []) {
                self.conversation.usedSources = used
            }
        }
        suggester.conversationNotes = { [weak self] in self?.conversation.summary ?? "" }
        suggester.earlierTurns = { [weak self] in
            guard let self else { return [] }
            // Not the turn being written right now, and not suggestions the
            // user chose not to say: those are not part of what was said.
            return self.conversation.turns.filter {
                !self.streamingTurns.contains($0.id) && self.usage(of: $0) != .unused && $0.matched != false
            }
        }
        refreshHistory()
        loadFarhelmModels()
        if AppSettings.shared.provider == .anthropic {
            loadAnthropicModels()
        }
        preloadSpeechModel()
    }

    var isReplying: Bool {
        conversation.turns.contains { $0.kind == .reply && streamingTurns.contains($0.id) }
    }

    var isAnsweringScreen: Bool {
        conversation.turns.contains { $0.kind == .screen && streamingTurns.contains($0.id) }
    }

    /// The engine a new turn will use, e.g. "Farhelm · auto".
    var engineLabel: String {
        let settings = AppSettings.shared
        switch settings.provider {
        case .farhelm:
            return settings.farhelmModel.isEmpty ? "Farhelm · auto" : "Farhelm · \(settings.farhelmModel)"
        case .anthropic:
            return "Claude · \(settings.anthropicModel)"
        case .openai:
            return "OpenAI · \(settings.openAIModel)"
        case .ollama:
            return "Ollama · \(settings.ollamaModel)"
        case .subscription:
            let agents = CLIAgents.shared
            let name = agents.name(of: settings.cliAgent)
            if settings.cliModel.isEmpty {
                return agents.version(of: "", for: settings.cliAgent).map { "\(name) · \($0)" } ?? name
            }
            return "\(name) · \(agents.title(of: settings.cliModel, for: settings.cliAgent))"
        }
    }

    // MARK: - Listening

    func toggleListening() {
        isListening ? stop() : start()
    }

    func start() {
        guard !isListening else { return }
        let settings = AppSettings.shared
        guard settings.captureMic || settings.captureSystemAudio else {
            lastError = "Enable at least one audio source in Settings > Listening."
            return
        }
        lastError = nil
        isListening = true
        statusText = "Starting"
        Task { @MainActor in
            await teardown?.value
            if settings.captureMic {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard granted else {
                    failStart("Microphone access denied. Enable Companion in System Settings > Privacy & Security > Microphone.")
                    return
                }
            }
            do {
                // Normally already loaded at launch; this then returns at once.
                if !modelReady {
                    statusText = "Loading speech model"
                }
                try await prepareSpeechModel()
                guard isListening else { return }
                if settings.captureMic {
                    if settings.separateMicVoices, voiceEnrolled {
                        statusText = "Preparing voice separation"
                        // Never let this hold up the microphone: its model
                        // downloads on first use, which can take a while.
                        let separationReady = await startVoiceSession(timeout: 8)
                        if !separationReady {
                            lastError = "Voice separation is not ready yet (its model downloads on first use). Listening continues without it, so everything on the mic shows as You for now. Stop and start listening again in a minute to use it."
                        }
                        guard isListening else { return }
                        micSessionID = 0
                        if separationReady {
                            micSessionID = await speakerID.sessionID()
                            startVoicePasses()
                        }
                        voiceRemap = [:]
                    }
                    micChunker.reset()
                    try mic.start()
                }
                if settings.captureSystemAudio {
                    do {
                        try await system.start()
                    } catch {
                        log.error("system audio: \(error.localizedDescription)")
                        lastError = "System audio unavailable. Grant Screen Recording to Companion in System Settings > Privacy & Security, then relaunch. Mic still works."
                    }
                }
                statusText = "Listening"
            } catch {
                failStart("Could not start: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        isListening = false
        statusText = "Ready"
        autoSuggestWork?.cancel()
        voicePassTask?.cancel()
        mic.stop()
        // Kept so a start() right after this stop waits for the teardown
        // instead of racing it.
        teardown = Task {
            await system.stop()
            await speakerID.endSession()
        }
        micChunker.reset()
        systemChunker.reset()
        micLevel = 0
        systemLevel = 0
        // Whatever was mid-sentence is as final as it will get.
        for index in segments.indices where !segments[index].isFinal {
            segments[index].isFinal = true
            if segments[index].tag == TranscriptSegment.pendingTag {
                segments[index].tag = nil
            }
        }
        schedulePolish()
        persist()
        // The conversation is over: write it up for later, once the last
        // lines have had their polish.
        if AppSettings.shared.keepNotes, segments.count >= 6 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !self.isListening else { return }
                self.writeUpRecord(auto: true)
            }
        }
    }

    private func failStart(_ message: String) {
        isListening = false
        statusText = "Ready"
        lastError = message
    }

    /// Loads the speech model (a download only the very first time) and shows
    /// what it is doing in the status line while not yet listening.
    private func prepareSpeechModel() async throws {
        let usingFallback = try await transcriber.prepare(englishOnly: AppSettings.shared.asrEnglishOnly) { [weak self] text in
            Task { @MainActor in
                guard let self, self.statusText != "Listening" else { return }
                self.statusText = text
            }
        }
        modelReady = true
        if usingFallback {
            lastError = "The English-only speech model is downloading in the background. The multilingual model is used until it is ready, so listening is not held up."
        }
    }

    /// Loads the speech model as soon as the app starts, so pressing play
    /// does not wait on it.
    private func preloadSpeechModel() {
        Task { @MainActor in
            if !isListening { statusText = "Loading speech model" }
            do {
                try await prepareSpeechModel()
                if !isListening { statusText = "Ready" }
            } catch {
                if !isListening {
                    statusText = "Ready"
                    lastError = "The speech model could not be loaded: \(error.localizedDescription). It needs a network connection the first time."
                }
            }
        }
    }

    /// Starts the voice-separation session, giving up after `timeout` seconds.
    private func startVoiceSession(timeout: Double) async -> Bool {
        voiceSessionOutcome = nil
        Task { @MainActor in
            self.voiceSessionOutcome = await self.speakerID.startSession()
        }
        var waited = 0.0
        while waited < timeout {
            if let outcome = voiceSessionOutcome { return outcome }
            try? await Task.sleep(nanoseconds: 150_000_000)
            waited += 0.15
        }
        await speakerID.abandonStart()
        return false
    }

    // MARK: - Transcription pipeline

    private func wirePipelines() {
        mic.onFailure = { [weak self] message in
            Task { @MainActor in self?.lastError = message }
        }
        mic.onSamples = { [weak self] samples in
            // The chunker and the diarizer must see the same samples in the
            // same order: utterance positions are looked up on that clock.
            self?.micChunker.feed(samples)
            self?.speakerID.ingest(samples)
        }
        system.onSamples = { [weak self] samples in self?.systemChunker.feed(samples) }
        system.onStopped = { [weak self] error in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                // The capture stream can end on its own (display sleep, a
                // permission re-check). Bring it back instead of going deaf.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.isListening else { return }
                do {
                    try await self.system.start()
                } catch {
                    self.lastError = "System audio stopped and could not restart: \(error.localizedDescription)"
                }
            }
        }
        micChunker.onLevel = { [weak self] level in
            Task { @MainActor in self?.micLevel = level }
        }
        systemChunker.onLevel = { [weak self] level in
            Task { @MainActor in self?.systemLevel = level }
        }
        micChunker.onChunk = { [weak self] chunk in self?.handleChunk(chunk, speaker: .me) }
        systemChunker.onChunk = { [weak self] chunk in self?.handleChunk(chunk, speaker: .them) }
    }

    nonisolated private func handleChunk(_ chunk: SpeechChunk, speaker: Speaker) {
        Task { @MainActor in
            if chunk.samples.isEmpty {
                self.applyTranscription("", chunk: chunk, speaker: speaker)
                return
            }
            if !chunk.isFinal {
                guard !self.partialInFlight.contains(speaker) else { return }
                self.partialInFlight.insert(speaker)
            }
            do {
                let text = try await self.transcriber.transcribe(chunk.samples)
                var resolved = speaker
                var tag: String?
                if speaker == .me {
                    (resolved, tag) = await self.resolveMicSpeaker(text: text, chunk: chunk)
                }
                self.applyTranscription(text, chunk: chunk, speaker: resolved, tag: tag, fromMic: speaker == .me)
            } catch {
                self.log.error("transcribe: \(error.localizedDescription)")
            }
            if !chunk.isFinal {
                self.partialInFlight.remove(speaker)
            }
        }
    }

    private func applyTranscription(_ raw: String,
                                    chunk: SpeechChunk,
                                    speaker: Speaker,
                                    tag: String? = nil,
                                    fromMic: Bool = false) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if chunk.isFinal {
                segments.removeAll { $0.utteranceID == chunk.utteranceID && !$0.isFinal }
            }
            return
        }
        // The mic also hears the Mac's speakers. If this repeats what system
        // audio just delivered, it is that leak, not a new speaker.
        if fromMic, isEchoOfSystemAudio(text) {
            segments.removeAll { $0.utteranceID == chunk.utteranceID }
            return
        }
        // "Um", "mm-hm" and the like on their own are noise in a transcript.
        if chunk.isFinal, Self.isFillerOnly(text) {
            segments.removeAll { $0.utteranceID == chunk.utteranceID }
            return
        }
        // Reading a suggested answer aloud: that is the user, whatever the
        // voice model thinks.
        var speaker = speaker
        var tag = tag
        if fromMic, readingKind(text, heardAt: firstHeard(chunk.utteranceID)) != nil {
            speaker = .me
            tag = nil
            lastReadingAt = Date()
        }
        if let index = segments.lastIndex(where: { $0.utteranceID == chunk.utteranceID }) {
            guard chunk.isFinal || chunk.seq > segments[index].seq else { return }
            segments[index].text = text
            segments[index].isFinal = chunk.isFinal
            segments[index].seq = chunk.seq
            segments[index].speaker = speaker
            segments[index].tag = tag
            if fromMic {
                segments[index].micStart = chunk.startSample
                segments[index].micEnd = chunk.endSample
            }
        } else {
            segments.append(TranscriptSegment(id: UUID(),
                                              utteranceID: chunk.utteranceID,
                                              speaker: speaker,
                                              tag: tag,
                                              text: text,
                                              isFinal: chunk.isFinal,
                                              seq: chunk.seq,
                                              timestamp: Date(),
                                              systemAudio: !fromMic,
                                              micStart: fromMic ? chunk.startSample : nil,
                                              micEnd: fromMic ? chunk.endSample : nil,
                                              micSession: fromMic ? micSessionID : 0))
            if segments.count > Self.maxSegments {
                segments.removeFirst(segments.count - 200)
            }
        }
        if speaker == .me, tag == nil {
            updateReadingProgress(text, utterance: chunk.utteranceID, isFinal: chunk.isFinal)
        }
        // A spoken yes or no answers the agent's pending question.
        if chunk.isFinal, fromMic, AppSettings.shared.voiceCommands, pendingApproval != nil,
           let decision = Self.spokenDecision(text) {
            decide(decision)
            return
        }
        // "Companion, open Safari and search for ..." is a task, not conversation.
        if chunk.isFinal, fromMic, AppSettings.shared.voiceCommands, let task = Self.voiceCommand(in: text) {
            autoSuggestWork?.cancel()
            runAgent(task)
            return
        }
        if chunk.isFinal, speaker == .them {
            if AppSettings.shared.autoSuggest {
                scheduleAutoSuggest()
            } else {
                replyHint = "Replies are off. Turn Reply on, or press the bolt to draft one."
            }
        }
        if chunk.isFinal {
            schedulePolish()
        }
    }

    /// "Allow", "approve", "go ahead", "deny": a short spoken answer to the
    /// agent's question. Longer speech is conversation, not an answer.
    private static func spokenDecision(_ text: String) -> AgentDecision? {
        let words = normalizedWords(text)
        guard !words.isEmpty, words.count <= 4 else { return nil }
        // Only words that are clearly meant for the agent: an "okay" or
        // "yes" in the conversation must never approve a command.
        let said = words.joined(separator: " ")
        if words.contains("deny") || words.contains("denied") || said == "cancel" || said == "stop" { return .deny }
        if words.contains("allow") || words.contains("approve") || words.contains("approved") || said == "go ahead" {
            return .allow
        }
        return nil
    }

    /// The task in speech addressed to the agent: what follows "Companion"
    /// (or "Hey Companion") at the start of an utterance.
    private static func voiceCommand(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for wake in ["hey companion", "ok companion", "okay companion", "companion"] where lower.hasPrefix(wake) {
            let rest = trimmed.dropFirst(wake.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!-"))
            return normalizedWords(rest).count >= 2 ? rest : nil
        }
        return nil
    }

    func clearTranscript() {
        polishWork?.cancel()
        rescanTask?.cancel()
        segments = []
        lastError = nil
        rescanUndo = nil
        canUndoRescan = false
    }

    // MARK: - Recheck: who said what, and where it belongs

    /// Goes through the recent transcript one line at a time, from the newest
    /// line back to the oldest, and redoes each against the conversation around
    /// it: who said it, whether it holds two people's speech, and how it
    /// should read (misheard words fixed, written clearly). Each fix is
    /// applied as soon as it is found, so the transcript corrects itself line
    /// by line and the recheck can be stopped at any point. What was heard is
    /// kept behind the wand, and the whole run can be undone.
    func rescanTranscript() {
        guard !isRescanning else { return }
        let recent = Array(segments.filter(\.isFinal).suffix(40))
        guard recent.count >= 2 else {
            lastError = "Not enough conversation to recheck yet."
            return
        }
        // Lines a previous recheck already went through are not redone. When
        // there is nothing new, pressing Recheck again redoes all of it.
        // The scope stays one unbroken stretch so it can be undone in place.
        let firstNew = recent.firstIndex { !recheckedIDs.contains($0.id) }
        let scope = firstNew.map { Array(recent[$0...]) } ?? recent
        polishWork?.cancel()
        isRescanning = true
        lastError = nil
        rescanProgress = "0/\(scope.count)"
        rescanTask = Task { @MainActor in
            // Undo restores every settled line as it stands now.
            let snapshot = self.segments.filter(\.isFinal)
            var current = snapshot.map(\.id)
            var changed = false
            // First by voice: the recorded audio says who was speaking more
            // reliably than the wording does.
            if self.voiceEnrolled, AppSettings.shared.separateMicVoices {
                self.rescanProgress = "voices"
                if await self.relabelByVoice() {
                    changed = true
                    self.rescanUndo = (current: current, original: snapshot)
                    self.canUndoRescan = true
                }
            }
            for (step, id) in scope.map(\.id).reversed().enumerated() {
                if Task.isCancelled { break }
                self.rescanProgress = "\(step + 1)/\(scope.count)"
                let finals = self.segments.filter(\.isFinal)
                guard let position = finals.firstIndex(where: { $0.id == id }) else { continue }
                let line = finals[position]
                self.rescanningID = id
                // Lines after it have already been rechecked, so each line is
                // judged against corrected context.
                let before = Array(finals[max(0, position - 6)..<position])
                let after = Array(finals[(position + 1)..<min(finals.count, position + 5)])
                do {
                    let output = try await self.suggester.recheckLine(line, before: before, after: after)
                    if Task.isCancelled { break }
                    var parsed = Self.parseTranscript(output)
                    // Speech from the system-audio channel is never the user's.
                    if line.systemAudio {
                        for index in parsed.indices where parsed[index].speaker == .me {
                            parsed[index].speaker = line.speaker
                            parsed[index].tag = line.tag
                        }
                    }
                    // Settled from the audio: only the wording is open.
                    if line.voiceVerified, !parsed.isEmpty {
                        parsed = [(speaker: line.speaker, tag: line.tag,
                                   text: parsed.map(\.text).joined(separator: " "))]
                    }
                    let heard = line.original ?? line.text
                    let joined = parsed.map(\.text).joined(separator: " ")
                    // A rewrite, not a different utterance.
                    guard !parsed.isEmpty, parsed.count <= 3,
                          Self.acceptablePolish(joined, for: heard) else { continue }
                    if parsed.count == 1, parsed[0].speaker == line.speaker, parsed[0].tag == line.tag,
                       parsed[0].text == line.text {
                        self.recheckedIDs.insert(id)
                        continue // already right
                    }
                    guard let index = self.segments.firstIndex(where: { $0.id == id }) else { continue }
                    let single = parsed.count == 1
                    let rebuilt = parsed.map { piece in
                        TranscriptSegment(id: UUID(),
                                          utteranceID: UUID(),
                                          speaker: piece.speaker,
                                          tag: piece.tag,
                                          text: piece.text,
                                          isFinal: true,
                                          seq: Int.max,
                                          timestamp: line.timestamp,
                                          // What was heard stays behind the wand. Having it
                                          // set also keeps the polish pass off this line.
                                          original: single ? heard : piece.text,
                                          speakerCorrected: line.speakerCorrected
                                              || piece.speaker != line.speaker || piece.tag != line.tag,
                                          systemAudio: line.systemAudio,
                                          micStart: single ? line.micStart : nil,
                                          micEnd: single ? line.micEnd : nil,
                                          micSession: single ? line.micSession : 0,
                                          voiceVerified: single && line.voiceVerified)
                    }
                    self.segments.replaceSubrange(index...index, with: rebuilt)
                    self.recheckedIDs.formUnion(rebuilt.map(\.id))
                    if let slot = current.firstIndex(of: id) {
                        current.replaceSubrange(slot...slot, with: rebuilt.map(\.id))
                    }
                    changed = true
                    self.rescanUndo = (current: current, original: snapshot)
                    self.canUndoRescan = true
                } catch {
                    if !Task.isCancelled {
                        self.lastError = error.localizedDescription
                    }
                    break
                }
            }
            self.rescanningID = nil
            // Then the replies: do they still match what was actually said?
            if !Task.isCancelled {
                self.rescanProgress = "replies"
                await self.verifyReplies()
            }
            self.isRescanning = false
            self.rescanProgress = ""
            if changed {
                self.afterTranscriptRearranged()
                self.persist()
                // The write-up should say what the corrected transcript says.
                if !Task.isCancelled, self.conversation.record != nil {
                    self.writeUpRecord(auto: true)
                }
            }
        }
    }

    /// While listening, the accurate by-voice pass (the one Recheck uses)
    /// runs by itself every so often and quietly corrects who said what. The
    /// live labels are a first guess made on the spot; this pass hears the
    /// whole session before deciding, and what it finds also teaches the
    /// live check. It only runs when there is something new to check, and
    /// backs off as a long session makes each pass take longer.
    private func startVoicePasses() {
        voicePassTask?.cancel()
        voicePassTask = Task { @MainActor [weak self] in
            var wait: TimeInterval = 45
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard let self, !Task.isCancelled, self.isListening else { return }
                let session = self.micSessionID
                guard AppSettings.shared.autoVoiceRecheck, !self.isRescanning, session != 0 else { continue }
                let fresh = self.segments.contains {
                    $0.isFinal && !$0.systemAudio && $0.micSession == session
                        && !$0.voiceVerified && !$0.speakerByHand
                }
                guard fresh else { continue }
                let began = Date()
                if await self.relabelByVoice(quiet: true) {
                    self.afterTranscriptRearranged()
                    self.persist()
                }
                wait = min(max(45, Date().timeIntervalSince(began) * 10), 300)
            }
        }
    }

    /// Re-labels every mic line of this session from the recorded audio, with
    /// the offline diarization pipeline. Returns whether anything changed.
    ///
    /// `quiet` is the automatic pass: it reports no errors. Lines whose
    /// speaker the user set by hand are never changed.
    private func relabelByVoice(quiet: Bool = false) async -> Bool {
        // One pass at a time.
        while voicePassBusy {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        voicePassBusy = true
        defer { voicePassBusy = false }
        let session = micSessionID
        let lines = segments.filter {
            $0.isFinal && !$0.systemAudio && $0.micSession == session && session != 0
                && $0.micStart != nil && $0.micEnd != nil && !$0.speakerByHand
        }
        guard !lines.isEmpty else { return false }
        let ranges = lines.map { $0.micStart!..<max($0.micEnd!, $0.micStart! + 1) }
        let labels: [SpeakerLabel?]
        do {
            labels = try await speakerID.relabel(session: session, ranges: ranges)
        } catch {
            if !quiet { lastError = error.localizedDescription }
            return false
        }
        var changed = false
        var votes: [String: [String: Int]] = [:]
        for (line, label) in zip(lines, labels) {
            guard let label, let index = segments.firstIndex(where: { $0.id == line.id }) else { continue }
            let speaker: Speaker
            let tag: String?
            switch label {
            case .me:
                speaker = .me
                tag = nil
            case .other(let number):
                speaker = .them
                tag = "P\(number)"
            }
            // What each live name turned out to be, for the rest of the session.
            if line.speaker == .them, let old = line.tag, !line.speakerCorrected {
                votes[old, default: [:]][tag ?? "Me", default: 0] += 1
            }
            if segments[index].speaker != speaker || segments[index].tag != tag {
                segments[index].speaker = speaker
                segments[index].tag = tag
                segments[index].speakerCorrected = true
                changed = true
            }
            // The offline pipeline's verdicts calibrate the live check. Each
            // line teaches it once, the first time it is verified.
            if !segments[index].voiceVerified {
                teachVoice(segments[index], isMe: speaker == .me, tag: tag)
            }
            segments[index].voiceVerified = true
        }
        voiceRemap = [:]
        for (old, counts) in votes {
            guard let winner = counts.max(by: { $0.value < $1.value }),
                  winner.value * 2 > counts.values.reduce(0, +), winner.key != old else { continue }
            if winner.key == "Me" {
                voiceRemap[old] = (speaker: Speaker.me, tag: nil)
            } else {
                voiceRemap[old] = (speaker: Speaker.them, tag: winner.key)
            }
        }
        return changed
    }

    /// Stops a recheck where it is. Fixes already made stay (and can be undone).
    func stopRescan() {
        rescanTask?.cancel()
    }

    /// Puts back the lines as they were before the last recheck. Speech heard
    /// since then is kept.
    func undoRescan() {
        guard !isRescanning, let undo = rescanUndo else { return }
        let ids = Set(undo.current)
        let index = segments.firstIndex { ids.contains($0.id) } ?? segments.count
        segments.removeAll { ids.contains($0.id) }
        segments.insert(contentsOf: undo.original, at: min(index, segments.count))
        rescanUndo = nil
        canUndoRescan = false
        afterTranscriptRearranged()
        persist()
    }

    /// Gives the live voice check a labeled example: this line's audio was
    /// the user, or was not. It adjusts where the line between "me" and
    /// "someone else" is drawn, and is remembered across sessions.
    private func teachVoice(_ segment: TranscriptSegment, isMe: Bool, tag: String?) {
        guard segment.micSession == micSessionID, micSessionID != 0,
              let start = segment.micStart, let end = segment.micEnd else { return }
        let number = tag.flatMap { Int($0.dropFirst()) }
        Task { await speakerID.learn(startSample: start, endSample: end, isMe: isMe, other: number) }
    }

    /// Manual fix: gives a stretch of transcript to the next speaker in turn
    /// (You, Them, then any P1, P2, ... present). A hand-corrected line is
    /// left alone by the automatic passes.
    func cycleSpeaker(of ids: [UUID]) {
        let idSet = Set(ids)
        guard let first = segments.first(where: { idSet.contains($0.id) }) else { return }
        var options: [(speaker: Speaker, tag: String?)] = [(.me, nil), (.them, nil)]
        let tags = Set(segments.compactMap { segment -> String? in
            guard segment.speaker == .them, let tag = segment.tag, tag != TranscriptSegment.pendingTag else { return nil }
            return tag
        })
        for tag in tags.sorted() {
            options.append((speaker: .them, tag: tag))
        }
        let current = options.firstIndex { $0.speaker == first.speaker && $0.tag == first.tag } ?? 0
        let next = options[(current + 1) % options.count]
        for index in segments.indices where idSet.contains(segments[index].id) {
            segments[index].speaker = next.speaker
            segments[index].tag = next.tag
            segments[index].speakerCorrected = true
            segments[index].speakerByHand = true
            // The correction teaches the voice check: this stretch of audio
            // is now a known example of that person.
            teachVoice(segments[index], isMe: next.speaker == .me, tag: next.tag)
            if segments[index].original == nil {
                segments[index].original = segments[index].text
            }
        }
        afterTranscriptRearranged()
        persist()
    }

    /// After speakers or order changed: if the open question is still the one
    /// already answered, keep that answer; if it is a different one now, draft
    /// a reply for it.
    private func afterTranscriptRearranged() {
        var theirTurn: [TranscriptSegment] = []
        for segment in segments.filter(\.isFinal).reversed() {
            if segment.speaker == .me { break }
            theirTurn.insert(segment, at: 0)
        }
        guard let first = theirTurn.first else { return }
        let heard = theirTurn.map { $0.original ?? $0.text }.joined(separator: " ")
        if lastAutoTurnID != nil, Self.similarity(lastAutoQuestion, heard) >= 0.85 {
            lastAutoRunKey = first.utteranceID
            lastAutoQuestion = heard
        } else if AppSettings.shared.autoSuggest {
            scheduleAutoSuggest()
        }
    }

    /// Parses a rechecked transcript: lines of "Me: ...", "Them: ..." or "P2: ...".
    private static func parseTranscript(_ output: String) -> [(speaker: Speaker, tag: String?, text: String)] {
        var lines: [(speaker: Speaker, tag: String?, text: String)] = []
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var parsed: (speaker: Speaker, tag: String?, text: String)?
            if let colon = line.firstIndex(of: ":") {
                let label = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
                let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    if label == "ME" {
                        parsed = (.me, nil, text)
                    } else if label == "THEM" {
                        parsed = (.them, nil, text)
                    } else if label.count <= 3, label.hasPrefix("P"), Int(label.dropFirst()) != nil {
                        parsed = (.them, label, text)
                    }
                }
            }
            if let parsed {
                lines.append(parsed)
            } else if !lines.isEmpty {
                lines[lines.count - 1].text += " " + line
            }
        }
        return lines
    }

    // MARK: - Transcript polish

    /// Once speech has settled for a moment, the model re-reads each finished
    /// turn in context and rewrites it so it is easy to read: misheard words,
    /// punctuation, false starts. The original is kept on the line.
    private func schedulePolish() {
        polishWork?.cancel()
        polishWork = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard !Task.isCancelled else { return }
            await self.polishPending()
            await self.updateNotesIfNeeded()
        }
    }

    /// Transcript lines the reply model still sees verbatim.
    /// How many lines travel with a live reply; older ones are folded into
    /// the running notes first. Grows with the engine's context window.
    private var recentWindow: Int { ContextBudget.current.transcriptLines(.liveReply) }
    /// The transcript kept in memory and saved with the conversation.
    private static let maxSegments = 1500

    /// Summarizes everything so far on demand: folds every transcript line
    /// not yet in the notes, plus the answers given, into the running notes.
    func summarizeNow() {
        guard !isSummarizing else { return }
        let finals = segments.filter(\.isFinal)
        var start = 0
        if let id = lastSummarizedID, let index = finals.firstIndex(where: { $0.id == id }) {
            start = index + 1
        }
        let batch = Array(finals[start...])
        let answers = conversation.turns
        guard !batch.isEmpty || !answers.isEmpty else {
            notesError = "Nothing to summarize yet."
            return
        }
        notesError = nil
        isSummarizing = true
        Task { @MainActor in
            defer { isSummarizing = false }
            do {
                let notes = try await suggester.updateNotes(existing: conversation.summary ?? "",
                                                            newLines: batch,
                                                            answers: answers)
                guard !notes.isEmpty else {
                    notesError = "The model returned an empty summary. Try again."
                    return
                }
                conversation.summary = String(notes.prefix(1800))
                if let last = batch.last {
                    lastSummarizedID = last.id
                }
                persist()
            } catch {
                notesError = error.localizedDescription
            }
        }
    }

    // MARK: - Write-up: the conversation as notes worth keeping

    /// Writes the conversation up as structured notes for later use: a short
    /// summary, the topics covered, decisions, action items and open
    /// questions. Runs when listening stops and on demand, and is saved with
    /// the conversation. The transcript itself stays as it is.
    func writeUpRecord(auto: Bool = false) {
        guard !isWritingUp else { return }
        let finals = Array(segments.filter(\.isFinal).suffix(Self.maxSegments))
        guard finals.count >= 2 else {
            if !auto { notesError = "Not enough conversation to write up yet." }
            return
        }
        // Automatic runs skip a transcript that was already written up.
        var hasher = Hasher()
        for line in finals {
            hasher.combine(line.speaker)
            hasher.combine(line.tag)
            hasher.combine(line.text)
        }
        let signature = hasher.finalize()
        if auto, conversation.record != nil, signature == writeUpSignature { return }
        notesError = nil
        isWritingUp = true
        let conversationID = conversation.id
        let earlier = conversation.summary ?? ""
        Task { @MainActor in
            defer { self.isWritingUp = false }
            do {
                let text = try await self.suggester.writeUp(transcript: finals, earlier: earlier)
                guard self.conversation.id == conversationID else { return }
                guard !text.isEmpty else {
                    self.notesError = "The model returned an empty write-up. Try again."
                    return
                }
                self.conversation.record = text
                self.writeUpSignature = signature
                self.persist()
                // Also kept as a Markdown file, one per conversation, so the
                // wrap-up can be opened, searched and shared outside the app.
                self.saveWrapUp(text)
                // What is worth knowing next time goes into long-term memory.
                if AppSettings.shared.rememberAcross {
                    let title = self.conversation.title
                    if let facts = try? await self.suggester.memories(from: text),
                       self.conversation.id == conversationID {
                        MemoryStore.shared.replace(for: conversationID, title: title, facts: facts)
                    }
                }
            } catch {
                self.notesError = error.localizedDescription
            }
        }
    }

    /// Folder the call wrap-ups are saved in.
    var wrapUpFolder: URL {
        ContextStore.shared.baseDir.appendingPathComponent("Wrap-ups", isDirectory: true)
    }

    /// Writes the wrap-up to Wrap-ups/<date> <title>.md, replacing the
    /// previous version for the same conversation.
    private func saveWrapUp(_ notes: String) {
        let folder = wrapUpFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let title = conversation.title
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n"))
            .joined(separator: " ")
        let name = "\(formatter.string(from: conversation.createdAt)) \(String(title.prefix(50))).md"
        // An earlier save of this conversation under an older title goes.
        let tag = "<!-- companion:\(conversation.id.uuidString) -->"
        if let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "md" && file.lastPathComponent != name {
                if let head = try? String(contentsOf: file, encoding: .utf8), head.hasPrefix(tag) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        try? (tag + "\n" + notes).write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Saves the write-up and the cleaned transcript as a Markdown file.
    func exportRecord() {
        let finals = segments.filter(\.isFinal)
        var text = conversation.record ?? conversation.summary ?? ""
        guard !text.isEmpty || !finals.isEmpty else {
            notesError = "Nothing to export yet."
            return
        }
        if !finals.isEmpty {
            let lines = finals.map { "**\($0.speaker == .me ? "Me" : ($0.tag ?? "Them")):** \($0.text)" }
            text += (text.isEmpty ? "" : "\n\n") + "## Transcript\n\n" + lines.joined(separator: "\n\n")
        }
        let name = conversation.title
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n"))
            .joined(separator: " ")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(name.prefix(60)) + ".md"
        panel.canCreateDirectories = true
        // Above Companion's own floating panel.
        panel.level = .popUpMenu
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            notesError = error.localizedDescription
        }
    }

    /// Long conversations outgrow what is sent to the model. Before lines
    /// leave the recent window they are folded into running notes, which
    /// travel with every request, so the beginning is never lost.
    private func updateNotesIfNeeded() async {
        guard AppSettings.shared.keepNotes, !isSummarizing, Date() >= polishBackoffUntil else { return }
        let finals = segments.filter(\.isFinal)
        let leaving = finals.count - recentWindow
        guard leaving > 0 else { return }
        var start = 0
        if let id = lastSummarizedID, let index = finals.firstIndex(where: { $0.id == id }) {
            start = index + 1
        }
        // Fold in batches rather than one model call per sentence.
        guard leaving - start >= 8 else { return }
        let batch = Array(finals[start..<leaving])
        isSummarizing = true
        defer { isSummarizing = false }
        do {
            let notes = try await suggester.updateNotes(existing: conversation.summary ?? "", newLines: batch)
            guard !notes.isEmpty else { return }
            conversation.summary = String(notes.prefix(1800))
            lastSummarizedID = batch.last?.id
        } catch {
            log.error("notes: \(error.localizedDescription)")
            polishBackoffUntil = Date().addingTimeInterval(60)
        }
    }

    private func polishPending() async {
        guard AppSettings.shared.polishTranscript, !isPolishing, Date() >= polishBackoffUntil else { return }
        isPolishing = true
        defer { isPolishing = false }
        var passes = 0
        while passes < 4, let run = nextUnpolishedRun() {
            passes += 1
            let ids = run.map(\.id)
            let raw = run.map(\.text).joined(separator: " ")
            let given = run[0].speaker
            let tag = run[0].tag
            // System audio is always the other side; only mic speech can be
            // attributed to the wrong person.
            let certain = run[0].systemAudio
            // Too short to be worth a model call: accept as heard.
            guard Self.normalizedWords(raw).count >= 4 else {
                replace(ids, with: [(given, raw)], original: raw, given: given, tag: tag)
                continue
            }
            let before: [TranscriptSegment]
            if let index = segments.firstIndex(where: { $0.id == ids[0] }) {
                before = Array(segments[..<index].filter(\.isFinal).suffix(6))
            } else {
                before = []
            }
            do {
                let output = try await suggester.polish(utterance: raw,
                                                        speakerIsMe: given == .me,
                                                        speakerCertain: certain,
                                                        before: before)
                var lines = Self.parsePolish(output, fallback: given)
                if certain {
                    lines = [(given, lines.map(\.1).joined(separator: " "))]
                }
                let rewritten = lines.map(\.1).joined(separator: " ")
                if lines.isEmpty || lines.count > 3 || !Self.acceptablePolish(rewritten, for: raw) {
                    lines = [(given, raw)]
                }
                replace(ids, with: lines, original: raw, given: given, tag: tag)
            } catch {
                // No engine configured or it is unreachable: stop trying for a
                // minute instead of failing on every sentence.
                log.error("polish: \(error.localizedDescription)")
                polishBackoffUntil = Date().addingTimeInterval(60)
                return
            }
        }
    }

    /// The next stretch of finished, not yet polished speech by one speaker.
    /// A stretch someone is still adding to is left for the next pass.
    private func nextUnpolishedRun() -> [TranscriptSegment]? {
        guard let start = segments.firstIndex(where: { $0.isFinal && $0.original == nil }) else { return nil }
        var end = start
        while end + 1 < segments.count,
              segments[end + 1].isFinal,
              segments[end + 1].original == nil,
              segments[end + 1].speaker == segments[start].speaker,
              segments[end + 1].tag == segments[start].tag {
            end += 1
        }
        if end + 1 < segments.count, !segments[end + 1].isFinal {
            return nil
        }
        return Array(segments[start...end])
    }

    /// Replaces a run of segments with its polished form: normally one line,
    /// more when the run turned out to hold two people's speech. Lines whose
    /// speaker differs from the automatic label are marked as corrected.
    private func replace(_ ids: [UUID],
                         with lines: [(Speaker, String)],
                         original: String,
                         given: Speaker,
                         tag: String?) {
        guard let first = segments.firstIndex(where: { $0.id == ids[0] }),
              ids.allSatisfy({ id in segments.contains { $0.id == id } }),
              !lines.isEmpty else { return }
        var template = segments[first]
        // The merged line covers the audio of the whole run.
        template.micEnd = segments.filter { ids.contains($0.id) }.compactMap(\.micEnd).max() ?? template.micEnd
        var rebuilt: [TranscriptSegment] = []
        for (offset, line) in lines.enumerated() {
            var segment = offset == 0
                ? template
                : TranscriptSegment(id: UUID(),
                                    utteranceID: UUID(),
                                    speaker: line.0,
                                    tag: nil,
                                    text: line.1,
                                    isFinal: true,
                                    seq: Int.max,
                                    timestamp: template.timestamp)
            segment.speaker = line.0
            segment.tag = line.0 == given ? tag : nil
            segment.text = line.1
            segment.original = offset == 0 ? original : line.1
            segment.speakerCorrected = line.0 != given
            rebuilt.append(segment)
        }
        let rest = Set(ids.dropFirst())
        if !rest.isEmpty {
            segments.removeAll { rest.contains($0.id) }
        }
        guard let index = segments.firstIndex(where: { $0.id == ids[0] }) else { return }
        segments.replaceSubrange(index...index, with: rebuilt)

        // A line that turned out to be theirs is a question nobody answered yet.
        if rebuilt.contains(where: { $0.speakerCorrected && $0.speaker == .them }),
           AppSettings.shared.autoSuggest {
            scheduleAutoSuggest()
        }
    }

    /// Parses the polish output: lines of "Me: ..." or "Them: ...". Text
    /// without a label is attributed to the given speaker.
    private static func parsePolish(_ output: String, fallback: Speaker) -> [(Speaker, String)] {
        var lines: [(Speaker, String)] = []
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()
            var speaker: Speaker?
            var text = line
            if lower.hasPrefix("me:") {
                speaker = .me
                text = String(line.dropFirst(3))
            } else if lower.hasPrefix("them:") {
                speaker = .them
                text = String(line.dropFirst(5))
            }
            text = text
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D}"))
            guard !text.isEmpty else { continue }
            if let speaker {
                if let last = lines.last, last.0 == speaker {
                    lines[lines.count - 1].1 += " " + text
                } else {
                    lines.append((speaker, text))
                }
            } else if lines.isEmpty {
                lines.append((fallback, text))
            } else {
                lines[lines.count - 1].1 += " " + text
            }
        }
        return lines
    }

    /// A rewrite is only accepted if it is plausibly the same utterance: not
    /// empty and not wildly shorter or longer than what was heard.
    private static func acceptablePolish(_ cleaned: String, for raw: String) -> Bool {
        guard !cleaned.isEmpty else { return false }
        let ratio = Double(cleaned.count) / Double(max(raw.count, 1))
        return ratio >= 0.4 && ratio <= 1.6
    }

    // MARK: - Who is speaking

    /// Decides whose voice a mic utterance is. Only relevant with voice
    /// separation on; otherwise everything on the mic is the user.
    private func resolveMicSpeaker(text: String, chunk: SpeechChunk) async -> (Speaker, String?) {
        guard voiceEnrolled, AppSettings.shared.separateMicVoices else { return (.me, nil) }

        // Reading a suggested answer aloud is always the user, whatever the
        // voice model thinks. This also stops answers triggering new answers.
        if readingKind(text, heardAt: firstHeard(chunk.utteranceID)) != nil {
            if chunk.isFinal { lastMicLabel = (.me, nil, Date()) }
            return (.me, nil)
        }
        // Not identified until the utterance is complete: show it as pending
        // rather than guessing.
        guard chunk.isFinal else { return (.me, TranscriptSegment.pendingTag) }

        if let label = await speakerID.classify(startSample: chunk.startSample, endSample: chunk.endSample) {
            let result: (Speaker, String?)
            switch label {
            case .me: result = (.me, nil)
            case .other(let n):
                if let renamed = voiceRemap["P\(n)"] {
                    result = (renamed.speaker, renamed.tag)
                } else {
                    result = (.them, "P\(n)")
                }
            }
            lastMicLabel = (result.0, result.1, Date())
            return result
        }
        // Too short or too close to call: the same voice is probably continuing.
        if let last = lastMicLabel, Date().timeIntervalSince(last.at) < 6 {
            lastMicLabel = (last.speaker, last.tag, Date())
            return (last.speaker, last.tag)
        }
        return (.me, nil)
    }

    /// When an utterance was first heard (now, if this is its first chunk).
    private func firstHeard(_ utterance: UUID) -> Date {
        segments.last { $0.utteranceID == utterance }?.timestamp ?? Date()
    }

    /// Which newest answer, if any, this speech is a reading of.
    ///
    /// Two things must hold. The speech began after the answer appeared: a
    /// question is spoken before its answer exists, so it can never be a
    /// reading of it, however many words the answer echoes back. And the
    /// words follow the answer in order: a reading walks through the text,
    /// while a question about the same topic only shares scattered words.
    /// Speech recognition mangles names and numbers, so half the words in
    /// order is enough, and a little less once a reading is under way.
    private func readingKind(_ text: String, heardAt: Date) -> TurnKind? {
        let spoken = Self.normalizedWords(text)
        guard spoken.count >= 4 else { return nil }
        let underWay = Date().timeIntervalSince(lastReadingAt) < 6
        let needed = underWay ? 0.4 : 0.5
        var best: (kind: TurnKind, share: Double)?
        for kind in [TurnKind.reply, TurnKind.screen] {
            guard let turn = conversation.turns.last(where: { $0.kind == kind }), !turn.answer.isEmpty,
                  heardAt > (answerStartedAt[turn.id] ?? turn.date) else { continue }
            let script = Self.normalizedWords(turn.answer)
            let share = Double(Self.wordsInOrder(spoken, script)) / Double(spoken.count)
            if share >= needed, share > (best?.share ?? 0) {
                best = (kind, share)
            }
        }
        return best?.kind
    }

    /// How many of `spoken`'s words appear in `script` in the same order
    /// (longest common subsequence).
    private static func wordsInOrder(_ spoken: [String], _ script: [String]) -> Int {
        guard !spoken.isEmpty, !script.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: script.count + 1)
        var current = previous
        for word in spoken {
            for index in 1...script.count {
                current[index] = word == script[index - 1]
                    ? previous[index - 1] + 1
                    : max(previous[index], current[index - 1])
            }
            previous = current
        }
        return previous[script.count]
    }

    private func isEchoOfSystemAudio(_ text: String) -> Bool {
        guard AppSettings.shared.captureSystemAudio,
              Self.normalizedWords(text).count >= 3 else { return false }
        let cutoff = Date().addingTimeInterval(-15)
        let recent = segments
            .filter { $0.speaker == .them && $0.tag == nil && $0.timestamp >= cutoff }
            .map(\.text)
            .joined(separator: " ")
        guard !recent.isEmpty else { return false }
        return Self.containment(of: text, in: recent) >= 0.7
    }

    private static let fillers: Set<String> = ["uh", "um", "mm", "hmm", "hm", "mhm", "ah", "eh", "er", "uhh", "umm"]

    private static func isFillerOnly(_ text: String) -> Bool {
        let words = normalizedWords(text)
        return !words.isEmpty && words.count <= 3 && words.allSatisfy { fillers.contains($0) }
    }

    /// Word-set overlap of two texts, 0 to 1.
    private static func similarity(_ a: String, _ b: String) -> Double {
        let x = Set(normalizedWords(a))
        let y = Set(normalizedWords(b))
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// Fraction of the words of `text` that also occur in `other`.
    private static func containment(of text: String, in other: String) -> Double {
        let words = normalizedWords(text)
        guard !words.isEmpty, !other.isEmpty else { return 0 }
        let pool = Set(normalizedWords(other))
        return Double(words.filter { pool.contains($0) }.count) / Double(words.count)
    }

    // MARK: - Turns

    @discardableResult
    private func appendTurn(_ turn: ChatTurn) -> UUID {
        conversation.turns.append(turn)
        return turn.id
    }

    private func updateTurn(_ id: UUID, _ mutate: (inout ChatTurn) -> Void) {
        guard let index = conversation.turns.firstIndex(where: { $0.id == id }) else { return }
        mutate(&conversation.turns[index])
    }

    /// Streams an answer into a turn. One run per thread at a time; starting a
    /// new one cancels the previous run of the same kind.
    private func run(turnID: UUID,
                     kind: TurnKind,
                     reveal: Bool,
                     keeping draft: String = "",
                     make: @escaping @MainActor () async throws -> AsyncThrowingStream<String, Error>) {
        tasks[kind]?.cancel()
        if let previous = runningTurn[kind] {
            streamingTurns.remove(previous)
        }
        runningTurn[kind] = turnID
        streamingTurns.insert(turnID)
        if draft.isEmpty {
            answerStartedAt[turnID] = nil
        } else {
            quietTurns.insert(turnID)
        }
        updateTurn(turnID) {
            // A kept draft stays on screen and the new answer grows out of it.
            if draft.isEmpty {
                $0.answer = ""
                $0.spoken = nil
                $0.matched = nil
            }
            $0.error = nil
            $0.model = engineLabel
        }
        if draft.isEmpty {
            startTracking(kind)
        }
        if reveal {
            showHistory = false
            overlay?.showPanel()
        }
        tasks[kind] = Task { @MainActor in
            defer { self.quietTurns.remove(turnID) }
            do {
                let stream = try await make()
                // What the answer is drawing on, shown under it.
                let sources = self.suggester.lastSources
                self.updateTurn(turnID) { $0.sources = sources.isEmpty ? nil : sources }
                var fresh = ""
                for try await delta in stream {
                    if Task.isCancelled { break }
                    fresh += delta
                    if self.answerStartedAt[turnID] == nil {
                        self.answerStartedAt[turnID] = Date()
                    }
                    // A hand-off to the agent is an instruction, not an answer:
                    // it is not shown while it arrives.
                    if Self.startsAgentHandOff(fresh) { continue }
                    // A first answer streams in. A re-check of an answer that
                    // is already on screen is written out of sight: the text
                    // the user is looking at does not move while it arrives.
                    if draft.isEmpty {
                        let text = fresh
                        self.updateTurn(turnID) { $0.answer = text }
                    }
                }
                // The model decided this is something to do, not to explain.
                if !Task.isCancelled, kind == .reply, let task = Self.agentHandOff(in: fresh) {
                    self.streamingTurns.remove(turnID)
                    if self.runningTurn[kind] == turnID {
                        self.runningTurn[kind] = nil
                    }
                    self.runAgent(task, in: turnID)
                    return
                }
                // The re-check is in. If it says the same thing, the answer on
                // screen is left exactly as it is. Only a real difference
                // replaces it, in one step, with the changed version.
                let revised = fresh.trimmingCharacters(in: .whitespacesAndNewlines)
                if !Task.isCancelled, !draft.isEmpty, !revised.isEmpty,
                   Self.similarity(draft, revised) < 0.9 {
                    self.updateTurn(turnID) { $0.answer = revised }
                }
            } catch is CancellationError {
                // replaced by a newer run
            } catch {
                if !Task.isCancelled {
                    self.updateTurn(turnID) { $0.error = error.localizedDescription }
                }
            }
            guard !Task.isCancelled else { return }
            self.streamingTurns.remove(turnID)
            if self.runningTurn[kind] == turnID {
                self.runningTurn[kind] = nil
            }
            if !self.panelVisible {
                self.hasUnseen = true
            }
            self.persist()
        }
    }

    private func cancelRuns() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        runningTurn = [:]
        streamingTurns = []
        draftTurns = []
        answeredQuestions = []
        autoSettledBefore = nil
        recheckedIDs = []
        writeUpSignature = nil
        lastAutoRunKey = nil
        lastAutoTurnID = nil
        lastAutoQuestion = ""
        lastMicLabel = nil
        polishWork?.cancel()
        lastSummarizedID = nil
        rescanTask?.cancel()
        rescanUndo = nil
        canUndoRescan = false
    }

    // MARK: - Reply thread

    private func scheduleAutoSuggest() {
        autoSuggestWork?.cancel()
        autoSuggestWork = Task { @MainActor in
            // Wait for a real pause, so one answer covers their whole thought.
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            self.suggestNow(auto: true)
            // A question that sounded unfinished stays a draft. If they then
            // stay quiet, that was the whole question: confirm the answer.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let id = self.lastAutoTurnID else { return }
            self.draftTurns.remove(id)
        }
    }

    /// Whether what they said calls for an answer: a question, or a request
    /// such as "tell me about" or "walk me through".
    private static func asksSomething(_ text: String) -> Bool {
        if text.contains("?") || text.contains("？") { return true }
        let padded = " " + normalizedWords(text).joined(separator: " ") + " "
        let cues = ["what", "why", "how", "when", "where", "who", "which", "whose",
                    "can you", "could you", "would you", "will you", "do you", "did you", "are you",
                    "have you", "is it", "is there", "are there", "tell me", "explain", "describe",
                    "walk me through", "let me know", "talk about", "thoughts on", "go ahead"]
        return cues.contains { padded.contains(" \($0) ") }
    }

    private func rememberAnswered(_ question: String, turnID: UUID) {
        answeredQuestions.removeAll { $0.turnID == turnID }
        answeredQuestions.append((question: question, turnID: turnID))
        if answeredQuestions.count > 12 {
            answeredQuestions.removeFirst(answeredQuestions.count - 12)
        }
    }

    /// Whether what they said reads as a finished question or sentence: it
    /// ends with a question mark, or with a full stop that is not hanging on
    /// a word like "and" or "because".
    private static func looksComplete(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        if last == "?" || last == "？" { return true }
        guard ".!。।".contains(last) else { return false }
        let dangling: Set<String> = ["and", "or", "but", "so", "because", "if", "when", "while", "that", "which",
                                     "who", "the", "a", "an", "to", "of", "with", "for", "in", "on", "at", "by",
                                     "about", "like", "is", "are", "was", "were", "then", "also"]
        guard let lastWord = normalizedWords(trimmed).last else { return false }
        return !dangling.contains(lastWord)
    }

    /// Drafts what to say next from the live transcript.
    ///
    /// Automatic runs answer one "their turn" (everything they have said since
    /// the user last spoke) with one turn in the thread. While they keep
    /// talking, that turn is refreshed in place, and only when the question
    /// has materially changed; a new turn starts after the user has spoken.
    func suggestNow(auto: Bool = false) {
        let finals = segments.filter(\.isFinal)
        guard !finals.isEmpty else {
            if !auto {
                lastError = "Nothing heard yet. Start listening, or type a message below."
                overlay?.showPanel()
            }
            return
        }
        var theirTurn: [TranscriptSegment] = []
        for segment in finals.reversed() {
            if segment.speaker == .me { break }
            theirTurn.insert(segment, at: 0)
        }
        // Listening goes on while the user is replying. A reply the user has
        // started saying settles everything it was written for; what the
        // others say after that is a new turn with its own reply, even
        // though the user's own sentence is not finished yet.
        if auto {
            if let id = lastAutoTurnID,
               let turn = conversation.turns.first(where: { $0.id == id }),
               (turn.spoken ?? 0) > 0,
               let covered = turn.anchor,
               covered > (autoSettledBefore ?? .distantPast) {
                autoSettledBefore = covered
            }
            if let settled = autoSettledBefore {
                theirTurn.removeAll { $0.timestamp <= settled }
            }
        }
        let question = theirTurn.map(\.text).joined(separator: " ")
        // Compare questions on what was heard, so polishing a line never
        // looks like a new question.
        let heard = theirTurn.map { $0.original ?? $0.text }.joined(separator: " ")
        let prompt = String(question.suffix(240))
        let transcript = Array(finals.suffix(ContextBudget.current.transcriptLines(.liveReply)))

        if auto {
            guard let first = theirTurn.first, Self.normalizedWords(question).count >= 3 else { return }
            let complete = Self.looksComplete(question)
            // The reply belongs right after the last thing they said.
            let anchor = theirTurn.last?.timestamp
            if first.utteranceID == lastAutoRunKey,
               let existingID = lastAutoTurnID,
               let existing = conversation.turns.first(where: { $0.id == existingID }) {
                // Once the user has started saying a reply, its words are
                // theirs to finish: it is never rewritten under them.
                if (existing.spoken ?? 0) > 0 {
                    draftTurns.remove(existingID)
                    return
                }
                let sameQuestion = Self.similarity(lastAutoQuestion, heard) >= 0.85
                let answered = !existing.answer.isEmpty || streamingTurns.contains(existingID)
                if sameQuestion, answered, existing.error == nil {
                    if complete { draftTurns.remove(existingID) }
                    return // nothing new to answer
                }
                lastAutoQuestion = heard
                rememberAnswered(heard, turnID: existingID)
                updateTurn(existingID) {
                    $0.prompt = prompt
                    $0.anchor = anchor
                }
                if complete { draftTurns.remove(existingID) } else { draftTurns.insert(existingID) }
                // The question grew: build on what is already written, even
                // if it was only half generated, instead of starting over.
                let draft = existing.error == nil ? existing.answer : ""
                run(turnID: existingID, kind: .reply, reveal: false, keeping: draft) {
                    try await self.suggester.replyStream(transcript: transcript,
                                                         draft: draft,
                                                         questionComplete: complete)
                }
                return
            }
            // They are answering a new question: the previous answer is settled.
            if let previous = lastAutoTurnID { draftTurns.remove(previous) }
            // Asked before (or the same lines came back relabeled or
            // rewritten): the answer already in the thread still stands.
            if let known = answeredQuestions.last(where: { Self.similarity($0.question, heard) >= 0.85 }),
               let turn = conversation.turns.first(where: { $0.id == known.turnID }),
               turn.error == nil,
               !turn.answer.isEmpty || streamingTurns.contains(turn.id) {
                lastAutoRunKey = first.utteranceID
                lastAutoTurnID = turn.id
                lastAutoQuestion = heard
                replyHint = "Same question as before: the earlier answer still stands."
                return
            }
            // Short remarks and acknowledgements ("Okay.", "Simplify.") do not
            // need a drafted reply. Anything longer, or any question, gets one.
            if AppSettings.shared.replyToQuestionsOnly,
               Self.normalizedWords(question).count < 6,
               !Self.asksSomething(question) {
                replyHint = "No reply: that was a short remark, not a question. Press the bolt to draft one anyway."
                return
            }
            replyHint = nil
            let turnID = appendTurn(ChatTurn(kind: .reply, origin: .auto, prompt: prompt, model: engineLabel))
            lastAutoRunKey = first.utteranceID
            lastAutoTurnID = turnID
            lastAutoQuestion = heard
            rememberAnswered(heard, turnID: turnID)
            updateTurn(turnID) { $0.anchor = anchor }
            if !complete { draftTurns.insert(turnID) }
            run(turnID: turnID, kind: .reply, reveal: false) {
                try await self.suggester.replyStream(transcript: transcript, questionComplete: complete)
            }
            return
        }

        lastError = nil
        let turnID = appendTurn(ChatTurn(kind: .reply,
                                         origin: .manual,
                                         prompt: prompt.isEmpty ? "What should I say next?" : prompt,
                                         model: engineLabel))
        run(turnID: turnID, kind: .reply, reveal: true) {
            try await self.suggester.replyStream(transcript: transcript)
        }
    }

    /// Sends what the user typed in the input bar.
    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Code works on a repository: before the first message of a code
        // chat goes anywhere, it has one. What was typed is kept and sent
        // as soon as the folder is chosen.
        if codeMode, !hasWorkFolder, pendingQuestion == nil {
            pickWorkFolder { [weak self] in self?.sendDraft() }
            return
        }
        draft = ""
        lastError = nil
        // The agent is waiting on a question: what is typed is the answer.
        if pendingQuestion != nil {
            answerAgent(text)
            return
        }
        // What was attached while writing goes with this message; the
        // files themselves stay with the chat (Details lists them).
        let sent = attachments.filter { pendingAttachments.contains($0.id) }.map(\.name)
        let before = Set(conversation.turns.map(\.id))
        pendingAttachments = []
        // One chat box for everything: a message that asks for something to
        // be done on the Mac goes to the agent, anything else is answered.
        // In code, every message is work on the repository, so it goes to
        // the agent, which reads and changes files there.
        if codeMode || Self.looksLikeTask(text) {
            runAgent(text)
        } else if attachScreen {
            answerScreenNow(question: text)
        } else {
            ask(text)
        }
        if !sent.isEmpty, let made = conversation.turns.last(where: { !before.contains($0.id) }) {
            updateTurn(made.id) { $0.attached = sent }
        }
    }

    // MARK: - The agent: doing things on the Mac from the chat

    /// The task in a chat answer that hands off to the agent ("AGENT: ...").
    static func agentHandOff(in answer: String) -> String? {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("AGENT:") else { return nil }
        let task = trimmed.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
        return task.isEmpty ? nil : task
    }

    /// Whether an answer that is still arriving is, so far, a hand-off.
    static func startsAgentHandOff(_ partial: String) -> Bool {
        let start = partial.drop(while: { $0.isWhitespace }).prefix(6).uppercased()
        return !start.isEmpty && "AGENT:".hasPrefix(start)
    }

    /// Whether a chat message asks for something to be done on the Mac
    /// (typed somewhere, an app opened) rather than asking a question.
    static func looksLikeTask(_ text: String) -> Bool {
        let words = normalizedWords(text)
        // A question about doing something is still a question.
        let asking: Set<String> = ["how", "what", "why", "when", "where", "who", "which", "is", "are", "does",
                                   "do", "did", "should", "explain", "tell"]
        guard let first = words.first, !asking.contains(first) else { return false }
        let padded = " " + words.joined(separator: " ") + " "
        if padded.hasPrefix(" type ") { return true }
        let cues = [" please type ", " can you type ", " could you type ", " and type ", " write it in", " write this in", " write that in", " write in the", " write into",
                    " write a prompt in", " write a message in", " write a reply in", " write an email in",
                    " put it in", " put this in", " put that in", " enter it in", " enter this in",
                    " fill in", " fill out", " paste ", " open the ", " open my ", " switch to ", " go to the ",
                    " in the chat ", " in the search", " in the text box", " in the field", " for me in "]
        if cues.contains(where: { padded.contains($0) }) { return true }
        return padded.hasPrefix(" open ") || padded.hasPrefix(" launch ")
    }

    /// Hands a task to the agent. It works the way a coding agent does: in
    /// rounds, it proposes the next few steps (a shell command, typing into
    /// an app, opening one), the user allows or declines them, they run, and
    /// the results go back to the model, until it says the task is done or
    /// needs the user.
    ///
    /// Nothing that changes anything runs without a yes. Commands that only
    /// read (ls, cat, git status) are allowed as they are, and "always
    /// allow" remembers a program so it is not asked about again. Stop ends
    /// it at any point. After a set number of steps (Settings > Agent) it
    /// stops to ask whether to carry on, so a long task is never cut off
    /// and never runs away either.
    func runAgent(_ task: String, in existing: UUID? = nil) {
        // Problems are reported in the chat turn when the task came from one.
        func refuse(_ message: String) {
            if let existing {
                updateTurn(existing) { $0.answer = message }
            } else {
                lastError = message
            }
        }
        guard !agentRunning else {
            refuse("The agent is still working on the last task. Press Stop (in the chat box, or Cmd+Shift+period) to end it, then ask again.")
            return
        }
        followUpTask?.cancel()
        lastError = nil
        agentTask = task
        agentRunning = true
        agentGeneration += 1
        let generation = agentGeneration
        agentLog = []
        agentContext = []
        agentOutputs = [:]
        agentPlan = []
        // The task and its outcome live in the chat like any other message.
        if let existing {
            agentTurnID = existing
            updateTurn(existing) { $0.answer = "" }
        } else {
            agentTurnID = appendTurn(ChatTurn(kind: .reply, origin: .typed, prompt: task, model: engineLabel))
        }
        if let agentTurnID { streamingTurns.insert(agentTurnID) }
        showHistory = false
        overlay?.showPanel()
        agentRun = Task { @MainActor in
            // However the task ends, the running state is cleared, unless a
            // forced stop already did it and a newer task now owns the state.
            defer {
                if generation == self.agentGeneration {
                    self.endAgent()
                }
            }
            var directory = self.agentStartDirectory
            // The repository's own instructions and the skills on hand go
            // with every task, so none of it has to be said in the chat.
            // A task that ended early leaves its report for the next message
            // in the same chat, so "continue" picks up where it stopped.
            let carried = self.unfinishedReport.isEmpty ? "" :
                "\n\nThe previous task in this chat ended before it was complete. Its report:\n"
                + self.unfinishedReport
                + "\nIf this message asks to continue, pick up from what is left and do not redo finished steps."
            let brief = task + self.repositoryNote + self.attachedPathsNote
                + (self.hasWorkFolder ? ProjectContext.note(for: self.agentStartDirectory) : ProjectContext.note(for: ""))
                + carried
            var keyboardAllowed = false
            var usedKeyboard = false
            var stepsRun = 0
            // How many steps it takes before it checks in with the user.
            let stepBudget = max(10, AppSettings.shared.agentStepBudget)
            var stepLimit = stepBudget
            // Rounds are counted too, as a backstop: a task that goes
            // round and round without taking steps is ended.
            var rounds = 0
            while true {
                if Task.isCancelled { return }
                rounds += 1
                if rounds > stepLimit * 2 {
                    self.finishAgent(self.reportUnfinished("Stopped: \(rounds) rounds went by without the task getting anywhere."), failed: true)
                    return
                }
                self.isPlanning = true
                self.agentStatus = "Working out the next step"
                // One look gives the app, window, page address and text.
                // Neither is allowed to hang the task: each has a time limit.
                let seen = (try? await Self.limited(10) { await ScreenReader.read() })
                    ?? ScreenContext(app: NSWorkspace.shared.frontmostApplication?.localizedName ?? "", window: "", url: "", text: "")
                if Task.isCancelled { return }
                let steps: [ActionStep]
                do {
                    let folder = directory
                    let history = self.agentContext
                    let clickable = DeviceControl.shared.clickableLabels()
                    let output = try await Self.limited(90) {
                        try await self.suggester.agentStep(task: brief,
                                                           directory: folder,
                                                           frontApp: seen.header,
                                                           screenText: seen.text,
                                                           clickable: clickable,
                                                           done: history)
                    }
                    if Task.isCancelled { return }
                    let plan = DeviceControl.parsePlan(output)
                    if let refusal = plan.refusal {
                        self.finishAgent("Can't do that: \(refusal)", failed: true)
                        return
                    }
                    // The model answered in plain words instead of steps (a
                    // greeting, a question that needs no action): that is
                    // its answer, not a failure.
                    if plan.steps.isEmpty {
                        let said = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !said.isEmpty {
                            self.finishAgent(said, failed: false)
                            return
                        }
                    }
                    steps = Array(plan.steps.prefix(4))
                } catch {
                    self.finishAgent(error.localizedDescription, failed: true)
                    return
                }
                self.isPlanning = false
                if Task.isCancelled { return }
                guard !steps.isEmpty else {
                    self.finishAgent("The model returned no steps. Try a clearer instruction, or a stronger model.", failed: true)
                    return
                }

                // Ask first: anything that is not known to be harmless.
                let remembered = AppSettings.shared.agentAllowed
                let autoReads = AppSettings.shared.agentAutoApproveReads
                // The chat's mode is read each round, so changing it
                // takes effect in the middle of a task.
                let access = self.agentAccess
                let repository = self.hasWorkFolder ? self.agentStartDirectory : ""
                let asking = steps.filter { step in
                    switch step.kind {
                    case .run:
                        // Keys and credentials are asked about in every mode.
                        if AgentPermissions.touchesSecrets(step.value) { return true }
                        if access == .full { return false }
                        if AgentPermissions.isAllowed(step.value, remembered: remembered, autoApproveReads: autoReads) {
                            return false
                        }
                        // Editing on its own covers commands that keep to
                        // the chat's repository.
                        return !(access == .autoEdit
                                 && AgentPermissions.staysInside(step.value, repository: repository, directory: directory))
                    case .type, .key, .open, .click: return access != .full && !keyboardAllowed
                    case .wait, .done, .ask, .plan: return false
                    // Looking never changes anything, so in Manual it
                    // follows the "read-only without asking" setting; keys
                    // and credentials are asked about regardless.
                    case .read:
                        if AgentTools.isSensitive(AgentTools.resolve(step.value, in: directory)) { return true }
                        return access == .manual && !autoReads
                    // A helper only reads and searches, and is refused
                    // keys and credentials outright.
                    case .search, .fetch, .web, .delegate: return access == .manual && !autoReads
                    // A change to a file is shown first in Manual. On its
                    // own, edits stay in the repository unless access is
                    // full, and nothing writes to keys or credentials.
                    case .write, .edit:
                        let target = AgentTools.resolve(step.value, in: directory)
                        if AgentTools.isSensitive(target) { return true }
                        switch access {
                        case .manual: return true
                        case .full: return false
                        case .autoEdit:
                            return repository.isEmpty
                                || !(target == repository || target.hasPrefix(repository + "/"))
                        }
                    }
                }
                if !asking.isEmpty {
                    let commands = asking.filter { $0.kind == .run }.map(\.value)
                    let remember = commands.flatMap { AgentPermissions.toRemember($0, remembered: remembered, autoApproveReads: autoReads) }
                    self.agentStatus = "Waiting for your OK"
                    self.pendingApproval = AgentProposal(steps: asking, directory: directory, remember: remember)
                    if !self.panelVisible { self.hasUnseen = true }
                    let decision: AgentDecision = await withCheckedContinuation { self.approval = $0 }
                    self.pendingApproval = nil
                    if Task.isCancelled { return }
                    switch decision {
                    case .deny:
                        let declined = asking.map(\.label).joined(separator: "; ")
                        self.finishAgent("Not run, as you declined: \(declined). Tell me what to do instead.", failed: true)
                        return
                    case .always:
                        var allowed = AppSettings.shared.agentAllowed
                        for name in remember where !allowed.contains(name) {
                            allowed.append(name)
                        }
                        AppSettings.shared.agentAllowed = allowed
                        if asking.contains(where: { $0.kind.usesKeyboard }) {
                            keyboardAllowed = true
                        }
                    case .allow:
                        break
                    }
                }

                for step in steps {
                    if Task.isCancelled { return }
                    switch step.kind {
                    case .done:
                        // The task is over here. Suggestions are worked out
                        // afterwards on their own and never hold up a new task.
                        self.finishAgent(step.value, failed: false)
                        self.startFollowUp(task: task, waitForScreen: usedKeyboard)
                        return
                    case .ask:
                        // The task pauses on the question and carries on
                        // with the answer, like an assistant that checks
                        // with you and then keeps going.
                        let question = AgentQuestion(step.value)
                        self.agentStatus = "Waiting for your answer"
                        self.pendingQuestion = question
                        self.publishProgress()
                        if !self.panelVisible { self.hasUnseen = true }
                        let answer: String? = await withCheckedContinuation { self.questionAnswer = $0 }
                        self.pendingQuestion = nil
                        if Task.isCancelled { return }
                        guard let answer, !answer.isEmpty else {
                            self.finishAgent(question.question, failed: true)
                            return
                        }
                        self.agentLog.append("Asked: \(question.question) You said: \(answer)")
                        self.agentContext.append("ASK: \(question.question)\nResult: the user answered: \(answer)")
                        self.publishProgress()
                    case .plan:
                        // The checklist is the agent's own; it only needs showing.
                        self.agentPlan = PlanItem.parse(step.value)
                        self.agentContext.append("PLAN: \(step.value)")
                    case .read:
                        self.agentStatus = "Reading \((step.value as NSString).lastPathComponent)"
                        let outcome = AgentTools.read(step.value, in: directory)
                        self.noteTool("Read", step.value, outcome)
                    case .search:
                        self.agentStatus = "Searching files"
                        let found = await AgentShell.shared.run(AgentTools.searchCommand(step.value), in: directory)
                        if Task.isCancelled { return }
                        let text = found.output.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.noteTool("Searched", step.value,
                                      AgentTools.Outcome(ok: true, text: text.isEmpty ? "No matches." : String(text.prefix(AgentTools.limit))))
                    case .write:
                        self.agentStatus = "Writing \((step.value as NSString).lastPathComponent)"
                        // The file as it was is kept first, so the write can
                        // be seen and undone from the workspace's Changes.
                        let target = AgentTools.resolve(step.value, in: directory)
                        let before = ChangeStore.shared.snapshot(target)
                        let outcome = AgentTools.write(step.value, content: step.body, in: directory)
                        if outcome.ok {
                            ChangeStore.shared.record(path: target, before: before, task: self.agentTask ?? "",
                                                      conversation: self.conversation.id)
                            self.workspace.reloadIfOpen(target)
                        }
                        self.noteTool("Wrote", step.value, outcome)
                    case .edit:
                        self.agentStatus = "Editing \((step.value as NSString).lastPathComponent)"
                        let target = AgentTools.resolve(step.value, in: directory)
                        let before = ChangeStore.shared.snapshot(target)
                        let outcome = AgentTools.edit(step.value, old: step.body, new: step.replacement, in: directory)
                        if outcome.ok {
                            ChangeStore.shared.record(path: target, before: before, task: self.agentTask ?? "",
                                                      conversation: self.conversation.id)
                            self.workspace.reloadIfOpen(target)
                        }
                        self.noteTool("Edited", step.value, outcome)
                    case .delegate:
                        self.agentStatus = "A helper is looking into it"
                        let outcome = await self.delegate(step.value, in: directory)
                        if Task.isCancelled { return }
                        self.noteTool("Delegated", step.value, outcome)
                    case .fetch:
                        self.agentStatus = "Reading a web page"
                        let outcome = await AgentTools.fetch(step.value)
                        if Task.isCancelled { return }
                        self.noteTool("Fetched", step.value, outcome)
                    case .web:
                        self.agentStatus = "Searching the web"
                        let outcome = await AgentTools.search(web: step.value)
                        if Task.isCancelled { return }
                        self.noteTool("Searched the web for", step.value, outcome)
                    case .wait:
                        let seconds = min(max(Double(step.value.filter { $0.isNumber || $0 == "." }) ?? 2, 1), 10)
                        self.agentStatus = "Waiting"
                        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                        self.agentContext.append(step.label)
                    case .run:
                        self.agentStatus = "Running a command"
                        let result = await AgentShell.shared.run(step.value, in: directory)
                        // Stopped while it ran: this task no longer owns the state.
                        if Task.isCancelled { return }
                        directory = result.directory
                        let verdict = result.timedOut
                            ? "stopped after 2 minutes"
                            : (result.exitCode == 0 ? "ok" : "failed, exit \(result.exitCode)")
                        // In the chat: the command and how it went. Its output
                        // is shown while it is the latest step, and kept at
                        // the end only when the task fails.
                        self.agentLog.append("Ran `\(step.value)` (\(verdict))")
                        self.agentOutputs[self.agentLog.count - 1] = String(result.output.suffix(700))
                        // For the model: all of the kept output.
                        self.agentContext.append("RUN: \(step.value)\nResult: \(verdict)\nOutput:\n\(result.output.isEmpty ? "(none)" : result.output)")
                    case .open:
                        self.agentStatus = "Opening \(step.value)"
                        // Self-check: the app has to actually come to the
                        // front. One retry, then say plainly that it did not.
                        var confirmed = false
                        for attempt in 0..<2 where !confirmed {
                            guard await DeviceControl.shared.open(app: step.value) else {
                                if attempt == 1 { break }
                                continue
                            }
                            confirmed = await self.waitUntilFront(step.value)
                        }
                        if Task.isCancelled { return }
                        if confirmed {
                            AgentOrbit.shared.flash(.open, at: DeviceControl.shared.focusPoint())
                        }
                        let outcome = confirmed ? "confirmed in front" : "NOT confirmed: it did not come to the front"
                        self.agentLog.append(confirmed ? step.label : "\(step.label) (did not come to the front)")
                        self.agentContext.append("\(step.label)\nResult: \(outcome)")
                    case .click:
                        self.agentStatus = "Clicking \(step.value)"
                        // Self-check: the press either reached a named
                        // control or it did not. One retry after a moment,
                        // in case the window was still drawing.
                        var result = DeviceControl.shared.click(step.value)
                        if !result.ok {
                            try? await Task.sleep(nanoseconds: 800_000_000)
                            result = DeviceControl.shared.click(step.value)
                        }
                        usedKeyboard = true
                        if result.ok {
                            AgentOrbit.shared.flash(.click, at: DeviceControl.shared.lastClickPoint)
                            self.agentLog.append("Clicked the \(result.detail)")
                            self.agentContext.append("\(step.label)\nResult: pressed the \(result.detail)")
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        } else {
                            self.agentLog.append("\(step.label) (failed: \(result.detail))")
                            self.agentContext.append("\(step.label)\nResult: FAILED after one retry, \(result.detail). Nothing was clicked.")
                        }
                    case .type, .key:
                        // Keys must land in the app underneath, never in
                        // Companion's own input box.
                        if !usedKeyboard {
                            self.overlay?.releaseKeyboard()
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            usedKeyboard = true
                        }
                        self.agentStatus = "Typing for you"
                        // The orbit rides the caret for as long as this types.
                        AgentOrbit.shared.beginTyping()
                        defer { AgentOrbit.shared.endTyping() }
                        self.isActing = true
                        do {
                            try await DeviceControl.shared.run([step])
                        } catch {
                            if Task.isCancelled { return }
                            self.isActing = false
                            self.finishAgent(error.localizedDescription, failed: true)
                            return
                        }
                        if Task.isCancelled { return }
                        self.isActing = false
                        // Self-check: typed text should now be on screen. It is
                        // never retyped (that would double it); the result just
                        // says whether it was seen.
                        var note = ""
                        if step.kind == .type, Self.normalizedWords(step.value).count >= 2 {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            let after = try? await Self.limited(10) { await ScreenReader.read() }
                            if Task.isCancelled { return }
                            let seen = Self.containment(of: step.value, in: after?.text ?? "") >= 0.5
                            note = seen
                                ? "\nResult: confirmed, the text is on screen"
                                : "\nResult: NOT confirmed, the text was not seen on screen afterwards (the field may be hidden, or the cursor was elsewhere)"
                            self.agentLog.append(seen ? step.label : "\(step.label) (not seen on screen afterwards)")
                        } else {
                            self.agentLog.append(step.label)
                        }
                        self.agentContext.append(step.label + note)
                    }
                    self.publishProgress()
                    // A checkmark for a step that went through, a shake for one that did not.
                    let latest = self.agentContext.last ?? ""
                    if latest.contains("FAILED") || latest.contains("NOT confirmed") || latest.contains("failed, exit")
                        || latest.contains("stopped after") {
                        self.stepFailures += 1
                    } else {
                        self.stepSuccesses += 1
                    }
                    stepsRun += 1
                    if stepsRun >= stepLimit {
                        // A long task is not cut off: it checks in, and
                        // carries on for as many steps again on a yes.
                        let question = AgentQuestion("I have taken \(stepsRun) steps and the task is not finished yet. Carry on? | Carry on | Stop here")
                        self.agentStatus = "Waiting for your answer"
                        self.pendingQuestion = question
                        self.publishProgress()
                        if !self.panelVisible { self.hasUnseen = true }
                        let answer: String? = await withCheckedContinuation { self.questionAnswer = $0 }
                        self.pendingQuestion = nil
                        if Task.isCancelled { return }
                        let said = (answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let lowered = said.lowercased()
                        if said.isEmpty || lowered.hasPrefix("stop") || lowered == "no" {
                            // What was done and what is left is reported,
                            // and kept for the next message in this chat.
                            self.finishAgent(self.reportUnfinished("Stopped after \(stepsRun) steps, before the task was finished."), failed: true)
                            return
                        }
                        stepLimit += stepBudget
                        // Anything else typed there is direction for the rest.
                        self.agentContext.append("ASK: \(stepsRun) steps taken, carry on?\nResult: the user answered: \(said)")
                        // The rest of this round was planned before the
                        // answer, so the next round starts from it.
                        break
                    }
                }
                if usedKeyboard {
                    // Let the screen catch up before looking again.
                    try? await Task.sleep(nanoseconds: 700_000_000)
                }
            }
        }
    }

    /// Waits up to two seconds for the named app to be the one in front.
    private func waitUntilFront(_ name: String) async -> Bool {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        for _ in 0..<8 {
            if NSWorkspace.shared.frontmostApplication?.localizedName?.lowercased() == wanted { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// Hands one question to a helper and waits for its report. The helper
    /// is a second, smaller agent with a context of its own: it reads and
    /// searches for up to eight rounds and only its report comes back, so
    /// a long look through files costs the task a few hundred words
    /// instead of everything that was read.
    ///
    /// It cannot change anything: no commands, no edits, no apps. Keys and
    /// credentials are refused to it, since there is nobody to ask.
    private func delegate(_ question: String, in directory: String) async -> AgentTools.Outcome {
        var done: [String] = []
        for _ in 0..<8 {
            if Task.isCancelled { return AgentTools.Outcome(ok: false, text: "Stopped.") }
            let output: String
            do {
                let history = done
                output = try await Self.limited(90) {
                    try await self.suggester.helperStep(question: question, directory: directory, done: history)
                }
            } catch {
                return AgentTools.Outcome(ok: false, text: "The helper could not go on: \(error.localizedDescription)")
            }
            if Task.isCancelled { return AgentTools.Outcome(ok: false, text: "Stopped.") }
            let steps = DeviceControl.parsePlan(output).steps
            // An answer in plain words instead of steps is the report.
            if steps.isEmpty {
                let said = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return AgentTools.Outcome(ok: !said.isEmpty,
                                          text: said.isEmpty ? "The helper gave no report." : String(said.prefix(3_000)))
            }
            for step in steps.prefix(6) {
                switch step.kind {
                case .done:
                    return AgentTools.Outcome(ok: true, text: String(step.value.prefix(3_000)))
                case .read:
                    if AgentTools.isSensitive(AgentTools.resolve(step.value, in: directory)) {
                        done.append("READ: \(step.value)\nResult: FAILED. Keys and credentials are not a helper's to read.")
                    } else {
                        self.agentStatus = "Helper: reading \((step.value as NSString).lastPathComponent)"
                        let file = AgentTools.read(step.value, in: directory)
                        done.append("READ: \(step.value)\nResult: \(file.text)")
                    }
                case .search:
                    self.agentStatus = "Helper: searching files"
                    let found = await AgentShell.shared.run(AgentTools.searchCommand(step.value), in: directory)
                    let text = found.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    let shown = text.isEmpty ? "No matches." : String(text.prefix(AgentTools.limit))
                    done.append("SEARCH: \(step.value)\nResult: \(shown)")
                case .fetch:
                    self.agentStatus = "Helper: reading a web page"
                    let page = await AgentTools.fetch(step.value)
                    done.append("FETCH: \(step.value)\nResult: \(page.text)")
                case .web:
                    self.agentStatus = "Helper: searching the web"
                    let results = await AgentTools.search(web: step.value)
                    done.append("WEB: \(step.value)\nResult: \(results.text)")
                default:
                    done.append("\(step.label)\nResult: FAILED. A helper only reads and searches.")
                }
                if Task.isCancelled { return AgentTools.Outcome(ok: false, text: "Stopped.") }
            }
        }
        return AgentTools.Outcome(ok: false, text: "The helper ran out of rounds before it could report. Ask it something narrower, or look yourself.")
    }

    /// Records what one of the agent's file or web tools did: a line for
    /// the chat, the start of what came back for the step's detail, and
    /// the whole result for the model.
    private func noteTool(_ verb: String, _ subject: String, _ outcome: AgentTools.Outcome) {
        agentLog.append("\(verb) `\(subject)`" + (outcome.ok ? "" : " (failed)"))
        agentOutputs[agentLog.count - 1] = String(outcome.text.prefix(900))
        agentContext.append("\(verb.uppercased()): \(subject)\nResult: \(outcome.ok ? "" : "FAILED. ")\(outcome.text)")
    }

    /// What has been done so far, as steps for the chat: each log line
    /// becomes the thing done (the command itself, the app, the label), how
    /// it went, and a command's output.
    private var workSteps: [WorkStep] {
        agentLog.enumerated().map { index, line in
            if line.hasPrefix("Ran `"), let end = line.range(of: "` (", options: .backwards) {
                let command = String(line[line.index(line.startIndex, offsetBy: 5)..<end.lowerBound])
                let verdict = String(line[end.upperBound...].dropLast())
                let output = agentOutputs[index].flatMap { $0.isEmpty ? nil : $0 }
                return WorkStep(kind: .run,
                                title: verdict == "ok" ? command : "\(command)  (\(verdict))",
                                output: output,
                                failed: verdict != "ok")
            }
            let failed = line.contains("(failed:") || line.contains("(did not come to the front)")
                || line.hasSuffix("(failed)")
            // The file and web tools: "Read `path`", "Edited `path`" and so on.
            let tools: [(prefix: String, kind: WorkStep.Kind)] = [
                ("Searched the web for `", .web), ("Fetched `", .web), ("Read `", .read),
                ("Searched `", .search), ("Wrote `", .edit), ("Edited `", .edit), ("Delegated `", .search)
            ]
            if let tool = tools.first(where: { line.hasPrefix($0.prefix) }) {
                let output = agentOutputs[index].flatMap { $0.isEmpty ? nil : $0 }
                return WorkStep(kind: tool.kind, title: line.replacingOccurrences(of: "`", with: ""),
                                output: output, failed: failed)
            }
            if line.hasPrefix("Open: ") {
                return WorkStep(kind: .open, title: "Opened " + line.dropFirst(6), failed: failed)
            }
            if line.hasPrefix("Clicked the ") || line.hasPrefix("Click: ") {
                return WorkStep(kind: .click, title: line, failed: failed)
            }
            if line.hasPrefix("Type: ") {
                return WorkStep(kind: .type, title: "Typed " + line.dropFirst(6), failed: failed)
            }
            if line.hasPrefix("Press: ") {
                return WorkStep(kind: .key, title: "Pressed " + line.dropFirst(7), failed: failed)
            }
            return WorkStep(kind: .other, title: line, failed: failed)
        }
    }

    /// Shows what has been done so far in the chat while the task goes on.
    private func publishProgress() {
        guard let id = agentTurnID else { return }
        let steps = workSteps
        let plan = agentPlan
        updateTurn(id) {
            $0.steps = steps.isEmpty ? nil : steps
            $0.plan = plan.isEmpty ? nil : plan
            $0.answer = ""
        }
    }

    /// Writes the result into the chat turn the way an assistant reports
    /// back: the answer on its own, with the work it took kept behind it as
    /// steps that can be opened. A failure keeps the reason as the answer;
    /// the failing command's output is in its step.
    private func finishAgent(_ message: String, failed: Bool) {
        // What the task changed goes into git where the folder is a
        // repository, and the workspace's file list catches up.
        let finished = agentTask ?? "agent task"
        Task { @MainActor in
            await ChangeStore.shared.commitPending(message: finished)
            self.workspace.refreshAll()
        }
        if let id = agentTurnID {
            let steps = workSteps
            // Whatever was still marked as being done is done now.
            var plan = agentPlan
            if !failed {
                for index in plan.indices where plan[index].state == .doing { plan[index].state = .done }
            }
            updateTurn(id) {
                $0.steps = steps.isEmpty ? nil : steps
                $0.plan = plan.isEmpty ? nil : plan
                $0.answer = message
            }
        } else if failed {
            lastError = message
        }
        lastAgentReport = message
        if failed {
            stepFailures += 1
        } else {
            // A task that completed leaves nothing to pick up.
            unfinishedReport = ""
        }
    }

    /// The report for a task that ended early: why it stopped, the steps
    /// that ran and the plan items still open. It is kept for the next
    /// message in this chat; nothing resumes by itself.
    private func reportUnfinished(_ reason: String) -> String {
        let done = agentLog.suffix(12).map { "- " + String($0.prefix(160)) }
        let left = agentPlan.filter { $0.state != .done }
            .map { "- " + $0.text + ($0.state == .doing ? " (in progress)" : "") }
        if done.isEmpty && left.isEmpty { return reason }
        var lines = [reason]
        if !done.isEmpty {
            lines.append("")
            lines.append(agentLog.count > done.count
                         ? "Done (last \(done.count) of \(agentLog.count) steps):" : "Done:")
            lines.append(contentsOf: done)
        }
        if !left.isEmpty {
            lines.append("")
            lines.append("Left:")
            lines.append(contentsOf: left)
        }
        lines.append("")
        lines.append("Say \"continue\" to pick up from here.")
        let report = lines.joined(separator: "\n")
        unfinishedReport = report
        return report
    }

    /// Clears everything that says a task is running. Called exactly once
    /// per task, whichever way it ended.
    private func endAgent() {
        isPlanning = false
        isActing = false
        agentRun = nil
        approval?.resume(returning: .deny)
        approval = nil
        pendingApproval = nil
        questionAnswer?.resume(returning: nil)
        questionAnswer = nil
        pendingQuestion = nil
        overlay?.restoreKeyboard()
        agentStatus = nil
        agentTask = nil
        agentRunning = false
        if let id = agentTurnID {
            streamingTurns.remove(id)
            // Ended without a verdict: say so in the chat.
            if conversation.turns.first(where: { $0.id == id })?.answer.isEmpty == true {
                let report = reportUnfinished("Stopped.")
                updateTurn(id) { $0.answer = report }
            }
        }
        persist()
    }

    /// Runs work with a time limit. If the limit passes first, an error is
    /// thrown and the caller moves on, even if the work never returns.
    private static func limited<T>(_ seconds: Double,
                                   _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let once = OnceFlag()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            Task { @MainActor in
                do {
                    let value = try await work()
                    if !once.done {
                        once.done = true
                        continuation.resume(returning: value)
                    }
                } catch {
                    if !once.done {
                        once.done = true
                        continuation.resume(throwing: error)
                    }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if !once.done {
                    once.done = true
                    continuation.resume(throwing: NSError(domain: "Companion", code: 7, userInfo: [
                        NSLocalizedDescriptionKey: "That took longer than \(Int(seconds)) seconds, so the agent stopped waiting for it."
                    ]))
                }
            }
        }
    }

    /// After a task has ended: works out how it turned out and what the
    /// user may want next, and adds that to the chat turn. It runs on its
    /// own, so the agent is free for a new task straight away; starting one
    /// (or pressing Stop) cancels it.
    private func startFollowUp(task: String, waitForScreen: Bool) {
        guard let id = agentTurnID else { return }
        let done = agentContext
        let report = lastAgentReport
        followUpTask?.cancel()
        followUpTask = Task { @MainActor in
            var screen = "(not relevant: the work was done in the shell)"
            if waitForScreen {
                await ScreenWatcher.waitForScreenToSettle(limit: 45)
                if Task.isCancelled { return }
                if let seen = try? await Self.limited(10, { await ScreenReader.read() }) {
                    screen = seen.header + "\n\n" + seen.text
                }
            }
            if Task.isCancelled { return }
            guard let output = try? await Self.limited(60, {
                try await self.suggester.nextSteps(task: task, done: done, report: report, screenText: screen)
            }), !Task.isCancelled else { return }
            var outcome: [String] = []
            var next: [String] = []
            for raw in output.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-*• \t"))
                guard !line.isEmpty else { continue }
                if line.uppercased().hasPrefix("NEXT:") {
                    let step = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if !step.isEmpty { next.append(step) }
                } else {
                    outcome.append(line)
                }
            }
            let summary = outcome.joined(separator: " ")
            self.updateTurn(id) {
                if !summary.isEmpty {
                    $0.answer += "\n\n\(summary)"
                }
                $0.suggestions = next.isEmpty ? nil : Array(next.prefix(3))
            }
            self.persist()
        }
    }

    private var quitArmedUntil = Date.distantPast

    /// Quits Companion. If it is in the middle of something (listening, or
    /// the agent working), the first request only asks; a second within
    /// three seconds quits. A slip does not end a live session.
    func requestQuit() {
        let busy = isListening || agentRunning
        if busy, Date() > quitArmedUntil {
            quitArmedUntil = Date().addingTimeInterval(3)
            lastError = "Companion is \(agentRunning ? "working on a task" : "listening"). Quit again to close it."
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - Side panel: details and browser

    /// Opens the column on the right in the given mode, closes it with nil,
    /// and gives the panel the width it needs.
    func showSide(_ mode: SidePanelMode?) {
        // In code the workspace is what the right column comes back to:
        // closing the details or the browser returns to it, not to plain chat.
        let mode = (mode == nil && codeMode) ? .workspace : mode
        // Closing the column, or switching to the details, brings the chat back.
        if mode == nil || mode == .details { sideFull = false }
        sidePanel = mode
        overlay?.setRightRoom(mode?.width ?? 0)
    }

    /// Shows a page in the browser beside the chat.
    func browse(_ url: URL) {
        showSide(.browser)
        web.open(url)
    }

    /// An address as typed: a full one, a bare domain, or words to search for.
    func browse(_ text: String) {
        if let url = BrowserModel.url(from: text) { browse(url) }
    }

    /// Every step the agent has taken in this conversation.
    private var sessionSteps: [WorkStep] {
        conversation.turns.flatMap { $0.steps ?? [] }
    }

    /// The checklist of the newest task that kept one.
    var sessionPlan: [PlanItem]? {
        conversation.turns.last { $0.plan?.isEmpty == false }?.plan
    }

    /// What one request in the session drew on and produced, for the
    /// details beside the chat.
    struct TaskUse: Identifiable {
        let id: UUID
        /// The request, as it was written.
        let title: String
        let date: Date
        /// The engine and model that did the work ("Claude Code · Opus").
        var model = ""
        /// Names of the files attached with it.
        var uploads: [String] = []
        var web: [String] = []
        var reads: [String] = []
        /// Files it created or changed, as full paths.
        var edits: [String] = []
        /// The commands it ran, in order.
        var commands: [String] = []
        /// When the request after it was made, if there is one: the end
        /// of the stretch this request's changes fall in.
        var until: Date?
        /// Which of the user's material the answer drew on.
        var sources: [String] = []

        var isEmpty: Bool {
            uploads.isEmpty && web.isEmpty && reads.isEmpty && edits.isEmpty && commands.isEmpty && sources.isEmpty
        }
    }

    /// The requests in this chat that used something, oldest first.
    var sessionTasks: [TaskUse] {
        let turns = conversation.turns
        return turns.enumerated().compactMap { index, turn -> TaskUse? in
            let steps = turn.steps ?? []
            var use = TaskUse(id: turn.id, title: turn.prompt, date: turn.date)
            use.until = index + 1 < turns.count ? turns[index + 1].date : nil
            use.model = turn.model
            use.uploads = turn.attached ?? []
            use.web = subjects(in: steps, of: ["Fetched ", "Searched the web for "], kind: .web).map {
                $0.contains("://") || $0.contains(" ") || !$0.contains(".") ? $0 : "https://" + $0
            }
            use.reads = subjects(in: steps, of: ["Read "], kind: .read)
            use.edits = subjects(in: steps, of: ["Wrote ", "Edited "], kind: .edit).map {
                AgentTools.resolve($0, in: agentStartDirectory)
            }
            use.commands = steps.filter { $0.kind == .run }.map(\.title)
            use.sources = turn.sources ?? []
            return use.isEmpty ? nil : use
        }
    }

    /// Opens a file in the workspace's editor, bringing the workspace up.
    /// The path may be as the agent wrote it: relative to its folder, and
    /// with a range of lines on the end ("src/app.py:40-90").
    func openInWorkspace(_ path: String) {
        var target = path
        if let colon = target.lastIndex(of: ":"),
           target[target.index(after: colon)...].allSatisfy({ $0.isNumber || $0 == "-" }) {
            target = String(target[..<colon])
        }
        let full = AgentTools.resolve(target, in: agentStartDirectory)
        // Opening a file always brings up code mode.
        if !codeMode { setCode(true) }
        if sidePanel != .workspace { showSide(.workspace) }
        workspace.use(root: workspaceRoot)
        // Edits to the file being left are kept, not dropped.
        if workspace.dirty { workspace.save(conversation: conversation.id) }
        workspace.open(full)
    }

    /// Opens several files at once, each in its own tab of the editor,
    /// bringing up code mode. The last one chosen is shown.
    func openInWorkspace(all paths: [String]) {
        guard !paths.isEmpty else { return }
        if !codeMode { setCode(true) }
        if sidePanel != .workspace { showSide(.workspace) }
        workspace.use(root: workspaceRoot)
        let full = paths.map { AgentTools.resolve($0, in: agentStartDirectory) }
        workspace.open(all: full, conversation: conversation.id)
    }

    /// Asks for any number of files and opens them all in code mode.
    func pickFilesToOpen() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Open"
        panel.message = "Choose one or more files. Each opens in its own tab (⌘-click or ⇧-click to pick several)."
        panel.directoryURL = URL(fileURLWithPath: workspaceRoot)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        openInWorkspace(all: panel.urls.map(\.path))
    }

    /// Shows what a request changed in a file, side by side in the
    /// workspace: the file as it was before the request's first change to
    /// it, and as it was after its last. A file with no change on record
    /// is simply opened.
    func showEdit(_ path: String, of task: TaskUse) {
        let from = task.date.addingTimeInterval(-1)
        // Changes are kept newest first.
        let changes = ChangeStore.shared.changes.filter {
            $0.path == path && $0.conversation == conversation.id && $0.date >= from
                && (task.until == nil || $0.date < task.until!)
        }
        guard let newest = changes.first, let oldest = changes.last else {
            openInWorkspace(path)
            return
        }
        if !codeMode { setCode(true) }
        if sidePanel != .workspace { showSide(.workspace) }
        workspace.use(root: workspaceRoot)
        let count = changes.count
        workspace.showDiff(DiffDocument(
            title: workspace.relative(path),
            subtitle: "\(count) change\(count == 1 ? "" : "s")  ·  " + String(task.title.prefix(80)),
            before: ChangeStore.shared.text(oldest.before),
            after: ChangeStore.shared.text(newest.after),
            path: FileManager.default.fileExists(atPath: path) ? path : nil))
    }

    /// A site's own icon, when its page has been open in the browser here.
    func siteIcon(for address: String) -> NSImage? {
        webHistory.icon(for: address)
    }

    private func subjects(of prefixes: [String], kind: WorkStep.Kind) -> [String] {
        subjects(in: sessionSteps, of: prefixes, kind: kind)
    }

    private func subjects(in steps: [WorkStep], of prefixes: [String], kind: WorkStep.Kind) -> [String] {
        var seen: Set<String> = []
        var found: [String] = []
        for step in steps where step.kind == kind && !step.failed {
            guard let prefix = prefixes.first(where: { step.title.hasPrefix($0) }) else { continue }
            let subject = String(step.title.dropFirst(prefix.count))
            if seen.insert(subject).inserted { found.append(subject) }
        }
        return found
    }

    /// Files the agent wrote or changed, as full paths.
    var sessionOutputs: [String] {
        subjects(of: ["Wrote ", "Edited "], kind: .edit).map {
            AgentTools.resolve($0, in: agentStartDirectory)
        }
    }

    /// Pages fetched (addresses) and web searches (their words).
    var sessionWeb: [String] {
        subjects(of: ["Fetched ", "Searched the web for "], kind: .web).map {
            $0.contains("://") || $0.contains(" ") || !$0.contains(".") ? $0 : "https://" + $0
        }
    }

    /// Files the agent read.
    var sessionReads: [String] {
        subjects(of: ["Read "], kind: .read)
    }

    var sessionCommandCount: Int {
        sessionSteps.filter { $0.kind == .run }.count
    }

    /// Next steps suggested after the newest answer, for the card above the
    /// chat box. Only the newest answer's are offered: older ones are stale.
    var nextSteps: (turn: UUID, steps: [String])? {
        guard let last = conversation.turns.last, !streamingTurns.contains(last.id),
              let steps = last.suggestions, !steps.isEmpty else { return nil }
        return (last.id, steps)
    }

    /// Puts an answer's suggestions away, once one is chosen or they are
    /// dismissed.
    func dismissSuggestions(_ turnID: UUID) {
        updateTurn(turnID) { $0.suggestions = nil }
        persist()
    }

    /// The user's answer to the agent's question: a choice they picked, or
    /// what they typed. The task carries on with it.
    func answerAgent(_ text: String) {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, pendingQuestion != nil else { return }
        questionAnswer?.resume(returning: answer)
        questionAnswer = nil
    }

    /// The user's answer to the steps the agent is waiting on.
    func decide(_ decision: AgentDecision) {
        approval?.resume(returning: decision)
        approval = nil
    }

    /// Brings the panel up with the cursor in the input box, from any app,
    /// without switching away from that app.
    func askFromAnywhere() {
        showHistory = false
        if compact { overlay?.setCompact(false) }
        overlay?.focusInput()
        focusInputRequest += 1
    }

    /// Sends a message as if the user had typed it: a suggested next step.
    func send(_ text: String) {
        draft = text
        sendDraft()
    }

    /// Stops the agent, whatever it is doing, and always leaves it ready
    /// for a new task: the running command is ended, typing stops, a pending
    /// question is answered with no, and the running state is cleared here
    /// and now rather than when the task gets round to noticing.
    func stopAgent() {
        followUpTask?.cancel()
        guard agentRunning else { return }
        DeviceControl.shared.cancel()
        agentRun?.cancel()
        Task { await AgentShell.shared.cancel() }
        if let id = agentTurnID, conversation.turns.first(where: { $0.id == id })?.answer.isEmpty == false {
            updateTurn(id) { $0.answer += "\n\nStopped." }
        }
        // From here the old task no longer owns the state.
        agentGeneration += 1
        endAgent()
    }

    private func ask(_ question: String, reusing existing: UUID? = nil) {
        let prior: [ChatTurn]
        let turnID: UUID
        if let existing, let index = conversation.turns.firstIndex(where: { $0.id == existing }) {
            prior = Array(conversation.turns[..<index])
            turnID = existing
        } else {
            prior = conversation.turns
            turnID = appendTurn(ChatTurn(kind: .reply, origin: .typed, prompt: question, model: engineLabel))
        }
        let transcript = Array(segments.suffix(ContextBudget.current.transcriptLines(.ask)))
        run(turnID: turnID, kind: .reply, reveal: true) {
            try await self.suggester.askStream(question: question, history: prior, transcript: transcript)
        }
    }

    // MARK: - Screen thread

    /// Captures the screen, shows the capture in the thread and answers it.
    ///
    /// If the screen is the same as the previous capture and no specific
    /// question was typed, that turn is refreshed instead of adding a duplicate.
    func answerScreenNow(question: String? = nil) {
        lastError = nil
        showHistory = false
        overlay?.showPanel()
        let placeholder = appendTurn(ChatTurn(kind: .screen,
                                              origin: question == nil ? .manual : .typed,
                                              prompt: question ?? "What's on my screen?",
                                              model: engineLabel))
        streamingTurns.insert(placeholder)
        let conversationID = conversation.id
        Task { @MainActor in
            do {
                let shot = try await ScreenReader.capture()
                guard conversation.id == conversationID,
                      conversation.turns.contains(where: { $0.id == placeholder }) else { return }
                var target = placeholder
                if question == nil,
                   let previous = conversation.turns.last(where: { $0.kind == .screen && $0.id != placeholder }),
                   let context = previous.context,
                   // An answer being read aloud is left exactly as it is.
                   (previous.spoken ?? 0) == 0,
                   Self.similarity(context, shot.text) >= 0.85 {
                    conversation.turns.removeAll { $0.id == placeholder }
                    streamingTurns.remove(placeholder)
                    if let old = previous.imageFile {
                        store.deleteImage(conversation: conversationID, file: old)
                    }
                    target = previous.id
                }
                let file = store.saveThumbnail(shot.image, conversation: conversationID)
                updateTurn(target) {
                    $0.imageFile = file
                    $0.context = shot.text
                }
                // The picture itself goes to engines that can see, so
                // diagrams and figures are read, not just the text.
                let picture = ScreenReader.jpeg(shot.image)
                // Refreshing an answer that is already there: keep it on
                // screen and change it only if the new one differs.
                let kept = target == placeholder ? "" : (conversation.turns.first { $0.id == target }?.answer ?? "")
                run(turnID: target, kind: .screen, reveal: true, keeping: kept) {
                    // The app, window and page address go along with the text.
                    let info = ScreenReader.frontInfo()
                    let header = ScreenContext(app: info.app, window: info.window, url: info.url, text: "").header
                    return try await self.suggester.screenAnswerStream(screenText: header + "\n\n" + shot.text,
                                                                       question: question,
                                                                       transcript: Array(self.segments.suffix(10)),
                                                                       image: picture)
                }
            } catch {
                streamingTurns.remove(placeholder)
                updateTurn(placeholder) { $0.error = error.localizedDescription }
            }
        }
    }

    /// Used by the screen watcher, which already has the OCR text. OCR output
    /// jitters between captures, so the screen is compared by similarity:
    /// unchanged screens are ignored, a slightly changed one updates the last
    /// automatic turn, and only a different screen starts a new turn.
    func answerScreen(with text: String) {
        guard !isAnsweringScreen else { return }
        if let last = conversation.turns.last(where: { $0.kind == .screen }), let previous = last.context {
            let overlap = Self.similarity(previous, text)
            if overlap >= 0.85 {
                return
            }
            if overlap >= 0.5, last.origin == .auto {
                updateTurn(last.id) { $0.context = text }
                run(turnID: last.id, kind: .screen, reveal: false, keeping: last.answer) {
                    try await self.suggester.screenAnswerStream(screenText: text,
                                                                question: nil,
                                                                transcript: Array(self.segments.suffix(10)))
                }
                return
            }
        }
        let turnID = appendTurn(ChatTurn(kind: .screen,
                                         origin: .auto,
                                         prompt: "New question on screen",
                                         context: text,
                                         model: engineLabel))
        run(turnID: turnID, kind: .screen, reveal: true) {
            try await self.suggester.screenAnswerStream(screenText: text,
                                                        question: nil,
                                                        transcript: Array(self.segments.suffix(10)))
        }
    }

    // MARK: - Turn actions

    func regenerate(_ turnID: UUID) {
        guard let turn = conversation.turns.first(where: { $0.id == turnID }) else { return }
        switch turn.kind {
        case .reply:
            if turn.origin == .typed {
                ask(turn.prompt, reusing: turnID)
            } else {
                let transcript = Array(segments.suffix(ContextBudget.current.transcriptLines(.screen)))
                run(turnID: turnID, kind: .reply, reveal: true) {
                    try await self.suggester.replyStream(transcript: transcript)
                }
            }
        case .screen:
            let question = turn.origin == .typed ? turn.prompt : nil
            if let context = turn.context {
                // The saved capture, smaller than the original but still a picture.
                let picture = turn.imageFile.flatMap {
                    try? Data(contentsOf: store.imageURL(conversation: conversation.id, file: $0))
                }
                run(turnID: turnID, kind: .screen, reveal: true) {
                    try await self.suggester.screenAnswerStream(screenText: context,
                                                                question: question,
                                                                transcript: Array(self.segments.suffix(10)),
                                                                image: picture)
                }
            } else {
                deleteTurn(turnID)
                answerScreenNow(question: question)
            }
        }
    }

    /// Whether a suggested reply was actually said: judged by how much of it
    /// the user spoke aloud. nil while that is still open, and for turns that
    /// were never meant to be spoken (typed questions, screen answers).
    func usage(of turn: ChatTurn) -> TurnUsage? {
        guard turn.kind == .reply, turn.origin != .typed, turn.error == nil, !turn.answer.isEmpty else { return nil }
        let total = Self.normalizedWords(turn.answer).count
        guard total > 0 else { return nil }
        let share = Double(turn.spoken ?? 0) / Double(total)
        if share >= 0.5 { return .used }
        if share >= 0.15 { return .partly }
        // Not said, and the user has spoken since: it was passed over.
        let position = turn.anchor ?? turn.date
        let movedOn = segments.contains { $0.isFinal && $0.speaker == .me && $0.timestamp > position }
        return movedOn ? .unused : nil
    }

    var unusedReplyCount: Int {
        conversation.turns.filter { isLeftover($0) }.count
    }

    /// An automatic reply that was not said, or that the recheck found
    /// matches nothing in the conversation.
    private func isLeftover(_ turn: ChatTurn) -> Bool {
        guard turn.origin == .auto, turn.kind == .reply, !streamingTurns.contains(turn.id) else { return false }
        return usage(of: turn) == .unused || turn.matched == false
    }

    /// Second half of a recheck: goes back over the suggested replies and
    /// checks each against the corrected transcript. A reply written for a
    /// line that turned out to be misheard, or to be the user's own, no
    /// longer matches anything.
    private func verifyReplies() async {
        let candidates = Array(conversation.turns
            .filter { $0.kind == .reply && $0.origin != .typed && $0.error == nil && !$0.answer.isEmpty
                && !streamingTurns.contains($0.id) }
            .suffix(15))
        let transcript = Array(segments.filter(\.isFinal).suffix(80))
        guard !candidates.isEmpty, !transcript.isEmpty else { return }
        do {
            let output = try await suggester.verifyReplies(
                transcript: transcript,
                replies: candidates.map { (question: $0.prompt, answer: $0.answer) })
            for rawLine in output.components(separatedBy: .newlines) {
                let parts = rawLine.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                      let number = Int(parts[0].filter(\.isNumber)),
                      number >= 1, number <= candidates.count else { continue }
                let verdict = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
                guard verdict.hasPrefix("yes") || verdict.hasPrefix("no") else { continue }
                updateTurn(candidates[number - 1].id) { $0.matched = verdict.hasPrefix("yes") }
            }
            persist()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Removes the automatic replies that were never said, so what is kept is
    /// the conversation as it actually went.
    func cleanUnusedReplies() {
        let unused = conversation.turns.filter { isLeftover($0) }.map(\.id)
        for id in unused {
            deleteTurn(id)
        }
    }

    /// Puts a turn's prompt back into the input bar to edit and resend.
    func reuse(_ turnID: UUID) {
        guard let turn = conversation.turns.first(where: { $0.id == turnID }) else { return }
        draft = turn.prompt
        attachScreen = turn.kind == .screen
    }

    func deleteTurn(_ turnID: UUID) {
        guard let turn = conversation.turns.first(where: { $0.id == turnID }) else { return }
        if runningTurn[turn.kind] == turnID {
            tasks[turn.kind]?.cancel()
            runningTurn[turn.kind] = nil
        }
        streamingTurns.remove(turnID)
        if let file = turn.imageFile {
            store.deleteImage(conversation: conversation.id, file: file)
        }
        conversation.turns.removeAll { $0.id == turnID }
        persist()
    }

    // MARK: Checkpoints

    // Every message is a checkpoint: the chat and its files as they were
    // just before it. Going back to one puts the files back, takes the
    // messages from there on out of the chat, and so also returns the
    // session's outputs and what it used to that stage.

    /// Whether files have been changed in this chat since a message was
    /// sent, so there is something to go back to before it.
    func hasCheckpoint(_ turn: ChatTurn) -> Bool {
        guard let last = ChangeStore.shared.lastChange(of: conversation.id) else { return false }
        return last >= turn.date
    }

    /// What going back to before a message would do: how many files would
    /// be put back and how many messages would leave the chat.
    func checkpoint(before turnID: UUID) -> (files: Int, turns: Int)? {
        guard let index = conversation.turns.firstIndex(where: { $0.id == turnID }) else { return nil }
        let since = conversation.turns[index].date.addingTimeInterval(-1)
        let files = ChangeStore.shared.stage(of: conversation.id, at: since).count
        return (files, conversation.turns.count - index)
    }

    /// Goes back to just before a message: the files this chat changed
    /// since are put back as they were, the message and everything after
    /// it leave the chat, and its words return to the chat box to be sent
    /// again or changed. In a git repository the result is committed as a
    /// new commit; no history is rewritten. What commands did outside of
    /// files (installs, pushes) is not undone.
    func restoreCheckpoint(before turnID: UUID) {
        guard let index = conversation.turns.firstIndex(where: { $0.id == turnID }) else { return }
        if agentRunning { stopAgent() }
        cancelRuns()
        let turn = conversation.turns[index]
        let label = String(turn.prompt.prefix(60))
        let result = ChangeStore.shared.rewind(conversation: conversation.id,
                                               to: turn.date.addingTimeInterval(-1), label: label)
        for later in conversation.turns[index...] {
            if let file = later.imageFile {
                store.deleteImage(conversation: conversation.id, file: file)
            }
        }
        conversation.turns.removeSubrange(index...)
        // The agent's own record of what it did is of work now undone.
        agentLog = []
        agentContext = []
        agentOutputs = [:]
        agentPlan = []
        unfinishedReport = ""
        draft = turn.prompt
        lastError = result.failed > 0
            ? "\(result.failed) file\(result.failed == 1 ? "" : "s") could not be put back. See Changes in the workspace."
            : nil
        persist()
        workspace.refreshAll()
        if let open = workspace.openPath { workspace.reloadIfOpen(open) }
        Task { @MainActor in
            await ChangeStore.shared.commitPending(message: "restore checkpoint before \(label)")
            GitModel.shared.refresh()
        }
    }

    func copy(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Attached files

    var attachments: [Attachment] { conversation.attachments ?? [] }

    /// What the "+" menu can add.
    enum AttachmentKind {
        case files, images, folder
    }

    /// Opens a picker and attaches what was chosen: files of any kind,
    /// images, or a whole folder.
    func pickAttachments(_ kind: AttachmentKind = .files) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = kind == .folder
        panel.canChooseFiles = kind != .folder
        if kind == .images {
            panel.allowedContentTypes = [.image]
        }
        switch kind {
        case .files: panel.message = "Attach files as context: documents, reports, code, anything readable"
        case .images: panel.message = "Attach images. Text in them is read."
        case .folder: panel.message = "Attach a folder. Companion reads it, and the agent can work in it."
        }
        panel.prompt = "Attach"
        // Above the overlay, which floats at status-bar level.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in self?.attach(urls) }
        }
    }

    /// Reads each file or folder and keeps it with the conversation, along
    /// with where it lives so the agent can open or change it.
    func attach(_ urls: [URL]) {
        Task { @MainActor in
            var unreadable: [String] = []
            for url in urls.prefix(8) {
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                let folder = isDirectory.boolValue
                let text: String?
                if folder {
                    text = FileTextExtractor.extractFolder(url)
                } else {
                    text = await FileTextExtractor.extract(url)
                }
                if let text {
                    var files = conversation.attachments ?? []
                    files.removeAll { $0.path == url.path || ($0.path == nil && $0.name == url.lastPathComponent) }
                    let file = Attachment(name: url.lastPathComponent, text: text,
                                          path: url.path, isFolder: folder ? true : nil)
                    files.append(file)
                    conversation.attachments = Array(files.suffix(8))
                    pendingAttachments.append(file.id)
                } else {
                    unreadable.append(url.lastPathComponent)
                }
            }
            lastError = unreadable.isEmpty
                ? nil
                : "Couldn't read text from: \(unreadable.joined(separator: ", "))"
            persist()
        }
    }

    /// For the agent: what the user attached and where it is. These are the
    /// things it was handed to work on.
    private var attachedPathsNote: String {
        let located = attachments.filter { $0.path != nil }
        guard !located.isEmpty else { return "" }
        let lines = located.map { "- \($0.path ?? "")\($0.isFolder == true ? "/ (folder)" : "")" }
        return "\n\nAttached by the user for this conversation. You may read these and, when the task calls for it, change them:\n"
            + lines.joined(separator: "\n")
    }

    /// Where the agent's shell starts: the folder attached last, or else the
    /// working folder from Settings.
    var agentStartDirectory: String {
        conversation.workFolder
            ?? attachments.last { $0.isFolder == true }?.path
            ?? AppSettings.shared.agentDirectory
    }

    /// Whether this chat has a folder for the code side to work in: one
    /// chosen for it, or one attached to the chat.
    var hasWorkFolder: Bool {
        conversation.workFolder != nil || attachments.contains { $0.isFolder == true }
    }

    /// How much the agent does in this chat without asking: the chat's own
    /// choice, or the setting for new chats.
    var agentAccess: AgentAccess {
        AgentAccess(rawValue: conversation.access ?? "")
            ?? AgentAccess(rawValue: AppSettings.shared.agentAccess) ?? .manual
    }

    func setAgentAccess(_ access: AgentAccess) {
        conversation.access = access.rawValue
        persist()
    }

    /// Switches between the two sides of the app. Chat and code share the
    /// same list of conversations, search and "new"; code adds the
    /// workspace, and what is sent there is work on the chat's repository.
    func setCode(_ on: Bool) {
        codeMode = on
        if on {
            showSide(.workspace)
        } else if sidePanel == .workspace {
            showSide(nil)
        }
    }

    /// A note for the agent on the repository a code chat works in.
    private var repositoryNote: String {
        guard codeMode, hasWorkFolder else { return "" }
        let folder = agentStartDirectory
        return "\n\nThis is a code chat. The repository to work in and maintain is \(folder). Keep your work inside it unless told otherwise."
    }

    /// Asks for the folder this chat's code side works in, and opens the
    /// workspace on it. The agent's shell starts there too. `then` runs
    /// once a folder has been chosen.
    func pickWorkFolder(then: (() -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose the folder to work in. Files, search, changes and the terminal all start here."
        panel.prompt = "Work here"
        if let current = conversation.workFolder {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        // Above the overlay, which floats at status-bar level.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                self.conversation.workFolder = url.path
                self.persist()
                self.showSide(.workspace)
                then?()
            }
        }
    }

    func removeAttachment(_ id: UUID) {
        conversation.attachments?.removeAll { $0.id == id }
        pendingAttachments.removeAll { $0 == id }
        persist()
    }

    // MARK: - Conversations

    func refreshHistory() {
        let query = historyQuery.trimmingCharacters(in: .whitespaces)
        history = query.isEmpty ? store.list() : store.search(query)
    }

    /// The line under the app name: what Companion is doing, or why it did
    /// not draft a reply just now.
    var statusLine: String {
        if isListening, let replyHint { return replyHint }
        return statusText
    }

    /// Saves the current conversation (turns plus the final transcript lines).
    /// Empty conversations are never written.
    func persist() {
        let lines = segments.filter(\.isFinal).suffix(Self.maxSegments).map {
            SavedLine(isMe: $0.speaker == .me, tag: $0.tag, text: $0.text, original: $0.original,
                      systemAudio: $0.systemAudio ? true : nil,
                      date: $0.timestamp)
        }
        guard !conversation.turns.isEmpty || !lines.isEmpty || !attachments.isEmpty else { return }
        conversation.transcript = Array(lines)
        if let id = lastSummarizedID,
           let index = segments.filter(\.isFinal).firstIndex(where: { $0.id == id }) {
            conversation.summarizedLines = index + 1
        } else {
            conversation.summarizedLines = 0
        }
        if conversation.title == Conversation.defaultTitle {
            let seed = conversation.turns.first?.prompt ?? lines.first?.text ?? ""
            if !seed.isEmpty {
                conversation.title = String(seed.prefix(48))
            }
        }
        // The time of the last thing said or answered, not of this save:
        // reading an old conversation must not move it to the top.
        conversation.updatedAt = conversation.lastActivity
        store.save(conversation)
        refreshHistory()
    }

    /// What the agent did belongs to the conversation it did it in: a new or
    /// reopened conversation starts without it.
    private func forgetAgentWork() {
        stopAgent()
        unfinishedReport = ""
        pendingAttachments = []
        agentLog = []
        agentContext = []
        agentOutputs = [:]
        agentPlan = []
    }

    func newConversation() {
        persist()
        cancelRuns()
        forgetAgentWork()
        conversation = Conversation()
        segments = []
        replySpokenWords = 0
        screenSpokenWords = 0
        lastError = nil
        showHistory = false
    }

    /// Reopens a saved conversation so it can be continued.
    func openConversation(_ id: UUID) {
        guard id != conversation.id else {
            showHistory = false
            return
        }
        persist()
        cancelRuns()
        forgetAgentWork()
        guard let loaded = store.load(id) else {
            refreshHistory()
            return
        }
        conversation = loaded
        segments = loaded.transcript.map {
            TranscriptSegment(id: UUID(),
                              utteranceID: UUID(),
                              speaker: $0.isMe ? .me : .them,
                              tag: $0.tag,
                              text: $0.text,
                              isFinal: true,
                              seq: Int.max,
                              timestamp: $0.date ?? loaded.updatedAt,
                              // Saved lines are settled; never re-polish them.
                              original: $0.original ?? $0.text,
                              systemAudio: $0.systemAudio ?? false)
        }
        // Lines already folded into the notes must not be folded again.
        if let count = loaded.summarizedLines, count > 0, count <= segments.count {
            lastSummarizedID = segments[count - 1].id
        }
        replySpokenWords = 0
        screenSpokenWords = 0
        lastError = nil
        showHistory = false
    }

    /// Gives a conversation a name of the user's choosing. A named
    /// conversation keeps its name; only an unnamed one is titled from
    /// its first words.
    func renameConversation(_ id: UUID, to name: String) {
        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !title.isEmpty else { return }
        if id == conversation.id {
            conversation.title = title
            persist()
        } else if var other = store.load(id) {
            other.title = title
            store.save(other)
        }
        refreshHistory()
    }

    /// How much the open conversation holds, counting what has been heard
    /// since it was last saved.
    var contextUse: ContextUse {
        conversation.contextUse(spoken: segments.reduce(0) { $0 + $1.text.utf8.count })
    }

    func deleteConversation(_ id: UUID) {
        endWebSession(of: id)
        store.delete(id)
        if id == conversation.id {
            cancelRuns()
            conversation = Conversation()
            segments = []
        }
        refreshHistory()
    }

    /// Fetches the models the Farhelm gateway offers, for the inline switcher.
    func loadFarhelmModels() {
        let key = Keychain.read("farhelm") ?? ProcessInfo.processInfo.environment["FARHELM_API_KEY"] ?? ""
        guard !key.isEmpty else { return }
        let base = AppSettings.shared.farhelmURL
        Task { @MainActor in
            if let models = try? await ModelCatalog.openAIStyleModels(base: base, bearer: key) {
                farhelmModels = models
            }
        }
    }

    /// Fetches the Claude models this API key can use, for the model pickers.
    func loadAnthropicModels() {
        let key = Keychain.read("anthropic") ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        guard !key.isEmpty else {
            anthropicModelsStatus = "Add an API key to load your models"
            return
        }
        anthropicModelsStatus = "Loading…"
        Task { @MainActor in
            do {
                let models = try await ModelCatalog.anthropicModels(key: key)
                if models.isEmpty {
                    anthropicModelsStatus = "The API reported no models"
                } else {
                    anthropicModels = models
                    anthropicModelsStatus = "\(models.count) available"
                }
            } catch {
                anthropicModelsStatus = error.localizedDescription
            }
        }
    }

    // MARK: - Read-along: follow the user's voice through the newest answer

    private func lastAnswer(_ kind: TurnKind) -> String {
        conversation.turns.last { $0.kind == kind }?.answer ?? ""
    }

    private func startTracking(_ kind: TurnKind) {
        activeKind = kind
        spokenCommitted = 0
        trackedUtterance = nil
        switch kind {
        case .reply: replySpokenWords = 0
        case .screen: screenSpokenWords = 0
        }
    }

    /// Matches what the mic hears against the newest answer in the thread that
    /// ran last, so it dims what was already said and scrolls along.
    private func updateReadingProgress(_ spoken: String, utterance: UUID, isFinal: Bool) {
        let script = lastAnswer(activeKind)
        guard !script.isEmpty else { return }
        let scriptWords = Self.normalizedWords(script)
        guard !scriptWords.isEmpty else { return }
        if trackedUtterance != utterance {
            trackedUtterance = utterance
            spokenCommitted = activeKind == .reply ? replySpokenWords : screenSpokenWords
        }
        var position = spokenCommitted
        for word in Self.normalizedWords(spoken) {
            let limit = min(position + 10, scriptWords.count)
            var index = position
            while index < limit {
                if scriptWords[index] == word {
                    position = index + 1
                    break
                }
                index += 1
            }
        }
        switch activeKind {
        case .reply: replySpokenWords = position
        case .screen: screenSpokenWords = position
        }
        // Remembered on the turn: this is how a reply is known to have been used.
        let kind = activeKind
        if let turn = conversation.turns.last(where: { $0.kind == kind && !$0.answer.isEmpty }),
           position > (turn.spoken ?? 0) {
            updateTurn(turn.id) { $0.spoken = position }
        }
        if isFinal {
            spokenCommitted = position
            trackedUtterance = nil
        }
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    // MARK: - Screen watcher

    private func startScreenWatcher() {
        if screenWatcher == nil {
            let watcher = ScreenWatcher()
            watcher.onQuestion = { [weak self] text in
                self?.answerScreen(with: text)
            }
            screenWatcher = watcher
        }
        screenWatcher?.start()
    }

    private func stopScreenWatcher() {
        screenWatcher?.stop()
    }

    /// Opens Settings inside the panel, bringing the panel up if needed.
    /// `tab` names the section to open on ("Engine", "You", "Listening"…),
    /// matching the raw values of SettingsView's tabs.
    func openSettings(tab: String? = nil) {
        if let tab { UserDefaults.standard.set(tab, forKey: "settingsTab") }
        showHistory = false
        showSettings = true
        overlay?.setCompact(false)
        overlay?.showPanel()
    }

    // MARK: - Reference voices

    /// Learns what other people sound like from a folder of recordings (for
    /// example LibriSpeech), one voiceprint per person.
    func importReferenceVoices(from folder: URL) {
        guard referenceImport == nil else { return }
        referenceImport = "Loading the voice models…"
        Task { @MainActor in
            do {
                let added = try await speakerID.importReferenceVoices(from: folder) { done, total in
                    Task { @MainActor in
                        if self.referenceImport != nil {
                            self.referenceImport = "Listening to voice \(min(done + 1, total)) of \(total)…"
                        }
                    }
                }
                referenceVoices = await speakerID.referenceVoiceCount()
                referenceImport = nil
                statusText = "Added \(added) reference voices"
            } catch {
                referenceImport = nil
                statusText = "Could not add voices: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Voice enrollment (who is "You" on the mic)

    /// Sentences the user reads aloud during voice setup. Varied sounds and a
    /// natural speaking rhythm give the diarizer a representative sample.
    static let enrollmentPhrases = [
        "Hey Companion, this is my voice, and this is how I usually speak.",
        "I like to keep my answers clear, short and friendly.",
        "The quick brown fox jumps over the lazy dog near the quiet river.",
        "Could you tell me more about the pricing, the timeline and the next steps?",
        "Thanks for joining today. Let's go through the plan together."
    ]

    /// Guided voice setup: the user reads each phrase aloud; a phrase is done
    /// once enough of it has been heard and they pause (or clearly finish).
    func enrollVoice() {
        guard !isEnrollingVoice else { return }
        isEnrollingVoice = true
        enrollStep = 0
        enrollStepProgress = 0
        enrollMessage = nil
        enrollSucceeded = false
        lastError = nil
        enrollTask = Task { @MainActor in
            defer {
                isEnrollingVoice = false
                enrollLevel = 0
            }
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                enrollMessage = "Microphone access denied. Enable Companion in System Settings > Privacy & Security > Microphone."
                return
            }
            let wasListening = isListening
            if wasListening {
                stop()
                await teardown?.value
            }

            let (stream, continuation) = AsyncStream<[Float]>.makeStream()
            let capture = MicCapture()
            capture.onSamples = { continuation.yield($0) }
            do {
                try capture.start()
            } catch {
                enrollMessage = "Could not start the microphone: \(error.localizedDescription)"
                return
            }
            defer {
                capture.stop()
                continuation.finish()
            }

            let frameSize = 1600                       // 100 ms
            let neededVoiced = 2 * 16000               // 2 s of speech per phrase
            var recorded: [Float] = []
            var pending: [Float] = []
            var voiced = 0
            var quietAfterSpeech = 0

            reading: for await chunk in stream {
                if Task.isCancelled { break reading }
                recorded.append(contentsOf: chunk)
                pending.append(contentsOf: chunk)
                while pending.count >= frameSize {
                    var sum: Float = 0
                    for sample in pending.prefix(frameSize) { sum += sample * sample }
                    pending.removeFirst(frameSize)
                    let rms = sqrt(sum / Float(frameSize))
                    enrollLevel = min(1, rms * 18)
                    if rms >= 0.006 {
                        voiced += frameSize
                        quietAfterSpeech = 0
                    } else if voiced > 0 {
                        quietAfterSpeech += frameSize
                    }
                    enrollStepProgress = min(1, Double(voiced) / Double(neededVoiced))
                    let finishedPhrase = voiced >= neededVoiced
                        && (quietAfterSpeech >= 6 * frameSize || voiced >= neededVoiced + 3 * 16000)
                    if finishedPhrase {
                        if enrollStep + 1 >= Self.enrollmentPhrases.count {
                            break reading
                        }
                        enrollStep += 1
                        enrollStepProgress = 0
                        voiced = 0
                        quietAfterSpeech = 0
                    }
                }
            }
            if Task.isCancelled {
                if wasListening { start() }
                return
            }
            capture.stop()
            enrollLevel = 0
            enrollMessage = "Saving your voice…"
            do {
                try await speakerID.enroll(samples: recorded)
                voiceEnrolled = true
                enrollSucceeded = true
                enrollMessage = nil
            } catch {
                enrollMessage = "Voice setup failed: \(error.localizedDescription)"
            }
            if wasListening { start() }
        }
    }

    func cancelEnrollment() {
        enrollTask?.cancel()
        enrollTask = nil
    }
}
