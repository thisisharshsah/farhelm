import CompanionBoard
import Foundation

/// The git side of a task's own copy of its repository (`WorkingCopy` in
/// CompanionBoard): making it, a git worktree on a branch of its own;
/// merging that branch into the branch it came from once the task is
/// approved; and taking it down. The board keeps what a copy is and how
/// it stands; this does git's part and says how it went. Steps on one
/// repository go one at a time, so two never trip over git's locks.
///
/// Nothing here rewrites history or forces anything. A merge is a new
/// commit on top of the person's branch, made only when the task's branch
/// merges into it without a conflict, and worked out by git without
/// touching any folder (`git merge-tree`). The person's folder is then
/// moved up to it the way `git merge --ff-only` does, which changes
/// nothing at all when changes of theirs are in the way. Folders are only
/// ever deleted inside `root`, where copies are made.
@MainActor
final class TaskCopies {
    static let shared = TaskCopies()

    /// Where copies are made: a folder per project under the person's
    /// home, outside every repository (so no copy turns up in a
    /// repository's own files, searches or builds), and with no space in
    /// its path, which some build tools still trip over.
    static let root = (NSHomeDirectory() as NSString).appendingPathComponent(".companion/worktrees")

    private var queues: [String: Task<Void, Never>] = [:]

    private init() {}

    // MARK: Running git

    /// Runs `work` once whatever is already under way on the same
    /// repository is done.
    private func inTurn<T: Sendable>(_ repository: String, _ work: @escaping @MainActor () async -> T) async -> T {
        let before = queues[repository]
        let task = Task { @MainActor () -> T in
            await before?.value
            return await work()
        }
        queues[repository] = Task { @MainActor in _ = await task.value }
        return await task.value
    }

    /// Runs git in a folder that is there. A password prompt has nowhere
    /// to be answered here, so git is told not to ask, and fails instead.
    private func git(_ arguments: String, in folder: String, timeout: TimeInterval = 60) async -> Shell.Result {
        // The shell would start somewhere else, and git with it.
        guard Self.isFolder(folder) else { return Shell.Result(output: "There is no folder at \(folder).", code: -1) }
        return await Shell.run("GIT_TERMINAL_PROMPT=0 git -c core.quotePath=false " + arguments, in: folder,
                               timeout: timeout)
    }

    private static func lines(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The last line a command printed: what git said, after anything the
    /// shell printed first.
    private static func last(_ output: String) -> String {
        lines(output).last(where: { !$0.isEmpty }) ?? ""
    }

    /// What a command that failed said, for the person: its last lines.
    private static func said(_ output: String) -> String {
        let text = lines(output).filter { !$0.isEmpty }.suffix(4).joined(separator: " ")
        return text.isEmpty ? "git gave no reason" : String(text.prefix(400))
    }

    /// A commit or tree as git names it in full.
    private static func isObject(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64) && text.allSatisfy(\.isHexDigit)
    }

    /// git talking about itself rather than naming a file.
    private static func isRemark(_ line: String) -> Bool {
        ["warning:", "hint:", "error:", "fatal:", "Auto-merging", "CONFLICT"].contains { line.hasPrefix($0) }
    }

    private static func isFolder(_ path: String) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue
    }

    /// Whether two paths name the same folder.
    private static func same(_ one: String, _ other: String) -> Bool {
        func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
        return real(one) == real(other)
    }

    /// Whether a folder is one of the copies made here, which may be
    /// deleted. Nothing else ever is.
    private static func isOurs(_ path: String) -> Bool {
        let tidy = URL(fileURLWithPath: path).standardizedFileURL.path
        return tidy.hasPrefix(root + "/") && tidy.count > root.count + 1
    }

    /// The top of the repository a folder is in, or nil when it is in none.
    private func top(of folder: String) async -> String? {
        let found = await git("rev-parse --show-toplevel", in: folder, timeout: 15)
        let line = Self.last(found.output)
        return found.ok && line.hasPrefix("/") ? line : nil
    }

    /// A commit by any name git knows it by, in full; nil when there is none.
    private func revision(_ name: String, in folder: String) async -> String? {
        let found = await git("rev-parse --verify --quiet \(Shell.quote(name + "^{commit}"))", in: folder, timeout: 15)
        let line = Self.last(found.output)
        return found.ok && Self.isObject(line) ? line : nil
    }

    /// How many files have changes git has not committed in a folder.
    private func uncommitted(in folder: String, untracked: Bool = true) async -> Int? {
        let found = await git("status --porcelain --untracked-files=\(untracked ? "normal" : "no")", in: folder,
                              timeout: 60)
        guard found.ok else { return nil }
        let marks: Set<Character> = [" ", "M", "A", "D", "R", "C", "U", "T", "?"]
        return found.output.split(whereSeparator: \.isNewline).filter { line in
            line.count > 3 && line.prefix(2).allSatisfy { marks.contains($0) } && line.dropFirst(2).first == " "
        }.count
    }

    /// Commits everything in a folder, on the branch it is on. Returns why
    /// it could not, or nil.
    private func commitAll(in folder: String, message: String) async -> String? {
        let added = await git("add -A", in: folder, timeout: 120)
        guard added.ok else { return Self.said(added.output) }
        // The commit is the person's: no co-author or AI credit lines.
        let committed = await git("commit -q -m \(Shell.quote(CommitHygiene.clean(message)))", in: folder, timeout: 120)
        guard committed.ok else { return Self.said(committed.output) }
        _ = await CommitHygiene.fixLastCommit(in: folder)
        return nil
    }

    /// The folder a branch is checked out in, when one is. A folder that
    /// is gone does not count.
    private func checkout(of branch: String, in repository: String) async -> String? {
        let listed = await git("worktree list --porcelain", in: repository, timeout: 15)
        guard listed.ok else { return nil }
        var path: String?
        for line in listed.output.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line == "branch refs/heads/" + branch, let path, Self.isFolder(path) {
                return path
            }
        }
        return nil
    }

    // MARK: Making a copy

    /// How readying a task's copy went.
    enum Prepared: Sendable {
        /// The copy to run in: made now (`made`), or found in place or put
        /// back. One made now says how many files had changes in the
        /// project's folder that it does not have (`uncommitted`), and the
        /// branch of the task's copy before it that was found gone (`lost`).
        case ready(WorkingCopy, made: Bool, uncommitted: Int, lost: String?)
        /// No copy can be made for this project (`why`): its runs work in
        /// its folder.
        case inFolder(String)
        /// It could not be readied now, for this reason. No run should start.
        case failed(String)
    }

    /// Readies the copy a task's next run works in. The task's open copy
    /// (`open`) is checked, and its folder put back from its branch when
    /// the folder is gone; failing that, or with none, a new copy is made
    /// from the branch the project's folder is on, at its last commit.
    func prepare(_ item: WorkItem, open: WorkingCopy?, folder: String, project: UUID, now: Date) async -> Prepared {
        await inTurn(folder) {
            var lost: String?
            if let open {
                if Self.isFolder(open.folder), let top = await self.top(of: open.folder), Self.same(top, open.folder) {
                    // A folder of the project's that the copy lost is made again, empty.
                    try? FileManager.default.createDirectory(atPath: open.directory, withIntermediateDirectories: true)
                    return .ready(open, made: false, uncommitted: 0, lost: nil)
                }
                guard let repository = await self.top(of: folder) else {
                    return .failed("the project's folder is no longer in a git repository")
                }
                if await self.revision("refs/heads/" + open.branch, in: repository) != nil {
                    // The folder went; the branch holds what was committed in it.
                    guard !FileManager.default.fileExists(atPath: open.folder) else {
                        return .failed("its copy at \(open.folder) is not a git worktree any more. Move that folder away, then start it again")
                    }
                    _ = await self.git("worktree prune", in: repository, timeout: 30)
                    try? FileManager.default.createDirectory(atPath: (open.folder as NSString).deletingLastPathComponent,
                                                             withIntermediateDirectories: true)
                    let back = await self.git("worktree add \(Shell.quote(open.folder)) \(Shell.quote(open.branch))",
                                              in: repository, timeout: 300)
                    guard back.ok else {
                        return .failed("its copy was gone and could not be made again from \(open.branch): \(Self.said(back.output))")
                    }
                    try? FileManager.default.createDirectory(atPath: open.directory, withIntermediateDirectories: true)
                    return .ready(open, made: false, uncommitted: 0, lost: nil)
                }
                lost = open.branch
            }
            return await self.make(item, folder: folder, project: project, now: now, lost: lost)
        }
    }

    private func make(_ item: WorkItem, folder: String, project: UUID, now: Date, lost: String?) async -> Prepared {
        guard let repository = await top(of: folder) else { return .inFolder("its folder is not in a git repository") }
        let head = await git("symbolic-ref --quiet --short HEAD", in: repository, timeout: 15)
        let current = Self.last(head.output)
        guard head.ok, !current.isEmpty else { return .inFolder("its folder is not on a branch") }
        guard await revision("HEAD", in: repository) != nil else {
            return .inFolder("its repository has no commit yet")
        }
        let listed = await git("for-each-ref '--format=%(refname:short)' refs/heads", in: repository, timeout: 15)
        let taken = Set(Self.lines(listed.output).filter { !$0.isEmpty })
        // Tasks branch from the board's own branch, which first takes the
        // person's newer commits, and their work is merged there: never
        // into the branch checked out in the person's folder (`deliver`).
        var base = current
        var target: String?
        var trouble: String?
        if !WorkingCopy.isBoardBranch(current) {
            base = WorkingCopy.boardBranch(for: current, flat: taken.contains { $0.lowercased() == WorkingCopy.boardPrefix })
            target = current
            let caught = await catchUp(base, with: current, in: repository)
            if case .failed(let why) = caught { trouble = why }
        }
        guard let baseCommit = await revision("refs/heads/" + base, in: repository) else {
            return .failed(trouble ?? "the board's branch, \(base), is not in the repository")
        }
        let branch = WorkingCopy.branch(for: item, taken: taken, flat: taken.contains { $0.lowercased() == "task" })
        let place = (Self.root as NSString).appendingPathComponent(Self.placeName(of: repository, project: project))
        do {
            try FileManager.default.createDirectory(atPath: place, withIntermediateDirectories: true)
        } catch {
            return .failed("there is no room for its copy at \(place): \(error.localizedDescription)")
        }
        let there = Set((try? FileManager.default.contentsOfDirectory(atPath: place)) ?? [])
        let copyFolder = (place as NSString).appendingPathComponent(WorkingCopy.folderName(for: item, taken: there))
        let made = await git("worktree add -b \(Shell.quote(branch)) \(Shell.quote(copyFolder)) \(baseCommit)",
                             in: repository, timeout: 300)
        guard made.ok else { return .failed("its copy could not be made: \(Self.said(made.output))") }
        let copy = WorkingCopy(folder: copyFolder, subfolder: Self.subfolder(of: folder, in: repository), branch: branch,
                               base: base, baseCommit: baseCommit, madeAt: now, target: target)
        // A folder git does not know yet is not in the copy: runs start in
        // an empty one there.
        try? FileManager.default.createDirectory(atPath: copy.directory, withIntermediateDirectories: true)
        let changed = await uncommitted(in: repository) ?? 0
        return .ready(copy, made: true, uncommitted: changed, lost: lost)
    }

    /// The folder for a project's copies: the repository's name and the
    /// start of the project's id, "farhelm-1a2b3c".
    static func placeName(of repository: String, project: UUID) -> String {
        let name = WorkingCopy.slug((repository as NSString).lastPathComponent, limit: 30) ?? "repository"
        return name + "-" + project.uuidString.prefix(6).lowercased()
    }

    /// Where a folder is inside its repository, as a path from the top:
    /// "" at the top itself.
    static func subfolder(of folder: String, in repository: String) -> String {
        let inner = URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.path
        let outer = URL(fileURLWithPath: repository).resolvingSymlinksInPath().standardizedFileURL.path
        guard inner != outer, inner.hasPrefix(outer + "/") else { return "" }
        return String(inner.dropFirst(outer.count + 1))
    }

    // MARK: Merging its work

    /// How merging a task's work went.
    enum Landed: Sendable, Equatable {
        /// Its work is in the branch it came from, as this commit.
        case merged(String)
        /// Its branch held nothing that branch does not have already, or
        /// was gone: there was nothing to merge.
        case nothing
        /// That branch has moved on and conflicts with its work, in these files.
        case conflicts([String])
        /// Something only the person can settle stands in the way, said for them.
        case held(String)
        /// It was no longer wanted when the person's branch would have changed.
        case dropped
    }

    /// Merges a task's approved work into the branch its copy came from,
    /// as one commit named after the task (`squashMessage`), not the
    /// commits its agent made along the way, then takes the copy and its
    /// branch down. What was left uncommitted
    /// in the copy is committed on its branch first, unless a merge in it
    /// was left unsettled (`unsettled`): then nothing is committed or
    /// merged, and the task goes back to settle it. `wanted` is asked
    /// just before the branch it goes into changes; when it says no (a run
    /// began on the task meanwhile, say), nothing is changed.
    func land(_ copy: WorkingCopy, key: String, title: String, folder: String,
              wanted: @escaping @MainActor () -> Bool) async -> Landed {
        await inTurn(folder) {
            guard let repository = await self.top(of: folder) else {
                return .held("The project's folder is no longer in a git repository.")
            }
            if Self.isFolder(copy.folder) {
                let unsettled = await self.unsettled(copy)
                if !unsettled.isEmpty { return .conflicts(unsettled) }
            }
            if Self.isFolder(copy.folder), let left = await self.uncommitted(in: copy.folder), left > 0 {
                if let problem = await self.commitAll(in: copy.folder,
                                                       message: "\(title)\n\nWhat \(key) left uncommitted in its copy.") {
                    return .held("What was left uncommitted in its copy could not be committed: \(problem)")
                }
            }
            // The branch it goes into may move on while this works; then it
            // is worked out again.
            for _ in 0..<3 {
                guard let landed = await self.mergeOnce(copy, key: key, title: title, repository: repository,
                                                        wanted: wanted) else { continue }
                switch landed {
                case .merged, .nothing:
                    if let problem = await self.takeDown(copy, repository: repository, keepBranch: false) {
                        NSLog("%@", "\(key)'s work was merged, but its copy was not all taken down: \(problem)")
                    }
                case .conflicts, .held, .dropped:
                    break
                }
                return landed
            }
            return .held("\(copy.base) kept changing while \(key) was being merged into it. Merge it again in a moment.")
        }
    }

    /// Whether a task's work would merge into the branch its copy came
    /// from, worked out by git without touching any folder, as
    /// `mergeOnce` does: nil when it would, or the reason it would not.
    /// The supervisor's approve asks this first, so work that conflicts
    /// stays in Review with the reason, instead of being approved and
    /// then sent back to To do by the merge. What the copy has not
    /// committed yet is not on its branch and is not looked at here;
    /// `land` still finds a conflict there and sends the task back.
    func wouldNotMerge(_ copy: WorkingCopy, folder: String) async -> String? {
        await inTurn(folder) {
            guard let repository = await self.top(of: folder) else {
                return "the project's folder is no longer in a git repository"
            }
            if Self.isFolder(copy.folder) {
                let unsettled = await self.unsettled(copy)
                if !unsettled.isEmpty {
                    return "a merge in its copy is left unsettled in " + unsettled.prefix(6).joined(separator: ", ")
                }
            }
            // No branch: nothing to merge, which `land` settles by itself.
            guard let tip = await self.revision("refs/heads/" + copy.branch, in: repository) else { return nil }
            guard let baseTip = await self.revision("refs/heads/" + copy.base, in: repository) else {
                return "the branch it came from, \(copy.base), is no longer in the repository"
            }
            if await self.git("merge-base --is-ancestor \(tip) \(baseTip)", in: repository, timeout: 30).ok { return nil }
            let worked = await self.git("merge-tree --write-tree --name-only --no-messages \(baseTip) \(tip)",
                                        in: repository, timeout: 180)
            let said = Self.lines(worked.output)
            // A git before 2.38 cannot work it out without a folder; the
            // merge itself finds out then.
            guard let treeAt = said.firstIndex(where: { Self.isObject($0) }) else { return nil }
            if worked.code == 1 {
                var files: [String] = []
                for line in said[(treeAt + 1)...] where !line.isEmpty && !Self.isRemark(line) && !files.contains(line) {
                    files.append(line)
                }
                let list = files.prefix(6).joined(separator: ", ") + (files.count > 6 ? " and \(files.count - 6) more" : "")
                return "its work conflicts with \(copy.base) in \(list.isEmpty ? "some files" : list)"
            }
            return worked.ok ? nil : "git could not work the merge out: \(Self.said(worked.output))"
        }
    }

    /// One try at the merge. nil when the branch it goes into moved on
    /// while it was worked out.
    private func mergeOnce(_ copy: WorkingCopy, key: String, title: String, repository: String,
                           wanted: @MainActor () -> Bool) async -> Landed? {
        // Gone: taken down outside the app, its work merged by the person or let go.
        guard let tip = await revision("refs/heads/" + copy.branch, in: repository) else { return .nothing }
        guard let baseTip = await revision("refs/heads/" + copy.base, in: repository) else {
            return .held("The branch it came from, \(copy.base), is no longer in the repository. Merge \(copy.branch) where you want it yourself, or throw the copy away.")
        }
        if await git("merge-base --is-ancestor \(tip) \(baseTip)", in: repository, timeout: 30).ok { return .nothing }
        let worked = await git("merge-tree --write-tree --name-only --no-messages \(baseTip) \(tip)",
                               in: repository, timeout: 180)
        let said = Self.lines(worked.output)
        // A git before 2.38 cannot work a merge out on its own.
        guard let treeAt = said.firstIndex(where: { Self.isObject($0) }) else {
            return await mergeInCheckout(copy, key: key, title: title, repository: repository, wanted: wanted)
        }
        if worked.code == 1 {
            var files: [String] = []
            for line in said[(treeAt + 1)...] where !line.isEmpty && !Self.isRemark(line) && !files.contains(line) {
                files.append(line)
            }
            return .conflicts(files)
        }
        guard worked.ok else { return .held("git could not work the merge out: \(Self.said(worked.output))") }
        let tree = said[treeAt]
        // Nothing it holds is new there: its work came in another way.
        let baseTree = await git("rev-parse --verify --quiet \(Shell.quote(baseTip + "^{tree}"))", in: repository,
                                 timeout: 15)
        if baseTree.ok, Self.last(baseTree.output) == tree { return .nothing }
        // One commit on top of that branch, with the merged files and the
        // task's name; the commits its agent made stay out of its history.
        let counted = await git("rev-list --count \(baseTip)..\(tip)", in: repository, timeout: 30)
        let message = Self.squashMessage(key: key, title: title, branch: copy.branch,
                                         commits: Int(Self.last(counted.output)) ?? 0)
        let made = await git("commit-tree \(tree) -p \(baseTip) -m \(Shell.quote(message))",
                             in: repository, timeout: 60)
        let commit = Self.last(made.output)
        guard made.ok, Self.isObject(commit) else {
            return .held("The merge could not be committed: \(Self.said(made.output))")
        }
        guard wanted() else { return .dropped }
        // Where the branch is checked out, its folder moves up with it;
        // anywhere else only the branch moves, and only from where it was.
        if let checkout = await checkout(of: copy.base, in: repository) {
            let moved = await git("merge --ff-only --no-edit \(commit)", in: checkout, timeout: 300)
            if moved.ok { return .merged(String(commit.prefix(7))) }
            if await revision("HEAD", in: checkout) != baseTip { return nil }
            return .held(Self.inTheWay(moved.output, base: copy.base, key: key))
        }
        let moved = await git("update-ref -m \(Shell.quote("merge " + key)) \(Shell.quote("refs/heads/" + copy.base)) \(commit) \(baseTip)",
                              in: repository, timeout: 30)
        if moved.ok { return .merged(String(commit.prefix(7))) }
        if await revision("refs/heads/" + copy.base, in: repository) != baseTip { return nil }
        return .held("\(copy.base) could not be moved up to the merge: \(Self.said(moved.output))")
    }

    /// The work of a task as one commit, the message's subject its key and
    /// title, and how many commits on which branch it was made from.
    /// Credit lines are taken out (`CommitHygiene`).
    static func squashMessage(key: String, title: String, branch: String, commits: Int) -> String {
        let made = commits == 1 ? "1 commit" : "\(commits) commits"
        let body = commits > 0 ? "\n\nBoard task \(key), squashed from \(made) on \(branch)." : ""
        return CommitHygiene.clean("\(key): \(title)" + body)
    }

    /// The merge done in the folder where the branch it goes into is
    /// checked out, for a git too old to work it out on its own, as one
    /// commit, the same as `mergeOnce` makes. Only a folder with nothing
    /// uncommitted is used, so a merge that conflicts can be taken back
    /// whole.
    private func mergeInCheckout(_ copy: WorkingCopy, key: String, title: String, repository: String,
                                 wanted: @MainActor () -> Bool) async -> Landed? {
        guard let checkout = await checkout(of: copy.base, in: repository) else {
            return .held("This git cannot merge into \(copy.base) unless it is checked out (git 2.38 or later can). Check \(copy.base) out in your folder, then merge \(key) again.")
        }
        guard await uncommitted(in: checkout, untracked: false) == 0 else {
            return .held("This git can only merge in your folder, which has changes that are not committed. Commit them or put them aside, then merge \(key) again.")
        }
        guard wanted() else { return .dropped }
        let counted = await git("rev-list --count HEAD..\(Shell.quote(copy.branch))", in: checkout, timeout: 30)
        let message = Self.squashMessage(key: key, title: title, branch: copy.branch,
                                         commits: Int(Self.last(counted.output)) ?? 0)
        let merged = await git("merge --squash \(Shell.quote(copy.branch))", in: checkout, timeout: 300)
        if merged.ok {
            // Nothing new staged: its work was in already.
            if await git("diff --cached --quiet", in: checkout, timeout: 30).ok { return .nothing }
            let committed = await git("commit -q -m \(Shell.quote(message))", in: checkout, timeout: 120)
            if committed.ok {
                let head = await revision("HEAD", in: checkout) ?? ""
                return .merged(String(head.prefix(7)))
            }
            _ = await git("reset -q --merge", in: checkout, timeout: 60)
            return .held("\(key)'s work could not be committed in your folder: \(Self.said(committed.output))")
        }
        // Stopped halfway: what conflicts is noted, and the folder is put
        // back as it was (a squash leaves no merge to abort).
        let listed = await git("diff --name-only --diff-filter=U", in: checkout, timeout: 30)
        let conflicted = Self.lines(listed.output).filter { !$0.isEmpty && !Self.isRemark($0) }
        if !conflicted.isEmpty {
            _ = await git("reset -q --merge", in: checkout, timeout: 60)
            return .conflicts(conflicted)
        }
        return .held(Self.inTheWay(merged.output, base: copy.base, key: key))
    }

    /// Why the person's folder could not be moved up to a merge, in their
    /// words: changes of theirs that are in the way, named, or what git said.
    private static func inTheWay(_ output: String, base: String, key: String) -> String {
        let files = wayFiles(output)
        if !files.isEmpty {
            let named = files.prefix(6).joined(separator: ", ") + (files.count > 6 ? " and \(files.count - 6) more" : "")
            return "Changes in your folder that are not committed are in the way: \(named). Commit them or put them aside, then merge \(key) again."
        }
        return "Your folder could not be moved up to the merge into \(base): \(said(output)). Settle that, then merge \(key) again."
    }

    /// The files git names as in the way of a merge into a folder:
    /// changes there that are not committed.
    private static func wayFiles(_ output: String) -> [String] {
        var files: [String] = []
        var listing = false
        for line in output.components(separatedBy: .newlines) {
            if line.contains("would be overwritten by") {
                listing = true
            } else if listing, line.hasPrefix("\t") || line.hasPrefix("    ") {
                files.append(line.trimmingCharacters(in: .whitespaces))
            } else if listing, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                listing = false
            }
        }
        return files
    }

    /// Files of a copy that a merge left unsettled: still marked as in
    /// conflict, or with conflict marks left among its changes, committed
    /// or not. Work like that is never committed or merged.
    private func unsettled(_ copy: WorkingCopy) async -> [String] {
        let open = await git("diff --name-only --diff-filter=U", in: copy.folder, timeout: 30)
        var files = open.ok ? Self.lines(open.output).filter { !$0.isEmpty && !Self.isRemark($0) } : []
        let since = await forkPoint(of: copy)
        let checked = await git("diff --check \(since)", in: copy.folder, timeout: 60)
        // "path:12: leftover conflict marker"
        for line in Self.lines(checked.output) where line.hasSuffix(": leftover conflict marker") {
            let path = line.components(separatedBy: ":").dropLast(2).joined(separator: ":")
            if !path.isEmpty, !files.contains(path) { files.append(path) }
        }
        return files
    }

    // MARK: The board's own branch

    /// How the board's own branch stands against the person's branch.
    enum CaughtUp: Sendable, Equatable {
        /// It has every commit of theirs: it was made now, moved up to
        /// take their newer ones, or had them.
        case even
        /// Both changed the same lines, in these files: git cannot bring
        /// theirs in by itself.
        case conflicts([String])
        /// It could not be looked at or moved, for this reason.
        case failed(String)
    }

    /// Makes sure the board's branch (`board`) has every commit of the
    /// person's branch (`target`): it is made from it the first time,
    /// moved up to it while it has nothing of its own, and otherwise takes
    /// it in as a merge git works out without touching any folder, when
    /// that has no conflict. A board branch checked out somewhere is left
    /// as it is. Runs inside `inTurn`.
    private func catchUp(_ board: String, with target: String, in repository: String) async -> CaughtUp {
        guard let theirs = await revision("refs/heads/" + target, in: repository) else {
            return .failed("\(target) is no longer in the repository")
        }
        guard let ours = await revision("refs/heads/" + board, in: repository) else {
            let made = await git("branch --no-track \(Shell.quote(board)) \(theirs)", in: repository, timeout: 30)
            return made.ok ? .even : .failed("the board's branch, \(board), could not be made: \(Self.said(made.output))")
        }
        if ours == theirs { return .even }
        if await git("merge-base --is-ancestor \(theirs) \(ours)", in: repository, timeout: 30).ok { return .even }
        if await checkout(of: board, in: repository) != nil { return .even }
        let reason = Shell.quote("catch up with " + target)
        let ref = Shell.quote("refs/heads/" + board)
        if await git("merge-base --is-ancestor \(ours) \(theirs)", in: repository, timeout: 30).ok {
            let moved = await git("update-ref -m \(reason) \(ref) \(theirs) \(ours)", in: repository, timeout: 30)
            return moved.ok ? .even : .failed("\(board) could not be moved up to \(target): \(Self.said(moved.output))")
        }
        let worked = await git("merge-tree --write-tree --name-only --no-messages \(ours) \(theirs)",
                               in: repository, timeout: 180)
        let said = Self.lines(worked.output)
        guard let treeAt = said.firstIndex(where: { Self.isObject($0) }) else {
            return .failed("this git cannot merge \(target) into \(board) without a folder (git 2.38 or later can)")
        }
        if worked.code == 1 {
            var files: [String] = []
            for line in said[(treeAt + 1)...] where !line.isEmpty && !Self.isRemark(line) && !files.contains(line) {
                files.append(line)
            }
            return .conflicts(files)
        }
        guard worked.ok else { return .failed("git could not work the merge out: \(Self.said(worked.output))") }
        let subject = CommitHygiene.clean("Merge \(target) into \(board)")
        let made = await git("commit-tree \(said[treeAt]) -p \(ours) -p \(theirs) -m \(Shell.quote(subject))",
                             in: repository, timeout: 60)
        let commit = Self.last(made.output)
        guard made.ok, Self.isObject(commit) else {
            return .failed("the merge could not be committed: \(Self.said(made.output))")
        }
        let moved = await git("update-ref -m \(reason) \(ref) \(commit) \(ours)", in: repository, timeout: 30)
        return moved.ok ? .even : .failed("\(board) could not be moved up to the merge: \(Self.said(moved.output))")
    }

    /// How bringing the board's work into the person's branch went.
    enum Delivered: Sendable, Equatable {
        /// There was nothing to bring: their branch has it all, or no task
        /// of theirs has been merged on a board branch.
        case even
        /// Their branch moved up to the board's, to this commit.
        case delivered(String, into: String)
        /// Changes of theirs that are not committed are in the way, said
        /// for them. It is tried again later, by itself.
        case held(String)
        /// Their branch (`target`) and the board's changed the same lines
        /// in these files: a task settles that.
        case conflicts([String], target: String)
        /// It could not be done, for this reason.
        case failed(String)
    }

    /// Brings the work merged on the board's own branch into the branch
    /// the project's folder is on. The board's branch first takes that
    /// branch's newer commits (`catchUp`); then that branch moves up to
    /// it the way `git merge --ff-only` does, which changes nothing at all
    /// when changes of the person's are in the way. Nothing here touches
    /// what they have not committed.
    func deliver(folder: String) async -> Delivered {
        await inTurn(folder) {
            guard let repository = await self.top(of: folder) else { return .even }
            let head = await self.git("symbolic-ref --quiet --short HEAD", in: repository, timeout: 15)
            let target = Self.last(head.output)
            guard head.ok, !target.isEmpty, !WorkingCopy.isBoardBranch(target) else { return .even }
            let flat = await self.revision("refs/heads/" + WorkingCopy.boardPrefix, in: repository) != nil
            let board = WorkingCopy.boardBranch(for: target, flat: flat)
            guard await self.revision("refs/heads/" + board, in: repository) != nil else { return .even }
            let caught = await self.catchUp(board, with: target, in: repository)
            switch caught {
            case .conflicts(let files): return .conflicts(files, target: target)
            case .failed(let why): return .failed(why)
            case .even: break
            }
            guard let ours = await self.revision("refs/heads/" + board, in: repository),
                  let theirs = await self.revision("refs/heads/" + target, in: repository), ours != theirs
            else { return .even }
            let behind = await self.git("merge-base --is-ancestor \(theirs) \(ours)", in: repository, timeout: 30)
            guard behind.ok else { return .even }
            if let checkout = await self.checkout(of: target, in: repository) {
                let moved = await self.git("merge --ff-only --no-edit \(ours)", in: checkout, timeout: 300)
                if moved.ok { return .delivered(String(ours.prefix(7)), into: target) }
                // It moved meanwhile: the next try sees where it is now.
                if await self.revision("HEAD", in: checkout) != theirs { return .even }
                return .held(Self.waitsFor(moved.output, target: target))
            }
            let moved = await self.git("update-ref -m \(Shell.quote("bring in " + board)) \(Shell.quote("refs/heads/" + target)) \(ours) \(theirs)",
                                       in: repository, timeout: 30)
            return moved.ok ? .delivered(String(ours.prefix(7)), into: target)
                : .failed("\(target) could not be moved up to \(board): \(Self.said(moved.output))")
        }
    }

    /// Why the person's branch could not take the board's work, for them.
    private static func waitsFor(_ output: String, target: String) -> String {
        let files = wayFiles(output)
        guard !files.isEmpty else { return "The board's merged work could not go into \(target): \(said(output))." }
        let named = files.prefix(6).joined(separator: ", ") + (files.count > 6 ? " and \(files.count - 6) more" : "")
        return "The board's merged work waits to go into \(target): changes in your folder that are not committed are in the way (\(named)). Commit them or put them aside, and it goes in by itself."
    }

    // MARK: Taking a copy down

    /// Removes a copy's folder (whatever git ignores in it goes too) and,
    /// unless `keepBranch`, its branch. Returns what was left, or nil.
    private func takeDown(_ copy: WorkingCopy, repository: String, keepBranch: Bool) async -> String? {
        var left: [String] = []
        if Self.isOurs(copy.folder), FileManager.default.fileExists(atPath: copy.folder) {
            let removed = await git("worktree remove --force \(Shell.quote(copy.folder))", in: repository, timeout: 120)
            if !removed.ok { try? FileManager.default.removeItem(atPath: copy.folder) }
            if FileManager.default.fileExists(atPath: copy.folder) { left.append("its folder, \(copy.folder)") }
        }
        _ = await git("worktree prune", in: repository, timeout: 30)
        if !keepBranch, await revision("refs/heads/" + copy.branch, in: repository) != nil {
            let deleted = await git("branch -D \(Shell.quote(copy.branch))", in: repository, timeout: 30)
            if !deleted.ok { left.append("its branch, \(copy.branch) (\(Self.said(deleted.output)))") }
        }
        return left.isEmpty ? nil : left.joined(separator: "; ")
    }

    /// Throws a task's copy away: its folder and its branch, with any work
    /// on them. Returns why that could not be done, or nil.
    func discard(_ copy: WorkingCopy, folder: String) async -> String? {
        await inTurn(folder) {
            guard let repository = await self.top(of: folder) else {
                return "the project's folder is no longer in a git repository"
            }
            return await self.takeDown(copy, repository: repository, keepBranch: false).map { "left behind " + $0 }
        }
    }

    /// Puts a task's copy away when the task is taken off the board: what
    /// was left uncommitted is committed on its branch, and the folder is
    /// removed. The branch stays, with all of the task's work. Returns why
    /// that could not be done, or nil.
    func putAway(_ copy: WorkingCopy, key: String, title: String, folder: String) async -> String? {
        await inTurn(folder) {
            guard let repository = await self.top(of: folder) else {
                return "the project's folder is no longer in a git repository"
            }
            if Self.isFolder(copy.folder), let left = await self.uncommitted(in: copy.folder), left > 0 {
                let message = "\(title) (work in progress)\n\nWhat \(key) left uncommitted when it was taken off the board."
                if let problem = await self.commitAll(in: copy.folder, message: message) {
                    return "its copy was kept at \(copy.folder), since what was left in it could not be committed (\(problem))"
                }
            }
            return await self.takeDown(copy, repository: repository, keepBranch: true).map { "left behind " + $0 }
        }
    }

    // MARK: What a copy holds

    /// What a task's copy changed, against the commit it branched from:
    /// what it committed, what it has not, and new files git does not know yet.
    struct Changes: Equatable, Sendable {
        struct File: Identifiable, Equatable, Sendable {
            /// From the repository's top.
            var path: String
            /// Lines added and taken out; nil for a file that is not text.
            var added: Int?
            var removed: Int?
            /// New, and not yet known to git.
            var untracked: Bool
            var id: String { path }
        }

        /// The commit they are counted against: where the copy's branch
        /// left the branch it came from.
        var since: String
        var files: [File]

        var added: Int { files.reduce(0) { $0 + ($1.added ?? 0) } }
        var removed: Int { files.reduce(0) { $0 + ($1.removed ?? 0) } }
    }

    /// Where a copy's branch left the branch it came from.
    private func forkPoint(of copy: WorkingCopy) async -> String {
        let found = await git("merge-base \(Shell.quote("refs/heads/" + copy.base)) HEAD", in: copy.folder, timeout: 30)
        let commit = Self.last(found.output)
        return found.ok && Self.isObject(commit) ? commit : copy.baseCommit
    }

    func changes(of copy: WorkingCopy) async -> Changes? {
        guard Self.isFolder(copy.folder) else { return nil }
        let since = await forkPoint(of: copy)
        guard Self.isObject(since) else { return nil }
        let counted = await git("diff --numstat --no-renames \(since)", in: copy.folder, timeout: 60)
        guard counted.ok else { return nil }
        var files: [Changes.File] = []
        for line in counted.output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, Int(parts[0]) != nil || parts[0] == "-" else { continue }
            files.append(Changes.File(path: String(parts[2]), added: Int(parts[0]), removed: Int(parts[1]),
                                      untracked: false))
        }
        let fresh = await git("ls-files --others --exclude-standard", in: copy.folder, timeout: 60)
        for path in Self.lines(fresh.output) where !path.isEmpty {
            let full = (copy.folder as NSString).appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: full) else { continue }
            files.append(Changes.File(path: path, added: Self.lineCount(full), removed: 0, untracked: true))
        }
        return Changes(since: since, files: files.sorted { $0.path < $1.path })
    }

    /// Lines in a text file; nil for one that is not text, or too large to read.
    private static func lineCount(_ path: String) -> Int? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber,
              size.intValue <= 4_000_000, let data = FileManager.default.contents(atPath: path),
              !data.contains(0) else { return nil }
        guard !data.isEmpty else { return 0 }
        let breaks = data.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        return data.last == 10 ? breaks : breaks + 1
    }

    /// A task's work as a reviewer reads it: the files it changed and the
    /// diff itself, new files in full, fitted to `limit` characters
    /// (`ReviewDiff`: every file named, small ones whole first).
    struct BranchDiff: Sendable {
        var branch: String
        var base: String
        var files: [Changes.File]
        var diff: String
        /// The files whose changes are not shown in full.
        var cut: [String]
    }

    func branchDiff(of copy: WorkingCopy, limit: Int = ReviewDiff.defaultLimit) async -> BranchDiff? {
        guard let changes = await changes(of: copy) else { return nil }
        // Against where the branch began, with the files git does not know
        // of yet added on a throwaway index, so a new file shows in full.
        // The copy's own index is left as it was.
        let script = """
        scratch=$(mktemp -d) || exit 1
        cp "$(git rev-parse --git-path index)" "$scratch/index" 2>/dev/null
        export GIT_INDEX_FILE="$scratch/index" GIT_TERMINAL_PROMPT=0
        git add -A && git -c core.quotePath=false diff --cached --no-color --no-ext-diff --no-renames \(changes.since)
        code=$?
        rm -rf "$scratch"
        exit $code
        """
        var shown = Shell.Result(output: "", code: -1)
        if Self.isFolder(copy.folder) { shown = await Shell.run(script, in: copy.folder, timeout: 90) }
        if !shown.ok {
            // Then as git has it, without what it does not know of.
            shown = await git("diff --no-color --no-ext-diff --no-renames \(changes.since)", in: copy.folder, timeout: 60)
        }
        var text = shown.ok ? shown.output : ""
        // Anything the shell printed before git's own output is passed over.
        if let start = text.range(of: "diff --git ") { text = String(text[start.lowerBound...]) }
        let fitted = ReviewDiff.fit(text, limit: limit)
        return BranchDiff(branch: copy.branch, base: copy.base, files: changes.files, diff: fitted.text, cut: fitted.cut)
    }

    /// A file as it was at a commit, or "" when it was not there.
    func original(of path: String, in copy: WorkingCopy, at commit: String) async -> String {
        let shown = await git("show \(Shell.quote(commit + ":" + path))", in: copy.folder, timeout: 30)
        return shown.ok ? shown.output : ""
    }
}
