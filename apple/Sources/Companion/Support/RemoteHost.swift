import Foundation

/// Commands on a server or cluster the user reaches over ssh, run by the
/// agent through the connection the user signed in to once (a terminal
/// beside the chat holds it open, `AppState.openTerminalBeside`). Plain
/// commands with their real output: far steadier than typing into a web
/// terminal, whose keys can go astray and whose screen can go stale.
enum RemoteHost {
    /// Where the shared connection lives, as `openTerminalBeside` opens it.
    static let controlPath = "~/.ssh/companion-%C"
    /// The start of every command built here, to know one again.
    static let prefix = "ssh -o ControlPath=\(controlPath) -o ControlMaster=no -o BatchMode=yes -o ConnectTimeout=20 "

    /// A host as ssh takes it: "user@host", with "-J user@jump" or "-p 22"
    /// before it if needed. Nothing that a shell would read as more than
    /// that (no ; | & $ ` quotes or new lines).
    static func valid(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return false }
        return trimmed.range(of: #"^[A-Za-z0-9@._:\- ]+$"#, options: .regularExpression) != nil
    }

    /// The command that runs `command` on `host` through the shared
    /// connection, in a login shell (so modules, conda and Slurm are on the
    /// path as when the user signs in).
    static func command(host: String, run command: String) -> String? {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard valid(host), !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return prefix + host + " " + quote("bash -lc " + quote(command))
    }

    /// The host a command built here runs on.
    static func host(of command: String) -> String? {
        guard command.hasPrefix(prefix) else { return nil }
        let rest = command.dropFirst(prefix.count)
        guard let quoteStart = rest.firstIndex(of: "'") else { return nil }
        let host = rest[..<quoteStart].trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? nil : host
    }

    /// The command as the person reads it: "on user@host: squeue -u me".
    static func shown(_ command: String) -> String? {
        guard let host = host(of: command),
              let first = command.range(of: "bash -lc ") else { return nil }
        var inner = String(command[first.upperBound...])
        // Undo the two layers of quoting, for reading only.
        inner = inner.replacingOccurrences(of: "'\\''", with: "'")
        inner = inner.trimmingCharacters(in: CharacterSet(charactersIn: "'\\ "))
        return "on \(host): \(inner)"
    }

    /// The output says the shared connection is not there (never signed
    /// in, or it timed out) rather than that the command failed.
    static func needsSignIn(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("control socket connect")
            || (text.contains("companion-") && text.contains("no such file or directory"))
            || text.contains("permission denied (")
            || text.contains("host key verification failed")
            || text.contains("connection closed by")
            || (text.contains("batchmode") && text.contains("password"))
    }

    /// The output says this Mac cannot reach the host at all (off the
    /// campus network or VPN, a wrong name), which no sign-in fixes.
    static func unreachable(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("network is unreachable")
            || text.contains("could not resolve hostname")
            || text.contains("operation timed out")
            || text.contains("connection timed out")
            || text.contains("no route to host")
            || text.contains("connection refused")
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
