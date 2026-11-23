import SwiftUI

// The five selection controls in the Design Gallery, with sample data. The
// gallery shows them in light and dark at each width class and density, so
// the compact switcher (icons only), the stacked settings row and the
// wrapping chips can be checked there.

struct SelectionControlsDemo: View {
    enum Side: String { case chat, code, advanced }
    enum Mode: String { case ask, plan, agent, review }

    @State private var model = "local/qwen"
    @State private var side = Side.chat
    @State private var mode = Mode.agent
    @State private var filters: Set<String> = ["local"]
    @State private var accessLevel = "Edit"
    @State private var showInMenuBar = true
    @State private var name = "Companion"

    static let models: [SelectionSection<String>] = [
        SelectionSection(id: "local", title: "On this Mac", symbol: "lock.fill", items: [
            SelectionItem(id: "local/qwen", title: "Qwen3 Coder 30B", subtitle: "Fast code edits, nothing leaves the Mac",
                          symbol: "cpu",
                          badges: [SelectionBadge("Local", symbol: "lock.fill", tone: .positive),
                                   SelectionBadge("Free", tone: .positive),
                                   SelectionBadge("32K context"),
                                   SelectionBadge("Tool calls", symbol: "wrench.and.screwdriver")]),
            SelectionItem(id: "local/gpt-oss", title: "GPT OSS 20B", subtitle: "General answers and short plans",
                          symbol: "cpu",
                          badges: [SelectionBadge("Local", symbol: "lock.fill", tone: .positive),
                                   SelectionBadge("Free", tone: .positive),
                                   SelectionBadge("32K context")]),
        ]),
        SelectionSection(id: "api", title: "Through an API", symbol: "cloud", items: [
            SelectionItem(id: "api/opus", title: "Opus 5.5", subtitle: "The most capable, for hard plans and reviews",
                          symbol: "sparkle",
                          badges: [SelectionBadge("API", symbol: "cloud", tone: .info),
                                   SelectionBadge("Paid", tone: .caution),
                                   SelectionBadge("200K context"),
                                   SelectionBadge("Tool calls", symbol: "wrench.and.screwdriver")]),
            SelectionItem(id: "api/gemini", title: "Gemini Flash", subtitle: "Quick and cheap, with a long memory",
                          symbol: "bolt",
                          badges: [SelectionBadge("API", symbol: "cloud", tone: .info),
                                   SelectionBadge("Free tier", tone: .positive),
                                   SelectionBadge("1M context")]),
        ]),
        SelectionSection(id: "account", title: "On your account", symbol: "person.fill", items: [
            SelectionItem(id: "account/codex", title: "Codex", subtitle: "The tool picks the model",
                          symbol: "terminal",
                          badges: [SelectionBadge("Account", symbol: "person.fill", tone: .accent),
                                   SelectionBadge("In your plan"),
                                   SelectionBadge("Tool calls", symbol: "wrench.and.screwdriver")]),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xl) {
            part("Searchable picker") {
                Text("Type to filter, arrow keys to move, Return to choose, Escape to close.")
                    .textRole(.caption, .secondary)
                SearchablePicker(title: "Model", sections: Self.models, selection: model, recents: ["api/opus"],
                                 maxHeight: 280, autoFocus: false, onSelect: { model = $0 })
                    .frame(maxWidth: 400)
                    .padding(Design.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background { GlassBackdrop() }
                    .clipShape(Design.Radius.shape(Design.Radius.card))
                HStack(spacing: Design.Space.s) {
                    SearchablePickerButton(title: "Model", sections: Self.models, selection: $model)
                    SearchablePicker(title: "Nothing here", sections: [], autoFocus: false, onSelect: { _ in })
                        .frame(maxWidth: 260)
                }
            }
            part("Segmented switcher") {
                SegmentedSwitcher("Side", options: [
                    SwitcherOption(id: Side.chat, title: "Chat", symbol: "bubble.left"),
                    SwitcherOption(id: Side.code, title: "Code", symbol: "chevron.left.forwardslash.chevron.right"),
                    SwitcherOption(id: Side.advanced, title: "Advanced", symbol: "square.stack.3d.up"),
                ], selection: $side)
                SegmentedSwitcher("Mode", options: [
                    SwitcherOption(id: Mode.ask, title: "Ask", symbol: "questionmark.bubble"),
                    SwitcherOption(id: Mode.plan, title: "Plan", symbol: "list.bullet.clipboard"),
                    SwitcherOption(id: Mode.agent, title: "Agent", symbol: "bolt"),
                    SwitcherOption(id: Mode.review, title: "Review", symbol: "checkmark.seal"),
                ], selection: $mode)
            }
            part("Filter chips") {
                FilterChips("Models", options: [
                    FilterOption(id: "local", title: "Local", symbol: "lock", count: 2),
                    FilterOption(id: "api", title: "API", symbol: "cloud", count: 2),
                    FilterOption(id: "account", title: "Account", symbol: "person", count: 1),
                    FilterOption(id: "free", title: "Free", symbol: "gift", count: 3),
                    FilterOption(id: "tools", title: "Tool calls", symbol: "wrench.and.screwdriver", count: 4),
                ], selection: $filters)
                .frame(maxWidth: 480)
            }
            part("Settings rows") {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsRow("Access", help: "What an agent may do without asking.") {
                        Picker("Access", selection: $accessLevel) {
                            ForEach(["Ask", "Edit", "Full"], id: \.self) { Text($0) }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    Divider()
                    SettingsRow("Show in menu bar", help: "Adds Companion to the menu bar.") {
                        Toggle("Show in menu bar", isOn: $showInMenuBar).toggleStyle(.switch)
                    }
                    Divider()
                    SettingsRow("Name", help: "Shown at the top of the panel.") {
                        TextField("Name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 240)
                    }
                }
                .frame(maxWidth: Design.readableWidth)
            }
            part("Sectioned menu") {
                SectionedMenu("Chat actions", symbol: "ellipsis.circle", groups: [
                    MenuGroup("Chat", entries: [
                        MenuEntry("New chat", symbol: "square.and.pencil",
                                  shortcut: KeyboardShortcut(KeyEquivalent("n"), modifiers: .command)),
                        MenuEntry("Duplicate", symbol: "plus.square.on.square",
                                  shortcut: KeyboardShortcut(KeyEquivalent("d"), modifiers: .command)),
                    ]),
                    MenuGroup("Export", entries: [
                        MenuEntry("Copy as Markdown", symbol: "doc.on.doc",
                                  shortcut: KeyboardShortcut(KeyEquivalent("c"), modifiers: [.command, .shift])),
                        MenuEntry("Save as file", symbol: "square.and.arrow.down", selected: true),
                    ]),
                    MenuGroup(entries: [
                        MenuEntry("Delete chat", symbol: "trash",
                                  shortcut: KeyboardShortcut(.delete, modifiers: .command), destructive: true),
                    ]),
                ])
            }
        }
    }

    private func part<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            Text(title).textRole(.label, .secondary)
            content()
        }
    }
}