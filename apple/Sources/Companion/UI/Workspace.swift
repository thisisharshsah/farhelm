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
        /// The whole output of builds and of the agent's commands.
        case output = "Output"
        /// The project's tests, one by one.
        case tests = "Tests"
        /// What is listening on this Mac's ports.
        case ports = "Ports"
        /// Pull requests and workflow runs, through the GitHub CLI.
        case github = "GitHub"
        /// The debugger: run, step, the stack and the variables.
        case debug = "Debug"
        /// The folder's files, when there is no room for them at the side.
        case files = "Files"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .terminal: return "terminal"
            case .output: return "doc.plaintext"
            case .files: return "folder"
            case .search: return "magnifyingglass"
            case .changes: return "pencil.and.list.clipboard"
            case .source: return "arrow.triangle.branch"
            case .problems: return "exclamationmark.triangle"
            case .tests: return "testtube.2"
            case .ports: return "antenna.radiowaves.left.and.right"
            case .github: return "arrow.triangle.pull"
            case .debug: return "ladybug"
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
    /// The file tree is put away by hand (the top bar's button); the
    /// files are then a tab of the panel.
    @Published var filesHidden = false

    /// What the side bar shows, picked from the activity bar beside it.
    enum Activity: String, CaseIterable, Identifiable {
        case files = "Files"
        case search = "Search"
        case source = "Git"
        case changes = "Changes"
        case outline = "Outline"
        case timeline = "Timeline"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .files: return "folder"
            case .search: return "magnifyingglass"
            case .source: return "arrow.triangle.branch"
            case .changes: return "pencil.and.list.clipboard"
            case .outline: return "list.bullet.indent"
            case .timeline: return "calendar.day.timeline.left"
            }
        }

        /// The panel tab it stands for, which leaves the panel while it is
        /// at the side.
        var tab: Tab? {
            switch self {
            case .files: return .files
            case .search: return .search
            case .source: return .source
            case .changes: return .changes
            case .outline, .timeline: return nil
            }
        }
    }
    @Published var activity: Activity = .files

    /// Files shown as they look rather than as text (a page, a document,
    /// a picture); text ones among them can switch between the two.
    static let previewable: Set<String> = ["html", "htm", "md", "markdown", "svg", "pdf",
                                           "png", "jpg", "jpeg", "gif", "heic", "tiff", "bmp", "webp"]
    static let previewOnly: Set<String> = ["pdf", "png", "jpg", "jpeg", "gif", "heic", "tiff", "bmp", "webp"]
    @Published var previewing = false
    var canPreview: Bool {
        guard let openPath else { return false }
        return Self.previewable.contains((openPath as NSString).pathExtension.lowercased())
    }
    var previewOnlyFile: Bool {
        guard let openPath else { return false }
        return Self.previewOnly.contains((openPath as NSString).pathExtension.lowercased())
    }

    /// A second file beside the open one, to read while working (an
    /// editor's split view). "Edit here" swaps it into the editor.
    @Published var sidePath: String?
    @Published var sideText = ""
    private var sideSaved = ""
    /// The side file has typing not yet saved (when it is not the open file).
    var sideDirty: Bool { sidePath != nil && sidePath != openPath && sideText != sideSaved }

    func openToSide(_ path: String) {
        guard let data = FileManager.default.contents(atPath: path), data.count < 2_000_000,
              let content = String(data: data, encoding: .utf8) else {
            editorNote = "That file cannot be shown beside this one."
            return
        }
        sidePath = path
        sideText = content
        sideSaved = content
    }

    /// Saves the side file; like any save it goes into Changes.
    func saveSide(conversation: UUID?) {
        guard let path = sidePath, sideDirty else { return }
        let before = ChangeStore.shared.snapshot(path)
        do {
            try sideText.write(toFile: path, atomically: true, encoding: .utf8)
            sideSaved = sideText
            ChangeStore.shared.record(path: path, before: before, task: "Edited by you", conversation: conversation)
            Task { await ChangeStore.shared.commitPending(message: "edit \((path as NSString).lastPathComponent)") }
        } catch {
            editorNote = "Could not save \((path as NSString).lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// ⌘S: both editors' files.
    func saveAll(conversation: UUID?) {
        if dirty { save(conversation: conversation) }
        if sideDirty { saveSide(conversation: conversation) }
    }

    /// Closing the side keeps what was typed in it: it is saved first.
    func closeSide(conversation: UUID? = nil) {
        if sideDirty { saveSide(conversation: conversation) }
        sidePath = nil
        sideText = ""
        sideSaved = ""
    }

    /// The side file into the editor, and the editor's file to the side.
    func swapSide(conversation: UUID?) {
        guard let side = sidePath else { return }
        if dirty { save(conversation: conversation) }
        if sideDirty { saveSide(conversation: conversation) }
        let current = openPath
        open(side)
        if let current { openToSide(current) } else { closeSide() }
    }

    /// Shows a file's folders open in the tree, and the tree itself.
    func revealInTree(_ path: String) {
        var folder = (path as NSString).deletingLastPathComponent
        while folder.count >= root.count, folder != "/" {
            expanded.insert(folder)
            folder = (folder as NSString).deletingLastPathComponent
        }
        activity = .files
        filesHidden = false
    }

    /// The open file's symbols, for the outline and the path bar: from the
    /// language server when there is one, else read from the text.
    @Published var symbols: [CodeSymbol] = []
    private var symbolTask: Task<Void, Never>?

    func refreshSymbols(after delay: Double = 0) {
        symbolTask?.cancel()
        guard let path = openPath, !previewOnlyFile else {
            symbols = []
            return
        }
        let folder = root
        symbolTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            let found = await LanguageServers.shared.symbols(path, root: folder)
            guard !Task.isCancelled, self.openPath == path else { return }
            self.symbols = found ?? CodeSymbol.scan(self.text, language: (path as NSString).pathExtension.lowercased())
        }
    }

    /// The innermost symbol the cursor is in, for the path bar.
    var currentSymbol: CodeSymbol? {
        let line = cursor.line
        return symbols
            .filter { $0.line <= line && ($0.endLine ?? Int.max) >= line }
            .max { ($0.depth, $0.line) < ($1.depth, $1.line) }
    }
    /// Where the cursor is in the open file, for the status bar.
    @Published var cursor = (line: 1, column: 1, selected: 0)
    /// Files gone back from and forward to, as a browser keeps pages.
    @Published private(set) var backStack: [String] = []
    @Published private(set) var forwardStack: [String] = []
    private var navigating = false

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let current = openPath { forwardStack.append(current) }
        navigating = true
        open(previous)
        navigating = false
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = openPath { backStack.append(current) }
        navigating = true
        open(next)
        navigating = false
    }
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
            // The language server sees edits as they are typed, and the
            // outline catches up after a pause.
            if let openPath, text != oldValue {
                LanguageServers.shared.changed(openPath, text: text, root: root)
                refreshSymbols(after: 0.8)
            }
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
    /// Search and replace across the folder.
    @Published var replacement = ""
    @Published private(set) var replacing = false

    /// The open file as git has it at HEAD, for the change marks beside the
    /// lines: "" for a file git does not track yet, nil outside a repository.
    @Published private(set) var gitBase: String?
    /// Who last changed the cursor's line, and when (git blame).
    @Published private(set) var blame = ""
    private var blameTask: Task<Void, Never>?
    private var blamed: (path: String, line: Int)?

    // Changes
    @Published var shownChange: UUID?

    // Terminals: live shells in this folder, kept running while the
    // workspace stays on it. Several can be open; one shows at a time.
    @Published private(set) var terminals: [TerminalSession] = []
    @Published var currentTerminal = 0

    var dirty: Bool { openPath != nil && text != saved }

    private static let hidden = workspaceHiddenNames

    /// Points the workspace at a folder. Opening the same one again keeps
    /// everything as it was.
    func use(root folder: String) {
        guard folder != root else { return }
        root = folder
        // The terminals belonged to the folder before this one.
        terminals.forEach { $0.end() }
        terminals = []
        currentTerminal = 0
        diff = nil
        expanded = []
        listings = [:]
        hits = []
        ignored = []
        refresh(folder)
        refreshIgnored()
    }

    /// What git ignores in the folder (build output, .env...), dimmed in
    /// the tree as an editor does.
    @Published private(set) var ignored: Set<String> = []

    func refreshIgnored() {
        let folder = root
        guard !folder.isEmpty else { return }
        Task {
            let result = await Shell.run("git ls-files --others --ignored --exclude-standard --directory 2>/dev/null | head -n 5000",
                                         in: folder, timeout: 15)
            guard folder == root else { return }
            ignored = Set(result.output.split(separator: "\n").map { line -> String in
                var relative = String(line)
                if relative.hasSuffix("/") { relative.removeLast() }
                return (folder as NSString).appendingPathComponent(relative)
            })
        }
    }

    /// Closes every open folder in the tree.
    func collapseAll() {
        expanded = []
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

    /// The terminal showing, if any is open yet.
    var terminalShowing: TerminalSession? {
        terminals.isEmpty ? nil : terminals[min(max(currentTerminal, 0), terminals.count - 1)]
    }

    /// The task run last, for Run Again.
    @Published private(set) var lastTask: ProjectTask?

    /// Runs a task in a terminal of its own, which comes into view.
    func run(_ task: ProjectTask) {
        lastTask = task
        let session = newTerminal()
        // The shell reads it once it has started; what is typed waits.
        session.view.send(txt: task.command + "\r")
        showPanel(.terminal)
    }

    /// A new shell in the folder, which becomes the one showing.
    @discardableResult
    func newTerminal() -> TerminalSession {
        let session = TerminalSession(folder: root)
        // What the shell changed shows in the files once it is looked away
        // from or ends.
        session.changed = { [weak self] in self?.refreshAll() }
        terminals.append(session)
        currentTerminal = terminals.count - 1
        return session
    }

    /// Ends one shell and takes it off the list.
    func closeTerminal(_ session: TerminalSession) {
        guard let index = terminals.firstIndex(where: { $0 === session }) else { return }
        session.end()
        terminals.remove(at: index)
        currentTerminal = max(0, min(currentTerminal >= index ? currentTerminal - 1 : currentTerminal, terminals.count - 1))
        refreshAll()
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
        refreshIgnored()
    }

    // MARK: File operations

    /// A file or folder being named in the tree: a new one in a folder, or
    /// an existing one being renamed.
    enum Naming: Equatable {
        case newFile(in: String)
        case newFolder(in: String)
        case rename(String)
    }
    @Published var naming: Naming?

    /// Where a new file goes when none is picked: the open file's folder,
    /// if it is in this one, else the top.
    var defaultFolder: String {
        if let path = openPath, path.hasPrefix(root + "/") { return (path as NSString).deletingLastPathComponent }
        return root
    }

    func startNew(folder isFolder: Bool, in folder: String? = nil) {
        let place = folder ?? defaultFolder
        if place != root { expanded.insert(place) }
        refresh(place)
        naming = isFolder ? .newFolder(in: place) : .newFile(in: place)
        activity = .files
        filesHidden = false
    }

    /// Whether a typed name is usable: no empty parts and no "..".
    private static func valid(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return !name.isEmpty && !name.hasPrefix("/")
            && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// Finishes naming: creates or renames. "a/b.swift" makes the folders too.
    func finishNaming(_ typed: String, conversation: UUID?) {
        guard let naming else { return }
        self.naming = nil
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard Self.valid(name) else {
            editorNote = "\"\(name)\" is not a name a file can have here."
            return
        }
        let fm = FileManager.default
        switch naming {
        case .newFile(let folder), .newFolder(let folder):
            let path = (folder as NSString).appendingPathComponent(name)
            guard !fm.fileExists(atPath: path) else {
                editorNote = "\(name) is already there."
                return
            }
            do {
                if case .newFolder = naming {
                    try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
                } else {
                    try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    guard fm.createFile(atPath: path, contents: Data()) else { throw CocoaError(.fileWriteUnknown) }
                    ChangeStore.shared.record(path: path, before: nil, task: "Created by you", conversation: conversation)
                }
            } catch {
                editorNote = "Could not create \(name): \(error.localizedDescription)"
                return
            }
            revealInTree(path)
            refreshAll()
            refresh(folder)
            if case .newFile = naming { switchTo(path, conversation: conversation) }
        case .rename(let old):
            let target = ((old as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
            move(old, to: target, conversation: conversation)
        }
    }

    /// Moves or renames a file or folder, keeping its tabs open at the new
    /// place. A file's move is recorded in Changes (taken out here, put there).
    func move(_ old: String, to target: String, conversation: UUID?) {
        guard old != target else { return }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target) else {
            editorNote = "\((target as NSString).lastPathComponent) is already there."
            return
        }
        guard !target.hasPrefix(old + "/") else {
            editorNote = "A folder cannot go inside itself."
            return
        }
        var isFolder: ObjCBool = false
        fm.fileExists(atPath: old, isDirectory: &isFolder)
        if old == openPath, dirty { save(conversation: conversation) }
        let before = isFolder.boolValue ? nil : ChangeStore.shared.snapshot(old)
        do {
            try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.moveItem(atPath: old, toPath: target)
        } catch {
            editorNote = "Could not move \((old as NSString).lastPathComponent): \(error.localizedDescription)"
            return
        }
        if !isFolder.boolValue {
            ChangeStore.shared.record(path: old, before: before, task: "Moved by you", conversation: conversation)
            ChangeStore.shared.record(path: target, before: nil, task: "Moved by you", conversation: conversation)
            Task { await ChangeStore.shared.commitPending(message: "move \((old as NSString).lastPathComponent)") }
        }
        // Tabs, the side file and open folders follow it.
        func moved(_ path: String) -> String {
            if path == old { return target }
            if path.hasPrefix(old + "/") { return target + path.dropFirst(old.count) }
            return path
        }
        openFiles = openFiles.map(moved)
        if let path = openPath, moved(path) != path {
            openPath = moved(path)
            LanguageServers.shared.opened(moved(path), text: text, root: root)
        }
        if let side = sidePath { sidePath = moved(side) }
        expanded = Set(expanded.map(moved))
        refreshAll()
        refresh((target as NSString).deletingLastPathComponent)
        editorNote = ""
    }

    /// Moves files dragged onto a folder into it.
    func move(_ paths: [String], into folder: String, conversation: UUID?) {
        for path in paths where (path as NSString).deletingLastPathComponent != folder {
            move(path, to: (folder as NSString).appendingPathComponent((path as NSString).lastPathComponent),
                 conversation: conversation)
        }
    }

    /// A copy beside the file: "name copy.ext", "name copy 2.ext"...
    func duplicate(_ path: String, conversation: UUID?) {
        let folder = (path as NSString).deletingLastPathComponent
        let ext = (path as NSString).pathExtension
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var number = 1
        var target = ""
        repeat {
            let name = stem + (number == 1 ? " copy" : " copy \(number)") + (ext.isEmpty ? "" : "." + ext)
            target = (folder as NSString).appendingPathComponent(name)
            number += 1
        } while FileManager.default.fileExists(atPath: target)
        do {
            try FileManager.default.copyItem(atPath: path, toPath: target)
        } catch {
            editorNote = "Could not copy \((path as NSString).lastPathComponent): \(error.localizedDescription)"
            return
        }
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: target, isDirectory: &isFolder)
        if !isFolder.boolValue {
            ChangeStore.shared.record(path: target, before: nil, task: "Copied by you", conversation: conversation)
        }
        refresh(folder)
    }

    /// Moves a file or folder to the Trash, closing what was open from it.
    /// A file is recorded in Changes, so it can be put back from there too.
    func trash(_ path: String, conversation: UUID?) {
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isFolder)
        let before = isFolder.boolValue ? nil : ChangeStore.shared.snapshot(path)
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            editorNote = "Could not move \((path as NSString).lastPathComponent) to the Trash: \(error.localizedDescription)"
            return
        }
        if !isFolder.boolValue {
            ChangeStore.shared.record(path: path, before: before, task: "Moved to the Trash by you", conversation: conversation)
            Task { await ChangeStore.shared.commitPending(message: "remove \((path as NSString).lastPathComponent)") }
        }
        let gone: (String) -> Bool = { $0 == path || $0.hasPrefix(path + "/") }
        if let side = sidePath, gone(side) {
            sidePath = nil
            sideText = ""
            sideSaved = ""
        }
        for file in openFiles where gone(file) {
            if file == openPath { text = saved }   // nothing to save into a file that is gone
            close(file, conversation: conversation)
        }
        expanded = expanded.filter { !gone($0) }
        refresh((path as NSString).deletingLastPathComponent)
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
        // Leaving one file for another is a step that Back can undo.
        if !navigating, let current = openPath, current != path {
            backStack.append(current)
            if backStack.count > 50 { backStack.removeFirst() }
            forwardStack = []
        }
        // A file takes the place of a comparison.
        diff = nil
        editorNote = ""
        guard let data = FileManager.default.contents(atPath: path) else {
            editorNote = "That file could not be read."
            return
        }
        // A document or a picture: shown as it looks, with nothing to edit.
        if Self.previewOnly.contains((path as NSString).pathExtension.lowercased()) {
            openPath = path
            if !openFiles.contains(path) { openFiles.append(path) }
            text = ""
            saved = ""
            previewing = true
            symbols = []
            return
        }
        guard data.count < 2_000_000, !data.prefix(4096).contains(0), let content = String(data: data, encoding: .utf8) else {
            editorNote = "\((path as NSString).lastPathComponent) is not a text file, or is too large to edit here."
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return
        }
        LanguageServers.shared.opened(path, text: content, root: root)
        if openPath != path { previewing = false }
        let other = openPath != path
        openPath = path
        if !openFiles.contains(path) { openFiles.append(path) }
        text = content
        saved = content
        refreshSymbols()
        if other {
            gitBase = nil
            blame = ""
            blamed = nil
        }
        Task { await refreshGitBase() }
    }

    // MARK: Git beside the lines

    /// Reads the open file as it is at HEAD.
    func refreshGitBase() async {
        guard let path = openPath else { return }
        let folder = (path as NSString).deletingLastPathComponent
        let name = Shell.quote("./" + (path as NSString).lastPathComponent)
        let shown = await Shell.run("git show HEAD:\(name)", in: folder, timeout: 10)
        guard openPath == path else { return }
        if shown.ok {
            gitBase = shown.output
            return
        }
        // Not at HEAD: new in a repository (all of it is added), or no repository.
        let inside = await Shell.run("git rev-parse --is-inside-work-tree", in: folder, timeout: 10)
        guard openPath == path else { return }
        gitBase = inside.ok ? "" : nil
    }

    /// Who last changed a line, read a moment after the cursor settles on it.
    /// The text as typed is what is blamed, so unsaved lines say so.
    func refreshBlame(line: Int) {
        guard let path = openPath, gitBase != nil else {
            blame = ""
            return
        }
        if let blamed, blamed.path == path, blamed.line == line, !dirty { return }
        blamed = (path, line)
        blameTask?.cancel()
        let contents = text
        let isDirty = dirty
        blameTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else { return }
            let folder = (path as NSString).deletingLastPathComponent
            var extra = ""
            var scratch: String?
            if isDirty {
                let file = (NSTemporaryDirectory() as NSString).appendingPathComponent("companion-blame-\(UUID().uuidString)")
                if (try? contents.write(toFile: file, atomically: true, encoding: .utf8)) != nil {
                    scratch = file
                    extra = "--contents \(Shell.quote(file)) "
                }
            }
            let name = Shell.quote((path as NSString).lastPathComponent)
            let result = await Shell.run("git blame --porcelain -L \(line),\(line) \(extra)-- \(name)", in: folder, timeout: 10)
            if let scratch { try? FileManager.default.removeItem(atPath: scratch) }
            guard !Task.isCancelled, self.openPath == path else { return }
            self.blame = result.ok ? Self.describeBlame(result.output) : ""
        }
    }

    /// "Name, 3 days ago · subject" from `git blame --porcelain`.
    static func describeBlame(_ output: String) -> String {
        let lines = output.components(separatedBy: "\n")
        guard let hash = lines.first?.split(separator: " ").first else { return "" }
        if hash.allSatisfy({ $0 == "0" }) { return "Not committed yet" }
        func field(_ key: String) -> String? {
            lines.first { $0.hasPrefix(key + " ") }.map { String($0.dropFirst(key.count + 1)) }
        }
        let author = field("author") ?? "Someone"
        var when = ""
        if let stamp = field("author-time").flatMap({ Double($0) }) {
            when = ", " + RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: stamp), relativeTo: Date())
        }
        let subject = field("summary").map { " · " + $0 } ?? ""
        return author + when + subject
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
            Task {
                await ChangeStore.shared.commitPending(message: "edit \((path as NSString).lastPathComponent)")
                await refreshGitBase()
            }
        } catch {
            editorNote = "Could not save: \(error.localizedDescription)"
        }
    }

    /// Edits to files on disk, as a rename makes in files not open. Each
    /// goes into the history, so it can be undone from Changes.
    func applyEdits(_ edits: [String: [LSPEdit]], conversation: UUID?) {
        var changed = 0
        for (path, list) in edits {
            guard let old = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let new = LSPEdit.apply(list, to: old)
            guard new != old else { continue }
            let before = ChangeStore.shared.snapshot(path)
            guard (try? new.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { continue }
            ChangeStore.shared.record(path: path, before: before, task: "Renamed", conversation: conversation)
            reloadIfOpen(path)
            changed += 1
        }
        if changed > 0 {
            editorNote = "Changed \(changed) other \(changed == 1 ? "file" : "files")"
            Task { await ChangeStore.shared.commitPending(message: "rename") }
        }
    }

    /// The open file changed on disk (an undo, the agent): show what is there now.
    func reloadIfOpen(_ path: String) {
        guard openPath == path, !dirty else { return }
        open(path)
    }

    /// Replaces the searched text with `replacement` in every file that has
    /// it (plain text, case as typed). Each file goes into the history, so
    /// Changes can undo it.
    func replaceAll(conversation: UUID?) {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty, !root.isEmpty, !replacing else { return }
        if dirty { save(conversation: conversation) }
        replacing = true
        let folder = root
        let with = replacement
        Task {
            let skip = Self.hidden.map { "--exclude-dir=\(Shell.quote($0))" }.joined(separator: " ")
            let listed = await Shell.run("grep -rlIF \(skip) -e \(Shell.quote(wanted)) .", in: folder, timeout: 30)
            var files = 0, count = 0
            for row in listed.output.split(separator: "\n") {
                var name = String(row)
                if name.hasPrefix("./") { name.removeFirst(2) }
                let path = (folder as NSString).appendingPathComponent(name)
                guard let old = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                let found = old.components(separatedBy: wanted).count - 1
                guard found > 0 else { continue }
                let before = ChangeStore.shared.snapshot(path)
                let new = old.replacingOccurrences(of: wanted, with: with)
                guard (try? new.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { continue }
                ChangeStore.shared.record(path: path, before: before, task: "Replaced \"\(wanted)\"", conversation: conversation)
                reloadIfOpen(path)
                files += 1
                count += found
            }
            if files > 0 { await ChangeStore.shared.commitPending(message: "replace \(wanted)") }
            replacing = false
            search()
            searchNote = files == 0 ? "Nothing to replace."
                : "Replaced \(count) in \(files) \(files == 1 ? "file" : "files"). Changes can undo it."
        }
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
            replacing = false
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
        // A terminal the agent opened (an ssh session) shows with or without a folder.
        if app.hasWorkFolder || app.workspace.diff != nil || app.workspace.openPath != nil
            || !app.workspace.terminals.isEmpty {
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
            .panelCard(.work)
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
    /// Room for the activity bar and the side bar.
    /// In code the files are always at the side, however narrow the pane.
    private var wide: Bool { app.codeMode || paneWidth >= 560 }
    private var split: Bool { wide && !model.filesHidden }

    /// What the side bar shows: the files, or another view of the work.
    @ViewBuilder
    private var sideView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.activity != .files {
                Text(model.activity.rawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(Theme.ink.opacity(0.5))
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
            switch model.activity {
            case .files: FilesTab(model: model, part: .tree)
            case .search: SearchTab(model: model)
            case .source: SourceTab(model: model, git: git)
            case .changes: ChangesTab(model: model, history: history)
            case .outline: OutlineView(model: model)
            case .timeline: FileTimelineView(model: model, history: history)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
    /// The files' width, never so wide that what is open has no room.
    private var filesShown: CGFloat {
        min(max(model.filesWidth, 150), max(150, paneWidth - 320))
    }

    var body: some View {
        VStack(spacing: 0) {
        HStack(spacing: 0) {
            // The activity bar and the side bar it opens are one panel, as
            // in an editor: the bar is a strip down the panel's left side
            // and the side bar fills the rest, apart from the editor but
            // joined to what opens and closes it. Clicking the one showing
            // puts the side bar away, and the panel is just the strip.
            if wide {
                HStack(spacing: 0) {
                    ActivityBar(model: model)
                    if split {
                        sideView
                            .frame(width: filesShown, alignment: .leading)
                            .transition(.opacity)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .panelCard(.work)
                if split {
                    // Drag the gap to give the side bar more or less room.
                    ColumnDivider(width: { filesShown },
                                  direction: 1,
                                  resize: { model.filesWidth = min(max($0, 150), max(150, paneWidth - 320)) },
                                  reset: { model.filesWidth = 220 },
                                  done: { model.saveFilesWidth() })
                } else {
                    Color.clear.frame(width: Theme.panelGap)
                }
            }
            // What is being worked on, with the panel of tools under it.
            VStack(spacing: 0) {
                document
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .panelCard(.work)
                if model.panelOpen {
                    RowDivider(height: { panelShown },
                               resize: { model.panelHeight = min(max($0, 120), max(120, paneHeight - 150)) },
                               reset: { model.panelHeight = 230 },
                               done: { model.savePanelHeight() })
                    panel
                        .frame(height: panelShown)
                        .panelCard(.work)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: model.panelOpen)
        }
        // Branch, problems, the cursor and the build, under all of it.
        WorkspaceStatusBar(model: model)
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        paneWidth = geometry.size.width
                        paneHeight = geometry.size.height
                        model.filesAtSide = (app.codeMode || geometry.size.width >= 560) && !model.filesHidden
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
        // Nor a tab for what the side bar now shows.
        .onChange(of: model.activity) { _, activity in
            if split, let tab = activity.tab, model.tab == tab { model.tab = .terminal }
        }
    }

    /// The panel's height: what was chosen, as far as the pane allows.
    private var panelShown: CGFloat {
        min(max(model.panelHeight, 120), max(120, paneHeight - 150))
    }

    /// The panel's tabs: the files are one of them only when they have no
    /// room at the side.
    private var tabs: [WorkspaceModel.Tab] {
        // What the side bar shows is not repeated in the panel.
        let atSide = split ? model.activity.tab : nil
        return WorkspaceModel.Tab.allCases.filter { ($0 != .files || !split) && $0 != atSide }
    }

    /// The tabs kept in the bar (the rest are under More), by name. The
    /// tab in use always shows, kept or not.
    @AppStorage("panelBarTabs") private var keptTabs = "Terminal,Search,Git,Problems,Output"

    private var kept: Set<String> { Set(keptTabs.split(separator: ",").map(String.init)) }

    private var barTabs: [WorkspaceModel.Tab] {
        tabs.filter { kept.contains($0.rawValue) || $0 == model.tab }
    }

    private var otherTabs: [WorkspaceModel.Tab] {
        tabs.filter { !barTabs.contains($0) }
    }

    private func setKept(_ tab: WorkspaceModel.Tab, _ on: Bool) {
        var names = kept
        if on { names.insert(tab.rawValue) } else { names.remove(tab.rawValue) }
        // In the order they are listed, so the bar keeps its order.
        keptTabs = WorkspaceModel.Tab.allCases.map(\.rawValue).filter(names.contains).joined(separator: ",")
    }

    /// The tabs not in the bar, and which tabs the bar keeps.
    private var moreTabs: some View {
        Menu {
            ForEach(otherTabs) { tab in
                Button { model.tab = tab } label: { Label(title(of: tab), systemImage: tab.icon) }
            }
            if !otherTabs.isEmpty { Divider() }
            Menu("Keep in the Bar") {
                ForEach(tabs) { tab in
                    Toggle(isOn: Binding(get: { kept.contains(tab.rawValue) }, set: { setKept(tab, $0) })) {
                        Label(tab.rawValue, systemImage: tab.icon)
                    }
                }
                Divider()
                Button("Reset") { keptTabs = "Terminal,Search,Git,Problems,Output" }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.68))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More tabs, and which ones the bar keeps")
    }

    /// One tab: its icon, its name when there is room, and its count.
    private func tabButton(_ tab: WorkspaceModel.Tab, named: Bool) -> some View {
        let on = model.tab == tab
        return Button {
            model.tab = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 10.5, weight: .semibold))
                if named {
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
            .padding(.horizontal, named ? 9 : 7)
            .frame(height: 26)
            .background(Capsule().fill(on ? Theme.accent.opacity(0.16) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title(of: tab))
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
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(Theme.ink.opacity(0.9))
                .lineLimit(1)
                .help(model.root)
            Spacer(minLength: 4)
            IconButton("inset.filled.bottomthird.rectangle",
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
                // The tabs in the bar, named; short of room, as icons only.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 2) { ForEach(barTabs) { tabButton($0, named: true) } }
                    HStack(spacing: 2) { ForEach(barTabs) { tabButton($0, named: false) } }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // With one shell its + sits here; with more, in the list.
                if model.tab == .terminal, model.terminals.count <= 1 {
                    IconButton("plus", help: "New terminal") { model.newTerminal() }
                }
                moreTabs
                RunTaskMenu(model: model)
                IconButton("chevron.down", help: "Hide the panel (⌃`)") { model.panelOpen = false }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
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
                case .output: OutputTab()
                case .tests: TestsTab(model: model)
                case .ports: PortsTab()
                case .github: GitHubTab(model: model)
                case .debug: DebugTab(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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
    /// The file or folder asked about before it goes to the Trash.
    @State private var trashing: String?
    /// Watched so breakpoints and the stopped line show in the editor.
    @ObservedObject private var debug = DebugModel.shared
    /// Watched so changed files are marked in the tree.
    @ObservedObject private var gitModel = GitModel.shared
    /// The whole tree is open.
    @State private var rootOpen = true

    /// What git says about the files, by path, for marking them in the tree.
    private var gitDecorations: GitDecorations {
        GitDecorations(root: gitModel.root, files: gitModel.staged + gitModel.unstaged)
    }
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
            // As an editor's explorer: the folder's name, which folds the
            // whole tree, and its actions, which show while the pointer is
            // over the files.
            HStack(spacing: 4) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { rootOpen.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: rootOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.ink.opacity(0.55))
                            .frame(width: 10)
                        Text((model.root as NSString).lastPathComponent)
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(Theme.ink.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                .help((model.root as NSString).abbreviatingWithTildeInPath)
                Spacer(minLength: 8)
                // As many actions as fit sit in the row, one by one as it
                // widens; the rest go back into "…" as it narrows.
                ViewThatFits(in: .horizontal) {
                    treeActionsRow(showing: 4)
                    treeActionsRow(showing: 3)
                    treeActionsRow(showing: 2)
                    treeActionsRow(showing: 1)
                    treeActionsRow(showing: 0)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            Rectangle()
                .fill(Theme.ink.opacity(0.09))
                .frame(height: 1)
            treeBody
        }
    }

    /// The explorer's actions that can sit in its header row, in the order
    /// they come out of "…".
    private var treeActions: [(title: String, icon: String, run: () -> Void)] {
        [
            ("New File…", "doc.badge.plus", { model.startNew(folder: false) }),
            ("New Folder…", "folder.badge.plus", { model.startNew(folder: true) }),
            ("Refresh Explorer", "arrow.clockwise", { model.refreshAll() }),
            ("Collapse Folders", "rectangle.compress.vertical", { model.collapseAll() }),
        ]
    }

    /// The first `shown` actions as buttons, and the rest with everything
    /// else in "…".
    private func treeActionsRow(showing shown: Int) -> some View {
        let actions = treeActions
        let n = max(0, min(shown, actions.count))
        return HStack(spacing: 0) {
            ForEach(0..<n, id: \.self) { i in
                Button(action: actions[i].run) {
                    Image(systemName: actions[i].icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ink.opacity(0.68))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(actions[i].title)
            }
            Menu {
                ForEach(n..<actions.count, id: \.self) { i in
                    Button(action: actions[i].run) { Label(actions[i].title, systemImage: actions[i].icon) }
                }
                if n < actions.count { Divider() }
                Button("Work in a Different Folder…") { app.pickWorkFolder() }
                    Button("Open Several Files…") { app.pickFilesToOpen() }
                    Divider()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.root)])
                    }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.root, forType: .string)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.ink.opacity(0.68))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(n == 0 ? "New file, folder and more" : "More")
        }
        .fixedSize()
    }

    /// Below the explorer's header: its note, the files, and the trash prompt.
    @ViewBuilder
    private var treeBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.editorNote.isEmpty {
                workspaceNote(model.editorNote)
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if rootOpen {
                        rows(in: model.root, depth: 0, git: gitDecorations)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                // Dropped on the empty space below: to the top folder.
                .dropDestination(for: String.self) { paths, _ in
                    model.move(paths.filter { $0.hasPrefix(model.root + "/") }, into: model.root, conversation: app.conversation.id)
                    return true
                }
            }
        }
        .confirmationDialog(trashing.map { "Move \(($0 as NSString).lastPathComponent) to the Trash?" } ?? "",
                            isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }),
                            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let path = trashing { model.trash(path, conversation: app.conversation.id) }
                trashing = nil
            }
            Button("Cancel", role: .cancel) { trashing = nil }
        } message: {
            Text("It can be put back from the Trash, and a file from Changes too.")
        }
    }

    /// The row where a new file or folder is named, at the top of its folder.
    @ViewBuilder
    private func namingRow(in folder: String, depth: Int) -> some View {
        switch model.naming {
        case .newFile(let place) where place == folder:
            NameField(icon: "doc", initial: "", depth: depth) { model.finishNaming($0 ?? "", conversation: app.conversation.id) }
        case .newFolder(let place) where place == folder:
            NameField(icon: "folder", initial: "", depth: depth) { model.finishNaming($0 ?? "", conversation: app.conversation.id) }
        default:
            EmptyView()
        }
    }

    /// A folder's entries, with those of every open folder under it.
    private func rows(in folder: String, depth: Int, git: GitDecorations) -> AnyView {
        AnyView(Group {
        namingRow(in: folder, depth: depth)
        ForEach(model.children(of: folder)) { entry in
            if model.naming == .rename(entry.path) {
                NameField(icon: entry.isFolder ? "folder" : "doc", initial: entry.name, depth: depth) {
                    model.finishNaming($0 ?? entry.name, conversation: app.conversation.id)
                }
            } else {
            FileRow(entry: entry, depth: depth, open: model.expanded.contains(entry.path),
                    status: git.status(of: entry.path, isFolder: entry.isFolder),
                    dimmed: model.ignored.contains(entry.path)) {
                if entry.isFolder { model.toggle(entry.path) } else { model.switchTo(entry.path, conversation: app.conversation.id) }
            }
            .draggable(entry.path)
            .dropDestination(for: String.self) { paths, _ in
                // Onto a folder: into it. Onto a file: beside it.
                let folder = entry.isFolder ? entry.path : (entry.path as NSString).deletingLastPathComponent
                model.move(paths.filter { $0.hasPrefix(model.root + "/") && $0 != folder }, into: folder,
                           conversation: app.conversation.id)
                return true
            }
            .contextMenu {
                if entry.isFolder {
                    Button("New File…") { model.startNew(folder: false, in: entry.path) }
                    Button("New Folder…") { model.startNew(folder: true, in: entry.path) }
                } else {
                    Button("Open") { model.switchTo(entry.path, conversation: app.conversation.id) }
                    Button("Open to the Side") { model.openToSide(entry.path) }
                }
                Divider()
                Button("Rename…") { model.naming = .rename(entry.path) }
                Button("Duplicate") { model.duplicate(entry.path, conversation: app.conversation.id) }
                Button("Move to Trash…") { trashing = entry.path }
                Divider()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.path, forType: .string)
                }
                Button("Copy Relative Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.relative(entry.path), forType: .string)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                }
            }
            }
            if entry.isFolder, model.expanded.contains(entry.path), depth < 12 {
                rows(in: entry.path, depth: depth + 1, git: git)
            }
        }
        })
    }

    /// The open files, one tab each, shown when more than one is open.
    private func tabs(_ current: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(model.openFiles, id: \.self) { file in
                    HStack(spacing: 4) {
                        FileIcon(name: (file as NSString).lastPathComponent, size: 13)
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
                // Folder by folder, then the symbol the cursor is in.
                Breadcrumbs(model: model, path: path)
                    .layoutPriority(-1)
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
                // A page, a document or a picture: as text, or as it looks.
                if model.canPreview, !model.previewOnlyFile {
                    Picker("", selection: $model.previewing) {
                        Text("Text").tag(false)
                        Text("Preview").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 128)
                    .help("Show the file as text, or as it looks")
                }
                IconButton(model.sidePath == path ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                           help: model.sidePath == nil ? "Open this file to the side too (⌘\\)" : "Close the side file",
                           tint: model.sidePath != nil ? Theme.accent : nil) {
                    if model.sidePath != nil { model.closeSide() } else { model.openToSide(path) }
                }
                Button {
                    model.saveAll(conversation: app.conversation.id)
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
                .disabled(!model.dirty && !model.sideDirty)
                .keyboardShortcut("s", modifiers: .command)
                .help("Save (Cmd+S). A save goes into Changes, so it can be undone.")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            Rectangle()
                .fill(Theme.ink.opacity(0.07))
                .frame(height: 1)
            ConflictBar(model: model)
            HStack(spacing: 0) {
            Group {
            if model.previewing || model.previewOnlyFile {
                FilePreview(path: path, text: model.text)
            } else {
            CodeEditor(text: $model.text, language: (path as NSString).pathExtension.lowercased(),
                       zoom: settings.contentZoom,
                       marks: problems.marks(in: path),
                       reveal: model.reveal,
                       path: path,
                       root: model.root,
                       onCursor: {
                           let moved = model.cursor.line != $0.line
                           model.cursor = $0
                           if moved || model.blame.isEmpty { model.refreshBlame(line: $0.line) }
                       },
                       onInlineEdit: { from, to, selected, instruction in
                           app.inlineEdit(path: path, from: from, to: to, selected: selected, instruction: instruction)
                       },
                       onEditFiles: { model.applyEdits($0, conversation: app.conversation.id) },
                       gitBase: model.gitBase,
                       breakpoints: debug.breakpoints[path] ?? [],
                       stoppedLine: debug.location?.path == path ? debug.location?.line : nil,
                       onToggleBreakpoint: { debug.toggle(path, line: $0) },
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A second file beside this one, to read while working.
            if let side = model.sidePath {
                Rectangle().fill(Theme.ink.opacity(0.09)).frame(width: 1)
                sideEditor(side)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }
        }
    }

    /// The file to the side: read only, with its own bar; "Edit here"
    /// swaps it with the one in the editor.
    private func sideEditor(_ side: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ink.opacity(0.5))
                Text((side as NSString).lastPathComponent)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.85))
                    .lineLimit(1)
                    .help(model.relative(side))
                if model.sideDirty {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                        .help("Not saved yet; ⌘S saves it")
                }
                Spacer(minLength: 4)
                if side != model.openPath {
                    Button("Edit here") { model.swapSide(conversation: app.conversation.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .help("Put this file in the editor, and the editor's file here")
                }
                IconButton("xmark", help: "Close the side file (what is typed in it is saved)") {
                    model.closeSide(conversation: app.conversation.id)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            Rectangle().fill(Theme.ink.opacity(0.07)).frame(height: 1)
            // Editable: the same file as the editor shares its text; another
            // file has its own, saved with ⌘S.
            CodeEditor(text: side == model.openPath ? $model.text : $model.sideText,
                       language: (side as NSString).pathExtension.lowercased(),
                       zoom: settings.contentZoom,
                       root: model.root)
                .id("side-" + side)
        }
    }
}

/// Naming a file or folder in the tree, in place of its row. Return
/// keeps the name, Esc gives up, clicking away keeps it too.
private struct NameField: View {
    let icon: String
    let initial: String
    let depth: Int
    /// The name typed, or nil when given up.
    let done: (String?) -> Void
    @State private var text = ""
    @State private var finished = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: 10)
            Image(systemName: icon)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.accent.opacity(0.9))
                .frame(width: 15)
            TextField(icon == "folder" ? "Folder name" : "File name, or folder/name", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($focused)
                .onSubmit { finish(text) }
                .onKeyPress(.escape) {
                    finish(nil)
                    return .handled
                }
        }
        .padding(.leading, CGFloat(depth) * 12 + 4)
        .padding(.trailing, 4)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1))
        .onAppear {
            text = initial
            focused = true
        }
        .onChange(of: focused) { _, now in
            if !now { finish(text) }
        }
    }

    private func finish(_ value: String?) {
        guard !finished else { return }
        finished = true
        done(value)
    }
}

/// What git says about files, for marking them in the tree: changed files
/// in colour with a letter, folders holding changes with a dot.
struct GitDecorations {
    enum Status { case modified, added, untracked, deleted, renamed, conflict, holdsChanges }
    private var byPath: [String: Status] = [:]
    private var changed: [String] = []

    init(root: String, files: [GitFile]) {
        guard !root.isEmpty else { return }
        for file in files {
            let path = (root as NSString).appendingPathComponent(file.path)
            let status: Status
            switch file.kind {
            case .modified: status = .modified
            case .added: status = .added
            case .untracked: status = .untracked
            case .deleted: status = .deleted
            case .renamed: status = .renamed
            case .conflict: status = .conflict
            }
            // A conflict outranks everything; otherwise the first one seen.
            if byPath[path] == nil || status == .conflict { byPath[path] = status }
            changed.append(path)
        }
    }

    func status(of path: String, isFolder: Bool) -> Status? {
        if !isFolder { return byPath[path] }
        let prefix = path + "/"
        return changed.contains { $0.hasPrefix(prefix) } ? .holdsChanges : nil
    }
}

private struct FileRow: View {
    let entry: WorkspaceModel.Entry
    let depth: Int
    let open: Bool
    var status: GitDecorations.Status? = nil
    /// Ignored by git: drawn faint.
    var dimmed = false
    let action: () -> Void
    @State private var hover = false

    private var tint: Color? {
        switch status {
        case .modified, .holdsChanges: return Theme.amber
        case .added, .untracked: return Theme.mint
        case .deleted, .conflict: return Theme.rose
        case .renamed: return Theme.accent
        case nil: return nil
        }
    }

    private var letter: String? {
        switch status {
        case .modified: return "M"
        case .added: return "A"
        case .untracked: return "U"
        case .deleted: return "D"
        case .renamed: return "R"
        case .conflict: return "!"
        case .holdsChanges, nil: return nil
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(Theme.ink.opacity(entry.isFolder ? 0.45 : 0))
                .frame(width: 10)
            FileIcon(name: entry.name, isFolder: entry.isFolder, open: open, size: 15)
            Text(entry.name)
                .font(.system(size: 11.5))
                .foregroundStyle(tint ?? Theme.ink.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let letter {
                Text(letter)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint ?? Theme.ink)
                    .padding(.trailing, 2)
            } else if status == .holdsChanges {
                Circle().fill((tint ?? Theme.amber).opacity(0.8)).frame(width: 5, height: 5)
                    .padding(.trailing, 4)
            }
        }
        .opacity(dimmed ? 0.5 : 1)
        .padding(.leading, CGFloat(depth) * 12 + 4)
        .padding(.trailing, 4)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.ink.opacity(hover ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
        .help(dimmed ? "\(entry.name) (ignored by git)" : entry.name)
    }
}

/// A plain code editor: monospaced, no wrapping surprises, with comments,
/// strings, numbers and common keywords colored.
private struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let language: String
    /// The content zoom: the code's size follows it.
    var zoom: Double = 1
    /// False for a file only shown, such as the one to the side.
    var editable = true
    /// Lines the build has errors or warnings on, tinted.
    var marks: [Int: Problem.Severity] = [:]
    /// A line to scroll to and select.
    var reveal: WorkspaceModel.Reveal?
    /// The file and its folder, for the language server.
    var path = ""
    var root = ""
    /// Told where the cursor is (line, column, characters selected).
    var onCursor: (((line: Int, column: Int, selected: Int)) -> Void)? = nil
    /// Inline edit (⌘I): the first and last line chosen, their text, and
    /// what to do with them.
    var onInlineEdit: ((Int, Int, String, String) -> Void)? = nil
    /// Edits to other files, as a rename makes, file by file.
    var onEditFiles: (([String: [LSPEdit]]) -> Void)? = nil
    /// The file at HEAD, for marking changed lines beside the text.
    var gitBase: String? = nil
    /// Lines with a breakpoint, the line the debugger is stopped on, and
    /// setting or clearing a breakpoint (F9, or a click beside the line).
    var breakpoints: Set<Int> = []
    var stoppedLine: Int? = nil
    var onToggleBreakpoint: ((Int) -> Void)? = nil
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
        view.isEditable = editable
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        // ⌘F: the find and replace bar over the text, as in an editor.
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.font = font
        view.textColor = NSColor(Theme.ink.opacity(0.92))
        view.insertionPointColor = NSColor(Theme.accent)
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.string = text
        context.coordinator.view = view
        // A narrow strip left of the text marks lines changed since HEAD.
        let ruler = ChangeRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = view
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.ruler = ruler
        ruler.breakpoints = breakpoints
        ruler.toggle = onToggleBreakpoint
        context.coordinator.color()
        context.coordinator.show(reveal)
        context.coordinator.install()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let resized = abs(context.coordinator.parent.zoom - zoom) > 0.001
        let remarked = context.coordinator.parent.marks != marks || context.coordinator.parent.gitBase != gitBase
            || context.coordinator.parent.stoppedLine != stoppedLine
        context.coordinator.ruler?.breakpoints = breakpoints
        context.coordinator.ruler?.toggle = onToggleBreakpoint
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
        weak var ruler: ChangeRuler?

        /// Marks the lines changed since HEAD in the strip beside the text.
        func markChanges() {
            guard let ruler, let view else { return }
            guard let base = parent.gitBase, base != view.string else {
                ruler.marks = []
                return
            }
            ruler.marks = DiffHunk.hunks(before: base, after: view.string).map { hunk -> ChangeRuler.Mark in
                if hunk.after.isEmpty { return ChangeRuler.Mark(lines: hunk.after.lowerBound..<hunk.after.lowerBound, kind: .removed) }
                return ChangeRuler.Mark(lines: hunk.after, kind: hunk.before.isEmpty ? .added : .changed)
            }
        }
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
                if event.type == .keyDown, let handled = self.key(event, in: view) { return handled ? nil : event }
                if event.type == .keyDown, event.keyCode == 111, view.window?.firstResponder === view {
                    self.goToDefinition(at: view.selectedRange().location)
                    return nil
                }
                // ⌘I: ask for a change to the chosen lines.
                if event.type == .keyDown, event.keyCode == 34,
                   event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                   view.window?.firstResponder === view, view.isEditable, self.parent.onInlineEdit != nil {
                    self.askInlineEdit()
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

        // MARK: Inline edit

        private var editPopover: NSPopover?

        /// Shows a box by the chosen lines (or the cursor's line) for what
        /// to change; the agent then changes only those lines.
        private func askInlineEdit() {
            guard let view, let layout = view.layoutManager, let container = view.textContainer else { return }
            let text = view.string as NSString
            let lines = text.lineRange(for: view.selectedRange())
            let first = Self.position(of: lines.location, in: text).line + 1
            let endIndex = max(lines.location, lines.location + lines.length - 1)
            let last = Self.position(of: min(endIndex, max(0, text.length - 1)), in: text).line + 1
            let selected = text.substring(with: lines)
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: lines.location, length: 0), actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x = view.textContainerOrigin.x
            rect.origin.y += view.textContainerOrigin.y
            rect.size.width = max(40, view.visibleRect.width - 30)
            rect.size.height = max(rect.height, 14)

            editPopover?.close()
            let popover = NSPopover()
            popover.behavior = .transient
            let place = first == last ? "Line \(first)" : "Lines \(first)–\(last)"
            popover.contentViewController = NSHostingController(rootView: EditorPrompt(
                icon: "sparkles", title: "Edit \(place.lowercased())",
                placeholder: "What should change here?", multiline: true) { [weak self, weak popover] instruction in
                popover?.close()
                guard let self, let instruction else { return }
                self.parent.onInlineEdit?(first, last, selected, instruction)
            })
            popover.show(relativeTo: rect, of: view, preferredEdge: .minY)
            editPopover = popover
        }

        /// Shows a view in a popover by a place in the text.
        private func present<Content: View>(_ content: Content, at index: Int) -> NSPopover? {
            guard let view, let layout = view.layoutManager, let container = view.textContainer else { return nil }
            let length = (view.string as NSString).length
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: min(index, length), length: 0),
                                           actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += view.textContainerOrigin.x
            rect.origin.y += view.textContainerOrigin.y
            rect.size.width = max(rect.width, 2)
            rect.size.height = max(rect.height, 14)
            editPopover?.close()
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: content)
            popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
            editPopover = popover
            return popover
        }

        /// A short word by the cursor, such as why an action did nothing.
        private func say(_ message: String) {
            guard let view else { return }
            _ = present(Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 7), at: view.selectedRange().location)
        }

        private var hasServerLanguage: Bool { LanguageServers.language(of: parent.path) != nil && !parent.root.isEmpty }

        // MARK: Find, replace, go to line

        /// The find bar's actions (find, replace, next, previous).
        private func finder(_ action: NSTextFinder.Action) {
            guard let view else { return }
            let item = NSMenuItem()
            item.tag = action.rawValue
            view.performTextFinderAction(item)
        }

        private func askGoToLine() {
            guard let view else { return }
            let count = (view.string as NSString).components(separatedBy: "\n").count
            var popover: NSPopover?
            popover = present(EditorPrompt(icon: "arrow.right.to.line", title: "Go to line",
                                           placeholder: "Line, 1 to \(count)") { [weak self] value in
                popover?.close()
                guard let self, let value, let line = Int(value.split(separator: ":").first ?? "") else { return }
                self.select(line: min(max(line, 1), count))
            }, at: view.selectedRange().location)
        }

        /// Selects a line and scrolls to it.
        func select(line wanted: Int) {
            guard let view else { return }
            let text = view.string as NSString
            let location = LSPEdit.offset(line: wanted - 1, character: 0, in: text)
            let target = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
            DispatchQueue.main.async {
                view.setSelectedRange(target)
                view.scrollRangeToVisible(target)
                view.showFindIndicator(for: target)
                view.window?.makeFirstResponder(view)
            }
        }

        // MARK: Completion

        private var completionItems: [LSPCompletion]?
        private var completionStart = -1

        /// Where the word being typed at an index starts.
        private func wordStart(before index: Int) -> Int {
            guard let view else { return index }
            let text = view.string as NSString
            var start = min(index, text.length)
            while start > 0, Self.isWord(text.character(at: start - 1)) { start -= 1 }
            return start
        }

        /// Asks the server what can be typed here, then shows the list.
        func requestCompletion() {
            guard let view, hasServerLanguage else { return }
            let index = view.selectedRange().location
            let start = wordStart(before: index)
            let place = Self.position(of: index, in: view.string as NSString)
            completionItems = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                let items = await LanguageServers.shared.completions(self.parent.path, text: view.string, line: place.line,
                                                                     character: place.character, root: self.parent.root)
                guard let items, !items.isEmpty, self.wordStart(before: view.selectedRange().location) == start else { return }
                self.completionItems = items
                self.completionStart = start
                view.complete(nil)
            }
        }

        /// The list NSTextView shows: the server's, narrowed by what is typed.
        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            guard let items = completionItems, charRange.location == completionStart else {
                // Esc (the usual key for completion) with nothing asked yet.
                if hasServerLanguage { requestCompletion() }
                return []
            }
            let typed = (textView.string as NSString).substring(with: charRange).lowercased()
            let matching = items.map(\.insert).filter { typed.isEmpty || $0.lowercased().hasPrefix(typed) }
            index?.pointee = matching.isEmpty ? -1 : 0
            return Array(matching.prefix(100))
        }

        // MARK: Rename, references, format

        /// The word at the cursor, with its range.
        private func wordAtCursor() -> (word: String, range: NSRange)? {
            guard let view else { return nil }
            let text = view.string as NSString
            let index = min(view.selectedRange().location, text.length)
            var start = index, end = index
            while start > 0, Self.isWord(text.character(at: start - 1)) { start -= 1 }
            while end < text.length, Self.isWord(text.character(at: end)) { end += 1 }
            guard end > start else { return nil }
            let range = NSRange(location: start, length: end - start)
            return (text.substring(with: range), range)
        }

        private static func same(_ a: String, _ b: String) -> Bool {
            (a as NSString).resolvingSymlinksInPath == (b as NSString).resolvingSymlinksInPath
        }

        /// Replaces the whole text so the change can be undone with ⌘Z.
        private func replaceText(with new: String) {
            guard let view, new != view.string else { return }
            let selection = view.selectedRange()
            let whole = NSRange(location: 0, length: (view.string as NSString).length)
            guard view.shouldChangeText(in: whole, replacementString: new) else { return }
            view.replaceCharacters(in: whole, with: new)
            view.didChangeText()
            view.setSelectedRange(NSRange(location: min(selection.location, (new as NSString).length), length: 0))
            color()
        }

        private func askRename() {
            guard let view else { return }
            guard hasServerLanguage else { return say("Rename needs a language server for this language.") }
            guard let found = wordAtCursor() else { return say("Put the cursor on a name to rename it.") }
            let place = Self.position(of: found.range.location, in: view.string as NSString)
            var popover: NSPopover?
            popover = present(EditorPrompt(icon: "character.cursor.ibeam", title: "Rename \(found.word)",
                                           placeholder: "New name", initial: found.word) { [weak self] value in
                popover?.close()
                guard let self, let value, value != found.word else { return }
                self.rename(at: place, to: value)
            }, at: found.range.location)
        }

        private func rename(at place: (line: Int, character: Int), to name: String) {
            guard let view else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let edits = await LanguageServers.shared.rename(self.parent.path, text: view.string, line: place.line,
                                                                character: place.character, to: name, root: self.parent.root)
                guard let edits, !edits.isEmpty else { return self.say("The language server could not rename this.") }
                var others: [String: [LSPEdit]] = [:]
                for (file, list) in edits {
                    if Self.same(file, self.parent.path) {
                        self.replaceText(with: LSPEdit.apply(list, to: view.string))
                    } else {
                        others[file] = list
                    }
                }
                if !others.isEmpty { self.parent.onEditFiles?(others) }
            }
        }

        private func showReferences() {
            guard let view else { return }
            guard hasServerLanguage else { return say("Finding uses needs a language server for this language.") }
            guard let found = wordAtCursor() else { return say("Put the cursor on a name to find where it is used.") }
            let place = Self.position(of: found.range.location, in: view.string as NSString)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let items = await LanguageServers.shared.references(self.parent.path, text: view.string, line: place.line,
                                                                    character: place.character, root: self.parent.root) ?? []
                guard !items.isEmpty else { return self.say("No uses of \(found.word) found.") }
                var popover: NSPopover?
                popover = self.present(ReferencesList(symbol: found.word, items: items, root: self.parent.root) { [weak self] item in
                    popover?.close()
                    self?.parent.goTo?(item.path, item.line)
                }, at: found.range.location)
            }
        }

        private func formatDocument() {
            guard let view else { return }
            guard hasServerLanguage else { return say("Formatting needs a language server for this language.") }
            let indent = WorkspaceStatusBar.indentation(of: view.string)
            let spaces = indent != "Tabs"
            let size = Int(indent.filter(\.isNumber)) ?? 4
            let before = view.string
            Task { @MainActor [weak self] in
                guard let self else { return }
                let edits = await LanguageServers.shared.format(self.parent.path, text: before, tabSize: size,
                                                                spaces: spaces, root: self.parent.root)
                guard view.string == before else { return }
                guard let edits else { return self.say("Formatting needs a language server for this language.") }
                if edits.isEmpty { return self.say("Already formatted.") }
                self.replaceText(with: LSPEdit.apply(edits, to: before))
            }
        }

        /// The editor's keys. True when one was used, nil when the event is
        /// not the editor's.
        private func key(_ event: NSEvent, in view: NSTextView) -> Bool? {
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let responder = view.window?.firstResponder as? NSView
            let mine = responder === view
            // The find bar sits in the editor's scroll view: ⌘G works from it too.
            let inEditor = mine || (responder.map { r in view.enclosingScrollView.map { r.isDescendant(of: $0) } ?? false } ?? false)
            guard inEditor else { return nil }
            switch (event.keyCode, flags) {
            case (3, [.command]): finder(.showFindInterface); return true                 // ⌘F
            case (3, [.command, .option]):                                                   // ⌥⌘F
                finder(view.isEditable ? .showReplaceInterface : .showFindInterface); return true
            case (5, [.command]): finder(.nextMatch); return true                          // ⌘G
            case (5, [.command, .shift]): finder(.previousMatch); return true              // ⇧⌘G
            default: break
            }
            guard mine else { return nil }
            switch (event.keyCode, flags) {
            case (5, [.control]): askGoToLine(); return true                               // ⌃G
            case (101, []) where parent.onToggleBreakpoint != nil:                           // F9
                let index = view.selectedRange().location
                parent.onToggleBreakpoint?(Self.position(of: index, in: view.string as NSString).line + 1)
                return true
            case (49, [.control]) where hasServerLanguage: requestCompletion(); return true // ⌃Space
            case (120, []) where view.isEditable: askRename(); return true                // F2
            case (111, [.shift]): showReferences(); return true                           // ⇧F12
            case (3, [.shift, .option]) where view.isEditable: formatDocument(); return true // ⇧⌥F
            default: break
            }
            // A "." after a name: what can follow it.
            if flags.isEmpty, event.characters == ".", view.isEditable, hasServerLanguage {
                DispatchQueue.main.async { [weak self] in self?.requestCompletion() }
            }
            return nil
        }

        func uninstall() {
            editPopover?.close()
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

        /// Line and column of the cursor, from 1, for the status bar.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view, let report = parent.onCursor else { return }
            let range = view.selectedRange()
            let text = view.string as NSString
            let location = min(range.location, text.length)
            var line = 1
            var lineStart = 0
            var index = 0
            while index < location {
                if text.character(at: index) == 10 {
                    line += 1
                    lineStart = index + 1
                }
                index += 1
            }
            report((line, location - lineStart + 1, range.length))
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
            // The line the debugger is stopped on.
            if let stopped = parent.stoppedLine, stopped > 0 {
                let text = storage.string as NSString
                let start = LSPEdit.offset(line: stopped - 1, character: 0, in: text)
                if start < text.length || text.length == 0 {
                    let range = text.lineRange(for: NSRange(location: min(start, text.length), length: 0))
                    storage.addAttribute(.backgroundColor, value: NSColor(Theme.amber.opacity(0.28)), range: range)
                }
            }
            // Merge conflicts: the current side, the incoming side and the
            // marker lines, tinted the way an editor shows them.
            if storage.string.contains("<<<<<<<") {
                let text = storage.string as NSString
                var location = 0
                var side = 0   // 0 outside, 1 current, 2 base, 3 incoming
                while location < text.length {
                    let range = text.lineRange(for: NSRange(location: location, length: 0))
                    let line = text.substring(with: range)
                    var tint: Color?
                    if line.hasPrefix("<<<<<<<") { side = 1; tint = Theme.mint.opacity(0.32) }
                    else if line.hasPrefix("|||||||"), side == 1 { side = 2; tint = Theme.ink.opacity(0.14) }
                    else if line.hasPrefix("======="), side == 1 || side == 2 { side = 3; tint = Theme.ink.opacity(0.14) }
                    else if line.hasPrefix(">>>>>>>"), side == 3 { side = 0; tint = Theme.accent.opacity(0.32) }
                    else if side == 1 { tint = Theme.mint.opacity(0.12) }
                    else if side == 2 { tint = Theme.ink.opacity(0.06) }
                    else if side == 3 { tint = Theme.accent.opacity(0.12) }
                    if let tint { storage.addAttribute(.backgroundColor, value: NSColor(tint), range: range) }
                    location = NSMaxRange(range)
                }
            }
            storage.endEditing()
            markChanges()
        }
    }
}

/// The strip left of the editor's text, as in an editor's gutter: green
/// for lines added since HEAD, blue for lines changed, a red notch where
/// lines were taken out.
final class ChangeRuler: NSRulerView {
    enum Kind { case added, changed, removed }
    struct Mark: Equatable {
        /// Lines from 0, end not included; empty for a removal, at the line after it.
        let lines: Range<Int>
        let kind: Kind
    }

    var marks: [Mark] = [] {
        didSet { if marks != oldValue { needsDisplay = true } }
    }
    /// Lines with a breakpoint, from 1: a red dot each.
    var breakpoints: Set<Int> = [] {
        didSet { if breakpoints != oldValue { needsDisplay = true } }
    }
    /// A click in the strip sets or clears a breakpoint on that line.
    var toggle: ((Int) -> Void)?

    private static let width: CGFloat = 16

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = Self.width
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var requiredThickness: CGFloat { Self.width }

    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    /// Where each line starts in the text.
    private func starts(_ text: NSString) -> [Int] {
        var starts: [Int] = [0]
        var location = 0
        while location < text.length {
            location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
            starts.append(location)
        }
        return starts
    }

    override func mouseDown(with event: NSEvent) {
        guard let toggle, let view = clientView as? NSTextView,
              let layout = view.layoutManager, let container = view.textContainer else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        let inner = NSPoint(x: 1, y: point.y - view.textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: inner, in: container)
        let index = layout.characterIndexForGlyph(at: glyph)
        let text = view.string as NSString
        var line = 1
        for i in 0..<min(index, text.length) where text.character(at: i) == 10 { line += 1 }
        toggle(line)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard !marks.isEmpty || !breakpoints.isEmpty, let view = clientView as? NSTextView,
              let layout = view.layoutManager else { return }
        let text = view.string as NSString
        let starts = starts(text)
        func y(ofLine line: Int) -> (top: CGFloat, bottom: CGFloat) {
            guard text.length > 0 else { return (0, 14) }
            let index = min(starts[min(line, starts.count - 1)], max(0, text.length - 1))
            let glyph = layout.glyphIndexForCharacter(at: index)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let top = convert(NSPoint(x: 0, y: fragment.minY + view.textContainerOrigin.y), from: view).y
            let bottom = convert(NSPoint(x: 0, y: fragment.maxY + view.textContainerOrigin.y), from: view).y
            return (min(top, bottom), max(top, bottom))
        }
        for line in breakpoints {
            let place = y(ofLine: line - 1)
            let size: CGFloat = 8
            let dot = NSRect(x: 2, y: (place.top + place.bottom) / 2 - size / 2, width: size, height: size)
            guard dot.intersects(rect) else { continue }
            NSColor(Theme.rose).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        for mark in marks {
            let color: NSColor
            var band: NSRect
            switch mark.kind {
            case .added, .changed:
                color = NSColor(mark.kind == .added ? Theme.mint : Theme.accent)
                let first = y(ofLine: mark.lines.lowerBound)
                let last = y(ofLine: max(mark.lines.lowerBound, mark.lines.upperBound - 1))
                band = NSRect(x: Self.width - 4.5, y: first.top, width: 3, height: max(4, last.bottom - first.top))
            case .removed:
                color = NSColor(Theme.rose)
                let place = y(ofLine: mark.lines.lowerBound)
                band = NSRect(x: Self.width - 6, y: place.top - 2, width: 6, height: 4)
            }
            guard band.intersects(rect) else { continue }
            color.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: band, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

// MARK: - Search

private struct SearchTab: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: WorkspaceModel
    @FocusState private var focused: Bool
    /// The replace row is showing.
    @State private var replaceShown = false
    /// Replace All was pressed once; the second press does it.
    @State private var confirming = false

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
                IconButton(replaceShown ? "chevron.up" : "arrow.2.squarepath",
                           help: replaceShown ? "Hide replace" : "Replace in every file") {
                    replaceShown.toggle()
                    confirming = false
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(Theme.ink.opacity(0.07)))
            .overlay(Capsule().strokeBorder((focused ? Theme.accent : Theme.ink).opacity(focused ? 0.5 : 0.1), lineWidth: 0.75))
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, replaceShown ? 4 : 8)
            if replaceShown {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.ink.opacity(0.5))
                    TextField("Replace with", text: $model.replacement)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink.opacity(0.95))
                        .onChange(of: model.replacement) { _, _ in confirming = false }
                    if model.replacing {
                        LoadingMark(state: .working, size: 14)
                    } else {
                        Button(confirming ? "Replace in \(fileCount)\(model.hits.count >= 300 ? "+" : "") \(fileCount == 1 ? "file" : "files")?" : "Replace All") {
                            if confirming {
                                confirming = false
                                model.replaceAll(conversation: app.conversation.id)
                            } else {
                                confirming = true
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(confirming ? Theme.rose : Theme.accent)
                        .disabled(model.hits.isEmpty)
                        .help("Replace every match in every file. Each file is recorded in Changes, so it can be undone.")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(Theme.ink.opacity(0.07)))
                .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.1), lineWidth: 0.75))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
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
        .onChange(of: model.query) { _, _ in confirming = false }
    }

    /// Files among the matches found (at most the first 300 matches).
    private var fileCount: Int { Set(model.hits.map(\.path)).count }
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
    @EnvironmentObject var app: AppState
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
                                ProblemRow(problem: problem, fix: { app.fixProblem(problem) }) {
                                    model.open(problem.file, line: problem.line)
                                }
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
    /// Hands the problem to the agent.
    var fix: (() -> Void)? = nil
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
                if hover, let fix, problem.severity != .note {
                    Button(action: fix) {
                        Label("Fix", systemImage: "sparkles")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Have the agent fix this")
                }
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

    /// "Spaces: 4" or "Tabs", from how the file's lines start.
    static func indentation(of text: String) -> String {
        var tabs = 0
        var widths: [Int: Int] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(400) {
            if line.hasPrefix("\t") { tabs += 1; continue }
            let spaces = line.prefix { $0 == " " }.count
            if spaces > 0, spaces < line.count { widths[spaces, default: 0] += 1 }
        }
        let spaced = widths.values.reduce(0, +)
        if tabs > spaced { return "Tabs" }
        guard spaced > 0 else { return "Spaces: 4" }
        // The smallest step most lines are a multiple of.
        for size in [2, 4, 3, 8] {
            let fits = widths.filter { $0.key % size == 0 }.values.reduce(0, +)
            if Double(fits) / Double(spaced) > 0.9, widths.keys.contains(size) { return "Spaces: \(size)" }
        }
        return "Spaces: \(widths.keys.min() ?? 4)"
    }

    /// The language's name, by the file's extension.
    static func language(of path: String) -> String {
        let names: [String: String] = [
            "swift": "Swift", "py": "Python", "js": "JavaScript", "mjs": "JavaScript", "jsx": "JavaScript React",
            "ts": "TypeScript", "tsx": "TypeScript React", "html": "HTML", "css": "CSS", "scss": "SCSS",
            "json": "JSON", "md": "Markdown", "yml": "YAML", "yaml": "YAML", "toml": "TOML", "sh": "Shell",
            "zsh": "Shell", "bash": "Shell", "rs": "Rust", "go": "Go", "c": "C", "h": "C", "cpp": "C++",
            "hpp": "C++", "m": "Objective-C", "mm": "Objective-C++", "java": "Java", "kt": "Kotlin",
            "rb": "Ruby", "sql": "SQL", "xml": "XML", "txt": "Plain Text", "csv": "CSV"
        ]
        let ext = (path as NSString).pathExtension.lowercased()
        if (path as NSString).lastPathComponent == "Makefile" { return "Makefile" }
        return names[ext] ?? (ext.isEmpty ? "Plain Text" : ext.uppercased())
    }
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
            if !model.blame.isEmpty, model.diff == nil {
                Label(model.blame, systemImage: "person.crop.circle")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 280, alignment: .trailing)
                    .layoutPriority(-1)
                    .help("Last change to this line: \(model.blame)")
            }
            // About the open file, as an editor shows it: where the cursor
            // is, how it is indented, its encoding, line endings, language.
            if let path = model.openPath, model.diff == nil {
                Group {
                    Text("Ln \(model.cursor.line), Col \(model.cursor.column)"
                         + (model.cursor.selected > 0 ? " (\(model.cursor.selected) selected)" : ""))
                        .monospacedDigit()
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            Text(Self.indentation(of: model.text))
                            Text("UTF-8")
                            Text(model.text.contains("\r\n") ? "CRLF" : "LF")
                            Text(Self.language(of: path))
                        }
                        Text(Self.language(of: path))
                        EmptyView()
                    }
                }
                .lineLimit(1)
                .fixedSize()
            }
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
        .padding(.top, 2)
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

/// The strip down the left of the workspace, as in an editor: what the side
/// bar shows. The one showing is marked; the side bar is always open.
private struct ActivityBar: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: WorkspaceModel
    /// In code the side bar never closes: a click only changes what it shows.
    var keepsOpen = false
    @ObservedObject private var git = GitModel.shared
    /// The well under the one showing slides to the one chosen.
    @Namespace private var showing

    var body: some View {
        VStack(spacing: 4) {
            ForEach(WorkspaceModel.Activity.allCases) { activity in
                let on = model.activity == activity && (keepsOpen || !model.filesHidden)
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                        if on {
                            if !keepsOpen { model.filesHidden = true }
                        } else {
                            model.activity = activity
                            model.filesHidden = false
                        }
                    }
                } label: {
                    Image(systemName: activity.icon)
                        .font(.system(size: 13, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.accent : Theme.ink.opacity(0.5))
                        .frame(width: 34, height: 32)
                        .background {
                            // The one showing sits in a small well, a shade
                            // deeper than the strip, edged in the primary.
                            if on {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Theme.shade.opacity(Theme.isLight ? 0.7 : 0.35))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Theme.accent.opacity(0.3), lineWidth: 0.75))
                                    .frame(width: 32, height: 30)
                                    .matchedGeometryEffect(id: "showing", in: showing)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if activity == .source, git.count > 0 {
                                Text(git.count > 99 ? "99+" : "\(git.count)")
                                    .font(.system(size: 7, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 2)
                                    .frame(minWidth: 10, minHeight: 10)
                                    .background(Capsule().fill(Theme.accent))
                                    .fixedSize()
                                    .offset(x: 1, y: 3)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(on ? "Put the side bar away" : activity.rawValue)
            }
            Spacer(minLength: 0)
            // In code, Settings and Quit sit at the foot of the bar, as in
            // an editor; in chat they stay at the foot of the chats.
            if app.codeMode {
                BarFootButton("gearshape.fill", help: "Settings", on: app.showSettings) {
                    if app.showSettings {
                        app.showSettings = false
                    } else {
                        app.openSettings()
                    }
                }
                BarFootButton("power", help: "Quit Companion (⌘Q)", tint: Theme.rose) {
                    app.requestQuit()
                }
                .padding(.bottom, 6)
            }
        }
        .padding(.top, 6)
        .frame(width: 40)
        .clipped()
        // The strip is a shade lighter than the side bar beside it, as an
        // editor's bar is.
        .background(Theme.card)
    }
}

/// A button at the foot of the activity bar: the same size as the bar's own,
/// quiet until the pointer is on it. On (Settings open) it sits in the
/// bar's well, in the primary.
private struct BarFootButton: View {
    let symbol: String
    let help: String
    var tint: Color?
    var on = false
    let action: () -> Void
    @State private var hover = false

    init(_ symbol: String, help: String, tint: Color? = nil, on: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.tint = tint
        self.on = on
        self.action = action
    }

    var body: some View {
        let color = on ? Theme.accent : (tint ?? Theme.ink)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on || hover ? color : color.opacity(tint == nil ? 0.5 : 0.7))
                .frame(width: 34, height: 32)
                .background {
                    if on || hover {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(on ? Theme.shade.opacity(Theme.isLight ? 0.7 : 0.35) : color.opacity(0.12))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Theme.accent.opacity(on ? 0.3 : 0), lineWidth: 0.75))
                            .frame(width: 32, height: 30)
                            .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(help)
    }
}

/// A small box the editor shows by the text: for an inline edit (⌘I),
/// a line to go to (⌃G) or a new name (F2).
private struct EditorPrompt: View {
    let icon: String
    let title: String
    let placeholder: String
    var initial = ""
    var multiline = false
    /// What was typed, or nil when dismissed.
    let done: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.7))
                Spacer(minLength: 4)
                Text("↩ to apply · esc to close")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ink.opacity(0.4))
            }
            Group {
                if multiline {
                    TextField(placeholder, text: $text, axis: .vertical).lineLimit(1...4)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .focused($focused)
            .onSubmit(send)
            .onKeyPress(.escape) {
                done(nil)
                return .handled
            }
        }
        .padding(10)
        .frame(width: multiline ? 360 : 280)
        .onAppear {
            text = initial
            focused = true
        }
    }

    private func send() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        done(value)
    }
}

/// Where a symbol is used (⇧F12), file by file; a click goes there.
private struct ReferencesList: View {
    let symbol: String
    let items: [LSPLocation]
    let root: String
    let pick: (LSPLocation) -> Void

    private func name(_ path: String) -> String {
        guard !root.isEmpty, path.hasPrefix(root + "/") else { return (path as NSString).abbreviatingWithTildeInPath }
        return String(path.dropFirst(root.count + 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(items.count) \(items.count == 1 ? "place uses" : "places use") \(symbol)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            Rectangle().fill(Theme.ink.opacity(0.07)).frame(height: 1)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(items) { item in
                        ReferenceRow(name: name(item.path), item: item) { pick(item) }
                    }
                }
                .padding(5)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 420)
    }
}

private struct ReferenceRow: View {
    let name: String
    let item: LSPLocation
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
                Text("\(item.line)")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink.opacity(0.45))
            }
            Text(item.preview)
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
