import CryptoKit
import Foundation

/// Runs a shell command for the workspace (search, the terminal, git) and
/// hands back what it printed. It is separate from the agent's own shell,
/// so using the workspace never gets in the agent's way.
enum Shell {
    struct Result {
        let output: String
        let code: Int32
        var ok: Bool { code == 0 }
    }

    /// A string made safe to pass as one shell argument.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func run(_ command: String, in directory: String, timeout: TimeInterval = 60) async -> Result {
        await withCheckedContinuation { (done: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", command]
                let folder = FileManager.default.fileExists(atPath: directory) ? directory : NSHomeDirectory()
                process.currentDirectoryURL = URL(fileURLWithPath: folder)
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    done.resume(returning: Result(output: error.localizedDescription, code: -1))
                    return
                }
                let limit = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: limit)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                limit.cancel()
                done.resume(returning: Result(output: String(decoding: data, as: UTF8.self),
                                              code: process.terminationStatus))
            }
        }
    }
}

/// One change to one file, with the file as it was before and after, so it
/// can be shown, undone, or gone back to.
struct FileChange: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case created, edited, deleted, restored
    }

    var id = UUID()
    var date: Date
    var path: String
    var kind: Kind
    /// What was being done: the agent's task, or "Edited by you".
    var task: String
    var conversation: UUID?
    /// The file before and after, as keys into the store. nil is "no file".
    var before: String?
    var after: String?
    var added: Int
    var removed: Int
    /// The git commit this change went into, when the folder is a repository.
    var commit: String?

    var name: String { (path as NSString).lastPathComponent }
}

/// The history of every file Companion has changed: the agent's edits and
/// writes, and what you save in the editor. Each change keeps the file as
/// it was before and after, so anything can be undone or put back as it was
/// at any point, whether or not the folder is under git. Where it is, the
/// agent's changes are also committed (Settings > Agent), so they show in
/// `git log` like any other work.
///
/// Files are kept by their content's hash under Application
/// Support/Companion/history, so the same text is stored once.
@MainActor
final class ChangeStore: ObservableObject {
    static let shared = ChangeStore()

    /// Newest first.
    @Published private(set) var changes: [FileChange] = []

    private let folder: URL
    private let blobs: URL
    private let index: URL
    private static let limit = 3000
    /// Changes not yet committed to git, by path.
    private var uncommitted: [UUID] = []

    private init() {
        folder = ContextStore.shared.baseDir.appendingPathComponent("history", isDirectory: true)
        blobs = folder.appendingPathComponent("files", isDirectory: true)
        index = folder.appendingPathComponent("changes.json")
        try? FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: index), let saved = try? decoder.decode([FileChange].self, from: data) {
            changes = saved
        }
    }

    // MARK: Keeping file contents

    private func keep(_ data: Data) -> String {
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = blobs.appendingPathComponent(key)
        if !FileManager.default.fileExists(atPath: file.path) {
            try? data.write(to: file, options: .atomic)
        }
        return key
    }

    func data(_ key: String?) -> Data? {
        guard let key else { return nil }
        return try? Data(contentsOf: blobs.appendingPathComponent(key))
    }

    func text(_ key: String?) -> String {
        guard let data = data(key) else { return "" }
        return String(data: data, encoding: .utf8) ?? "(not text: \(data.count) bytes)"
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(changes) {
            try? data.write(to: index, options: .atomic)
        }
    }

    // MARK: Recording

    /// The file as it is now, taken before something changes it. nil when
    /// there is no file there yet.
    func snapshot(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return keep(data)
    }

    /// Records what happened to a file since `before` was taken. Nothing is
    /// recorded when the file did not change.
    @discardableResult
    func record(path: String, before: String?, task: String, conversation: UUID?,
                kind: FileChange.Kind? = nil) -> FileChange? {
        let after = snapshot(path)
        guard after != before else { return nil }
        let stats = LineDiff.counts(before: text(before), after: text(after))
        let change = FileChange(date: Date(), path: path,
                                kind: kind ?? (before == nil ? .created : (after == nil ? .deleted : .edited)),
                                task: task.isEmpty ? "Change" : String(task.prefix(160)),
                                conversation: conversation,
                                before: before, after: after,
                                added: stats.added, removed: stats.removed)
        changes.insert(change, at: 0)
        if changes.count > Self.limit { changes.removeLast(changes.count - Self.limit) }
        uncommitted.append(change.id)
        save()
        return change
    }

    // MARK: Undo and going back

    /// Puts a file's content in place, or removes the file for nil.
    private func place(_ key: String?, at path: String) -> Bool {
        if let key {
            guard let data = data(key) else { return false }
            let parent = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
        }
        return (try? FileManager.default.removeItem(atPath: path)) != nil || !FileManager.default.fileExists(atPath: path)
    }

    /// Undoes one change: the file goes back to how it was before it. This
    /// is itself recorded, so an undo can be undone.
    @discardableResult
    func undo(_ change: FileChange) -> Bool {
        let now = snapshot(change.path)
        guard place(change.before, at: change.path) else { return false }
        record(path: change.path, before: now, task: "Undid: \(change.task)", conversation: change.conversation, kind: .restored)
        return true
    }

    /// Puts the file back as it was right after a change, whatever has
    /// happened to it since.
    @discardableResult
    func restore(to change: FileChange) -> Bool {
        let now = snapshot(change.path)
        guard place(change.after, at: change.path) else { return false }
        record(path: change.path, before: now, task: "Went back to: \(change.task)", conversation: change.conversation, kind: .restored)
        return true
    }

    /// Undoes everything one task changed, newest first.
    func undo(task: String, conversation: UUID?) {
        for change in changes.filter({ $0.task == task && $0.conversation == conversation && $0.kind != .restored }) {
            undo(change)
        }
    }

    // MARK: Checkpoints

    /// When a conversation last changed a file, if it ever did.
    func lastChange(of conversation: UUID) -> Date? {
        changes.first { $0.conversation == conversation }?.date
    }

    /// The files a conversation has changed since a moment, each with the
    /// file as it was at that moment. A file changed several times since
    /// is listed once, with what it held before the first of them.
    func stage(of conversation: UUID, at date: Date) -> [(path: String, before: String?)] {
        // Changes are kept newest first, so the last one seen for a path
        // is the oldest since then.
        var oldest: [String: FileChange] = [:]
        for change in changes where change.conversation == conversation && change.date >= date {
            oldest[change.path] = change
        }
        return oldest.values.sorted { $0.path < $1.path }.map { ($0.path, $0.before) }
    }

    /// Puts every file a conversation has changed since a moment back as
    /// it was then. Each file put back is recorded like any other change,
    /// so going back can itself be undone from Changes.
    @discardableResult
    func rewind(conversation: UUID, to date: Date, label: String) -> (restored: Int, failed: Int) {
        var restored = 0
        var failed = 0
        for file in stage(of: conversation, at: date) {
            let now = snapshot(file.path)
            // Already as it was then: nothing to do.
            if now == file.before { continue }
            if place(file.before, at: file.path) {
                record(path: file.path, before: now, task: "Restored checkpoint: \(label)",
                       conversation: conversation, kind: .restored)
                restored += 1
            } else {
                failed += 1
            }
        }
        return (restored, failed)
    }

    /// Whether the file is still as this change left it.
    func isCurrent(_ change: FileChange) -> Bool {
        snapshot(change.path) == change.after
    }

    // MARK: Git

    /// Commits the changes made since the last commit to git, in whichever
    /// repositories the files belong to. Only the files Companion changed
    /// are added, on the branch that is checked out; nothing is pushed.
    /// The commit is the user's: their git name, a message saying what
    /// changed, and no co-author or AI credit (see `CommitHygiene`).
    func commitPending(message: String) async {
        let ids = uncommitted
        uncommitted = []
        guard AppSettings.shared.historyGit, !ids.isEmpty else { return }
        let paths = Array(Set(changes.filter { ids.contains($0.id) }.map(\.path)))
        var byRepository: [String: [String]] = [:]
        for path in paths {
            let parent = (path as NSString).deletingLastPathComponent
            let top = await Shell.run("git rev-parse --show-toplevel", in: parent, timeout: 10)
            guard top.ok else { continue }
            let root = top.output.trimmingCharacters(in: .whitespacesAndNewlines)
            byRepository[root, default: []].append(path)
        }
        var title = CommitHygiene.clean(message).replacingOccurrences(of: "\n", with: " ")
        if title.isEmpty { title = "Update files" }
        title = title.prefix(1).uppercased() + title.dropFirst()
        if title.count > 72 { title = String(title.prefix(71)) + "…" }
        for (root, files) in byRepository {
            let list = files.map(Shell.quote).joined(separator: " ")
            let command = "git add -A -- \(list) && git commit -q -m \(Shell.quote(title)) -- \(list) && git rev-parse --short HEAD"
            let result = await Shell.run(command, in: root, timeout: 30)
            guard result.ok else { continue }
            // A hook of the repository's own could still add a credit line.
            _ = await CommitHygiene.fixLastCommit(in: root)
            let head = await Shell.run("git rev-parse --short HEAD", in: root, timeout: 10)
            guard let last = (head.ok ? head.output : result.output).split(separator: "\n").last else { continue }
            let hash = String(last)
            for index in changes.indices where ids.contains(changes[index].id) && files.contains(changes[index].path) {
                changes[index].commit = hash
            }
        }
        save()
    }
}

// MARK: - Comparing two versions of a file

/// A line-by-line comparison of two texts.
enum LineDiff {
    struct Row: Identifiable {
        enum Kind { case same, added, removed, gap }
        let id: Int
        let kind: Kind
        let text: String
        let before: Int?
        let after: Int?
    }

    private static func lines(_ text: String) -> [String] {
        text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    static func counts(before: String, after: String) -> (added: Int, removed: Int) {
        let old = lines(before), new = lines(after)
        guard old.count <= 6000, new.count <= 6000 else { return (new.count, old.count) }
        let difference = new.difference(from: old)
        return (difference.insertions.count, difference.removals.count)
    }

    /// The comparison as rows to show: changed lines, a few unchanged lines
    /// around them, and a gap marker where a long unchanged run is left out.
    static func rows(before: String, after: String, context: Int = 3) -> [Row] {
        let old = lines(before), new = lines(after)
        struct Entry {
            let kind: Row.Kind
            let text: String
            let before: Int?
            let after: Int?
        }
        var all: [Entry] = []
        if old.count > 6000 || new.count > 6000 {
            // Too long to compare line by line in good time.
            for (offset, line) in old.enumerated() {
                all.append(Entry(kind: .removed, text: line, before: offset + 1, after: nil))
            }
            for (offset, line) in new.enumerated() {
                all.append(Entry(kind: .added, text: line, before: nil, after: offset + 1))
            }
        } else {
            let difference = new.difference(from: old)
            var removed = Set<Int>(), added = Set<Int>()
            for change in difference {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): added.insert(offset)
                }
            }
            var i = 0, j = 0
            while i < old.count || j < new.count {
                if i < old.count, removed.contains(i) {
                    all.append(Entry(kind: .removed, text: old[i], before: i + 1, after: nil))
                    i += 1
                } else if j < new.count, added.contains(j) {
                    all.append(Entry(kind: .added, text: new[j], before: nil, after: j + 1))
                    j += 1
                } else if i < old.count, j < new.count {
                    all.append(Entry(kind: .same, text: new[j], before: i + 1, after: j + 1))
                    i += 1
                    j += 1
                } else {
                    break
                }
            }
        }
        // Keep the changes and the lines near them.
        var keep = [Bool](repeating: false, count: all.count)
        for (index, row) in all.enumerated() where row.kind != .same {
            for near in max(0, index - context)...min(all.count - 1, index + context) {
                keep[near] = true
            }
        }
        var rows: [Row] = []
        var skipping = false
        for (index, row) in all.enumerated() {
            if keep[index] {
                rows.append(Row(id: rows.count, kind: row.kind, text: row.text, before: row.before, after: row.after))
                skipping = false
            } else if !skipping {
                rows.append(Row(id: rows.count, kind: .gap, text: "", before: nil, after: nil))
                skipping = true
            }
        }
        return rows
    }
}
