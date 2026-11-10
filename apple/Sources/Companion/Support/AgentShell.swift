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

/// Runs shell commands for the agent, one at a time, in the user's login
/// shell so their PATH and tools are available.
actor AgentShell {
    static let shared = AgentShell()

    private var process: Process?
    private static let marker = "__COMPANION_CWD__"
    /// How much of a command's output is kept (the end of it).
    private static let outputLimit = 6_000

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
        do {
            try process.run()
        } catch {
            return ShellResult(output: "Could not start the command: \(error.localizedDescription)",
                               exitCode: -1, timedOut: false, directory: folder)
        }
        self.process = process

        let reading = pipe.fileHandleForReading
        let reader = Task.detached { reading.readDataToEndOfFile() }
        let limit = Task.detached { () -> Bool in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, process.isRunning else { return false }
            process.terminate()
            // A child that outlives the shell would keep the pipe open.
            try? reading.close()
            return true
        }
        let data = await reader.value
        process.waitUntilExit()
        limit.cancel()
        let timedOut = await limit.value
        self.process = nil

        var text = String(decoding: data, as: UTF8.self)
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
                           timedOut: timedOut,
                           directory: ended.isEmpty ? folder : ended)
    }

    /// Stops the command that is running, if any.
    func cancel() {
        process?.terminate()
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
enum AgentPermissions {
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
