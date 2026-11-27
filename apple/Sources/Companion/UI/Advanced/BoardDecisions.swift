import CompanionBoard
import SwiftUI

/// The board's decision log: what the automatic reviewer decided about
/// each task, newest first, one line of reason each, with the model that
/// decided and when. It is read from `Board.decisions`, which only
/// `Board.decide` writes, so every decision shown here was carried out.
struct BoardDecisions: View {
    @ObservedObject private var advanced = Advanced.shared
    let board: Board

    var body: some View {
        if board.decisions.isEmpty {
            ContentUnavailableView {
                Label("No decisions yet", systemImage: "list.bullet.clipboard")
            } description: {
                Text(board.settings.autoReview
                     ? "When a run finishes, the PM reviews it and its decision is written here."
                     : "Automatic Review is off in Board Settings, so finished runs wait for you.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Design.Space.xxs) {
                    ForEach(board.decisions.reversed()) { entry in
                        row(entry)
                    }
                }
                .padding(.horizontal, Design.Space.s)
                .padding(.vertical, Design.Space.xs)
            }
        }
    }

    private func row(_ entry: DecisionEntry) -> some View {
        let task = board.item(number: entry.item)
        let selected = task.map { advanced.selectedItem == $0.id } ?? false
        return HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
            DecisionPill(decision: entry.decision)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Design.Space.xxs) {
                    Text(entry.task)
                        .font(Design.TextRole.caption.font.monospaced().weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Text(task?.title ?? "Taken off the board")
                        .textRole(.label, .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(entry.reason)
                    .textRole(.caption, .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Design.Space.xs)
            VStack(alignment: .trailing, spacing: 2) {
                Text(BoardText.modelName(entry.model))
                    .textRole(.caption, .secondary)
                    .lineLimit(1)
                Text(BoardText.when(entry.date))
                    .textRole(.number, .tertiary)
            }
        }
        .padding(Design.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? AnyShapeStyle(Design.Tone.accent.color.opacity(0.16)) : AnyShapeStyle(Design.Fill.raised.style),
                    in: Design.Radius.shape(Design.Radius.tile))
        .contentShape(Rectangle())
        .onTapGesture {
            guard let task else { return }
            advanced.selectedItem = selected ? nil : task.id
        }
        .help("\(entry.task): \(entry.decision.title). \(entry.reason)")
    }
}

/// A decision as a filled pill with its word, so it never reads by colour
/// alone. Its width is fixed so the log's columns line up.
private struct DecisionPill: View {
    let decision: ReviewDecision

    private var tone: Design.Tone {
        switch decision {
        case .approve: return .positive
        case .sendBack, .askOwner: return .caution
        case .reassign: return .accent
        case .hold: return .neutral
        case .stopAndReplan: return .critical
        }
    }

    var body: some View {
        Text(decision.title)
            .font(Design.TextRole.caption.font.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, Design.Space.xs)
            .padding(.vertical, 2)
            .frame(width: 118)
            .background(tone.color, in: Capsule())
    }
}