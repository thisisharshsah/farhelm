import CompanionBoard
import SwiftUI

/// The board along a line of time: for each task, how long it waited, when
/// it was worked on and when it was done, with every run drawn on its
/// row. It shows at a glance what ran side by side, what is stuck, and
/// where the time went.
struct BoardTimeline: View {
    @ObservedObject private var advanced = Advanced.shared
    let project: Project
    let board: Board

    private static let labelWidth: CGFloat = 190
    private static let rowHeight: CGFloat = 26

    /// Tasks that have been worked on first, in the order work began;
    /// then the rest, by number.
    private var rows: [WorkItem] {
        let started = board.items.filter { $0.startedAt != nil }
            .sorted { ($0.startedAt ?? .distantPast, $0.number) < ($1.startedAt ?? .distantPast, $1.number) }
        let waiting = board.items.filter { $0.startedAt == nil }.sorted { $0.number < $1.number }
        return started + waiting
    }

    /// The stretch of time shown: from the first task's making to now (or
    /// the last thing that happened), never less than an hour.
    private func span(now: Date) -> (start: Date, end: Date) {
        let start = board.items.map(\.createdAt).min() ?? now
        let last = board.items.compactMap(\.finishedAt).max() ?? now
        let end = max(now, last)
        return end.timeIntervalSince(start) < 3_600 ? (start, start.addingTimeInterval(3_600)) : (start, end)
    }

    var body: some View {
        let now = Date()
        let shown = self.span(now: now)
        let length = shown.end.timeIntervalSince(shown.start)
        VStack(alignment: .leading, spacing: 0) {
            axis(shown.start, shown.end)
                .padding(.leading, Self.labelWidth + Design.Space.xs + Design.Space.s)
                .padding(.trailing, Design.Space.m)
                .padding(.top, Design.Space.xs)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { item in
                        row(item, start: shown.start, length: length, now: now)
                    }
                }
                .padding(.bottom, Design.Space.l)
            }
            legend
        }
    }

    /// The dates the line runs between, and its middle.
    private func axis(_ start: Date, _ end: Date) -> some View {
        let middle = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
        return HStack {
            Text(BoardText.when(start))
            Spacer()
            Text(BoardText.when(middle))
            Spacer()
            Text(BoardText.when(end))
        }
        .textRole(.number, .tertiary)
        .frame(minHeight: Design.Control.small.height)
    }

    private func row(_ item: WorkItem, start: Date, length: TimeInterval, now: Date) -> some View {
        let selected = advanced.selectedItem == item.id
        return HStack(spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.xxs) {
                Text(item.key)
                    .font(Design.TextRole.caption.font.monospaced().weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text(item.title)
                    .textRole(.label, .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: Self.labelWidth, alignment: .leading)
            GeometryReader { geometry in
                track(item, start: start, length: length, now: now, width: geometry.size.width)
            }
            .frame(height: Self.rowHeight)
        }
        .padding(.leading, Design.Space.s)
        .padding(.trailing, Design.Space.m)
        .background(selected ? AnyShapeStyle(Design.Tone.accent.color.opacity(0.16)) : AnyShapeStyle(Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { advanced.selectedItem = selected ? nil : item.id }
        .help("\(item.key) \(item.title)\n\(item.status.title)" + (item.runs.isEmpty ? "" : ", \(item.runs.count) \(item.runs.count == 1 ? "run" : "runs")"))
    }

    /// Where a moment falls along a track of a given width.
    private func place(_ date: Date, start: Date, length: TimeInterval, width: CGFloat) -> CGFloat {
        guard length > 0 else { return 0 }
        return CGFloat(min(max(date.timeIntervalSince(start) / length, 0), 1)) * width
    }

    private func runTint(_ run: WorkRun) -> Color {
        switch run.outcome {
        case .running: return Design.Tone.accent.color
        case .succeeded: return Design.Tone.positive.color
        case .failed: return Design.Tone.critical.color
        case .stopped: return Design.Tone.neutral.color
        }
    }

    private func track(_ item: WorkItem, start: Date, length: TimeInterval, now: Date, width: CGFloat) -> some View {
        let made = place(item.createdAt, start: start, length: length, width: width)
        let began = item.startedAt.map { place($0, start: start, length: length, width: width) }
        // Work goes on until the task is done; one that is open runs to now.
        let ended = place(item.finishedAt ?? now, start: start, length: length, width: width)
        return ZStack(alignment: .leading) {
            // The whole row's line, faint.
            Rectangle()
                .fill(Design.Fill.line.style)
                .frame(height: 1)
            // Waiting: from being made to being started (or to now).
            Capsule()
                .fill(Design.Tone.neutral.color.opacity(0.4))
                .frame(width: max(2, (began ?? ended) - made), height: 3)
                .offset(x: made)
            // Worked on: from the start to being done (or to now).
            if let began {
                Capsule()
                    .fill(item.status.tint.opacity(0.35))
                    .frame(width: max(3, ended - began), height: 11)
                    .offset(x: began)
            }
            // Each run, on top, in the color of how it ended.
            ForEach(item.runs) { run in
                let from = place(run.startedAt, start: start, length: length, width: width)
                let to = place(run.endedAt ?? now, start: start, length: length, width: width)
                Capsule()
                    .fill(runTint(run))
                    .frame(width: max(3, to - from), height: 6)
                    .offset(x: from)
            }
            // The day it is wanted by.
            if let due = item.dueAt, due >= start, due <= start.addingTimeInterval(length) {
                Rectangle()
                    .fill(Design.Tone.caution.color)
                    .frame(width: 1.5, height: Design.Space.m)
                    .offset(x: place(due, start: start, length: length, width: width))
            }
        }
        .frame(width: width, height: Self.rowHeight, alignment: .leading)
    }

    private func key(_ tint: Color, _ text: String, tall: Bool = false) -> some View {
        HStack(spacing: Design.Space.xxs) {
            Capsule().fill(tint)
                .frame(width: Design.Icon.small.width, height: tall ? Design.Space.xs : Design.Space.xxs)
            Text(text)
        }
    }

    private var legend: some View {
        HStack(spacing: Design.Space.s) {
            key(Design.Tone.neutral.color.opacity(0.4), "Waiting")
            key(Design.Tone.accent.color.opacity(0.35), "Worked on", tall: true)
            key(Design.Tone.accent.color, "Run going on")
            key(Design.Tone.positive.color, "Run finished")
            key(Design.Tone.critical.color, "Run failed")
            Spacer()
        }
        .textRole(.caption, .secondary)
        .padding(.horizontal, Design.Space.s)
        .frame(minHeight: Design.Control.regular.height)
        .glassToolbarGroup()
    }
}
