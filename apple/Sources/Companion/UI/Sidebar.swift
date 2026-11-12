import SwiftUI

/// The sidebar of conversations, in Companion's own style: a title with the
/// main action, a search field, then every saved conversation as a card,
/// grouped by when it was last used, the open one edged in purple. Used both
/// floating (on hover) and pinned beside the chat.
struct SidebarView: View {
    @EnvironmentObject var app: AppState
    @FocusState private var searchFocused: Bool

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
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(0.07)))
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
            }
            ScrollView(.vertical, showsIndicators: false) {
                // A plain list, newest first: one line a chat, nothing else.
                LazyVStack(alignment: .leading, spacing: 1) {
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
            // Settings and Quit, pinned to the bottom of the sidebar.
            Spacer(minLength: 0)
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
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
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
