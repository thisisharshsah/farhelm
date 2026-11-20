import Foundation

/// A task's own copy of its project's repository: a git worktree on a
/// branch of its own, made from the branch the project's folder was on
/// when the task's first run began. All of the task's runs work there.
/// So runs going on at once stay out of each other's way and out of the
/// person's own folder, and what the supervisor may let a run do unasked
/// ends at the copy's edge (`Delegation` takes the folder a run starts in
/// as the project). Approved, the branch is merged into the branch it
/// came from and the copy is taken down; thrown away, the copy and its
/// branch are deleted.
///
/// The board keeps what a copy is and how it stands. Making one, merging
/// it and taking it down is git's work, which the app does.
public struct WorkingCopy: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// The task's runs work in it.
        case open
        /// Its branch was merged into the branch it came from; the copy
        /// and the branch are gone.
        case merged
        /// Thrown away: the copy and its branch were deleted, or the
        /// branch was found gone.
        case discarded
    }

    /// The copy's top folder.
    public var folder: String
    /// Where the project's folder is in the repository, as a path from
    /// its top: "apple" for a project that is one folder of a larger
    /// repository, "" for one at the top. Runs start there.
    public var subfolder: String
    /// The copy's own branch.
    public var branch: String
    /// The branch it was made from. Its work is merged into this one.
    public var base: String
    /// The commit it was made from.
    public var baseCommit: String
    public var state: State
    public var madeAt: Date
    /// When it was merged or thrown away.
    public var closedAt: Date?
    /// Who let its work be merged: "You", or the model whose review
    /// approved it. Given when the task is approved, or a person moves it
    /// to Done; taken back when a run begins on it or it leaves Done.
    public var approvedBy: String?
    /// Why its work was not merged the last time that was tried, in words
    /// for the person. Nothing tries again until they say so.
    public var problem: String?
    /// The files where the branch it came from has moved on in a way that
    /// conflicts with its work, as found the last time a merge was tried.
    /// The next run is told to bring that branch in and settle them.
    public var conflicts: [String]
    /// The commit its work went into the branch it came from as. nil
    /// when it is not merged, or there was nothing to merge.
    public var mergeCommit: String?
    /// The person's branch, when `base` is the board's own branch for it
    /// (`boardBranch(for:)`): the work merged there goes on into this one
    /// whenever the person's own changes allow. nil for a copy whose work
    /// is merged straight into the person's branch.
    public var target: String?
    /// How many times its work was found to conflict with `base` and sent
    /// back for a run to settle (`Board.copyConflicts`).
    public var settleTries: Int

    public init(folder: String, subfolder: String = "", branch: String, base: String, baseCommit: String,
                state: State = .open, madeAt: Date, closedAt: Date? = nil, approvedBy: String? = nil,
                problem: String? = nil, conflicts: [String] = [], mergeCommit: String? = nil,
                target: String? = nil, settleTries: Int = 0) {
        self.folder = folder
        self.subfolder = subfolder
        self.branch = branch
        self.base = base
        self.baseCommit = baseCommit
        self.state = state
        self.madeAt = madeAt
        self.closedAt = closedAt
        self.approvedBy = approvedBy
        self.problem = problem
        self.conflicts = conflicts
        self.mergeCommit = mergeCommit
        self.target = target
        self.settleTries = settleTries
    }

    /// Its task's runs work in it.
    public var isOpen: Bool { state == .open }

    /// Where its runs start: the project's folder, inside the copy.
    public var directory: String {
        subfolder.isEmpty ? folder : folder + "/" + subfolder
    }

    private enum CodingKeys: String, CodingKey {
        case folder, subfolder, branch, base, baseCommit, state, madeAt, closedAt, approvedBy, problem, conflicts
        case mergeCommit, target, settleTries
    }

    /// Read field by field, so what was saved before a field existed
    /// still loads.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        folder = try values.decode(String.self, forKey: .folder)
        subfolder = try values.decodeIfPresent(String.self, forKey: .subfolder) ?? ""
        branch = try values.decode(String.self, forKey: .branch)
        base = try values.decode(String.self, forKey: .base)
        baseCommit = try values.decodeIfPresent(String.self, forKey: .baseCommit) ?? ""
        state = try values.decodeIfPresent(State.self, forKey: .state) ?? .open
        madeAt = try values.decodeIfPresent(Date.self, forKey: .madeAt) ?? Date(timeIntervalSince1970: 0)
        closedAt = try values.decodeIfPresent(Date.self, forKey: .closedAt)
        approvedBy = try values.decodeIfPresent(String.self, forKey: .approvedBy)
        problem = try values.decodeIfPresent(String.self, forKey: .problem)
        conflicts = try values.decodeIfPresent([String].self, forKey: .conflicts) ?? []
        mergeCommit = try values.decodeIfPresent(String.self, forKey: .mergeCommit)
        target = try values.decodeIfPresent(String.self, forKey: .target)
        settleTries = try values.decodeIfPresent(Int.self, forKey: .settleTries) ?? 0
    }
}

// MARK: - Names

extension WorkingCopy {
    /// The most of a task's title that a branch name carries.
    public static let slugLimit = 40

    /// A title as a branch name can carry it: lower-case letters and
    /// digits, words joined by "-", cut after the last whole word that
    /// fits in `limit`. Marks come off letters ("é" is "e"); anything
    /// else that is not a letter or digit of the Latin alphabet ends a
    /// word. nil when nothing is left.
    public static func slug(_ text: String, limit: Int = slugLimit) -> String? {
        let plain = text.folding(options: [.diacriticInsensitive, .widthInsensitive],
                                 locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var words: [String] = []
        var word = ""
        for scalar in plain.unicodeScalars {
            let value = scalar.value
            if (48...57).contains(value) || (97...122).contains(value) {
                word.unicodeScalars.append(scalar)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }
        if !word.isEmpty { words.append(word) }
        guard let first = words.first, limit > 0 else { return nil }
        var joined = ""
        for word in words {
            let longer = joined.isEmpty ? word : joined + "-" + word
            if longer.count > limit { break }
            joined = longer
        }
        // One word longer than the limit is cut to it.
        return joined.isEmpty ? String(first.prefix(limit)) : joined
    }

    /// The branch for a task's copy: "task/t-7-add-the-login-form". A name
    /// the repository has already (`taken`, compared without regard to
    /// case, as a Mac's disk compares them) gets "-2", "-3" and so on.
    /// `flat` writes "task-t-7-..." instead, for a repository with a
    /// branch named "task", which leaves no room for "task/" branches.
    public static func branch(for item: WorkItem, taken: Set<String>, flat: Bool = false) -> String {
        let stem = (flat ? "task-" : "task/") + item.key.lowercased() + (slug(item.title).map { "-" + $0 } ?? "")
        return unique(stem, among: taken)
    }

    /// The folder a task's copy is made in, inside the project's place for
    /// copies: "t-7", or "t-7-2" and so on when that is `taken`.
    public static func folderName(for item: WorkItem, taken: Set<String>) -> String {
        unique(item.key.lowercased(), among: taken)
    }

    /// What the board's own branches begin with.
    public static let boardPrefix = "companion"

    /// The board's own branch for a person's branch: "companion/main".
    /// Tasks branch from it and their approved work is merged into it, one
    /// at a time, so merging never touches the folder the person works in
    /// or what they have not committed; it goes on into their branch when
    /// that can be done without touching their changes. `flat` writes
    /// "companion-main" instead, for a repository with a branch named
    /// "companion", which leaves no room for "companion/" branches.
    public static func boardBranch(for branch: String, flat: Bool = false) -> String {
        flat ? boardPrefix + "-" + branch.replacingOccurrences(of: "/", with: "-") : boardPrefix + "/" + branch
    }

    /// Whether a branch is a board's own ("companion/main"): a folder on
    /// one has its tasks branch from it, and nothing goes on from there.
    public static func isBoardBranch(_ branch: String) -> Bool {
        branch.hasPrefix(boardPrefix + "/")
    }

    static func unique(_ stem: String, among taken: Set<String>) -> String {
        let known = Set(taken.map { $0.lowercased() })
        guard known.contains(stem.lowercased()) else { return stem }
        var number = 2
        while known.contains("\(stem)-\(number)".lowercased()) { number += 1 }
        return "\(stem)-\(number)"
    }
}

// MARK: - The board's side

extension Board {
    /// Whether a task's next run needs a copy made for it first. On a
    /// board that gives each task one (`BoardSettings.copyPerTask`), a
    /// task gets its copy for its first run, and a new one after the one
    /// it had was merged or thrown away. A task whose runs worked in the
    /// project's folder before it had a copy goes on working there.
    public func needsCopy(_ item: WorkItem) -> Bool {
        guard settings.copyPerTask else { return false }
        if let copy = item.workingCopy { return !copy.isOpen }
        return item.runs.isEmpty
    }

    /// Who did what a copy's approval says was done.
    static func actor(approvedBy: String?) -> BoardActor {
        approvedBy == "You" ? .person : .supervisor
    }

    /// Gives a task the copy made for it.
    @discardableResult
    public mutating func setCopy(_ id: UUID, _ copy: WorkingCopy, by actor: BoardActor, now: Date) -> Bool {
        guard let index = allItems.firstIndex(where: { $0.id == id }) else { return false }
        allItems[index].workingCopy = copy
        allItems[index].updatedAt = now
        log("\(allItems[index].key) works on branch \(copy.branch), made from \(copy.base)", by: actor,
            item: allItems[index].number, now: now)
        return true
    }

    /// Lets the work in a task's open copy be merged, as `who` said.
    mutating func approveCopy(at index: Int, by who: String) {
        guard allItems[index].workingCopy?.isOpen == true else { return }
        allItems[index].workingCopy?.approvedBy = who
        allItems[index].workingCopy?.problem = nil
    }

    /// Takes back the leave to merge the work in a task's open copy.
    mutating func withdrawCopyApproval(at index: Int) {
        guard allItems[index].workingCopy?.isOpen == true else { return }
        allItems[index].workingCopy?.approvedBy = nil
        allItems[index].workingCopy?.problem = nil
    }

    /// The tasks whose work was approved and waits to be merged, under
    /// whichever goal: done, with an open copy that was let through and
    /// is not held back by a problem only the person can settle.
    public var waitingToMerge: [WorkItem] {
        allItems.filter { item in
            guard item.status == .done, let copy = item.workingCopy, copy.isOpen else { return false }
            return copy.approvedBy != nil && copy.problem == nil
        }
    }

    /// Whether a task's work waits on the person to be merged: it is
    /// done, but its copy is still open, and either the last try to merge
    /// it found a problem only they can settle, or nobody let it through.
    public func mergeWaitsOnPerson(_ item: WorkItem) -> Bool {
        guard item.status == .done, let copy = item.workingCopy, copy.isOpen else { return false }
        return copy.problem != nil || copy.approvedBy == nil
    }

    /// A person asks for a done task's work to be merged now: it is let
    /// through, as theirs, and whatever held it back last time is tried
    /// again.
    @discardableResult
    public mutating func mergeAgain(_ id: UUID, now: Date) -> Bool {
        guard let index = allItems.firstIndex(where: { $0.id == id }), allItems[index].status == .done,
              allItems[index].workingCopy?.isOpen == true else { return false }
        approveCopy(at: index, by: "You")
        allItems[index].updatedAt = now
        updatedAt = now
        return true
    }

    /// A task's work went into the branch its copy came from (`commit`),
    /// or there was nothing in it to merge (nil): the copy is closed.
    @discardableResult
    public mutating func copyMerged(_ id: UUID, commit: String?, now: Date) -> Bool {
        guard let index = allItems.firstIndex(where: { $0.id == id }), let copy = allItems[index].workingCopy,
              copy.isOpen else { return false }
        allItems[index].workingCopy?.state = .merged
        allItems[index].workingCopy?.closedAt = now
        allItems[index].workingCopy?.mergeCommit = commit
        allItems[index].workingCopy?.problem = nil
        allItems[index].workingCopy?.conflicts = []
        allItems[index].updatedAt = now
        let key = allItems[index].key
        let text = commit.map { "Merged \(key) into \(copy.base) (\($0))" }
            ?? "\(key) had nothing on \(copy.branch) to merge, and its copy was taken down"
        log(text, by: Self.actor(approvedBy: copy.approvedBy), item: allItems[index].number, now: now)
        return true
    }

    /// A task's work could not be merged now, for a reason only the
    /// person can settle (changes of theirs in the way, say): it waits in
    /// Done for them to try again (`mergeAgain`).
    @discardableResult
    public mutating func copyHeld(_ id: UUID, problem: String, now: Date) -> Bool {
        let problem = problem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !problem.isEmpty, let index = allItems.firstIndex(where: { $0.id == id }),
              allItems[index].workingCopy?.isOpen == true else { return false }
        allItems[index].workingCopy?.problem = String(problem.prefix(600))
        allItems[index].updatedAt = now
        log("\(allItems[index].key) was not merged: \(problem.prefix(160))", by: .run, item: allItems[index].number,
            now: now)
        return true
    }

    /// The branch a task's copy came from has moved on and conflicts with
    /// the task's work in `files` (or a run left a merge unsettled there).
    /// The task goes back to To do, where its next run brings that branch
    /// in and settles them, and its work is looked at again before it is
    /// merged. Sent back `BoardRules.settleLimit` times already, it waits
    /// in Done for the person instead.
    @discardableResult
    public mutating func copyConflicts(_ id: UUID, files: [String], now: Date) -> Bool {
        guard let index = allItems.firstIndex(where: { $0.id == id }), let copy = allItems[index].workingCopy,
              copy.isOpen else { return false }
        let actor = Self.actor(approvedBy: copy.approvedBy)
        let named = Array(files.prefix(30))
        let list = named.prefix(6).joined(separator: ", ") + (named.count > 6 ? " and \(named.count - 6) more" : "")
        allItems[index].workingCopy?.conflicts = named
        allItems[index].workingCopy?.settleTries = copy.settleTries + 1
        allItems[index].updatedAt = now
        if copy.settleTries >= BoardRules.settleLimit {
            let tries = copy.settleTries == 1 ? "a run" : "\(copy.settleTries) runs"
            allItems[index].workingCopy?.problem = "It still conflicts with \(copy.base) in \(list.isEmpty ? "some files" : list) after \(tries) to settle it. Settle that in its chat and merge it again, or throw the work away."
            log("\(allItems[index].key) still conflicts with \(copy.base): it waits for you", by: .run,
                item: allItems[index].number, now: now)
            return true
        }
        allItems[index].workingCopy?.approvedBy = nil
        allItems[index].workingCopy?.problem = nil
        note(id, "\(copy.base) has moved on and conflicts with this work in \(list.isEmpty ? "some files" : list). "
             + "The next run brings \(copy.base) in and settles them.", author: "Git", now: now)
        if allItems[index].status != .todo { move(id, to: .todo, by: actor, now: now) }
        return true
    }

    /// A task's copy was thrown away, with its branch: its next run
    /// starts again from a new copy. A task that waited for review or to
    /// be merged goes back to To do, since the work it waited with is gone.
    @discardableResult
    public mutating func copyDiscarded(_ id: UUID, by actor: BoardActor, now: Date) -> Bool {
        guard let index = allItems.firstIndex(where: { $0.id == id }), let copy = allItems[index].workingCopy,
              copy.isOpen else { return false }
        close(index, now: now)
        log("Threw away \(allItems[index].key)'s work on \(copy.branch)", by: actor, item: allItems[index].number,
            now: now)
        // Its next run reads this: what the runs before it did is gone.
        note(id, "Its work on \(copy.branch) was thrown away. The next run starts again, in a new copy of \(copy.base).",
             author: "Git", now: now)
        if allItems[index].status == .review || allItems[index].status == .done {
            move(id, to: .todo, by: actor, now: now)
        }
        return true
    }

    /// A task's open copy has lost its branch (someone deleted it outside
    /// the app): it is let go, and the next run gets a new copy.
    @discardableResult
    public mutating func copyLost(_ id: UUID, now: Date) -> Bool {
        guard let index = allItems.firstIndex(where: { $0.id == id }), let copy = allItems[index].workingCopy,
              copy.isOpen else { return false }
        close(index, now: now)
        log("\(allItems[index].key)'s branch \(copy.branch) is no longer in the repository", by: .run,
            item: allItems[index].number, now: now)
        note(id, "Its branch, \(copy.branch), was no longer in the repository. The next run starts in a new copy of \(copy.base).",
             author: "Git", now: now)
        return true
    }

    private mutating func close(_ index: Int, now: Date) {
        allItems[index].workingCopy?.state = .discarded
        allItems[index].workingCopy?.closedAt = now
        allItems[index].workingCopy?.approvedBy = nil
        allItems[index].workingCopy?.problem = nil
        allItems[index].workingCopy?.conflicts = []
        allItems[index].updatedAt = now
        updatedAt = now
    }
}
