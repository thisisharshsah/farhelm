import Foundation

/// What a shell command the agent ran came back with.
struct ShellResult {
    let output: String
    let exitCode: Int32
    let timedOut: Bool
    /// The folder the shell was in when the command ended, so `cd` carries
    /// over to the next command.
    let directory: String
}

/// Collects a command's output as it arrives, from the reading thread.
private final class OutputBox: @unchecked Sendable {
    private var data = Data()
    private var failure: String?
    private var expired = false
    private let lock = NSLock()

    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    func fail(_ message: String) { lock.withLock { failure = message } }
    func expire() { lock.withLock { expired = true } }
    var collected: Data { lock.withLock { data } }
    var startFailure: String? { lock.withLock { failure } }
    var timedOut: Bool { lock.withLock { expired } }
}

/// Runs shell commands for the agent, one at a time, in the user's login
/// shell so their PATH and tools are available.
actor AgentShell {
    static let shared = AgentShell()

    private var process: Process?
    private static let marker = "__COMPANION_CWD__"
    /// How much of a command's output is kept (the end of it).
    private static let outputLimit = 6_000

    /// Runs a command and returns when the shell exits or the time is up,
    /// whichever comes first. It never waits on the output pipe itself, so
    /// a command that leaves something running in the background (which
    /// keeps the pipe open) cannot hang the agent.
    func run(_ command: String, in directory: String, timeout: TimeInterval = 120) async -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // After the command, report the folder it ended in and keep its exit code.
        let script = "\(command)\n__companion_status=$?\nprintf '\\n\(Self.marker)%s\\n' \"$PWD\"\nexit $__companion_status"
        process.arguments = ["-lc", script]
        let folder = FileManager.default.fileExists(atPath: directory) ? directory : NSHomeDirectory()
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // No terminal: a command that waits for input gets end-of-file instead of hanging.
        process.standardInput = FileHandle.nullDevice

        let box = OutputBox()
        let reading = pipe.fileHandleForReading
        reading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                box.append(chunk)
            }
        }
        self.process = process
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in finished.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                box.fail(error.localizedDescription)
                finished.resume()
                return
            }
            // The time limit: end the shell, which lets the wait above return.
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if process.isRunning {
                    box.expire()
                    process.terminate()
                }
            }
        }
        self.process = nil
        if let failure = box.startFailure {
            reading.readabilityHandler = nil
            return ShellResult(output: "Could not start the command: \(failure)",
                               exitCode: -1, timedOut: false, directory: folder)
        }
        // A moment for the last of the output to arrive, then stop listening.
        try? await Task.sleep(nanoseconds: 150_000_000)
        reading.readabilityHandler = nil

        var text = String(decoding: box.collected, as: UTF8.self)
        var ended = folder
        if let range = text.range(of: Self.marker, options: .backwards) {
            let after = text[range.upperBound...]
            ended = String(after.prefix { $0 != "\n" })
            text = String(text[..<range.lowerBound])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > Self.outputLimit {
            text = "[earlier output left out]\n" + String(text.suffix(Self.outputLimit))
        }
        return ShellResult(output: text,
                           exitCode: process.terminationStatus,
                           timedOut: box.timedOut,
                           directory: ended.isEmpty ? folder : ended)
    }

    /// Stops the command that is running, if any.
    func cancel() {
        if let process, process.isRunning {
            process.terminate()
        }
    }
}

/// Decides which shell commands may run without asking.
///
/// The model is the same one as in coding agents: commands that only read
/// may run on their own (when the user has that setting on), everything
/// else needs the user's yes, and "always allow" remembers a program (or a
/// program and its subcommand, such as "git commit") so it is not asked
/// about again. A command that redirects output or runs a subshell is never
/// judged safe automatically.
/// How much the agent does without asking first. Manual asks before
/// anything that changes something. The two automatic modes differ in how
/// far they reach: edits keeps to the chat's repository, full access asks
/// about nothing. Keys and credentials are asked about in every mode.
enum AgentAccess: String, CaseIterable, Identifiable {
    case manual, autoEdit, full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return "Manual"
        case .autoEdit: return "Auto: edits"
        case .full: return "Auto: full access"
        }
    }

    /// A word for the button in the chat box.
    var short: String {
        switch self {
        case .manual: return "Manual"
        case .autoEdit: return "Auto"
        case .full: return "Full"
        }
    }

    var icon: String {
        switch self {
        case .manual: return "hand.raised.fill"
        case .autoEdit: return "pencil.and.outline"
        case .full: return "bolt.shield.fill"
        }
    }

    var detail: String {
        switch self {
        case .manual:
            return "Asks before anything that changes something: commands, file edits, typing into apps."
        case .autoEdit:
            return "Edits files and runs commands inside the chat's repository without asking. Still asks for anything outside it, installs and network tools, deleting folders, and control of other apps."
        case .full:
            return "Asks about nothing: commands anywhere, file edits, and control of other apps all run on their own. Only keys and credentials are still asked about."
        }
    }
}

enum AgentPermissions {
    /// Programs that reach outside the repository whatever they are given:
    /// the network, other apps, the system.
    private static let outward: Set<String> = [
        "sudo", "curl", "wget", "ssh", "scp", "sftp", "rsync", "nc", "telnet", "ftp", "brew", "open", "osascript",
        "killall", "pkill", "shutdown", "reboot", "diskutil", "launchctl", "defaults", "chown", "dd", "security"
    ]
    /// The same for programs where it is the subcommand that reaches out.
    private static let outwardPhrases = [
        "git push", "git remote", "npm publish", "npm install", "npm i ", "pnpm add", "pnpm install", "yarn add",
        "yarn install", "pip install", "pip3 install", "gem install", "cargo install", "go install", "docker ", "kubectl "
    ]

    private static func inside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// Whether a command names keys or credentials. Asked about in every
    /// mode, full access included.
    static func touchesSecrets(_ command: String) -> Bool {
        let lower = command.lowercased()
        return AgentTools.isSensitive(lower)
            || [".env", "keychain", "security find-", "security dump-", ".pem", "credentials"].contains { lower.contains($0) }
    }

    /// For the mode that edits on its own: whether a command keeps to the
    /// repository. It must start inside it, name no path outside it, run
    /// nothing that reaches the network, other apps or the system, and
    /// delete no folders. Anything that cannot be judged counts as leaving.
    static func staysInside(_ command: String, repository: String, directory: String) -> Bool {
        guard !repository.isEmpty, inside(directory, repository) else { return false }
        guard !command.contains("`"), !command.contains("$("), !command.contains("..") else { return false }
        let lower = command.lowercased()
        guard !outwardPhrases.contains(where: { lower.contains($0) }) else { return false }
        var parts = [command]
        for separator in ["&&", "||", ";", "|", "\n"] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        for piece in parts.map({ $0.trimmingCharacters(in: .whitespaces) }) where !piece.isEmpty {
            guard let program = name(of: piece)?.split(separator: " ").first.map(String.init) else { return false }
            if outward.contains((program as NSString).lastPathComponent) { return false }
            // Removing a folder and all in it is asked about.
            if program == "rm" {
                let flags = piece.split(separator: " ").filter { $0.hasPrefix("-") }
                if flags.contains(where: { $0.contains("r") || $0.contains("R") }) { return false }
            }
        }
        // Every path that is spelled out in full must be in the repository.
        let breaks = CharacterSet(charactersIn: " \t\n;|&()<>=\"'")
        for token in command.components(separatedBy: breaks) {
            if token.hasPrefix("$HOME") || token.hasPrefix("${HOME}") { return false }
            guard token.hasPrefix("/") || token.hasPrefix("~") else { continue }
            if token == "/dev/null" { continue }
            let path = ((token as NSString).expandingTildeInPath as NSString).standardizingPath
            if !inside(path, repository) { return false }
        }
        return true
    }

    /// Programs that only look at things.
    static let readOnly: Set<String> = [
        "ls", "pwd", "cd", "cat", "head", "tail", "grep", "rg", "wc", "which", "date", "whoami", "echo",
        "file", "stat", "du", "df", "tree", "sw_vers", "uname", "mdls", "mdfind", "defaults read", "pgrep", "ps",
        "git status", "git diff", "git log", "git branch", "git show", "git remote"
    ]

    /// Programs whose first argument decides what they do.
    private static let withSubcommands: Set<String> = [
        "git", "npm", "yarn", "pnpm", "docker", "brew", "cargo", "swift", "kubectl", "gh", "pip", "pip3",
        "make", "go", "python", "python3", "node", "defaults"
    ]

    /// Words that mean an AppleScript changes something or drives the UI.
    private static let scriptWrites = [
        "set ", "delete", "keystroke", "key code", "click", "do shell script", "do script", "make ", "close",
        "quit", "activate", "move ", "duplicate", "save", "open ", "run ", "launch", "write", "empty", "eject",
        "restart", "shut down", "sleep", "log out", "say "
    ]

    /// The parts of a command line joined by "&&", "|", ";" and the like.
    /// nil when the line does something that cannot be judged part by part
    /// (redirection, subshells).
    static func pieces(of command: String) -> [String]? {
        for risky in [">", "<", "`", "$("] where command.contains(risky) {
            return nil
        }
        var parts = [command]
        for separator in ["&&", "||", ";", "|", "\n"] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        let trimmed = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The program a piece runs: "ls", or "git commit" for programs whose
    /// subcommand matters.
    static func name(of piece: String) -> String? {
        // Skip leading VAR=value settings.
        let words = piece.split(separator: " ").map(String.init).drop { $0.contains("=") && !$0.hasPrefix("-") }
        guard let program = words.first else { return nil }
        if withSubcommands.contains(program), let sub = words.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            return "\(program) \(sub)"
        }
        return program
    }

    /// Whether a piece only reads: a listed program, an AppleScript that
    /// only asks for information, or a screenshot saved to a temporary folder.
    static func isReadOnly(_ piece: String) -> Bool {
        guard let program = name(of: piece) else { return false }
        if readOnly.contains(program) { return true }
        let lower = piece.lowercased()
        switch program {
        case "osascript":
            return lower.contains(" -e ") && !scriptWrites.contains { lower.contains($0) }
        case "screencapture":
            guard let target = piece.split(separator: " ").last.map(String.init) else { return false }
            return target.hasPrefix("/tmp/") || target.hasPrefix("/private/tmp/") || target.hasPrefix("$TMPDIR")
        default:
            return false
        }
    }

    /// Whether a command may run without asking: every piece is either
    /// something the user said to always allow, or read-only while reads
    /// are set to run on their own.
    static func isAllowed(_ command: String, remembered: [String], autoApproveReads: Bool) -> Bool {
        guard let parts = pieces(of: command) else { return false }
        return parts.allSatisfy { piece in
            if let program = name(of: piece), remembered.contains(program) { return true }
            return autoApproveReads && isReadOnly(piece)
        }
    }

    /// What "always allow" would add for this command; empty when the
    /// command cannot be remembered safely.
    static func toRemember(_ command: String, remembered: [String], autoApproveReads: Bool) -> [String] {
        guard let parts = pieces(of: command) else { return [] }
        var names: [String] = []
        for piece in parts {
            guard let program = name(of: piece), !remembered.contains(program), !names.contains(program) else { continue }
            if autoApproveReads && isReadOnly(piece) { continue }
            names.append(program)
        }
        return names
    }
}
