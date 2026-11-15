import SwiftUI

/// The sidebar of conversations, in Companion's own style: a title with the
/// main action, a search field, then every saved conversation as a card,
/// grouped by when it was last used, the open one edged in purple. Used both
/// floating (on hover) and pinned beside the chat.
struct SidebarView: View {
    @EnvironmentObject var app: AppState
    @FocusState private var searchFocused: Bool
    /// The sidebar's own toggle, beside the search while the sidebar is
    /// pinned. The panel hands it in, so it is the same button that floats
    /// in the top bar when the sidebar is closed and springs between them.
    private let toggle: AnyView?
    /// The toggle goes before the search (code: the sidebar is on the
    /// right, the chat on its left) rather than after the new button.
    private let toggleLeading: Bool

    init(toggle: AnyView? = nil, toggleLeading: Bool = false) {
        self.toggle = toggle
        self.toggleLeading = toggleLeading
    }

    private struct Bucket: Identifiable {
        let title: String
        let items: [ConversationSummary]
        var id: String { title }
    }

    /// Conversations grouped by recency. A search shows one flat list.
    private var sections: [Bucket] {
        guard app.historyQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            return app.history.isEmpty ? [] : [Bucket(title: "Results", items: app.history)]
        }
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        var today: [ConversationSummary] = []
        var yesterday: [ConversationSummary] = []
        var week: [ConversationSummary] = []
        var earlier: [ConversationSummary] = []
        for item in app.history {
            if calendar.isDateInToday(item.updatedAt) {
                today.append(item)
            } else if calendar.isDateInYesterday(item.updatedAt) {
                yesterday.append(item)
            } else if item.updatedAt > weekAgo {
                week.append(item)
            } else {
                earlier.append(item)
            }
        }
        return [Bucket(title: "Today", items: today),
                Bucket(title: "Yesterday", items: yesterday),
                Bucket(title: "This week", items: week),
                Bucket(title: "Earlier", items: earlier)].filter { !$0.items.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Search, always at hand, with the main action beside it.
            HStack(spacing: 6) {
                if toggleLeading, let toggle {
                    toggle
                }
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(searchFocused ? Theme.accent : Theme.ink.opacity(0.45))
                    TextField("Search", text: $app.historyQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink.opacity(0.95))
                        .focused($searchFocused)
                        .onChange(of: app.historyQuery) { _, _ in app.refreshHistory() }
                        .onExitCommand { endSearch() }
                    if !app.historyQuery.isEmpty {
                        IconButton("xmark.circle.fill", help: "Clear the search") { endSearch() }
                    }
                }
                .padding(.leading, 9)
                .padding(.trailing, 4)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.ink.opacity(0.07)))
                .glassBorder(radius: 9, tint: searchFocused ? Theme.accent : nil)
                // The same height as the search field, and round, so it
                // keeps its place however narrow the sidebar is.
                Button {
                    app.newConversation()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.82))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.accentGradient))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Start a new conversation")
                if !toggleLeading, let toggle {
                    toggle
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                // A plain list, newest first: one line a chat, nothing else.
                LazyVStack(alignment: .leading, spacing: 1) {
                    if app.historyQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        HStack(spacing: 6) {
                            Text("Projects")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.ink.opacity(0.5))
                            Spacer(minLength: 2)
                            IconButton("plus", help: "Add a project folder") { app.addProject() }
                        }
                        .padding(.horizontal, 4)
                        .padding(.bottom, 2)
                        ForEach(app.projects) { project in
                            ProjectRow(project: project)
                        }
                        if app.projects.isEmpty {
                            Text("No projects yet. Add a folder with +.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.ink.opacity(0.42))
                                .padding(.horizontal, 4)
                        }
                        Divider().padding(.vertical, 6)
                    }
                    ForEach(sections) { section in
                        ForEach(section.items) { item in
                            SidebarRow(item: item, isCurrent: item.id == app.conversation.id)
                        }
                    }
                    if sections.isEmpty {
                        Text(app.historyQuery.isEmpty
                             ? "Nothing saved yet. Conversations are kept once they have content."
                             : "No conversation contains that.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.ink.opacity(0.42))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                            .padding(.top, 10)
                    }
                }
                .padding(.bottom, 8)
            }
            // Settings and Quit, pinned to the bottom of the sidebar. In
            // code, with a folder open, they sit at the foot of the
            // workspace's activity bar instead.
            Spacer(minLength: 0)
            if !app.appButtonsInCodeBar {
                Divider()
                HStack(spacing: 6) {
                    IconButton("gearshape.fill",
                               help: "Settings",
                               tint: app.showSettings ? Theme.accent : nil) {
                        if app.showSettings {
                            app.showSettings = false
                        } else {
                            app.openSettings()
                        }
                    }
                    Spacer()
                    IconButton("power", help: "Quit Companion (⌘Q)", tint: Theme.rose) {
                        app.requestQuit()
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func endSearch() {
        searchFocused = false
        if !app.historyQuery.isEmpty {
            app.historyQuery = ""
            app.refreshHistory()
        }
    }
}

/// One project: its name, its newest chat (or "No conversations yet") and
/// how long ago it was used. Rename and remove show while the pointer is on
/// the row; removing takes it off the list only, never touching the folder.
private struct ProjectRow: View {
    @EnvironmentObject var app: AppState
    let project: Project
    @State private var hover = false
    @State private var renaming = false
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    private var latest: ConversationSummary? { app.chats(in: project).first }

    private func startRenaming() {
        newName = project.name
        renaming = true
        nameFocused = true
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.55))
            VStack(alignment: .leading, spacing: 1) {
                if renaming {
                    TextField("Name", text: $newName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink.opacity(0.97))
                        .focused($nameFocused)
                        .onSubmit {
                            app.renameProject(project.id, to: newName)
                            renaming = false
                        }
                        .onExitCommand { renaming = false }
                        .onChange(of: nameFocused) { _, focused in
                            if !focused { renaming = false }
                        }
                } else {
                    Text(project.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.ink.opacity(0.9))
                        .lineLimit(1)
                }
                Text(latest?.title ?? "No conversations yet")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 2)
            if hover, !renaming {
                IconButton("pencil", help: "Rename this project") { startRenaming() }
                IconButton("minus.circle", help: "Remove from the list (the folder is kept)") { app.removeProject(project.id) }
            } else if let latest {
                Text(latest.updatedAt.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.42))
                    .lineLimit(1)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .fill(Theme.ink.opacity(hover ? 0.06 : 0)))
        .help(project.folderPath)
        .contentShape(Rectangle())
        .onTapGesture {
            if !renaming, let latest { app.openConversation(latest.id) }
        }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Rename") { startRenaming() }
            Button("Remove from Projects", role: .destructive) { app.removeProject(project.id) }
        }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// One conversation, as a card in Companion's style: its name and when it
/// was last used. The open one carries the purple edge. Delete shows while
/// the pointer is on the row.
private struct SidebarRow: View {
    @EnvironmentObject var app: AppState
    let item: ConversationSummary
    let isCurrent: Bool
    @State private var hover = false
    @State private var renaming = false
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    private func startRenaming() {
        newName = item.title == Conversation.defaultTitle ? "" : item.title
        renaming = true
        nameFocused = true
    }

    var body: some View {
        HStack(spacing: 6) {
            if renaming {
                TextField("Name", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink.opacity(0.97))
                    .focused($nameFocused)
                    .onSubmit {
                        app.renameConversation(item.id, to: newName)
                        renaming = false
                    }
                    .onExitCommand { renaming = false }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { renaming = false }
                    }
            } else {
                Text(item.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink.opacity(isCurrent ? 0.97 : 0.86))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 2)
            if hover, !renaming {
                rowButton("pencil", help: "Rename") { startRenaming() }
                rowButton("trash", help: "Delete this conversation") { app.deleteConversation(item.id) }
            } else if app.chatsWaiting.contains(item.id) {
                // This chat's task waits on you: a question or an OK.
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.amber)
                    .frame(width: 20, height: 20)
                    .help("The task in this chat is waiting for you")
            } else if app.jobs[item.id] != nil {
                // A task is running in this chat.
                LoadingMark(state: .working, size: 12)
                    .frame(width: 20, height: 20)
                    .help("A task is running in this chat")
            } else if app.webRunning.contains(item.id) {
                // This chat's browser has a page open.
                Image(systemName: "globe")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent.opacity(0.9))
                    .frame(width: 20, height: 20)
                    .help("The browser in this chat has a page open")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .fill(Theme.ink.opacity(isCurrent ? 0.11 : (hover ? 0.06 : 0))))
        // The details that used to sit under the title, a pointer away.
        .help("\(item.title)\n\(item.turnCount) \(item.turnCount == 1 ? "turn" : "turns") · \(item.updatedAt.formatted(.relative(presentation: .named))) · \(ContextUse.short(item.tokens)) tokens")
        .contentShape(Rectangle())
        .onTapGesture {
            if !renaming { app.openConversation(item.id) }
        }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Rename") { startRenaming() }
            Button("Delete", role: .destructive) { app.deleteConversation(item.id) }
        }
        .animation(.easeOut(duration: 0.12), value: hover)
    }

    /// A small quiet button at the end of the row.
    private func rowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.6))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
