import AppKit
import SwiftUI

/// The agent's work laid out step by step, as a transcript: a thin line
/// down the left with a dot for each step, each step titled by its tool and
/// what it was for, with what went in and what came out underneath. It is
/// what a folded work line opens to, and what shows live while the agent
/// works.
struct WorkRail: View {
    let steps: [WorkStep]
    /// The last step is still going.
    let working: Bool

    var body: some View {
        // Thinking is shown live above the chat box; chats saved before
        // that still hold it as a step, and it is left out here.
        let shown = steps.filter { $0.kind != .think }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, step in
                RailRow(step: step,
                        live: working && index == shown.count - 1,
                        first: index == 0,
                        last: index == shown.count - 1)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

/// One step on the rail: its dot, and what it was.
private struct RailRow: View {
    let step: WorkStep
    let live: Bool
    let first: Bool
    let last: Bool
    @EnvironmentObject var app: AppState
    /// The full result is shown under the line.
    @State private var open = false

    private static let dotTop: CGFloat = 6
    private static let dotSize: CGFloat = 7
    private static let railX: CGFloat = 3

    var body: some View {
        content
            .padding(.leading, 20)
            .padding(.bottom, last ? 0 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The line joins this dot to the next one.
            .background(alignment: .topLeading) {
                Rectangle()
                    .fill(Theme.ink.opacity(0.14))
                    .frame(width: 1)
                    .frame(maxHeight: last ? Self.dotTop : .infinity, alignment: .top)
                    .padding(.top, first ? Self.dotTop : 0)
                    .padding(.leading, Self.railX)
            }
            .overlay(alignment: .topLeading) {
                Group {
                    // The step at work breathes in Core Animation: as a
                    // SwiftUI animation it redrew the whole window every
                    // frame for as long as the step ran.
                    if live {
                        Pulse(kind: .breathe(low: 0.35), color: dotColor, size: Self.dotSize, period: 0.8)
                    } else {
                        Circle()
                            .fill(dotColor)
                            .frame(width: Self.dotSize, height: Self.dotSize)
                    }
                }
                .padding(.top, Self.dotTop - Self.dotSize / 2 + 1)
            }
    }

    private var dotColor: Color {
        if step.failed { return Theme.rose }
        if live { return Theme.accent }
        switch step.kind {
        case .think, .note: return Theme.ink.opacity(0.3)
        case .ask: return Theme.amber
        default: return Theme.mint.opacity(0.85)
        }
    }

    // MARK: What the step was

    @ViewBuilder
    private var content: some View {
        switch step.kind {
        case .think:
            Text("Thinking")
                .font(.system(size: WorkType.size))
                .foregroundStyle(Theme.ink.opacity(0.45))
        case .note:
            Text(step.title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink.opacity(0.9))
                .lineSpacing(3.9)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .ask:
            QuestionCard(step: step)
        case .edit:
            VStack(alignment: .leading, spacing: 6) {
                fileHeader
                if step.failed, let output = step.output {
                    TrailIOCard(input: nil, output: output)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                if hasCard {
                    compactHeader
                } else {
                    header
                }
                if hasCard, open {
                    TrailIOCard(input: input, output: step.output)
                        .transition(.opacity)
                }
            }
        }
    }

    /// A tool step's mark when it has no file to show.
    private var symbol: String {
        if let mark = step.mark { return mark.icon }
        switch step.kind {
        case .run: return "terminal"
        case .search: return "magnifyingglass"
        case .web: return "globe"
        default: return "doc.text"
        }
    }

    /// One line, the same height as the other steps: the verb quiet, what it
    /// worked on bright, a chevron that opens the full result, and a small
    /// thumbnail on the far right (laid over the line, so the row and the
    /// node line keep their size).
    private var compactHeader: some View {
        let isRead = step.kind == .read
        let name = isRead ? ((step.shownFile ?? subject) as NSString).lastPathComponent : (step.why ?? subject)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(isRead ? "Read" : tool)
                .foregroundStyle(Theme.ink.opacity(0.55))
            Text(name)
                .foregroundStyle(Theme.ink.opacity(0.92))
                .lineLimit(1)
                .truncationMode(isRead ? .middle : .tail)
            if step.failed {
                Text("failed")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.rose)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Theme.ink.opacity(0.4))
                .rotationEffect(.degrees(open ? 90 : 0))
            Spacer(minLength: 36)
        }
        .font(.system(size: WorkType.size))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } }
        // A fixed 18 pt tile, centred on the line: smaller than the 25 pt
        // between lines, so tiles on lines next to each other keep apart. Its
        // right edge is the rail's, 12 pt in from the card like the dots on
        // the left, so the tiles stand in one column.
        .overlay(alignment: .trailing) {
            if let file = step.shownFile, ThumbStrip.isFile(file) {
                StepThumb(path: file, size: 18, radius: 4, logo: 12)
            }
        }
        .help(open ? "Hide the result" : "Show the result")
    }

    /// The tool, in a word.
    private var tool: String {
        if let mark = step.mark { return mark.name }
        switch step.kind {
        case .run: return "Shell"
        case .read: return "Read"
        case .search: return step.title.hasPrefix("Delegated") ? "Helper" : "Search"
        case .web:
            if step.title.hasPrefix("Chrome") { return "Chrome" }
            if step.title.hasPrefix("Browser: ") { return "Browser" }
            return step.title.hasPrefix("Fetched") ? "Fetch" : "Web"
        case .edit: return step.title.hasPrefix("Wrote") ? "Write" : "Edit"
        case .open: return "Open"
        case .click: return "Click"
        case .type: return "Type"
        case .key: return "Key"
        case .skill: return "Skill"
        default: return "Step"
        }
    }

    /// What the step worked on, without the words around it.
    private var subject: String {
        if step.mark != nil { return step.markSubject }
        var text = step.title
        for verb in ["Chrome: ", "Browser: ", "Searched the web for ", "Fetched ", "Read ", "Searched ", "Wrote ", "Edited ", "Delegated ",
                     "Opened ", "Typed ", "Pressed "] where text.hasPrefix(verb) {
            text = String(text.dropFirst(verb.count))
            break
        }
        for tail in ["  (failed)", " (failed)"] where text.hasSuffix(tail) {
            text = String(text.dropLast(tail.count))
        }
        // A command's verdict is shown by the dot, not in its text.
        if step.kind == .run, let verdict = text.range(of: "  (", options: .backwards), text.hasSuffix(")") {
            text = String(text[..<verdict.lowerBound])
        }
        return text
    }

    private var hasCard: Bool {
        switch step.kind {
        case .run, .read, .search, .web: return true
        default: return false
        }
    }

    /// What went in: the command, or what was read, searched or fetched.
    private var input: String { subject }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(tool)
                .font(.system(size: WorkType.size, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.92))
            // Its purpose in words when the agent gave one; else what it was.
            Text(step.why ?? (hasCard ? "" : subject))
                .font(.system(size: WorkType.size))
                .foregroundStyle(Theme.ink.opacity(0.6))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if step.failed {
                Text("failed")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.rose)
            }
        }
    }

    /// Write `name` · 78 lines, or Edit `name` +12 −4: the name opens the
    /// file, the counts open what changed.
    private var fileHeader: some View {
        let path = step.path ?? subject
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(tool)
                    .font(.system(size: WorkType.size, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.92))
                Button { app.openInWorkspace(path) } label: {
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: WorkType.size, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("Open \(path)")
                if let added = step.added, let removed = step.removed {
                    Button { app.showLatestChange(of: path) } label: {
                        HStack(spacing: 4) {
                            if tool == "Write", removed == 0, let lines = step.lines {
                                Text("\(lines) lines").foregroundStyle(Theme.ink.opacity(0.55))
                            } else {
                                Text("+\(added)").foregroundStyle(Theme.mint)
                                Text("−\(removed)").foregroundStyle(Theme.rose)
                            }
                        }
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    }
                    .buttonStyle(.plain)
                    .help("See what changed")
                }
                if step.failed {
                    Text("failed")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.rose)
                }
            }
            if let why = step.why {
                Text(why)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink.opacity(0.55))
                    .lineLimit(2)
            }
        }
    }
}


/// A question the agent asked, kept in the reply with what was chosen.
private struct QuestionCard: View {
    let step: WorkStep

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Question")
                    .font(.system(size: WorkType.size, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.92))
                Text("Answered")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink.opacity(0.5))
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(step.title)
                    .font(.system(size: WorkType.size, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                let options = step.options ?? []
                // Who answered: the person, or the project's supervisor
                // in their place.
                let said = step.answeredBy == nil ? "You said" : "The supervisor said"
                if options.isEmpty {
                    Text("\(said): \(step.answer ?? "")")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink.opacity(0.7))
                } else {
                    ForEach(options, id: \.self) { option in
                        let chosen = option == step.answer
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 11))
                                .foregroundStyle(chosen ? Theme.accent : Theme.ink.opacity(0.35))
                            Text(option)
                                .font(.system(size: 12, weight: chosen ? .medium : .regular))
                                .foregroundStyle(Theme.ink.opacity(chosen ? 0.92 : 0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let answer = step.answer, !options.contains(answer) {
                        Text("\(said): \(answer)")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink.opacity(0.7))
                    }
                }
                if let who = step.answeredBy {
                    Text("Answered in your place by \(who)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.shade.opacity(0.32)))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .strokeBorder(Theme.ink.opacity(0.10), lineWidth: 0.5))
        }
    }
}

/// Where each request sits in the conversation, to know which to pin.
struct TurnFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Where each message bubble sits in the conversation, so a held message
/// starts sticking when it reaches the top and stops where its reply ends.
struct BubbleFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}


/// The agent's work as a chat app shows it: one card, a line for each step
/// in plain words (what it was for), and a click on a line opens what went
/// in and came out.
struct WorkCard: View {
    let steps: [WorkStep]
    /// The last step is still going.
    let working: Bool

    /// A line of the card: what was said along the way (lines next to each
    /// other kept together), or one step.
    private enum Line: Identifiable {
        case words(Int, [String])
        case step(Int, WorkStep)
        var id: Int {
            switch self {
            case .words(let index, _), .step(let index, _): return index
            }
        }
    }

    private var lines: [Line] {
        var lines: [Line] = []
        for (index, step) in steps.enumerated() {
            switch step.kind {
            case .think: continue
            case .note:
                if case .words(let start, let said)? = lines.last {
                    lines[lines.count - 1] = .words(start, said + [step.title])
                } else {
                    lines.append(.words(index, [step.title]))
                }
            default:
                lines.append(.step(index, step))
            }
        }
        return lines
    }

    var body: some View {
        let lines = self.lines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { position, line in
                    if position > 0 {
                        Rectangle().fill(Theme.ink.opacity(0.08)).frame(height: 1)
                    }
                    switch line {
                    case .words(_, let said):
                        WordsRow(said: said, open: working && position == lines.count - 1)
                    case .step(let index, let step):
                        CardRow(step: step, live: working && index == steps.count - 1)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).fill(Theme.ink.opacity(0.025)))
            .overlay(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                .strokeBorder(Theme.ink.opacity(0.11), lineWidth: 0.75))
            .padding(.top, 6)
        }
    }
}

/// What the agent said along the way: the latest line, which opens to all
/// of them.
private struct WordsRow: View {
    let said: [String]
    /// Open to begin with (the newest, while the agent works).
    var open: Bool
    @State private var chosen: Bool?
    private var showing: Bool { chosen ?? open }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(said.last ?? "")
                    .foregroundStyle(Theme.ink.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.ink.opacity(0.4))
                    .rotationEffect(.degrees(showing ? 90 : 0))
                Spacer(minLength: 0)
            }
            .font(.system(size: WorkType.size))
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { chosen = !showing } }
            if showing {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(said.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: WorkType.size))
                            .foregroundStyle(Theme.ink.opacity(0.62))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// One step in the card: a line of what it was; open, what went in and out.
private struct CardRow: View {
    let step: WorkStep
    let live: Bool
    @EnvironmentObject var app: AppState
    @State private var open = false
    @State private var hover = false

    /// What the step worked on, without the words around it.
    private var subject: String {
        if step.mark != nil { return step.markSubject }
        var text = step.title
        for verb in ["Chrome: ", "Browser: ", "Searched the web for ", "Fetched ", "Read ", "Searched ", "Wrote ", "Edited ", "Delegated ",
                     "Opened ", "Typed ", "Pressed "] where text.hasPrefix(verb) {
            text = String(text.dropFirst(verb.count))
            break
        }
        for tail in ["  (failed)", " (failed)"] where text.hasSuffix(tail) {
            text = String(text.dropLast(tail.count))
        }
        if step.kind == .run, let verdict = text.range(of: "  (", options: .backwards), text.hasSuffix(")") {
            text = String(text[..<verdict.lowerBound])
        }
        return text
    }

    private var file: String { ((step.path ?? subject) as NSString).lastPathComponent }

    /// A new file: written whole, nothing taken out.
    private var created: Bool {
        step.title.hasPrefix("Wrote") && (step.removed ?? 0) == 0
    }

    /// The line, in plain words: what it was for when the agent said, else what it was.
    private var title: String {
        if let why = step.why, !why.isEmpty, step.kind != .edit { return why }
        if let mark = step.mark { return "\(mark.verb) \(step.markSubject)" }
        switch step.kind {
        case .run: return "Ran a command"
        case .read: return "Read \(file)"
        case .search: return step.title.hasPrefix("Delegated") ? "A helper looked into it" : "Searched for \(subject)"
        case .web:
            if step.title.hasPrefix("Browser: ") { return "In the browser: \(subject)" }
            if step.title.hasPrefix("Chrome: ") { return "In Chrome: \(subject)" }
            return step.title.hasPrefix("Fetched") ? "Read \(URL(string: subject)?.host ?? subject)" : "Searched the web for \(subject)"
        case .skill: return "Used the \(step.title) skill"
        case .ask: return step.title
        default: return step.title
        }
    }

    private var hasDetail: Bool {
        switch step.kind {
        case .run, .read, .search, .web, .ask: return true
        case .edit: return step.why != nil || step.failed
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Aligned on the first line of text, so when the line wraps the
            // mark and the chevron stay up beside its start.
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if live {
                    LoadingMark(state: .working, size: 11)
                        .alignmentGuide(.firstTextBaseline) { $0.height / 2 + 4 }
                }
                if step.kind == .edit {
                    Text(created ? "Created" : "Edited")
                        .foregroundStyle(Theme.ink.opacity(0.6))
                    Button { app.openInWorkspace(step.path ?? subject) } label: {
                        Text(file)
                            .fontWeight(.medium)
                            .foregroundStyle(Theme.ink.opacity(0.95))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(step.path ?? subject)")
                    if let added = step.added, let removed = step.removed, !created {
                        Button { app.showLatestChange(of: step.path ?? subject) } label: {
                            HStack(spacing: 4) {
                                Text("+\(added)").foregroundStyle(Theme.mint)
                                Text("−\(removed)").foregroundStyle(Theme.rose)
                            }
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        .buttonStyle(.plain)
                        .help("See what changed")
                    }
                } else {
                    Text(title)
                        .foregroundStyle(Theme.ink.opacity(0.75))
                        .lineLimit(open ? 3 : 1)
                        .truncationMode(.tail)
                }
                if step.failed {
                    Text("failed")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.rose)
                }
                if hasDetail {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.ink.opacity(0.4))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: WorkType.size))
            .contentShape(Rectangle())
            .onTapGesture {
                guard hasDetail else { return }
                withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
            }
            if open {
                detail
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.ink.opacity(hover && hasDetail && !open ? 0.035 : 0))
        .onHover { hover = $0 }
    }

    @ViewBuilder
    private var detail: some View {
        switch step.kind {
        case .ask:
            QuestionCard(step: step)
        case .edit:
            if let why = step.why {
                Text(why)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink.opacity(0.6))
            }
            if step.failed, let output = step.output {
                TrailIOCard(input: nil, output: output)
            }
        default:
            TrailIOCard(input: subject, output: step.output)
        }
    }
}


/// The work card's one text size, the same as the small facts beside the
/// chat (the context meter), so the work reads as a quiet aside under
/// what was said, not as part of the conversation.
enum WorkType {
    static let size: CGFloat = 11
}

extension WorkStep {
    /// The file a read, write or edit was about, from its path or its title
    /// ("Read Sources/a.swift:40-90" gives "Sources/a.swift").
    var shownFile: String? {
        guard kind == .read || kind == .edit else { return nil }
        if let path, !path.isEmpty { return (path as NSString).expandingTildeInPath }
        var text = title
        for verb in ["Read ", "Wrote ", "Edited "] where text.hasPrefix(verb) {
            text = String(text.dropFirst(verb.count))
            break
        }
        if let failed = text.range(of: " (failed") { text = String(text[..<failed.lowerBound]) }
        text = text.trimmingCharacters(in: .whitespaces)
        if let colon = text.range(of: ":", options: .backwards) {
            let lines = text[colon.upperBound...]
            if !lines.isEmpty, lines.allSatisfy({ $0.isNumber || $0 == "-" }) {
                text = String(text[..<colon.lowerBound])
            }
        }
        return text.isEmpty ? nil : (text as NSString).expandingTildeInPath
    }

    /// The files the steps read or made, each once, in the order first met.
    static func files(in steps: [WorkStep]) -> [String] {
        var seen = Set<String>()
        var list: [String] = []
        for step in steps {
            if let file = step.shownFile, seen.insert(file).inserted { list.append(file) }
        }
        return list
    }
}

/// A step's small rounded thumbnail: the picture itself for an image, the
/// file-type icon for any other file, or the tool's mark when there is no
/// file. A click opens the file in the same preview as an attachment.
struct StepThumb: View {
    var path: String?
    var symbol = "doc.text"
    var size: CGFloat = 28
    /// How round the tile's corners are.
    var radius: CGFloat = 6
    /// The file-type logo's size; when not given, 60% of the tile.
    var logo: CGFloat? = nil
    /// Pictures already read, made small, so scrolling never reads a file again.
    private static let cache = NSCache<NSString, NSImage>()

    private var exists: Bool {
        guard let path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private var picture: NSImage? {
        guard let path, exists, Previewer.pictures.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        if let kept = Self.cache.object(forKey: path as NSString) { return kept }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 128] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let image = NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
        Self.cache.setObject(image, forKey: path as NSString)
        return image
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if let picture {
                Color.clear
                    .frame(width: size, height: size)
                    .overlay(
                        Image(nsImage: picture)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size, height: size)
                    )
                    .clipped()
            } else if let path {
                FileIcon(name: (path as NSString).lastPathComponent, size: logo ?? size * 0.6)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .background(shape.fill(Theme.ink.opacity(0.08)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.ink.opacity(0.16), lineWidth: 0.5))
        .contentShape(shape)
        .onTapGesture {
            guard let path, exists else { return }
            Previewer.shared.open(Attachment(name: (path as NSString).lastPathComponent, text: "", path: path))
        }
        .allowsHitTesting(exists)
        .help(path.map { "Open \(($0 as NSString).lastPathComponent)" } ?? "")
    }
}

/// The files behind a folded line: "+N" in secondary text when there are
/// more than three, then the last three as small thumbnails.
struct ThumbStrip: View {
    let paths: [String]
    var size: CGFloat = 22

    /// A file that is there on disk (not a folder): only these get a thumbnail.
    static func isFile(_ path: String) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && !folder.boolValue
    }

    var body: some View {
        let files = paths.filter(Self.isFile)
        if !files.isEmpty {
            HStack(spacing: 4) {
                if files.count > 3 {
                    Text("+\(files.count - 3)")
                        .font(.system(size: WorkType.size, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink.opacity(0.5))
                        .lineLimit(1)
                        .fixedSize()
                }
                ForEach(files.suffix(3), id: \.self) { path in
                    StepThumb(path: path, size: size)
                        .frame(width: size, height: size)
                        .clipped()
                }
            }
            .frame(height: size)
            .fixedSize()
            .clipped()
        }
    }
}
