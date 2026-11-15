import CompanionDesign
import CompanionKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The chat open on the Mac, laid out as on the Mac: the glass top bar,
/// your messages on the right, replies across the width with the work they
/// took and their footer, the status and plan floating over the end of the
/// chat, and the chat box with the model, effort and mode under it.
struct ChatView: View {
    @Environment(LiveSession.self) private var session
    /// Opens the chats over this one (iPhone); nil when they are beside it.
    var showChats: (() -> Void)?
    /// In a panel of its own (iPad), on the panel's glass rather than a
    /// backdrop of its own.
    var framed = false
    @State private var draft = ""
    @State private var modelsOpen = false
    @State private var problem: String?
    @State private var planOpen = false
    @State private var atBottom = true
    @FocusState private var typing: Bool
    /// Photos and files picked for the next message, sent to the Mac as
    /// they are picked.
    @State private var files: [PhoneFile] = []
    @State private var photoPicks: [PhotosPickerItem] = []
    @State private var photosOpen = false
    @State private var filesOpen = false
    @State private var dictation = Dictation()
    /// The chat (on its Mac) whose words are in the box; each chat keeps
    /// its own, as on the Mac.
    @State private var draftFor = ""
    /// What was in the box when dictation started; the words heard go after it.
    @State private var beforeDictation = ""
    @State private var sentTick = 0

    private var meta: ChatMeta { session.meta }
    private var palette: Palette { Design.palette() }
    private var plan: [PlanStep] { (session.turns.last?.plan ?? []).map(\.design) }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                MessageStack {
                    if session.turns.isEmpty && meta.queued.isEmpty { empty }
                    ForEach(session.turns) { turn in
                        TurnView(turn: turn, last: turn.id == session.turns.last?.id, send: { say($0) },
                                 edit: { text, choice in
                                     run { try await session.edit(turn.id, to: text, choice: choice) }
                                 })
                            .equatable()
                            .id(turn.id)
                    }
                    // Sent while the agent works: in the chat, waiting for it.
                    ForEach(meta.queued) { item in
                        QueuedBubble(item: item) { action in
                            run { try await session.queued(action, item.id) }
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                        .onAppear { if !BottomTracking.measuresBottom { atBottom = true } }
                        .onDisappear { if !BottomTracking.measuresBottom { atBottom = false } }
                }
                .padding(.horizontal, Design.gutter)
                .padding(.top, 8)
                .padding(.bottom, 48)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .modifier(BottomTracking(atBottom: $atBottom))
            .onChange(of: session.turns.last?.reply.count) { _, _ in follow(reader) }
            .onChange(of: session.turns.count) { _, _ in follow(reader) }
            .onChange(of: meta.queued.count) { _, _ in follow(reader) }
            .overlay(alignment: .bottom) { floating(reader) }
        }
        .background { if !framed { CompanionBackdrop() } }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomArea }
        .toolbar(.hidden, for: .navigationBar)
        // Each chat keeps what is being written in it.
        .onAppear { swapDraft(to: meta.chat) }
        .onChange(of: meta.chat) { _, chat in swapDraft(to: chat) }
        .onChange(of: draft) { _, text in Drafts.shared.setText(text, for: draftFor) }
    }

    /// Puts away what is in the box with the chat it was written in, and
    /// brings back what was being written in the chat now open. Words typed
    /// while no chat was open stay in the box if the chat had none.
    private func swapDraft(to chat: String) {
        let next = Drafts.key(mac: session.store.selected?.id, chat: chat)
        guard next != draftFor else { return }
        if dictation.listening { dictation.stop() }
        let wasNone = draftFor.isEmpty
        if !wasNone {
            Drafts.shared.setText(draft, for: draftFor)
            Drafts.shared.setFiles(files, for: draftFor)
        }
        draftFor = next
        guard !next.isEmpty else { return }
        let words = Drafts.shared.text(for: next)
        if !(wasNone && words.isEmpty) { draft = words }
        let picked = Drafts.shared.files(for: next)
        if !(wasNone && picked.isEmpty) { files = picked }
    }

    private func follow(_ reader: ScrollViewProxy) {
        guard atBottom else { return }
        withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo("end", anchor: .bottom) }
    }

    /// A new chat, as on the Mac: the mark, and the ways to start as
    /// bubbles. One tap starts dictating, puts the cursor in the box, picks
    /// a photo or asks about the Mac's screen.
    private var empty: some View {
        VStack(spacing: 14) {
            LoadingMark(state: session.isLive ? .idle : .thinking, size: 48)
            Text(session.isLive ? "Ready when you are" : "Reaching your Mac…")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.ink.opacity(session.isLive ? 0.92 : 0.55))
            if session.isLive {
                let ways = starts
                ChoiceBubbles(ways.map { $0.bubble }, size: 14) { ways[$0].start() }
                    .frame(maxWidth: 380)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 110)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: session.isLive)
    }

    /// The ways to start a chat here, and what each does.
    private var starts: [(bubble: Bubble, start: () -> Void)] {
        [(Bubble("Dictate", icon: "mic.fill", detail: "say what you need"), { toggleDictation() }),
         (Bubble("Type", icon: "keyboard", detail: "a question or a task"), { typing = true }),
         (Bubble("Photo", icon: "photo", detail: "for it to look at"), { photosOpen = true }),
         (Bubble("Screen", icon: "text.viewfinder", detail: "ask about your Mac's screen"), { askAboutScreen() })]
    }

    // MARK: The top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            if let showChats {
                GlassIconButton("sidebar.left", label: "Chats", action: showChats)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(meta.title.isEmpty ? "Companion" : meta.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.ink.opacity(0.96))
                    .lineLimit(1)
                if !meta.mac.isEmpty {
                    Text(meta.mac)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.ink.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            GlassIconButton("square.and.pencil", label: "New chat") {
                run { try await session.newChat() }
            }
            .disabled(!session.isLive)
        }
        .padding(.horizontal, Design.gutter)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(alignment: .top) {
            LinearGradient(colors: [Color.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    // MARK: Floating over the end of the chat

    private func floating(_ reader: ScrollViewProxy) -> some View {
        ZStack(alignment: .bottom) {
            HStack {
                if meta.busy {
                    StatusPill(statusText, thinking: !meta.agentRunning, size: 13)
                }
                Spacer()
                if !plan.isEmpty, !planOpen {
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { planOpen = true } } label: {
                        PlanRing(plan: plan, size: 17, showsCount: true)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(Capsule().fill(Color.black.opacity(0.4)))
                            .liquidGlass(in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            if !atBottom {
                Button {
                    withAnimation(.easeOut(duration: 0.25)) { reader.scrollTo("end", anchor: .bottom) }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.ink.opacity(0.9))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.black.opacity(0.4)))
                        .liquidGlass(in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, meta.busy || !plan.isEmpty ? 40 : 0)
                .accessibilityLabel("Go to the newest message")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, Design.gutter)
        .padding(.bottom, 6)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: meta.busy)
        .animation(.easeOut(duration: 0.2), value: atBottom)
    }

    private var statusText: String {
        if meta.awaitingApproval { return "Waiting for your OK on the Mac" }
        if meta.question != nil { return "Waiting for your answer" }
        if meta.agentRunning { return meta.agentStatus.isEmpty ? "Working…" : meta.agentStatus }
        return "Thinking…"
    }

    // MARK: The chat box and what sits on it

    private var bottomArea: some View {
        VStack(spacing: 8) {
            if planOpen, !plan.isEmpty {
                PlanCard(plan: plan) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { planOpen = false }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let question = meta.question {
                QuestionCard(question: question, options: meta.options ?? []) { say($0) }
            }
            if let problem = problem ?? dictation.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(palette.rose)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !files.isEmpty { fileChips }
            chatBox
            controls
        }
        .padding(.horizontal, Design.gutter)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, Color.black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .onChange(of: plan.isEmpty) { _, gone in if gone { planOpen = false } }
        .onChange(of: dictation.heard) { _, heard in
            draft = beforeDictation.isEmpty ? heard : beforeDictation + " " + heard
        }
        .photosPicker(isPresented: $photosOpen, selection: $photoPicks, maxSelectionCount: 6, matching: .images)
        .onChange(of: photoPicks) { _, picks in
            guard !picks.isEmpty else { return }
            photoPicks = []
            for item in picks { upload(photo: item) }
        }
        .fileImporter(isPresented: $filesOpen, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls.prefix(6) { upload(file: url) }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sentTick)
        .sheet(isPresented: $modelsOpen) {
            ModelSheet()
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
    }

    /// The picked files above the box: each uploading, or ready, with ✕.
    private var fileChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(files) { file in
                    HStack(spacing: 6) {
                        if let thumb = file.thumbnail {
                            Image(uiImage: thumb).resizable().scaledToFill()
                                .frame(width: 26, height: 26)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        } else {
                            Image(systemName: "doc")
                                .font(.system(size: 13))
                                .foregroundStyle(palette.ink.opacity(0.7))
                        }
                        Text(file.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.ink.opacity(0.85))
                            .lineLimit(1)
                            .frame(maxWidth: 140)
                        if file.macID == nil, file.failed == false {
                            ProgressView().controlSize(.mini)
                        } else if file.failed {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(palette.amber)
                        }
                        Button { files.removeAll { $0.key == file.key } } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(palette.ink.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(file.name)")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.ink.opacity(0.08)))
                }
            }
        }
    }

    private func upload(photo item: PhotosPickerItem) {
        let key = UUID()
        files.append(PhoneFile(key: key, name: "Photo"))
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                mark(key, failed: true)
                return
            }
            // Sent as JPEG, a size the Mac reads quickly.
            let image = UIImage(data: data)
            let jpeg = image?.jpegData(compressionQuality: 0.82) ?? data
            let name = "Photo \(Date().formatted(.dateTime.hour().minute().second())).jpg"
                .replacingOccurrences(of: ":", with: ".")
            if let index = files.firstIndex(where: { $0.key == key }) {
                files[index].name = name
                files[index].thumbnail = image?.preparingThumbnail(of: CGSize(width: 80, height: 80))
            }
            do {
                let id = try await session.attach(jpeg, name: name)
                mark(key, id: id)
            } catch {
                mark(key, failed: true)
                problem = error.localizedDescription
            }
        }
    }

    private func upload(file url: URL) {
        let key = UUID()
        files.append(PhoneFile(key: key, name: url.lastPathComponent))
        Task {
            let reading = url.startAccessingSecurityScopedResource()
            defer { if reading { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                mark(key, failed: true)
                return
            }
            do {
                let id = try await session.attach(data, name: url.lastPathComponent)
                mark(key, id: id)
            } catch {
                mark(key, failed: true)
                problem = error.localizedDescription
            }
        }
    }

    private func mark(_ key: UUID, id: String? = nil, failed: Bool = false) {
        guard let index = files.firstIndex(where: { $0.key == key }) else { return }
        files[index].macID = id
        files[index].failed = failed
    }

    /// As on the Mac: the box holds only what you write, with Send (or
    /// Stop) at its end.
    private var chatBox: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(meta.question == nil ? "Ask anything" : "Your answer", text: $draft, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(1...6)
                .focused($typing)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            if meta.busy {
                Button {
                    run { try await session.stopWork() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(palette.rose))
                }
                .accessibilityLabel("Stop")
            }
            let uploading = files.contains { $0.macID == nil && !$0.failed }
            let ready = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.isLive && !uploading
            if !meta.busy || ready {
                Button { send(draft) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(palette.ink.opacity(ready ? 1 : 0.4))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(ready ? AnyShapeStyle(palette.accentGradient)
                                                        : AnyShapeStyle(palette.ink.opacity(0.10))))
                }
                .disabled(!ready)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.45)))
        .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(palette.accent.opacity(typing ? 0.45 : 0), lineWidth: 1))
        .animation(.easeOut(duration: 0.18), value: typing)
    }

    /// Under the box, as on the Mac: the model, its effort, and the mode.
    private var controls: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Photos", systemImage: "photo.on.rectangle") { photosOpen = true }
                Button("Files", systemImage: "folder") { filesOpen = true }
            } label: {
                RowIcon(symbol: "plus", on: !files.isEmpty)
            }
            .accessibilityLabel("Attach")
            Button {
                toggleDictation()
            } label: {
                RowIcon(symbol: dictation.listening ? "stop.fill" : "mic.fill", on: dictation.listening,
                        tint: dictation.listening ? palette.rose : nil)
            }
            .accessibilityLabel(dictation.listening ? "Stop dictating" : "Dictate")
            Button {
                askAboutScreen()
            } label: {
                RowIcon(symbol: "text.viewfinder", on: false)
            }
            .accessibilityLabel("Ask about your Mac's screen")
            if !meta.model.isEmpty {
                // The model in use; a tap lists the engines and their models.
                Button { modelsOpen = true } label: {
                    HStack(spacing: 6) {
                        LoadingMark(state: .idle, size: 14)
                        Text(meta.model)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.ink.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.up")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(palette.ink.opacity(0.5))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .bubbleSurface(tint: palette.accent, lit: modelsOpen)
                }
                .buttonStyle(.plain)
                .layoutPriority(-1)
                .accessibilityLabel("Model: \(meta.model)")
            }
            Spacer(minLength: 4)
            if !meta.efforts.isEmpty {
                EffortMenu(effort: meta.effort, levels: meta.efforts) { level in
                    run { try await session.setEffort(level) }
                }
            }
            AccessSwitch(access: meta.access) { access in
                run { try await session.setAccess(access) }
            }
        }
        .padding(.horizontal, 2)
        .disabled(!session.isLive)
    }

    private func send(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        if dictation.listening { dictation.stop() }
        // The files that reached the Mac go with it.
        let ids = files.compactMap(\.macID)
        let kept = files
        draft = ""
        files = []
        sentTick += 1
        Task {
            do {
                try await session.send(words, files: ids)
                problem = nil
            } catch {
                problem = error.localizedDescription
                if draft.isEmpty { draft = words }
                if files.isEmpty { files = kept }
            }
        }
    }

    /// Sends words that did not come from the box (a next step, a choice
    /// picked from the agent's question): the box keeps what is in it, as
    /// on the Mac.
    private func say(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        sentTick += 1
        run { try await session.send(words) }
    }

    /// Starts dictating into the box, after what is already in it, or stops.
    private func toggleDictation() {
        if dictation.listening {
            dictation.stop()
        } else {
            beforeDictation = draft.trimmingCharacters(in: .whitespaces)
            Task { await dictation.start() }
        }
    }

    /// Asks about what is on the Mac's screen, with what is in the box as
    /// the question.
    private func askAboutScreen() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        run { try await session.lookAtScreen(question) }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

// MARK: - One exchange

/// Your message on the right in its bubble, with its time and Copy under
/// it; then the work it took, the reply across the width, and the reply's
/// footer: Copy, then the model and the time.
/// The chat's messages, top to bottom.
///
/// On iOS 18 and later this is a plain stack. A lazy stack guesses the
/// height of rows it has not drawn, and on iOS 26 those guesses, with the
/// chat held to its bottom and the keyboard up, make the whole chat bounce
/// up and down while anything in it moves (Apple feedback FB20979569). A
/// plain stack knows every height. Rows are drawn again only when their
/// turn changes (`TurnView` is `Equatable`), so a long chat stays cheap.
/// iOS 17 keeps the lazy stack.
private struct MessageStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 18, *) {
            VStack(alignment: .leading, spacing: 20) { content }
        } else {
            LazyVStack(alignment: .leading, spacing: 20) { content }
        }
    }
}

/// Keeps `atBottom` true while the end of the chat is in view, read from
/// the scroll view's own geometry. A plain stack shows all its rows at
/// once, so the end marker's appearing no longer says where the user is.
private struct BottomTracking: ViewModifier {
    @Binding var atBottom: Bool

    /// Whether the geometry decides; before iOS 18 the end marker does.
    static var measuresBottom: Bool {
        if #available(iOS 18, *) { return true } else { return false }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                // Within a few lines of the end counts as at the end.
                geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom
                    >= geometry.contentSize.height - 60
            } action: { _, isAtBottom in
                atBottom = isAtBottom
            }
        } else {
            content
        }
    }
}

extension TurnView: Equatable {
    /// A row is drawn again only when what it shows changes: its turn, or
    /// whether it is the last one. The closures only pass actions on.
    static func == (lhs: TurnView, rhs: TurnView) -> Bool {
        lhs.turn == rhs.turn && lhs.last == rhs.last
    }
}

struct TurnView: View {
    @Environment(LiveSession.self) private var session
    let turn: Turn
    let last: Bool
    let send: (String) -> Void
    /// Sends the message again, changed: in place (""), or "fork",
    /// "rewindCode", "forkAndRewind".
    let edit: (String, String) -> Void
    @State private var workOpen = false
    @State private var copied: String?
    @State private var editing = false
    @State private var editText = ""
    @State private var choosing = false

    private var palette: Palette { Design.palette() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if turn.image, let client = session.client {
                AsyncImage(url: client.imageURL(turn: turn.id)) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 10).fill(palette.ink.opacity(0.06)).frame(height: 120)
                }
                .frame(maxWidth: 240)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if !turn.me.isEmpty { request }
            if !turn.steps.isEmpty { work }
            if !turn.reply.isEmpty {
                Text(markdown(turn.reply))
                    .font(.system(size: 15))
                    .foregroundStyle(palette.ink.opacity(0.92))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if turn.streaming, turn.steps.isEmpty {
                HStack(spacing: 7) {
                    LoadingMark(state: .thinking, size: 16)
                    Text("Thinking…")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.ink.opacity(0.55))
                }
            }
            if !turn.error.isEmpty {
                Label(turn.error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(palette.rose)
            }
            if !turn.streaming, !turn.reply.isEmpty { replyFooter }
            if last, !turn.streaming, !turn.suggestions.isEmpty {
                NextSteps(steps: turn.suggestions, send: send)
            }
        }
    }

    private var request: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if editing {
                editor
            } else {
            Text(turn.me)
                .font(.system(size: 15))
                .foregroundStyle(palette.ink.opacity(0.93))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(BubbleShape(side: .right).fill(palette.accent.opacity(0.10)))
                .overlay(BubbleShape(side: .right).strokeBorder(palette.accent.opacity(0.24), lineWidth: 0.5))
            HStack(spacing: 4) {
                if let date = turn.date {
                    Text(date, style: .time)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.ink.opacity(0.45))
                        .padding(.trailing, 4)
                }
                if !turn.streaming {
                    FooterIcon("pencil", label: "Edit") {
                        editText = turn.me
                        editing = true
                    }
                }
                FooterIcon(copied == "me" ? "checkmark" : "doc.on.doc", label: "Copy",
                           tint: copied == "me" ? palette.mint : nil) { copy(turn.me, as: "me") }
            }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .confirmationDialog("Files have changed since this message", isPresented: $choosing, titleVisibility: .visible) {
            Button("Fork conversation from here") { finishEdit("fork") }
            Button("Rewind code to here") { finishEdit("rewindCode") }
            Button("Fork conversation and rewind code") { finishEdit("forkAndRewind") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Send the edited message in a new chat, put the files back as they were before it, or both.")
        }
    }

    /// The message open for editing, in its bubble: Cancel and Send.
    private var editor: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("Message", text: $editText, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(1...10)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(BubbleShape(side: .right).fill(palette.accent.opacity(0.14)))
                .overlay(BubbleShape(side: .right).strokeBorder(palette.accent.opacity(0.45), lineWidth: 1))
            HStack(spacing: 14) {
                Button("Cancel") { editing = false }
                    .foregroundStyle(palette.ink.opacity(0.7))
                Button("Send") {
                    if turn.canRewind { choosing = true } else { finishEdit("") }
                }
                .fontWeight(.semibold)
                .foregroundStyle(palette.accent)
                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.system(size: 14))
            .buttonStyle(.plain)
        }
    }

    private func finishEdit(_ choice: String) {
        editing = false
        edit(editText, choice)
    }

    /// The work it took: one line until opened, open while it is going.
    private var work: some View {
        let open = workOpen || turn.streaming
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { workOpen.toggle() }
            } label: {
                HStack(spacing: 7) {
                    LoadingMark(state: turn.streaming ? .working : (turn.steps.contains(where: \.failed) && !turn.error.isEmpty ? .failed : .done),
                                size: 15)
                    Text(turn.streaming ? (turn.steps.last.map { $0.why?.isEmpty == false ? $0.why! : $0.title } ?? "Working")
                         : "\(turn.steps.count) step\(turn.steps.count == 1 ? "" : "s")")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.ink.opacity(0.7))
                        .lineLimit(1)
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(palette.ink.opacity(0.4))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                StepTrail(steps: turn.steps.map(\.design), live: turn.streaming, textSize: 13)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                        .fill(palette.ink.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                        .strokeBorder(palette.ink.opacity(0.08), lineWidth: 0.5))
                    .transition(.opacity)
            }
        }
    }

    /// As on the Mac: what can be done with it, a divider, then the facts.
    private var replyFooter: some View {
        HStack(spacing: 4) {
            FooterIcon(copied == "reply" ? "checkmark" : "doc.on.doc", label: "Copy",
                       tint: copied == "reply" ? palette.mint : nil) { copy(turn.reply, as: "reply") }
            ShareLink(item: turn.reply) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.ink.opacity(0.6))
                    .frame(width: 30, height: 30)
            }
            Rectangle().fill(palette.ink.opacity(0.12)).frame(width: 1, height: 14).padding(.horizontal, 4)
            LoadingMark(state: .idle, size: 12)
            Text(turn.model)
                .lineLimit(1)
            if let date = turn.date {
                Text("·")
                Text(date, style: .time)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(palette.ink.opacity(0.45))
    }

    private func copy(_ text: String, as which: String) {
        UIPasteboard.general.string = text
        copied = which
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copied == which { copied = nil }
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Pieces, as on the Mac

/// A round glass button in the top bar.
struct GlassIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    init(_ symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Design.palette().ink.opacity(0.85))
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.black.opacity(0.35)))
                .liquidGlass(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A small footer action.
struct FooterIcon: View {
    let symbol: String
    let label: String
    var tint: Color?
    let action: () -> Void

    init(_ symbol: String, label: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint ?? Design.palette().ink.opacity(0.6))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A message sent while the agent works: in the chat as yours, dimmed,
/// waiting for the agent, with Send now and Cancel (Restore once cancelled).
struct QueuedBubble: View {
    let item: QueuedMessage
    let act: (String) -> Void

    var body: some View {
        let palette = Design.palette()
        VStack(alignment: .trailing, spacing: 5) {
            Text(item.text)
                .font(.system(size: 15))
                .foregroundStyle(palette.ink.opacity(item.void ? 0.35 : 0.6))
                .strikethrough(item.void, color: palette.ink.opacity(0.4))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(BubbleShape(side: .right).fill(palette.accent.opacity(0.06)))
                .overlay(BubbleShape(side: .right)
                    .strokeBorder(palette.accent.opacity(0.28), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3])))
            HStack(spacing: 14) {
                if item.void {
                    Text("Cancelled").foregroundStyle(palette.ink.opacity(0.4))
                    Button("Restore") { act("restore") }.underline()
                        .foregroundStyle(palette.ink.opacity(0.7))
                } else {
                    Label("Waiting for the agent", systemImage: "clock")
                        .foregroundStyle(palette.ink.opacity(0.45))
                    Button("Cancel") { act("cancel") }.underline()
                        .foregroundStyle(palette.rose)
                    Button("Send now") { act("now") }.underline()
                        .foregroundStyle(palette.accent)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// What to do next once the agent is done: a bubble each, one tap to do one.
struct NextSteps: View {
    let steps: [String]
    let send: (String) -> Void

    var body: some View {
        let palette = Design.palette()
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.accentGradient)
                Text("Next step")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
            // Each step a bubble, as on the Mac; one tap does it.
            ChoiceBubbles(steps, size: 14) { send($0) }
                .id(steps)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous).fill(palette.ink.opacity(0.05)))
    }
}

/// The plan, open above the chat box: its progress and ✕ at the top right,
/// the checklist under them, scrolling when long.
struct PlanCard: View {
    let plan: [PlanStep]
    let close: () -> Void

    var body: some View {
        let palette = Design.palette()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Plan")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.ink.opacity(0.95))
                Spacer()
                PlanRing(plan: plan, size: 16, showsCount: true)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(Capsule().fill(palette.accent.opacity(0.16)))
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(palette.ink.opacity(0.6))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(palette.ink.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close the plan")
            }
            ScrollView {
                PlanChecklist(plan: plan, textSize: 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.45)))
        .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// The effort, as the Mac's pill: the fire ball, burning brighter the
/// harder it thinks, and the level; tap for the levels.
struct EffortMenu: View {
    let effort: String
    let levels: [String]
    let choose: (String) -> Void

    private var heat: Double {
        guard let index = levels.firstIndex(of: effort) else { return 0 }
        return Double(index + 1) / Double(levels.count)
    }

    var body: some View {
        let palette = Design.palette()
        let lit = !effort.isEmpty
        Menu {
            Button("Auto") { choose("") }
            ForEach(levels, id: \.self) { level in
                Button(Self.label(level)) { choose(level) }
            }
        } label: {
            HStack(spacing: 5) {
                // Burning, still: the box's controls stay in view, and a
                // flicker would redraw the screen all the time.
                Fireball(heat: heat, size: 12, alive: lit, flickers: false)
                Text(Self.label(effort))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(lit ? palette.accent : palette.ink.opacity(0.85))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .bubbleSurface(tint: lit ? palette.accent : nil)
            .shadow(color: palette.accent.opacity(lit ? 0.10 + 0.22 * heat : 0), radius: 2 + 4 * heat)
        }
        .accessibilityLabel("Effort: \(Self.label(effort))")
    }

    static func label(_ level: String) -> String {
        switch level {
        case "": return "Auto"
        case "xhigh": return "Extra high"
        default: return level.prefix(1).uppercased() + level.dropFirst()
        }
    }
}

/// Manual or Auto, as the Mac's switch; when Auto, its mark says how far
/// (edits, or full access) and a tap on it changes that.
struct AccessSwitch: View {
    let access: String
    let choose: (String) -> Void
    /// The chosen side's own small bubble slides from one side to the other.
    @Namespace private var chosen

    private var auto: Bool { access != "manual" }

    /// The small bubble behind the chosen side.
    @ViewBuilder
    private func mark(_ on: Bool, _ tint: Color) -> some View {
        if on {
            Capsule()
                .fill(tint.opacity(0.18))
                .overlay(Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
                .matchedGeometryEffect(id: "chosen", in: chosen)
        }
    }

    var body: some View {
        let palette = Design.palette()
        let tint = access == "full" ? palette.rose : palette.amber
        HStack(spacing: 2) {
            Button { choose("manual") } label: {
                Text("Manual")
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background { mark(!auto, palette.ink) }
                    .foregroundStyle(palette.ink.opacity(auto ? 0.55 : 0.95))
            }
            Button { if !auto { choose("autoEdit") } } label: {
                HStack(spacing: 5) {
                    Text("Auto")
                    if auto {
                        Image(systemName: access == "full" ? "bolt.fill" : "pencil")
                            .font(.system(size: 9.5, weight: .bold))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(tint.opacity(0.22)))
                            .onTapGesture { choose(access == "full" ? "autoEdit" : "full") }
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background { mark(auto, tint) }
                .foregroundStyle(auto ? tint : palette.ink.opacity(0.55))
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .buttonStyle(.plain)
        .padding(2)
        .bubbleSurface(tint: auto ? tint : nil, lifts: false)
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: access)
    }
}

/// The agent's question, with its choices as numbered bubbles.
struct QuestionCard: View {
    let question: String
    let options: [String]
    let answer: (String) -> Void

    var body: some View {
        let palette = Design.palette()
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                LoadingMark(state: .waiting, size: 14)
                Text(question)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.ink.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Its choices, as bubbles, as on the Mac; one tap answers.
            if !options.isEmpty {
                ChoiceBubbles(options, numbered: true, size: 14) { answer($0) }
                    .id(question)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous).fill(Color.black.opacity(0.4)))
        .liquidGlass(in: RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous), tint: palette.amber)
    }
}

// MARK: - From the feed's shapes to the shared views'

extension CompanionKit.PlanItem {
    var design: PlanStep {
        PlanStep(text: text, state: PlanStep.State(rawValue: state.rawValue) ?? .todo)
    }
}

extension CompanionKit.WorkStep {
    var design: TrailStep {
        TrailStep(kind: kind, title: title,
                  why: (why ?? "").isEmpty ? nil : why,
                  output: (output ?? "").isEmpty ? nil : output,
                  failed: failed)
    }
}


/// A photo or file picked for the next message: uploading until the Mac
/// gives it an id.
struct PhoneFile: Identifiable {
    var key: UUID
    var name: String
    /// The Mac's id for it, once it has arrived there.
    var macID: String?
    var failed = false
    var thumbnail: UIImage?

    init(key: UUID, name: String) {
        self.key = key
        self.name = name
    }

    var id: UUID { key }
}

/// A round button in the row under the chat box, as on the Mac.
struct RowIcon: View {
    let symbol: String
    let on: Bool
    var tint: Color?

    var body: some View {
        let palette = Design.palette()
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(tint ?? (on ? palette.accent : palette.ink.opacity(0.85)))
            .frame(width: 30, height: 30)
            .background(Circle().fill((tint ?? (on ? palette.accent : palette.ink)).opacity(on ? 0.18 : 0.10)))
    }
}
