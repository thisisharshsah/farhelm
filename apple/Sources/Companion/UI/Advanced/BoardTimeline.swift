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
                .padding(.leading, Self.labelWidth + 8)
                .padding(.trailing, 14)
                .padding(.top, 10)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { item in
                        row(item, start: shown.start, length: length, now: now)
                    }
                }
                .padding(.bottom, 20)
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
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(Theme.ink.opacity(0.45))
        .frame(height: 18)
    }

    private func row(_ item: WorkItem, start: Date, length: TimeInterval, now: Date) -> some View {
        let selected = advanced.selectedItem == item.id
        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                Text(item.key)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                Text(item.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: Self.labelWidth, alignment: .leading)
            GeometryReader { geometry in
                track(item, start: start, length: length, now: now, width: geometry.size.width)
            }
            .frame(height: Self.rowHeight)
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .background(Theme.ink.opacity(selected ? 0.10 : 0))
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
        case .running: return Theme.accent
        case .succeeded: return Theme.mint
        case .failed: return Theme.rose
        case .stopped: return Theme.ink.opacity(0.45)
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
                .fill(Theme.ink.opacity(0.06))
                .frame(height: 1)
            // Waiting: from being made to being started (or to now).
            Capsule()
                .fill(Theme.ink.opacity(0.16))
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
                    .fill(Theme.amber)
                    .frame(width: 1.5, height: 16)
                    .offset(x: place(due, start: start, length: length, width: width))
            }
        }
        .frame(width: width, height: Self.rowHeight, alignment: .leading)
    }

    private func key(_ tint: Color, _ text: String, tall: Bool = false) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(tint).frame(width: 14, height: tall ? 9 : 4)
            Text(text)
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            key(Theme.ink.opacity(0.2), "Waiting")
            key(Theme.accent.opacity(0.35), "Worked on", tall: true)
            key(Theme.accent, "Run going on")
            key(Theme.mint, "Run finished")
            key(Theme.rose, "Run failed")
            Spacer()
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.ink.opacity(0.5))
        .padding(.horizontal, 12)
        .frame(height: 26)
    }
}
