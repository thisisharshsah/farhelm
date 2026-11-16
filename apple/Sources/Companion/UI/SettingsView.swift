import CEFKit
import SwiftUI
import AppKit

/// Settings, shown inside the panel in place of the conversation.
///
/// A list of sections down the left with a search box, the chosen section
/// on the right. Every section is a card of rows: a name, one line on what
/// it does, and the control.
struct SettingsView: View {
    @ObservedObject var app = AppState.shared
    /// Kept outside the view, so the page you are on stays put when a change
    /// of color or theme redraws the whole panel, and when Settings is
    /// opened again.
    @AppStorage("settingsTab") private var tab = Tab.engine
    @Namespace private var tabSpace

    private enum Tab: String, CaseIterable, Identifiable {
        case engine = "Engine"
        case you = "You"
        case listening = "Listening"
        case replies = "Replies"
        case screen = "Screen"
        case agent = "Agent"
        case skills = "Skills"
        case browser = "Browser"
        case keys = "Keys"
        case remote = "Remote"
        case usage = "Usage"
        case look = "Look"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .engine: return "cpu"
            case .you: return "person.crop.circle"
            case .listening: return "waveform"
            case .replies: return "text.bubble"
            case .screen: return "text.viewfinder"
            case .agent: return "terminal"
            case .skills: return "book.closed"
            case .browser: return "globe"
            case .keys: return "keyboard"
            case .remote: return "iphone"
            case .usage: return "chart.bar"
            case .look: return "paintbrush"
            }
        }

        var subtitle: String {
            switch self {
            case .engine: return "Which model writes the answers"
            case .you: return "What Companion knows and remembers about you"
            case .listening: return "What it hears, and who is speaking"
            case .replies: return "When and how it suggests what to say"
            case .screen: return "What it reads from your display"
            case .agent: return "What it may do on this Mac"
            case .skills: return "Ways of working the agent follows, and where they were used"
            case .browser: return "Extensions, passwords and sign-ins for Companion's browser"
            case .keys: return "Shortcuts that work from any app"
            case .remote: return "Watch and message this chat from your phone"
            case .usage: return "Tokens used and what they cost"
            case .look: return "Theme, background and the app itself"
            }
        }

        /// Words that should find this section in the search box, beyond
        /// its name: the settings that live in it.
        var keywords: String {
            switch self {
            case .engine: return "model claude openai farhelm ollama api key effort context window provider"
            case .you: return "details about me memory remember context folder profile"
            case .listening: return "microphone mic system audio voice speaker english sensitivity enroll reference"
            case .replies: return "auto reply suggest questions polish transcript notes"
            case .screen: return "watch monitor display interval privacy screen sharing hide"
            case .agent: return "accessibility working folder approve commands voice commands allowed shell"
            case .skills: return "skills skill.md github anthropic superpowers install library plugins chats used"
            case .browser: return "browser extensions chrome web store arc brave edge import passwords keychain icloud login sign in sign up autofill apwlib"
            case .keys: return "shortcut hotkey keyboard keys"
            case .remote: return "remote phone mobile ios web server network qr pair session wifi"
            case .usage: return "cost price tokens budget plan export csv spend billing"
            case .look: return "theme dark light appearance background darkness quit reset position"
            }
        }
    }

    /// The sections, grouped the way they are listed: what runs it, what it
    /// does, and the app itself.
    private static let groups: [[Tab]] = [
        [.engine, .usage],
        [.you, .listening, .replies, .screen, .agent, .skills, .browser],
        [.keys, .remote, .look]
    ]

    @State private var search = ""
    @FocusState private var searchFocused: Bool
    /// How wide the list of pages is.
    @AppStorage("settingsNavigationWidth") private var navigationWidth: Double = 150

    private func matches(_ item: Tab) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return "\(item.rawValue) \(item.subtitle) \(item.keywords)".lowercased().contains(query)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            navigation
                .frame(width: CGFloat(min(max(navigationWidth, 130), 260)))
            // Drag to give the list more or less room.
            ColumnDivider(width: { CGFloat(navigationWidth) },
                          direction: 1,
                          resize: { navigationWidth = Double(min(max($0, 130), 260)) },
                          reset: { navigationWidth = 150 },
                          done: {})
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tab.rawValue)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.ink.opacity(0.96))
                        Text(tab.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ink.opacity(0.55))
                    }
                    .id(tab)
                    .transition(.opacity)
                    Spacer()
                    PillButton("Done", prominent: true) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { app.showSettings = false }
                    }
                    .keyboardShortcut(.cancelAction)
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 9) {
                        switch tab {
                        case .engine: EngineSettings()
                        case .you: YouSettings()
                        case .listening: ListeningSettings()
                        case .replies: RepliesSettings()
                        case .screen: ScreenSettings()
                        case .agent:
                            AgentSettings()
                            ChromeSettings()
                        case .skills: SkillsSettings()
                        case .browser:
                            ChromiumSettings()
                            PasswordsSettings()
                        case .keys: ShortcutSettings()
                        case .remote: RemoteSettings()
                        case .usage: UsageSettings()
                        case .look: LookSettings()
                        }
                    }
                    .padding(.bottom, 6)
                    .id(tab)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        // Settings need more width than a chat: the panel grows for them
        // and goes back to its size afterwards.
        .onAppear { app.overlay?.setSettingsRoom(true) }
        .onDisappear { app.overlay?.setSettingsRoom(false) }
    }

    /// The list of sections down the left, with a search box above it.
    private var navigation: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(searchFocused ? Theme.accent : Theme.ink.opacity(0.45))
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink.opacity(0.95))
                    .focused($searchFocused)
                    .onSubmit {
                        // Return opens the first section found.
                        if let first = Tab.allCases.first(where: matches) {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { tab = first }
                        }
                    }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.ink.opacity(0.07)))
            .glassBorder(radius: 8, tint: searchFocused ? Theme.accent : nil)
            .padding(.bottom, 6)

            ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
                let shown = group.filter(matches)
                if index > 0, !shown.isEmpty, search.isEmpty {
                    Rectangle()
                        .fill(Theme.ink.opacity(0.08))
                        .frame(height: 1)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 6)
                }
                ForEach(shown) { item in
                    let on = item == tab
                    HStack(spacing: 9) {
                        Image(systemName: item.icon)
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(width: 18)
                        Text(item.rawValue)
                            .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(on ? Theme.accent : Theme.ink.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                                .fill(Theme.accent.opacity(0.14))
                                .matchedGeometryEffect(id: "tab", in: tabSpace)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { tab = item }
                    }
                    .help(item.subtitle)
                }
            }
            if !Tab.allCases.contains(where: matches) {
                Text("Nothing matches.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
    }
}

// MARK: - Building blocks

/// A titled group of settings.
private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    var tint: Color
    var status: String?
    var statusTint: Color?
    let content: Content

    init(_ title: String, icon: String, tint: Color = Theme.accent,
         status: String? = nil, statusTint: Color? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.status = status
        self.statusTint = statusTint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(tint.opacity(0.16)))
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.95))
                Spacer(minLength: 6)
                if let status {
                    Chip(status, tint: statusTint)
                }
            }
            .padding(.bottom, 5)
            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card))
        .glassBorder(radius: Theme.cardRadius)
    }
}

/// One setting: its name, one line on what it does, and its control.
private struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.vertical, 6)
    }
}

/// A setting that is on or off.
private struct ToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        SettingRow(title, detail: detail) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.accent)
        }
    }
}

private struct RowLine: View {
    var body: some View {
        Rectangle()
            .fill(Theme.ink.opacity(0.07))
            .frame(height: 1)
    }
}

/// A labeled text box.
private struct SettingField: View {
    let label: String
    @Binding var text: String
    var secure = false
    var mono = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.55))
            Group {
                if secure {
                    SecureField("", text: $text)
                } else {
                    TextField("", text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: mono ? .monospaced : .default))
            .foregroundStyle(Theme.ink.opacity(0.95))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.ink.opacity(0.07)))
            .glassBorder(radius: 8)
        }
        .padding(.vertical, 4)
    }
}

/// A short explanation under a group of rows.
private struct Note: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.ink.opacity(0.48))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
    }
}

/// A capsule button: filled for the main action, tinted for the rest.
private struct PillButton: View {
    let title: String
    var icon: String?
    var prominent: Bool
    var tint: Color
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    init(_ title: String, icon: String? = nil, prominent: Bool = false, tint: Color = Theme.accent,
         action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.prominent = prominent
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(prominent ? Color.black.opacity(0.82) : tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(prominent ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(tint.opacity(0.14))))
            .overlay(Capsule().strokeBorder(tint.opacity(prominent ? 0 : 0.30), lineWidth: 0.75))
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// A sliding choice between a few options.
struct Segmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Namespace private var space

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let on = option.0 == selection
                Text(option.1)
                    .font(.system(size: 11, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Color.black.opacity(0.82) : Theme.ink.opacity(0.7))
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background {
                        if on {
                            Capsule()
                                .fill(Theme.accentGradient)
                                .matchedGeometryEffect(id: "choice", in: space)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = option.0 }
                    }
            }
        }
        .padding(3)
        .liquidGlass(in: Capsule())
        .fixedSize()
    }
}

// MARK: - Subscriptions

/// The subscription tools: which are on this Mac, which one is in use and
/// the model it is asked for.
private struct SubscriptionSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var agents = CLIAgents.shared

    private var chosen: CLIAgentAdapter? { agents.adapter(settings.cliAgent) }

    /// Opens Terminal to install the tool (when missing) and sign in, then
    /// switches to it once it is there.
    private func setUp(_ adapter: CLIAgentAdapter) {
        agents.setUp(adapter) {
            if settings.cliAgent != adapter.id { settings.cliModel = "" }
            settings.cliAgent = adapter.id
        }
    }

    /// Asks where a tool's program is. In Terminal, `which claude` (or
    /// `codex`, `gemini`) prints the place to pick.
    private func locate(_ adapter: CLIAgentAdapter) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the \(adapter.command) program. In Terminal, `which \(adapter.command)` prints where it is. Press Cmd+Shift+G to type a path."
        panel.prompt = "Use this"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                agents.locate(adapter.id, at: url.path)
                if settings.cliAgent != adapter.id { settings.cliModel = "" }
                settings.cliAgent = adapter.id
            }
        }
    }

    var body: some View {
        SettingsCard("Subscription tools", icon: "person.badge.key",
                     status: agents.checking ? "Looking..." : "\(agents.installed.count) found") {
            ForEach(agents.adapters) { adapter in
                let found = agents.paths[adapter.id] != nil
                let on = settings.cliAgent == adapter.id
                HStack(spacing: 9) {
                    Image(systemName: on ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(on ? Theme.accent : Theme.ink.opacity(0.4))
                    EngineLogo(kind: .subscription, tool: adapter.id, size: 15)
                        .foregroundStyle(Theme.ink.opacity(found ? 0.85 : 0.4))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(adapter.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ink.opacity(found ? 0.95 : 0.5))
                        // Whether it is there and signed in, in plain words.
                        HStack(spacing: 4) {
                            if found, let signed = agents.signedIn[adapter.id] {
                                Circle()
                                    .fill(signed ? Theme.mint : Theme.amber)
                                    .frame(width: 6, height: 6)
                                Text(signed ? "Signed in" : "Not signed in")
                                    .foregroundStyle(signed ? Theme.mint : Theme.amber)
                            } else {
                                Text(found ? "Installed" : "Not installed. Click Set up to install it and sign in.")
                                    .foregroundStyle(Theme.ink.opacity(0.5))
                            }
                        }
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .help(agents.paths[adapter.id] ?? "")
                        // What is left of the plan, when the tool says.
                        if let left = agents.limitsLine(for: adapter.id) {
                            Text(left)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.ink.opacity(0.6))
                                .lineLimit(1)
                                .help(agents.limitsDetail(for: adapter.id) ?? left)
                        }
                    }
                    Spacer(minLength: 0)
                    // Missing: install it and sign in. There: sign in
                    // again, should the sign-in have lapsed.
                    if agents.settingUp == adapter.id {
                        Button("Waiting... Stop") { agents.stopSettingUp() }
                            .font(.system(size: 11))
                    } else if agents.signedIn[adapter.id] != true,
                              adapter.install != nil || adapter.signInCommand != nil {
                        // Once it is signed in the button goes: the label
                        // on the left says so, and that is enough.
                        Button(found ? "Sign in" : "Set up") { setUp(adapter) }
                            .font(.system(size: 11))
                    }
                    // One short message through the tool, as a chat sends
                    // it: the plain way to know it is connected.
                    if found {
                        if agents.trying == adapter.id {
                            LoadingMark(state: .working, size: 16)
                                .frame(width: 26, height: 26)
                        } else {
                            IconButton("arrow.clockwise",
                                       help: "Check the connection: sends one short message through \(adapter.name)") {
                                agents.tryOut(adapter, model: on ? settings.cliModel : "")
                            }
                            .disabled(agents.trying != nil)
                        }
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    // Not found: offer to install it and sign in.
                    guard found else { setUp(adapter); return }
                    if settings.cliAgent != adapter.id { settings.cliModel = "" }
                    settings.cliAgent = adapter.id
                }
                .contextMenu {
                    if found, adapter.signInCommand != nil {
                        Button("Sign in again") { setUp(adapter) }
                    }
                    Button("Choose where \(adapter.name) is...") { locate(adapter) }
                }
                if let result = agents.trials[adapter.id] {
                    Text(result)
                        .font(.system(size: 10.5))
                        .foregroundStyle(result.hasPrefix("Works") ? Theme.mint : Theme.rose)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.leading, 22)
                        .padding(.bottom, 4)
                }
            }
            RowLine().padding(.top, 4)
            // The model the tool is asked for: one it is known to offer,
            // or any other by name.
            SettingRow("Model", detail: "For \(chosen?.name ?? "the tool"). Its own default is whatever your plan gives.") {
                Picker("", selection: $settings.cliModel) {
                    Text("Auto (the tool picks)").tag("")
                    ForEach(agents.models(for: settings.cliAgent).filter { !$0.isEmpty }, id: \.self) { model in
                        Text(agents.title(of: model, for: settings.cliAgent)).tag(model)
                    }
                    if !settings.cliModel.isEmpty, !agents.models(for: settings.cliAgent).contains(settings.cliModel) {
                        Text(ModelName.prettyTool(settings.cliModel)).tag(settings.cliModel)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }
            SettingField(label: "Or type another model's name", text: $settings.cliModel, mono: true)
            HStack(spacing: 8) {
                Button("Look again") {
                    agents.check(again: true)
                    agents.refreshModels()
                }
                Button("Show the adapters file") {
                    NSWorkspace.shared.activateFileViewerSelecting([agents.file])
                }
            }
            .font(.system(size: 11.5))
            .padding(.top, 2)
            if let hint = chosen?.signIn {
                Note(hint)
            }
            Note("Companion runs the tool itself, signed in with your subscription; it never sees the sign-in. The tool may read the chat's repository but not change it: changes are made by Companion's agent, which asks first. Each reply starts the tool, so it is a little slower than an API. Pictures are not sent. Another tool can be added by adding an entry to the adapters file.")
        }
        .onAppear {
            agents.check()
            agents.refreshSignIns()
            agents.refreshLimits()
        }
        // Back from the browser or Terminal: ask again who is signed in.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            agents.refreshSignIns()
        }
    }
}

// MARK: - Engine

private struct EngineSettings: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var app = AppState.shared
    @State private var anthropicKey = Keychain.read("anthropic") ?? ""
    @State private var openAIKey = Keychain.read("openai") ?? ""
    @State private var farhelmKey = Keychain.read("farhelm") ?? ""
    @State private var farhelmModels: [String] = []
    @State private var farhelmModelsStatus: String?

    private func look(_ kind: LLMProviderKind) -> (name: String, place: String, icon: String) {
        switch kind {
        case .farhelm: return ("Farhelm", "On this Mac", "server.rack")
        case .anthropic: return ("Claude", "Anthropic API", "sparkle")
        case .openai: return ("OpenAI", "OpenAI API", "circle.hexagongrid")
        case .ollama: return ("Ollama", "On this Mac", "desktopcomputer")
        case .subscription: return ("Subscriptions", "Claude, ChatGPT, Gemini", "person.badge.key")
        }
    }

    var body: some View {
        SettingsCard("Reply engine", icon: "cpu") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(LLMProviderKind.allCases) { kind in
                    let info = look(kind)
                    let on = settings.provider == kind
                    HStack(spacing: 9) {
                        EngineLogo(kind: kind, size: 15)
                            .foregroundStyle(on ? Theme.accent : Theme.ink.opacity(0.6))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(info.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.ink.opacity(0.95))
                            Text(info.place)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.ink.opacity(0.5))
                        }
                        Spacer(minLength: 0)
                        if on {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.accent)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                        .fill(on ? Theme.accent.opacity(0.14) : Theme.ink.opacity(0.05)))
                    .glassBorder(radius: 10, tint: on ? Theme.accent : nil)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { settings.provider = kind }
                    }
                }
            }
        }

        switch settings.provider {
        case .farhelm:
            SettingsCard("Farhelm connection", icon: "link", status: farhelmModelsStatus) {
                SettingField(label: "Client key", text: $farhelmKey, secure: true)
                    .onChange(of: farhelmKey) { _, value in
                        Keychain.write(value, account: "farhelm")
                    }
                SettingField(label: "Gateway URL", text: $settings.farhelmURL, mono: true)
                RowLine().padding(.top, 4)
                SettingRow("Model", detail: "Auto lets Farhelm choose.") {
                    HStack(spacing: 6) {
                        Picker("", selection: $settings.farhelmModel) {
                            Text("Auto").tag("")
                            if !settings.farhelmModel.isEmpty, !farhelmModels.contains(settings.farhelmModel) {
                                Text(settings.farhelmModel).tag(settings.farhelmModel)
                            }
                            ForEach(farhelmModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 170)
                        PillButton("Refresh", icon: "arrow.clockwise") {
                            Task { await loadFarhelmModels() }
                        }
                    }
                }
                RowLine()
                contextRow
                Note("One-time setup on this Mac: farhelm clients add companion, then restart the runner.")
            }
            .onAppear {
                if !farhelmKey.isEmpty, farhelmModels.isEmpty {
                    Task { await loadFarhelmModels() }
                }
            }
        case .anthropic:
            SettingsCard("Claude connection", icon: "link") {
                SettingField(label: "API key", text: $anthropicKey, secure: true)
                    .onChange(of: anthropicKey) { _, value in
                        Keychain.write(value, account: "anthropic")
                    }
                RowLine().padding(.top, 4)
                SettingRow("Model", detail: "Haiku is fastest for live replies; Sonnet and Opus answer better but slower.") {
                    HStack(spacing: 6) {
                        Picker("", selection: $settings.anthropicModel) {
                            if !app.anthropicModels.contains(settings.anthropicModel) {
                                Text(settings.anthropicModel).tag(settings.anthropicModel)
                            }
                            ForEach(app.anthropicModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 170)
                        PillButton("Refresh", icon: "arrow.clockwise") {
                            app.loadAnthropicModels()
                        }
                    }
                }
                SettingField(label: "Or type a model ID", text: $settings.anthropicModel, mono: true)
                if let status = app.anthropicModelsStatus {
                    Note(status)
                }
                Note("The key is kept in your Keychain. The ANTHROPIC_API_KEY environment variable works too.")
            }
            .onAppear {
                if !anthropicKey.isEmpty {
                    app.loadAnthropicModels()
                }
            }
        case .openai:
            SettingsCard("OpenAI connection", icon: "link") {
                SettingField(label: "API key", text: $openAIKey, secure: true)
                    .onChange(of: openAIKey) { _, value in
                        Keychain.write(value, account: "openai")
                    }
                SettingField(label: "Model", text: $settings.openAIModel, mono: true)
                Note("The key is kept in your Keychain. The OPENAI_API_KEY environment variable works too.")
            }
        case .ollama:
            SettingsCard("Ollama connection", icon: "link") {
                SettingField(label: "Server URL", text: $settings.ollamaURL, mono: true)
                SettingField(label: "Model", text: $settings.ollamaModel, mono: true)
                RowLine().padding(.top, 4)
                contextRow
                Note("Install from ollama.com, then run: ollama pull \(settings.ollamaModel)")
            }
        case .subscription:
            SubscriptionSettings(settings: settings)
        }

        SettingsCard("Effort", icon: "brain", tint: Theme.amber) {
            SettingRow("How hard it thinks",
                       detail: "For what you type, screen answers and the agent. Higher is more careful and slower. Live replies always stay fast.") {
                Picker("", selection: Binding(get: { settings.chosenEffort },
                                              set: { settings.chosenEffort = $0 })) {
                    ForEach([""] + settings.effortLevels, id: \.self) { level in
                        Text(AppSettings.effortLabel(level)).tag(level)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }
            Note("Kept for each model on its own, with that engine's own levels. It can also be set beside the model in the chat box. Auto leaves it to the model; if a model refuses a level, choose Auto.")
        }

        SettingsCard("What the engine is given", icon: "square.stack.3d.up", tint: Theme.violet) {
            Text(ContextBudget.current.summary)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var contextRow: some View {
        SettingRow("Context window", detail: "Match what the model is loaded with; requests are sized to fit.") {
            Picker("", selection: $settings.localContextTokens) {
                ForEach(ContextBudget.localChoices, id: \.self) { tokens in
                    Text("\(tokens / 1000)k tokens").tag(tokens)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    @MainActor
    private func loadFarhelmModels() async {
        farhelmModelsStatus = "Loading…"
        do {
            let models = try await ModelCatalog.openAIStyleModels(base: settings.farhelmURL, bearer: farhelmKey)
            farhelmModels = models
            farhelmModelsStatus = models.isEmpty ? "No models reported" : "\(models.count) models"
        } catch {
            farhelmModelsStatus = "Not reachable"
        }
    }
}

// MARK: - You

private struct YouSettings: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var memory = MemoryStore.shared

    var body: some View {
        SettingsCard("About you", icon: "person.text.rectangle") {
            Text("Who you are, your product, pricing, talking points, the role you are interviewing for. Replies are drafted from this.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            TextEditor(text: $settings.userDetails)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink.opacity(0.95))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 170)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.ink.opacity(0.07)))
                .glassBorder(radius: 9)
            SettingRow("Context folder", detail: "Any .md or .txt files dropped there are included too.") {
                PillButton("Open", icon: "folder") {
                    NSWorkspace.shared.open(ContextStore.shared.contextDir)
                }
            }
            .padding(.top, 4)
        }

        SettingsCard("Memory", icon: "brain.head.profile", tint: Theme.mint,
                     status: memory.items.isEmpty ? nil : "\(memory.items.count) remembered",
                     statusTint: Theme.mint) {
            ToggleRow("Remember across conversations",
                      detail: "Key facts from each write-up (who, what was asked, commitments, dates) are kept on this Mac and given to later conversations when relevant.",
                      isOn: $settings.rememberAcross)
            if memory.items.isEmpty {
                RowLine()
                Text("Nothing remembered yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                    .padding(.top, 10)
            } else {
                ForEach(memory.items.reversed()) { item in
                    RowLine()
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.ink.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(item.title) · \(item.date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.ink.opacity(0.45))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        IconButton("trash", help: "Forget this") {
                            memory.delete(item.id)
                        }
                    }
                    .padding(.vertical, 7)
                }
                RowLine()
                HStack {
                    Spacer()
                    PillButton("Forget everything", icon: "trash", tint: Theme.rose) {
                        memory.clear()
                    }
                }
                .padding(.top, 10)
            }
        }
    }
}

// MARK: - Listening

private struct ListeningSettings: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var app = AppState.shared
    @State private var showVoiceSetup = false

    var body: some View {
        SettingsCard("Sources", icon: "mic") {
            ToggleRow("Microphone", detail: "You, and anyone in the room.", isOn: $settings.captureMic)
            RowLine()
            ToggleRow("System audio",
                      detail: "The other side of Zoom, Meet or any app. Needs Screen Recording permission.",
                      isOn: $settings.captureSystemAudio)
            RowLine()
            ToggleRow("English only", detail: "More accurate when the whole conversation is in English.",
                      isOn: $settings.asrEnglishOnly)
            RowLine()
            SettingRow("Mic sensitivity", detail: "Raise it if the level bars barely move when others talk.") {
                Segmented(options: MicSensitivity.allCases.map { ($0, $0.label) },
                          selection: $settings.micSensitivity)
            }
            Note("On calls, wear headphones so the other side does not leak into the mic.")
        }

        SettingsCard("Who is speaking", icon: "person.2.wave.2", tint: Theme.mint,
                     status: app.voiceEnrolled ? "Voice set up" : "Voice not set up",
                     statusTint: app.voiceEnrolled ? Theme.mint : Theme.amber) {
            ToggleRow("Separate voices on the mic",
                      detail: "Your voice stays You; every other voice becomes P1, P2 and gets reply suggestions.",
                      isOn: $settings.separateMicVoices)
            RowLine()
            ToggleRow("Keep correcting while listening",
                      detail: "A more accurate pass re-checks who said what every so often and fixes labels in place.",
                      isOn: $settings.autoVoiceRecheck)
                .disabled(!settings.separateMicVoices)
                .opacity(settings.separateMicVoices ? 1 : 0.5)
            RowLine()
            SettingRow("Your voice",
                       detail: app.voiceEnrolled
                           ? "Set up. Redo it if you are often taken for someone else."
                           : "Needed once: you read five short sentences aloud.") {
                PillButton(app.voiceEnrolled ? "Redo" : "Set up", icon: "waveform", prominent: !app.voiceEnrolled) {
                    showVoiceSetup = true
                    app.enrollVoice()
                }
            }
            RowLine()
            SettingRow("Other voices",
                       detail: app.referenceImport ?? (app.referenceVoices > 0
                           ? "\(app.referenceVoices) learned from public recordings."
                           : "Optional: a folder of other people's recordings, such as LibriSpeech.")) {
                PillButton("Add", icon: "plus") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.prompt = "Use This Folder"
                    panel.message = "Choose a folder of recordings of other people, such as LibriSpeech."
                    if panel.runModal() == .OK, let folder = panel.url {
                        app.importReferenceVoices(from: folder)
                    }
                }
                .disabled(app.referenceImport != nil)
            }
            Note("Click a speaker badge in the conversation to fix it; every fix teaches the voice check. Mic audio stays in memory for up to 30 minutes and is gone when the app quits.")
        }
        .sheet(isPresented: $showVoiceSetup) {
            VoiceSetupSheet(isPresented: $showVoiceSetup)
        }
    }
}

// MARK: - Replies

private struct RepliesSettings: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        SettingsCard("Suggestions", icon: "text.bubble") {
            ToggleRow("Suggest a reply automatically", detail: "After the other person finishes speaking.",
                      isOn: $settings.autoSuggest)
            RowLine()
            ToggleRow("Only for questions", detail: "Skip short remarks that are not questions, for fewer replies.",
                      isOn: $settings.replyToQuestionsOnly)
                .disabled(!settings.autoSuggest)
                .opacity(settings.autoSuggest ? 1 : 0.5)
        }

        SettingsCard("Transcript and notes", icon: "doc.text", tint: Theme.violet) {
            ToggleRow("Polish the transcript", detail: "Fix misheard words and tidy the wording.",
                      isOn: $settings.polishTranscript)
            RowLine()
            ToggleRow("Keep running notes", detail: "So long conversations stay in context.",
                      isOn: $settings.keepNotes)
        }
    }
}

// MARK: - Screen

private struct ScreenSettings: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        SettingsCard("Reading the screen", icon: "text.viewfinder", tint: Theme.violet) {
            ToggleRow("Watch the screen",
                      detail: "Answers new questions that appear, without being asked.",
                      isOn: $settings.autoScreenWatch)
            RowLine()
            SettingRow("Monitor", detail: "Automatic uses the one your pointer is on.") {
                Picker("", selection: $settings.screenDisplayID) {
                    Text("Automatic").tag(0)
                    ForEach(ScreenReader.screens()) { screen in
                        Text(screen.name).tag(screen.id)
                    }
                    // A saved monitor that is not connected right now.
                    if settings.screenDisplayID != 0,
                       !ScreenReader.screens().contains(where: { $0.id == settings.screenDisplayID }) {
                        Text("Disconnected monitor").tag(settings.screenDisplayID)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 190)
            }
            RowLine()
            SettingRow("Check every", detail: "It only reads when something changed and has settled.") {
                Segmented(options: [2, 3, 5, 10].map { ($0, "\($0)s") },
                          selection: $settings.screenWatchInterval)
            }
            Note("After a minute without change it slows to every 10 seconds.")
        }

        SettingsCard("Privacy", icon: "eye.slash", tint: Theme.mint) {
            ToggleRow("Hide from screen sharing", detail: "Companion stays out of shared screens and recordings.",
                      isOn: $settings.hideFromScreenShare)
            RowLine()
            ToggleRow("Use my location",
                      detail: "For answers that depend on where you are, such as the weather here. macOS asks once. It is used for the answer and not stored.",
                      isOn: $settings.useLocation)
            LocationNote()
        }
    }
}

/// Under "Use my location": the place found, or why there is none.
private struct LocationNote: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var location = LocationService.shared

    var body: some View {
        Group {
            if settings.useLocation {
                if !location.problem.isEmpty {
                    Note(location.problem)
                } else if let place = location.place {
                    Note("Now: \(place.label).")
                } else {
                    Note("Finding where this Mac is.")
                }
            }
        }
        .onAppear { location.refresh() }
        .onChange(of: settings.useLocation) { _, on in
            if on { location.refresh() }
        }
    }
}

// MARK: - Agent

private struct AgentSettings: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var allowed = DeviceControl.shared.allowed

    var body: some View {
        SettingsCard("Access", icon: "lock.shield",
                     status: allowed ? "Accessibility granted" : "Accessibility needed",
                     statusTint: allowed ? Theme.mint : Theme.amber) {
            if !allowed {
                SettingRow("Accessibility permission", detail: "Needed to click and type in other apps.") {
                    PillButton("Allow", prominent: true) {
                        DeviceControl.shared.requestAccess()
                        allowed = DeviceControl.shared.allowed
                    }
                }
                RowLine()
            }
            HStack(alignment: .bottom, spacing: 8) {
                SettingField(label: "Working folder (where shell commands start)",
                             text: $settings.agentDirectory, mono: true)
                PillButton("Choose", icon: "folder") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        settings.agentDirectory = url.path
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .onAppear { allowed = DeviceControl.shared.allowed }

        SettingsCard("Approvals", icon: "checkmark.shield", tint: Theme.mint) {
            SettingRow("New chats start in",
                       detail: "How much the agent does without asking. Each chat can be given its own mode from the button beside the model in the chat box.") {
                Picker("", selection: $settings.agentAccess) {
                    ForEach(AgentAccess.allCases) { access in
                        Text(access.title).tag(access.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }
            Note((AgentAccess(rawValue: settings.agentAccess) ?? .manual).detail)
            RowLine()
            SettingRow("Tasks at once",
                       detail: "Each chat can run its own task. Shell, file and web work run side by side; tasks that click or type take turns with the mouse and keyboard.") {
                Picker("", selection: $settings.agentMaxTasks) {
                    ForEach([1, 2, 3, 5, 8], id: \.self) { count in
                        Text(count == 1 ? "1 task" : "\(count) tasks").tag(count)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }
            RowLine()
            ToggleRow("Run read-only commands without asking",
                      detail: "ls, cat, git status and the like. In Manual, anything that writes, deletes, sends or types asks.",
                      isOn: $settings.agentAutoApproveReads)
            RowLine()
            ToggleRow("Commit changes to git",
                      detail: "Where a folder is a git repository, files the agent changes (and files you save or undo in the workspace) are committed on the current branch as \"Companion: ...\". Nothing is pushed. Off keeps Companion's own history only.",
                      isOn: $settings.historyGit)
            RowLine()
            ToggleRow("Show the orbit while it works",
                      detail: "An orbit appears on screen where the agent clicks, types or opens something, and rides along with text as it types.",
                      isOn: $settings.agentOrbit)
            RowLine()
            ToggleRow("Voice commands",
                      detail: "Say \"Companion, ...\" to give a task, and \"allow\" or \"deny\" to answer.",
                      isOn: $settings.voiceCommands)
            if !settings.agentAllowed.isEmpty {
                RowLine()
                Text("Always allowed")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.55))
                    .padding(.top, 9)
                    .padding(.bottom, 2)
                ForEach(settings.agentAllowed, id: \.self) { name in
                    HStack {
                        Text(name)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.ink.opacity(0.9))
                        Spacer()
                        IconButton("minus.circle", help: "Ask about this again") {
                            settings.agentAllowed.removeAll { $0 == name }
                        }
                    }
                }
            }
        }

        SettingsCard("How it works", icon: "info.circle", tint: Theme.violet) {
            Text("There is one chat box. Ask a question and it is answered; tell Companion to do something and the agent takes it on. It proposes each step (a shell command, opening an app, a click, typing), you choose Allow, Always allow or Deny, it runs, and it checks the result before the next step.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Keys

/// Every global shortcut in one place, each one changeable: click it, then
/// press the new keys.
private struct ShortcutSettings: View {
    @ObservedObject var keys = Shortcuts.shared
    @State private var recording: ShortcutAction?
    @State private var message: String?
    @State private var monitor: Any?

    var body: some View {
        SettingsCard("Shortcuts", icon: "keyboard", tint: Theme.amber) {
            ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                if index > 0 {
                    RowLine()
                }
                SettingRow(action.title, detail: action.detail) {
                    HStack(spacing: 4) {
                        if keys.isChanged(action), recording != action {
                            IconButton("arrow.counterclockwise",
                                       help: "Back to \(action.standard.display)") {
                                keys.reset(action)
                            }
                        }
                        Button {
                            recording == action ? stop() : start(action)
                        } label: {
                            Text(recording == action ? "Press keys…" : keys.label(action))
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(recording == action ? Theme.accent : Theme.ink.opacity(0.9))
                                .frame(minWidth: 62)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                                    .fill((recording == action ? Theme.accent : Theme.ink).opacity(recording == action ? 0.16 : 0.08)))
                                .glassBorder(radius: 7, tint: recording == action ? Theme.accent : nil)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Click, then press the new keys. Esc cancels.")
                    }
                }
            }
            if let message {
                Text(message)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            HStack(alignment: .center) {
                Note("Click a shortcut, then press the new keys. A shortcut needs ⌘, ⌃ or ⌥. Esc cancels.")
                Spacer(minLength: 8)
                PillButton("Reset all", icon: "arrow.counterclockwise") {
                    stop()
                    keys.resetAll()
                    message = nil
                }
            }
        }
        .onDisappear { stop() }
    }

    /// Listens for the next key press in the panel. While it does, none of
    /// the global shortcuts fire, so pressing one that is in use records it
    /// instead of running it.
    private func start(_ action: ShortcutAction) {
        stop()
        recording = action
        message = nil
        keys.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event, for: action)
            return nil
        }
    }

    private func handle(_ event: NSEvent, for action: ShortcutAction) {
        // Escape leaves things as they were.
        if event.keyCode == 53 {
            stop()
            return
        }
        guard let combo = KeyCombo(event: event) else {
            message = "Hold ⌘, ⌃ or ⌥ together with the key."
            return
        }
        if let taken = keys.set(combo, for: action) {
            message = "\(combo.display) is already used for \"\(taken.title)\". Press another, or Esc."
            return
        }
        message = nil
        stop()
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        guard recording != nil else { return }
        recording = nil
        keys.registerAll()
    }
}

// MARK: - Usage

/// What Companion has used and what that costs: in total, by what it was
/// for, and by model. The figures to price a plan on, and to see where an
/// optimisation would pay.
private struct UsageSettings: View {
    @ObservedObject var usage = UsageStore.shared
    @ObservedObject var prices = PriceBook.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var period = 7
    @State private var planPrice = 20.0
    @State private var planTokens = 5.0

    private var shown: [UsageRecord] {
        usage.records(since: period == 0 ? nil : Calendar.current.date(byAdding: .day, value: -period, to: Date()))
    }

    private struct Line: Identifiable {
        let id: String
        var requests = 0
        var input = 0
        var output = 0
        var cost = 0.0
        var seconds = 0.0
        var engine = ""
        var model = ""
    }

    private func lines(by key: (UsageRecord) -> String) -> [Line] {
        var table: [String: Line] = [:]
        for record in shown {
            let name = key(record)
            var line = table[name] ?? Line(id: name)
            line.requests += 1
            line.input += record.input + record.cacheRead + record.cacheWrite
            line.output += record.output
            line.cost += prices.cost(of: record)
            line.seconds += record.seconds
            line.engine = record.engine
            line.model = record.model
            table[name] = line
        }
        return table.values.sorted { ($0.cost, $0.input + $0.output) > ($1.cost, $1.input + $1.output) }
    }

    private var totalCost: Double { usage.cost(of: shown) }
    private var totalTokens: Int { shown.reduce(0) { $0 + $1.tokens } }
    /// Dollars per million tokens across everything in the period.
    private var blended: Double { totalTokens > 0 ? totalCost / Double(totalTokens) * 1_000_000 : 0 }

    /// This month's spend against the budget, and where it is heading.
    @ViewBuilder
    private var budgetCard: some View {
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let spent = usage.cost(of: usage.records(since: start))
        let day = Double(calendar.component(.day, from: now))
        let days = Double(calendar.range(of: .day, in: .month, for: now)?.count ?? 30)
        let projected = spent / max(day, 1) * days
        let budget = settings.monthlyBudget
        let share = budget > 0 ? min(spent / budget, 1) : 0
        let color = share < 0.6 ? Theme.accent : (share < 0.9 ? Theme.amber : Theme.rose)
        SettingsCard("This month", icon: "gauge.with.dots.needle.33percent") {
            if budget > 0 {
                Text(projected <= budget
                     ? "On track. At this pace you will spend about \(Money.text(projected)) of your \(Money.text(budget)) by the end of the month."
                     : "Over pace. At this rate you will spend about \(Money.text(projected)), above your \(Money.text(budget)) budget.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(projected <= budget ? Theme.ink.opacity(0.92) : Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
                HStack(spacing: 10) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.ink.opacity(0.10))
                            Capsule().fill(color)
                                .frame(width: max(4, geometry.size.width * share))
                        }
                    }
                    .frame(height: 4)
                    Text("\(Int((share * 100).rounded()))% used")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink.opacity(0.6))
                        .fixedSize()
                }
                Note("\(Money.text(spent)) spent since the 1st. Resets on the 1st of next month.")
                RowLine().padding(.top, 8)
            }
            SettingRow("Monthly budget",
                       detail: budget > 0 ? "Shown against what you have spent this month." : "Set one to see how the month is going. Nothing is cut off when you pass it.") {
                NumberField(value: $settings.monthlyBudget, prefix: "$")
            }
        }
    }

    var body: some View {
        budgetCard

        SettingsCard("Limits for API models", icon: "timer", tint: Theme.amber,
                     status: settings.apiStepMinutes == 0 && settings.agentStepBudget == 0 ? "Off" : nil) {
            SettingRow("One step of an API model",
                       detail: "When Claude or OpenAI through an API key takes this long over one step, the agent stops waiting, so a stuck call does not keep running up cost. Local models (Ollama, Farhelm) and subscriptions have no limit; Stop always works.") {
                Picker("", selection: $settings.apiStepMinutes) {
                    Text("Off").tag(0)
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            RowLine()
            SettingRow("Steps before it asks to carry on",
                       detail: "On a long task with Claude or OpenAI through an API key, the agent stops after this many steps and asks whether to go on, so cost never runs away. A yes gives it as many again. Subscriptions and local models never stop to ask.") {
                Picker("", selection: $settings.agentStepBudget) {
                    Text("Never").tag(0)
                    ForEach([50, 100, 250, 500], id: \.self) { Text("\($0) steps").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }

        SettingsCard("Used", icon: "chart.bar", tint: Theme.mint,
                     status: shown.isEmpty ? nil : "\(shown.count) requests", statusTint: Theme.mint) {
            HStack {
                Segmented(options: [(1, "Today"), (7, "7 days"), (30, "30 days"), (0, "All")], selection: $period)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 8)
            if shown.isEmpty {
                Note("Nothing used in this period yet. Every request is counted from now on.")
            } else {
                HStack(spacing: 8) {
                    figure(Money.text(totalCost), "cost")
                    figure(ContextUse.short(shown.reduce(0) { $0 + $1.input + $1.cacheRead + $1.cacheWrite }), "tokens in")
                    figure(ContextUse.short(shown.reduce(0) { $0 + $1.output }), "tokens out")
                    figure(Money.text(blended), "per million")
                }
                let cached = shown.reduce(0) { $0 + $1.cacheRead }
                let estimated = shown.filter { !$0.exact }.count
                Note([
                    cached > 0 ? "\(ContextUse.short(cached)) of the input came from the engine's cache, at a fraction of the price." : nil,
                    estimated > 0 ? "\(estimated) of \(shown.count) requests are estimated from text length, because the engine did not report a count." : nil
                ].compactMap { $0 }.joined(separator: " "))
            }
        }

        if !shown.isEmpty {
            SettingsCard("By purpose", icon: "list.bullet.rectangle", tint: Theme.violet) {
                table(lines(by: { $0.purpose }))
                Note("Where the money goes. The top rows are where a smaller model, a shorter prompt or fewer calls would save the most.")
            }

            SettingsCard("By model", icon: "cpu") {
                table(lines(by: { "\($0.engine)|\($0.model)" }), showsModel: true)
            }

            SettingsCard("Prices", icon: "dollarsign.circle", tint: Theme.amber) {
                Text("Dollars per million tokens. Claude's list prices are filled in; set your own for anything else. For a local engine, enter what it costs you to run.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                ForEach(lines(by: { "\($0.engine)|\($0.model)" })) { line in
                    PriceRow(engine: line.engine, model: line.model)
                }
                Note("List prices were read on 11 Nov 2026 and change over time. Check them before relying on a figure.")
            }

            SettingsCard("Plan check", icon: "function", tint: Theme.mint) {
                SettingRow("Plan price", detail: "What a customer pays per month.") {
                    NumberField(value: $planPrice, prefix: "$")
                }
                RowLine()
                SettingRow("Tokens included", detail: "Millions of tokens per month, in and out together.") {
                    NumberField(value: $planTokens, suffix: "M")
                }
                RowLine()
                let cost = planTokens * blended
                let margin = planPrice - cost
                HStack(spacing: 8) {
                    figure(Money.text(cost), "your cost")
                    figure(Money.text(margin), "left per customer")
                    figure(planPrice > 0 ? "\(Int((margin / planPrice * 100).rounded()))%" : "0%", "margin")
                }
                .padding(.top, 8)
                Note("Uses your measured rate of \(Money.text(blended)) per million tokens over this period, assuming the customer uses the whole allowance with the same mix of work. A local engine with no price set counts as free.")
            }

            SettingsCard("Export", icon: "square.and.arrow.up") {
                SettingRow("Every request as a spreadsheet",
                           detail: "Date, model, purpose, tokens, time and cost, one row per request, for the last 90 days.") {
                    PillButton("Save CSV", icon: "arrow.down.doc") {
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = "companion-usage.csv"
                        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
                        if panel.runModal() == .OK, let url = panel.url {
                            try? usage.csv().write(to: url, atomically: true, encoding: .utf8)
                        }
                    }
                }
            }
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.ink.opacity(0.96))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.ink.opacity(0.5))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.ink.opacity(0.06)))
    }

    /// Rows of usage with a bar showing each one's share of the cost (or of
    /// the tokens, when nothing has a price).
    private func table(_ rows: [Line], showsModel: Bool = false) -> some View {
        let totalCost = rows.reduce(0) { $0 + $1.cost }
        let totalTokens = rows.reduce(0) { $0 + $1.input + $1.output }
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let share = totalCost > 0
                    ? row.cost / totalCost
                    : (totalTokens > 0 ? Double(row.input + row.output) / Double(totalTokens) : 0)
                if index > 0 {
                    RowLine()
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(showsModel ? "\(LLMProviderKind(rawValue: row.engine)?.shortName ?? row.engine) \(ModelName.pretty(row.model))" : row.id)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.ink.opacity(0.92))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Money.text(row.cost))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink.opacity(0.92))
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.ink.opacity(0.08))
                            Capsule().fill(Theme.accent.opacity(0.8))
                                .frame(width: max(3, geometry.size.width * share))
                        }
                    }
                    .frame(height: 3)
                    Text("\(row.requests) requests · \(ContextUse.short(row.input)) in · \(ContextUse.short(row.output)) out · \(String(format: "%.1f", row.seconds / Double(max(row.requests, 1)))) s each")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink.opacity(0.48))
                        .lineLimit(1)
                }
                .padding(.vertical, 6)
            }
        }
    }
}

/// A model's price, editable: dollars per million tokens in and out.
private struct PriceRow: View {
    let engine: String
    let model: String
    @ObservedObject var prices = PriceBook.shared

    private func binding(_ path: WritableKeyPath<Price, Double>) -> Binding<Double> {
        Binding(get: { prices.price(engine: engine, model: model)[keyPath: path] },
                set: { value in
                    var price = prices.price(engine: engine, model: model)
                    price[keyPath: path] = max(value, 0)
                    prices.set(price, engine: engine, model: model)
                })
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(LLMProviderKind(rawValue: engine)?.shortName ?? engine) \(ModelName.pretty(model))")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 4)
            NumberField(value: binding(\.input), prefix: "in $")
            NumberField(value: binding(\.output), prefix: "out $")
        }
        .padding(.vertical, 3)
    }
}

/// A small box for a number.
private struct NumberField: View {
    @Binding var value: Double
    var prefix = ""
    var suffix = ""

    var body: some View {
        HStack(spacing: 3) {
            if !prefix.isEmpty {
                Text(prefix)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.5))
            }
            TextField("0", value: $value, format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Theme.ink.opacity(0.95))
                .frame(width: 48)
            if !suffix.isEmpty {
                Text(suffix)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.5))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.ink.opacity(0.07)))
        .glassBorder(radius: 7)
    }
}

// MARK: - Look

private struct LookSettings: View {
    /// The agent's work shown open in replies, not folded to a line.
    @AppStorage("workAlwaysOpen") private var workAlwaysOpen = false
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        SettingsCard("Appearance", icon: "paintbrush") {
            SettingRow("Theme") {
                Segmented(options: [("dark", "Dark"), ("light", "Light"), ("system", "System")],
                          selection: $settings.appearance)
            }
        }

        SettingsCard("Size", icon: "textformat.size", tint: Theme.amber) {
            SettingRow("Chat text", detail: "The messages, replies and the agent's work list. Also from Aa over the conversation.") {
                HStack(spacing: 6) {
                    IconButton("minus", help: "Smaller") { settings.chatText(-1) }
                    Text("\(Int((settings.chatTextScale / AppSettings.chatTextDefault * 100).rounded()))%")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink.opacity(0.9))
                        .frame(width: 44)
                    IconButton("plus", help: "Larger") { settings.chatText(1) }
                    PillButton("Reset", icon: "arrow.counterclockwise") { settings.chatText(0) }
                }
            }
            RowLine()
            ToggleRow("Keep the agent's work open",
                      detail: "Each step on a rail with what went in and came out, in every reply. Off, the work folds to one line once the agent is done; a click opens it.",
                      isOn: $workAlwaysOpen)
        }

        LookColorCard()
        LookGlassCard()
        SavedLooksCard()

        // Where Companion shows up outside its panel. Both are off to begin
        // with, so the things a menu would hold also live here.
        SettingsCard("App", icon: "macwindow", tint: Theme.violet) {
            ToggleRow("Show in menu bar", detail: "An icon with a short menu: show or hide the panel, new conversation, settings, quit. Off, Companion shows no menus at the top of the screen either.",
                      isOn: $settings.showInMenuBar)
            RowLine()
            ToggleRow("Show in Dock", detail: "An icon in the Dock. Click it to bring the panel back.",
                      isOn: $settings.showInDock)
            RowLine()
            ToggleRow("Keep on top", detail: "The panel floats above every other window. Off, it acts like an ordinary window: other apps can cover it, and clicking it brings it forward.",
                      isOn: $settings.keepOnTop)
            RowLine()
            ToggleRow("Show on all desktops", detail: "The panel follows you to every desktop and over full-screen apps. Off, it stays on the desktop it is on.",
                      isOn: $settings.onAllDesktops)
            RowLine()
            SettingRow("Panel position", detail: "Puts the panel back where it started, if it ended up off screen.") {
                PillButton("Reset", icon: "arrow.counterclockwise") {
                    AppState.shared.overlay?.resetPositions()
                }
            }
            RowLine()
            SettingRow("Quit Companion", detail: "Stops listening and closes the app. ⌘Q does the same while the panel is in use; it asks once if Companion is busy.") {
                PillButton("Quit", icon: "power", tint: Theme.rose) {
                    AppState.shared.requestQuit()
                }
            }
            Note("\(Shortcuts.shared.label(.panel)) shows and hides the panel from anywhere; opening Companion again also brings it back.")
        }
    }
}

// MARK: Look: colors, glass, saved looks

/// The panel's two colors: a ready-made pair, or the user's own.
private struct LookColorCard: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var primaryText = LookStore.current.primary
    @State private var secondaryText = LookStore.current.secondary
    @State private var settle: Task<Void, Never>?

    var body: some View {
        SettingsCard("Color", icon: "paintpalette", tint: Theme.accent) {
            SettingRow("Shade", detail: "A ready-made pair of colors.") {
                HStack(spacing: 7) {
                    ForEach(LookPreset.all) { preset in
                        let on = settings.look.preset == preset.id
                        Button {
                            var look = settings.look
                            look.preset = preset.id
                            look.primary = preset.primary
                            look.secondary = preset.secondary
                            apply(look)
                        } label: {
                            Circle()
                                .fill(LinearGradient(colors: [Hex.color(preset.primary), Hex.color(preset.secondary)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(Theme.ink.opacity(on ? 0.95 : 0.18), lineWidth: on ? 2 : 1))
                                .padding(2)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(preset.name)
                    }
                }
            }
            RowLine()
            SettingRow("Your own", detail: "Two colors: the main one, and its partner in gradients and glows. Pick, or type a code like #7FB2FF.") {
                VStack(alignment: .trailing, spacing: 6) {
                    well("Main", text: $primaryText, keyPath: \.primary)
                    well("Partner", text: $secondaryText, keyPath: \.secondary)
                }
            }
            Note(settings.look.preset == "custom"
                 ? "Your colors are fitted to the glass so text stays readable: lightened on dark, deepened on light."
                 : "Choosing your own colors switches to a custom look.")
        }
    }

    /// One color: a well to pick with, and its code to read or type.
    private func well(_ name: String, text: Binding<String>, keyPath: WritableKeyPath<Look, String>) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.6))
            ColorPicker("", selection: Binding(
                get: { Hex.color(settings.look[keyPath: keyPath]) },
                set: { color in
                    let code = Hex.string(color)
                    guard code != settings.look[keyPath: keyPath] else { return }
                    var look = settings.look
                    look[keyPath: keyPath] = code
                    look.preset = "custom"
                    settings.look = look
                    text.wrappedValue = code
                    // Colors are drawn everywhere once the choosing pauses.
                    settle?.cancel()
                    settle = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        if !Task.isCancelled { settings.redrawLook() }
                    }
                }), supportsOpacity: false)
                .labelsHidden()
            TextField("#RRGGBB", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.ink.opacity(0.92))
                .frame(width: 70)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.ink.opacity(0.07)))
                .onSubmit {
                    guard let code = Hex.normalized(text.wrappedValue) else {
                        text.wrappedValue = settings.look[keyPath: keyPath]
                        return
                    }
                    var look = settings.look
                    look[keyPath: keyPath] = code
                    look.preset = "custom"
                    apply(look)
                }
        }
    }

    private func apply(_ look: Look) {
        settings.look = look
        primaryText = look.primary
        secondaryText = look.secondary
        settings.redrawLook()
    }
}

/// How see-through and how blurred the panel is: as a whole, or part by part.
private struct LookGlassCard: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        SettingsCard("Glass", icon: "square.on.square.dashed", tint: Theme.violet) {
            group("Surfaces with content",
                  detail: "Headers, cards, lists and the ask bar: anything with text or icons on it.",
                  \.content)
            group("Empty surfaces",
                  detail: "The panel's base behind everything, where nothing sits.",
                  \.empty)
            RowLine()
            SettingRow("Bubbles", detail: "How solid the bubbles around what was said are.") {
                slider(Binding(get: { settings.look.bubble },
                               set: { settings.look.bubble = $0 }), label: { "\(Int($0 * 100))%" })
            }
            RowLine()
            SettingRow("Start over", detail: "Puts the glass back as it came. Colors are kept.") {
                PillButton("Reset", icon: "arrow.counterclockwise") {
                    var look = settings.look
                    let usual = Look.usual
                    look.linked = usual.linked
                    look.all = usual.all
                    look.top = usual.top
                    look.center = usual.center
                    look.bottom = usual.bottom
                    look.bubble = usual.bubble
                    look.content = usual.content
                    look.empty = usual.empty
                    settings.look = look
                }
            }
            Note("Text stays readable at any setting: the panel never goes fully clear, and the light theme keeps more of its white than the dark theme keeps of its black, because dark text is lost over a picture sooner. Blur has five steps, because macOS offers set strengths and not a dial.")
        }
    }

    @ViewBuilder
    private func group(_ name: String, detail: String, _ keyPath: WritableKeyPath<Look, ZoneStyle>) -> some View {
        RowLine()
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.9))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        SettingRow("Transparency", detail: "Further right lets more of the desktop through.") {
            slider(Binding(get: { 1 - settings.look[keyPath: keyPath].dim },
                           set: { settings.look[keyPath: keyPath].dim = 1 - $0 }),
                   label: { "\(Int($0 * 100))%" })
        }
        SettingRow("Blur", detail: "Off, three steps, or the most.") {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { Double(settings.look[keyPath: keyPath].blur) },
                                      set: { settings.look[keyPath: keyPath].blur = Int($0.rounded()) }),
                       in: 0...4, step: 1)
                    .tint(Theme.accent)
                    .controlSize(.small)
                    .frame(width: 130)
                Text(["Off", "1", "2", "3", "Max"][min(4, max(0, settings.look[keyPath: keyPath].blur))])
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink.opacity(0.55))
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }

    private func slider(_ value: Binding<Double>, label: @escaping (Double) -> String) -> some View {
        HStack(spacing: 8) {
            Slider(value: value, in: 0...1)
                .tint(Theme.accent)
                .controlSize(.small)
                .frame(width: 130)
            Text(label(value.wrappedValue))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Theme.ink.opacity(0.55))
                .frame(width: 34, alignment: .trailing)
        }
    }
}

/// Looks the user named and kept, to switch between.
private struct SavedLooksCard: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var saved = LookStore.saved
    @State private var name = ""

    var body: some View {
        SettingsCard("Saved looks", icon: "square.stack", tint: Theme.mint) {
            SettingRow("Keep this look", detail: "Colors and glass together, under a name.") {
                HStack(spacing: 6) {
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink.opacity(0.92))
                        .frame(width: 110)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.ink.opacity(0.07)))
                        .onSubmit(keep)
                    PillButton("Save", icon: "plus", action: keep)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            ForEach(saved) { item in
                RowLine()
                HStack(spacing: 8) {
                    Circle()
                        .fill(LinearGradient(colors: [Hex.color(item.look.primary), Hex.color(item.look.secondary)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 16, height: 16)
                    Text(item.name)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink.opacity(0.9))
                        .lineLimit(1)
                    if item.look == settings.look {
                        Text("In use")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.mint)
                    }
                    Spacer(minLength: 6)
                    PillButton("Use", icon: "checkmark") {
                        settings.look = item.look
                        settings.redrawLook()
                    }
                    IconButton("trash", help: "Delete this look") {
                        saved.removeAll { $0.id == item.id }
                        LookStore.saved = saved
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func keep() {
        let title = name.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        // The same name again replaces that look.
        saved.removeAll { $0.name.caseInsensitiveCompare(title) == .orderedSame }
        saved.append(SavedLook(name: title, look: settings.look))
        LookStore.saved = saved
        name = ""
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
                    LoadingMark(state: .working, size: 16)
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

/// The Remote section: turn the phone session on, reach it from anywhere
/// through the relay, and show the link and a QR code to pair with.
private struct RemoteSettings: View {
    @ObservedObject var server = RemoteServer.shared
    @ObservedObject var relay = RemoteRelay.shared
    @State private var on = RemoteServer.shared.enabled
    @State private var relayAddress = RemoteRelay.shared.address

    var body: some View {
        SettingsCard("Remote session", icon: "iphone",
                     status: server.running ? "On" : "Off",
                     statusTint: server.running ? Theme.mint : nil) {
            ToggleRow("Let the Companion app connect",
                      detail: "The Companion app on your iPhone, iPad and Apple Watch can follow your chats, send messages, answer the agent and stop it. Approving what the agent does stays on this Mac.",
                      isOn: Binding(get: { on }, set: { value in
                          on = value
                          server.enabled = value
                      }))

            if server.running {
                RowLine()
                ToggleRow("Reach this Mac from anywhere",
                          detail: "Away from this Wi-Fi, the app reaches this Mac through your relay. What passes through is sealed with a key that only travels in the pairing code, so the relay cannot read it. Pair again after turning this on.",
                          isOn: Binding(get: { relay.enabled }, set: { relay.enabled = $0 }))
                if relay.enabled {
                    HStack(alignment: .bottom, spacing: 8) {
                        SettingField(label: "Relay", text: $relayAddress, mono: true)
                            .onSubmit { relay.address = relayAddress }
                        if relayAddress.trimmingCharacters(in: .whitespacesAndNewlines) != relay.address {
                            PillButton("Use") { relay.address = relayAddress }
                                .padding(.bottom, 4)
                        }
                    }
                    Text(relayLine.text)
                        .font(.system(size: 10.5))
                        .foregroundStyle(relayLine.tint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                RowLine()
                if let link = server.appLink {
                    SettingRow("Pair the app",
                               detail: "In the Companion app, tap Pair and scan this code. On the same Wi-Fi the app also finds this Mac by itself.") {
                        EmptyView()
                    }
                    HStack(alignment: .top, spacing: 14) {
                        #if canImport(AppKit)
                        if let qr = RemoteServer.qrImage(for: link, size: 170) {
                            Image(nsImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 140, height: 140)
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).fill(.white))
                        }
                        #endif
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(server.hosts, id: \.self) { host in
                                Text("\(host):\(server.port)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.ink.opacity(0.85))
                                    .textSelection(.enabled)
                            }
                            Text(awayNote)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.ink.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                            PillButton("New code", icon: "arrow.triangle.2.circlepath") {
                                server.newCode()
                            }
                            .help("Cut off every device that has the current code; each has to pair again.")
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                } else {
                    SettingRow("Address",
                               detail: "Join this Mac to Wi-Fi, or turn on Reach this Mac from anywhere, to get somewhere the app can reach.") {
                        EmptyView()
                    }
                }
            }

            if let error = server.lastError {
                RowLine()
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.rose)
            }
        }
    }

    /// How the relay is doing, in a line.
    private var relayLine: (text: String, tint: Color) {
        switch relay.status {
        case .connected:
            let host = relay.relayURL?.host ?? "the relay"
            return (relay.listening ? "Connected to \(host). The app is following through it." : "Connected to \(host).",
                    Theme.mint)
        case .connecting:
            return ("Connecting to the relay…", Theme.ink.opacity(0.55))
        case .failed(let why):
            return (why, Theme.rose)
        case .noAddress:
            return ("Set the relay's address (wss://…).", Theme.rose)
        case .off:
            return ("Off.", Theme.ink.opacity(0.55))
        }
    }

    /// How the app reaches this Mac away from this Wi-Fi.
    private var awayNote: String {
        if relay.enabled, relay.relayURL != nil {
            return "Away from this Wi-Fi the app reaches this Mac through the relay, once paired with this code."
        }
        if RemoteServer.tailscaleAddress() != nil {
            return "Tailscale is on: the app reaches this Mac from anywhere while your phone is on the same tailnet."
        }
        return "Away from this Wi-Fi: turn on Reach this Mac from anywhere, then pair again."
    }
}


/// Settings > Skills: the skills the agent has (the repository's, yours,
/// Claude Code's), which chats used each, and more from GitHub.
private struct SkillsSettings: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var library = SkillLibrary.shared
    @State private var repo = "anthropics/skills"
    @State private var suggesting = false
    @State private var openUses: Set<String> = []

    private var installed: [Skill] { ProjectContext.skills(in: app.agentStartDirectory) }

    var body: some View {
        SettingsCard("Skills on hand", icon: "book.closed",
                     status: installed.isEmpty ? "None" : "\(installed.count)") {
            Text("Each skill is a SKILL.md that says how to do one kind of work well. The agent sees their names with every task and reads one when the task calls for it. They come from the repository (.companion/skills, .claude/skills), Companion's skills folder, and Claude Code's (~/.claude/skills).")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            if installed.isEmpty {
                Text("No skills yet. Get some from GitHub below.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink.opacity(0.6))
            }
            ForEach(installed) { skill in
                RowLine()
                installedRow(skill)
            }
            RowLine()
            HStack(spacing: 8) {
                PillButton("Open skills folder", icon: "folder") {
                    let folder = ProjectContext.skillsFolder
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
                Spacer()
            }
        }

        SettingsCard("Get skills from GitHub", icon: "arrow.down.circle",
                     status: library.loading ? "Looking" : nil) {
            HStack(spacing: 8) {
                TextField("owner/repository, or a link", text: $repo)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.ink.opacity(0.07)))
                    .onSubmit { library.browse(repo) }
                PillButton("Browse", icon: "magnifyingglass", prominent: true) { library.browse(repo) }
                    .disabled(library.loading)
            }
            HStack(spacing: 6) {
                ForEach(SkillLibrary.known, id: \.repo) { known in
                    Button(known.repo) {
                        repo = known.repo
                        library.browse(known.repo)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(Theme.accent.opacity(0.12)))
                    .help(known.about)
                }
                Spacer()
            }
            if !library.note.isEmpty {
                Text(library.note)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !library.remote.isEmpty {
                RowLine()
                HStack {
                    Text("\(library.remote.count) skills in \(library.browsing)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.ink.opacity(0.8))
                    Spacer()
                    PillButton(suggesting ? "Thinking…" : "Suggest for my work", icon: "sparkles") {
                        suggesting = true
                        Task {
                            library.suggested = await app.suggestSkills(library.remote)
                            library.note = library.suggested.isEmpty
                                ? "None of these stands out for the folder and chats you work in."
                                : "Suggested: \(library.suggested.sorted().joined(separator: ", "))."
                            suggesting = false
                        }
                    }
                    .disabled(suggesting)
                    .help("Ask the model which of these fit the folder you work in and your recent chats")
                }
                ForEach(sortedRemote) { skill in
                    RowLine()
                    remoteRow(skill)
                }
            }
            Text("Installing copies the skill's files into Companion's skills folder; nothing in it runs by itself. Each keeps a note of where it came from and its license. Anthropic's document skills (docx, pdf, pptx, xlsx) are source-available, not open source: their LICENSE.txt says what they may be used for.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Suggested first, then by name.
    private var sortedRemote: [SkillLibrary.Remote] {
        library.remote.sorted {
            let a = library.suggested.contains($0.name), b = library.suggested.contains($1.name)
            return a != b ? a : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func installedRow(_ skill: Skill) -> some View {
        let uses = library.chats(using: skill.name)
        let source = SkillLibrary.source(of: skill)
        let place = skill.fromProject ? "This repository"
            : (source.map { "From \($0.repo)" } ?? (skill.file.contains("/.claude/skills/") ? "Claude Code's" : "Yours"))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(skill.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.92))
                Text(place)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.5))
                if let license = source?.license, !license.isEmpty {
                    Text(license)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ink.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer()
                Button(uses.isEmpty ? "Not used yet" : "Used in \(uses.count) chat\(uses.count == 1 ? "" : "s")") {
                    if openUses.contains(skill.name) { openUses.remove(skill.name) } else { openUses.insert(skill.name) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(uses.isEmpty ? Theme.ink.opacity(0.4) : Theme.accent)
                .disabled(uses.isEmpty)
                IconButton("doc.text", help: "Open its SKILL.md") { NSWorkspace.shared.open(URL(fileURLWithPath: skill.file)) }
                if !skill.fromProject, skill.file.hasPrefix(ProjectContext.skillsFolder.path) {
                    IconButton("trash", help: "Move to the Trash") { library.remove(skill) }
                }
            }
            if !skill.about.isEmpty {
                Text(skill.about)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .lineLimit(2)
            }
            if openUses.contains(skill.name) {
                ForEach(uses, id: \.self) { use in
                    Button {
                        app.openConversation(use.conversation)
                        app.showSettings = false
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bubble.left")
                                .font(.system(size: 9.5))
                            Text(use.title)
                                .lineLimit(1)
                            Spacer()
                            Text(use.date.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(Theme.ink.opacity(0.45))
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink.opacity(0.8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 10)
                    .help("Open this chat")
                }
            }
        }
    }

    private func remoteRow(_ skill: SkillLibrary.Remote) -> some View {
        let done = library.isInstalled(skill)
        let busy = library.installing.contains(skill.id)
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.ink.opacity(0.92))
                    if library.suggested.contains(skill.name) {
                        Text("Suggested")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Theme.mint)
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(Capsule().fill(Theme.mint.opacity(0.15)))
                    }
                    Text(skill.license)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ink.opacity(0.45))
                        .lineLimit(1)
                }
                Text(skill.about)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if busy {
                LoadingMark(state: .working, size: 14)
            } else if done {
                Label("Installed", systemImage: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.mint)
            } else {
                PillButton("Install", icon: "arrow.down") { library.install(skill) }
            }
        }
    }
}


/// Settings > Agent > Chrome: connecting the agent to the user's own Chrome.
private struct ChromeSettings: View {
    @ObservedObject private var bridge = BrowserBridge.shared

    var body: some View {
        SettingsCard("Your Chrome", icon: "safari",
                     status: bridge.connected ? "Connected" : (bridge.installed ? "Not connected" : "Not set up"),
                     statusTint: bridge.connected ? Theme.mint : nil) {
            Text("The agent can open pages, read them, click and fill forms in your own Chrome (or Brave, Edge), where you are already signed in and iCloud Passwords and passkeys work as usual. It never types passwords: when a page needs one, it asks you to sign in. Clicking, typing and opening pages ask first, as other steps do.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            RowLine()
            SettingRow("1. Set up the connection",
                       detail: "Puts Companion's extension in its folder and tells Chrome, Brave and Edge how to reach Companion.") {
                PillButton(bridge.installed ? "Set up again" : "Set up", icon: "link", prominent: !bridge.installed) {
                    bridge.install()
                }
            }
            RowLine()
            SettingRow("2. Load the extension in Chrome",
                       detail: "On Chrome's Extensions page, turn on Developer mode, choose Load unpacked, and pick the ChromeExtension folder this shows. Once is enough.") {
                PillButton("Show it", icon: "puzzlepiece.extension") { bridge.showExtension() }
                    .disabled(!bridge.installed)
            }
            RowLine()
            SettingRow("3. Keep Chrome open",
                       detail: bridge.connected
                           ? "Connected to \(bridge.browser). Ask for something on a website, such as \"open my GitHub notifications\"."
                           : "It connects within half a minute of both running. Clicking the extension's icon connects at once.") {
                Circle()
                    .fill(bridge.connected ? Theme.mint : Theme.ink.opacity(0.25))
                    .frame(width: 9, height: 9)
            }
            if !bridge.note.isEmpty {
                Text(bridge.note)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}


/// Settings > Passwords: iCloud Passwords in Companion's browser.
private struct PasswordsSettings: View {
    @ObservedObject private var passwords = ICloudPasswords.shared
    @State private var code = ""
    @AppStorage("browserKeepsSignIns") private var keepSignIns = false

    private var status: (String, Color?) {
        switch passwords.state {
        case .ready: return ("Paired", Theme.mint)
        case .notInstalled: return ("Not set up", nil)
        case .installing: return ("Installing", nil)
        case .starting: return ("Starting", nil)
        case .needsPairing, .awaitingCode: return ("Not paired", Theme.amber)
        case .failed: return ("Not working", Theme.rose)
        }
    }

    var body: some View {
        SettingsCard("iCloud Passwords", icon: "key", status: status.0, statusTint: status.1) {
            Text("Logins saved in your iCloud Keychain are offered on sign-in pages in Companion's browser, with a strong password for sign-ups, and new logins are saved there after you sign in or up. Passwords go straight into the page: never into the chat, the model, a log or a file of Companion's.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            RowLine()
            switch passwords.state {
            case .notInstalled, .failed:
                if case .failed(let why) = passwords.state {
                    Text(why)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.rose)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if passwords.missingBrowser {
                    SettingRow("Install Chrome", detail: "With Homebrew if you have it, else Google's own installer, into Applications. It runs hidden, only to reach iCloud Passwords; you keep browsing in Companion.") {
                        PillButton("Install Chrome", prominent: true) { passwords.installBrowser() }
                    }
                } else {
                    SettingRow("Set up", detail: "Installs apwlib 0.1.2 (MIT) into Companion's own folder, with uv if you have it, else Python 3.12 or later. It needs Chrome, Brave or Edge on this Mac.") {
                        PillButton(passwords.installed ? "Try again" : "Set up", prominent: true) {
                            passwords.installed ? passwords.startPairing() : passwords.install()
                        }
                    }
                }
            case .installing, .starting:
                HStack(spacing: 8) {
                    LoadingMark(state: .working, size: 14)
                    Text(passwords.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink.opacity(0.7))
                }
            case .needsPairing:
                SettingRow("Pair", detail: passwords.detail.isEmpty
                           ? "macOS shows a 6-digit code to type in here, once each time the hidden Chrome starts."
                           : passwords.detail) {
                    PillButton("Pair", prominent: true) { passwords.startPairing() }
                }
            case .awaitingCode:
                SettingRow("Code from macOS", detail: passwords.detail) {
                    HStack(spacing: 6) {
                        TextField("123456", text: $code)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .frame(width: 80)
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.ink.opacity(0.07)))
                            .onSubmit { passwords.submit(code: code); code = "" }
                        PillButton("Pair", prominent: true) { passwords.submit(code: code); code = "" }
                    }
                }
            case .ready:
                SettingRow("Paired", detail: passwords.detail.isEmpty ? "Open a sign-in page in the browser to use it." : passwords.detail) {
                    PillButton("Disconnect") { passwords.stop() }
                }
            }
            RowLine()
            ToggleRow("Keep browser sign-ins",
                      detail: "Sites you sign in to in Companion's browser (a cluster portal, a course site) stay signed in between chats and restarts, kept on this Mac like any browser. Off: each chat's browser starts signed out and forgets everything when it ends. Applies to chats opened after the change.",
                      isOn: $keepSignIns)
            RowLine()
            Text("How it works: macOS lets only approved browsers talk to its iCloud Passwords helper, so a hidden Chrome hosts Apple's own iCloud Passwords extension and Companion talks to it on this Mac (the way apwlib does). Apple does not publish this, so an update to macOS or the extension can break it until apwlib catches up. Passkeys are not available this way.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}


/// Chrome extensions in Companion's browser: add from the Chrome Web Store,
/// a folder or file, or bring over the ones in Chrome, Arc, Brave or Edge.
private struct ExtensionsSettings: View {
    @ObservedObject private var extensions = BrowserExtensions.shared
    @State private var address = ""
    /// Extensions found in other browsers, while choosing which to bring.
    @State private var found: [BrowserExtensions.Found] = []
    @State private var chosen = Set<String>()
    @State private var looked = false

    var body: some View {
        SettingsCard("Extensions", icon: "puzzlepiece.extension",
                     status: BrowserExtensions.supported ? "\(extensions.items.filter(\.enabled).count) on" : "macOS 15.4+",
                     statusTint: nil) {
            Text("The same extensions Chrome uses, in every chat's browser and the agent's steps there: a blocker, a reader, a password manager. Each asks before it is added, with what it may do. Ones that need Chrome-only features, or a helper app that only answers Chrome, may not work.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            if !BrowserExtensions.supported {
                RowLine()
                Text("Extensions need macOS 15.4 or later.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.amber)
            } else {
                ForEach(extensions.items) { item in
                    RowLine()
                    row(item)
                }
                RowLine()
                SettingRow("Chrome Web Store", detail: "Paste a store link or an extension ID, or open the store in the browser and press Add to Companion there.") {
                    HStack(spacing: 6) {
                        TextField("Link or ID", text: $address)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .frame(width: 150)
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.ink.opacity(0.07)))
                            .onSubmit { extensions.addFromStore(address); address = "" }
                        PillButton("Add", prominent: true) { extensions.addFromStore(address); address = "" }
                            .disabled(BrowserExtensions.storeID(in: address) == nil || extensions.busy != nil)
                    }
                }
                RowLine()
                SettingRow("From this Mac", detail: "An unpacked extension folder (manifest.json), a .crx or a .zip; or the extensions already in Chrome, Arc, Brave, Edge, Chromium or Vivaldi (their files only: no sign-ins or history).") {
                    HStack(spacing: 6) {
                        PillButton("Choose…") { extensions.addFromDisk() }
                        PillButton("Import…") {
                            found = extensions.importable()
                            chosen = Set(found.map(\.id))
                            looked = true
                        }
                    }
                }
                if looked { importList }
                if let busy = extensions.busy {
                    RowLine()
                    HStack(spacing: 8) {
                        LoadingMark(state: .working, size: 14)
                        Text(busy)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.ink.opacity(0.7))
                    }
                    .padding(.vertical, 6)
                } else if let notice = extensions.notice {
                    RowLine()
                    Text(notice)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                }
            }
        }
    }

    private func row(_ item: BrowserExtensions.Item) -> some View {
        HStack(spacing: 9) {
            Group {
                if let icon = extensions.icon(for: item.id) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .foregroundStyle(Theme.ink.opacity(0.5))
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(item.enabled ? 0.95 : 0.5))
                    .lineLimit(1)
                Text(item.problem ?? ([item.version, item.source].filter { !$0.isEmpty }.joined(separator: " · ")))
                    .font(.system(size: 10.5))
                    .foregroundStyle(item.problem == nil ? Theme.ink.opacity(0.5) : Theme.rose)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            Button {
                extensions.setPinned(item.id, !item.pinned)
            } label: {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(item.pinned ? Theme.accent : Theme.ink.opacity(0.45))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(item.pinned ? "Shown in the browser bar" : "Only under the puzzle piece")
            Button {
                extensions.remove(item.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Remove")
            Toggle("", isOn: Binding(get: { item.enabled }, set: { extensions.setEnabled(item.id, $0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var importList: some View {
        RowLine()
        if found.isEmpty {
            HStack {
                Text("No extensions to bring over: none found in Chrome, Arc, Brave, Edge, Chromium or Vivaldi that are not here already.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                PillButton("Done") { looked = false }
            }
            .padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bring over (each keeps the access it has in its browser):")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.6))
                ForEach(found) { item in
                    Toggle(isOn: Binding(get: { chosen.contains(item.id) },
                                         set: { on in if on { chosen.insert(item.id) } else { chosen.remove(item.id) } })) {
                        Text("\(item.name)  ")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.ink.opacity(0.9))
                        + Text("\(item.browser) · \(item.version)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.ink.opacity(0.45))
                    }
                    .toggleStyle(.checkbox)
                }
                HStack(spacing: 6) {
                    Spacer()
                    PillButton("Cancel") { looked = false }
                    PillButton("Add \(chosen.count)", prominent: true) {
                        extensions.importFound(found.filter { chosen.contains($0.id) })
                        looked = false
                    }
                    .disabled(chosen.isEmpty)
                }
            }
            .padding(.vertical, 6)
        }
    }
}


/// The browser's engine: Chromium, the way Arc and Chrome are built (Chrome
/// extensions, the Web Store, Chrome's toolbar and one kept profile), or
/// WebKit with its own extension support.
private struct ChromiumSettings: View {
    @AppStorage(BrowserEngine.key) private var chromium = true

    var body: some View {
        SettingsCard("Engine", icon: "globe",
                     status: Chromium.isAvailable ? (chromium ? "Chromium" : "WebKit") : "WebKit",
                     statusTint: nil) {
            if Chromium.isAvailable {
                ToggleRow("Chromium",
                          detail: "Chromium \(Chromium.chromiumVersion.components(separatedBy: "+chromium-").last ?? "") runs the browser beside the chat, like Arc: Chrome's toolbar, its extensions straight from the Chrome Web Store, and one profile kept on this Mac (sign-ins, extensions, history). Off: WebKit, Safari's engine.",
                          isOn: $chromium)
                if chromium {
                    RowLine()
                    SettingRow("Extensions", detail: "Managed by Chromium, as in Chrome: add them from the Web Store, manage them on its Extensions page.") {
                        HStack(spacing: 6) {
                            PillButton("Web Store") { open("https://chromewebstore.google.com") }
                            PillButton("Manage") { open("chrome://extensions/") }
                        }
                    }
                }
            } else {
                Text("This build has WebKit only. bash build.sh fetches Chromium (about 250 MB) and builds it into the app.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if !(chromium && Chromium.isAvailable) {
            ExtensionsSettings()
        }
    }

    private func open(_ address: String) {
        let app = AppState.shared
        app.showSide(.browser)
        app.web.chromium.newTab(address)
    }
}
