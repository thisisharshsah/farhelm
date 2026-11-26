import Foundation

/// Markdown to HTML for the chat drawn as one document (`ChatDocument`).
///
/// Every character of a message reaches the page through `escape`, so HTML
/// written in a message (a <script>, an <img onerror>) shows as text and
/// nothing in a message can run. Links keep only addresses the app opens
/// itself, and only pictures and films on this Mac are placed in the page:
/// the page loads nothing from the network.
enum ChatMarkdown {
    static let pictureTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp"]
    static let filmTypes: Set<String> = ["mp4", "mov", "m4v", "webm"]

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    static func html(_ text: String) -> String {
        blocks(text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
    }

    /// A picture or film on this Mac as the tag that shows it, or nil for
    /// any other file.
    static func media(_ url: URL, alt: String) -> String? {
        guard url.isFileURL else { return nil }
        let type = url.pathExtension.lowercased()
        let source = escape(url.absoluteString)
        if pictureTypes.contains(type) {
            return "<img src=\"\(source)\" alt=\"\(escape(alt))\">"
        }
        if filmTypes.contains(type) {
            return "<video src=\"\(source)\" controls preload=\"metadata\" title=\"\(escape(alt))\"></video>"
        }
        return nil
    }

    static func isWebAddress(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    /// A path or file URL written in a message, as a file URL.
    static func localFile(_ target: String) -> URL? {
        if target.lowercased().hasPrefix("file://") {
            guard let url = URL(string: target), url.isFileURL else { return nil }
            return url.standardizedFileURL
        }
        let path = target.removingPercentEncoding ?? target
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        if path.hasPrefix("~/") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL }
        return nil
    }

    // MARK: - Blocks

    private struct ListItem {
        var indent: Int
        var ordered: Bool
        var number: Int
        var text: String
        /// Lines that belong to the item after its first (indented text, a
        /// code block inside a step).
        var more: [String] = []
    }

    private enum Align: String {
        case none, left, center, right
    }

    private static func blocks(_ lines: [String]) -> String {
        var out: [String] = []
        var paragraph: [String] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            // Chat answers are written line by line, so a line break stays one.
            out.append("<p>" + paragraph.map(inline).joined(separator: "<br>") + "</p>")
            paragraph.removeAll()
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                i += 1
                continue
            }
            if let fence = fence(trimmed) {
                flush()
                let language = trimmed.dropFirst(fence.count).split(separator: " ").first.map(String.init) ?? ""
                var code: [String] = []
                i += 1
                while i < lines.count, !closes(lines[i], fence) {
                    code.append(lines[i])
                    i += 1
                }
                // Past the closing fence, or the end when it never came.
                i += 1
                out.append(codeBlock(code, language: language))
                continue
            }
            if let title = heading(trimmed) {
                flush()
                out.append("<h\(title.level)>\(inline(title.text))</h\(title.level)>")
                i += 1
                continue
            }
            if isRule(trimmed) {
                flush()
                out.append("<hr>")
                i += 1
                continue
            }
            if trimmed.contains("|"), i + 1 < lines.count, let aligns = separator(lines[i + 1]) {
                flush()
                var rows: [[String]] = []
                var next = i + 2
                while next < lines.count {
                    let row = lines[next].trimmingCharacters(in: .whitespaces)
                    if row.isEmpty || !row.contains("|") { break }
                    rows.append(cells(row))
                    next += 1
                }
                out.append(table(header: cells(trimmed), aligns: aligns, rows: rows))
                i = next
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while i < lines.count {
                    let quote = lines[i].trimmingCharacters(in: .whitespaces)
                    guard quote.hasPrefix(">") else { break }
                    var rest = quote.dropFirst()
                    if rest.first == " " { rest = rest.dropFirst() }
                    quoted.append(String(rest))
                    i += 1
                }
                out.append("<blockquote>" + blocks(quoted) + "</blockquote>")
                continue
            }
            if listItem(line) != nil {
                flush()
                var items: [ListItem] = []
                while i < lines.count {
                    if let item = listItem(lines[i]) {
                        items.append(item)
                        i += 1
                        continue
                    }
                    if lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        // A blank line keeps the list going when what follows
                        // is another item or more of the last one.
                        var next = i + 1
                        while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
                        guard next < lines.count, listItem(lines[next]) != nil || indent(of: lines[next]) > 0 else { break }
                        if listItem(lines[next]) == nil {
                            items[items.count - 1].more.append(contentsOf: Array(repeating: "", count: next - i))
                        }
                        i = next
                        continue
                    }
                    guard indent(of: lines[i]) > 0 else { break }
                    items[items.count - 1].more.append(lines[i])
                    i += 1
                }
                out.append(list(items[...]))
                continue
            }
            paragraph.append(trimmed)
            i += 1
        }
        flush()
        return out.joined(separator: "\n")
    }

    private static func fence(_ line: String) -> String? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let run = line.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        // A fence's language never holds a backtick: that line is inline code.
        if first == "`", line.dropFirst(run.count).contains("`") { return nil }
        return String(run)
    }

    private static func closes(_ line: String, _ fence: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let mark = fence.first else { return false }
        return trimmed.count >= fence.count && trimmed.allSatisfy { $0 == mark }
    }

    private static func codeBlock(_ lines: [String], language: String) -> String {
        let label = language.isEmpty ? "" : " data-lang=\"\(escape(language))\""
        return "<pre class=\"code\"\(label)><code>\(escape(lines.joined(separator: "\n")))</code></pre>"
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let marks = line.prefix { $0 == "#" }
        guard (1...6).contains(marks.count) else { return nil }
        let rest = line.dropFirst(marks.count)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return (marks.count, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func separator(_ line: String) -> [Align]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return nil }
        var result: [Align] = []
        for cell in cells(trimmed) {
            let body = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            result.append(left && right ? .center : right ? .right : left ? .left : .none)
        }
        return result.isEmpty ? nil : result
    }

    /// A table row's cells, split on pipes outside inline code; `\|` is a
    /// pipe in the cell.
    private static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var result: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for character in text {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "`" { inCode.toggle() }
            if character == "|", !inCode {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(character)
        }
        if escaped { current.append("\\") }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    private static func table(header: [String], aligns: [Align], rows: [[String]]) -> String {
        func cell(_ tag: String, _ text: String, _ index: Int) -> String {
            let align = index < aligns.count ? aligns[index] : .none
            let mark = align == .none ? "" : " class=\"align-\(align.rawValue)\""
            return "<\(tag)\(mark)>\(inline(text))</\(tag)>"
        }
        let head = header.enumerated().map { cell("th", $0.element, $0.offset) }.joined()
        let body = rows.map { row -> String in
            let filled = (0..<header.count).map { $0 < row.count ? row[$0] : "" }
            return "<tr>" + filled.enumerated().map { cell("td", $0.element, $0.offset) }.joined() + "</tr>"
        }.joined()
        return "<div class=\"table\"><table><thead><tr>\(head)</tr></thead><tbody>\(body)</tbody></table></div>"
    }

    /// Columns of leading space, a tab counting as four.
    private static func indent(of line: String) -> Int {
        var columns = 0
        for character in line {
            if character == " " { columns += 1 } else if character == "\t" { columns += 4 } else { break }
        }
        return columns
    }

    private static func dedent(_ line: String, by columns: Int) -> String {
        var removed = 0
        var rest = Substring(line)
        while removed < columns, let first = rest.first, first == " " || first == "\t" {
            removed += first == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        return String(rest)
    }

    private static func listItem(_ line: String) -> ListItem? {
        let depth = indent(of: line)
        let rest = line.drop { $0 == " " || $0 == "\t" }
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return ListItem(indent: depth, ordered: false, number: 1,
                            text: String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count) else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " else { return nil }
        return ListItem(indent: depth, ordered: true, number: Int(digits) ?? 1,
                        text: String(after.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    /// Items at one depth, each with the deeper items after it as its own list.
    private static func list(_ items: ArraySlice<ListItem>) -> String {
        guard let first = items.first else { return "" }
        let tag = first.ordered ? "ol" : "ul"
        var html = "<\(tag)" + (first.ordered && first.number != 1 ? " start=\"\(first.number)\"" : "") + ">"
        var index = items.startIndex
        while index < items.endIndex {
            let item = items[index]
            var end = index + 1
            while end < items.endIndex, items[end].indent > item.indent { end += 1 }
            html += "<li>" + itemHTML(item) + list(items[(index + 1)..<end]) + "</li>"
            index = end
        }
        return html + "</\(tag)>"
    }

    private static func itemHTML(_ item: ListItem) -> String {
        var text = item.text
        var box = ""
        for (mark, checked) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(mark) {
            box = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
            text = String(text.dropFirst(mark.count))
        }
        guard !item.more.isEmpty else { return box + inline(text) }
        let shift = item.more
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(indent(of:)).min() ?? 0
        return box + blocks([text] + item.more.map { dedent($0, by: shift) })
    }

    // MARK: - Inline

    private static let escapable: Set<Character> = Set("\\`*_{}[]()#+-.!|~<>\"'")

    static func inline(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            let character = chars[i]
            if character == "\\", i + 1 < chars.count, escapable.contains(chars[i + 1]) {
                out += escape(String(chars[i + 1]))
                i += 2
                continue
            }
            if character == "`" {
                let run = count(of: "`", in: chars, at: i)
                if let close = closingRun(of: "`", length: run, in: chars, from: i + run) {
                    var code = String(chars[(i + run)..<close])
                    if code.count > 1, code.hasPrefix(" "), code.hasSuffix(" ") { code = String(code.dropFirst().dropLast()) }
                    out += "<code>\(escape(code))</code>"
                    i = close + run
                } else {
                    out += String(repeating: "`", count: run)
                    i += run
                }
                continue
            }
            if character == "!", i + 1 < chars.count, chars[i + 1] == "[", let link = bracketed(chars, at: i + 1) {
                out += picture(alt: link.label, target: link.target)
                i = link.end
                continue
            }
            if character == "[", let link = bracketed(chars, at: i) {
                out += anchor(label: inline(link.label), target: link.target)
                i = link.end
                continue
            }
            if character == "<", let close = chars[(i + 1)...].firstIndex(of: ">") {
                let inner = String(chars[(i + 1)..<close])
                if isWebAddress(inner), !inner.contains(" ") {
                    out += anchor(label: escape(inner), target: inner)
                    i = close + 1
                    continue
                }
            }
            if character == "h", i == 0 || chars[i - 1].isWhitespace || chars[i - 1] == "(",
               let end = bareAddressEnd(chars, at: i) {
                let address = String(chars[i..<end])
                out += anchor(label: escape(address), target: address)
                i = end
                continue
            }
            if let styled = emphasis(chars, at: i) {
                out += styled.html
                i = styled.end
                continue
            }
            out += escape(String(character))
            i += 1
        }
        return out
    }

    private static func anchor(label: String, target: String) -> String {
        guard let address = linkAddress(target) else { return label }
        return "<a href=\"\(escape(address))\">\(label)</a>"
    }

    /// Only addresses the app can open in its own way; `javascript:`,
    /// `data:` and relative links stay plain text.
    private static func linkAddress(_ target: String) -> String? {
        if isWebAddress(target) || target.lowercased().hasPrefix("mailto:") { return target }
        return localFile(target)?.absoluteString
    }

    private static func picture(alt: String, target: String) -> String {
        if let url = localFile(target), let tag = media(url, alt: alt) { return tag }
        // A picture from the web is not loaded, since the page loads nothing
        // from the network: it stays a link to open in the browser.
        return anchor(label: escape(alt.isEmpty ? target : alt), target: target)
    }

    private static func bareAddressEnd(_ chars: [Character], at start: Int) -> Int? {
        let opening = String(chars[start..<min(chars.count, start + 8)])
        guard isWebAddress(opening) else { return nil }
        var end = start
        while end < chars.count, !chars[end].isWhitespace, chars[end] != "<" { end += 1 }
        // Trailing punctuation belongs to the sentence, and a closing
        // bracket to the text around the address unless the address opened one.
        while end > start {
            let last = chars[end - 1]
            if ".,;:!?'\"*_".contains(last) {
                end -= 1
                continue
            }
            if last == ")" {
                let inner = chars[start..<end]
                if inner.filter({ $0 == "(" }).count < inner.filter({ $0 == ")" }).count {
                    end -= 1
                    continue
                }
            }
            break
        }
        guard let url = URL(string: String(chars[start..<end])), url.host?.isEmpty == false else { return nil }
        return end
    }

    private static func emphasis(_ chars: [Character], at i: Int) -> (html: String, end: Int)? {
        for (mark, tag) in [("**", "strong"), ("__", "strong"), ("~~", "del"), ("*", "em"), ("_", "em")] {
            let token = Array(mark)
            guard starts(chars, with: token, at: i) else { continue }
            let open = i + token.count
            guard open < chars.count, !chars[open].isWhitespace else { continue }
            // Underscores inside a word (snake_case) are not emphasis.
            if token[0] == "_", i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber { continue }
            var search = open + 1
            while let close = find(token, in: chars, from: search) {
                let after = close + token.count
                let followedByWord = after < chars.count && (chars[after].isLetter || chars[after].isNumber)
                let doubled = token.count == 1 && after < chars.count && chars[after] == token[0]
                if !chars[close - 1].isWhitespace, !(token[0] == "_" && followedByWord), !doubled {
                    return ("<\(tag)>" + inline(String(chars[open..<close])) + "</\(tag)>", after)
                }
                search = close + (doubled ? 2 : 1)
            }
        }
        return nil
    }

    private static func bracketed(_ chars: [Character], at open: Int) -> (label: String, target: String, end: Int)? {
        guard open < chars.count, chars[open] == "[" else { return nil }
        var depth = 0
        var i = open
        var labelEnd: Int?
        while i < chars.count {
            if chars[i] == "\\" {
                i += 2
                continue
            }
            if chars[i] == "[" { depth += 1 }
            if chars[i] == "]" {
                depth -= 1
                if depth == 0 {
                    labelEnd = i
                    break
                }
            }
            i += 1
        }
        guard let labelEnd, labelEnd + 1 < chars.count, chars[labelEnd + 1] == "(" else { return nil }
        depth = 0
        i = labelEnd + 1
        while i < chars.count {
            if chars[i] == "(" { depth += 1 }
            if chars[i] == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            i += 1
        }
        guard i < chars.count else { return nil }
        var target = String(chars[(labelEnd + 2)..<i]).trimmingCharacters(in: .whitespaces)
        if target.hasPrefix("<"), let close = target.firstIndex(of: ">") {
            target = String(target[target.index(after: target.startIndex)..<close])
        } else if target.hasSuffix("\""), let title = target.range(of: " \"", options: .backwards) {
            target = String(target[..<title.lowerBound])
        }
        return (String(chars[(open + 1)..<labelEnd]), target, i + 1)
    }

    private static func starts(_ chars: [Character], with token: [Character], at i: Int) -> Bool {
        i + token.count <= chars.count && Array(chars[i..<(i + token.count)]) == token
    }

    private static func find(_ token: [Character], in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i + token.count <= chars.count {
            if starts(chars, with: token, at: i) { return i }
            i += 1
        }
        return nil
    }

    private static func count(of mark: Character, in chars: [Character], at start: Int) -> Int {
        var length = 0
        while start + length < chars.count, chars[start + length] == mark { length += 1 }
        return length
    }

    private static func closingRun(of mark: Character, length: Int, in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == mark {
                let run = count(of: mark, in: chars, at: i)
                if run == length { return i }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }
}