import Foundation

/// A diff cut to what a review is given, fairly. Every file it touches is
/// named with how much changed in it. Whole files go in smallest first,
/// so one large file cannot crowd out the rest; what room is left shows
/// the start of the files that did not fit, in the order the diff has
/// them; and files that tools write (`isLowSignal`) only get what is left
/// after that. The files keep the diff's order throughout.
public enum ReviewDiff {
    /// Files a reviewer learns little from: what package managers and
    /// build tools write.
    public static let lowSignalNames: Set<String> = [
        "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "Cargo.lock", "Package.resolved",
        "Gemfile.lock", "poetry.lock", "uv.lock", "Pipfile.lock", "composer.lock", "go.sum", "Podfile.lock",
        "flake.lock",
    ]
    public static let lowSignalEndings = [".min.js", ".min.css", ".map", ".snap"]
    /// Below this much room left, a file that did not fit is only named.
    public static let smallestShare = 400

    public struct Fitted: Equatable, Sendable {
        public var text: String
        /// The files whose changes are not shown in full, in the diff's order.
        public var cut: [String]

        public init(text: String, cut: [String]) {
            self.text = text
            self.cut = cut
        }
    }

    /// One file's part of a diff.
    struct Part: Equatable {
        var path: String
        var text: String
        var added: Int
        var removed: Int
    }

    public static func isLowSignal(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return lowSignalNames.contains(name) || lowSignalEndings.contains { name.hasSuffix($0) }
    }

    /// A git diff cut to at most about `limit` characters. (Naming every
    /// file can take more than that when there are very many; then as
    /// many are named as fit, and how many more there are.)
    public static func fit(_ diff: String, limit: Int) -> Fitted {
        let parts = parts(of: diff)
        guard !parts.isEmpty else {
            return Fitted(text: diff.count <= limit ? diff : String(diff.prefix(limit)), cut: [])
        }
        let sizes = parts.map(\.text.count)
        if sizes.reduce(0, +) <= limit {
            return Fitted(text: parts.map(\.text).joined(), cut: [])
        }
        var shown = parts.map(stub)
        var room = limit - shown.reduce(0) { $0 + $1.count }
        guard room >= 0 else {
            // Too many files even to name them all.
            var text = ""
            var used = 0
            var named = 0
            for line in shown {
                if used + line.count > limit { break }
                text += line
                used += line.count
                named += 1
            }
            text += "[and \(parts.count - named) more files]\n"
            return Fitted(text: text, cut: parts.map(\.path))
        }
        var whole = Set<Int>()
        // Whole files, smallest first, as many as there is room for.
        func showWhole(_ indices: [Int]) {
            let order = indices.sorted { sizes[$0] != sizes[$1] ? sizes[$0] < sizes[$1] : $0 < $1 }
            for index in order {
                let extra = sizes[index] - shown[index].count
                guard extra <= room else { continue }
                shown[index] = parts[index].text
                room -= extra
                whole.insert(index)
            }
        }
        let written = parts.indices.filter { !isLowSignal(parts[$0].path) }
        showWhole(written)
        // The start of the people's files that did not fit, in the diff's
        // order, before anything tools wrote.
        for index in written where !whole.contains(index) && room >= smallestShare {
            guard let start = start(of: parts[index], within: room + shown[index].count) else { continue }
            room -= start.count - shown[index].count
            shown[index] = start
        }
        showWhole(parts.indices.filter { isLowSignal(parts[$0].path) })
        return Fitted(text: shown.joined(), cut: parts.indices.filter { !whole.contains($0) }.map { parts[$0].path })
    }

    /// A diff's files, each with its own part of the text.
    static func parts(of diff: String) -> [Part] {
        var parts: [Part] = []
        var lines: [Substring] = []
        func close() {
            while let last = lines.last, last.isEmpty { lines.removeLast() }
            guard let header = lines.first else { return }
            var added = 0
            var removed = 0
            for line in lines.dropFirst() {
                if line.hasPrefix("+"), !line.hasPrefix("+++ ") { added += 1 }
                if line.hasPrefix("-"), !line.hasPrefix("--- ") { removed += 1 }
            }
            parts.append(Part(path: path(header: header, lines: lines), text: lines.joined(separator: "\n") + "\n",
                              added: added, removed: removed))
            lines = []
        }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let starts = line.hasPrefix("diff --git ")
            if starts { close() }
            // Anything before the first file (what a shell printed) is left out.
            if starts || !lines.isEmpty { lines.append(line) }
        }
        close()
        return parts
    }

    /// The file a part is about, from the lines git writes for it.
    static func path(header: Substring, lines: [Substring]) -> String {
        func named(_ prefix: String) -> String? {
            guard let line = lines.prefix(8).first(where: { $0.hasPrefix(prefix) }) else { return nil }
            // git ends the name with a tab when it holds a space.
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\t"))
        }
        if let after = named("+++ b/") { return after }
        if let before = named("--- a/") { return before }
        // "diff --git a/<path> b/<path>": the same path twice, as renames
        // are not followed.
        let rest = String(header.dropFirst("diff --git ".count))
        let length = (rest.count - 5) / 2
        if rest.count >= 7, (rest.count - 5) % 2 == 0, rest.hasPrefix("a/") {
            let candidate = String(rest.dropFirst(2).prefix(length))
            if rest == "a/" + candidate + " b/" + candidate { return candidate }
        }
        return rest
    }

    /// A file named, with how much changed in it, in place of its changes.
    static func stub(_ part: Part) -> String {
        let header = String(part.text.prefix { $0 != "\n" })
        return header + "\n[its changes are left out: +\(part.added) -\(part.removed) lines]\n"
    }

    /// The start of a file's changes that fits in `room`, marked as cut;
    /// nil when not even its first lines do.
    static func start(of part: Part, within room: Int) -> String? {
        let marker = "[the rest of its changes are left out]\n"
        var text = ""
        var size = 0
        for line in part.text.split(separator: "\n", omittingEmptySubsequences: false) {
            let next = line.count + 1
            if size + next + marker.count > room { break }
            text += line
            text += "\n"
            size += next
        }
        // The header and something of the changes, or nothing.
        guard text.split(separator: "\n").count > 1 else { return nil }
        return text + marker
    }
}
