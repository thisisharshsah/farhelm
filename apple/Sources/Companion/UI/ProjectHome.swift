import AppKit
import CompanionBoard
import SwiftUI

/// Which project's page the chat's panel shows in place of a chat. The
/// sidebar lists projects one line each and opens this; opening or
/// starting any chat closes it.
@MainActor
final class ProjectHome: ObservableObject {
    static let shared = ProjectHome()

    /// The project whose page is showing, if one is.
    @Published private(set) var projectID: UUID?

    func show(_ project: UUID) {
        projectID = project
    }

    func close() {
        if projectID != nil { projectID = nil }
    }
}

/// A project's page, in the chat's panel: its name and folder, a box that
/// starts a chat in it, and its chats placed the way its work stands
/// (`ChatShelf.spot`). The supervisor's chat comes first; then what needs
/// you and what is running, each task with its one chat; then your own
/// chats, the newest few and the rest on request; then, folded, those
/// unused for two weeks and those put away. A search finds any of its
/// chats by name or by task. Its board, timeline and usage are a click away.
struct ProjectHomeView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var advanced = Advanced.shared
    @ObservedObject private var boards = BoardStore.shared
    let project: Project
    /// Room at the top, for the sidebar's toggle when it sits in this panel.
    var topInset: CGFloat = 10

    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @State private var query = ""
    @State private var showAll = false
    @State private var showOlder = false
    @State private var showArchived = false
    @State private var renaming = false
    @State private var newName = ""
    @FocusState private var nameFocused: Bool
    /// Asked whether to take it off the list.
    @State private var removing = false

    /// How many of your own chats are listed before "Show all".
    private static let few = 8
    /// A search box is offered once a project has more chats than this.
    private static let searchable = 6

    /// A chat with where it goes, and its task as the board has it.
    private struct Placed: Identifiable {
        let chat: ConversationSummary
        let spot: ChatShelf.Spot
        let task: WorkItem?
        var id: UUID { chat.id }
    }

    private func placed() -> [Placed] {
        let board = boards.boards[project.id]
        return app.chats(in: project).map { chat in
            let spot = advanced.spot(of: chat, in: project.id)
            return Placed(chat: chat, spot: spot, task: spot.task.flatMap { board?.item($0) })
        }
    }

    /// Every word searched for is in its name, or its task's key or name.
    private func matches(_ item: Placed) -> Bool {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return true }
        let text = [item.chat.title, item.task?.key ?? "", item.task?.title ?? ""].joined(separator: " ").lowercased()
        return words.allSatisfy { text.contains($0) }
    }

    var body: some View {
        let all = placed()
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                composer
                if all.count > Self.searchable {
                    searchField
                }
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    sections(all)
                } else {
                    results(all)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.gutter)
            .padding(.top, topInset)
            .padding(.bottom, 24)
        }
        // Its board is read, so its chats can be placed by it.
        .onAppear {
            advanced.prepareChats(of: project)
            composerFocused = true
        }
        // From one project's page straight to another's: start clean.
        .onChange(of: project.id) { _, _ in
            draft = ""
            query = ""
            showAll = false
            showOlder = false
            showArchived = false
            renaming = false
            advanced.prepareChats(of: project)
        }
        .confirmationDialog("Take \(project.name) off the Projects list?", isPresented: $removing,
                            titleVisibility: .visible) {
            Button("Remove from Projects", role: .destructive) {
                ProjectHome.shared.close()
                app.removeProject(project.id)
            }
            Button("Cancel", role: .cancel) { removing = false }
        } message: {
            Text("Its chats, its board and its folder are kept. Add the folder again and the project is back as it was.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                if renaming {
                    TextField("", text: $newName, prompt: Text("Name").foregroundStyle(Theme.ink.opacity(0.42)))
                        .textFieldStyle(.plain)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
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
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.ink.opacity(0.96))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help("\(project.name). Double-click to rename.")
                        .onTapGesture(count: 2) { startRenaming() }
                }
                Text(project.abbreviatedFolder ?? "No folder")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(project.folder ?? "No folder")
            }
            Spacer(minLength: 8)
            ToolbarGroup {
                ForEach(Self.boardViews) { kind in
                    IconButton(kind.icon, help: Self.help(for: kind)) { openBoard(kind) }
                }
                moreMenu
            }
        }
    }

    /// The board's views offered from here.
    private static let boardViews: [BoardViewKind] = [.board, .timeline, .usage]

    private static func help(for kind: BoardViewKind) -> String {
        switch kind {
        case .board: return "Open its board"
        case .table: return "Open its tasks as a table"
        case .timeline: return "Open its timeline"
        case .usage: return "What its work has cost"
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("New Chat") { start() }
            Divider()
            Button("Rename") { startRenaming() }
            Button("Change Folder…") { app.changeProjectFolder(project.id) }
            if let folder = project.folder {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
                }
            }
            Divider()
            Button("Remove from Projects…", role: .destructive) { removing = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.7))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More for this project")
    }

    private func startRenaming() {
        newName = project.name
        renaming = true
        nameFocused = true
    }

    /// Opens the project's board on one of its views, in Advanced.
    private func openBoard(_ kind: BoardViewKind) {
        UserDefaults.standard.set(kind.rawValue, forKey: BoardViewKind.storageKey)
        ProjectHome.shared.close()
        Advanced.shared.open(project)
        app.setAdvanced(true)
    }

    // MARK: Starting a chat

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("", text: $draft, prompt: Text("Start a chat in \(project.name)…").foregroundStyle(Theme.ink.opacity(0.42)))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink.opacity(0.96))
                .focused($composerFocused)
                .onSubmit { start() }
            Button {
                start()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.82))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.accentGradient))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(draft.isEmpty ? "Start a new chat in \(project.name)" : "Send it, in a new chat in \(project.name)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.ink.opacity(0.06)))
        .glassBorder(radius: Theme.controlRadius, tint: composerFocused ? Theme.accent : nil)
    }

    /// A new chat in the project, with what was typed sent in it. Opening
    /// the new chat closes this page.
    private func start() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        ProjectHome.shared.close()
        app.newConversation(in: project.id)
        if !text.isEmpty { app.send(text) }
    }

    // MARK: Its chats

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.45))
            TextField("", text: $query, prompt: Text("Find a chat in \(project.name)").foregroundStyle(Theme.ink.opacity(0.42)))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink.opacity(0.95))
                .onExitCommand { query = "" }
            if !query.isEmpty {
                IconButton("xmark.circle.fill", help: "Clear the search") { query = "" }
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.ink.opacity(0.05)))
    }

    /// Everything in its place: the supervisor, what needs you, what is
    /// running, your chats, then the older ones and those put away, folded.
    @ViewBuilder
    private func sections(_ all: [Placed]) -> some View {
        let supervisor = all.filter { $0.spot.place == .supervisor }
        let needs = all.filter { $0.spot.place == .needsYou }
        let running = all.filter { $0.spot.place == .running }
        let mine = all.filter { $0.spot.place == .mine }
        let older = all.filter { $0.spot.place == .older }
        let archived = all.filter { $0.spot.place == .archived }
        if all.isEmpty {
            note("No chats yet. Start one above.")
        }
        if !supervisor.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(supervisor) { row($0) }
            }
        }
        if !needs.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                heading("Needs you", count: needs.count, tint: Theme.amber)
                ForEach(needs) { row($0) }
            }
        }
        if !running.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                heading("Running", count: running.count)
                ForEach(running) { row($0) }
            }
        }
        if !mine.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                heading("Chats", count: mine.count)
                ForEach(showAll ? mine : Array(mine.prefix(Self.few))) { row($0) }
                if mine.count > Self.few {
                    quiet(showAll ? "Show fewer" : "Show all \(mine.count)") { showAll.toggle() }
                }
            }
        }
        if !older.isEmpty || !archived.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                if !older.isEmpty {
                    fold("Older", count: older.count, open: $showOlder,
                         help: "Your chats here that have not been used for two weeks")
                    if showOlder {
                        ForEach(older) { row($0) }
                    }
                }
                if !archived.isEmpty {
                    fold("Archived", count: archived.count, open: $showArchived,
                         help: "Put away: chats of done or shelved tasks, earlier ones, and those you archived")
                    if showArchived {
                        ForEach(archived) { row($0) }
                    }
                }
            }
        }
    }

    /// A search: every one of its chats that matches, wherever it is placed.
    @ViewBuilder
    private func results(_ all: [Placed]) -> some View {
        let found = all.filter(matches)
        if found.isEmpty {
            note("No chat here has that in its name or its task.")
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(found) { row($0) }
            }
        }
    }

    private func row(_ item: Placed) -> some View {
        SidebarRow(item: item.chat, isCurrent: false, spot: item.spot, task: item.task, showsTime: true)
    }

    private func heading(_ title: String, count: Int? = nil, tint: Color? = nil) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
            if let count {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(tint ?? Theme.ink.opacity(0.5))
        .padding(.leading, 9)
        .padding(.bottom, 3)
    }

    /// A folded group's heading: a click opens or closes it.
    private func fold(_ title: String, count: Int, open: Binding<Bool>, help: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { open.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(Theme.ink.opacity(0.5))
            .padding(.leading, 9)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.ink.opacity(0.45))
            .padding(.leading, 9)
    }

    private func quiet(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.55))
                .padding(.leading, 9)
                .frame(height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
