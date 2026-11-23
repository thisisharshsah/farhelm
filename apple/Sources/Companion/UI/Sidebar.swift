import CompanionBoard
import SwiftUI

/// The sidebar of conversations, in Companion's own style: a search field
/// with the main action, then the projects and the recent chats.
/// A project is one line: a click opens its page in the chat's panel
/// (`ProjectHomeView`), where its chats are placed the way its work stands.
/// Under the projects come the recent chats: those in no project and your
/// own in every project, tagged with its name, newest first, the open one
/// edged in purple. A task's chat and the supervisor's are on the project's
/// page and its board. Used both floating (on hover) and pinned beside the
/// chat.
struct SidebarView: View {
    @EnvironmentObject var app: AppState
    /// Watched for projects that are off the list with their boards and
    /// chats still here, which the list offers to bring back, and for
    /// where each project's chats are placed.
    @ObservedObject private var advanced = Advanced.shared
    /// The project whose page is showing, if one is.
    @ObservedObject private var home = ProjectHome.shared
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

    /// The recent chats: those in no project on the list, and your own in
    /// every project (not a task's, not the supervisor's, not one put
    /// away; those are on the project's page), newest first.
    private var recents: [ConversationSummary] {
        let listed = Set(app.projects.map(\.id))
        return app.history.filter { item in
            guard let project = item.projectID, listed.contains(project) else { return true }
            let place = advanced.spot(of: item, in: project).place
            return place == .mine || place == .older
        }
    }

    /// The name of the project a chat is in, for the tag on its row.
    private func projectName(of item: ConversationSummary) -> String? {
        guard let id = item.projectID else { return nil }
        return app.projects.first { $0.id == id }?.name
    }

    /// The recent chats, grouped by recency. A search shows one flat list
    /// of everything that matches, wherever it is.
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
        for item in recents {
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
        let buckets = sections
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
                // The projects, one line each, then the recent chats,
                // newest first: one line a chat.
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
                            ProjectLine(project: project)
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
                        if !buckets.isEmpty {
                            Text("Recents")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.ink.opacity(0.5))
                                .padding(.horizontal, 4)
                                .padding(.top, 10)
                                .padding(.bottom, 2)
                        }
                    }
                    ForEach(buckets) { section in
                        ForEach(section.items) { item in
                            // While a project's page shows, no chat is the open one.
                            SidebarRow(item: item, isCurrent: item.id == app.conversation.id && home.projectID == nil,
                                       projectName: projectName(of: item))
                        }
                    }
                    // Nothing at all, or nothing found: when every chat is a
                    // task's or put away, this part stays empty without a word.
                    if buckets.isEmpty, app.history.isEmpty {
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
        .onAppear { advanced.lookForLostProjects() }
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

/// One project, on one line: its name, and how many of its chats need you
/// or that one of them is running. A click opens the project's page in the
/// chat's panel (`ProjectHomeView`), where its chats are; the line of the
/// page that is showing is shaded like the open chat. A new chat in it,
/// rename, change folder and remove are in its menu (right-click).
/// Removing asks first, takes it off the list only, and is undone by
/// adding its folder again.
private struct ProjectLine: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var advanced = Advanced.shared
    @ObservedObject private var home = ProjectHome.shared
    let project: Project
    @State private var hover = false
    @State private var renaming = false
    @State private var newName = ""
    /// Asked whether to take it off the list.
    @State private var removing = false
    @FocusState private var nameFocused: Bool

    private func startRenaming() {
        newName = project.name
        renaming = true
        nameFocused = true
    }

    private func open() {
        app.showSettings = false
        home.show(project.id)
    }

    /// How many of its chats wait on you: a task that needs you, or one of
    /// your own chats where an agent asks something.
    private func needing(_ chats: [ConversationSummary]) -> Int {
        let waiting = app.chatsWaiting
        return chats.filter { chat in
            waiting.contains(chat.id) || advanced.spot(of: chat, in: project.id).place == .needsYou
        }.count
    }

    var body: some View {
        let chats = app.chats(in: project)
        let needs = needing(chats)
        let working = chats.contains { app.jobs[$0.id] != nil }
        let showing = home.projectID == project.id
        HStack(spacing: 7) {
            Image(systemName: showing ? "folder.fill" : "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(showing ? Theme.accent : Theme.ink.opacity(0.55))
                .frame(width: 14)
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
                    .foregroundStyle(Theme.ink.opacity(showing ? 0.97 : 0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 2)
            if needs > 0 {
                Text("\(needs)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.amber)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill(Theme.amber.opacity(0.16)))
                    .help(needs == 1 ? "1 chat here needs you" : "\(needs) chats here need you")
            } else if working {
                LoadingMark(state: .working, size: 12)
                    .frame(width: 20, height: 20)
                    .help("A task is running in one of this project's chats")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .fill(Theme.ink.opacity(showing ? 0.11 : (hover ? 0.06 : 0))))
        .help((project.folder ?? "No folder") + "\nClick to open the project. Right-click for more.")
        .contentShape(Rectangle())
        .onTapGesture {
            if !renaming { open() }
        }
        .onHover { hover = $0 }
        // Its board is read, so its chats can be counted by it.
        .onAppear { advanced.prepareChats(of: project) }
        .contextMenu {
            Button("Open") { open() }
            Button("New Chat in This Project") { app.newConversation(in: project.id) }
            Divider()
            Button("Rename") { startRenaming() }
            Button("Change Folder…") { app.changeProjectFolder(project.id) }
            Button("Remove from Projects…", role: .destructive) { removing = true }
        }
        .confirmationDialog("Take \(project.name) off the Projects list?", isPresented: $removing,
                            titleVisibility: .visible) {
            Button("Remove from Projects", role: .destructive) {
                if showing { home.close() }
                app.removeProject(project.id)
            }
            Button("Cancel", role: .cancel) { removing = false }
        } message: {
            Text("Its chats, its board and its folder are kept. Add the folder again and the project is back as it was.")
        }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// One conversation, as a card in Companion's style: its name and when it
/// was last used. The open one carries the purple edge. Rename and delete
/// show while the pointer is on the row. Deleting asks first: the buttons
/// sit where a click to open the chat can land, and a deleted chat does
/// not come back. On a project's page, a task's chat is named after its
/// task, with the task's key in front and how the task stands at the end;
/// the supervisor's chat is "Supervisor". Among the recent chats, one in a
/// project carries the project's name.
struct SidebarRow: View {
    @EnvironmentObject var app: AppState
    let item: ConversationSummary
    let isCurrent: Bool
    /// Where it is listed in its project, and its task as the board has it.
    var spot: ChatShelf.Spot? = nil
    var task: WorkItem? = nil
    /// When it was last used, at the end of the row while nothing else is
    /// shown there (on a project's page, which has the room).
    var showsTime = false
    /// The project it is in, as a tag, among the recent chats.
    var projectName: String? = nil
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
        ProjectHome.shared.close()
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
                .help(Advanced.shared.checkingWork.contains(task.id) ? "Its checks are running on its work"
                      : "The supervisor is reviewing its run")
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
            if let projectName, !hover, !renaming {
                Text(projectName)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 5)
                    .frame(height: 15)
                    .background(Capsule().fill(Theme.ink.opacity(0.08)))
                    .frame(maxWidth: 90, alignment: .trailing)
                    .help("In \(projectName)")
            }
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
            } else if showsTime {
                Text(item.updatedAt.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.42))
                    .lineLimit(1)
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
