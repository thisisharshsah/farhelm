import Foundation
import AppKit
import AVFoundation
import Combine
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
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    private let log = Logger(subsystem: "com.harshsah.companion", category: "app")

    // Listening
    @Published var isListening = false
    @Published var statusText = "Idle"
    @Published var modelReady = false
    @Published var segments: [TranscriptSegment] = []
    @Published var lastError: String?
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var voiceEnrolled = false
    @Published var isEnrollingVoice = false
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
    /// What the history list is filtered by.
    @Published var historyQuery = ""
    /// The panel is shrunk to a strip with just the newest answer.
    @Published var compact = false
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
    /// Steps the agent wants to take, waiting for the user's yes or no.
    @Published var pendingApproval: AgentProposal?
    private var approval: CheckedContinuation<AgentDecision, Never>?
    /// What the model is told has happened so far, results included.
    private var agentContext: [String] = []
    /// What the agent last told the user, so the follow-up does not repeat it.
    private var lastAgentReport = ""
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
    private var polishBackoffUntil = Date.distantPast
    private var bag = Set<AnyCancellable>()
    /// Last identified voice on the mic, so short or ambiguous utterances can
    /// inherit it instead of defaulting to the user.
    private var lastMicLabel: (speaker: Speaker, tag: String?, at: Date)?
    /// The "their turn" the newest automatic reply belongs to.
    private var lastAutoRunKey: UUID?
    private var lastAutoTurnID: UUID?
    private var lastAutoQuestion = ""
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
        }
        suggester.attachedFiles = { [weak self] in self?.attachments ?? [] }
        suggester.conversationID = { [weak self] in self?.conversation.id }
        suggester.agentActivity = { [weak self] in self?.agentActivity ?? "" }
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
            lastError = "Enable at least one audio source in Settings > Behavior."
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
        statusText = "Idle"
        autoSuggestWork?.cancel()
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
        statusText = "Idle"
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
                if !isListening { statusText = "Idle" }
            } catch {
                if !isListening {
                    statusText = "Idle"
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

    /// Re-labels every mic line of this session from the recorded audio, with
    /// the offline diarization pipeline. Returns whether anything changed.
    private func relabelByVoice() async -> Bool {
        let session = micSessionID
        let lines = segments.filter {
            $0.isFinal && !$0.systemAudio && $0.micSession == session && session != 0
                && $0.micStart != nil && $0.micEnd != nil
        }
        guard !lines.isEmpty else { return false }
        let ranges = lines.map { $0.micStart!..<max($0.micEnd!, $0.micStart! + 1) }
        let labels: [SpeakerLabel?]
        do {
            labels = try await speakerID.relabel(session: session, ranges: ranges)
        } catch {
            lastError = error.localizedDescription
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
                    // While the new answer is still retracing the kept draft,
                    // nothing changes on screen. It takes over where it first
                    // differs or grows past the draft.
                    // A hand-off to the agent is an instruction, not an answer:
                    // it is not shown while it arrives.
                    if Self.startsAgentHandOff(fresh) { continue }
                    if draft.isEmpty || !draft.hasPrefix(fresh) {
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
                if !Task.isCancelled, !draft.isEmpty,
                   !fresh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let text = fresh
                    self.updateTurn(turnID) { $0.answer = text }
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
        draft = ""
        lastError = nil
        // One chat box for everything: a message that asks for something to
        // be done on the Mac goes to the agent, anything else is answered.
        if Self.looksLikeTask(text) {
            runAgent(text)
        } else if attachScreen {
            answerScreenNow(question: text)
        } else {
            ask(text)
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
    /// it at any point, and it never runs more than 40 steps for one task.
    func runAgent(_ task: String, in existing: UUID? = nil) {
        // Problems are reported in the chat turn when the task came from one.
        func refuse(_ message: String) {
            if let existing {
                updateTurn(existing) { $0.answer = message }
            } else {
                lastError = message
            }
        }
        guard agentRun == nil else {
            refuse("The agent is still working on the last task. Press Stop to end it first.")
            return
        }
        lastError = nil
        agentTask = task
        agentLog = []
        agentContext = []
        agentOutputs = [:]
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
            defer {
                self.isPlanning = false
                self.isActing = false
                self.agentRun = nil
                self.pendingApproval = nil
                self.overlay?.restoreKeyboard()
                self.agentStatus = nil
                self.agentTask = nil
                if let id = self.agentTurnID {
                    self.streamingTurns.remove(id)
                    // Stopped without a verdict: say so in the chat.
                    if self.conversation.turns.first(where: { $0.id == id })?.answer.isEmpty == true {
                        self.finishAgent("Stopped.", failed: true)
                    }
                }
                self.persist()
            }
            var directory = AppSettings.shared.agentDirectory
            var keyboardAllowed = false
            var usedKeyboard = false
            var stepsRun = 0
            for _ in 0..<14 {
                if Task.isCancelled { return }
                self.isPlanning = true
                self.agentStatus = "Working out the next step"
                // One look gives the app, window, page address and text.
                let seen = await ScreenReader.read()
                let steps: [ActionStep]
                do {
                    let output = try await self.suggester.agentStep(task: task,
                                                                    directory: directory,
                                                                    frontApp: seen.header,
                                                                    screenText: seen.text,
                                                                    clickable: DeviceControl.shared.clickableLabels(),
                                                                    done: self.agentContext)
                    let plan = DeviceControl.parsePlan(output)
                    if let refusal = plan.refusal {
                        self.finishAgent("Can't do that: \(refusal)", failed: true)
                        return
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
                let asking = steps.filter { step in
                    switch step.kind {
                    case .run:
                        return !AgentPermissions.isAllowed(step.value, remembered: remembered, autoApproveReads: autoReads)
                    case .type, .key, .open, .click: return !keyboardAllowed
                    case .wait, .done, .ask: return false
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
                        if asking.contains(where: { $0.kind != .run }) {
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
                        self.finishAgent(step.value, failed: false, keepOpen: true)
                        await self.followUp(task: task, waitForScreen: usedKeyboard)
                        return
                    case .ask:
                        self.finishAgent(step.value, failed: true)
                        return
                    case .wait:
                        let seconds = min(max(Double(step.value.filter { $0.isNumber || $0 == "." }) ?? 2, 1), 10)
                        self.agentStatus = "Waiting"
                        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                        self.agentContext.append(step.label)
                    case .run:
                        self.agentStatus = "Running a command"
                        let result = await AgentShell.shared.run(step.value, in: directory)
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
                        self.isActing = true
                        do {
                            try await DeviceControl.shared.run([step])
                        } catch {
                            self.isActing = false
                            self.finishAgent(error.localizedDescription, failed: true)
                            return
                        }
                        self.isActing = false
                        // Self-check: typed text should now be on screen. It is
                        // never retyped (that would double it); the result just
                        // says whether it was seen.
                        var note = ""
                        if step.kind == .type, Self.normalizedWords(step.value).count >= 2 {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            let after = await ScreenReader.read()
                            let seen = Self.containment(of: step.value, in: after.text) >= 0.5
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
                    stepsRun += 1
                    if stepsRun >= 40 {
                        self.finishAgent("Stopped after 40 steps without finishing.", failed: true)
                        return
                    }
                }
                if usedKeyboard {
                    // Let the screen catch up before looking again.
                    try? await Task.sleep(nanoseconds: 700_000_000)
                }
            }
            self.finishAgent("Stopped after 14 rounds without finishing.", failed: true)
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

    /// The steps as chat lines; optionally with the latest command's output.
    private func agentLines(withLatestOutput: Bool) -> [String] {
        agentLog.enumerated().map { index, line in
            if withLatestOutput, index == agentLog.count - 1, let output = agentOutputs[index], !output.isEmpty {
                return "- \(line)\n```\n\(output)\n```"
            }
            return "- \(line)"
        }
    }

    /// Shows what has been done so far in the chat while the task goes on.
    private func publishProgress() {
        guard let id = agentTurnID else { return }
        let text = agentLines(withLatestOutput: true).joined(separator: "\n")
        updateTurn(id) { $0.answer = text }
    }

    /// Writes the one result into the chat turn: the steps as short lines,
    /// then the outcome, the agent's question, or why it stopped. A failure
    /// keeps the output of the last command, since that is where the reason is.
    private func finishAgent(_ message: String, failed: Bool, keepOpen: Bool = false) {
        var lines = agentLines(withLatestOutput: failed)
        lines.append(failed ? message : "**Done.** \(message)")
        let text = lines.joined(separator: "\n")
        if let id = agentTurnID {
            updateTurn(id) { $0.answer = text }
        } else if failed {
            lastError = message
        }
        lastAgentReport = message
        if !keepOpen {
            agentTask = nil
        }
    }

    /// After the agent has finished: if it worked in an app, waits for what
    /// it set in motion to settle on screen; then adds to the chat how it
    /// turned out and what the user may want to do next.
    private func followUp(task: String, waitForScreen: Bool) async {
        guard let id = agentTurnID else { return }
        if waitForScreen {
            agentStatus = "Waiting for it to finish"
            await ScreenWatcher.waitForScreenToSettle()
            if Task.isCancelled { return }
        }
        agentStatus = "Thinking about next steps"
        var screen = "(not relevant: the work was done in the shell)"
        if waitForScreen {
            let seen = await ScreenReader.read()
            screen = seen.header + "\n\n" + seen.text
        }
        guard let output = try? await suggester.nextSteps(task: task,
                                                          done: agentContext,
                                                          report: lastAgentReport,
                                                          screenText: screen),
              !Task.isCancelled else { return }
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
        updateTurn(id) {
            if !summary.isEmpty {
                $0.answer += "\n\n\(summary)"
            }
            $0.suggestions = next.isEmpty ? nil : Array(next.prefix(3))
        }
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
        overlay?.focusInput()
        focusInputRequest += 1
    }

    /// Sends a message as if the user had typed it: a suggested next step.
    func send(_ text: String) {
        draft = text
        sendDraft()
    }

    /// Stops the agent in mid-task: a running command is ended, typing
    /// stops, and a pending question is answered with no.
    func stopAgent() {
        DeviceControl.shared.cancel()
        agentRun?.cancel()
        Task { await AgentShell.shared.cancel() }
        decide(.deny)
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
                run(turnID: target, kind: .screen, reveal: true) {
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
                run(turnID: last.id, kind: .screen, reveal: true) {
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

    func copy(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Attached files

    var attachments: [Attachment] { conversation.attachments ?? [] }

    /// Opens a file picker and attaches the chosen files as context.
    func pickAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Attach files as context for this conversation"
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

    /// Extracts each file's text and keeps it with the conversation.
    func attach(_ urls: [URL]) {
        Task { @MainActor in
            var unreadable: [String] = []
            for url in urls.prefix(8) {
                if let text = await FileTextExtractor.extract(url) {
                    var files = conversation.attachments ?? []
                    files.removeAll { $0.name == url.lastPathComponent }
                    files.append(Attachment(name: url.lastPathComponent, text: text))
                    conversation.attachments = Array(files.suffix(8))
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

    func removeAttachment(_ id: UUID) {
        conversation.attachments?.removeAll { $0.id == id }
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
        conversation.updatedAt = Date()
        store.save(conversation)
        refreshHistory()
    }

    func newConversation() {
        persist()
        cancelRuns()
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

    func deleteConversation(_ id: UUID) {
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
