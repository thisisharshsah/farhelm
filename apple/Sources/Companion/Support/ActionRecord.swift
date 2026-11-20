import Foundation

/// A permanent record of what the agent did on this Mac: Orbit's
/// append-only history, carried into Companion.
///
/// One JSON object per line, in Application Support/Companion/Actions/
/// <year>-<month>.jsonl. A step writes a "start" line when it begins and an
/// "end" line when it settles, so a step that was cut off still shows; a
/// step the user turned down writes one "declined" line. Lines are only
/// ever added: Companion never rewrites, trims or deletes these files.
///
/// Nothing secret is written. Typed text longer than a few words is kept as
/// its length, text for a password field never, and commands, addresses and
/// searches are scrubbed of keys, tokens and passwords first.
final class ActionRecord {
    static let shared = ActionRecord()

    /// How a step settled.
    enum Outcome: String {
        /// It went through.
        case done
        /// It was tried and did not take effect.
        case failed
        /// It was stopped before it reached the Mac, by the focus check or a rule.
        case refused
        /// The user stopped it: Escape, or stopping the task.
        case interrupted
    }

    /// Which steps are actions worth a line: all but waiting, planning,
    /// finishing and asking.
    static func records(_ kind: ActionStep.Kind) -> Bool {
        switch kind {
        case .wait, .plan, .done, .ask: return false
        default: return true
        }
    }

    /// Application Support/Companion/Actions.
    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Companion/Actions", isDirectory: true)

    private let queue = DispatchQueue(label: "Companion.ActionRecord")
    /// This run of Companion, so its lines can be told from another's.
    private let run = UUID().uuidString
    private var written = 0

    /// A step is starting. `approval` says who let it run.
    func begin(_ step: ActionStep, task: UUID, chat: UUID, approval: String, app: String, passwordField: Bool) {
        write([
            "event": "start", "step": step.id.uuidString, "task": task.uuidString, "chat": chat.uuidString,
            "kind": "\(step.kind)", "what": Self.describe(step, passwordField: passwordField),
            "app": app, "approval": approval
        ])
    }

    /// A step settled.
    func end(_ step: ActionStep, _ outcome: Outcome, why: String? = nil) {
        var line: [String: Any] = ["event": "end", "step": step.id.uuidString, "outcome": outcome.rawValue]
        if let why { line["why"] = Self.scrub(Self.clip(why, 300)) }
        write(line)
    }

    /// Steps that were said no to: nothing ran. `by` says who said it:
    /// the user, or the project's supervisor in their place.
    func declined(_ steps: [ActionStep], task: UUID, chat: UUID, by: String = "you") {
        for step in steps where Self.records(step.kind) {
            write([
                "event": "declined", "step": step.id.uuidString, "task": task.uuidString, "chat": chat.uuidString,
                "kind": "\(step.kind)", "what": Self.describe(step, passwordField: false), "by": by
            ])
        }
    }

    // MARK: - Writing

    private func write(_ fields: [String: Any]) {
        let at = Date()
        queue.async { [self] in
            written += 1
            var line = fields
            line["v"] = 1
            line["run"] = run
            line["seq"] = written
            line["at"] = Self.stamp.string(from: at)
            guard JSONSerialization.isValidJSONObject(line),
                  var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return }
            data.append(0x0A)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let path = folder.appendingPathComponent(Self.month.string(from: at) + ".jsonl").path
            // Opened for appending only: a line can be added, never changed.
            let file = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
            guard file >= 0 else { return }
            defer { Darwin.close(file) }
            data.withUnsafeBytes { buffer in
                _ = Darwin.write(file, buffer.baseAddress, buffer.count)
            }
        }
    }

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let month: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    // MARK: - Saying what a step did, with nothing secret in it

    static func describe(_ step: ActionStep, passwordField: Bool) -> String {
        switch step.kind {
        case .type:
            let count = step.value.count
            if passwordField { return "Type \(count) characters into a password field" }
            // Never the whole of a long text: forms ask for card numbers,
            // codes and keys, and the length is enough to recognize it.
            return count <= 24 ? "Type \u{201C}\(scrub(step.value))\u{201D}" : "Type \(count) characters"
        case .key: return "Press \(clip(step.value, 60))"
        case .click: return "Click \(clip(step.value, 120))"
        case .open: return "Open \(clip(step.value, 120))"
        case .run: return "Run `\(scrub(clip(step.value, 300)))`"
        case .terminal: return "Open a terminal running `\(scrub(clip(step.value, 300)))`"
        case .write: return "Write \(clip(step.value, 300))"
        case .edit: return "Edit \(clip(step.value, 300))"
        case .read: return "Read \(clip(step.value, 300))"
        case .search: return "Search files for \(scrub(clip(step.value, 200)))"
        case .fetch: return "Fetch \(scrub(clip(step.value, 300)))"
        case .web: return "Search the web for \(scrub(clip(step.value, 200)))"
        case .delegate: return "Ask a helper: \(scrub(clip(step.value, 200)))"
        case .browser:
            // What is typed into a page is kept as its length only.
            if let made = step.browserCommand, made.command == "type" {
                let text = made.args["text"] as? String ?? ""
                return "In the browser: type \(text.count) characters into [\(made.args["target"] ?? "?")]"
            }
            return "In the browser: \(scrub(clip(step.value, 300)))"
        case .wait, .plan, .done, .ask:
            return clip(step.label, 200)
        }
    }

    /// One line, at most `limit` characters.
    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "\u{2026}"
    }

    /// Keys, tokens and passwords in a piece of text, replaced: provider key
    /// prefixes, "password=...", bearer tokens, secret query parameters.
    static func scrub(_ text: String) -> String {
        var out = text
        for (pattern, template) in scrubbers {
            out = pattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    private static let scrubbers: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            (#"sk-ant-[A-Za-z0-9_\-]{8,}"#, "sk-ant-[hidden]"),
            (#"\bsk-[A-Za-z0-9_\-]{16,}"#, "sk-[hidden]"),
            (#"\bfhk_[A-Za-z0-9_\-]{8,}"#, "fhk_[hidden]"),
            (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, "gh_[hidden]"),
            (#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, "github_pat_[hidden]"),
            (#"\bAKIA[0-9A-Z]{16}\b"#, "AKIA[hidden]"),
            (#"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#, "xox-[hidden]"),
            (#"\bAIza[0-9A-Za-z_\-]{30,}"#, "AIza[hidden]"),
            (#"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=\-]{12,}"#, "$1 [hidden]"),
            (#"(?i)([?&](?:token|access_token|api_key|apikey|key|secret|password|sig|signature|auth|code)=)[^&\s#]+"#, "$1[hidden]"),
            (#"(?i)\b(password|passwd|pwd|passphrase|secret|token|api[_-]?key|access[_-]?key|client[_-]?secret)(\s*[=:]\s*)(?!\[hidden\])("[^"]*"|'[^']*'|[^\s&]+)"#, "$1$2[hidden]")
        ]
        return patterns.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()
}
