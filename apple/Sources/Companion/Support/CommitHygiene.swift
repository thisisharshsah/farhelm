import Foundation

/// Commits are the user's own: no co-author lines and no AI attribution
/// for any model or tool, and always the user's git name. Every commit
/// Companion makes, and every commit the agent makes, goes through here.
enum CommitHygiene {
    /// Lines that credit a model or a tool rather than the user.
    private static let attribution: [NSRegularExpression] = [
        #"^\s*co-authored-by:.*$"#,
        #"^\s*(claude|codex|chatgpt|openai|anthropic|gemini|copilot|cursor)[-\s]session:.*$"#,
        #"^.*generated (with|by) .*(claude|codex|chatgpt|openai|anthropic|gemini|copilot|cursor|ai\b).*$"#,
        #"^\s*🤖.*$"#,
        #"^\s*signed-off-by:.*(claude|codex|chatgpt|openai|anthropic|gemini|copilot|cursor|noreply@).*$"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive, .anchorsMatchLines]) }

    /// Names that mark an author as a model or tool, not the user.
    private static let machineNames = ["claude", "codex", "chatgpt", "openai", "anthropic", "gemini", "copilot",
                                       "cursor", "companion", "noreply@anthropic", "noreply@openai"]

    /// The message with every attribution line taken out, and the blank
    /// lines they leave at the end trimmed.
    static func clean(_ message: String) -> String {
        var text = message
        for pattern in attribution {
            let range = NSRange(text.startIndex..., in: text)
            text = pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }
        // Lines the removal left empty, run together, and the end trimmed.
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A commit subject from what the agent reported: its first sentence,
    /// plain, at most 72 characters. The fallback when there is none.
    static func subject(from answer: String, fallback: String) -> String {
        let first = answer
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        var line = first
        for symbol in ["**", "__", "`", "#"] { line = line.replacingOccurrences(of: symbol, with: "") }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "-* ").union(.whitespaces))
        if let stop = line.range(of: ". ") { line = String(line[..<stop.lowerBound]) }
        if line.hasSuffix(".") { line.removeLast() }
        if line.isEmpty { line = fallback.components(separatedBy: .newlines).first ?? fallback }
        if line.count > 72 { line = String(line.prefix(71)) + "…" }
        return line
    }

    private static func isMachine(_ identity: String) -> Bool {
        let lower = identity.lowercased()
        return machineNames.contains { lower.contains($0) }
    }

    /// Looks at the commit just made in a folder. If it credits a model or
    /// tool, in its message or as its author, and it has not been pushed,
    /// it is made again without that, under the user's git name (the
    /// repository's hooks still run). Returns what was done, or nil when
    /// there was nothing to do.
    static func fixLastCommit(in directory: String) async -> String? {
        let probe = await Shell.run("git rev-parse --is-inside-work-tree && git log -1 --format=%H", in: directory, timeout: 10)
        guard probe.ok else { return nil }
        let message = await Shell.run("git log -1 --format=%B", in: directory, timeout: 10).output
        let author = await Shell.run("git log -1 --format='%an <%ae>|%cn <%ce>'", in: directory, timeout: 10).output
        let cleaned = clean(message)
        let messageNeedsIt = cleaned != message.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorNeedsIt = isMachine(author)
        guard messageNeedsIt || authorNeedsIt else { return nil }

        // Already on a remote: rewriting it would need a force push, which
        // Companion never does. Say so instead.
        let pushed = await Shell.run("git branch -r --contains HEAD", in: directory, timeout: 10)
        if !pushed.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The last commit credits an AI, but it is already pushed, so it was left as it is."
        }

        let file = NSTemporaryDirectory() + "companion-commit-\(UUID().uuidString).txt"
        guard (try? cleaned.write(toFile: file, atomically: true, encoding: .utf8)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(atPath: file) }
        let amend = "git commit --amend -q --allow-empty -F \(Shell.quote(file))" + (authorNeedsIt ? " --reset-author" : "")
        let result = await Shell.run(amend, in: directory, timeout: 60)
        guard result.ok else { return "Could not take the AI credit out of the last commit: \(result.output.suffix(200))" }
        return "Took the AI credit out of the last commit; it is under your git name."
    }
}
