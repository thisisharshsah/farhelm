import AppKit
import SwiftUI

// MARK: - One selection across the chat's messages

/// Lets one drag select across the chat's messages, as in a document.
/// Each message is drawn by a text view of its own (`ChatTextView`), and a
/// selection of AppKit's never leaves the view it began in. So the drag is
/// tracked here instead: every text view in the window is asked which of
/// its characters lie between where the drag began and where it is now,
/// and Copy gathers what is selected in all of them, top to bottom.
@MainActor
final class ChatSelection {
    static let shared = ChatSelection()

    private let views = NSHashTable<ChatTextView>.weakObjects()
    private weak var anchorView: ChatTextView?
    private var anchorIndex = 0

    func add(_ view: ChatTextView) { views.add(view) }

    /// The window's text views that can be seen, top to bottom.
    private func ordered(in window: NSWindow?) -> [(view: ChatTextView, frame: NSRect)] {
        guard let window else { return [] }
        return views.allObjects
            .filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
            .map { (view: $0, frame: $0.convert($0.bounds, to: nil)) }
            // Window coordinates grow upwards: the highest edge is the first.
            .sorted { $0.frame.maxY != $1.frame.maxY ? $0.frame.maxY > $1.frame.maxY : $0.frame.minX < $1.frame.minX }
    }

    /// A drag begins in a view, at a character: whatever was selected in
    /// any view before is let go.
    func begin(in view: ChatTextView, at index: Int) {
        clear()
        anchorView = view
        anchorIndex = index
    }

    func clear() {
        for view in views.allObjects where view.selectedRange().length > 0 {
            view.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    /// The drag is at this point of the window now: each view's selection
    /// is set to its share of what lies between the anchor and the point.
    func drag(to point: NSPoint, in window: NSWindow?) {
        let list = ordered(in: window)
        guard let anchorView, let from = list.firstIndex(where: { $0.view === anchorView }) else { return }
        // The view the pointer is in, or the nearest one above or below it.
        func distance(_ frame: NSRect) -> CGFloat {
            if point.y > frame.maxY { return point.y - frame.maxY }
            if point.y < frame.minY { return frame.minY - point.y }
            return 0
        }
        guard let to = list.indices.min(by: { distance(list[$0].frame) < distance(list[$1].frame) }) else { return }
        let target = list[to].view
        let targetIndex = target.index(atWindowPoint: point)
        for (place, entry) in list.enumerated() {
            let length = entry.view.string.utf16.count
            var range = NSRange(location: 0, length: 0)
            if from == to {
                if place == from {
                    range = NSRange(location: min(anchorIndex, targetIndex), length: abs(anchorIndex - targetIndex))
                }
            } else if place == min(from, to) {
                // The upper end: from its character to the view's end.
                let start = from < to ? anchorIndex : targetIndex
                range = NSRange(location: start, length: max(0, length - start))
            } else if place == max(from, to) {
                // The lower end: from the view's start to its character.
                range = NSRange(location: 0, length: from < to ? targetIndex : anchorIndex)
            } else if place > min(from, to), place < max(from, to) {
                range = NSRange(location: 0, length: length)
            }
            if entry.view.selectedRange() != range { entry.view.setSelectedRange(range) }
        }
    }

    /// Everything in the window's messages.
    func selectAll(in window: NSWindow?) {
        for entry in ordered(in: window) {
            entry.view.setSelectedRange(NSRange(location: 0, length: entry.view.string.utf16.count))
        }
    }

    /// What is selected across the window's messages, top to bottom; nil
    /// when the selection is in one view or none (that view copies it).
    func gathered(in window: NSWindow?) -> String? {
        let parts = ordered(in: window).compactMap { entry -> String? in
            let range = entry.view.selectedRange()
            guard range.length > 0 else { return nil }
            return (entry.view.string as NSString).substring(with: range)
        }
        return parts.count > 1 ? parts.joined(separator: "\n\n") : nil
    }
}

/// A message's text, drawn by AppKit so its selection can be set from
/// outside: the drag that selects is `ChatSelection`'s, not the view's own.
final class ChatTextView: NSTextView {
    /// The character at a point of the window; the first above the text,
    /// the last below it.
    func index(atWindowPoint point: NSPoint) -> Int {
        let local = convert(point, from: nil)
        let length = string.utf16.count
        if local.y < 0 { return 0 }
        if local.y > bounds.height { return length }
        return min(max(0, characterIndexForInsertion(at: local)), length)
    }

    /// The height its text takes at a width, and the width it really uses.
    func fitted(to width: CGFloat) -> NSSize {
        guard let container = textContainer, let layout = layoutManager else { return NSSize(width: width, height: 16) }
        // Measured at the width asked about, then put back to the width
        // it is really drawn at: SwiftUI asks about several widths (its
        // ideal one among them), and the last one asked about was left
        // set, so text wrapped at that width inside a wider frame and ran
        // on under whatever came below.
        let drawn = container.containerSize
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        if bounds.width > 1, abs(drawn.width - width) > 0.5 {
            container.containerSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        }
        return NSSize(width: ceil(used.width), height: ceil(used.height))
    }

    /// The text is laid out at the width the view is given.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let container = textContainer, abs(container.containerSize.width - newSize.width) > 0.5 {
            container.containerSize = NSSize(width: newSize.width, height: .greatestFiniteMagnitude)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let selection = ChatSelection.shared
        // A double or triple click (a word, a paragraph) and a shift-click
        // stay the view's own.
        guard event.clickCount == 1, !event.modifierFlags.contains(.shift) else {
            selection.clear()
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        let start = index(atWindowPoint: event.locationInWindow)
        selection.begin(in: self, at: start)
        var dragged = false
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            dragged = true
            // Past the edge of what shows, the chat scrolls along.
            autoscroll(with: next)
            selection.drag(to: next.locationInWindow, in: window)
        }
        // A plain click on a link opens it.
        if !dragged, start < string.utf16.count,
           let link = textStorage?.attribute(.link, at: start, effectiveRange: nil) {
            if let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
        }
    }

    override func copy(_ sender: Any?) {
        if let gathered = ChatSelection.shared.gathered(in: window) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(gathered, forType: .string)
        } else {
            super.copy(sender)
        }
    }

    override func selectAll(_ sender: Any?) {
        ChatSelection.shared.selectAll(in: window)
    }
}

/// A message's text in the chat, selectable together with the messages
/// around it. `hugs` makes it only as wide as its words (your own
/// message in its bubble); otherwise it takes the width it is given.
struct SelectableText: NSViewRepresentable {
    let text: NSAttributedString
    var hugs = false

    func makeNSView(context: Context) -> ChatTextView {
        // TextKit 1, so the layout can be measured for a width.
        let view = ChatTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.linkTextAttributes = [.foregroundColor: NSColor(Theme.accent), .cursor: NSCursor.pointingHand]
        view.textStorage?.setAttributedString(text)
        ChatSelection.shared.add(view)
        return view
    }

    func updateNSView(_ view: ChatTextView, context: Context) {
        if !view.attributedString().isEqual(to: text) {
            view.textStorage?.setAttributedString(text)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChatTextView, context: Context) -> CGSize? {
        let offered = proposal.width ?? 480
        let width = offered.isFinite && offered > 0 ? offered : 480
        // Hugging, it is as wide as its words are when set by themselves:
        // the layout's own used width came out as the whole width offered,
        // which stretched your message's bubble across the chat.
        var taken = width
        if hugs {
            let natural = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading])
            taken = min(width, max(ceil(natural.width) + 1, 4))
        }
        let fitted = nsView.fitted(to: taken)
        return CGSize(width: taken, height: max(fitted.height, 4))
    }
}

// MARK: - An answer as attributed text

/// An answer's Markdown as attributed text for `SelectableText`: the
/// same things `MarkdownNotes` shows (headings, lists, tables, code, bold
/// and code in a line), as one text per stretch between its pictures.
enum MarkdownAttributed {
    enum Part {
        case text(NSAttributedString)
        /// A picture or a film on this Mac (`MarkdownNotes.mediaPath`).
        case media(String)
    }

    private final class Kept {
        let parts: [Part]
        init(_ parts: [Part]) { self.parts = parts }
    }

    /// Built once for a text, a size and a look: an answer is drawn again
    /// with every word that streams in.
    private static let cache: NSCache<NSString, Kept> = {
        let cache = NSCache<NSString, Kept>()
        cache.countLimit = 300
        return cache
    }()

    private static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, serif: Bool, mono: Bool = false,
                             italic: Bool = false) -> NSFont {
        var font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        if serif, !mono, let descriptor = font.fontDescriptor.withDesign(.serif) {
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        if italic {
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? font
        }
        return font
    }

    /// A line's bold, italics, code and links, in a base font and color.
    private static func inline(_ line: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor,
                               serif: Bool) -> NSMutableAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? NSAttributedString(markdown: line, options: options)) ?? NSAttributedString(string: line)
        let result = NSMutableAttributedString(string: parsed.string)
        let whole = NSRange(location: 0, length: result.length)
        result.addAttributes([.font: font(size, weight, serif: serif), .foregroundColor: color], range: whole)
        parsed.enumerateAttributes(in: NSRange(location: 0, length: parsed.length)) { attributes, range, _ in
            if let link = attributes[.link] { result.addAttribute(.link, value: link, range: range) }
            guard let raw = attributes[.inlinePresentationIntent] as? NSNumber else { return }
            let intent = InlinePresentationIntent(rawValue: raw.uintValue)
            if intent.contains(.code) {
                result.addAttributes([.font: font(size - 1, serif: serif, mono: true),
                                      .foregroundColor: NSColor(Theme.amber),
                                      .backgroundColor: NSColor(Theme.ink.opacity(0.09))], range: range)
            } else if intent.contains(.stronglyEmphasized) || intent.contains(.emphasized) {
                let heavy = intent.contains(.stronglyEmphasized) ? NSFont.Weight.semibold : weight
                result.addAttribute(.font, value: font(size, heavy, serif: serif, italic: intent.contains(.emphasized)),
                                    range: range)
            }
            if intent.contains(.strikethrough) {
                result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        return result
    }

    private static func paragraph(spacing: CGFloat, before: CGFloat = 0, indent: CGFloat = 0, hanging: CGFloat = 0,
                                  line: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = line
        style.paragraphSpacing = spacing
        style.paragraphSpacingBefore = before
        style.firstLineHeadIndent = indent
        style.headIndent = indent + hanging
        if hanging > 0 { style.tabStops = [NSTextTab(textAlignment: .left, location: indent + hanging)] }
        return style
    }

    static func parts(_ text: String, size: CGFloat, serif: Bool) -> [Part] {
        let key = "\(size)|\(serif)|\(Theme.isLight)|\(text)" as NSString
        if let kept = cache.object(forKey: key) { return kept.parts }
        let ink = NSColor(Theme.ink.opacity(0.9))
        let line = size * 0.3 + (serif ? 2 : 0)
        var parts: [Part] = []
        var current = NSMutableAttributedString()
        // Room before the next paragraph: after an empty line, or around a heading.
        var gap = false
        func close() {
            // The last paragraph ends without a line break of its own.
            if current.length > 0, current.string.hasSuffix("\n") {
                current.deleteCharacters(in: NSRange(location: current.length - 1, length: 1))
            }
            if current.length > 0 { parts.append(.text(current)) }
            current = NSMutableAttributedString()
            gap = false
        }
        func add(_ piece: NSMutableAttributedString, style: NSMutableParagraphStyle) {
            if gap, current.length > 0 { style.paragraphSpacingBefore += size * 0.55 }
            gap = false
            piece.append(NSAttributedString(string: "\n", attributes: piece.length > 0
                ? piece.attributes(at: piece.length - 1, effectiveRange: nil) : [:]))
            piece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: piece.length))
            current.append(piece)
        }
        var inCode = false
        var headerRow = true
        var lastWasTable = false
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                gap = true
                continue
            }
            if inCode {
                let piece = NSMutableAttributedString(string: raw.isEmpty ? " " : raw, attributes: [
                    .font: font(size - 1.5, serif: serif, mono: true), .foregroundColor: NSColor(Theme.ink.opacity(0.88)),
                    .backgroundColor: NSColor(Theme.ink.opacity(0.06))])
                add(piece, style: paragraph(spacing: 0, indent: 8, line: 1.5))
                continue
            }
            if let media = MarkdownNotes.mediaPath(in: trimmed) {
                close()
                parts.append(.media(media))
                continue
            }
            if trimmed.hasPrefix("|") {
                let cells = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                // The |---|---| rule under the header carries nothing.
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) { continue }
                if !lastWasTable { headerRow = true; gap = true }
                let row = NSMutableAttributedString()
                for (place, cell) in cells.enumerated() {
                    if place > 0 { row.append(NSAttributedString(string: "\t")) }
                    row.append(inline(cell, size: size - 0.5, weight: headerRow ? .semibold : .regular, color: ink, serif: false))
                }
                let style = paragraph(spacing: 3, line: 1.5)
                style.tabStops = (1...8).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * 170) }
                style.headIndent = 12
                add(row, style: style)
                headerRow = false
                lastWasTable = true
                continue
            }
            lastWasTable = false
            if trimmed.isEmpty || trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) {
                gap = true
                continue
            }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let title = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                gap = true
                let piece = level == 1
                    ? inline(title, size: size + 1.5, weight: .semibold, color: NSColor(Theme.ink.opacity(0.95)), serif: serif)
                    : inline(title, size: size - 0.5, weight: .bold, color: NSColor(Theme.accent), serif: false)
                add(piece, style: paragraph(spacing: size * 0.35, line: line))
                continue
            }
            var mark: String?
            var body = trimmed
            for prefix in ["- [ ] ", "- [x] ", "- ", "* ", "• "] where trimmed.hasPrefix(prefix) {
                mark = prefix == "- [ ] " ? "☐" : (prefix == "- [x] " ? "☑" : "•")
                body = String(trimmed.dropFirst(prefix.count))
                break
            }
            if mark == nil, let range = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                mark = trimmed[range].trimmingCharacters(in: .whitespaces)
                body = String(trimmed[range.upperBound...])
            }
            if let mark {
                let piece = NSMutableAttributedString(string: mark + "\t", attributes: [
                    .font: font(size, .medium, serif: false), .foregroundColor: NSColor(Theme.ink.opacity(0.5))])
                piece.append(inline(body, size: size, color: ink, serif: serif))
                add(piece, style: paragraph(spacing: size * 0.35, indent: size * 0.3, hanging: size * 1.5, line: line))
                continue
            }
            add(inline(trimmed, size: size, color: ink, serif: serif), style: paragraph(spacing: size * 0.25, line: line))
        }
        close()
        cache.setObject(Kept(parts), forKey: key)
        return parts
    }

    /// A plain message (your own) as attributed text.
    static func plain(_ text: String, size: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2.5
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor(Theme.ink.opacity(0.93)),
            .paragraphStyle: style])
    }
}

/// An answer drawn so that a selection can run through it and on into the
/// messages around it: its text in `SelectableText`, its pictures between.
struct SelectableAnswer: View {
    let text: String
    var size: CGFloat = 13

    var body: some View {
        let parts = MarkdownAttributed.parts(text, size: size, serif: AppSettings.shared.replySerif)
        VStack(alignment: .leading, spacing: size * 0.7) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let attributed):
                    SelectableText(text: attributed)
                case .media(let path):
                    GeneratedMedia(path: path)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
