import AppKit
import SwiftUI

/// Folders and files left out of the workspace's lists: version control,
/// dependencies and build output.
let workspaceHiddenNames: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".DS_Store", "dist",
                                         "__pycache__", ".venv", "venv", "target", ".next"]

// MARK: - Model

/// The workspace beside the chat: the folder's files, an editor, search,
/// the history of changes, and a terminal. It holds what each of those is
/// showing, so the column can be closed and opened again without losing
/// your place.
@MainActor
final class WorkspaceModel: ObservableObject {
    /// The tabs of the panel along the bottom. What is being worked on (a
    /// file, a comparison) is above it; these are the tools around it.
    enum Tab: String, CaseIterable, Identifiable {
        case terminal = "Terminal"
        case search = "Search"
        case changes = "Changes"
        /// The repository: what changed, commits and branches.
        case source = "Git"
        /// Errors and warnings from the build, by place.
        case problems = "Problems"
        /// The folder's files, when there is no room for them at the side.
        case files = "Files"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .terminal: return "terminal"
            case .files: return "folder"
            case .search: return "magnifyingglass"
            case .changes: return "clock.arrow.circlepath"
            case .source: return "arrow.triangle.branch"
            case .problems: return "exclamationmark.triangle"
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        let path: String
        let isFolder: Bool
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }

    struct Hit: Identifiable {
        let id: Int
        let path: String
        let line: Int
        let text: String
    }

    /// The panel's tab, whether the panel is showing, and how tall it is.
    @Published var tab = Tab.terminal
    @Published var panelOpen = true
    @Published var panelHeight: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "workspacePanelHeight")
        return saved > 0 ? CGFloat(saved) : 230
    }()

    // Files
    @Published var root = ""
    @Published var expanded: Set<String> = []
    @Published private(set) var listings: [String: [Entry]] = [:]

    // Editor
    @Published var openPath: String?
    /// Every file opened and not yet closed, shown as tabs over the editor.
    @Published var openFiles: [String] = []
    @Published var text = "" {
        didSet {
            // The language server sees edits as they are typed.
            if let openPath, text != oldValue { LanguageServers.shared.changed(openPath, text: text, root: root) }
        }
    }
    @Published private(set) var saved = ""
    @Published var editorNote = ""
    /// A comparison showing where the open file would be.
    @Published var diff: DiffDocument?

    // Search
    @Published var query = ""
    @Published private(set) var hits: [Hit] = []
    @Published private(set) var searching = false
    @Published private(set) var searchNote = ""

    // Changes
    @Published var shownChange: UUID?

    // Terminal: a live shell in this folder, kept running while the
    // workspace stays on it.
    private var terminal: TerminalSession?

    var dirty: Bool { openPath != nil && text != saved }

    private static let hidden = workspaceHiddenNames

    /// Points the workspace at a folder. Opening the same one again keeps
    /// everything as it was.
    func use(root folder: String) {
        guard folder != root else { return }
        root = folder
        // The terminal belonged to the folder before this one.
        terminal?.end()
        terminal = nil
        diff = nil
        expanded = []
        listings = [:]
        hits = []
        refresh(folder)
    }

    func savePanelHeight() {
        UserDefaults.standard.set(Double(panelHeight), forKey: "workspacePanelHeight")
    }

    /// How wide the files are when they sit at the side.
    @Published var filesWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "workspaceFilesWidth")
        return saved > 0 ? CGFloat(saved) : 220
    }()

    func saveFilesWidth() {
        UserDefaults.standard.set(Double(filesWidth), forKey: "workspaceFilesWidth")
    }

    /// The files have room at the side, so they are not a tab of the panel.
    var filesAtSide = false

    /// Opens the panel on a tab.
    func showPanel(_ tab: Tab) {
        // The files are already showing at the side.
        if tab == .files, filesAtSide { return }
        self.tab = tab
        panelOpen = true
    }

    /// The folder's terminal, made the first time it is asked for.
    func terminalSession() -> TerminalSession {
        if let terminal { return terminal }
        let session = TerminalSession(folder: root)
        // What the shell changed shows in the files once it is looked away
        // from or ends.
        session.changed = { [weak self] in self?.refreshAll() }
        terminal = session
        return session
    }

    /// Shows a comparison where the open file would be.
    func showDiff(_ document: DiffDocument) {
        diff = document
    }

    /// Puts one block of a comparison back as it was, in the file itself.
    /// The file is checked first: if it changed since the comparison was
    /// made, the comparison is brought up to date instead, to look again.
    /// The undo goes into Changes like any other change, so it can be
    /// undone in turn.
    func revert(_ hunk: DiffHunk, in document: DiffDocument, conversation: UUID?) {
        guard let path = document.path,
              let current = try? String(contentsOfFile: path, encoding: .utf8) else {
            editorNote = "That file could not be read, so nothing was changed."
            return
        }
        guard current == document.after else {
            var fresh = document
            fresh.after = current
            diff = fresh
            editorNote = "The file had changed since; the comparison is up to date now. Try again."
            return
        }
        let updated = hunk.revert(before: document.before, after: current)
        let before = ChangeStore.shared.snapshot(path)
        do {
            try updated.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            editorNote = "Could not write \((path as NSString).lastPathComponent): \(error.localizedDescription)"
            return
        }
        _ = ChangeStore.shared.record(path: path, before: before,
                                      task: "Undid one change in \((path as NSString).lastPathComponent)",
                                      conversation: conversation)
        reloadIfOpen(path)
        var fresh = document
        fresh.after = updated
        diff = fresh
        editorNote = ""
    }

    // MARK: Files

    /// What is known to be in a folder. It is read from disk when the
    /// folder is opened or refreshed, never while the list is being drawn.
    func children(of folder: String) -> [Entry] {
        listings[folder] ?? []
    }

    func refresh(_ folder: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        var entries: [Entry] = []
        for name in names where !Self.hidden.contains(name) {
            let path = (folder as NSString).appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else { continue }
            entries.append(Entry(path: path, isFolder: isFolder.boolValue))
        }
        entries.sort {
            $0.isFolder != $1.isFolder ? $0.isFolder : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        listings[folder] = Array(entries.prefix(600))
    }

    func refreshAll() {
        for folder in Array(listings.keys) { refresh(folder) }
    }

    func toggle(_ folder: String) {
        if expanded.contains(folder) {
            expanded.remove(folder)
        } else {
            expanded.insert(folder)
            refresh(folder)
        }
    }

    // MARK: Editor

    /// A line to bring into view and select in the open file. Each ask is
    /// its own, so asking for the same line twice still moves there.
    struct Reveal: Equatable {
        let line: Int
        let id = UUID()
    }
    @Published var reveal: Reveal?

    /// Opens a file at a line, as a problem or a search result points to.
    func open(_ path: String, line: Int) {
        open(path)
        guard openPath == path else { return }
        reveal = Reveal(line: max(1, line))
    }

    func open(_ path: String) {
        // A file takes the place of a comparison.
        diff = nil
        editorNote = ""
        guard let data = FileManager.default.contents(atPath: path) else {
            editorNote = "That file could not be read."
            return
        }
        guard data.count < 2_000_000, !data.prefix(4096).contains(0), let content = String(data: data, encoding: .utf8) else {
            editorNote = "\((path as NSString).lastPathComponent) is not a text file, or is too large to edit here."
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return
        }
        LanguageServers.shared.opened(path, text: content, root: root)
        openPath = path
        if !openFiles.contains(path) { openFiles.append(path) }
        text = content
        saved = content
    }

    /// Opens several files at once: each gets a tab, and the last is shown.
    func open(all paths: [String], conversation: UUID?) {
        for path in paths {
            if dirty { save(conversation: conversation) }
            open(path)
        }
    }

    /// Moves to another open file's tab, keeping edits to the one being left.
    func switchTo(_ path: String, conversation: UUID?) {
        guard path != openPath else { return }
        if dirty { save(conversation: conversation) }
        open(path)
    }

    /// Closes one tab. Closing the file being shown moves to its neighbour.
    func close(_ path: String, conversation: UUID?) {
        guard let index = openFiles.firstIndex(of: path) else { return }
        if path == openPath, dirty { save(conversation: conversation) }
        openFiles.remove(at: index)
        guard path == openPath else { return }
        if openFiles.isEmpty {
            closeFile()
        } else {
            open(openFiles[min(index, openFiles.count - 1)])
        }
    }

    func closeFile() {
        openPath = nil
        text = ""
        saved = ""
        editorNote = ""
    }

    /// Saves the open file. The save goes into the history like any other
    /// change, so it can be undone from Changes.
    func save(conversation: UUID?) {
        guard let path = openPath, dirty else { return }
        let before = ChangeStore.shared.snapshot(path)
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            saved = text
            editorNote = "Saved"
            LanguageServers.shared.saved(path, root: root)
            ChangeStore.shared.record(path: path, before: before, task: "Edited by you", conversation: conversation)
            Task { await ChangeStore.shared.commitPending(message: "edit \((path as NSString).lastPathComponent)") }
        } catch {
            editorNote = "Could not save: \(error.localizedDescription)"
        }
    }

    /// The open file changed on disk (an undo, the agent): show what is there now.
    func reloadIfOpen(_ path: String) {
        guard openPath == path, !dirty else { return }
        open(path)
    }

    func relative(_ path: String) -> String {
        guard !root.isEmpty, path.hasPrefix(root) else { return (path as NSString).abbreviatingWithTildeInPath }
        let rest = String(path.dropFirst(root.count))
        return rest.hasPrefix("/") ? String(rest.dropFirst()) : rest
    }

    // MARK: Search

    func search() {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty, !root.isEmpty, !searching else { return }
        searching = true
        searchNote = ""
        let folder = root
        Task {
            // Plain text, not a pattern; the usual junk folders are left out.
            let skip = Self.hidden.map { "--exclude-dir=\(Shell.quote($0))" }.joined(separator: " ")
            let result = await Shell.run("grep -rnIF \(skip) -e \(Shell.quote(wanted)) . | head -n 300", in: folder, timeout: 30)
            var found: [Hit] = []
            for row in result.output.split(separator: "\n") {
                let parts = row.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, let line = Int(parts[1]) else { continue }
                var path = String(parts[0])
                if path.hasPrefix("./") { path.removeFirst(2) }
                found.append(Hit(id: found.count, path: (folder as NSString).appendingPathComponent(path), line: line,
                                 text: String(parts[2].prefix(240)).trimmingCharacters(in: .whitespaces)))
            }
            hits = found
            searchNote = found.isEmpty ? "Nothing found for \"\(wanted)\"."
                : (found.count >= 300 ? "The first 300 matches." : "\(found.count) match\(found.count == 1 ? "" : "es").")
            searching = false
        }
    }

}

// MARK: - Views

/// The workspace column: tabs along the top, and the tab's content below.
struct WorkspacePane: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if app.hasWorkFolder || app.workspace.diff != nil || app.workspace.openPath != nil {
            WorkspaceBody(model: app.workspace, history: ChangeStore.shared)
                .onAppear {
                    app.workspace.use(root: app.workspaceRoot)
                    GitModel.shared.use(folder: app.workspaceRoot)
                }
                .onChange(of: app.workspaceRoot) { _, root in
                    app.workspace.use(root: root)
                    GitModel.shared.use(folder: root)
                }
        } else {
            // A code chat with no repository yet: nothing to show until
            // one is chosen. Sending a message asks for it too.
            VStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("Choose a repository")
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.ink.opacity(0.95))
                Text("Code chats work in a folder: its files, search, changes and terminal show here, and the agent keeps its work inside it.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 260)
                Button {
                    app.pickWorkFolder()
                } label: {
                    Text("Choose folder")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.82))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.accentGradient))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct WorkspaceBody: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var history: ChangeStore
    /// The repository the folder is in, for the branch on its tab.
    @ObservedObject private var git = GitModel.shared
    /// The build's errors and warnings, for the tab and the status bar.
    @ObservedObject private var problems = ProblemsModel.shared

    /// How wide and tall the pane is: whether the files fit at the side,
    /// and how much of it the panel may take.
    @State private var paneWidth: CGFloat = 0
    @State private var paneHeight: CGFloat = 600
    /// Wide enough to work like an editor: files on the left, always
    /// there, and what is open beside them.
    private var split: Bool { paneWidth >= 560 }
    /// The files' width, never so wide that what is open has no room.
    private var filesShown: CGFloat {
        min(max(model.filesWidth, 150), max(150, paneWidth - 320))
    }

    var body: some View {
        HStack(spacing: 0) {
            if split {
                FilesTab(model: model, part: .tree)
                    .frame(width: filesShown)
                // Drag to give the files more or less room.
                ColumnDivider(width: { filesShown },
                              direction: 1,
                              resize: { model.filesWidth = min(max($0, 150), max(150, paneWidth - 320)) },
                              reset: { model.filesWidth = 220 },
                              done: { model.saveFilesWidth() })
            }
            // What is being worked on, with the panel of tools under it.
            VStack(spacing: 0) {
                document
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if model.panelOpen {
                    RowDivider(height: { panelShown },
                               resize: { model.panelHeight = min(max($0, 120), max(120, paneHeight - 150)) },
                               reset: { model.panelHeight = 230 },
                               done: { model.savePanelHeight() })
                    panel
                        .frame(height: panelShown)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                WorkspaceStatusBar(model: model)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: model.panelOpen)
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        paneWidth = geometry.size.width
                        paneHeight = geometry.size.height
                        model.filesAtSide = geometry.size.width >= 560
                        if model.filesAtSide, model.tab == .files { model.tab = .terminal }
                    }
                    .onChange(of: geometry.size.width) { _, width in
                        if abs(width - paneWidth) > 0.5 { paneWidth = width }
                    }
                    .onChange(of: geometry.size.height) { _, height in
                        if abs(height - paneHeight) > 0.5 { paneHeight = height }
                    }
            }
        }
        // With the files at the side there is no Files tab to be on.
        .onChange(of: split) { _, wide in
            model.filesAtSide = wide
            if wide, model.tab == .files { model.tab = .terminal }
        }
    }

    /// The panel's height: what was chosen, as far as the pane allows.
    private var panelShown: CGFloat {
        min(max(model.panelHeight, 120), max(120, paneHeight - 150))
    }

    /// The panel's tabs: the files are one of them only when they have no
    /// room at the side.
    private var tabs: [WorkspaceModel.Tab] {
        WorkspaceModel.Tab.allCases.filter { $0 != .files || !split }
    }

    /// The tab row is short of room.
    private var tabsCompact: Bool {
        (split ? paneWidth - 221 : paneWidth) < 440
    }

    /// A tab's name. The repository's tab carries the branch.
    private func title(of tab: WorkspaceModel.Tab) -> String {
        tab == .source && !git.branch.isEmpty ? git.branch : tab.rawValue
    }

    /// The top of the pane: what is open, and the pane's own controls.
    private var bar: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.accent)
            Text((model.root as NSString).lastPathComponent)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.9))
                .lineLimit(1)
                .help(model.root)
            Spacer(minLength: 4)
            IconButton("rectangle.bottomthird.inset.filled",
                       help: model.panelOpen ? "Hide the panel (terminal, search, changes, git)" : "Show the panel",
                       tint: model.panelOpen ? Theme.accent : nil) {
                model.panelOpen.toggle()
            }
            FullToggle()
            IconButton("xmark", help: "Close the workspace") { app.showSide(nil) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    /// What is being worked on: a comparison, or the open file. In a
    /// narrow pane the files are here too, until one is opened.
    private var document: some View {
        VStack(spacing: 0) {
            bar
            Rectangle()
                .fill(Theme.ink.opacity(0.09))
                .frame(height: 1)
            if let diff = model.diff {
                DiffPane(document: diff,
                         open: diff.path.map { path -> (() -> Void) in { model.open(path) } },
                         close: { model.diff = nil },
                         revert: diff.path == nil ? nil : { hunk in
                             model.revert(hunk, in: diff, conversation: app.conversation.id)
                         })
            } else {
                FilesTab(model: model, part: .editor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    /// The tools around the work, along the bottom: terminal, search, the
    /// history of changes and the repository.
    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(tabs) { tab in
                    let on = model.tab == tab
                    Button {
                        model.tab = tab
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 10, weight: .semibold))
                            // With little room, only the tab in use is
                            // spelled out.
                            if on || !tabsCompact {
                                Text(title(of: tab))
                                    .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 110)
                                    .fixedSize()
                            }
                            // How many errors the last build found.
                            if tab == .problems, problems.root == model.root, problems.errors + problems.warnings > 0 {
                                Text("\(problems.errors + problems.warnings)")
                                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(problems.errors > 0 ? Theme.rose : Theme.amber)
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 15, minHeight: 15)
                                    .background(Capsule().fill((problems.errors > 0 ? Theme.rose : Theme.amber).opacity(0.2)))
                            }
                            // How many files git sees a change in.
                            if tab == .source, git.count > 0 {
                                Text("\(git.count)")
                                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 15, minHeight: 15)
                                    .background(Capsule().fill(Theme.accent.opacity(0.22)))
                            }
                        }
                        .foregroundStyle(on ? Theme.accent : Theme.ink.opacity(0.66))
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(Capsule().fill(on ? Theme.accent.opacity(0.16) : Color.clear))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 4)
                IconButton("chevron.down", help: "Hide the panel (⌃`)") { model.panelOpen = false }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Rectangle()
                .fill(Theme.ink.opacity(0.09))
                .frame(height: 1)
            Group {
                switch model.tab {
                case .terminal: TerminalPane(model: model)
                case .files: FilesTab(model: model, part: .tree)
                case .search: SearchTab(model: model)
                case .changes: ChangesTab(model: model, history: history)
                case .source: SourceTab(model: model, git: git)
                case .problems: ProblemsTab(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .liquidGlass(in: Rectangle())
    }
}

func workspaceNote(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.ink.opacity(0.5))
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
}

// MARK: - Files and the editor

private struct FilesTab: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: WorkspaceModel
    /// Watched so the editor follows the content zoom.
    @ObservedObject private var settings = AppSettings.shared
    /// Watched so the lines with problems are marked.
    @ObservedObject private var problems = ProblemsModel.shared
    /// Which part to show. In a narrow pane one view is both: the files,
    /// then the file that is opened. In a wide one they sit side by side.
    enum Part { case both, tree, editor }
    var part: Part = .both

    var body: some View {
        switch part {
        case .tree:
            tree
        case .editor:
            if let path = model.openPath {
                editor(path)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Theme.ink.opacity(0.35))
                    Text("Open a file from the list, or press ⌘P to go to one by name.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .both:
            if let path = model.openPath {
                editor(path)
            } else {
                tree
            }
        }
    }

    private var tree: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.accent)
                Text((model.root as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                IconButton("folder.badge.gearshape", help: "Work in a different folder") { app.pickWorkFolder() }
                IconButton("doc.on.doc", help: "Open several files at once, each in a tab") { app.pickFilesToOpen() }
                IconButton("arrow.clockwise", help: "Look again for new files") { model.refreshAll() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .help("The folder attached to this chat, or the agent's working folder when none is.")
            if !model.editorNote.isEmpty {
                workspaceNote(model.editorNote)
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    rows(in: model.root, depth: 0)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
        }
    }

    /// A folder's entries, with those of every open folder under it.
    private func rows(in folder: String, depth: Int) -> AnyView {
        AnyView(ForEach(model.children(of: folder)) { entry in
            FileRow(entry: entry, depth: depth, open: model.expanded.contains(entry.path)) {
                if entry.isFolder { model.toggle(entry.path) } else { model.switchTo(entry.path, conversation: app.conversation.id) }
            }
            if entry.isFolder, model.expanded.contains(entry.path), depth < 12 {
                rows(in: entry.path, depth: depth + 1)
            }
        })
    }

    /// The open files, one tab each, shown when more than one is open.
    private func tabs(_ current: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(model.openFiles, id: \.self) { file in
                    HStack(spacing: 4) {
                        Text((file as NSString).lastPathComponent)
                            .font(.system(size: 11, weight: file == current ? .semibold : .regular))
                            .foregroundStyle(Theme.ink.opacity(file == current ? 0.95 : 0.6))
                            .lineLimit(1)
                        if file == current, model.dirty {
                            Circle().fill(Theme.amber).frame(width: 5, height: 5)
                        }
                        Button {
                            model.close(file, conversation: app.conversation.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.ink.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                        .help("Close this file")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.ink.opacity(file == current ? 0.1 : 0)))
                    .contentShape(Rectangle())
                    .onTapGesture { model.switchTo(file, conversation: app.conversation.id) }
                    .help(model.relative(file))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        }
    }

    private func editor(_ path: String) -> some View {
        VStack(spacing: 0) {
            if model.openFiles.count > 1 {
                tabs(path)
                Rectangle()
                    .fill(Theme.ink.opacity(0.07))
                    .frame(height: 1)
            }
            HStack(spacing: 6) {
                IconButton(part == .editor ? "xmark" : "chevron.left",
                           help: part == .editor ? "Close this file" : "Back to the files") {
                    if part == .editor {
                        model.close(path, conversation: app.conversation.id)
                    } else {
                        model.closeFile()
                    }
                }
                Text(model.relative(path))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.head)
                if model.dirty {
                    Circle().fill(Theme.amber).frame(width: 6, height: 6)
                        .help("Not saved yet")
                } else if !model.editorNote.isEmpty {
                    Text(model.editorNote)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button {
                    model.save(conversation: app.conversation.id)
                } label: {
                    Text("Save")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.dirty ? Color.black.opacity(0.82) : Theme.ink.opacity(0.4))
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background(Capsule().fill(model.dirty ? Theme.accent : Theme.ink.opacity(0.07)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!model.dirty)
                .keyboardShortcut("s", modifiers: .command)
                .help("Save (Cmd+S). A save goes into Changes, so it can be undone.")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            Rectangle()
                .fill(Theme.ink.opacity(0.07))
                .frame(height: 1)
            CodeEditor(text: $model.text, language: (path as NSString).pathExtension.lowercased(),
                       zoom: settings.contentZoom,
                       marks: problems.marks(in: path),
                       reveal: model.reveal,
                       path: path,
                       root: model.root,
                       goTo: { file, line in
                           // Same file: just go there, keeping what is typed.
                           if file == model.openPath {
                               model.reveal = WorkspaceModel.Reveal(line: line)
                           } else {
                               if model.dirty { model.save(conversation: app.conversation.id) }
                               model.open(file, line: line)
                           }
                       })
                .id(path)
        }
    }
}

private struct FileRow: View {
    let entry: WorkspaceModel.Entry
    let depth: Int
    let open: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: entry.isFolder ? (open ? "chevron.down" : "chevron.right") : "circle.fill")
                .font(.system(size: entry.isFolder ? 7.5 : 2.5, weight: .bold))
                .foregroundStyle(Theme.ink.opacity(0.4))
                .frame(width: 10)
            Image(systemName: entry.isFolder ? "folder" : Self.icon(for: entry.name))
                .font(.system(size: 10.5))
                .foregroundStyle(entry.isFolder ? Theme.accent.opacity(0.9) : Theme.ink.opacity(0.55))
                .frame(width: 15)
            Text(entry.name)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 12 + 4)
        .padding(.trailing, 4)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.ink.opacity(hover ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            }
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.path, forType: .string)
            }
        }
    }

    private static func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift", "py", "js", "ts", "tsx", "jsx", "rs", "go", "c", "h", "cpp", "java", "kt", "rb", "sh", "zsh":
            return "chevron.left.forwardslash.chevron.right"
        case "md", "txt", "rtf": return "doc.text"
        case "json", "yaml", "yml", "toml", "plist", "xml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg", "heic", "icns": return "photo"
        default: return "doc"
        }
    }
}

/// A plain code editor: monospaced, no wrapping surprises, with comments,
/// strings, numbers and common keywords colored.
private struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let language: String
    /// The content zoom: the code's size follows it.
    var zoom: Double = 1
    /// Lines the build has errors or warnings on, tinted.
    var marks: [Int: Problem.Severity] = [:]
    /// A line to scroll to and select.
    var reveal: WorkspaceModel.Reveal?
    /// The file and its folder, for the language server.
    var path = ""
    var root = ""
    /// Opens a file at a line: where go to definition leads.
    var goTo: ((String, Int) -> Void)? = nil

    var font: NSFont { NSFont.monospacedSystemFont(ofSize: 11.5 * zoom, weight: .regular) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.font = font
        view.textColor = NSColor(Theme.ink.opacity(0.92))
        view.insertionPointColor = NSColor(Theme.accent)
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.string = text
        context.coordinator.view = view
        context.coordinator.color()
        context.coordinator.show(reveal)
        context.coordinator.install()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let resized = abs(context.coordinator.parent.zoom - zoom) > 0.001
        let remarked = context.coordinator.parent.marks != marks
        context.coordinator.parent = self
        if view.string != text {
            // The file changed from outside (an undo, a reload).
            view.string = text
            context.coordinator.color()
        } else if resized || remarked {
            context.coordinator.color()
        }
        context.coordinator.show(reveal)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var view: NSTextView?
        private var pending: Task<Void, Never>?

        init(_ parent: CodeEditor) { self.parent = parent }
        private var shown: UUID?

        // MARK: Language server: hover and go to definition

        private var monitor: Any?
        private var hoverTask: Task<Void, Never>?
        private var popover: NSPopover?
        private var lastHover = -1

        /// Watches the pointer over the text (hover), and F12 and
        /// Cmd-click (go to definition).
        func install() {
            guard let view, monitor == nil else { return }
            view.addTrackingArea(NSTrackingArea(rect: .zero,
                                                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                owner: self, userInfo: nil))
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
                guard let self, let view = self.view, event.window === view.window else { return event }
                if event.type == .keyDown, event.keyCode == 111, view.window?.firstResponder === view {
                    self.goToDefinition(at: view.selectedRange().location)
                    return nil
                }
                if event.type == .leftMouseDown, event.modifierFlags.contains(.command) {
                    let point = view.convert(event.locationInWindow, from: nil)
                    guard view.visibleRect.contains(point), let index = self.index(at: point) else { return event }
                    self.goToDefinition(at: index)
                    return nil
                }
                return event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            hoverTask?.cancel()
            popover?.close()
        }

        /// The character under a point in the text view, if any.
        private func index(at point: NSPoint) -> Int? {
            guard let view, let layout = view.layoutManager, let container = view.textContainer else { return nil }
            let inner = NSPoint(x: point.x - view.textContainerOrigin.x, y: point.y - view.textContainerOrigin.y)
            var fraction: CGFloat = 0
            let index = layout.characterIndex(for: inner, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
            return index < (view.string as NSString).length ? index : nil
        }

        /// Line and column from 0, the column in UTF-16 units as LSP counts.
        private static func position(of index: Int, in text: NSString) -> (line: Int, character: Int) {
            var line = 0
            var lineStart = 0
            var i = 0
            while i < index {
                if text.character(at: i) == 10 {
                    line += 1
                    lineStart = i + 1
                }
                i += 1
            }
            return (line, index - lineStart)
        }

        private static func isWord(_ unit: unichar) -> Bool {
            guard let scalar = UnicodeScalar(unit) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || unit == 95
        }

        @objc func mouseMoved(with event: NSEvent) {
            guard let view, !parent.root.isEmpty, !parent.path.isEmpty else { return }
            let point = view.convert(event.locationInWindow, from: nil)
            let found = index(at: point) ?? -1
            guard found != lastHover else { return }
            lastHover = found
            hoverTask?.cancel()
            popover?.close()
            popover = nil
            let text = view.string as NSString
            guard found >= 0, Self.isWord(text.character(at: found)) else { return }
            // Resting on a word for a moment asks the server about it.
            hoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard let self, !Task.isCancelled else { return }
                let place = Self.position(of: found, in: text)
                guard let info = await LanguageServers.shared.hover(self.parent.path, line: place.line,
                                                                    character: place.character, root: self.parent.root),
                      !info.isEmpty, !Task.isCancelled, self.lastHover == found else { return }
                self.showHover(info, at: found)
            }
        }

        @objc func mouseExited(with event: NSEvent) {
            hoverTask?.cancel()
            lastHover = -1
        }

        private func showHover(_ info: String, at index: Int) {
            guard let view, let layout = view.layoutManager, let container = view.textContainer else { return }
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += view.textContainerOrigin.x
            rect.origin.y += view.textContainerOrigin.y
            let cleaned = info
                .components(separatedBy: "\n")
                .filter { !$0.hasPrefix("```") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pop = NSPopover()
            pop.behavior = .transient
            pop.animates = false
            pop.contentViewController = NSHostingController(rootView: HoverCard(text: cleaned))
            pop.show(relativeTo: rect, of: view, preferredEdge: .maxY)
            popover = pop
        }

        private func goToDefinition(at index: Int) {
            guard let view, !parent.root.isEmpty, !parent.path.isEmpty else { return }
            let place = Self.position(of: index, in: view.string as NSString)
            popover?.close()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let found = await LanguageServers.shared.definition(self.parent.path, line: place.line,
                                                                       character: place.character, root: self.parent.root) {
                    self.parent.goTo?(found.path, found.line)
                } else {
                    NSSound.beep()
                }
            }
        }

        /// Scrolls to a line and selects it, once per ask.
        func show(_ reveal: WorkspaceModel.Reveal?) {
            guard let reveal, reveal.id != shown, let view else { return }
            shown = reveal.id
            let text = view.string as NSString
            var location = 0
            var line = 1
            while line < reveal.line, location < text.length {
                let range = text.lineRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(range)
                line += 1
            }
            let target = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
            // After the view has laid out, so the scroll lands.
            DispatchQueue.main.async {
                view.setSelectedRange(target)
                view.scrollRangeToVisible(target)
                view.showFindIndicator(for: target)
                view.window?.makeFirstResponder(view)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            parent.text = view.string
            // Coloring waits for a pause in the typing.
            pending?.cancel()
            pending = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                self?.color()
            }
        }

        private static let keywords = try? NSRegularExpression(pattern: "\\b(func|let|var|if|else|for|while|return|import|class|struct|enum|protocol|extension|switch|case|default|break|continue|guard|defer|do|try|catch|throw|throws|async|await|static|private|public|internal|final|override|init|self|nil|true|false|in|where|def|from|as|with|lambda|pass|None|True|False|function|const|export|new|this|null|undefined|typeof|interface|type|implements|extends|package|fn|impl|pub|use|mod|match|mut|void|int|float|double|bool|string)\\b")
        private static let numbers = try? NSRegularExpression(pattern: "\\b\\d[\\d_]*(\\.\\d+)?\\b")
        private static let strings = try? NSRegularExpression(pattern: "\"(\\\\.|[^\"\\\\\\n])*\"|'(\\\\.|[^'\\\\\\n])*'")
        private static let slashComments = try? NSRegularExpression(pattern: "//[^\\n]*|/\\*[\\s\\S]*?\\*/")
        private static let hashComments = try? NSRegularExpression(pattern: "#[^\\n]*")

        /// Colors the whole text. Files past a size are left plain, so
        /// typing in a large file stays quick.
        func color() {
            guard let view, let storage = view.textStorage else { return }
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: parent.font, .foregroundColor: NSColor(Theme.ink.opacity(0.92))], range: whole)
            view.font = parent.font
            if storage.length < 200_000, !["txt", "md", "log", ""].contains(parent.language) {
                let text = storage.string
                func paint(_ regex: NSRegularExpression?, _ color: Color) {
                    regex?.enumerateMatches(in: text, range: whole) { match, _, _ in
                        if let range = match?.range {
                            storage.addAttribute(.foregroundColor, value: NSColor(color), range: range)
                        }
                    }
                }
                paint(Self.keywords, Theme.accent)
                paint(Self.numbers, Theme.amber)
                paint(Self.strings, Theme.mint)
                let hash = ["py", "sh", "zsh", "bash", "rb", "yaml", "yml", "toml"].contains(parent.language)
                paint(hash ? Self.hashComments : Self.slashComments, Theme.ink.opacity(0.45))
            }
            // Lines the build complains about, tinted the whole way across.
            if !parent.marks.isEmpty {
                let text = storage.string as NSString
                var location = 0
                var line = 1
                while location < text.length {
                    let range = text.lineRange(for: NSRange(location: location, length: 0))
                    if let severity = parent.marks[line] {
                        let tint = severity == .error ? Theme.rose : Theme.amber
                        storage.addAttribute(.backgroundColor, value: NSColor(tint.opacity(0.18)), range: range)
                    }
                    location = NSMaxRange(range)
                    line += 1
                }
            }
            storage.endEditing()
        }
    }
}

// MARK: - Search

private struct SearchTab: View {
    @ObservedObject var model: WorkspaceModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.5))
                TextField("Search in files", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink.opacity(0.95))
                    .focused($focused)
                    .onSubmit { model.search() }
                if model.searching {
                    LoadingMark(state: .working, size: 14)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(Theme.ink.opacity(0.07)))
            .overlay(Capsule().strokeBorder((focused ? Theme.accent : Theme.ink).opacity(focused ? 0.5 : 0.1), lineWidth: 0.75))
            .padding(8)
            if !model.searchNote.isEmpty {
                Text(model.searchNote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.5))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            } else if model.hits.isEmpty {
                workspaceNote("Type the text to look for and press Return. It searches every text file in the folder.")
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.hits) { hit in
                        HitRow(hit: hit, name: model.relative(hit.path)) { model.open(hit.path, line: hit.line) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
        }
        .onAppear { focused = true }
    }
}

private struct HitRow: View {
    let hit: WorkspaceModel.Hit
    let name: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(name)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text("\(hit.line)")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink.opacity(0.45))
            }
            Text(hit.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.ink.opacity(0.82))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.ink.opacity(hover ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
    }
}

// MARK: - Changes: the history, with undo

private struct ChangesTab: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var history: ChangeStore

    /// Changes under the workspace's folder come first in mind, but the
    /// list is everything, newest first, grouped by what was being done.
    private struct Batch: Identifiable {
        let id: UUID
        let task: String
        let conversation: UUID?
        var changes: [FileChange]
    }

    private var batches: [Batch] {
        var list: [Batch] = []
        for change in history.changes.prefix(400) {
            if let last = list.last, last.task == change.task, last.conversation == change.conversation,
               abs(last.changes[0].date.timeIntervalSince(change.date)) < 1800 {
                list[list.count - 1].changes.append(change)
            } else {
                list.append(Batch(id: change.id, task: change.task, conversation: change.conversation, changes: [change]))
            }
        }
        return list
    }

    var body: some View {
        if let id = model.shownChange, let change = history.changes.first(where: { $0.id == id }) {
            ChangeDetail(change: change, model: model, history: history)
        } else if history.changes.isEmpty {
            workspaceNote("Every file the agent edits or writes, and everything you save here, is listed in this tab with the file as it was before and after. Any change can be undone, and a file can be put back as it was at any point.")
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(batches) { batch in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(batch.task)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Theme.ink.opacity(0.92))
                                    .lineLimit(2)
                                Spacer(minLength: 4)
                                Text(batch.changes[0].date.formatted(.relative(presentation: .named)))
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.ink.opacity(0.45))
                                    .fixedSize()
                            }
                            ForEach(batch.changes) { change in
                                ChangeRow(change: change, name: model.relative(change.path)) {
                                    // What to do with it shows here; the
                                    // change itself, side by side, above.
                                    model.shownChange = change.id
                                    model.showDiff(DiffDocument(
                                        title: model.relative(change.path),
                                        subtitle: change.task + "  ·  " + change.date.formatted(date: .abbreviated, time: .shortened),
                                        before: history.text(change.before),
                                        after: history.text(change.after),
                                        path: change.path))
                                }
                            }
                            if batch.changes.count > 1, batch.changes.contains(where: { $0.kind != .restored }) {
                                Button {
                                    history.undo(task: batch.task, conversation: batch.conversation)
                                    after(batch.changes.map(\.path))
                                } label: {
                                    Label("Undo all \(batch.changes.count)", systemImage: "arrow.uturn.backward")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(Theme.ink.opacity(0.7))
                                        .padding(.horizontal, 8)
                                        .frame(height: 22)
                                        .background(Capsule().fill(Theme.ink.opacity(0.07)))
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 2)
                                .help("Puts every file this task changed back as it was before the task.")
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    private func after(_ paths: [String]) {
        model.refreshAll()
        for path in paths { model.reloadIfOpen(path) }
        Task { await history.commitPending(message: "undo") }
    }
}

private struct ChangeRow: View {
    let change: FileChange
    let name: String
    let action: () -> Void
    @State private var hover = false

    private var icon: String {
        switch change.kind {
        case .created: return "plus.circle"
        case .edited: return "pencil.circle"
        case .deleted: return "minus.circle"
        case .restored: return "arrow.uturn.backward.circle"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10.5))
                .foregroundStyle(change.kind == .restored ? Theme.amber : Theme.ink.opacity(0.55))
                .frame(width: 14)
            Text(name)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if let commit = change.commit {
                Text(commit)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                    .help("Committed to git as \(commit)")
            }
            Text("+\(change.added)")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.mint)
            Text("-\(change.removed)")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.rose)
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.ink.opacity(hover ? 0.09 : 0.04)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
        .help("\(change.path)\nClick to see what changed.")
    }
}

/// One change: what was taken out and put in, with undo and "go back".
private struct ChangeDetail: View {
    let change: FileChange
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var history: ChangeStore
    @State private var note = ""

    var body: some View {
        let rows = LineDiff.rows(before: history.text(change.before), after: history.text(change.after))
        let current = history.isCurrent(change)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                IconButton("chevron.left", help: "Back to the list") { model.shownChange = nil }
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.relative(change.path))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.ink.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text(change.task + "  ·  " + change.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ink.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            HStack(spacing: 6) {
                pill("Undo this change", icon: "arrow.uturn.backward",
                     help: "Puts the file back as it was before this change.") {
                    finish(history.undo(change), "Undone.")
                }
                if !current {
                    pill("Go back to this", icon: "clock.arrow.circlepath",
                         help: "The file has changed since. This puts it back as it was right after this change.") {
                        finish(history.restore(to: change), "The file is back as it was here.")
                    }
                }
                pill("Open file", icon: "doc.text", help: "Open the file as it is now.") {
                    model.open(change.path)
                }
                if !note.isEmpty {
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.mint)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            Rectangle()
                .fill(Theme.ink.opacity(0.07))
                .frame(height: 1)
            ScrollView([.vertical, .horizontal], showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        DiffLine(row: row)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func finish(_ worked: Bool, _ message: String) {
        note = worked ? message : "That could not be done: the file could not be written."
        model.refreshAll()
        model.reloadIfOpen(change.path)
        Task { await history.commitPending(message: "undo \(change.name)") }
    }

    private func pill(_ title: String, icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.85))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(Theme.ink.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct DiffLine: View {
    let row: LineDiff.Row

    var body: some View {
        if row.kind == .gap {
            Text("···")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.ink.opacity(0.35))
                .padding(.leading, 74)
                .frame(height: 16)
        } else {
            HStack(spacing: 0) {
                Text(row.before.map { "\($0)" } ?? "")
                    .frame(width: 30, alignment: .trailing)
                Text(row.after.map { "\($0)" } ?? "")
                    .frame(width: 30, alignment: .trailing)
                Text(row.kind == .added ? "+" : (row.kind == .removed ? "-" : " "))
                    .frame(width: 16)
                Text(row.text.isEmpty ? " " : row.text)
                    .foregroundStyle(Theme.ink.opacity(row.kind == .same ? 0.7 : 0.95))
                    .fixedSize()
                    .textSelection(.enabled)
                Spacer(minLength: 12)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.ink.opacity(0.4))
            .frame(minHeight: 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(row.kind == .added ? Theme.mint.opacity(0.16)
                        : (row.kind == .removed ? Theme.rose.opacity(0.16) : Color.clear))
        }
    }
}


// MARK: - Problems

/// The build's errors and warnings, grouped by file. A row opens the file
/// at the line; the button runs the build again.
private struct ProblemsTab: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject private var problems = ProblemsModel.shared

    private var mine: [Problem] { problems.root == model.root ? problems.problems : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if problems.running {
                    LoadingMark(state: .working, size: 14)
                    Text("Running \(problems.lastCommand)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink.opacity(0.6))
                        .lineLimit(1)
                } else {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if problems.running {
                    IconButton("stop.fill", help: "Stop the build", tint: Theme.rose) { problems.stop() }
                } else {
                    IconButton("hammer", help: "Build and list problems (⇧⌘B)", tint: Theme.accent) {
                        problems.run(in: model.root)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            Rectangle().fill(Theme.ink.opacity(0.07)).frame(height: 1)
            if mine.isEmpty {
                workspaceNote(problems.root == model.root && !problems.note.isEmpty
                              ? problems.note
                              : "Build to see errors and warnings here. Companion picks the build from the folder (swift build, cargo, go vet, tsc, make), or uses the command in .companion/build.")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.file) { group in
                            Text(model.relative(group.file))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Theme.ink.opacity(0.75))
                                .lineLimit(1)
                                .truncationMode(.head)
                                .padding(.horizontal, 10)
                                .padding(.top, 7)
                                .padding(.bottom, 2)
                            ForEach(group.items) { problem in
                                ProblemRow(problem: problem) { model.open(problem.file, line: problem.line) }
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private var summary: String {
        guard problems.root == model.root, let date = problems.lastRun else { return "Not built yet" }
        let time = date.formatted(date: .omitted, time: .shortened)
        if mine.isEmpty { return problems.lastOK ? "No problems · \(time)" : "Build failed · \(time)" }
        return "\(problems.errors) errors, \(problems.warnings) warnings · \(time)"
    }

    private var groups: [(file: String, items: [Problem])] {
        var order: [String] = []
        var byFile: [String: [Problem]] = [:]
        for problem in mine {
            if byFile[problem.file] == nil { order.append(problem.file) }
            byFile[problem.file, default: []].append(problem)
        }
        return order.map { ($0, byFile[$0] ?? []) }
    }
}

private struct ProblemRow: View {
    let problem: Problem
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: problem.severity == .error ? "xmark.octagon.fill"
                      : (problem.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle"))
                    .font(.system(size: 10))
                    .foregroundStyle(problem.severity == .error ? Theme.rose
                                     : (problem.severity == .warning ? Theme.amber : Theme.ink.opacity(0.5)))
                Text(problem.message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.88))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(problem.column > 0 ? "\(problem.line):\(problem.column)" : "\(problem.line)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.ink.opacity(0.45))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(hover ? Theme.ink.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Open at line \(problem.line)")
    }
}

/// The line along the bottom of the workspace, as in an editor: the
/// branch, the build's errors and warnings, and a button to build.
private struct WorkspaceStatusBar: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject private var git = GitModel.shared
    @ObservedObject private var problems = ProblemsModel.shared

    private var here: Bool { problems.root == model.root }

    var body: some View {
        HStack(spacing: 12) {
            if git.isRepository, !git.branch.isEmpty {
                Button { model.showPanel(.source) } label: {
                    Label(git.branch, systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 160, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Git: \(git.branch)")
            }
            Button { model.showPanel(.problems) } label: {
                HStack(spacing: 8) {
                    Label("\(here ? problems.errors : 0)", systemImage: "xmark.octagon")
                        .foregroundStyle(here && problems.errors > 0 ? Theme.rose : Theme.ink.opacity(0.6))
                    Label("\(here ? problems.warnings : 0)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(here && problems.warnings > 0 ? Theme.amber : Theme.ink.opacity(0.6))
                }
            }
            .buttonStyle(.plain)
            .help("Problems (⇧⌘M)")
            Spacer(minLength: 4)
            if problems.running {
                LoadingMark(state: .working, size: 12)
                Text("Building")
            } else {
                Button { problems.run(in: model.root) } label: {
                    Label("Build", systemImage: "hammer")
                }
                .buttonStyle(.plain)
                .help("Build and list problems (⇧⌘B)")
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(Theme.ink.opacity(0.6))
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Theme.ink.opacity(0.04))
        .overlay(alignment: .top) { Rectangle().fill(Theme.ink.opacity(0.08)).frame(height: 1) }
    }
}


/// What the language server says about a symbol, under the pointer.
private struct HoverCard: View {
    let text: String

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.ink.opacity(0.92))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 260)
    }
}
