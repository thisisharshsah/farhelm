import AppKit
import Foundation

/// Keys that run a command while Companion's panel is the window in use.
/// These are not global: in any other app the same keys do what they
/// always do there.
struct KeyChord {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    /// The keys as shown: "⇧⌘P".
    let display: String

    static func cmd(_ keyCode: UInt16, _ key: String) -> KeyChord {
        KeyChord(keyCode: keyCode, modifiers: .command, display: "⌘" + key)
    }

    static func cmdShift(_ keyCode: UInt16, _ key: String) -> KeyChord {
        KeyChord(keyCode: keyCode, modifiers: [.command, .shift], display: "⇧⌘" + key)
    }

    static func ctrl(_ keyCode: UInt16, _ key: String) -> KeyChord {
        KeyChord(keyCode: keyCode, modifiers: .control, display: "⌃" + key)
    }

    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode
            && event.modifierFlags.intersection([.command, .shift, .option, .control]) == modifiers
    }
}

/// One thing Companion can do, by name. Everything a person can trigger is
/// registered as a command, so it can be found in the palette, given keys,
/// and called from anywhere by its id. A feature adds its actions by
/// registering commands, not by adding buttons only it knows about.
struct Command: Identifiable {
    /// Stable and namespaced: "view.toggleSidebar", "file.save".
    let id: String
    let title: String
    /// The group it is listed under: "View", "Chat", "File".
    let category: String
    var icon: String = "command"
    /// Keys that run it inside the panel.
    var keys: KeyChord?
    /// Keys handled somewhere else (a global shortcut), for display only.
    var shortcut: @MainActor () -> String? = { nil }
    /// Whether it can run now. One that cannot is left out of the palette
    /// and its keys pass through.
    var available: @MainActor () -> Bool = { true }
    let run: @MainActor () -> Void
}

/// Every command, the keys that run them, and the palette's state.
@MainActor
final class CommandRegistry: ObservableObject {
    static let shared = CommandRegistry()

    @Published private(set) var all: [Command] = []
    /// The palette: open or not, and what is typed in it. Text that starts
    /// with ">" looks for commands; anything else looks for files.
    @Published var paletteOpen = false
    @Published var paletteQuery = ""

    /// The commands run most recently, newest first. They lead the list.
    private var recent: [String]
    private let recentKey = "recentCommands"

    private init() {
        recent = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
    }

    /// Adds commands. One registered again under the same id replaces the
    /// earlier one.
    func register(_ commands: [Command]) {
        for command in commands {
            if let index = all.firstIndex(where: { $0.id == command.id }) {
                all[index] = command
            } else {
                all.append(command)
            }
        }
    }

    func command(_ id: String) -> Command? {
        all.first { $0.id == id }
    }

    /// Runs a command by id, if it can run now.
    @discardableResult
    func run(_ id: String) -> Bool {
        guard let command = command(id), command.available() else { return false }
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        recent = Array(recent.prefix(12))
        UserDefaults.standard.set(recent, forKey: recentKey)
        command.run()
        return true
    }

    /// Runs the command a key press belongs to. False when the keys are
    /// nobody's, so the press goes on to whatever has the focus.
    func handle(_ event: NSEvent) -> Bool {
        guard let command = all.first(where: { $0.keys?.matches(event) == true }) else { return false }
        return run(command.id)
    }

    /// The keys to show for a command, wherever they are handled.
    func keysLabel(_ command: Command) -> String? {
        command.keys?.display ?? command.shortcut()
    }

    // MARK: Palette

    func openPalette(commands: Bool) {
        paletteQuery = commands ? ">" : ""
        paletteOpen = true
    }

    func closePalette() {
        paletteOpen = false
    }

    /// The commands that can run now and fit what is typed, best first.
    /// With nothing typed: the recent ones, then the rest by group.
    func matches(_ query: String) -> [Command] {
        let usable = all.filter { $0.available() }
        let wanted = query.trimmingCharacters(in: .whitespaces)
        if wanted.isEmpty {
            let first = recent.compactMap { id in usable.first { $0.id == id } }
            let rest = usable.filter { !recent.contains($0.id) }
                .sorted { ($0.category, $0.title) < ($1.category, $1.title) }
            return first + rest
        }
        var scored: [(score: Int, command: Command)] = []
        for command in usable {
            if let score = Fuzzy.score(wanted, in: "\(command.category): \(command.title)") {
                scored.append((score, command))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.command.title < $1.command.title }
        return scored.map(\.command)
    }
}

/// Matching the way a palette does: the letters typed must appear in
/// order, not side by side. Letters at the start of a word, and runs of
/// letters together, count for more, so "tsb" finds "Toggle Sidebar".
enum Fuzzy {
    /// How well `text` fits, higher is better; nil when it does not.
    static func score(_ query: String, in text: String) -> Int? {
        let needle = query.utf8.filter { $0 != 32 }.map(lower)
        guard !needle.isEmpty else { return 0 }
        var score = 0
        var found = 0
        var index = 0
        var last = -2
        // The start of the text counts as the start of a word.
        var previous: UInt8 = 47
        for raw in text.utf8 {
            if found < needle.count, lower(raw) == needle[found] {
                score += 1
                if index == last + 1 { score += 4 }
                if isBreak(previous) || (isUpper(raw) && !isUpper(previous)) { score += 6 }
                last = index
                found += 1
            }
            previous = raw
            index += 1
        }
        guard found == needle.count else { return nil }
        // Of two that fit equally, the shorter is the closer one.
        return score * 8 - min(index, 160) / 4
    }

    private static func lower(_ byte: UInt8) -> UInt8 {
        isUpper(byte) ? byte + 32 : byte
    }

    private static func isUpper(_ byte: UInt8) -> Bool {
        byte >= 65 && byte <= 90
    }

    /// A character words are separated by: / space . _ - :
    private static func isBreak(_ byte: UInt8) -> Bool {
        byte == 47 || byte == 32 || byte == 46 || byte == 95 || byte == 45 || byte == 58
    }
}

/// The files of the folder a code chat works in, for going to one by
/// name. Listed off the main thread, and again when the list is old.
@MainActor
final class FileIndex: ObservableObject {
    static let shared = FileIndex()

    /// Paths relative to the folder.
    @Published private(set) var files: [String] = []
    @Published private(set) var loading = false
    private(set) var root = ""
    private var loaded = Date.distantPast
    /// Files opened by name in this folder, newest first.
    private var recent: [String] = []

    /// Points the index at a folder and lists it if that has not been done
    /// in the last while.
    func use(root folder: String) {
        if folder != root {
            root = folder
            files = []
            recent = []
            loaded = .distantPast
        }
        guard !folder.isEmpty, !loading, Date().timeIntervalSince(loaded) > 20 else { return }
        loading = true
        Task {
            let found = await Self.list(folder)
            self.loading = false
            guard folder == self.root else { return }
            self.files = found
            self.loaded = Date()
        }
    }

    func noteOpened(_ file: String) {
        recent.removeAll { $0 == file }
        recent.insert(file, at: 0)
        recent = Array(recent.prefix(20))
    }

    /// The files that fit what is typed, best first. A fit in the file's
    /// name counts for more than one in its folders.
    func matches(_ query: String, limit: Int = 60) -> [String] {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        if wanted.isEmpty {
            let rest = files.lazy.filter { !self.recent.contains($0) }.prefix(max(0, limit - recent.count))
            return recent + Array(rest)
        }
        var scored: [(score: Int, file: String)] = []
        for file in files {
            let name = (file as NSString).lastPathComponent
            let inName = Fuzzy.score(wanted, in: name).map { $0 + 60 }
            guard let score = inName ?? Fuzzy.score(wanted, in: file) else { continue }
            scored.append((score, file))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.file < $1.file }
        return scored.prefix(limit).map(\.file)
    }

    /// Every file under a folder. A git repository is asked, so what it
    /// ignores stays out; any other folder is walked, skipping the usual
    /// build and dependency folders.
    private nonisolated static func list(_ folder: String) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let limit = 30_000
                let git = Process()
                git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                git.arguments = ["-C", folder, "ls-files", "--cached", "--others", "--exclude-standard"]
                let pipe = Pipe()
                git.standardOutput = pipe
                git.standardError = FileHandle.nullDevice
                if (try? git.run()) != nil {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    git.waitUntilExit()
                    if git.terminationStatus == 0, let text = String(data: data, encoding: .utf8) {
                        let found = text.split(separator: "\n").prefix(limit).map(String.init)
                        if !found.isEmpty {
                            continuation.resume(returning: found)
                            return
                        }
                    }
                }
                var found: [String] = []
                if let walker = FileManager.default.enumerator(atPath: folder) {
                    while let path = walker.nextObject() as? String, found.count < limit {
                        let name = (path as NSString).lastPathComponent
                        if workspaceHiddenNames.contains(name) {
                            walker.skipDescendants()
                            continue
                        }
                        if walker.fileAttributes?[.type] as? FileAttributeType == .typeRegular {
                            found.append(path)
                        }
                    }
                }
                continuation.resume(returning: found.sorted())
            }
        }
    }
}

// MARK: - Built-in commands

extension CommandRegistry {
    /// What Companion itself can do, registered once at launch. Key codes
    /// are the Mac's own for the key named beside them.
    func registerBuiltIns() {
        let app = AppState.shared
        let inCode: @MainActor () -> Bool = { AppState.shared.hasWorkFolder }
        let fileOpen: @MainActor () -> Bool = { AppState.shared.workspace.openPath != nil }
        let inRepository: @MainActor () -> Bool = { AppState.shared.hasWorkFolder && GitModel.shared.isRepository }

        /// Shows one of the tabs of the workspace's bottom panel.
        func workspaceTab(_ tab: WorkspaceModel.Tab) {
            if app.sidePanel != .workspace { app.showSide(.workspace) }
            app.workspace.showPanel(tab)
        }

        register([
            // Palette
            Command(id: "palette.commands", title: "Show All Commands", category: "View", icon: "command",
                    keys: .cmdShift(35, "P")) {
                CommandRegistry.shared.openPalette(commands: true)
            },
            Command(id: "palette.files", title: "Go to File", category: "File", icon: "magnifyingglass",
                    keys: .cmd(35, "P")) {
                CommandRegistry.shared.openPalette(commands: false)
            },

            // View
            Command(id: "view.toggleSidebar", title: "Toggle Sidebar", category: "View", icon: "sidebar.left",
                    keys: .cmd(11, "B")) {
                app.refreshHistory()
                app.sidebarPinned.toggle()
                app.overlay?.setSidebar(app.sidebarPinned)
            },
            Command(id: "view.chat", title: "Switch to Chat", category: "View", icon: "bubble.left.and.bubble.right",
                    available: { AppState.shared.codeMode }) {
                app.setCode(false)
            },
            Command(id: "view.code", title: "Switch to Code", category: "View",
                    icon: "chevron.left.forwardslash.chevron.right",
                    available: { !AppState.shared.codeMode }) {
                app.setCode(true)
            },
            Command(id: "view.files", title: "Show Files", category: "View", icon: "folder",
                    keys: .cmdShift(14, "E"), available: inCode) {
                workspaceTab(.files)
            },
            Command(id: "view.search", title: "Search in Files", category: "View", icon: "magnifyingglass",
                    keys: .cmdShift(3, "F"), available: inCode) {
                workspaceTab(.search)
            },
            Command(id: "view.changes", title: "Show Changes", category: "View", icon: "pencil.and.list.clipboard",
                    available: inCode) {
                workspaceTab(.changes)
            },
            Command(id: "view.git", title: "Show Source Control", category: "View", icon: "arrow.triangle.branch",
                    keys: KeyChord(keyCode: 5, modifiers: [.control, .shift], display: "⌃⇧G"), available: inCode) {
                workspaceTab(.source)
            },
            Command(id: "git.refresh", title: "Refresh", category: "Git", icon: "arrow.clockwise",
                    available: inRepository) {
                GitModel.shared.refresh()
            },
            Command(id: "git.stageAll", title: "Stage All Changes", category: "Git", icon: "plus",
                    available: inRepository) {
                GitModel.shared.stageAll()
            },
            Command(id: "git.unstageAll", title: "Unstage All Changes", category: "Git", icon: "minus",
                    available: inRepository) {
                GitModel.shared.unstageAll()
            },
            Command(id: "git.pull", title: "Pull", category: "Git", icon: "arrow.down", available: inRepository) {
                GitModel.shared.pull()
            },
            Command(id: "git.push", title: "Push", category: "Git", icon: "arrow.up", available: inRepository) {
                GitModel.shared.push()
            },
            Command(id: "view.panel", title: "Toggle Panel", category: "View",
                    icon: "inset.filled.bottomthird.rectangle", keys: .cmd(38, "J"), available: inCode) {
                if app.sidePanel != .workspace { app.showSide(.workspace) }
                app.workspace.panelOpen.toggle()
            },
            Command(id: "view.terminal", title: "Toggle Terminal", category: "View", icon: "terminal",
                    keys: .ctrl(50, "`"), available: inCode) {
                // It is a tab of the panel along the bottom: the keys
                // bring it up, and put the panel away when it is showing.
                if app.sidePanel != .workspace {
                    app.showSide(.workspace)
                    app.workspace.showPanel(.terminal)
                } else if app.workspace.panelOpen, app.workspace.tab == .terminal {
                    app.workspace.panelOpen = false
                } else {
                    app.workspace.showPanel(.terminal)
                }
            },
            Command(id: "build.run", title: "Build and Show Problems", category: "Build", icon: "hammer",
                    keys: .cmdShift(11, "B"), available: inCode) {
                workspaceTab(.problems)
                ProblemsModel.shared.run(in: app.workspace.root)
            },
            Command(id: "view.splitEditor", title: "Open Editor to the Side", category: "View",
                    icon: "rectangle.split.2x1", keys: .cmd(42, "\\"), available: inCode) {
                let workspace = app.workspace
                if workspace.sidePath != nil {
                    workspace.closeSide()
                } else if let path = workspace.openPath {
                    workspace.openToSide(path)
                }
            },
            Command(id: "view.outline", title: "Show Outline", category: "View", icon: "list.bullet.indent",
                    available: inCode) {
                app.workspace.activity = .outline
                app.workspace.filesHidden = false
            },
            Command(id: "view.timeline", title: "Show Timeline", category: "View",
                    icon: "calendar.day.timeline.left", available: inCode) {
                app.workspace.activity = .timeline
                app.workspace.filesHidden = false
            },
            Command(id: "view.preview", title: "Toggle Preview", category: "View", icon: "eye",
                    available: { inCode() && AppState.shared.workspace.canPreview }) {
                app.workspace.previewing.toggle()
            },
            Command(id: "debug.start", title: "Start Debugging / Continue", category: "Debug", icon: "ladybug",
                    keys: KeyChord(keyCode: 96, modifiers: [], display: "F5"), available: inCode) {
                workspaceTab(.debug)
                DebugModel.shared.start(in: app.workspace.root)
            },
            Command(id: "debug.stop", title: "Stop Debugging", category: "Debug", icon: "stop.fill",
                    keys: KeyChord(keyCode: 96, modifiers: .shift, display: "⇧F5"),
                    available: { DebugModel.shared.active }) {
                DebugModel.shared.stop()
            },
            Command(id: "debug.stepOver", title: "Step Over", category: "Debug", icon: "arrow.uturn.forward",
                    keys: KeyChord(keyCode: 109, modifiers: [], display: "F10"),
                    available: { DebugModel.shared.isStopped }) {
                DebugModel.shared.stepOver()
            },
            Command(id: "debug.stepIn", title: "Step Into", category: "Debug", icon: "arrow.down.to.line",
                    keys: KeyChord(keyCode: 103, modifiers: [], display: "F11"),
                    available: { DebugModel.shared.isStopped }) {
                DebugModel.shared.stepIn()
            },
            Command(id: "debug.stepOut", title: "Step Out", category: "Debug", icon: "arrow.up.to.line",
                    keys: KeyChord(keyCode: 103, modifiers: .shift, display: "⇧F11"),
                    available: { DebugModel.shared.isStopped }) {
                DebugModel.shared.stepOut()
            },
            Command(id: "debug.clearBreakpoints", title: "Remove All Breakpoints", category: "Debug", icon: "xmark.circle",
                    available: { !DebugModel.shared.breakpoints.isEmpty }) {
                DebugModel.shared.clearBreakpoints()
            },
            Command(id: "test.run", title: "Run Tests", category: "Build", icon: "testtube.2", available: inCode) {
                workspaceTab(.tests)
                TestModel.shared.run(in: app.workspace.root)
            },
            Command(id: "task.again", title: "Run Last Task Again", category: "Build", icon: "play",
                    available: { AppState.shared.workspace.lastTask != nil }) {
                if let task = app.workspace.lastTask { app.workspace.run(task) }
            },
            Command(id: "view.ports", title: "Show Ports", category: "View", icon: "antenna.radiowaves.left.and.right", available: inCode) {
                workspaceTab(.ports)
            },
            Command(id: "view.github", title: "Show Pull Requests and Runs", category: "View",
                    icon: "arrow.triangle.pull", available: inCode) {
                workspaceTab(.github)
            },
            Command(id: "view.problems", title: "Show Problems", category: "View",
                    icon: "exclamationmark.triangle", keys: .cmdShift(46, "M"), available: inCode) {
                workspaceTab(.problems)
            },
            Command(id: "view.browser", title: "Open Browser", category: "View", icon: "globe") {
                app.showSide(.browser)
            },
            Command(id: "view.details", title: "Show Details", category: "View", icon: "info.circle") {
                app.showSide(.details)
            },
            Command(id: "view.closeSide", title: "Close Side Panel", category: "View", icon: "sidebar.right",
                    available: { AppState.shared.sidePanel != nil && !AppState.shared.codeMode }) {
                app.showSide(nil)
            },
            Command(id: "view.settings", title: "Open Settings", category: "View", icon: "gearshape",
                    keys: .cmd(43, ",")) {
                app.openSettings()
            },

            // Chat
            Command(id: "chat.new", title: "New Conversation", category: "Chat", icon: "plus",
                    keys: .cmd(45, "N")) {
                app.newConversation()
            },
            Command(id: "chat.focus", title: "Focus Chat Box", category: "Chat", icon: "text.cursor") {
                app.focusInputRequest += 1
            },

            // What the agent is given beyond the chat
            Command(id: "skills.openFolder", title: "Open Skills Folder", category: "Agent", icon: "book.closed") {
                let folder = ProjectContext.skillsFolder
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(folder)
            },
            Command(id: "project.instructions", title: "Open Project Instructions", category: "Agent",
                    icon: "doc.text", available: inCode) {
                // The repository's own file, or a new COMPANION.md to start one.
                let root = app.agentStartDirectory
                let name = ProjectContext.instructions(in: root)?.name ?? "COMPANION.md"
                let path = (root as NSString).appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: path) {
                    let start = "# Project instructions\n\nWhat anyone working in this repository should know: how to build and test it, its conventions, and what to leave alone.\n"
                    try? start.write(toFile: path, atomically: true, encoding: .utf8)
                    app.workspace.refreshAll()
                }
                // Opening a file always brings up code mode.
                app.openInWorkspace(path)
            },

            // Code
            Command(id: "code.openFolder", title: "Open Folder", category: "File", icon: "folder.badge.plus",
                    keys: .cmd(31, "O")) {
                app.pickWorkFolder()
            },
            Command(id: "file.openFiles", title: "Open Files…", category: "File", icon: "doc.on.doc") {
                app.pickFilesToOpen()
            },
            Command(id: "file.save", title: "Save", category: "File", icon: "square.and.arrow.down",
                    shortcut: { "⌘S" }, available: { AppState.shared.workspace.dirty || AppState.shared.workspace.sideDirty }) {
                app.workspace.saveAll(conversation: app.conversation.id)
            },
            Command(id: "file.newFile", title: "New File…", category: "File", icon: "doc.badge.plus",
                    available: { !AppState.shared.workspace.root.isEmpty }) {
                app.workspace.startNew(folder: false)
            },
            Command(id: "file.newFolder", title: "New Folder…", category: "File", icon: "folder.badge.plus",
                    available: { !AppState.shared.workspace.root.isEmpty }) {
                app.workspace.startNew(folder: true)
            },
            Command(id: "file.close", title: "Close File", category: "File", icon: "xmark", available: fileOpen) {
                // Closes the file's tab and moves to the next open one.
                if let path = app.workspace.openPath {
                    app.workspace.close(path, conversation: app.conversation.id)
                } else {
                    app.workspace.closeFile()
                }
            },
            Command(id: "file.reveal", title: "Reveal in Finder", category: "File", icon: "folder",
                    available: fileOpen) {
                guard let path = app.workspace.openPath else { return }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            },
            Command(id: "file.copyPath", title: "Copy Path", category: "File", icon: "doc.on.doc",
                    available: fileOpen) {
                guard let path = app.workspace.openPath else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            },
            Command(id: "file.copyRelativePath", title: "Copy Relative Path", category: "File", icon: "doc.on.doc",
                    available: fileOpen) {
                guard let path = app.workspace.openPath else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.workspace.relative(path), forType: .string)
            }
        ])

        // What the global shortcuts do is in the list too, with the keys
        // they have now.
        register(ShortcutAction.allCases.map { action in
            Command(id: "global.\(action.rawValue)", title: action.title, category: "Companion",
                    icon: "bolt", shortcut: { Shortcuts.shared.label(action) }) {
                action.perform()
            }
        })
    }
}
