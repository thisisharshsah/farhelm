import AppKit
import SwiftUI
import WebKit

// The editor's frame, as in VS Code: the path bar over the file, a
// preview of pages, documents and pictures, the outline of a file's
// symbols and the timeline of its changes.

/// A type, function or property in a file, with where it starts (and ends,
/// when known) and how deep it sits.
struct CodeSymbol: Identifiable, Equatable {
    let id = UUID()
    let name: String
    /// The Language Server Protocol's kind number (5 class, 12 function...).
    let kind: Int
    let line: Int
    let endLine: Int?
    let depth: Int

    /// A letter and a color for the kind, as editors badge them.
    var badge: (letter: String, color: Color) {
        switch kind {
        case 5: return ("C", Theme.amber)            // class
        case 23: return ("S", Theme.amber)           // struct
        case 10: return ("E", Theme.amber)           // enum
        case 11: return ("P", Theme.lilac)           // protocol / interface
        case 2, 3, 4: return ("M", Theme.lilac)      // module, namespace, package
        case 6, 9: return ("m", Theme.accent)        // method, constructor
        case 12: return ("ƒ", Theme.accent)          // function
        case 7, 8: return ("p", Theme.mint)          // property, field
        case 13: return ("v", Theme.mint)            // variable
        case 14: return ("k", Theme.mint)            // constant
        case 22: return ("e", Theme.mint)            // enum member
        case 15: return ("#", Theme.ink.opacity(0.6)) // heading (Markdown)
        default: return ("•", Theme.ink.opacity(0.6))
        }
    }

    /// Symbols read from the text itself, for files with no language
    /// server: declarations by their keywords, headings in Markdown. Only
    /// the outline of the file, not every variable.
    static func scan(_ text: String, language: String) -> [CodeSymbol] {
        var found: [CodeSymbol] = []
        let lines = text.components(separatedBy: "\n")
        guard lines.count <= 40_000 else { return [] }
        if language == "md" || language == "markdown" {
            for (index, line) in lines.enumerated() where line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let title = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty, level <= 6 else { continue }
                found.append(CodeSymbol(name: title, kind: 15, line: index + 1, endLine: nil, depth: level - 1))
            }
            return found
        }
        let kinds: [String: Int] = [
            "class": 5, "struct": 23, "enum": 10, "protocol": 11, "interface": 11, "extension": 5, "actor": 5,
            "func": 12, "def": 12, "function": 12, "fn": 12, "trait": 11, "impl": 5, "type": 5, "module": 2
        ]
        let pattern = try? NSRegularExpression(
            pattern: #"^(\s*)(?:(?:public|private|internal|fileprivate|open|static|final|override|async|export|default|pub|mutating|@\w+(?:\([^)]*\))?)\s+)*(class|struct|enum|protocol|interface|extension|actor|func|def|function|fn|trait|impl|type|module)\s+([A-Za-z_][\w.]*)"#)
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = pattern?.firstMatch(in: line, range: range),
                  let indent = Range(match.range(at: 1), in: line),
                  let word = Range(match.range(at: 2), in: line),
                  let name = Range(match.range(at: 3), in: line) else { continue }
            let spaces = line[indent].reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            found.append(CodeSymbol(name: String(line[name]), kind: kinds[String(line[word])] ?? 0,
                                    line: index + 1, endLine: nil, depth: min(spaces / 4, 6)))
        }
        return found
    }
}

// MARK: - Path bar

/// Where the open file is, folder by folder, then the symbol the cursor is
/// in. A folder opens in the tree; the symbol goes to where it starts.
struct Breadcrumbs: View {
    @ObservedObject var model: WorkspaceModel
    let path: String

    var body: some View {
        let relative = model.relative(path)
        let parts = relative.components(separatedBy: "/").filter { !$0.isEmpty }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 { chevron }
                    let isFile = index == parts.count - 1
                    Button {
                        if !isFile {
                            let folder = (model.root as NSString)
                                .appendingPathComponent(parts[0...index].joined(separator: "/"))
                            model.revealInTree((folder as NSString).appendingPathComponent("_"))
                        }
                    } label: {
                        Text(part)
                            .font(.system(size: 11.5, weight: isFile ? .semibold : .regular))
                            .foregroundStyle(Theme.ink.opacity(isFile ? 0.92 : 0.6))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(isFile ? path : "Show this folder in the files")
                }
                if let symbol = model.currentSymbol {
                    chevron
                    Button { model.reveal = WorkspaceModel.Reveal(line: symbol.line) } label: {
                        HStack(spacing: 4) {
                            SymbolBadge(symbol: symbol)
                            Text(symbol.name)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.ink.opacity(0.75))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Go to where \(symbol.name) starts")
                }
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 7.5, weight: .bold))
            .foregroundStyle(Theme.ink.opacity(0.35))
    }
}

struct SymbolBadge: View {
    let symbol: CodeSymbol

    var body: some View {
        let badge = symbol.badge
        Text(badge.letter)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(badge.color)
            .frame(width: 14, height: 14)
            .background(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous).fill(badge.color.opacity(0.14)))
    }
}

// MARK: - Preview

/// A file as it looks: a web page drawn from the text being edited (so
/// unsaved changes show), Markdown formatted, anything else by Quick Look.
struct FilePreview: View {
    let path: String
    let text: String

    var body: some View {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm":
            HTMLPreview(html: text, base: URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true))
        case "md", "markdown":
            ScrollView(.vertical) {
                MarkdownNotes(text: text, size: 13)
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        default:
            QuickLookView(url: URL(fileURLWithPath: path))
        }
    }
}

/// A web page drawn from text, with its own folder as the base, so its
/// pictures and styles load.
private struct HTMLPreview: NSViewRepresentable {
    let html: String
    let base: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(html, baseURL: base)
        context.coordinator.shown = html
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.shown != html else { return }
        context.coordinator.shown = html
        view.loadHTMLString(html, baseURL: base)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown = ""
    }
}

// MARK: - Outline

/// The open file's symbols, nested; the one the cursor is in is marked,
/// and a click goes to where it starts.
struct OutlineView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        let current = model.currentSymbol?.id
        VStack(alignment: .leading, spacing: 0) {
            if model.openPath == nil {
                note("Open a file to see its outline.")
            } else if model.symbols.isEmpty {
                note("Nothing to outline in this file.")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.symbols) { symbol in
                            Button { model.reveal = WorkspaceModel.Reveal(line: symbol.line) } label: {
                                HStack(spacing: 6) {
                                    SymbolBadge(symbol: symbol)
                                    Text(symbol.name)
                                        .font(.system(size: 11.5, weight: symbol.id == current ? .semibold : .regular))
                                        .foregroundStyle(Theme.ink.opacity(symbol.id == current ? 0.95 : 0.78))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text("\(symbol.line)")
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(Theme.ink.opacity(0.35))
                                }
                                .padding(.leading, CGFloat(symbol.depth) * 12 + 8)
                                .padding(.trailing, 8)
                                .frame(height: 22)
                                .background(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                                    .fill(symbol.id == current ? Theme.accent.opacity(0.14) : Color.clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.ink.opacity(0.5))
            .padding(12)
    }
}

// MARK: - Timeline

/// Every change to the open file that Companion knows of, newest first: the
/// agent's edits and your saves. A click shows it side by side.
struct FileTimelineView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var history: ChangeStore

    var body: some View {
        let changes = model.openPath.map { path in history.changes.filter { $0.path == path } } ?? []
        VStack(alignment: .leading, spacing: 0) {
            if model.openPath == nil {
                note("Open a file to see its changes.")
            } else if changes.isEmpty {
                note("No changes to this file yet. Saves and the agent's edits show here.")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(changes) { change in
                            Button { show(change) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(change.task.isEmpty || change.task.hasPrefix("Edited by you") ? Theme.ink.opacity(0.4) : Theme.accent)
                                        .frame(width: 6, height: 6)
                                        .padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(change.task.isEmpty ? "Saved by you" : String(change.task.prefix(80)))
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(Theme.ink.opacity(0.85))
                                            .lineLimit(2)
                                        HStack(spacing: 6) {
                                            Text(change.date, format: .relative(presentation: .named))
                                            Text("+\(change.added)").foregroundStyle(Theme.mint)
                                            Text("−\(change.removed)").foregroundStyle(Theme.rose)
                                            if let commit = change.commit {
                                                Text(commit).font(.system(size: 9.5, design: .monospaced))
                                            }
                                        }
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.ink.opacity(0.45))
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("See this change side by side")
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func show(_ change: FileChange) {
        model.showDiff(DiffDocument(
            title: model.relative(change.path),
            subtitle: change.date.formatted(date: .abbreviated, time: .shortened) + "  ·  " + (change.task.isEmpty ? "Saved by you" : change.task),
            before: history.text(change.before),
            after: history.text(change.after),
            path: FileManager.default.fileExists(atPath: change.path) ? change.path : nil))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.ink.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
    }
}
