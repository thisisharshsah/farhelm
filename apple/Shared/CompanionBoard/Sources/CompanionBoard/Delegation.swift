import Foundation

/// What a project's supervisor may answer in the person's place, on a
/// board that is set to take its recommended answer
/// (`BoardSettings.followsAdvice`).
///
/// The supervisor is a model. It can be wrong, and what it reads (a
/// task, a file, a web page) can be written to mislead it. So its yes
/// counts only where a wrong yes can be put right from inside the
/// project: work in the project's folder, and installing or downloading
/// what the task needs. The rest stays the person's to answer, whatever
/// the supervisor says: keys and credentials, acting on the system or as
/// its administrator, sending work off this Mac, working other apps,
/// changing anything outside the project's folder, removing whole
/// folders, and throwing away changes that are not saved.
///
/// These are rules in code, not instructions to the model, so nothing it
/// is told can widen them. They read a command as text, part by part,
/// the way it is written. A command written to hide what it runs can get
/// past them, which is why they come after the supervisor's own judgment
/// and never instead of it.
public enum Delegation {
    /// One thing an agent asks permission to do, as far as it can be
    /// told without doing it.
    public struct Step: Equatable, Sendable {
        public enum What: Equatable, Sendable {
            /// A shell command, as written.
            case command(String)
            /// A file to create, replace or change, by its full path.
            case file(String)
            /// Something that only looks: reading, searching, a web page,
            /// a web search.
            case look
            /// Working an app with the keyboard or the pointer, or acting
            /// in a browser as the person.
            case app
            /// A terminal the person works in with the agent.
            case terminal
        }

        public var what: What
        /// It names keys or credentials. The app judges that, the same
        /// way at every level of access.
        public var namesKeys: Bool

        public init(_ what: What, namesKeys: Bool = false) {
            self.what = what
            self.namesKeys = namesKeys
        }
    }

    /// Where the agent works.
    public struct Place: Equatable, Sendable {
        /// The project's folder as a full path. Empty when it has none:
        /// then nothing is work in the project.
        public var project: String
        /// The folder commands run in.
        public var directory: String
        /// The person's home folder, for paths written with "~".
        public var home: String

        public init(project: String, directory: String, home: String) {
            self.project = project
            self.directory = directory
            self.home = home
        }
    }

    /// Why a step is the person's to answer.
    public enum Reserved: String, Equatable, Sendable, CaseIterable {
        case keys, system, sends, apps, terminal, outside, repository, removes, discards, unseen, unclear

        /// In words that finish "This one is yours to answer: ".
        public var words: String {
            switch self {
            case .keys: return "it names keys or credentials"
            case .system: return "it acts on the system or as its administrator"
            case .sends: return "it sends something off this Mac or acts on another machine"
            case .apps: return "it works another app, the screen or the clipboard"
            case .terminal: return "it opens a terminal for you to work in"
            case .outside: return "it reaches outside the project's folder"
            case .repository: return "it changes git's own files, not the project's"
            case .removes: return "it removes a whole folder that cannot simply be made again"
            case .discards: return "it puts away or throws away changes that are not saved in git"
            case .unseen: return "it runs what it downloads before anyone has seen it"
            case .unclear: return "what it runs cannot be told from how it is written"
            }
        }
    }

    // MARK: The rules

    /// Why these steps are the person's to answer: the first reason
    /// found, or nil when the supervisor's answer may be taken for all
    /// of them.
    public static func reserved(_ steps: [Step], in place: Place) -> Reserved? {
        for step in steps {
            if let reason = reserved(step, in: place) { return reason }
        }
        return nil
    }

    /// Why a step is the person's to answer, or nil when the
    /// supervisor's answer may be taken for it.
    public static func reserved(_ step: Step, in place: Place) -> Reserved? {
        if step.namesKeys { return .keys }
        let tidied = Place(project: folder(place.project), directory: folder(place.directory),
                           home: folder(place.home))
        switch step.what {
        case .look:
            return nil
        case .app:
            return .apps
        case .terminal:
            return .terminal
        case .file(let path):
            let target = tidy(path)
            if isScratch(target) { return nil }
            guard inside(target, tidied.project) else { return .outside }
            return inside(target, tidied.project + "/.git") ? .repository : nil
        case .command(let command):
            return reserved(command: command, in: tidied)
        }
    }

    /// The rules for a shell command. `place` has been tidied.
    static func reserved(command: String, in place: Place) -> Reserved? {
        let script = read(command)
        // What these run is only known once they have run.
        for mark in ["`", "$(", "<(", ">("] where script.live.contains(mark) {
            return .unclear
        }
        var onlyReads = !writesOutput(script.live)
        var downloads = false
        var feedsInterpreter = false
        var run: [Call] = []
        // The files a download saves, by name.
        var saved: [String] = []
        for piece in script.parts {
            let calls = Self.calls(in: piece.text)
            // Run through another program ("xargs", "env"), a part is
            // not known to only read.
            if calls.count > 1 { onlyReads = false }
            for call in calls {
                if let reason = reserved(call, in: place) { return reason }
                if !isReader(call) { onlyReads = false }
                if call.program == "curl" || call.program == "wget" {
                    downloads = true
                    saved.append(contentsOf: Self.saved(by: call))
                }
                if piece.joint == "|", interpreters.contains(call.program) { feedsInterpreter = true }
                run.append(call)
            }
        }
        // Fetched and run in one go, nobody has seen what is run: down
        // a pipe into a program that runs it, or saved and then run.
        if downloads && feedsInterpreter { return .unseen }
        for call in run where !saved.isEmpty {
            // A program that runs what it is handed is judged by the
            // files it is handed; any other, by its own name.
            var named = [call.program]
            if interpreters.contains(call.program) { named = call.arguments.map({ programName($0) }) }
            if named.contains(where: { saved.contains($0) }) { return .unseen }
        }
        return onlyReads ? nil : reach(of: script.parts, in: place)
    }

    // MARK: Programs

    /// Programs that act on the system itself, as its administrator, or
    /// on what other programs are doing.
    private static let system: Set<String> = [
        "sudo", "su", "doas", "shutdown", "reboot", "halt", "diskutil", "launchctl", "dd", "chown", "security",
        "killall", "pkill", "csrutil", "spctl", "systemsetup", "networksetup", "scutil", "pmset", "tmutil", "dscl",
        "crontab", "mount", "umount", "nvram", "softwareupdate", "installer", "docker", "podman"
    ]

    /// Programs that work other apps, look at the screen, or read and
    /// fill the clipboard.
    private static let otherApps: Set<String> = [
        "open", "osascript", "automator", "shortcuts", "screencapture", "pbpaste", "pbcopy"
    ]

    /// Programs that send to, or act on, another machine.
    private static let senders: Set<String> = [
        "scp", "sftp", "ssh", "nc", "ncat", "netcat", "telnet", "ftp", "mail", "sendmail", "aws", "gcloud", "az",
        "doctl", "firebase", "vercel", "netlify", "heroku", "fly", "flyctl", "wrangler", "kubectl", "helm",
        "terraform", "pulumi", "ansible", "ansible-playbook"
    ]

    /// Programs that make or hand over keys.
    static let keyTools: Set<String> = ["ssh-keygen", "ssh-add", "ssh-copy-id", "gpg", "gpg2"]

    /// What these programs are told to do when they publish, or sign in
    /// to where they publish.
    private static let publishing: [String: Set<String>] = [
        "npm": ["publish", "unpublish", "login", "adduser", "deprecate", "owner", "access", "token"],
        "pnpm": ["publish"],
        "yarn": ["publish", "login"],
        "cargo": ["publish", "login", "yank", "owner"],
        "gem": ["push", "yank", "signin"],
        "twine": ["upload"],
        "poetry": ["publish"],
        "uv": ["publish"],
        "hatch": ["publish"],
        "flit": ["publish"],
        "pod": ["trunk"]
    ]

    /// What Homebrew may be told without it changing what is installed
    /// beyond adding what a task needs.
    private static let brewKeeps: Set<String> = [
        "install", "list", "ls", "info", "search", "outdated", "deps", "fetch", "update", "config", "doctor"
    ]

    /// Programs that run what they are handed.
    private static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "fish", "python", "python3", "node", "ruby", "perl", "php", "osascript"
    ]

    /// Programs that only look, whatever they are pointed at.
    private static let readers: Set<String> = [
        "ls", "pwd", "cd", "cat", "head", "tail", "grep", "egrep", "fgrep", "rg", "wc", "which", "date", "whoami",
        "echo", "printf", "file", "stat", "du", "df", "tree", "sw_vers", "uname", "mdls", "mdfind", "pgrep", "ps",
        "diff", "cmp", "sort", "uniq", "cut", "tr", "basename", "dirname", "realpath", "readlink", "true", "false",
        "test", "[", "less", "more", "jq", "shasum", "md5", "id", "hostname", "nl", "column"
    ]

    /// What git may be told that only looks.
    private static let gitReads: Set<String> = [
        "status", "diff", "log", "show", "rev-parse", "ls-files", "blame", "describe", "shortlog", "ls-tree",
        "cat-file", "grep", "merge-base", "rev-list"
    ]

    /// Folders that are made from the project and can be made again:
    /// removing one loses nothing.
    private static let remade: Set<String> = [
        "build", ".build", "dist", "out", "target", "node_modules", "deriveddata", "__pycache__", ".pytest_cache",
        ".mypy_cache", ".ruff_cache", ".next", ".nuxt", ".turbo", ".cache", "coverage", "tmp", "temp", ".tmp",
        "venv", ".venv"
    ]

    /// Why one program, run with these words, is the person's to answer.
    private static func reserved(_ call: Call, in place: Place) -> Reserved? {
        let program = call.program
        let arguments = call.arguments
        // A program named by a variable, or put together as it runs.
        if program.hasPrefix("$") || program == "eval" { return .unclear }
        if keyTools.contains(program) { return .keys }
        if system.contains(program) { return .system }
        if otherApps.contains(program) { return .apps }
        if senders.contains(program) { return .sends }
        // A shell handed its commands in a word runs them like any others.
        if shells.contains(program), let inner = inlineScript(arguments) {
            return reserved(command: inner, in: place)
        }
        // What it is told to do: the first word after it that is not a flag.
        let verb = arguments.first(where: { !$0.hasPrefix("-") })?.lowercased() ?? ""
        if let verbs = publishing[program], verbs.contains(verb) { return .sends }
        switch program {
        case "defaults":
            return ["read", "read-type", "domains", "find", "help"].contains(verb) ? nil : .system
        case "brew":
            return verb.isEmpty || brewKeeps.contains(verb) ? nil : .system
        case "git":
            return git(arguments)
        case "gh":
            return gh(arguments)
        case "rsync":
            return arguments.contains(where: { isRemote($0) }) ? .sends : nil
        case "curl":
            return curlSends(arguments) ? .sends : nil
        case "wget":
            return wgetSends(arguments) ? .sends : nil
        case "rm":
            return removal(arguments, in: place)
        case "find":
            if arguments.contains("-delete") { return .removes }
            // What it runs on each thing it finds is a program like any
            // other; removing them is removing nobody can count.
            for (index, word) in arguments.enumerated() where ["-exec", "-execdir", "-ok", "-okdir"].contains(word) {
                let rest = arguments[(index + 1)...].prefix(while: { $0 != ";" && $0 != "+" })
                guard let first = rest.first else { continue }
                let inner = Call(program: programName(first), arguments: Array(rest.dropFirst()))
                if inner.program == "rm" { return .removes }
                if let reason = reserved(inner, in: place) { return reason }
            }
            return nil
        default:
            return nil
        }
    }

    /// Whether a program, run with these words, only looks.
    private static func isReader(_ call: Call) -> Bool {
        let arguments = call.arguments
        switch call.program {
        case "git":
            return gitReads.contains(gitVerb(arguments).verb)
        case "defaults":
            return true
        case "find":
            return !arguments.contains(where: { $0.hasPrefix("-exec") || $0.hasPrefix("-ok") || $0.hasPrefix("-fprint") })
        case "sed":
            return !arguments.contains(where: { $0.hasPrefix("-i") || $0 == "--in-place" })
        default:
            return readers.contains(call.program)
        }
    }

    /// The commands a shell is handed to run in a word ("-c"), when it
    /// is: nil when it runs a file, or reads from the keyboard.
    private static func inlineScript(_ arguments: [String]) -> String? {
        for (index, word) in arguments.enumerated() {
            if word.hasPrefix("--") { continue }
            guard word.hasPrefix("-") else { return nil }
            if word.contains("c"), index + 1 < arguments.count { return arguments[index + 1] }
        }
        return nil
    }

    /// The files a download is told to save, by name in lower case.
    private static func saved(by call: Call) -> [String] {
        let arguments = call.arguments
        var names: [String] = []
        // wget names the file after its address unless told otherwise;
        // curl only when asked to.
        var byAddress = call.program == "wget"
        for (index, word) in arguments.enumerated() {
            let next = index + 1 < arguments.count ? arguments[index + 1] : ""
            if call.program == "curl" {
                // "-o", alone or last among flags written together.
                let short = word.hasPrefix("-") && !word.hasPrefix("--") && word.hasSuffix("o")
                    && word.dropFirst().allSatisfy({ $0.isLetter })
                if short || word == "--output" { names.append(programName(next)) }
                if word == "-O" || word == "--remote-name" { byAddress = true }
            } else if word == "-O" || word == "--output-document" {
                names.append(programName(next))
                byAddress = false
            }
        }
        if byAddress {
            for word in arguments where word.contains("://") { names.append(programName(word)) }
        }
        return names.filter { !$0.isEmpty && $0 != "-" }
    }

    // MARK: git and GitHub

    /// What git is told to do, with the words after it. Its own options
    /// before that ("-C folder") are passed over.
    static func gitVerb(_ arguments: [String]) -> (verb: String, rest: [String]) {
        let takeValue: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"]
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if takeValue.contains(word) {
                index += 2
                continue
            }
            if word.hasPrefix("-") {
                index += 1
                continue
            }
            return (word.lowercased(), Array(arguments[(index + 1)...]))
        }
        return ("", [])
    }

    private static func git(_ arguments: [String]) -> Reserved? {
        let told = gitVerb(arguments)
        let rest = told.rest
        let next = rest.first(where: { !$0.hasPrefix("-") })?.lowercased() ?? ""
        switch told.verb {
        case "push", "send-email":
            return .sends
        case "remote":
            return ["add", "set-url", "remove", "rm", "rename"].contains(next) ? .sends : nil
        case "config":
            if rest.contains("--system") { return .system }
            return rest.contains("--global") ? .outside : nil
        case "reset":
            return rest.contains("--hard") ? .discards : nil
        case "clean":
            // Only a dry run leaves the files where they are.
            let dry = rest.contains(where: { $0 == "--dry-run" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("n")) })
            return dry ? nil : .discards
        case "checkout":
            return rest.contains(where: { $0 == "--" || $0 == "." || $0 == "-f" || $0 == "--force" }) ? .discards : nil
        case "restore":
            return rest.contains("--staged") && !rest.contains("--worktree") ? nil : .discards
        case "stash":
            return ["", "push", "save", "drop", "clear"].contains(next) ? .discards : nil
        case "branch":
            return rest.contains("-D") || (rest.contains("--delete") && rest.contains("--force")) ? .discards : nil
        case "filter-branch", "filter-repo":
            return .discards
        case "reflog":
            return ["expire", "delete"].contains(next) ? .discards : nil
        default:
            return nil
        }
    }

    /// GitHub's own program acts on GitHub as the person, except where
    /// it only shows something.
    private static func gh(_ arguments: [String]) -> Reserved? {
        let words = arguments.filter { !$0.hasPrefix("-") }.map { $0.lowercased() }
        guard let first = words.first else { return nil }
        if ["status", "help", "version"].contains(first) { return nil }
        if words.count > 1, ["view", "list", "status", "diff", "checks"].contains(words[1]) { return nil }
        return .sends
    }

    // MARK: Sending

    /// "host:folder" and "user@host:folder", and addresses.
    private static func isRemote(_ word: String) -> Bool {
        if word.hasPrefix("-") { return false }
        if word.contains("://") { return true }
        guard let colon = word.firstIndex(of: ":") else { return false }
        let before = word[..<colon]
        // A path with a colon in it has a slash before the colon.
        return !before.isEmpty && !before.contains("/")
    }

    private static func isQuiet(_ method: String) -> Bool {
        let name = method.uppercased()
        return name == "GET" || name == "HEAD"
    }

    /// Whether curl is told to send something: a body, a form, a file,
    /// or a request that is not a plain fetch. A value from the shell in
    /// what it asks for counts too, since it can carry anything out.
    private static func curlSends(_ arguments: [String]) -> Bool {
        for (index, word) in arguments.enumerated() {
            let lower = word.lowercased()
            if lower.hasPrefix("--data") || lower.hasPrefix("--form") || lower.hasPrefix("--upload-file")
                || lower == "--json" {
                return true
            }
            if lower == "--request" || word == "-X" {
                let method = index + 1 < arguments.count ? arguments[index + 1] : ""
                if !isQuiet(method) { return true }
                continue
            }
            if lower.hasPrefix("--request=") {
                if !isQuiet(String(word.dropFirst(10))) { return true }
                continue
            }
            guard word.hasPrefix("-"), !word.hasPrefix("--"), word.count > 1 else { continue }
            if word.hasPrefix("-X") {
                if !isQuiet(String(word.dropFirst(2))) { return true }
                continue
            }
            // -d, -F and -T: alone, with their value attached, or among
            // flags written together.
            if word.hasPrefix("-d") || word.hasPrefix("-F") || word.hasPrefix("-T") { return true }
            let flags = word.dropFirst()
            if flags.allSatisfy({ $0.isLetter }), flags.contains(where: { $0 == "d" || $0 == "F" || $0 == "T" }) {
                return true
            }
        }
        return arguments.contains(where: { $0.contains("$") })
    }

    private static func wgetSends(_ arguments: [String]) -> Bool {
        arguments.contains(where: { word in
            let lower = word.lowercased()
            return lower.hasPrefix("--post") || lower.hasPrefix("--body") || lower.hasPrefix("--method")
                || word.contains("$")
        })
    }

    // MARK: Removing

    /// Removing a folder and all in it is the person's to answer, unless
    /// every folder named is one that can be made again (`remade`), lies
    /// inside one, or is in a place for throwaway files.
    private static func removal(_ arguments: [String], in place: Place) -> Reserved? {
        var recursive = false
        var targets: [String] = []
        var flagsOver = false
        for word in arguments {
            if !flagsOver, word == "--" {
                flagsOver = true
                continue
            }
            if !flagsOver, word.hasPrefix("-"), word.count > 1 {
                if word == "--recursive" || (!word.hasPrefix("--") && word.lowercased().contains("r")) {
                    recursive = true
                }
                continue
            }
            targets.append(word)
        }
        guard recursive else { return nil }
        // Handed its targets by another program: not known.
        if targets.isEmpty { return .removes }
        for target in targets {
            // What a variable stands for is not known until it runs.
            if target.contains("$") { return .removes }
            // The folders on the way to it, from where the command runs.
            var steps = target.split(separator: "/").map { $0.lowercased() }
            if let path = full(target, in: place) {
                // Named in full: among throwaway files it may go; in the
                // project it is judged by where in the project it is;
                // anywhere else it is the person's.
                if isScratch(path) {
                    if scratchRoots.contains(path) { return .removes }
                    continue
                }
                guard inside(path, place.project), path != place.project else { return .removes }
                steps = path.dropFirst(place.project.count).split(separator: "/").map { $0.lowercased() }
            }
            if steps.contains("..") || !steps.contains(where: { remade.contains($0) }) { return .removes }
        }
        return nil
    }

    // MARK: Paths

    /// A folder's path tidied, or "" when there is none.
    private static func folder(_ path: String) -> String {
        path.isEmpty ? "" : tidy(path)
    }

    /// A full path with its "." and ".." steps worked out, as text:
    /// nothing is looked up on disk.
    static func tidy(_ path: String) -> String {
        var kept: [Substring] = []
        for step in path.split(separator: "/", omittingEmptySubsequences: true) {
            if step == "." { continue }
            if step == ".." {
                if !kept.isEmpty { kept.removeLast() }
                continue
            }
            kept.append(step)
        }
        return "/" + kept.joined(separator: "/")
    }

    private static func inside(_ path: String, _ folder: String) -> Bool {
        // No folder, and the root of the disk, are no project's.
        guard !folder.isEmpty, folder != "/" else { return false }
        return path == folder || path.hasPrefix(folder + "/")
    }

    /// Where throwaway files are kept.
    private static let scratchRoots: Set<String> = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]

    /// Places for throwaway files, and the ones that swallow or show
    /// what is written to them.
    static func isScratch(_ path: String) -> Bool {
        if ["/dev/null", "/dev/stdout", "/dev/stderr", "/dev/stdin", "/dev/tty"].contains(path) { return true }
        return scratchRoots.contains { root in
            path == root || path.hasPrefix(root + "/")
        }
    }

    /// A word of a command as a full path, when it is written as one
    /// that can leave where the command runs: from the root, from home,
    /// from a folder a variable names, or climbing with "..". nil for
    /// any other word: a plain name stays where the command runs.
    private static func full(_ text: String, in place: Place) -> String? {
        if text.hasPrefix("/") { return tidy(text) }
        if text == "~" || text.hasPrefix("~/") { return tidy(place.home + "/" + String(text.dropFirst())) }
        // Another person's home.
        if text.hasPrefix("~") { return "/~" }
        for (name, known) in [("HOME", place.home), ("PWD", place.directory), ("TMPDIR", "/tmp")] {
            for form in ["$" + name, "${" + name + "}"] {
                if text == form { return known }
                if text.hasPrefix(form + "/") { return tidy(known + String(text.dropFirst(form.count))) }
            }
        }
        // A folder only a variable knows.
        if text.hasPrefix("$"), text.contains("/") { return "/$" }
        if text == ".." || text.hasPrefix("../") || text.contains("/../") || text.hasSuffix("/..") {
            return tidy(place.directory + "/" + text)
        }
        return nil
    }

    /// Whether a command writes its output somewhere that matters.
    private static func writesOutput(_ command: String) -> Bool {
        var text = command
        for harmless in ["2>&1", "1>&2", ">&2", "2> /dev/null", "2>/dev/null", "&> /dev/null", "&>/dev/null",
                         "> /dev/null", ">/dev/null"] {
            text = text.replacingOccurrences(of: harmless, with: " ")
        }
        return text.contains(">")
    }

    /// Where a command that does more than look reaches, when that makes
    /// it the person's: it starts outside the project or names a place
    /// outside it, or it names one of git's own files. The program of
    /// each part is judged by its name, wherever it is kept.
    private static func reach(of pieces: [Part], in place: Place) -> Reserved? {
        if !inside(place.directory, place.project) && !isScratch(place.directory) { return .outside }
        let gitFiles = place.project + "/.git"
        for piece in pieces {
            var words = Self.words(of: piece.text)[...]
            while let first = words.first, isSetting(first) { words = words.dropFirst() }
            for word in words.dropFirst() {
                for fragment in word.split(whereSeparator: { "=<>(),".contains($0) }) {
                    let text = String(fragment)
                    if let path = full(text, in: place) {
                        if isScratch(path) { continue }
                        if !inside(path, place.project) { return .outside }
                        if inside(path, gitFiles) { return .repository }
                    } else if !text.hasPrefix("-"), inside(tidy(place.directory + "/" + text), gitFiles) {
                        return .repository
                    }
                }
            }
        }
        return nil
    }

    // MARK: Reading a command

    /// One part of a command line: what stands between "&&", "||", ";",
    /// "|", "&" and new lines.
    struct Part: Equatable {
        /// What joined it to the part before: "|" for a pipe, "" for the
        /// first part.
        var joint: String
        var text: String
    }

    /// A program a part runs, with the words after it.
    struct Call: Equatable {
        /// The program's name in lower case, without the path to it.
        var program: String
        var arguments: [String]
    }

    /// A command line as it is read here.
    struct Script: Equatable {
        /// Its parts, in order.
        var parts: [Part] = []
        /// The command without the text it feeds to programs just as it
        /// stands (after "<<'END'"): what is left is what a shell reads
        /// and fills in.
        var live = ""
    }

    /// Text a command feeds to a program on the lines after it ("<<").
    private struct Feed {
        /// The word that ends the text.
        var end: String
        /// The shell fills the text in before handing it on: its end
        /// word was written without quotes.
        var filled: Bool
        /// It is fed to a shell, which runs it.
        var run: Bool
    }

    /// Words that run the program after them.
    private static let wrappers: Set<String> = [
        "env", "time", "nohup", "nice", "command", "exec", "xargs", "builtin", "caffeinate", "arch", "stdbuf",
        "timeout", "gtimeout"
    ]

    /// Words of the shell's own that come before a program.
    private static let leading: Set<String> = ["do", "then", "else", "elif", "if", "while", "until", "!", "{"]

    /// Parts that are the shell's own and run nothing.
    private static let idle: Set<String> = ["for", "case", "select", "function", "done", "fi", "esac", "}", "in"]

    /// Programs that run text fed to them as commands.
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]

    /// Reads a command line into its parts. Quotes keep what is inside
    /// them together, and a backslash the character after it. Text fed
    /// to a program on the lines that follow ("<<END") is not commands,
    /// unless it is fed to a shell: then each line is read as one.
    static func read(_ command: String) -> Script {
        var script = Script()
        var text = ""
        var joint = ""
        var quote: Character?
        var escaped = false
        // The texts still to come on the lines after this one.
        var feeds: [Feed] = []
        let characters = Array(command)
        let none: Character = " "
        var index = 0
        while index < characters.count {
            let character = characters[index]
            index += 1
            script.live.append(character)
            if escaped {
                text.append(character)
                escaped = false
                continue
            }
            if let opened = quote {
                if character == opened {
                    quote = nil
                } else if character == "\\", opened == "\"" {
                    escaped = true
                }
                text.append(character)
                continue
            }
            if character == "\\" {
                escaped = true
                text.append(character)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                text.append(character)
                continue
            }
            let next = index < characters.count ? characters[index] : none
            let before = index >= 2 ? characters[index - 2] : none
            if character == "<", next == "<" {
                let third = index + 1 < characters.count ? characters[index + 1] : none
                if third == "<" {
                    // "<<<" hands a word over, not lines.
                    text.append("<<<")
                    script.live.append("<<")
                    index += 2
                    continue
                }
                // The word that ends the text, after "<<" or "<<-".
                var at = index + 1
                if at < characters.count, characters[at] == "-" { at += 1 }
                while at < characters.count, characters[at] == " " || characters[at] == "\t" { at += 1 }
                var end = ""
                var quoted = false
                while at < characters.count, !" \t\n;|&<>()".contains(characters[at]) {
                    let piece = characters[at]
                    if piece == "'" || piece == "\"" || piece == "\\" {
                        quoted = true
                    } else {
                        end.append(piece)
                    }
                    at += 1
                }
                script.live.append(contentsOf: String(characters[index..<at]))
                index = at
                text.append("<<")
                if !end.isEmpty {
                    let run = Self.calls(in: text).contains(where: { shells.contains($0.program) })
                    feeds.append(Feed(end: end, filled: !quoted, run: run))
                }
                continue
            }
            var found = ""
            if character == "&", next == "&" {
                found = "&&"
            } else if character == "|", next == "|" {
                found = "||"
            } else if character == "|", next == "&" {
                // Both what it prints and what it complains of go down the pipe.
                found = "|&"
            } else if character == "|" {
                found = "|"
            } else if character == ";" || character == "\n" {
                found = ";"
            } else if character == "&", before != ">", before != "<", next != ">" {
                // Left running while the rest goes on. Not the "&" of "2>&1".
                found = "&"
            }
            if found.isEmpty {
                text.append(character)
                continue
            }
            if found.count == 2 {
                script.live.append(characters[index])
                index += 1
            }
            script.parts.append(Part(joint: joint, text: text.trimmingCharacters(in: .whitespaces)))
            text = ""
            joint = found == "|&" ? "|" : found
            guard character == "\n" else { continue }
            // The lines after this one are the texts it feeds, each up to
            // the word that ends it.
            while !feeds.isEmpty, index < characters.count {
                var line = ""
                while index < characters.count, characters[index] != "\n" {
                    line.append(characters[index])
                    index += 1
                }
                if index < characters.count { index += 1 }
                if line.trimmingCharacters(in: .whitespaces) == feeds[0].end {
                    feeds.removeFirst()
                    continue
                }
                // What a shell fills in or runs is read like the rest.
                if feeds[0].filled || feeds[0].run { script.live.append(line + "\n") }
                if feeds[0].run { script.parts.append(contentsOf: read(line).parts) }
            }
        }
        script.parts.append(Part(joint: joint, text: text.trimmingCharacters(in: .whitespaces)))
        script.parts = script.parts.filter { !$0.text.isEmpty }
        return script
    }

    /// The words of a part: split at spaces outside quotes, with the
    /// quotes and backslashes taken off, as the shell would hand them on.
    static func words(of text: String) -> [String] {
        var words: [String] = []
        var word = ""
        var begun = false
        var quote: Character?
        var escaped = false
        for character in text {
            if escaped {
                word.append(character)
                escaped = false
                continue
            }
            if let opened = quote {
                if character == opened {
                    quote = nil
                } else if character == "\\", opened == "\"" {
                    escaped = true
                } else {
                    word.append(character)
                }
                continue
            }
            if character == "\\" {
                escaped = true
                begun = true
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                begun = true
                continue
            }
            if character == " " || character == "\t" {
                if begun { words.append(word) }
                word = ""
                begun = false
                continue
            }
            word.append(character)
            begun = true
        }
        if begun { words.append(word) }
        return words
    }

    /// "NAME=value" before a program: a setting for it, not a program.
    private static func isSetting(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// A program's name in lower case, without the path to it: this
    /// Mac's disk does not tell "SUDO" from "sudo".
    private static func programName(_ word: String) -> String {
        let name = word.split(separator: "/").last.map(String.init) ?? word
        return name.lowercased()
    }

    /// What a part runs: one program as a rule, none for the shell's own
    /// words. After a word that runs another program ("env", "xargs",
    /// "time"), where that word's own options end cannot be told for
    /// sure, so every word after it is taken as possibly the program.
    static func calls(in text: String) -> [Call] {
        var words = Self.words(of: text)[...]
        while let first = words.first, isSetting(first) || leading.contains(first) {
            words = words.dropFirst()
        }
        guard let first = words.first else { return [] }
        let name = programName(first)
        if idle.contains(name) { return [] }
        guard wrappers.contains(name) else {
            return [Call(program: name, arguments: Array(words.dropFirst()))]
        }
        var found: [Call] = []
        var rest = words.dropFirst()
        while let word = rest.first {
            rest = rest.dropFirst()
            if word.hasPrefix("-") || isSetting(word) { continue }
            found.append(Call(program: programName(word), arguments: Array(rest)))
        }
        return found
    }
}
