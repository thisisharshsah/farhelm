import Foundation

/// Which parts of a project a task works in, so that no two tasks change
/// the same file at once, and no task starts from a base that lacks work
/// it could collide with: a lease on its paths, the way a lock manager
/// keeps two writers apart. Merges then have nothing to settle by design,
/// not by luck. Where a plan was wrong and they still do, the task's own
/// agent settles them in its copy (`Board.copyConflicts`), never the
/// person (ADR 0014, "No conflicts reach the person").
///
/// A path is written from the project's folder: a file
/// ("Sources/App/Login.swift") or a folder ("Sources/App/"). A task whose
/// paths are not known holds the whole project, so it is kept apart from
/// every other: two unknowns never run side by side.
public enum Leases {
    /// The most paths a task keeps, and the longest one.
    public static let pathLimit = 40
    public static let pathLength = 300

    /// A path as it is compared: from the project's folder, with no
    /// leading "./" or "/", no trailing "/", no part from a wildcard on
    /// ("src/*.ts" is "src"), and in lower case, since a Mac's disk does
    /// not tell case apart. "" is the whole project.
    public static func normal(_ path: String) -> String {
        var text = path.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        while text.contains("//") { text = text.replacingOccurrences(of: "//", with: "/") }
        while text.hasPrefix("./") { text.removeFirst(2) }
        while text.hasPrefix("/") { text.removeFirst() }
        if let wild = text.firstIndex(where: { "*?[{".contains($0) }) {
            let before = text[..<wild]
            text = before.lastIndex(of: "/").map { String(before[..<$0]) } ?? ""
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text == "." ? "" : text.lowercased()
    }

    /// Paths as a task keeps them: each as written, tidied, without the
    /// same one twice, and no more than `pathLimit`.
    public static func list(_ paths: [String]) -> [String] {
        var kept: [String] = []
        var seen: Set<String> = []
        for path in paths {
            var text = path.trimmingCharacters(in: .whitespacesAndNewlines)
            while text.hasPrefix("./") { text.removeFirst(2) }
            guard !text.isEmpty, text.count <= pathLength, seen.insert(normal(text)).inserted else { continue }
            kept.append(text)
            if kept.count == pathLimit { break }
        }
        return kept
    }

    /// Whether two paths could name the same file: one is the other, or
    /// inside it. The whole project overlaps everything.
    public static func overlap(_ one: String, _ other: String) -> Bool {
        let first = normal(one)
        let second = normal(other)
        if first.isEmpty || second.isEmpty || first == second { return true }
        return first.hasPrefix(second + "/") || second.hasPrefix(first + "/")
    }

    /// Where two tasks' paths meet: the first path of `one` that overlaps
    /// one of `other`; "" when either list is not known (empty), since
    /// such a task holds the whole project; nil when they are apart.
    public static func meeting(_ one: [String], _ other: [String]) -> String? {
        guard !one.isEmpty, !other.isEmpty else { return "" }
        for path in one where other.contains(where: { overlap(path, $0) }) {
            return path
        }
        return nil
    }
}

extension Board {
    /// The paths a task holds against the others while its work is not
    /// in the project's branch; nil for none. While it runs (or is being
    /// started, `starting`) it holds what it was planned to change and
    /// what it has changed so far (`changed`). With work left in an open
    /// copy (waiting for review, to be merged, or to settle conflicts) it
    /// holds what it changed, or, while that is not known, what it was
    /// planned to change. An empty list holds the whole project.
    public func held(by item: WorkItem, changed: [String]?, starting: Bool = false) -> [String]? {
        if item.activeRun != nil || starting { return item.paths + (changed ?? []) }
        guard item.workingCopy?.isOpen == true else { return nil }
        if let changed { return changed.isEmpty ? nil : changed }
        return item.paths
    }

    /// The task a ready one waits for, so the two never change the same
    /// file at once and it starts from a base that has that task's work
    /// in it: the first other task, under any goal, whose held paths
    /// (`held(by:changed:starting:)`) meet the ready task's planned paths.
    /// `changed` gives what each task's copy changed, as last looked at,
    /// in paths from the project's folder; `starting` are the tasks whose
    /// runs are being started now. Returns that task and where the two
    /// meet ("" when either side is not known), or nil when it may start.
    public func leaseHolder(for item: WorkItem, changed: [UUID: [String]], starting: Set<UUID> = [])
        -> (holder: WorkItem, path: String)? {
        for other in allItems where other.id != item.id {
            guard let theirs = held(by: other, changed: changed[other.id], starting: starting.contains(other.id)),
                  let path = Leases.meeting(item.paths, theirs) else { continue }
            return (other, path)
        }
        return nil
    }
}
