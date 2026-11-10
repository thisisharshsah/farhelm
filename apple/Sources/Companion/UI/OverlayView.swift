import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The main glass panel, laid out as a conversation workspace:
/// header, status chips, a compact live transcript, one chat timeline holding
/// both reply and screen turns, and an input bar with the model switcher.
struct OverlayView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings
    @FocusState private var inputFocused: Bool
    @State private var showNotes = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if app.compact {
                compactBody
            } else {
                chipRow
                hairline
                if app.showHistory {
                    HistoryView()
                } else {
                    if showNotes {
                        notesView(app.conversation.record ?? app.conversation.summary ?? "")
                            .frame(height: 190)
                        hairline
                    }
                    if let error = app.lastError {
                        errorBanner(error)
                            .padding(.top, 8)
                    }
                    // What is still missing, with the button that fixes it.
                    if !settings.setupDismissed, !SetupGuide.essentialsDone || app.conversation.turns.isEmpty && app.segments.isEmpty && !setupComplete {
                        SetupGuide()
                            .padding(.horizontal, Theme.gutter)
                            .padding(.top, 10)
                    }
                    ChatThread()
                        .padding(.horizontal, Theme.gutter)
                        .padding(.top, 10)
                        .frame(maxHeight: .infinity)
                }
                actionCard
                attachmentStrip
                inputBar
                footer
            }
        }
        .frame(minWidth: app.compact ? 380 : 460, maxWidth: .infinity,
               minHeight: app.compact ? 200 : 560, maxHeight: .infinity)
        .background {
            ZStack {
                if settings.panelStyle == .frosted {
                    VisualEffectView(material: .hudWindow)
                }
                Color.black.opacity(settings.panelDarkness)
                Theme.accent.opacity(0.05)
            }
        }
        // Soft colored light in the corners plus a top sheen.
        .overlay(alignment: .topLeading) {
            RadialGradient(colors: [Theme.accent.opacity(0.20), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 260)
                .frame(width: 260, height: 260)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            RadialGradient(colors: [Theme.lilac.opacity(0.12), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 240)
                .frame(width: 240, height: 240)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            LinearGradient(colors: [.white.opacity(0.09), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 64)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .glassBorder(radius: Theme.panelRadius)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            WindowControls()
            VStack(alignment: .leading, spacing: 1) {
                Text("Companion")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                // What it is doing, or why it did not reply just now.
                Text(app.statusLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .help(app.statusLine)
            }
            Spacer(minLength: 8)
            // The one main action, with its name on it.
            Button {
                app.toggleListening()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: app.isListening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(app.isListening ? "Stop" : "Listen")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(app.isListening ? Theme.rose : Color.black.opacity(0.82))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(app.isListening
                                           ? AnyShapeStyle(Theme.rose.opacity(0.16))
                                           : AnyShapeStyle(Theme.accentGradient)))
                .overlay(Capsule().strokeBorder(app.isListening ? Theme.rose.opacity(0.4) : Color.clear, lineWidth: 0.75))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(app.isListening ? "Stop listening (⌘⇧L)" : "Start listening (⌘⇧L)")
            if !app.compact {
                ToolbarGroup {
                    IconButton("square.and.pencil", help: "New conversation") { app.newConversation() }
                    IconButton("clock.arrow.circlepath",
                               help: "Past conversations: search, reopen, delete",
                               tint: app.showHistory ? Theme.accent : nil) {
                        app.refreshHistory()
                        app.showHistory.toggle()
                    }
                    SettingsLink {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.68))
                            .frame(width: 26, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                }
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(DragHandle())
    }

    /// The agent at work. Normally a slim bar with what it is doing and a
    /// Stop button; when it wants to do something that needs a yes, the
    /// steps are laid out with Allow, Always allow and Deny.
    @ViewBuilder
    private var actionCard: some View {
        if app.agentTask != nil {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    if app.pendingApproval == nil {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.amber)
                    }
                    Text(app.pendingApproval == nil
                         ? (app.agentStatus ?? "Working")
                         : "Companion wants to do this")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(app.pendingApproval == nil ? Theme.accent : Theme.amber)
                    Spacer(minLength: 6)
                    Button { app.stopAgent() } label: { Chip("Stop", icon: "stop.fill", tint: Theme.rose) }
                        .buttonStyle(.plain)
                        .help("Stop the agent")
                }
                if let proposal = app.pendingApproval {
                    ForEach(proposal.steps) { step in
                        if step.kind == .run {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(step.value)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.95))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(9)
                                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Color.black.opacity(0.35)))
                                Text("Shell command, in \(proposal.directory)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: step.kind == .open ? "macwindow" : "keyboard")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .frame(width: 14)
                                Text(step.label)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(5)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Button { app.decide(.allow) } label: { Chip("Allow", icon: "checkmark", tint: Theme.accent) }
                            .buttonStyle(.plain)
                            .help("Run these steps this once")
                        if !proposal.remember.isEmpty || proposal.steps.contains(where: { $0.kind != .run }) {
                            Button { app.decide(.always) } label: { Chip("Always allow", icon: "checkmark.circle") }
                                .buttonStyle(.plain)
                                .help(proposal.remember.isEmpty
                                      ? "Run these, and stop asking about typing for the rest of this task"
                                      : "Run these, and never ask again about: \(proposal.remember.joined(separator: ", "))")
                        }
                        Button { app.decide(.deny) } label: { Chip("Deny", icon: "xmark", tint: Theme.rose) }
                            .buttonStyle(.plain)
                            .help("Do not run this; the task stops and you can say what to do instead")
                    }
                } else if let last = app.agentLog.last {
                    Text(MarkdownNotes.plain(last))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Color.black.opacity(0.28)))
            .glassBorder(radius: Theme.cardRadius,
                         tint: app.pendingApproval == nil ? Theme.accent : Theme.amber)
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 8)
        }
    }

    /// Everything optional in setup is done too.
    private var setupComplete: Bool {
        SetupGuide.essentialsDone && !settings.userDetails.isEmpty
    }

    /// Minimized: just the newest answer and the input.
    private var compactBody: some View {
        VStack(spacing: 0) {
            hairline
            ScrollView {
                if let turn = app.conversation.turns.last {
                    TurnView(turn: turn,
                             tint: ChatThread.tint(turn.kind),
                             streaming: app.streamingTurns.contains(turn.id),
                             spokenWords: turn.kind == .reply ? app.replySpokenWords : app.screenSpokenWords,
                             cursorID: "compact-cursor",
                             draft: app.draftTurns.contains(turn.id))
                } else {
                    Text("The newest answer shows here. The yellow button brings the full panel back.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.42))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .frame(maxHeight: .infinity)
            inputBar
        }
    }

    // MARK: Chips

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                liveChip
                // What kind of conversation this is: sets the reply style.
                Menu {
                    ForEach(SessionMode.allCases) { mode in
                        Button {
                            settings.sessionMode = mode
                        } label: {
                            Label(mode.label + (settings.sessionMode == mode ? "  ✓" : ""), systemImage: mode.icon)
                        }
                        .help(mode.summary)
                    }
                } label: {
                    Chip(settings.sessionMode.label, icon: settings.sessionMode.icon, tint: Theme.violet)
                        .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Mode: \(settings.sessionMode.summary) Click to change.")
                // Which helpers react on their own.
                Button {
                    settings.autoSuggest.toggle()
                } label: {
                    Chip(settings.autoSuggest ? "Reply on" : "Reply off",
                         icon: "sparkles",
                         tint: settings.autoSuggest ? Theme.accent : nil)
                }
                .buttonStyle(.plain)
                .help(settings.autoSuggest
                      ? "Drafts an answer when they finish speaking. Click to turn off."
                      : "Automatic replies are off. Click to turn on.")
                Button {
                    settings.autoScreenWatch.toggle()
                } label: {
                    Chip(settings.autoScreenWatch ? "Screen on" : "Screen off",
                         icon: "text.viewfinder",
                         tint: settings.autoScreenWatch ? Theme.violet : nil)
                }
                .buttonStyle(.plain)
                .help(settings.autoScreenWatch
                      ? "Answers new questions that appear on screen. Click to turn off."
                      : "Automatic screen answers are off. Click to turn on.")
                if !app.segments.isEmpty || !app.conversation.turns.isEmpty || app.conversation.summary != nil {
                    Button {
                        showNotes.toggle()
                    } label: {
                        Chip("Notes", icon: "note.text", tint: showNotes ? Theme.accent : nil)
                    }
                    .buttonStyle(.plain)
                    .help(showNotes
                          ? "Showing the notes. Click to close them."
                          : "See or update the summary of this conversation so far.")
                }
                // Only things that need attention get a chip.
                if settings.setupDismissed, !SetupGuide.essentialsDone {
                    Button {
                        settings.setupDismissed = false
                    } label: {
                        Chip("Finish setup", icon: "exclamationmark.circle", tint: Theme.amber)
                    }
                    .buttonStyle(.plain)
                }
                if settings.separateMicVoices, !app.voiceEnrolled {
                    Chip("Voice not set up", icon: "person.crop.circle.badge.exclamationmark", tint: Theme.amber)
                }
                if app.clickThrough {
                    Chip("Click-through", icon: "cursorarrow.rays", tint: Theme.amber)
                }
            }
            .padding(.horizontal, Theme.gutter)
        }
        .padding(.bottom, 10)
    }

    private var liveChip: some View {
        HStack(spacing: 5) {
            StatusDot(active: app.isListening)
            Text(app.isListening ? "Live" : "Idle")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            if app.isListening {
                LevelBars(level: max(app.micLevel, app.systemLevel), color: Theme.mint)
            }
        }
        .foregroundStyle(app.isListening ? Theme.mint : Color.white.opacity(0.6))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill((app.isListening ? Theme.mint : Color.white).opacity(app.isListening ? 0.14 : 0.07)))
        .overlay(Capsule().strokeBorder((app.isListening ? Theme.mint : Color.white).opacity(app.isListening ? 0.30 : 0.14),
                                        lineWidth: 0.75))
        .fixedSize()
    }

    private var hairline: some View {
        LinearGradient(colors: [.clear, .white.opacity(0.14), .clear],
                       startPoint: .leading, endPoint: .trailing)
            .frame(height: 1)
    }

    /// The notes: a summary of the conversation so far. They update on their
    /// own as lines scroll out of the recent transcript, and on demand here.
    private func notesView(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(app.conversation.record == nil ? "Summary so far" : "Notes", systemImage: "note.text")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                if app.isSummarizing || app.isWritingUp {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                }
                Spacer(minLength: 4)
                IconButton("wand.and.stars",
                           help: "Write up the conversation so far: summary, topics, decisions, action items") {
                    app.writeUpRecord()
                }
                .disabled(app.isWritingUp)
                if !notes.isEmpty {
                    IconButton("doc.on.doc", help: "Copy the notes") {
                        app.copy(notes)
                    }
                }
                IconButton("square.and.arrow.down", help: "Save the notes and the transcript as a Markdown file") {
                    app.exportRecord()
                }
                IconButton("folder", help: "Open the folder of saved call wrap-ups") {
                    try? FileManager.default.createDirectory(at: app.wrapUpFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(app.wrapUpFolder)
                }
                IconButton("xmark", help: "Close the notes") {
                    showNotes = false
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = app.notesError {
                        Text(error)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.amber)
                            .textSelection(.enabled)
                    }
                    if notes.isEmpty {
                        Text("No notes yet. Press the wand to write up the conversation so far. It is also written up on its own when you stop listening.")
                            .font(.system(size: 12.5))
                            .lineSpacing(2)
                            .foregroundStyle(.white.opacity(0.42))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        MarkdownNotes(text: notes)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 8)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Theme.amber)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.amber.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Theme.amber.opacity(0.28), lineWidth: 0.75))
        .padding(.horizontal, Theme.gutter)
    }

    // MARK: Input bar

    private var canSend: Bool {
        !app.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            modelMenu
            TextField(app.attachScreen ? "Ask about your screen…" : "Ask, or tell me what to do…",
                      text: $app.draft,
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { app.sendDraft() }
                .padding(.vertical, 4)
            IconButton("paperclip",
                       help: "Attach files as context (or drop them here)",
                       tint: app.attachments.isEmpty ? nil : Theme.accent) {
                app.pickAttachments()
            }
            IconButton("text.viewfinder",
                       help: app.attachScreen
                           ? "Screen capture will be attached. Click to turn off."
                           : "Attach a screen capture to this message",
                       tint: app.attachScreen ? Theme.violet : nil) {
                app.attachScreen.toggle()
            }
            Button(action: { app.sendDraft() }) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(canSend ? 1 : 0.4))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(canSend
                                              ? AnyShapeStyle(Theme.accentGradient)
                                              : AnyShapeStyle(Color.white.opacity(0.10))))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send (Return)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(.white.opacity(0.07)))
        .glassBorder(radius: 15, tint: inputFocused ? Theme.accent : nil)
        // The ask hotkey lands here: cursor in the box, ready to type.
        .onChange(of: app.focusInputRequest) { _, _ in
            inputFocused = true
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in app.attach([url]) }
                }
            }
            return true
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    /// Files attached to this conversation, each removable.
    @ViewBuilder
    private var attachmentStrip: some View {
        if !app.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(app.attachments) { file in
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text(file.name)
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 150)
                            Button {
                                app.removeAttachment(file.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 7.5, weight: .bold))
                                    .frame(width: 14, height: 14)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Remove from this conversation")
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.leading, 8)
                        .padding(.trailing, 4)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.accent.opacity(0.14)))
                        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.30), lineWidth: 0.75))
                        .fixedSize()
                    }
                }
                .padding(.horizontal, Theme.gutter)
            }
            .padding(.top, 10)
        }
    }

    /// Switch engine and model without leaving the conversation.
    private var modelMenu: some View {
        Menu {
            Section("Engine") {
                ForEach(LLMProviderKind.allCases) { kind in
                    Button {
                        settings.provider = kind
                        if kind == .farhelm { app.loadFarhelmModels() }
                        if kind == .anthropic { app.loadAnthropicModels() }
                    } label: {
                        menuRow(kind.label, selected: settings.provider == kind)
                    }
                }
            }
            if settings.provider == .farhelm {
                Section("Farhelm model") {
                    Button {
                        settings.farhelmModel = ""
                    } label: {
                        menuRow("Auto (Farhelm routes)", selected: settings.farhelmModel.isEmpty)
                    }
                    ForEach(app.farhelmModels, id: \.self) { model in
                        Button {
                            settings.farhelmModel = model
                        } label: {
                            menuRow(model, selected: settings.farhelmModel == model)
                        }
                    }
                }
            }
            if settings.provider == .anthropic {
                Section("Claude model") {
                    if !app.anthropicModels.contains(settings.anthropicModel) {
                        Button {} label: {
                            menuRow(settings.anthropicModel, selected: true)
                        }
                    }
                    ForEach(app.anthropicModels, id: \.self) { model in
                        Button {
                            settings.anthropicModel = model
                        } label: {
                            menuRow(model, selected: settings.anthropicModel == model)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: 9, weight: .semibold))
                Text(app.engineLabel)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.6)
            }
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: 150)
            .background(Capsule().fill(.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch model")
        .onAppear { app.loadFarhelmModels() }
    }

    @ViewBuilder
    private func menuRow(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if app.clickThrough {
                KeyCap(keys: "⌘⇧T", label: "Click-through is on, press to interact")
            } else {
                KeyCap(keys: "⌘⇧␣", label: "Panel")
                KeyCap(keys: "⌘⇧↩", label: "Reply")
                KeyCap(keys: "⌘⇧A", label: "Screen")
                KeyCap(keys: "⌘⇧\(settings.askHotKey)", label: "Ask")
                KeyCap(keys: "⌘⇧T", label: "Through")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 12)
        .background(DragHandle())
    }
}

// MARK: - Chat thread

/// The conversation as one timeline: reply and screen turns in the order they
/// happened, each tagged with its kind. The filter chips narrow it to one kind.
struct ChatThread: View {
    @EnvironmentObject var app: AppState
    /// nil shows everything.
    @State private var filter: TurnKind?
    /// Older answers the user opened again.
    @State private var expanded: Set<UUID> = []

    private var allTurns: [ChatTurn] { app.conversation.turns }
    private var turns: [ChatTurn] {
        guard let filter else { return allTurns }
        return allTurns.filter { $0.kind == filter }
    }
    /// Everything in the order it happened: what was said, typed or captured
    /// (shown on the right) and what the assistant answered (on the left).
    /// With a filter on, only that kind of turn is shown.
    private var items: [TimelineItem] {
        guard filter == nil else { return turns.map(TimelineItem.turn) }
        let ordered = allTurns.enumerated()
            .sorted { a, b in
                let left = a.element.anchor ?? a.element.date
                let right = b.element.anchor ?? b.element.date
                return left == right ? a.offset < b.offset : left < right
            }
            .map(\.element)
        var result: [TimelineItem] = []
        var group: TranscriptGroup?
        var next = 0
        func closeGroup() {
            if let open = group {
                result.append(.speech(open))
                group = nil
            }
        }
        for segment in app.segments {
            while next < ordered.count, (ordered[next].anchor ?? ordered[next].date) < segment.timestamp {
                closeGroup()
                result.append(.turn(ordered[next]))
                next += 1
            }
            // Consecutive lines by the same speaker read as one paragraph.
            if var open = group,
               open.speaker == segment.speaker,
               open.tag == segment.tag,
               open.liveText.isEmpty,
               segment.timestamp.timeIntervalSince(open.lastTimestamp) < 20 {
                if segment.isFinal {
                    open.finalText += " " + segment.text
                    open.heardText += " " + (segment.original ?? segment.text)
                    open.polished = open.polished || Self.wasReworded(segment)
                    open.speakerCorrected = open.speakerCorrected || segment.speakerCorrected
                } else {
                    open.liveText = segment.text
                }
                open.lastTimestamp = segment.timestamp
                open.segmentIDs.append(segment.id)
                group = open
            } else {
                closeGroup()
                group = TranscriptGroup(id: segment.id,
                                        speaker: segment.speaker,
                                        tag: segment.tag,
                                        finalText: segment.isFinal ? segment.text : "",
                                        heardText: segment.isFinal ? (segment.original ?? segment.text) : "",
                                        liveText: segment.isFinal ? "" : segment.text,
                                        polished: Self.wasReworded(segment),
                                        speakerCorrected: segment.speakerCorrected,
                                        lastTimestamp: segment.timestamp,
                                        started: segment.timestamp,
                                        segmentIDs: [segment.id])
            }
        }
        closeGroup()
        result.append(contentsOf: ordered[next...].map(TimelineItem.turn))
        return result
    }

    /// True when a rewrite actually changed the line's wording.
    private static func wasReworded(_ segment: TranscriptSegment) -> Bool {
        guard let original = segment.original else { return false }
        return original != segment.text
    }

    private var lastReplyID: UUID? { allTurns.last { $0.kind == .reply }?.id }
    private var lastScreenID: UUID? { allTurns.last { $0.kind == .screen }?.id }
    private var busyTint: Color? {
        if app.isAnsweringScreen { return Theme.violet }
        if app.isReplying { return Theme.accent }
        return nil
    }

    static func tint(_ kind: TurnKind) -> Color {
        kind == .reply ? Theme.accent : Theme.violet
    }

    static func cursorID(_ kind: TurnKind) -> String {
        "cursor-\(kind.rawValue)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if items.isEmpty {
                Text(emptyHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.36))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                timeline
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.08), .white.opacity(0.025)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .glassBorder(radius: Theme.cardRadius, tint: busyTint)
        .animation(.easeInOut(duration: 0.25), value: busyTint != nil)
    }

    private var emptyHint: String {
        switch filter {
        case .none:
            return app.isListening
                ? "Listening. What is said appears here as it's spoken, with each answer right after what it answers."
                : "Press play to listen, or type below. The conversation and the answers appear here together, in order."
        case .some(.reply):
            return "No replies yet. They appear when the other side finishes speaking, or when you type."
        case .some(.screen):
            return "No screen answers yet. Use the capture button, or turn Screen on in the header."
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            filterChip(nil, label: "All", count: allTurns.count, tint: nil)
            filterChip(.reply, label: "Reply", count: count(.reply), tint: Theme.accent)
            filterChip(.screen, label: "Screen", count: count(.screen), tint: Theme.violet)
            if let busyTint {
                Chip("Writing", icon: "ellipsis", tint: busyTint)
            }
            Spacer(minLength: 4)
            if app.isRescanning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 18, height: 18)
                Text("Rechecking \(app.rescanProgress)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize()
                IconButton("stop.fill", help: "Stop the recheck here. Fixes already made stay.") {
                    app.stopRescan()
                }
            } else {
                if app.canUndoRescan {
                    IconButton("arrow.uturn.backward", help: "Undo the recheck") {
                        app.undoRescan()
                    }
                }
                IconButton("arrow.triangle.2.circlepath",
                           help: "Recheck, newest first: fix who said what, rewrite each line clearly, then verify the replies still match") {
                    app.rescanTranscript()
                }
            }
            if app.unusedReplyCount > 0 {
                IconButton("eraser", help: "Clean up: remove the \(app.unusedReplyCount) suggested replies you did not say or that match nothing") {
                    app.cleanUnusedReplies()
                }
            }
            IconButton("bolt.fill", help: "Draft a reply now (⌘⇧↩)", tint: Theme.accent) {
                app.suggestNow()
            }
            IconButton("camera.viewfinder", help: "Capture the screen and answer now (⌘⇧A)", tint: Theme.violet) {
                app.answerScreenNow()
            }
        }
    }

    private func count(_ kind: TurnKind) -> Int {
        allTurns.filter { $0.kind == kind }.count
    }

    private func filterChip(_ kind: TurnKind?, label: String, count: Int, tint: Color?) -> some View {
        let selected = filter == kind
        let color = tint ?? Color.white
        return Button {
            filter = kind
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .medium, design: .rounded))
                Text("\(count)")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .opacity(0.6)
            }
            .foregroundStyle(selected ? color : Color.white.opacity(0.55))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(selected ? 0.16 : 0.05)))
            .overlay(Capsule().strokeBorder(color.opacity(selected ? 0.38 : 0.10), lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(kind == nil ? "Show everything" : "Show only \(label) turns")
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(items) { item in
                        switch item {
                        case .speech(let group):
                            // What was heard: a compact line, not a card.
                            SpeechBubble(group: group)
                                .id(group.id)
                        case .turn(let turn):
                            let streaming = app.streamingTurns.contains(turn.id)
                            // Only the newest answer of each kind stays open;
                            // older ones fold to a single line until clicked.
                            let current = turn.id == lastReplyID || turn.id == lastScreenID || streaming
                            VStack(alignment: .leading, spacing: 5) {
                                if turn.origin == .typed || turn.kind == .screen {
                                    TurnInputBubble(turn: turn, streaming: streaming)
                                }
                                TurnView(turn: turn,
                                         tint: Self.tint(turn.kind),
                                         streaming: streaming,
                                         spokenWords: spokenWords(for: turn),
                                         cursorID: Self.cursorID(turn.kind),
                                         draft: app.draftTurns.contains(turn.id),
                                         collapsed: !current && !expanded.contains(turn.id),
                                         onToggle: current ? nil : {
                                             if expanded.contains(turn.id) {
                                                 expanded.remove(turn.id)
                                             } else {
                                                 expanded.insert(turn.id)
                                             }
                                         })
                            }
                            .id(turn.id)
                        }
                    }
                }
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: app.replySpokenWords) { _, count in
                follow(proxy, kind: .reply, count: count)
            }
            .onChange(of: app.screenSpokenWords) { _, count in
                follow(proxy, kind: .screen, count: count)
            }
        }
    }

    /// Read-along applies to the newest answer of each kind.
    private func spokenWords(for turn: ChatTurn) -> Int {
        if turn.id == lastReplyID { return app.replySpokenWords }
        if turn.id == lastScreenID { return app.screenSpokenWords }
        return 0
    }

    private func follow(_ proxy: ScrollViewProxy, kind: TurnKind, count: Int) {
        guard count > 0 else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(Self.cursorID(kind), anchor: .center)
        }
    }
}

/// One exchange: the prompt (heard, typed or captured), the screenshot when
/// there is one, and the answer with its actions.
struct TurnView: View {
    @EnvironmentObject var app: AppState
    let turn: ChatTurn
    let tint: Color
    let streaming: Bool
    let spokenWords: Int
    let cursorID: String
    /// The question may still be unfinished, so the answer is not confirmed yet.
    var draft = false
    /// Folded to one line: an older answer, out of the way until clicked.
    var collapsed = false
    /// Folds or unfolds the answer. nil for the current answer, which stays open.
    var onToggle: (() -> Void)?
    @State private var hover = false
    @State private var copied = false

    /// The engine, and which of the user's material the answer drew on.
    private var footnote: String {
        guard let sources = turn.sources, !sources.isEmpty else { return turn.model }
        let names = sources.prefix(3).joined(separator: ", ") + (sources.count > 3 ? " +\(sources.count - 3)" : "")
        return "\(turn.model)  ·  from \(names)"
    }

    private var promptIcon: String {
        switch turn.origin {
        case .typed: return "person.fill"
        case .auto: return turn.kind == .screen ? "eye.fill" : "waveform"
        case .manual: return turn.kind == .screen ? "text.viewfinder" : "sparkles"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                // Which kind of turn this is, in its color.
                HStack(spacing: 3) {
                    Image(systemName: promptIcon)
                        .font(.system(size: 8, weight: .bold))
                    Text(turn.kind == .reply ? "Reply" : "Screen")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(tint.opacity(0.14)))
                .overlay(Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 0.5))
                .fixedSize()
                if draft {
                    HStack(spacing: 3) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 8, weight: .bold))
                            .symbolEffect(.variableColor.iterative, isActive: true)
                        Text("Draft")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Theme.amber)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.amber.opacity(0.14)))
                    .overlay(Capsule().strokeBorder(Theme.amber.opacity(0.30), lineWidth: 0.5))
                    .fixedSize()
                    .help("The question may not be finished. This answer is confirmed once it is.")
                }
                if let usage = app.usage(of: turn) {
                    usageBadge(usage)
                }
                if let matched = turn.matched {
                    matchBadge(matched)
                }
                TimeLabel(date: turn.anchor ?? turn.date)
                if collapsed {
                    Text(turn.answer.isEmpty ? (turn.error ?? "") : MarkdownNotes.plain(turn.answer))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(hover ? 0.7 : 0.35))
                } else {
                    Spacer(minLength: 4)
                    // Actions live in the header and fade in on hover, so the
                    // card never changes height.
                    if !streaming {
                        HStack(spacing: 2) {
                            actions
                            if let onToggle {
                                IconButton("chevron.up", help: "Fold this answer", action: onToggle)
                            }
                        }
                        .opacity(hover ? 1 : 0)
                        .allowsHitTesting(hover)
                    }
                }
            }

            if !collapsed {
                if let error = turn.error {
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.amber)
                        .textSelection(.enabled)
                }

                if turn.answer.isEmpty {
                    if streaming {
                        Text("Thinking…")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                } else {
                    // An answer that came back formatted (lists, tables, bold) is
                    // always shown formatted, never as raw Markdown.
                    if MarkdownNotes.looksFormatted(turn.answer) {
                        MarkdownNotes(text: turn.answer, size: 13)
                    } else {
                        ReadAlongText(text: turn.answer, spokenWords: spokenWords, tint: tint, cursorID: cursorID)
                    }
                }

                // What to do next: one click sends it.
                if let suggestions = turn.suggestions, !suggestions.isEmpty, !streaming {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button {
                                app.send(suggestion)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(.system(size: 9, weight: .bold))
                                    Text(suggestion)
                                        .font(.system(size: 12, weight: .medium))
                                        .multilineTextAlignment(.leading)
                                }
                                .foregroundStyle(tint)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(tint.opacity(0.12)))
                                .overlay(Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 0.5))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Do this next")
                        }
                    }
                    .padding(.top, 2)
                }
                Text(footnote)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.28))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(footnote)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, collapsed ? 7 : 12)
        .contentShape(Rectangle())
        .onTapGesture {
            if collapsed { onToggle?() }
        }
        .help(collapsed ? "Click to open this answer" : "")
        // A dark base keeps the text readable over whatever is behind the
        // panel; the tint marks which kind of answer it is.
        .background(BubbleShape(side: .left).fill(tint.opacity(hover ? 0.10 : 0.06)))
        .background(BubbleShape(side: .left).fill(Color.black.opacity(0.30)))
        .overlay(BubbleShape(side: .left).strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
        .overlay(ShimmerOverlay(active: streaming).clipShape(BubbleShape(side: .left)))
        .onHover { hover = $0 }
    }

    /// What the recheck found: does this reply answer something that was
    /// really asked in the conversation?
    private func matchBadge(_ matched: Bool) -> some View {
        let color = matched ? Theme.mint : Theme.rose
        return HStack(spacing: 3) {
            Image(systemName: matched ? "checkmark.seal" : "xmark.seal")
                .font(.system(size: 8, weight: .bold))
            Text(matched ? "Matched" : "No match")
                .font(.system(size: 9, weight: .bold, design: .rounded))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.14)))
        .overlay(Capsule().strokeBorder(color.opacity(0.30), lineWidth: 0.5))
        .fixedSize()
        .help(matched
              ? "Rechecked: this reply answers something that was asked in the conversation."
              : "Rechecked: nothing in the conversation matches this reply. Clean up removes it.")
    }

    /// Whether this suggestion was actually said in the conversation.
    private func usageBadge(_ usage: TurnUsage) -> some View {
        let label: String
        let icon: String
        let color: Color
        let help: String
        switch usage {
        case .used:
            label = "Used"
            icon = "checkmark"
            color = Theme.mint
            help = "You said this reply."
        case .partly:
            label = "Partly used"
            icon = "circle.lefthalf.filled"
            color = Theme.amber
            help = "You said part of this reply."
        case .unused:
            label = "Not used"
            icon = "minus"
            color = Color.white.opacity(0.5)
            help = "You did not say this reply. Clean up removes replies like this."
        }
        return HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.14)))
        .overlay(Capsule().strokeBorder(color.opacity(0.30), lineWidth: 0.5))
        .fixedSize()
        .help(help)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if !turn.answer.isEmpty {
                IconButton(copied ? "checkmark" : "doc.on.doc", help: "Copy answer", tint: copied ? Theme.mint : nil) {
                    app.copy(turn.answer)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                }
            }
            IconButton("arrow.clockwise", help: "Regenerate") { app.regenerate(turn.id) }
            IconButton("arrow.uturn.left", help: "Reuse this prompt in the input") { app.reuse(turn.id) }
            IconButton("trash", help: "Delete this turn") { app.deleteTurn(turn.id) }
        }
    }
}

/// Small clock time shown on every entry in the conversation.
struct TimeLabel: View {
    let date: Date

    var body: some View {
        Text(date, format: .dateTime.hour().minute())
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.38))
            .fixedSize()
    }
}

/// Chat bubble outline: rounded, with a tighter corner on the side it
/// belongs to (left for the assistant, right for inputs).
struct BubbleShape: InsettableShape {
    enum Side { case left, right }
    let side: Side
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let round = Theme.bubbleRadius
        let radii = RectangleCornerRadii(topLeading: round,
                                         bottomLeading: side == .left ? 6 : round,
                                         bottomTrailing: side == .right ? 6 : round,
                                         topTrailing: round)
        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
            .path(in: rect.insetBy(dx: inset, dy: inset))
    }

    func inset(by amount: CGFloat) -> BubbleShape {
        BubbleShape(side: side, inset: inset + amount)
    }
}

/// One entry in the conversation timeline.
enum TimelineItem: Identifiable {
    case speech(TranscriptGroup)
    case turn(ChatTurn)

    var id: UUID {
        switch self {
        case .speech(let group): return group.id
        case .turn(let turn): return turn.id
        }
    }
}

/// A paragraph of what was heard, from the user or from the other people:
/// a compact line in the flow of the conversation.
struct SpeechBubble: View {
    let group: TranscriptGroup

    var body: some View {
        SegmentRow(group: group)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the user typed, or the screen that was captured.
struct TurnInputBubble: View {
    @EnvironmentObject var app: AppState
    let turn: ChatTurn
    let streaming: Bool

    private var tint: Color { ChatThread.tint(turn.kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: turn.kind == .screen ? "text.viewfinder" : "keyboard")
                    .font(.system(size: 8.5, weight: .bold))
                Text(turn.kind == .screen ? "Screen" : "You typed")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                TimeLabel(date: turn.date)
            }
            .foregroundStyle(tint)
            if turn.kind == .screen {
                if let file = turn.imageFile {
                    TurnThumbnail(url: app.store.imageURL(conversation: app.conversation.id, file: file),
                                  processing: streaming && turn.answer.isEmpty)
                } else if streaming && turn.context == nil {
                    HStack(spacing: 6) {
                        Image(systemName: "text.viewfinder")
                        Text("Capturing screen…")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.05)))
                }
            }
            if !turn.prompt.isEmpty {
                Text(turn.prompt)
                    .font(.system(size: 12))
                    .lineSpacing(1.5)
                    .foregroundStyle(.white.opacity(0.9))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: turn.kind == .screen ? 300 : nil, alignment: .leading)
        .background(BubbleShape(side: .left).fill(Color.white.opacity(0.06)))
        .background(BubbleShape(side: .left).fill(Color.black.opacity(0.25)))
        .overlay(BubbleShape(side: .left).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The screenshot a Screen turn is working from. Click to open it.
struct TurnThumbnail: View {
    let url: URL
    let processing: Bool
    @State private var image: NSImage?

    var body: some View {
        Color.white.opacity(0.05)
            .frame(maxWidth: .infinity)
            .frame(height: 88)
            .overlay(alignment: .top) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if processing {
                    Chip("Reading", icon: "eye.fill", tint: Theme.violet)
                        .padding(5)
                }
            }
            .overlay(ShimmerOverlay(active: processing))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
            .contentShape(Rectangle())
            .onTapGesture { NSWorkspace.shared.open(url) }
            .help("Open capture")
            .task(id: url) {
                image = NSImage(contentsOf: url)
            }
    }
}

/// Answer text that dims what the user has already spoken aloud and exposes
/// a scroll anchor at the point they have reached.
struct ReadAlongText: View {
    let text: String
    let spokenWords: Int
    let tint: Color
    let cursorID: String

    var body: some View {
        if let cut = splitIndex(afterWords: spokenWords), cut > text.startIndex {
            Text(String(text[..<cut]))
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .foregroundStyle(tint.opacity(0.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(text[cut...]).trimmingCharacters(in: .whitespaces))
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .foregroundStyle(.white.opacity(0.96))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(cursorID)
        } else {
            Text(text)
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .foregroundStyle(.white.opacity(0.96))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Index right after the Nth word of `text`, counting words the same way
    /// the voice matcher does (runs of letters and digits).
    private func splitIndex(afterWords n: Int) -> String.Index? {
        guard n > 0 else { return nil }
        var count = 0
        var inWord = false
        for index in text.indices {
            let character = text[index]
            let isWordChar = character.isLetter || character.isNumber
            if isWordChar {
                inWord = true
            } else if inWord {
                inWord = false
                count += 1
                if count == n { return index }
            }
        }
        if inWord {
            count += 1
        }
        return count >= n ? text.endIndex : nil
    }
}

// MARK: - History

/// Saved conversations: open one to continue it, or delete it.
struct HistoryView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Conversations")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Button {
                    app.newConversation()
                } label: {
                    Chip("New", icon: "plus", tint: Theme.accent)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                TextField("Search everything said, answered or noted…", text: $app.historyQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.95))
                    .onChange(of: app.historyQuery) { _, _ in app.refreshHistory() }
                if !app.historyQuery.isEmpty {
                    IconButton("xmark.circle.fill", help: "Clear the search") {
                        app.historyQuery = ""
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.white.opacity(0.13), lineWidth: 0.5))
            if app.history.isEmpty {
                Text(app.historyQuery.isEmpty
                     ? "Nothing saved yet. Conversations are kept automatically once they have content."
                     : "No conversation contains that.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(app.history) { item in
                            HistoryRow(item: item, isCurrent: item.id == app.conversation.id)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct HistoryRow: View {
    @EnvironmentObject var app: AppState
    let item: ConversationSummary
    let isCurrent: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Text("\(item.turnCount) \(item.turnCount == 1 ? "turn" : "turns") · \(item.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.42))
            }
            Spacer(minLength: 6)
            if isCurrent {
                Chip("Open", tint: Theme.mint)
            }
            IconButton("trash", help: "Delete conversation") {
                app.deleteConversation(item.id)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(hover ? 0.09 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder((isCurrent ? Theme.mint : Color.white).opacity(isCurrent ? 0.35 : 0.09), lineWidth: 0.75))
        .contentShape(Rectangle())
        .onTapGesture { app.openConversation(item.id) }
        .onHover { hover = $0 }
    }
}

// MARK: - Notes

/// Renders Markdown the way models write it: headings, bullets, checkboxes,
/// numbered lists, tables and inline bold or code. Used for the notes and
/// for answers that come back formatted.
struct MarkdownNotes: View {
    let text: String
    var size: CGFloat = 12.5

    private enum Block {
        case line(String)
        case table([[String]])
        /// A fenced block: commands, output, source code.
        case code(String)
    }

    /// The text on one line with the Markdown symbols taken out, for previews.
    static func plain(_ text: String) -> String {
        var result = text
        for symbol in ["**", "__", "`", "#", "|", "- [ ] ", "- [x] "] {
            result = result.replacingOccurrences(of: symbol, with: "")
        }
        return result
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && !$0.allSatisfy { "-:".contains($0) } }
            .joined(separator: " ")
    }

    /// Whether a text uses Markdown structure worth rendering.
    static func looksFormatted(_ text: String) -> Bool {
        if text.contains("**") || text.contains("__") || text.contains("`") || text.contains("```")
            || text.contains("\n|") || text.hasPrefix("|") { return true }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return true
            }
        }
        return false
    }

    private var blocks: [(offset: Int, block: Block)] {
        var result: [Block] = []
        var rows: [[String]] = []
        func closeTable() {
            if !rows.isEmpty {
                result.append(.table(rows))
                rows = []
            }
        }
        var code: [String]?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Between ``` fences every line is kept exactly as written.
            if line.hasPrefix("```") {
                closeTable()
                if let lines = code {
                    result.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            if line.hasPrefix("|") {
                let cells = line
                    .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // The |---|---| rule under the header carries no content.
                let isRule = cells.allSatisfy { cell in
                    !cell.isEmpty && cell.allSatisfy { "-: ".contains($0) }
                }
                if !isRule {
                    rows.append(cells)
                }
                continue
            }
            closeTable()
            if line.isEmpty || line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) { continue }
            result.append(.line(line))
        }
        closeTable()
        // A fence still open (the answer is arriving) shows what it has.
        if let lines = code, !lines.isEmpty {
            result.append(.code(lines.joined(separator: "\n")))
        }
        return result.enumerated().map { (offset: $0.offset, block: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(blocks, id: \.offset) { item in
                switch item.block {
                case .line(let line):
                    row(line)
                case .table(let rows):
                    table(rows)
                case .code(let source):
                    Text(source)
                        .font(.system(size: size - 1.5, design: .monospaced))
                        .lineSpacing(1.5)
                        .foregroundStyle(.white.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.black.opacity(0.32)))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
                        .padding(.vertical, 2)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func table(_ rows: [[String]]) -> some View {
        let columns = rows.map(\.count).max() ?? 0
        return Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(inline(column < cells.count ? cells[column] : ""))
                            .font(.system(size: size - 0.5, weight: index == 0 ? .semibold : .regular))
                            .lineSpacing(1.5)
                            .foregroundStyle(.white.opacity(index == 0 ? 0.95 : 0.88))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if index == 0, rows.count > 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(height: 0.5)
                        .gridCellColumns(max(columns, 1))
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func row(_ line: String) -> some View {
        if line.hasPrefix("#") {
            let level = line.prefix(while: { $0 == "#" }).count
            let title = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
            if level == 1 {
                Text(inline(title))
                    .font(.system(size: size + 1.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
            } else {
                Text(inline(title))
                    .font(.system(size: size - 1.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 5)
            }
        } else if let item = bullet(line) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: item.symbol)
                    .font(.system(size: item.symbol == "circle.fill" ? 4 : 10, weight: .semibold))
                    .foregroundStyle(item.symbol == "circle.fill" ? Color.white.opacity(0.5) : Theme.mint)
                    .frame(width: 12)
                Text(inline(item.text))
                    .font(.system(size: size))
                    .lineSpacing(2)
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(inline(line))
                .font(.system(size: size))
                .lineSpacing(2)
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                // A line that is all bold is a section title: give it air.
                .padding(.top, line.hasPrefix("**") && line.hasSuffix("**") ? 5 : 0)
        }
    }

    private func bullet(_ line: String) -> (symbol: String, text: String)? {
        for (prefix, symbol) in [("- [ ] ", "square"), ("- [x] ", "checkmark.square"),
                                 ("- ", "circle.fill"), ("* ", "circle.fill"), ("• ", "circle.fill")] {
            if line.hasPrefix(prefix) {
                return (symbol, String(line.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    /// Bold, italics and code inside a line.
    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Transcript row

/// One speaker's run of speech: the settled text plus what is still being spoken.
struct TranscriptGroup: Identifiable {
    let id: UUID
    let speaker: Speaker
    let tag: String?
    var finalText: String
    /// The same speech as it was originally heard, before polishing.
    var heardText: String
    var liveText: String
    /// Whether polishing changed any wording in this group.
    var polished: Bool
    /// Whether the speaker label was corrected from context.
    var speakerCorrected: Bool
    var lastTimestamp: Date
    /// When this paragraph started.
    var started: Date
    /// The transcript lines merged into this paragraph.
    var segmentIDs: [UUID]
}

struct SegmentRow: View {
    @EnvironmentObject var app: AppState
    let group: TranscriptGroup
    @State private var showHeard = false

    private var isMe: Bool { group.speaker == .me }
    /// Mic speech whose speaker isn't identified yet.
    private var isPending: Bool { group.tag == TranscriptSegment.pendingTag }

    private var text: Text {
        let settled = Text(showHeard && group.polished ? group.heardText : group.finalText)
            .foregroundColor(.white.opacity(0.93))
        guard !group.liveText.isEmpty else { return settled }
        let live = Text(group.finalText.isEmpty ? group.liveText : " " + group.liveText)
            .italic()
            .foregroundColor(.white.opacity(0.55))
        return settled + live
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // Wrong person? Clicking the badge hands the line to the next speaker.
            Button {
                app.cycleSpeaker(of: group.segmentIDs)
            } label: {
                SpeakerBadge(label: isPending ? "···" : (isMe ? "You" : (group.tag ?? "Them")),
                             color: isPending ? Color.white.opacity(0.45)
                                              : Theme.speakerColor(isMe: isMe, tag: group.tag))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isPending || group.finalText.isEmpty)
            .help("Wrong speaker? Click to switch who said this.")
            text
                .font(.system(size: 12))
                .lineSpacing(1.5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            TimeLabel(date: group.started)
            if group.speakerCorrected {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.amber.opacity(0.85))
                    .frame(width: 14, height: 16)
                    .help("Speaker corrected. The automatic label was different.")
            }
            if group.polished {
                // Polished line: the wand flips to what was originally heard.
                Button {
                    showHeard.toggle()
                } label: {
                    Image(systemName: showHeard ? "ear" : "wand.and.stars")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(showHeard ? Theme.amber : Theme.accent.opacity(0.75))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showHeard
                      ? "Showing what was heard. Click for the polished version."
                      : "Polished. Click to see what was originally heard.")
            }
        }
        // The line the recheck is looking at right now.
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Theme.accent.opacity(beingRechecked ? 0.16 : 0)))
        .padding(.horizontal, -4)
        .animation(.easeInOut(duration: 0.2), value: beingRechecked)
    }

    private var beingRechecked: Bool {
        guard let id = app.rescanningID else { return false }
        return group.segmentIDs.contains(id)
    }
}
