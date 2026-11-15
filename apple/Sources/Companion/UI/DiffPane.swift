import SwiftUI

/// Two versions of a text to compare in the middle of the workspace: a
/// file before and after the agent's edits, or as git has it and as it is
/// now.
struct DiffDocument: Equatable {
    /// The file, as its name is shown.
    var title: String
    /// What is being compared, in a few words.
    var subtitle: String
    var before: String
    var after: String
    /// The file itself, when it can be opened.
    var path: String?
}

/// One block of change: lines taken out of the earlier text and lines put
/// in at the same place, as ranges of lines (from 0, end not included).
struct DiffHunk: Identifiable, Equatable {
    let id: Int
    let before: Range<Int>
    let after: Range<Int>

    private static func lines(_ text: String) -> [String] {
        text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    /// The blocks of change between two texts, top to bottom.
    static func hunks(before: String, after: String) -> [DiffHunk] {
        let old = lines(before), new = lines(after)
        guard old.count <= 6000, new.count <= 6000 else { return [] }
        var removed = Set<Int>(), added = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        var hunks: [DiffHunk] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if (i < old.count && removed.contains(i)) || (j < new.count && added.contains(j)) {
                let a = i, b = j
                var moved = true
                while moved {
                    moved = false
                    while i < old.count, removed.contains(i) { i += 1; moved = true }
                    while j < new.count, added.contains(j) { j += 1; moved = true }
                }
                hunks.append(DiffHunk(id: hunks.count, before: a..<i, after: b..<j))
            } else {
                // A line both have: the two step on together.
                i += 1
                j += 1
            }
        }
        return hunks
    }

    /// The later text with this one block put back as it was.
    func revert(before: String, after: String) -> String {
        let old = Self.lines(before), new = Self.lines(after)
        guard self.before.upperBound <= old.count, self.after.upperBound <= new.count else { return after }
        let result = Array(new[..<self.after.lowerBound]) + Array(old[self.before]) + Array(new[self.after.upperBound...])
        return result.joined(separator: "\n")
    }

    /// Whether a line, by its number from 1 on either side, is in this block.
    func holds(before line: Int?) -> Bool { line.map { before.contains($0 - 1) } ?? false }
    func holds(after line: Int?) -> Bool { line.map { after.contains($0 - 1) } ?? false }
}

/// One line across the two sides: what was there on the left, what is
/// there now on the right. A line that only one side has leaves the other
/// side empty, so the two stay level all the way down.
struct DiffPair: Identifiable {
    enum Kind { case same, changed, gap }

    let id: Int
    let kind: Kind
    var left: (number: Int, text: String)?
    var right: (number: Int, text: String)?

    /// Lines side by side, made from a line-by-line comparison: lines
    /// taken out and lines put in at the same place are set against each
    /// other.
    static func pairs(before: String, after: String) -> [DiffPair] {
        var pairs: [DiffPair] = []
        var removed: [LineDiff.Row] = []
        var added: [LineDiff.Row] = []

        func flush() {
            for index in 0..<max(removed.count, added.count) {
                var pair = DiffPair(id: pairs.count, kind: .changed)
                if index < removed.count { pair.left = (removed[index].before ?? 0, removed[index].text) }
                if index < added.count { pair.right = (added[index].after ?? 0, added[index].text) }
                pairs.append(pair)
            }
            removed = []
            added = []
        }

        for row in LineDiff.rows(before: before, after: after, context: 4) {
            switch row.kind {
            case .removed:
                removed.append(row)
            case .added:
                added.append(row)
            case .same:
                flush()
                pairs.append(DiffPair(id: pairs.count, kind: .same,
                                      left: (row.before ?? 0, row.text), right: (row.after ?? 0, row.text)))
            case .gap:
                flush()
                pairs.append(DiffPair(id: pairs.count, kind: .gap))
            }
        }
        flush()
        return pairs
    }
}

/// The comparison itself, where an open file would be: before on the left
/// and now on the right, level with each other, or the two run together
/// as one list of what changed.
struct DiffPane: View {
    let document: DiffDocument
    /// Opens the file itself, when there is one.
    var open: (() -> Void)?
    let close: () -> Void
    /// Puts one block of change back as it was, in the file itself.
    var revert: ((DiffHunk) -> Void)? = nil

    /// Side by side, or as one list. Kept between comparisons.
    @AppStorage("diffSideBySide") private var sideBySide = true
    @State private var pairs: [DiffPair] = []
    @State private var rows: [LineDiff.Row] = []
    @State private var counts = (added: 0, removed: 0)
    @State private var ready = false
    /// The blocks of change, and the line each starts on, where its Undo
    /// button goes (by the pair's id side by side, the row's in one list).
    @State private var hunkAtPair: [Int: DiffHunk] = [:]
    @State private var hunkAtRow: [Int: DiffHunk] = [:]
    /// How much of the width Before has; the rest is Now's.
    @AppStorage("diffSplit") private var share: Double = 0.5
    @State private var width: CGFloat = 0

    /// Before's width, leaving each side enough to read.
    private var leftWidth: CGFloat? {
        guard width > 260 else { return nil }
        return min(max(width * CGFloat(share), 120), width - 120)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                IconButton("xmark", help: "Close this comparison", action: close)
                VStack(alignment: .leading, spacing: 0) {
                    Text(document.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.ink.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text(document.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ink.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("+\(counts.added)")
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.mint)
                Text("-\(counts.removed)")
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.rose)
                IconButton(sideBySide ? "rectangle.split.2x1" : "list.bullet",
                           help: sideBySide ? "Side by side. Click for one list of what changed."
                                            : "One list. Click for before and now side by side.",
                           tint: Theme.accent) {
                    sideBySide.toggle()
                }
                if let open {
                    IconButton("doc.text", help: "Open the file as it is now", action: open)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            Rectangle()
                .fill(Theme.ink.opacity(0.07))
                .frame(height: 1)
            if !ready {
                workspaceNote("Comparing...")
            } else if rows.isEmpty {
                workspaceNote("The two are the same, or this is not a text file.")
            } else if sideBySide {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        columnTitle("Before")
                            .frame(width: leftWidth)
                        Rectangle()
                            .fill(Theme.ink.opacity(0.09))
                            .frame(width: 1)
                        columnTitle("Now")
                    }
                    .frame(height: 20)
                    Rectangle()
                        .fill(Theme.ink.opacity(0.07))
                        .frame(height: 1)
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(pairs) { pair in
                                DiffPairRow(pair: pair, leftWidth: leftWidth)
                                    .overlay(alignment: .topTrailing) {
                                        if let hunk = hunkAtPair[pair.id], let revert {
                                            UndoHunkButton { revert(hunk) }
                                        }
                                    }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
                // The line between the sides, over the whole height: drag
                // it to give one side more room. Double-click for halves.
                .overlay(alignment: .topLeading) {
                    if let leftWidth {
                        HStack(spacing: 0) {
                            Color.clear
                                .frame(width: leftWidth)
                                .allowsHitTesting(false)
                            ColumnDivider(width: { leftWidth },
                                          direction: 1,
                                          resize: { share = Double(min(max($0, 120), width - 120) / width) },
                                          reset: { share = 0.5 },
                                          done: {})
                            Spacer(minLength: 0)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { width = geometry.size.width }
                            .onChange(of: geometry.size.width) { _, new in width = new }
                    }
                }
            } else {
                ScrollView([.vertical, .horizontal], showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            DiffLine(row: row)
                                .overlay(alignment: .topTrailing) {
                                    if let hunk = hunkAtRow[row.id], let revert {
                                        UndoHunkButton { revert(hunk) }
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The comparison is worked out once for each pair of texts, not
        // every time the view is drawn.
        .task(id: document) {
            ready = false
            let before = document.before
            let after = document.after
            guard before.utf8.count <= 800_000, after.utf8.count <= 800_000 else {
                pairs = []
                rows = []
                counts = (0, 0)
                ready = true
                return
            }
            rows = LineDiff.rows(before: before, after: after)
            pairs = DiffPair.pairs(before: before, after: after)
            // Where each block of change starts, for its Undo button.
            let hunks = DiffHunk.hunks(before: before, after: after)
            func hunk(before: Int?, after: Int?) -> DiffHunk? {
                hunks.first { $0.holds(before: before) || $0.holds(after: after) }
            }
            var seen = Set<Int>()
            var atPair: [Int: DiffHunk] = [:]
            for pair in pairs where pair.kind == .changed {
                if let found = hunk(before: pair.left?.number, after: pair.right?.number), seen.insert(found.id).inserted {
                    atPair[pair.id] = found
                }
            }
            seen = []
            var atRow: [Int: DiffHunk] = [:]
            for row in rows where row.kind == .added || row.kind == .removed {
                if let found = hunk(before: row.before, after: row.after), seen.insert(found.id).inserted {
                    atRow[row.id] = found
                }
            }
            hunkAtPair = atPair
            hunkAtRow = atRow
            counts = (rows.filter { $0.kind == .added }.count, rows.filter { $0.kind == .removed }.count)
            ready = true
        }
    }

    private func columnTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(Theme.ink.opacity(0.5))
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Undo" on the first line of a block of change: puts that block back as
/// it was in the file, leaving the rest of the change in place.
private struct UndoHunkButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label("Undo", systemImage: "arrow.uturn.backward")
                .font(.system(size: 10, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(hover ? Theme.accent : Theme.ink.opacity(0.7))
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule().fill(Theme.shade.opacity(0.85)))
                .overlay(Capsule().strokeBorder(Theme.ink.opacity(hover ? 0.3 : 0.14), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.trailing, 6)
        .padding(.top, 1)
        .help("Put this block back as it was, in the file. The rest of the change stays; Changes can redo it.")
    }
}

/// One line of the two sides. A long line wraps inside its own half, and
/// both halves are as tall as the taller one, so the sides never drift.
private struct DiffPairRow: View {
    let pair: DiffPair
    /// Before's width; nil shares the width evenly.
    var leftWidth: CGFloat?

    var body: some View {
        if pair.kind == .gap {
            Text("···")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.ink.opacity(0.35))
                .frame(maxWidth: .infinity)
                .frame(height: 16)
                .background(Theme.ink.opacity(0.03))
        } else {
            HStack(alignment: .top, spacing: 0) {
                cell(pair.left, tint: Theme.rose)
                    .frame(width: leftWidth)
                Rectangle()
                    .fill(Theme.ink.opacity(0.09))
                    .frame(width: 1)
                cell(pair.right, tint: Theme.mint)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cell(_ line: (number: Int, text: String)?, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(line.map { "\($0.number)" } ?? "")
                .foregroundStyle(Theme.ink.opacity(0.38))
                .frame(width: 30, alignment: .trailing)
            Text(line.map { $0.text.isEmpty ? " " : $0.text } ?? " ")
                .foregroundStyle(Theme.ink.opacity(pair.kind == .same ? 0.7 : 0.95))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Changed lines are colored; the side with nothing is left blank.
        .background(pair.kind == .changed
                    ? (line == nil ? Theme.ink.opacity(0.04) : tint.opacity(0.16))
                    : Color.clear)
    }
}
