import Foundation

/// The board's Auto permission (`BoardSettings.auto`): the owner grants it
/// once, it is kept with the board, and every chat working in the project
/// takes it from there.
///
/// It is granted once so that a board of many tasks can go on without a
/// question at each edit, build, test or commit. Four things stay the
/// owner's even then (`AlwaysAsk`): what they do cannot be put right from
/// inside a task's own branch, or hands over what is not the project's.
/// These are rules in code, not words to a model, so nothing a model is
/// told can widen them: change them here and in their tests.
public enum AutoPermission {
    /// Who works in a project. Each takes Auto from the board, and none
    /// has a wider Auto than another: it is the board's, not a chat's.
    public enum Worker: String, CaseIterable, Sendable {
        /// A run the board started on a task, in the task's chat.
        case taskRun
        /// The board's supervisor.
        case supervisor
        /// Any other chat opened in the project.
        case projectChat
    }

    /// What is asked about whether Auto is on or off.
    public enum AlwaysAsk: String, CaseIterable, Sendable {
        case mergeIntoMain, push, deletes, keys

        /// The sentence Board Settings shows for it.
        public var sentence: String {
            switch self {
            case .mergeIntoMain:
                return "Merging the board's branch (companion/main) into main, or moving main any other way, always asks you first."
            case .push:
                return "Pushing to any remote always asks you first."
            case .deletes:
                return "Deleting files or tasks, other than the board's own cleanup, always asks you first."
            case .keys:
                return "Anything that reads, writes or uses keys, tokens or credentials (the keychain, .env files, API keys) always asks you first."
            }
        }

        /// In words that finish "This one is yours to answer: ".
        public var words: String {
            switch self {
            case .mergeIntoMain: return "it merges into or moves main, which is yours even with Auto on"
            case .push: return "it pushes to a remote, which is yours even with Auto on"
            case .deletes: return "it deletes files or tasks, which is yours even with Auto on"
            case .keys: return "it touches keys, tokens or credentials, which is yours even with Auto on"
            }
        }
    }

    /// The one list of what Auto never covers, in the order Board
    /// Settings shows it.
    public static let alwaysAsks: [AlwaysAsk] = AlwaysAsk.allCases

    /// How a step stands under the board's Auto.
    public enum Decision: Equatable, Sendable {
        /// It goes ahead without asking.
        case runs
        /// It is asked about, whatever the chat's own access says.
        case asks(AlwaysAsk)
        /// Auto is off, or does not reach it: the chat's own access
        /// decides, as it would on no board.
        case notCovered
    }

    /// The person's own branches: the board's work reaches them only when
    /// the person merges it.
    public static let mainBranches: Set<String> = ["main", "master"]

    /// How a step a chat waits on stands. `worker` is nil for a chat in no
    /// project: Auto is a project's, so it never reaches one.
    public static func decide(_ step: Delegation.Step, in place: Delegation.Place, settings: BoardSettings,
                              by worker: Worker?) -> Decision {
        guard settings.auto, worker != nil else { return .notCovered }
        if let kept = alwaysAsk(step, in: place) { return .asks(kept) }
        // Auto reaches as far as the supervisor's own answers do (work in
        // the project's folder) and no further, so turning it on never
        // lets the system, other apps or sending off this Mac through.
        return Delegation.reserved(step, in: place) == nil ? .runs : .notCovered
    }

    /// How a supervisor's change to the board stands. Taking a task off
    /// is the owner's; the board's own cleanup (a task's copy put away
    /// once it has merged) is not a request and never comes here.
    public static func decide(_ operation: BoardOperation, settings: BoardSettings) -> Decision {
        guard settings.auto else { return .notCovered }
        switch operation {
        case .remove, .delete: return .asks(.deletes)
        default: return .runs
        }
    }

    // MARK: The four

    /// Which of the four a step is, if any.
    public static func alwaysAsk(_ step: Delegation.Step, in place: Delegation.Place) -> AlwaysAsk? {
        if step.namesKeys { return .keys }
        switch step.what {
        case .file(let path):
            return namesKeys(path) ? .keys : nil
        case .command(let text):
            return alwaysAsk(command: text, from: Delegation.tidy(place.directory))
        case .look, .app, .terminal:
            return nil
        }
    }

    /// Words that name keys or credentials, in lower case. Wider than the
    /// app's own list on purpose: a false ask costs a click, a missed one
    /// can hand over a key.
    private static let keyWords = [
        ".env", "keychain", "credential", "secrets", "api_key", "apikey", "api-key", "access_token", "auth_token",
        "private_key", ".pem", ".p12", "id_rsa", "id_ed25519", ".netrc", ".npmrc", ".pypirc", ".ssh/", "/.ssh",
        ".aws/", "/.aws", ".gnupg"
    ]

    static func namesKeys(_ text: String) -> Bool {
        let lower = text.lowercased()
        return keyWords.contains { lower.contains($0) }
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]

    private static func alwaysAsk(command: String, from directory: String) -> AlwaysAsk? {
        if namesKeys(command) { return .keys }
        for part in Delegation.read(command).parts {
            for call in Delegation.calls(in: part.text) {
                if let kept = alwaysAsk(call, from: directory) { return kept }
            }
        }
        return nil
    }

    private static func alwaysAsk(_ call: Delegation.Call, from directory: String) -> AlwaysAsk? {
        let arguments = call.arguments
        if Delegation.keyTools.contains(call.program) || call.program == "security" { return .keys }
        // A shell handed its commands in a word runs them like any others.
        if shells.contains(call.program) {
            for (index, word) in arguments.enumerated() where word.hasPrefix("-") && !word.hasPrefix("--") {
                if word.contains("c"), index + 1 < arguments.count {
                    return alwaysAsk(command: arguments[index + 1], from: directory)
                }
            }
            return nil
        }
        switch call.program {
        case "git":
            return git(arguments)
        case "gh":
            let words = arguments.filter { !$0.hasPrefix("-") }.map { $0.lowercased() }
            if words.starts(with: ["pr", "merge"]) { return .mergeIntoMain }
            if words.starts(with: ["repo", "sync"]) { return .push }
            return nil
        case "rm", "rmdir", "unlink", "trash", "srm":
            return removes(arguments, from: directory)
        case "find":
            if arguments.contains("-delete") { return .deletes }
            for (index, word) in arguments.enumerated()
            where ["-exec", "-execdir", "-ok", "-okdir"].contains(word) && index + 1 < arguments.count {
                let program = (arguments[index + 1].split(separator: "/").last.map(String.init) ?? "").lowercased()
                if ["rm", "rmdir", "unlink", "trash"].contains(program) { return .deletes }
            }
            return nil
        default:
            return nil
        }
    }

    private static func git(_ arguments: [String]) -> AlwaysAsk? {
        let told = Delegation.gitVerb(arguments)
        let rest = told.rest
        let named = rest.filter { !$0.hasPrefix("-") }
        switch told.verb {
        case "push":
            return .push
        case "rm":
            return rest.contains("--cached") ? nil : .deletes
        case "clean":
            let dry = rest.contains(where: { $0 == "--dry-run" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("n")) })
            return dry ? nil : .deletes
        case "checkout", "switch":
            // On main, the next merge or commit lands on the person's branch.
            return named.contains(where: isMain) ? .mergeIntoMain : nil
        case "merge", "pull", "rebase", "cherry-pick":
            // The board's branch reaches the person's only by their merge;
            // a task's own copy is merged back by the board itself.
            return named.contains(where: { isMain($0) && $0.contains(":") || isBoardBranch($0) }) ? .mergeIntoMain : nil
        case "branch":
            let moves = rest.contains(where: { ["-f", "--force", "-m", "-M", "-c", "-C"].contains($0) })
            return moves && named.contains(where: isMain) ? .mergeIntoMain : nil
        case "update-ref":
            return named.contains(where: isMain) ? .mergeIntoMain : nil
        case "fetch":
            return named.contains(where: { $0.contains(":") && isMain($0) }) ? .mergeIntoMain : nil
        default:
            return nil
        }
    }

    /// A word that names one of the person's branches as where something
    /// lands: the branch itself, or the far side of a refspec.
    private static func isMain(_ word: String) -> Bool {
        var name = word.hasPrefix("+") ? String(word.dropFirst()) : word
        if let colon = name.lastIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
        if name.hasPrefix("refs/heads/") { name = String(name.dropFirst(11)) }
        return mainBranches.contains(name)
    }

    private static func isBoardBranch(_ word: String) -> Bool {
        let name = word.hasPrefix("refs/heads/") ? String(word.dropFirst(11)) : word
        return name.hasPrefix("companion/")
    }

    /// Removing is the owner's, except in a place for throwaway files.
    private static func removes(_ arguments: [String], from directory: String) -> AlwaysAsk? {
        var targets: [String] = []
        var flagsOver = false
        for word in arguments {
            if !flagsOver, word == "--" {
                flagsOver = true
                continue
            }
            if !flagsOver, word.hasPrefix("-"), word.count > 1 { continue }
            targets.append(word)
        }
        // Handed its targets by another program: not known.
        if targets.isEmpty { return .deletes }
        for target in targets {
            if target.contains("$") || target.hasPrefix("~") { return .deletes }
            let path = Delegation.tidy(target.hasPrefix("/") ? target : directory + "/" + target)
            if !Delegation.isScratch(path) { return .deletes }
        }
        return nil
    }
}