import AppKit
import Foundation

/// One file git sees a change in, either staged for the next commit or
/// still only in the working folder. A file changed in both places is two
/// of these.
struct GitFile: Identifiable, Equatable {
    enum Kind: String {
        case modified = "M"
        case added = "A"
        case deleted = "D"
        case renamed = "R"
        /// New and not yet known to git.
        case untracked = "U"
        /// Changed on both sides of a merge and waiting to be settled.
        case conflict = "C"
    }

    /// Relative to the repository's top folder.
    let path: String
    let kind: Kind
    let staged: Bool

    var id: String { (staged ? "staged:" : "working:") + path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

/// The repository the workspace's folder belongs to: its branch, what has
/// changed, and the everyday actions on it (stage, commit, switch branch,
/// pull, push). It asks git itself each time, so it always shows what a
/// terminal would.
///
/// Nothing here rewrites history or forces anything: no amend, no reset of
/// commits, no force push. Discarding a file's changes is the one action
/// that loses work, and it is recorded in Changes so it can be undone.
@MainActor
final class GitModel: ObservableObject {
    static let shared = GitModel()

    /// The workspace's folder, and the top of the repository it is in
    /// (empty when it is in none).
    @Published private(set) var folder = ""
    @Published private(set) var root = ""
    /// False until git has been asked once about this folder.
    @Published private(set) var loaded = false

    @Published private(set) var branch = ""
    @Published private(set) var upstream = ""
    @Published private(set) var ahead = 0
    @Published private(set) var behind = 0
    @Published private(set) var branches: [String] = []
    @Published private(set) var staged: [GitFile] = []
    @Published private(set) var unstaged: [GitFile] = []

    /// The message for the next commit.
    @Published var message = ""
    @Published private(set) var busy = false
    /// What the last action said: its result, or why it failed.
    @Published var note = ""
    @Published private(set) var noteFailed = false

    /// The file whose changes are showing, and the comparison itself.
    @Published private(set) var shown: GitFile?
    @Published private(set) var shownRows: [LineDiff.Row] = []
    @Published private(set) var shownNote = ""

    var isRepository: Bool { !root.isEmpty }
    var count: Int { staged.count + unstaged.count }

    /// Prompts for a password have nowhere to be answered here, so git is
    /// told not to ask: it fails with a message instead of waiting.
    private static let quiet = "GIT_TERMINAL_PROMPT=0 "

    // MARK: Reading

    /// Points at the workspace's folder and reads its state.
    func use(folder: String) {
        if folder != self.folder {
            self.folder = folder
            root = ""
            loaded = false
            branch = ""
            staged = []
            unstaged = []
            branches = []
            note = ""
            shown = nil
        }
        refresh()
    }

    func refresh() {
        Task { await reload() }
    }

    private func reload() async {
        let folder = self.folder
        guard !folder.isEmpty else { return }
        let top = await Shell.run("git rev-parse --show-toplevel", in: folder, timeout: 10)
        guard folder == self.folder else { return }
        guard top.ok, let line = top.output.split(separator: "\n").last else {
            root = ""
            branch = ""
            staged = []
            unstaged = []
            branches = []
            loaded = true
            return
        }
        let root = String(line).trimmingCharacters(in: .whitespaces)
        // Ends of entries are marked with a zero byte, so a file's name
        // can hold anything.
        let status = await Shell.run("git status --porcelain=v1 -b -z --untracked-files=all", in: root, timeout: 20)
        let list = await Shell.run("git branch --format='%(refname:short)'", in: root, timeout: 10)
        guard folder == self.folder else { return }
        self.root = root
        if status.ok { read(status.output) }
        branches = list.ok
            ? list.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("(") }
            : []
        loaded = true
        // The file being looked at may have changed, or be settled.
        if let shown {
            if (staged + unstaged).contains(shown) {
                await compare(shown)
            } else {
                self.shown = nil
            }
        }
    }

    /// Reads `git status --porcelain=v1 -b -z`: a line about the branch,
    /// then one entry a file, each "XY path" with X the staged state and Y
    /// the working folder's.
    private func read(_ output: String) {
        var staged: [GitFile] = []
        var unstaged: [GitFile] = []
        branch = ""
        upstream = ""
        ahead = 0
        behind = 0
        // Anything a shell printed before git's own output is passed over.
        let text = output.range(of: "## ").map { String(output[$0.lowerBound...]) } ?? output
        var tokens = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let token = tokens.popFirst() {
            if token.hasPrefix("## ") {
                readBranch(String(token.dropFirst(3)))
                continue
            }
            let characters = Array(token)
            guard characters.count > 3 else { continue }
            let x = characters[0], y = characters[1]
            let path = String(characters[3...])
            // A rename or copy is followed by the name it had before.
            if x == "R" || x == "C" || y == "R" || y == "C" { _ = tokens.popFirst() }
            if x == "?" {
                unstaged.append(GitFile(path: path, kind: .untracked, staged: false))
            } else if x == "!" {
                continue
            } else if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") {
                unstaged.append(GitFile(path: path, kind: .conflict, staged: false))
            } else {
                if x != " " { staged.append(GitFile(path: path, kind: Self.kind(x), staged: true)) }
                if y != " " { unstaged.append(GitFile(path: path, kind: Self.kind(y), staged: false)) }
            }
        }
        self.staged = staged
        self.unstaged = unstaged
    }

    private static func kind(_ letter: Character) -> GitFile.Kind {
        switch letter {
        case "A", "C": return .added
        case "D": return .deleted
        case "R": return .renamed
        default: return .modified
        }
    }

    /// "main...origin/main [ahead 1, behind 2]", "No commits yet on main",
    /// or "HEAD (no branch)".
    private func readBranch(_ header: String) {
        if header.hasPrefix("No commits yet on ") {
            branch = String(header.dropFirst(18))
            return
        }
        if header.hasPrefix("HEAD (no branch)") {
            branch = "detached"
            return
        }
        guard let dots = header.range(of: "...") else {
            branch = header
            return
        }
        branch = String(header[..<dots.lowerBound])
        let rest = String(header[dots.upperBound...])
        upstream = String(rest.prefix { $0 != " " })
        ahead = Self.number(after: "ahead ", in: rest)
        behind = Self.number(after: "behind ", in: rest)
    }

    private static func number(after word: String, in text: String) -> Int {
        guard let found = text.range(of: word) else { return 0 }
        return Int(text[found.upperBound...].prefix { $0.isNumber }) ?? 0
    }

    // MARK: Acting

    /// Runs one git command in the repository, says how it went, and reads
    /// the state again.
    private func run(_ command: String, done: String = "", timeout: TimeInterval = 60,
                     then: (@MainActor () -> Void)? = nil) {
        guard isRepository, !busy else { return }
        busy = true
        note = ""
        let root = self.root
        Task {
            let result = await Shell.run(Self.quiet + command, in: root, timeout: timeout)
            busy = false
            if result.ok {
                note = done
                noteFailed = false
                then?()
            } else {
                let said = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                note = said.isEmpty ? "That did not work." : String(said.suffix(400))
                noteFailed = true
            }
            await reload()
            // Files may have changed under the workspace.
            let workspace = AppState.shared.workspace
            workspace.refreshAll()
            if let open = workspace.openPath { workspace.reloadIfOpen(open) }
        }
    }

    func stage(_ file: GitFile) {
        run("git add -A -- \(Shell.quote(file.path))")
    }

    func unstage(_ file: GitFile) {
        // The second form is for a repository with no commit yet.
        let path = Shell.quote(file.path)
        run("git restore --staged -- \(path) 2>/dev/null || git rm -q --cached -- \(path)")
    }

    func stageAll() {
        run("git add -A")
    }

    func unstageAll() {
        run("git reset -q 2>/dev/null || git rm -r -q --cached .")
    }

    /// Drops a file's changes in the working folder. A file git does not
    /// know goes to the Trash; any other goes back to what is staged. What
    /// it held is kept in Changes, so this can be undone there.
    func discard(_ file: GitFile) {
        guard isRepository, !busy, !file.staged else { return }
        let full = (root as NSString).appendingPathComponent(file.path)
        let before = ChangeStore.shared.snapshot(full)
        let record: @MainActor () -> Void = {
            ChangeStore.shared.record(path: full, before: before, task: "Discarded by you",
                                      conversation: AppState.shared.conversation.id)
        }
        if file.kind == .untracked {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: full), resultingItemURL: nil)
                record()
                note = "\(file.name) is in the Trash."
                noteFailed = false
            } catch {
                note = "Could not move \(file.name) to the Trash: \(error.localizedDescription)"
                noteFailed = true
            }
            refresh()
            AppState.shared.workspace.refreshAll()
        } else {
            run("git restore -- \(Shell.quote(file.path))", done: "Changes to \(file.name) discarded. Undo it from Changes.",
                then: record)
        }
    }

    /// Commits what is staged, with the message as written. With nothing
    /// staged, everything that changed is staged first.
    func commit() {
        // The commit is the user's: no co-author or AI credit lines.
        let text = CommitHygiene.clean(message)
        guard !text.isEmpty else {
            note = "Write a message for the commit first."
            noteFailed = true
            return
        }
        let all = staged.isEmpty ? "git add -A && " : ""
        run(all + "git commit -q -m \(Shell.quote(text))", done: "Committed.") { [weak self] in
            self?.message = ""
        }
    }

    func switchTo(_ name: String) {
        guard name != branch else { return }
        run("git switch \(Shell.quote(name))", done: "On \(name).")
    }

    func createBranch(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        guard !name.isEmpty else { return }
        run("git switch -c \(Shell.quote(name))", done: "On the new branch \(name).")
    }

    /// Brings in what the remote has, only when that needs no merge.
    func pull() {
        run("git pull --ff-only", done: "Up to date with the remote.", timeout: 120)
    }

    /// Sends this branch's commits to its remote. A branch the remote does
    /// not have yet is created there under the same name.
    func push() {
        let command = upstream.isEmpty ? "git push -u origin \(Shell.quote(branch))" : "git push"
        run(command, done: "Pushed.", timeout: 120)
    }

    func initialize() {
        guard !folder.isEmpty, !busy else { return }
        busy = true
        let folder = self.folder
        Task {
            let result = await Shell.run("git init -q", in: folder, timeout: 20)
            busy = false
            note = result.ok ? "" : String(result.output.suffix(300))
            noteFailed = !result.ok
            await reload()
        }
    }

    // MARK: Comparing

    /// Shows what changed in a file, or goes back to the list for nil.
    func show(_ file: GitFile?) {
        shown = file
        shownRows = []
        shownNote = ""
        guard let file else { return }
        Task { await compare(file) }
    }

    /// A staged file is compared with the last commit; one in the working
    /// folder with what is staged.
    private func compare(_ file: GitFile) async {
        let root = self.root
        func stored(_ revision: String) async -> String {
            let result = await Shell.run("git show \(Shell.quote(revision + ":" + file.path))", in: root, timeout: 20)
            return result.ok ? result.output : ""
        }
        var before = ""
        var after = ""
        if file.staged {
            if file.kind != .added { before = await stored("HEAD") }
            if file.kind != .deleted { after = await stored("") }
        } else {
            if file.kind != .untracked { before = await stored("") }
            let full = (root as NSString).appendingPathComponent(file.path)
            after = (try? String(contentsOfFile: full, encoding: .utf8)) ?? ""
        }
        guard shown == file else { return }
        // Side by side, where the open file would be.
        AppState.shared.workspace.showDiff(DiffDocument(
            title: file.path,
            subtitle: file.staged ? "Staged, against the last commit" : "In the folder, against what is staged",
            before: before,
            after: after,
            path: file.kind == .deleted ? nil : (root as NSString).appendingPathComponent(file.path)))
        if before.utf8.count > 600_000 || after.utf8.count > 600_000 {
            shownRows = []
            shownNote = "This file is too large to compare here."
            return
        }
        shownRows = LineDiff.rows(before: before, after: after)
        shownNote = shownRows.isEmpty ? "No text changes to show. It may not be a text file." : ""
    }
}
