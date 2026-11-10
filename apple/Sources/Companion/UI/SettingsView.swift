import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            ProvidersTab()
                .tabItem { Label("Providers", systemImage: "brain") }
            ContextTab()
                .tabItem { Label("My Details", systemImage: "person.text.rectangle") }
            BehaviorTab()
                .tabItem { Label("Behavior", systemImage: "slider.horizontal.3") }
            MemoryTab()
                .tabItem { Label("Memory", systemImage: "brain.head.profile") }
        }
        .frame(width: 540, height: 460)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

private struct ProvidersTab: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var app = AppState.shared
    @State private var anthropicKey = Keychain.read("anthropic") ?? ""
    @State private var openAIKey = Keychain.read("openai") ?? ""
    @State private var farhelmKey = Keychain.read("farhelm") ?? ""
    @State private var farhelmModels: [String] = []
    @State private var farhelmModelsStatus: String?

    var body: some View {
        Form {
            Picker("Reply engine", selection: $settings.provider) {
                ForEach(LLMProviderKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.radioGroup)

            switch settings.provider {
            case .farhelm:
                Section("Farhelm (local gateway)") {
                    SecureField("Client key", text: $farhelmKey)
                        .onChange(of: farhelmKey) { _, value in
                            Keychain.write(value, account: "farhelm")
                        }
                    TextField("Gateway URL", text: $settings.farhelmURL)
                    Picker("Model", selection: $settings.farhelmModel) {
                        Text("Auto (Farhelm routes)").tag("")
                        if !settings.farhelmModel.isEmpty, !farhelmModels.contains(settings.farhelmModel) {
                            Text(settings.farhelmModel).tag(settings.farhelmModel)
                        }
                        ForEach(farhelmModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    HStack {
                        Button("Load available models") {
                            Task { await loadFarhelmModels() }
                        }
                        if let status = farhelmModelsStatus {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Picker("Context window", selection: $settings.localContextTokens) {
                        ForEach(ContextBudget.localChoices, id: \.self) { tokens in
                            Text("\(tokens / 1000)k tokens").tag(tokens)
                        }
                    }
                    Text("Set the context window to what Farhelm loads the model with; Companion sizes its requests to fit. One-time setup on this Mac: farhelm clients add companion, then restart the runner. Everything here saves as you change it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .onAppear {
                    if !farhelmKey.isEmpty, farhelmModels.isEmpty {
                        Task { await loadFarhelmModels() }
                    }
                }
            case .anthropic:
                Section("Anthropic") {
                    SecureField("API key", text: $anthropicKey)
                        .onChange(of: anthropicKey) { _, value in
                            Keychain.write(value, account: "anthropic")
                        }
                    Picker("Model", selection: $settings.anthropicModel) {
                        if !app.anthropicModels.contains(settings.anthropicModel) {
                            Text(settings.anthropicModel).tag(settings.anthropicModel)
                        }
                        ForEach(app.anthropicModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    HStack {
                        Button("Load available models") {
                            app.loadAnthropicModels()
                        }
                        if let status = app.anthropicModelsStatus {
                            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    TextField("Or type a model ID", text: $settings.anthropicModel)
                    Text("Key is stored in your Keychain. ANTHROPIC_API_KEY env var works too. Haiku is the fastest, which suits live replies; Sonnet and Opus answer better but slower.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .onAppear {
                    if !anthropicKey.isEmpty {
                        app.loadAnthropicModels()
                    }
                }
            case .openai:
                Section("OpenAI") {
                    SecureField("API key", text: $openAIKey)
                        .onChange(of: openAIKey) { _, value in
                            Keychain.write(value, account: "openai")
                        }
                    TextField("Model", text: $settings.openAIModel)
                    Text("Key is stored in your Keychain. OPENAI_API_KEY env var works too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .ollama:
                Section("Ollama (local)") {
                    TextField("Server URL", text: $settings.ollamaURL)
                    TextField("Model", text: $settings.ollamaModel)
                    Picker("Context window", selection: $settings.localContextTokens) {
                        ForEach(ContextBudget.localChoices, id: \.self) { tokens in
                            Text("\(tokens / 1000)k tokens").tag(tokens)
                        }
                    }
                    Text("Install from ollama.com, then run: ollama pull \(settings.ollamaModel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Context") {
                Text(ContextBudget.current.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }

    @MainActor
    private func loadFarhelmModels() async {
        farhelmModelsStatus = "Loading…"
        do {
            let models = try await ModelCatalog.openAIStyleModels(base: settings.farhelmURL, bearer: farhelmKey)
            farhelmModels = models
            farhelmModelsStatus = models.isEmpty ? "Gateway reported no models" : "\(models.count) available"
        } catch {
            farhelmModelsStatus = error.localizedDescription
        }
    }
}

private struct ContextTab: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What Companion should know when drafting your replies: who you are, your product, pricing, talking points, FAQs, the role you're interviewing for.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextEditor(text: $settings.userDetails)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .frame(maxHeight: .infinity)
            HStack {
                Button("Open context folder") {
                    NSWorkspace.shared.open(ContextStore.shared.contextDir)
                }
                Text("Any .md or .txt files dropped there are included too.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

/// Guided voice setup, in the style of Siri's: read each sentence aloud and
/// it advances on its own once it has heard enough.
private struct VoiceSetupSheet: View {
    @ObservedObject var app = AppState.shared
    @Binding var isPresented: Bool

    private var phrases: [String] { AppState.enrollmentPhrases }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: app.enrollSucceeded ? "checkmark.circle.fill" : "waveform.circle.fill")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(app.enrollSucceeded ? Theme.mint : Theme.accent)
                .symbolEffect(.variableColor.iterative, isActive: app.isEnrollingVoice && app.enrollMessage == nil)

            if app.enrollSucceeded {
                Text("Your voice is set up")
                    .font(.title3.weight(.semibold))
                Text("Companion will now tell your voice apart from everyone else on the microphone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let message = app.enrollMessage {
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                if app.isEnrollingVoice {
                    ProgressView()
                        .controlSize(.small)
                }
            } else if app.isEnrollingVoice {
                Text("Read this aloud, in your normal voice")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("\u{201C}\(phrases[min(app.enrollStep, phrases.count - 1)])\u{201D}")
                    .font(.system(size: 20, weight: .medium))
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 80)
                    .id(app.enrollStep)
                    .transition(.opacity)
                ProgressView(value: app.enrollStepProgress)
                    .tint(Theme.accent)
                HStack(spacing: 6) {
                    ForEach(phrases.indices, id: \.self) { index in
                        Capsule()
                            .fill(index < app.enrollStep
                                  ? Theme.mint
                                  : (index == app.enrollStep ? Theme.accent : Color.secondary.opacity(0.3)))
                            .frame(width: index == app.enrollStep ? 22 : 10, height: 5)
                    }
                    Spacer()
                    LevelBars(level: app.enrollLevel)
                    Text("\(min(app.enrollStep + 1, phrases.count)) of \(phrases.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                Text("Voice setup was cancelled.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                if app.isEnrollingVoice {
                    Button("Cancel") {
                        app.cancelEnrollment()
                        isPresented = false
                    }
                    .keyboardShortcut(.cancelAction)
                } else {
                    Button("Done") { isPresented = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(26)
        .frame(width: 460)
        .animation(.easeInOut(duration: 0.25), value: app.enrollStep)
    }
}

/// What Companion has learned from earlier conversations, all of it visible
/// and deletable.
private struct MemoryTab: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var memory = MemoryStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Remember key facts across conversations", isOn: $settings.rememberAcross)
            Text("When a conversation is written up, a few facts worth knowing later are saved here: who you spoke with, what you were asked and how you answered, commitments and dates. They are stored on this Mac only, and the relevant ones are given to the model in later conversations.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if memory.items.isEmpty {
                Text("Nothing remembered yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(memory.items.reversed()) { item in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.text)
                                    .font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("\(item.title) · \(item.date.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Button {
                                memory.delete(item.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Forget this")
                        }
                        .padding(.vertical, 2)
                    }
                }
                HStack {
                    Text("\(memory.items.count) remembered")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget everything", role: .destructive) {
                        memory.clear()
                    }
                }
            }
        }
        .padding(16)
    }
}

private struct BehaviorTab: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var app = AppState.shared
    @State private var showVoiceSetup = false

    var body: some View {
        Form {
            Section("Audio") {
                Toggle("Capture microphone (You)", isOn: $settings.captureMic)
                Toggle("Capture system audio (Them: Zoom, Meet, any app)", isOn: $settings.captureSystemAudio)
                Toggle("English-only transcription (more accurate for English)", isOn: $settings.asrEnglishOnly)
                Picker("Mic sensitivity", selection: $settings.micSensitivity) {
                    ForEach(MicSensitivity.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                Text("High picks up quieter audio: a phone on speaker, or someone farther from the Mac. If the level bars barely move while the other person talks, raise this. System audio needs Screen Recording permission; use headphones so your speakers don't leak Them into the mic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Voices on the mic") {
                Toggle("Separate voices (in-person talks, speakerphone calls)", isOn: $settings.separateMicVoices)
                HStack {
                    Button(app.voiceEnrolled ? "Redo voice setup…" : "Set up my voice…") {
                        showVoiceSetup = true
                        app.enrollVoice()
                    }
                    Text(app.voiceEnrolled
                         ? "Your voice is set up."
                         : "Needed once, so Companion knows which voice is you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("With this on, your voice stays You; every other voice the mic hears becomes P1, P2, ... and gets reply suggestions. Setup has you read five short sentences aloud. Live labels use two models together (a diarizer plus a voiceprint check), and Recheck re-labels the whole session from the recorded audio with a third, more accurate one. First use downloads the speaker models. Mic audio is kept in memory only, for up to 30 minutes, and is gone when the app quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .sheet(isPresented: $showVoiceSetup) {
                VoiceSetupSheet(isPresented: $showVoiceSetup)
            }
            Section("Ask from anywhere") {
                Picker("Hotkey", selection: $settings.askHotKey) {
                    ForEach(HotKeys.askChoices, id: \.letter) { choice in
                        Text("Cmd+Shift+\(choice.letter)").tag(choice.letter)
                    }
                }
                Text("Opens the panel with the cursor in the input box, from any app and without leaving it. Type your question and press Return.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Assist") {
                Toggle("Auto-suggest a reply after they finish speaking", isOn: $settings.autoSuggest)
                Toggle("Skip short remarks that aren't questions (fewer replies)", isOn: $settings.replyToQuestionsOnly)
                    .disabled(!settings.autoSuggest)
                Toggle("Polish the transcript (fix misheard words, tidy the wording)", isOn: $settings.polishTranscript)
                Toggle("Keep running notes so long conversations stay in context", isOn: $settings.keepNotes)
                Toggle("Watch screen and answer new questions automatically", isOn: $settings.autoScreenWatch)
            }
            Section("Screen") {
                Picker("Monitor to read", selection: $settings.screenDisplayID) {
                    Text("Automatic (where the pointer is)").tag(0)
                    ForEach(ScreenReader.screens()) { screen in
                        Text(screen.name).tag(screen.id)
                    }
                    // A saved monitor that is not connected right now.
                    if settings.screenDisplayID != 0,
                       !ScreenReader.screens().contains(where: { $0.id == settings.screenDisplayID }) {
                        Text("Disconnected monitor").tag(settings.screenDisplayID)
                    }
                }
                Picker("Check the screen every", selection: $settings.screenWatchInterval) {
                    ForEach([2, 3, 5, 10], id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
                Text("While Screen is on, Companion glances at the screen this often. It only reads it when something changed and has stopped moving, and only answers a question it has not answered yet. After a minute without change it slows to every 10 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Which monitor screen answers and the screen watcher look at. Automatic uses the monitor your mouse pointer is on at that moment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Agent") {
                HStack {
                    Text(DeviceControl.shared.allowed
                         ? "Accessibility permission is granted."
                         : "Needs the Accessibility permission.")
                    Spacer()
                    if !DeviceControl.shared.allowed {
                        Button("Allow…") { DeviceControl.shared.requestAccess() }
                    }
                }
                HStack {
                    TextField("Working folder", text: $settings.agentDirectory)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            settings.agentDirectory = url.path
                        }
                    }
                }
                Toggle("Run read-only commands without asking (ls, cat, git status, osascript queries, screenshots to /tmp)", isOn: $settings.agentAutoApproveReads)
                Toggle("Voice: say \"Companion, ...\" to give a task, and \"allow\" or \"deny\" to answer", isOn: $settings.voiceCommands)
                if !settings.agentAllowed.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Always allowed")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(settings.agentAllowed, id: \.self) { name in
                            HStack {
                                Text(name).font(.system(size: 12, design: .monospaced))
                                Spacer()
                                Button {
                                    settings.agentAllowed.removeAll { $0 == name }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Ask about this again")
                            }
                        }
                    }
                }
                Text("There is one chat box. Ask a question and it is answered; tell Companion to do something and the agent takes it on. It works like a coding agent: it proposes the next step (a shell command, opening an app, typing into one), you see exactly what it is and choose Allow, Always allow or Deny, it runs, and it reads the result before the next step. With the switch above on, commands that only read run without asking; anything that writes, deletes, sends or types always asks. Shell commands start in the working folder. Clicking and typing in apps need the Accessibility permission above. It clicks buttons, menu items and checkboxes by their label, and checks each step afterwards: a click names what was pressed, typed text is looked for on screen, an opened app has to come to the front.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Toggle("Hide Companion from screen sharing and recordings", isOn: $settings.hideFromScreenShare)
            }
            Section("Appearance") {
                Picker("Background", selection: $settings.panelStyle) {
                    ForEach(PanelStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Darkness")
                    Slider(value: $settings.panelDarkness, in: 0...0.8)
                    Text("\(Int(settings.panelDarkness * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                Text("Clear has no blur, so what's behind stays visible; text keeps full contrast either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
