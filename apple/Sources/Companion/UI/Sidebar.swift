import CompanionBoard
import SwiftUI

/// The sidebar of conversations, in Companion's own style: a title with the
/// main action, a search field, then the projects and the conversations.
/// A project holds its own chats (its supervisor's, its tasks', any other
/// started in it): they are listed inside it, placed the way its work
/// stands (`ProjectChatList`), and it opens and closes.
/// Under the projects come the chats that are in no project, grouped by
/// when they were last used, the open one edged in purple. Used both
/// floating (on hover) and pinned beside the chat.
struct SidebarView: View {
    @EnvironmentObject var app: AppState
    /// Watched for projects that are off the list with their boards and
    /// chats still here, which the list offers to bring back.
    @ObservedObject private var advanced = Advanced.shared
    @FocusState private var searchFocused: Bool
    /// The projects that are open (their chats showing), by id, with
    /// commas between: kept from one launch to the next.
    @AppStorage(SidebarProjects.key) private var openProjects = ""
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

    private var openIDs: Set<String> {
        Set(openProjects.split(separator: ",").map(String.init))
    }

    private func isOpen(_ project: Project) -> Bool {
        openIDs.contains(project.id.uuidString)
    }

    /// Opens or closes a project. Projects no longer on the list are
    /// forgotten along the way.
    private func setOpen(_ project: UUID, _ on: Bool) {
        var ids = openIDs.intersection(Set(app.projects.map { $0.id.uuidString }))
        if on {
            ids.insert(project.uuidString)
        } else {
            ids.remove(project.uuidString)
        }
        openProjects = ids.sorted().joined(separator: ",")
    }

    /// The open chat's project is opened, so the chat is in view where
    /// it belongs. (It can be closed again; it stays closed until another
    /// of its chats is opened.)
    private func revealOpenChat() {
        guard let project = app.currentProject, !isOpen(project) else { return }
        setOpen(project.id, true)
    }

    /// The conversations that are in no project, grouped by recency. A
    /// search shows one flat list of everything that matches, wherever
    /// it is.
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
        // A project's chats are listed inside the project, not here too.
        for item in app.chatsOutsideProjects {
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
                // The projects, each with its chats inside it, then the chats
                // in no project, newest first: one line a chat.
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
                            let expanded = isOpen(project)
                            ProjectRow(project: project, expanded: expanded) {
                                setOpen(project.id, !expanded)
                            }
                            if expanded {
                                ProjectChatList(project: project)
                            }
                        }
                        // A project that was taken off the list when that
                        // still cut its chats loose: one click puts it back.
                        ForEach(advanced.lostProjects) { lost in
                            LostProjectRow(lost: lost)
                        }
                        if app.projects.isEmpty, advanced.lostProjects.isEmpty {
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
                    // Nothing at all, or nothing found: chats that are all
                    // inside projects leave this part empty without a word.
                    if sections.isEmpty, app.history.isEmpty {
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
        .onAppear {
            revealOpenChat()
            advanced.lookForLostProjects()
        }
        .onChange(of: app.conversation.id) { _, _ in revealOpenChat() }
        .onChange(of: app.projects) { _, _ in advanced.lookForLostProjects() }
    }

    private func endSearch() {
        searchFocused = false
        if !app.historyQuery.isEmpty {
            app.historyQuery = ""
            app.refreshHistory()
        }
    }
}

/// Which projects are open in the sidebar, in the defaults the sidebar
/// reads, so that another part of the app can open one (a project that
/// was just brought back, say).
enum SidebarProjects {
    static let key = "sidebarOpenProjects"

    static func open(_ id: UUID) {
        var ids = Set((UserDefaults.standard.string(forKey: key) ?? "").split(separator: ",").map(String.init))
        ids.insert(id.uuidString)
        UserDefaults.standard.set(ids.sorted().joined(separator: ","), forKey: key)
    }
}

/// A project that is off the list though its board and its chats are
/// still here (`Advanced.LostProject`): it was taken off the list when
/// that still cut its chats loose. The row says what it is and how much
/// belongs to it, and a click puts it back as it was, its chats inside it.
private struct LostProjectRow: View {
    let lost: Advanced.LostProject
    @State private var hover = false

    private var facts: String {
        let tasks = lost.tasks == 1 ? "1 task" : "\(lost.tasks) tasks"
        let chats = lost.chats.count == 1 ? "1 chat" : "\(lost.chats.count) chats"
        return "\(tasks) and \(chats)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.amber)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(lost.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.92))
                    .lineLimit(1)
                Text("Off the list, with \(facts). Click to bring it back.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 2)
        }
        .padding(.leading, 6)
        .padding(.trailing, 5)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .fill(Theme.amber.opacity(hover ? 0.20 : 0.11)))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .strokeBorder(Theme.amber.opacity(0.35), lineWidth: 0.75))
        .contentShape(Rectangle())
        .onTapGesture { Advanced.shared.bringBack(lost) }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Bring It Back") { Advanced.shared.bringBack(lost) }
            Button("Do Not Offer This Again") { Advanced.shared.stopOffering(lost) }
        }
        .help("This project was taken off the list, which left its board and its chats without it. Click to put it back as it was"
              + (lost.folder.map { ", in \(($0 as NSString).abbreviatingWithTildeInPath)." } ?? ". Its folder is asked for."))
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// One project: its name and folder, and while it is closed its newest
/// chat (or "No conversations yet") and how long ago it was used. A click
/// anywhere on it opens it to show its chats under it, and closes it
/// again. Closed, it still says when a task in one of its chats is
/// running or waits on you. No button sits on the row: a click meant to
/// open or close it can land on nothing else. A new chat in it, rename,
/// change folder and remove are in its menu (right-click), and "New chat"
/// is also under its chats when it is open. Removing asks first, takes
/// it off the list only, and is undone by adding its folder again.
private struct ProjectRow: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var advanced = Advanced.shared
    @ObservedObject private var boards = BoardStore.shared
    let project: Project
    /// Its chats are showing under it.
    let expanded: Bool
    let toggle: () -> Void
    @State private var hover = false
    @State private var renaming = false
    @State private var newName = ""
    /// Asked whether to take it off the list.
    @State private var removing = false
    @FocusState private var nameFocused: Bool

    private var chats: [ConversationSummary] { app.chats(in: project) }
    private var latest: ConversationSummary? { chats.first }
    /// How many of its tasks wait on the person.
    private var needs: Int {
        chats.filter { advanced.spot(of: $0, in: project.id).place == .needsYou }.count
    }

    private func startRenaming() {
        newName = project.name
        renaming = true
        nameFocused = true
    }

    var body: some View {
        let chats = self.chats
        let waitingChats = app.chatsWaiting
        let waiting = chats.contains { waitingChats.contains($0.id) }
        let working = chats.contains { app.jobs[$0.id] != nil }
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.ink.opacity(0.45))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 9)
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
                Text(project.abbreviatedFolder ?? "No folder")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.42))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Open, its chats are right under it and say this themselves.
                if !expanded {
                    let needing = needs
                    Text(needing > 0 ? "\(needing) \(needing == 1 ? "task needs" : "tasks need") you"
                         : (latest?.title ?? "No conversations yet"))
                        .font(.system(size: 11, weight: needing > 0 ? .medium : .regular))
                        .foregroundStyle(needing > 0 ? Theme.amber : Theme.ink.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 2)
            if waiting {
                // A task in one of its chats waits on you: a question or an OK.
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.amber)
                    .frame(width: 20, height: 20)
                    .help("A task in one of this project's chats is waiting for you")
            } else if working {
                LoadingMark(state: .working, size: 12)
                    .frame(width: 20, height: 20)
                    .help("A task is running in one of this project's chats")
            } else if !expanded, let latest {
                Text(latest.updatedAt.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.42))
                    .lineLimit(1)
            } else if expanded, !chats.isEmpty {
                Text("\(chats.count)")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink.opacity(0.42))
                    .help(chats.count == 1 ? "1 chat in this project" : "\(chats.count) chats in this project")
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .fill(Theme.ink.opacity(hover ? 0.06 : 0)))
        .help((project.folder ?? "No folder")
              + (expanded ? "\nClick to close it." : "\nClick to show its chats.") + " Right-click for more.")
        .contentShape(Rectangle())
        .onTapGesture {
            if !renaming { toggle() }
        }
        .onHover { hover = $0 }
        // Its board is read, so its chats can be placed by it.
        .onAppear { advanced.prepareChats(of: project) }
        .contextMenu {
            Button(expanded ? "Close" : "Show Its Chats") { toggle() }
            Button("New Chat in This Project") { app.newConversation(in: project.id) }
            Divider()
            Button("Rename") { startRenaming() }
            Button("Change Folder…") { app.changeProjectFolder(project.id) }
            Button("Remove from Projects…", role: .destructive) { removing = true }
        }
        .confirmationDialog("Take \(project.name) off the Projects list?", isPresented: $removing,
                            titleVisibility: .visible) {
            Button("Remove from Projects", role: .destructive) { app.removeProject(project.id) }
            Button("Cancel", role: .cancel) { removing = false }
        } message: {
            Text("Its chats, its board and its folder are kept. Add the folder again and the project is back as it was.")
        }
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeOut(duration: 0.15), value: expanded)
    }
}

/// What a project's chat list shows: everything in its place, or one
/// group at a time.
private enum ChatFilter: String, CaseIterable, Identifiable {
    case all, needsYou, running, mine, archived

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "tray.full"
        case .needsYou: return "exclamationmark.bubble"
        case .running: return "play.circle"
        case .mine: return "person"
        case .archived: return "archivebox"
        }
    }

    var help: String {
        switch self {
        case .all: return "Everything in its place: the supervisor, what needs you, what is running, your chats"
        case .needsYou: return "Tasks that wait on you: an answer, a review, a run that stopped, or work to merge"
        case .running: return "Tasks being worked on, or about to be"
        case .mine: return "Your own chats in this project, old ones too"
        case .archived: return "Put away: chats of done or shelved tasks, earlier ones, and those you archived"
        }
    }

    /// What it says when it has nothing to show.
    var empty: String {
        switch self {
        case .all: return "No chats yet."
        case .needsYou: return "Nothing needs you."
        case .running: return "Nothing is running."
        case .mine: return "No chats of your own here yet."
        case .archived: return "Nothing put away."
        }
    }
}

/// A project's chats, inside the project, placed the way its work stands
/// (`ChatShelf`): the supervisor's pinned on top; then the tasks that need
/// you and the tasks being worked on, each task with its one chat, named
/// after it; then your own chats, the newest few and the rest when asked,
/// with those unused for two weeks folded into Older. Chats of tasks that
/// are done or shelved are put away (Archived), as are those you archive.
/// A filter shows one group at a time, and a search finds chats in the
/// project by their name or their task's.
private struct ProjectChatList: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var advanced = Advanced.shared
    @ObservedObject private var boards = BoardStore.shared
    let project: Project
    @State private var filter: ChatFilter = .all
    @State private var searching = false
    @State private var query = ""
    /// Every one of your chats is listed, not only the newest few.
    @State private var showAll = false
    /// The older ones are unfolded.
    @State private var showOlder = false
    @FocusState private var searchFocused: Bool

    private static let few = 6
    private static let most = 100
    /// How far the chats stand in from the project's edge.
    private static let indent: CGFloat = 15

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

    /// It waits on the person: a task that needs them, or one of their own
    /// chats where an agent asks something.
    private func needsYou(_ item: Placed) -> Bool {
        item.spot.place == .needsYou || item.spot.need == .answer
    }

    private func shown(_ item: Placed, by filter: ChatFilter) -> Bool {
        switch filter {
        case .all: return item.spot.place != .archived
        case .needsYou: return needsYou(item)
        case .running: return item.spot.place == .running
        case .mine: return item.spot.place == .mine || item.spot.place == .older
        case .archived: return item.spot.place == .archived
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
        let counts = Dictionary(uniqueKeysWithValues: ChatFilter.allCases.map { option in
            (option, all.filter { shown($0, by: option) }.count)
        })
        VStack(alignment: .leading, spacing: 1) {
            if all.count > 1 {
                filterBar(counts)
                if searching { searchField }
            }
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                // A search looks through all of the project's chats.
                let found = all.filter(matches)
                if found.isEmpty { note("No chat here has that in its name.") }
                ForEach(found) { row($0) }
            } else if filter == .all {
                everything(all)
            } else {
                let group = all.filter { shown($0, by: filter) }
                if group.isEmpty { note(filter.empty) }
                ForEach(group) { row($0) }
            }
            HStack(spacing: 2) {
                quiet("New chat", icon: "plus", help: "Start a new conversation in \(project.name)") {
                    app.newConversation(in: project.id)
                }
                Spacer(minLength: 2)
            }
            .padding(.leading, Self.indent + 3)
        }
        .padding(.bottom, 4)
        .onAppear { advanced.prepareChats(of: project) }
    }

    /// Everything in its place: the supervisor, what needs you, what is
    /// running, your chats and the older ones folded. The open chat is
    /// always listed, wherever it would be.
    @ViewBuilder
    private func everything(_ all: [Placed]) -> some View {
        let supervisor = all.filter { $0.spot.place == .supervisor }
        let needs = all.filter { $0.spot.place == .needsYou }
        let running = all.filter { $0.spot.place == .running }
        let mine = all.filter { $0.spot.place == .mine }
        let older = all.filter { $0.spot.place == .older }
        let listedMine = Array(mine.prefix(showAll ? Self.most : Self.few))
        let visible = Set((supervisor + needs + running + listedMine + (showOlder ? older : [])).map(\.id))
        ForEach(supervisor) { row($0) }
        if let open = all.first(where: { $0.id == app.conversation.id }), !visible.contains(open.id) {
            heading("Open")
            row(open)
        }
        if !needs.isEmpty {
            heading("Needs you", count: needs.count, tint: Theme.amber)
            ForEach(needs) { row($0) }
        }
        if !running.isEmpty {
            heading("Running", count: running.count)
            ForEach(running) { row($0) }
        }
        if !mine.isEmpty {
            if !supervisor.isEmpty || !needs.isEmpty || !running.isEmpty { heading("Chats") }
            ForEach(listedMine) { row($0) }
            if mine.count > Self.few {
                quiet(showAll ? "Show fewer" : "Show all \(mine.count)",
                      help: showAll ? "Show only the newest chats" : "Show every chat of yours in this project") {
                    showAll.toggle()
                }
                .padding(.leading, Self.indent + 3)
            }
        }
        if !older.isEmpty {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showOlder.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .rotationEffect(.degrees(showOlder ? 90 : 0))
                    Text("Older (\(older.count))")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(Theme.ink.opacity(0.45))
                .padding(.leading, Self.indent + 6)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Your chats here that have not been used for two weeks")
            if showOlder {
                ForEach(older) { row($0) }
            }
        }
        if all.isEmpty { note(ChatFilter.all.empty) }
    }

    private func row(_ item: Placed) -> some View {
        SidebarRow(item: item.chat, isCurrent: item.id == app.conversation.id, indent: Self.indent,
                   spot: item.spot, task: item.task)
    }

    /// The filter, one small button a group, with how many need you and
    /// how many are running; and the way to search the project's chats.
    private func filterBar(_ counts: [ChatFilter: Int]) -> some View {
        HStack(spacing: 1) {
            ForEach(ChatFilter.allCases) { option in
                let on = filter == option
                let count = counts[option] ?? 0
                let urgent = option == .needsYou && count > 0
                Button {
                    filter = option
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: option.icon)
                            .font(.system(size: 9.5, weight: .semibold))
                        if count > 0, option == .needsYou || option == .running {
                            Text("\(count)")
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(urgent ? Theme.amber : (on ? Theme.accent : Theme.ink.opacity(0.5)))
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(Capsule().fill(on ? Theme.accent.opacity(0.15) : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(option.help + (count > 0 && option != .all ? " (\(count))" : ""))
            }
            Spacer(minLength: 2)
            Button {
                searching.toggle()
                if searching {
                    searchFocused = true
                } else {
                    query = ""
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(searching ? Theme.accent : Theme.ink.opacity(0.5))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Find a chat in \(project.name) by its name or its task")
        }
        .padding(.leading, Self.indent)
        .padding(.vertical, 2)
    }

    private var searchField: some View {
        TextField("Find in \(project.name)", text: $query)
            .textFieldStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.ink.opacity(0.95))
            .focused($searchFocused)
            .onExitCommand {
                query = ""
                searching = false
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.ink.opacity(0.06)))
            .padding(.leading, Self.indent)
            .padding(.bottom, 3)
    }

    private func heading(_ title: String, count: Int? = nil, tint: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
            if let count {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(tint ?? Theme.ink.opacity(0.45))
        .padding(.leading, Self.indent + 6)
        .padding(.top, 5)
        .padding(.bottom, 1)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.ink.opacity(0.42))
            .padding(.leading, Self.indent + 6)
            .padding(.vertical, 4)
    }

    private func quiet(_ title: String, icon: String? = nil, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.ink.opacity(0.55))
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// One conversation, as a card in Companion's style: its name and when it
/// was last used. The open one carries the purple edge. Rename and delete
/// show while the pointer is on the row. Deleting asks first: the buttons
/// sit where a click to open the chat can land, and a deleted chat does
/// not come back. Inside a project, a task's chat is named after its task,
/// with the task's key in front and how the task stands at the end; the
/// supervisor's chat is "Supervisor".
private struct SidebarRow: View {
    @EnvironmentObject var app: AppState
    let item: ConversationSummary
    let isCurrent: Bool
    /// How far it stands in, when it is listed inside a project.
    var indent: CGFloat = 0
    /// Where it is listed in its project, and its task as the board has it.
    var spot: ChatShelf.Spot? = nil
    var task: WorkItem? = nil
    @State private var hover = false
    @State private var renaming = false
    @State private var newName = ""
    /// Asked whether to delete it.
    @State private var deleting = false
    @FocusState private var nameFocused: Bool

    /// What deleting it means, for the question that is asked first.
    private var deletionMessage: String {
        var text = "The conversation and everything in it is deleted for good."
        if app.jobs[item.id] != nil { text = "A task is running in it. " + text }
        if let note = Advanced.shared.noteOnDeleting(item.id) { text += " " + note }
        return text
    }

    private func startRenaming() {
        newName = item.title == Conversation.defaultTitle ? "" : item.title
        renaming = true
        nameFocused = true
    }

    private var isSupervisor: Bool { spot?.place == .supervisor }
    /// A chat the board names: a task's, or the supervisor's.
    private var named: Bool { task != nil || isSupervisor }

    /// What it is called: a task's chat by its task, as the task is called now.
    private var name: String {
        if let task { return task.title }
        return isSupervisor ? "Supervisor" : item.title
    }

    /// Opens it. A task's chat beside the board also opens its task.
    private func open() {
        app.openConversation(item.id)
        if let task, app.advancedMode { Advanced.shared.selectedItem = task.id }
    }

    /// Shows its task on the board.
    private func showTask(_ task: WorkItem) {
        app.setAdvanced(true)
        Advanced.shared.selectedItem = task.id
    }

    /// How its task stands, at the end of the row, when nothing is going
    /// on in the chat itself.
    @ViewBuilder
    private var standing: some View {
        if let need = spot?.need, need != .answer {
            let mark: (icon: String, tint: Color, help: String) = {
                switch need {
                case .review: return ("checkmark.seal", Theme.amber, "A finished run waits for your review on the board")
                case .redo: return ("arrow.uturn.backward.circle", Theme.amber,
                                    "The review asked for changes: start it again from the board")
                case .stopped: return ("exclamationmark.triangle.fill", Theme.rose,
                                       "Its last run stopped before the task was done")
                case .merge: return ("arrow.triangle.merge", Theme.amber,
                                     "Its work is approved but could not be merged: see why on the board")
                case .answer: return ("exclamationmark.bubble.fill", Theme.amber, "It waits for your answer")
                }
            }()
            Image(systemName: mark.icon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(mark.tint)
                .frame(width: 20, height: 20)
                .help(mark.help)
        } else if let task, Advanced.shared.reviewing.contains(task.id) {
            LoadingMark(state: .thinking, size: 12)
                .frame(width: 20, height: 20)
                .help("The supervisor is reviewing its run")
        } else if spot?.place == .running {
            Image(systemName: "clock")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.5))
                .frame(width: 20, height: 20)
                .help("It will be started by itself: by Autopilot, or by the supervisor carrying it on")
        } else if task?.status == .done {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.mint)
                .frame(width: 20, height: 20)
                .help("Its task is done")
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if let task, !renaming {
                Text(task.key)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.ink.opacity(0.55))
                    .padding(.horizontal, 4)
                    .frame(height: 15)
                    .background(Capsule().fill(Theme.ink.opacity(0.08)))
                    .fixedSize()
            } else if isSupervisor {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
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
                Text(name)
                    .font(.system(size: 12.5, weight: isSupervisor ? .medium : .regular))
                    .foregroundStyle(Theme.ink.opacity(isCurrent ? 0.97 : 0.86))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 2)
            if hover, !renaming {
                // A chat the board names follows its task, or is the supervisor's.
                if !named { rowButton("pencil", help: "Rename") { startRenaming() } }
                rowButton("trash", help: "Delete this conversation…") { deleting = true }
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
            } else if spot != nil, spot?.need != nil || spot?.place == .running || task?.status == .done {
                standing
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
        .padding(.leading, indent)
        // The details that used to sit under the title, a pointer away.
        .help("\(item.title)\n\(item.turnCount) \(item.turnCount == 1 ? "turn" : "turns") · \(item.updatedAt.formatted(.relative(presentation: .named))) · \(ContextUse.short(item.tokens)) tokens")
        .contentShape(Rectangle())
        .onTapGesture {
            if !renaming { open() }
        }
        .onHover { hover = $0 }
        .contextMenu {
            if let task {
                Button("Show Its Task on the Board") { showTask(task) }
            } else if !isSupervisor {
                Button("Rename") { startRenaming() }
            }
            // Your own chats are put away by hand; the board's follow their work.
            if spot != nil, !named, spot?.task == nil {
                Button(item.archivedAt == nil ? "Archive" : "Put Back on the List") {
                    app.setArchived(item.id, item.archivedAt == nil)
                }
            }
            Button("Delete…", role: .destructive) { deleting = true }
        }
        .confirmationDialog("Delete \"\(item.title)\"?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { app.deleteConversation(item.id) }
            Button("Cancel", role: .cancel) { deleting = false }
        } message: {
            Text(deletionMessage)
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
