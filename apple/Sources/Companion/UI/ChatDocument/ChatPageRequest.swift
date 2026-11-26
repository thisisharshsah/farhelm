import Foundation

/// Which requests the chat page may make. Kept as plain functions so the
/// rule is tested apart from WebKit: the page loads its own bundled files
/// and pictures and films on this Mac, and nothing else. Every remote
/// scheme (http, https, ws, wss and any other) is refused.
enum ChatPageRequest {
    enum Verdict: Equatable {
        /// Loaded in the page.
        case load
        /// A clicked link, opened by the app in the default browser or app.
        case openOutside
        case refuse
    }

    /// Clicked links the app opens outside the page.
    static let outsideSchemes: Set<String> = ["http", "https", "mailto"]

    /// `clicked` is a link the person activated: it never loads in the
    /// page. A local file opens outside only when it is a picture or film,
    /// so a link in an answer can never start a script or an app.
    static func verdict(for url: URL, pageFolder: URL, clicked: Bool) -> Verdict {
        if clicked {
            let scheme = url.scheme?.lowercased() ?? ""
            return outsideSchemes.contains(scheme) || isLocalMedia(url) ? .openOutside : .refuse
        }
        return allows(url, pageFolder: pageFolder) ? .load : .refuse
    }

    static func allows(_ url: URL, pageFolder: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "about": return url.absoluteString == "about:blank"
        case "file": return isInside(url, pageFolder) || isLocalMedia(url)
        default: return false
        }
    }

    static func isLocalMedia(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let type = url.pathExtension.lowercased()
        return ChatMarkdown.pictureTypes.contains(type) || ChatMarkdown.filmTypes.contains(type)
    }

    /// Inside the page's folder after `..` and links are resolved, so a
    /// path cannot climb out of it.
    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// The same rule as a WebKit content rule list, for what the page asks
    /// for itself (pictures, styles, scripts), which the navigation delegate
    /// never sees: block everything, then let the page's folder, blank and
    /// local pictures and films through.
    static func ruleList(pageFolder: URL) -> String {
        var folder = pageFolder.standardizedFileURL.absoluteString
        if !folder.hasSuffix("/") { folder += "/" }
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^about:blank$"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^" + regexEscaped(folder)], "action": ["type": "ignore-previous-rules"]]
        ]
        // Content rule lists take no alternation, so one rule per type.
        for type in ChatMarkdown.pictureTypes.union(ChatMarkdown.filmTypes).sorted() {
            rules.append(["trigger": ["url-filter": "^file://.*\\.\(type)$"], "action": ["type": "ignore-previous-rules"]])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    private static func regexEscaped(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\^$.|?*+()[]{}".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}