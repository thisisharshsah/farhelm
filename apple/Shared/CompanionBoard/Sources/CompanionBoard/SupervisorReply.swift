import Foundation

/// What a supervisor wrote back: words for the person, and the changes it
/// asks for on the board.
///
/// The supervisor writes its answer in plain words and, when the board
/// should change, ends with one block of JSON fenced as ```board. A model
/// wrote it, so it is read forgivingly (a ```json fence, no fence at all,
/// a trailing comma, numbers as "20k") and never trusted: what comes out
/// is a list of requests for `Board.apply` to check.
public struct SupervisorReply: Equatable, Sendable {
    /// The answer with the block of changes taken out.
    public var prose: String
    public var operations: [BoardOperation]
    /// What could not be read, in plain words.
    public var problems: [String]

    public init(prose: String, operations: [BoardOperation] = [], problems: [String] = []) {
        self.prose = prose
        self.operations = operations
        self.problems = problems
    }

    /// The fences a block of changes may start with.
    private static let fences = ["```board", "```json"]

    // MARK: While it arrives

    /// The part of a reply that is still arriving that can be shown: all
    /// of it up to where a block of changes starts, or may be starting.
    /// What is held back is never lost: `parse` gives it back as words if
    /// it turns out not to be changes.
    public static func visible(_ partial: String) -> String {
        let cut = candidates(in: partial).first ?? partial.endIndex
        var shown = partial[..<cut]
        // The reply may end in the first characters of a fence: "``".
        if cut == partial.endIndex, let lineStart = lastLineStart(in: partial) {
            let tail = partial[lineStart...].trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty, fences.contains(where: { $0.hasPrefix(tail) }) {
                shown = partial[..<lineStart]
            }
        }
        return String(shown)
    }

    // MARK: Once it is whole

    public static func parse(_ text: String) -> SupervisorReply {
        var problems: [String] = []
        // The last block that reads as changes is the one meant.
        for start in candidates(in: text).reversed() {
            guard let block = jsonObject(in: text, from: start),
                  let changes = operations(from: block.value) else { continue }
            let prose = (String(text[..<start]) + String(text[block.end...]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if changes.isEmpty, text[start...].hasPrefix("```board") {
                problems.append("The supervisor's changes were empty.")
            }
            return SupervisorReply(prose: prose, operations: changes, problems: problems)
        }
        // A block cut off before its end (the reply ran out of room): the
        // changes that arrived whole are made, and the person is told that
        // the rest is still to come.
        if let start = candidates(in: text).last, let changes = salvaged(in: text, from: start) {
            let count = changes.count == 1 ? "first change was" : "first \(changes.count) changes were"
            problems.append("The supervisor's reply was cut off before its changes ended: the \(count) made. Say \"continue\" for the rest.")
            return SupervisorReply(prose: String(text[..<start]).trimmingCharacters(in: .whitespacesAndNewlines),
                                   operations: changes, problems: problems)
        }
        if text.contains("```board") {
            problems.append("The supervisor's changes could not be read, so the board was left as it is.")
        }
        return SupervisorReply(prose: text.trimmingCharacters(in: .whitespacesAndNewlines), problems: problems)
    }

    /// Where a block of changes may start: a line that opens a ```board or
    /// ```json fence, or a line that starts a JSON value outside any
    /// fence. Lines inside a block are part of it, not blocks themselves,
    /// and what is inside some other code block is the person's to read,
    /// even when it is JSON.
    private static func candidates(in text: String) -> [String.Index] {
        var found: [String.Index] = []
        var lineStart = text.startIndex
        var inChanges = false
        var inOther = false
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(where: \.isNewline) ?? text.endIndex
            let line = text[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
            var next = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
            if line.hasPrefix("```") {
                let lowered = line.lowercased()
                if inChanges {
                    inChanges = false
                } else if inOther {
                    inOther = false
                } else if fences.contains(where: { lowered.hasPrefix($0) }) {
                    found.append(lineStart)
                    inChanges = true
                } else {
                    inOther = true
                }
            } else if !inChanges, !inOther, line.hasPrefix("{") || line.hasPrefix("[{") {
                found.append(lineStart)
                // On to the line after the value's end; a value still
                // arriving runs to the end of the text.
                if let open = text[lineStart...].firstIndex(where: { $0 == "{" || $0 == "[" }),
                   let close = matchingClose(in: text, from: open) {
                    let rest = text[close...]
                    next = rest.firstIndex(where: \.isNewline).map { text.index(after: $0) } ?? text.endIndex
                } else {
                    next = text.endIndex
                }
            }
            lineStart = next
        }
        return found
    }

    private static func lastLineStart(in text: String) -> String.Index? {
        guard !text.isEmpty else { return nil }
        if let newline = text.lastIndex(where: \.isNewline) {
            return text.index(after: newline)
        }
        return text.startIndex
    }

    /// The first JSON value at or after `start`, and where the block it is
    /// in ends (past its closing fence, when it has one).
    private static func jsonObject(in text: String, from start: String.Index) -> (value: Any, end: String.Index)? {
        guard let open = text[start...].firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        // Only a fence line and blank space may come before the value.
        let before = text[start..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        guard before.isEmpty || (before.hasPrefix("```") && !before.dropFirst(3).contains("`")) else { return nil }
        guard let close = matchingClose(in: text, from: open) else { return nil }
        let raw = String(text[open...close])
        guard let value = decode(raw) else { return nil }
        var end = text.index(after: close)
        // Take the closing fence with it.
        let rest = text[end...]
        if !before.isEmpty, let fence = rest.range(of: "```") {
            let between = rest[..<fence.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if between.isEmpty { end = fence.upperBound }
        }
        return (value, end)
    }

    /// The changes that arrived whole in a block that was cut off: every
    /// element of its list that closed before the text ended. nil when
    /// the block is whole, or holds no whole change.
    private static func salvaged(in text: String, from start: String.Index) -> [BoardOperation]? {
        guard let open = text[start...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var lastWhole: String.Index?
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" || character == "[" {
                depth += 1
            } else if character == "}" || character == "]" {
                depth -= 1
                // The outer object closed: the block is whole, not cut off.
                if depth <= 0 { return nil }
                // An element of the list inside the outer object closed.
                if depth == 2, character == "}" { lastWhole = index }
            }
            index = text.index(after: index)
        }
        guard let lastWhole, let value = decode(String(text[open...lastWhole]) + "]}"),
              let changes = operations(from: value), !changes.isEmpty else { return nil }
        return changes
    }

    /// The bracket that closes the one at `open`, with strings skipped.
    private static func matchingClose(in text: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" || character == "[" {
                depth += 1
            } else if character == "}" || character == "]" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// JSON as a model writes it: read as it is, and failing that with
    /// trailing commas and curly quotes put right.
    private static func decode(_ raw: String) -> Any? {
        if let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) { return value }
        var fixed = raw
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
        fixed = fixed.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
        return try? JSONSerialization.jsonObject(with: Data(fixed.utf8))
    }

    // MARK: From JSON to operations

    /// The operations in a decoded block, or nil when it is not a block
    /// of changes at all (some other JSON the supervisor showed).
    private static func operations(from value: Any) -> [BoardOperation]? {
        var list: [Any] = []
        var result: [BoardOperation] = []
        if let object = value as? [String: Any] {
            let keys = Set(object.keys.map { $0.lowercased() })
            guard !keys.isDisjoint(with: ["operations", "ops", "changes", "goal", "budget", "tasks"]) else { return nil }
            if let goal = Loose.text(object["goal"]) { result.append(.setGoal(goal)) }
            if let limits = object["budget"] as? [String: Any] { result.append(.setBudget(budget(limits))) }
            list = (object["operations"] ?? object["ops"] ?? object["changes"]) as? [Any] ?? []
            // A bare list of tasks is a list of tasks to add.
            for task in object["tasks"] as? [Any] ?? [] {
                guard var fields = task as? [String: Any] else { continue }
                if fields["op"] == nil { fields["op"] = "add" }
                list.append(fields)
            }
        } else if let array = value as? [Any] {
            guard array.contains(where: { ($0 as? [String: Any])?["op"] != nil }) else { return nil }
            list = array
        } else {
            return nil
        }
        for entry in list {
            guard let fields = entry as? [String: Any] else { continue }
            if let made = operation(from: fields) { result.append(made) }
        }
        return result
    }

    private static func budget(_ fields: [String: Any]) -> Budget {
        Budget(tokens: Loose.int(fields["tokens"]), dollars: Loose.double(fields["dollars"] ?? fields["usd"]))
    }

    private static func operation(from fields: [String: Any]) -> BoardOperation? {
        let name = (Loose.text(fields["op"] ?? fields["action"] ?? fields["type"]) ?? "")
            .lowercased().filter { $0.isLetter }
        let ref = Loose.text(fields["id"] ?? fields["task"] ?? fields["key"]) ?? ""
        switch name {
        case "add", "addtask", "create", "createtask", "new", "newtask":
            return .add(label: Loose.text(fields["ref"] ?? fields["label"] ?? fields["id"]), patch(from: fields))
        case "update", "updatetask", "edit", "change", "set", "patch":
            guard !ref.isEmpty else { return nil }
            return .update(ref: ref, patch(from: fields))
        case "move", "movetask", "status", "setstatus", "transition":
            guard !ref.isEmpty, let status = Loose.text(fields["status"] ?? fields["to"] ?? fields["column"])
                .flatMap(WorkStatus.init(loose:)) else { return nil }
            return .move(ref: ref, status)
        case "assign", "assignmodel", "suggest", "suggestmodel", "route":
            guard !ref.isEmpty, let model = Loose.text(fields["model"] ?? fields["assignee"] ?? fields["owner"]) else { return nil }
            return .assign(ref: ref, model: model, reason: Loose.text(fields["reason"] ?? fields["why"]) ?? "")
        case "note", "comment", "addnote":
            guard !ref.isEmpty, let text = Loose.text(fields["text"] ?? fields["note"] ?? fields["comment"]) else { return nil }
            return .note(ref: ref, text)
        case "remove", "removetask", "drop":
            guard !ref.isEmpty else { return nil }
            return .remove(ref: ref)
        // Its own op, not another name for remove: delete may take a task
        // with runs, so it carries a reason for the history.
        case "delete", "deletetask", "trash", "trashtask":
            guard !ref.isEmpty else { return nil }
            let reason = Loose.text(fields["reason"] ?? fields["why"] ?? fields["text"] ?? fields["note"]) ?? ""
            return .delete(ref: ref, reason: reason)
        case "approve", "approvetask", "accept", "pass":
            guard !ref.isEmpty else { return nil }
            return .approve(ref: ref)
        case "start", "startrun", "starttask", "run", "restart", "rerun":
            guard !ref.isEmpty else { return nil }
            return .start(ref: ref)
        case "stop", "stoprun", "cancel", "cancelrun", "halt", "haltrun":
            guard !ref.isEmpty else { return nil }
            let reason = Loose.text(fields["reason"] ?? fields["why"] ?? fields["text"] ?? fields["note"]) ?? ""
            return .stop(ref: ref, reason: reason)
        case "goal", "setgoal":
            guard let goal = Loose.text(fields["goal"] ?? fields["text"]) else { return nil }
            return .setGoal(goal)
        case "newgoal", "startgoal", "nextgoal":
            guard let goal = Loose.text(fields["goal"] ?? fields["text"] ?? fields["title"]) else { return nil }
            let carry = Loose.bool(fields["carry"] ?? fields["carry_over"] ?? fields["bring_unfinished"]) ?? false
            return .newGoal(goal, bringUnfinished: carry)
        case "budget", "setbudget":
            return .setBudget(budget(fields))
        default:
            return nil
        }
    }

    private static func patch(from fields: [String: Any]) -> ItemPatch {
        ItemPatch(
            title: Loose.text(fields["title"] ?? fields["name"]),
            details: Loose.text(fields["details"] ?? fields["description"] ?? fields["body"]),
            acceptance: Loose.list(fields["acceptance"] ?? fields["acceptance_criteria"] ?? fields["criteria"]),
            status: Loose.text(fields["status"]).flatMap(WorkStatus.init(loose:)),
            priority: Loose.text(fields["priority"]).flatMap(WorkPriority.init(loose:)),
            kind: Loose.text(fields["kind"] ?? fields["category"]).flatMap(WorkKind.init(loose:)),
            milestone: Loose.text(fields["milestone"] ?? fields["phase"] ?? fields["group"], allowEmpty: true),
            dependsOn: Loose.list(fields["depends_on"] ?? fields["dependsOn"] ?? fields["blocked_by"] ?? fields["after"]),
            estimateTokens: Loose.int(fields["estimate_tokens"] ?? fields["estimateTokens"] ?? fields["estimate"]),
            model: Loose.text(fields["model"] ?? fields["assignee"]),
            reason: Loose.text(fields["reason"] ?? fields["why"]),
            paths: Loose.list(fields["paths"] ?? fields["files"] ?? fields["touches"]),
            role: Loose.text(fields["role"]))
    }
}

/// Values as a model may write them.
enum Loose {
    /// Text, or a number as text. nil for nothing, or for only blank
    /// space unless `allowEmpty`.
    static func text(_ value: Any?, allowEmpty: Bool = false) -> String? {
        let text: String
        switch value {
        case let string as String: text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber: text = number.stringValue
        default: return nil
        }
        return text.isEmpty && !allowEmpty ? nil : text
    }

    /// Yes or no: true, "yes", 1.
    static func bool(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        switch text(value)?.lowercased() {
        case "true", "yes", "y", "1": return true
        case "false", "no", "n", "0": return false
        default: return nil
        }
    }

    /// A list of texts: a JSON list, or one text with a line or a
    /// semicolon between the items.
    static func list(_ value: Any?) -> [String]? {
        if let array = value as? [Any] {
            return array.compactMap { text($0) }
        }
        guard let single = text(value) else { return nil }
        let parts = single.split(whereSeparator: { $0.isNewline || $0 == ";" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-*•")) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts
    }

    /// A whole number: 20000, 20000.0, "20,000", "20k", "1.5m".
    static func int(_ value: Any?) -> Int? {
        guard let number = double(value), number.isFinite, abs(number) < 1e15 else { return nil }
        return Int(number.rounded())
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        guard var text = text(value)?.lowercased() else { return nil }
        text = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
        // "20k tokens": the number and its unit lead.
        let lead = text.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        guard let base = Double(lead) else { return nil }
        let unit = text.dropFirst(lead.count).trimmingCharacters(in: .whitespaces).first
        switch unit {
        case "k": return base * 1_000
        case "m": return base * 1_000_000
        case "b": return base * 1_000_000_000
        default: return base
        }
    }
}
