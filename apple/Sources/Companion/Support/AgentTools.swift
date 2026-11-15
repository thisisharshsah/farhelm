import Foundation

/// The agent's own tools for files and the web. Each returns what the model
/// is shown next round: the content it asked for, or a plain reason it
/// could not be had. They are separate from the shell so that a read is
/// only ever a read, and an edit can be shown to the user exactly as it
/// will be made.
enum AgentTools {
    struct Outcome {
        let ok: Bool
        /// What the model is shown.
        let text: String
    }

    /// The most text one result hands back to the model.
    static let limit = 12_000

    /// "~/x" and "x" (relative to the shell's folder) as a full path.
    static func resolve(_ path: String, in directory: String) -> String {
        var cleaned = path.trimmingCharacters(in: .whitespaces)
        if cleaned.count >= 2, let first = cleaned.first, first == cleaned.last, "\"'`".contains(first) {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        let expanded = (cleaned as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
        return ((directory as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }

    /// Places a read should always be asked about: keys and credentials.
    static func isSensitive(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return ["/.ssh", "/.aws", "/.gnupg", "/keychains", "/.env", "/.netrc", "/.config/gh", "id_rsa", "id_ed25519"]
            .contains { lowered.contains($0) }
    }

    // MARK: Files

    /// A file's text, with line numbers. "path:40-90" reads only those lines.
    static func read(_ spec: String, in directory: String) -> Outcome {
        var target = spec
        var range: ClosedRange<Int>?
        if let colon = spec.lastIndex(of: ":") {
            let tail = spec[spec.index(after: colon)...].split(separator: "-").compactMap { Int($0) }
            if tail.count == 2, tail[0] >= 1, tail[1] >= tail[0] {
                range = tail[0]...tail[1]
                target = String(spec[..<colon])
            }
        }
        let path = resolve(target, in: directory)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else {
            return Outcome(ok: false, text: "No file at \(path).")
        }
        if isFolder.boolValue {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
            return Outcome(ok: true, text: "\(path) is a folder containing:\n" + names.prefix(200).joined(separator: "\n"))
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            return Outcome(ok: false, text: "\(path) could not be read.")
        }
        guard !data.prefix(4096).contains(0), let text = String(data: data, encoding: .utf8) else {
            return Outcome(ok: false, text: "\(path) is not a text file (\(data.count) bytes).")
        }
        let lines = text.components(separatedBy: "\n")
        let first = max((range?.lowerBound ?? 1) - 1, 0)
        let last = min(range?.upperBound ?? lines.count, lines.count)
        guard first < last else {
            return Outcome(ok: false, text: "\(path) has \(lines.count) lines; that range is past the end.")
        }
        var shown = ""
        var reached = first
        for index in first..<last {
            let line = "\(index + 1)\t\(lines[index])\n"
            if shown.count + line.count > limit { break }
            shown += line
            reached = index + 1
        }
        let note = reached < last
            ? "\n(showing lines \(first + 1)-\(reached) of \(lines.count); read \(target):\(reached + 1)-\(min(reached + 300, lines.count)) for more)"
            : (range == nil ? "" : "\n(lines \(first + 1)-\(reached) of \(lines.count))")
        return Outcome(ok: true, text: shown + note)
    }

    /// Creates or replaces a file with the given text.
    static func write(_ target: String, content: String, in directory: String) -> Outcome {
        let path = resolve(target, in: directory)
        let folder = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return Outcome(ok: true, text: "Wrote \(content.components(separatedBy: "\n").count) lines to \(path).")
        } catch {
            return Outcome(ok: false, text: "Could not write \(path): \(error.localizedDescription)")
        }
    }

    /// Replaces one exact piece of a file's text. The piece has to be there
    /// exactly once, so an edit can never land in the wrong place.
    static func edit(_ target: String, old: String, new: String, in directory: String) -> Outcome {
        let path = resolve(target, in: directory)
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            return Outcome(ok: false, text: "\(path) could not be read as text.")
        }
        guard !old.isEmpty else {
            return Outcome(ok: false, text: "The text to replace is empty. Use WRITE to create a file.")
        }
        let count = text.components(separatedBy: old).count - 1
        guard count == 1 else {
            return Outcome(ok: false, text: count == 0
                ? "The text to replace was not found in \(path). READ the file and copy the lines exactly, including spaces."
                : "The text to replace appears \(count) times in \(path). Include more of the lines around it so it is unique.")
        }
        do {
            try text.replacingOccurrences(of: old, with: new).write(toFile: path, atomically: true, encoding: .utf8)
            return Outcome(ok: true, text: "Edited \(path): replaced \(old.components(separatedBy: "\n").count) lines with \(new.components(separatedBy: "\n").count).")
        } catch {
            return Outcome(ok: false, text: "Could not save \(path): \(error.localizedDescription)")
        }
    }

    /// The shell command behind SEARCH: "pattern" or "pattern in path".
    /// Text files only, the usual junk folders left out, 80 matches at most.
    static func searchCommand(_ spec: String) -> String {
        var pattern = spec
        var place = "."
        if let split = spec.range(of: " in ", options: .backwards) {
            pattern = String(spec[..<split.lowerBound])
            place = String(spec[split.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        func quoted(_ text: String) -> String {
            "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let target = place.hasPrefix("~") ? place : quoted(place)
        return "grep -rnI --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.build --exclude-dir=build --exclude-dir=dist -e \(quoted(pattern)) \(target) | head -80"
    }

    // MARK: Web

    private static func get(_ url: URL) async -> (data: Data, type: String)? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return (data, http.value(forHTTPHeaderField: "Content-Type") ?? "")
    }

    /// A page's readable text.
    static func fetch(_ address: String) async -> Outcome {
        var text = address.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            return Outcome(ok: false, text: "\(address) is not a web address.")
        }
        guard let (data, type) = await get(url) else {
            return Outcome(ok: false, text: "Could not load \(url.absoluteString).")
        }
        guard let raw = String(data: data.prefix(2_000_000), encoding: .utf8)
                ?? String(data: data.prefix(2_000_000), encoding: .isoLatin1) else {
            return Outcome(ok: false, text: "\(url.absoluteString) is not text.")
        }
        let body = type.contains("html") || raw.range(of: "<html", options: .caseInsensitive) != nil ? plainText(fromHTML: raw) : raw
        let cut = String(body.prefix(limit))
        return Outcome(ok: true, text: cut + (body.count > limit ? "\n(the page continues; this is the first part)" : ""))
    }

    /// Web results for a query: title, address and a line of each. It reads
    /// a public search page, so it is best effort: when that page changes
    /// or refuses, the result says so and the model can FETCH a known
    /// address instead.
    static func search(web query: String) async -> Outcome {
        var parts = URLComponents(string: "https://html.duckduckgo.com/html/")
        parts?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = parts?.url, let (data, _) = await get(url), let html = String(data: data, encoding: .utf8) else {
            return Outcome(ok: false, text: "The web search could not be reached. FETCH a page you know the address of instead.")
        }
        let titles = matches(in: html, pattern: "<a[^>]*class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>")
        let snippets = matches(in: html, pattern: "<a[^>]*class=\"result__snippet\"[^>]*>(.*?)</a>")
        var lines: [String] = []
        for (index, found) in titles.prefix(6).enumerated() where found.count >= 2 {
            var link = decodeEntities(found[0])
            // Results are wrapped in a redirect that carries the real address.
            if let wrapped = URLComponents(string: link.hasPrefix("//") ? "https:" + link : link),
               let real = wrapped.queryItems?.first(where: { $0.name == "uddg" })?.value {
                link = real
            }
            let title = plainText(fromHTML: found[1])
            let snippet = index < snippets.count ? plainText(fromHTML: snippets[index].first ?? "") : ""
            lines.append("\(index + 1). \(title)\n   \(link)\n   \(snippet)")
        }
        guard !lines.isEmpty else {
            return Outcome(ok: false, text: "The web search returned nothing usable for \"\(query)\". Try other words, or FETCH a page you know the address of.")
        }
        return Outcome(ok: true, text: lines.joined(separator: "\n"))
    }

    /// The capture groups of every match.
    private static func matches(in text: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return []
        }
        let whole = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: whole).map { match in
            (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
    }

    private static func replacing(_ text: String, _ pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return text
        }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                                    ("&#39;", "'"), ("&#x27;", "'"), ("&nbsp;", " "), ("&mdash;", "-"), ("&ndash;", "-")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }

    /// HTML with its scripts, styles and tags removed, as lines of text.
    static func plainText(fromHTML html: String) -> String {
        var text = replacing(html, "<(script|style|noscript|svg|head)[^>]*>.*?</\\1>", with: " ")
        text = replacing(text, "<!--.*?-->", with: " ")
        text = replacing(text, "<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>", with: "\n")
        text = replacing(text, "<[^>]+>", with: " ")
        text = decodeEntities(text)
        text = replacing(text, "[ \\t]+", with: " ")
        text = replacing(text, " ?\\n ?", with: "\n")
        text = replacing(text, "\\n{3,}", with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
