import CompanionBoard
import SwiftUI

/// The board as columns, one for each status. A card is dragged to another
/// column to change its task's status, or onto another card to sit above it.
struct BoardKanban: View {
    let project: Project
    let board: Board
    let ledger: Ledger

    private static let columnLeast: CGFloat = 204
    private static let gap: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            // Five columns share the width; in a narrow pane each keeps
            // its least and the row scrolls sideways.
            let count = CGFloat(WorkStatus.allCases.count)
            let room = geometry.size.width - 20 - Self.gap * (count - 1)
            let width = max(Self.columnLeast, room / count)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(WorkStatus.allCases) { status in
                        BoardColumn(project: project, board: board, ledger: ledger, status: status)
                            .frame(width: width)
                    }
                }
                .padding(10)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
    }
}

/// One status's column: its name and count, then its tasks, top to bottom.
private struct BoardColumn: View {
    @ObservedObject private var advanced = Advanced.shared
    let project: Project
    let board: Board
    let ledger: Ledger
    let status: WorkStatus
    /// A card is being dragged over this column.
    @State private var targeted = false

    private var overLimit: Bool { status == .inProgress && board.overWipLimit }

    var body: some View {
        let items = board.items(in: status)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                WorkStatusPill(status: status)
                Text("\(items.count)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(overLimit ? Theme.amber : Theme.ink.opacity(0.5))
                if overLimit, let limit = board.settings.wipLimit {
                    Text("of \(limit)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.amber)
                }
                Spacer(minLength: 2)
                if status == .backlog || status == .todo {
                    IconButton("plus", help: "Add a task to \(status.title)") {
                        advanced.selectedItem = advanced.addTask(BoardRules.newTaskTitle, status: status, in: project.id)
                    }
                }
            }
            .frame(height: 26)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(items) { item in
                        TaskCard(project: project, board: board, item: item, used: ledger.total(of: item))
                            .draggable(item.id.uuidString)
                            // Dropped on a card: the dragged task goes just above it.
                            .dropDestination(for: String.self) { dropped, _ in
                                drop(dropped, above: item.id)
                            }
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
            .fill(targeted ? status.tint.opacity(0.14) : Theme.ink.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
            .strokeBorder(targeted ? status.tint.opacity(0.6) : Theme.ink.opacity(0.06), lineWidth: 1))
        .contentShape(Rectangle())
        // Dropped on the column itself: to its foot.
        .dropDestination(for: String.self) { dropped, _ in
            drop(dropped, above: nil)
        } isTargeted: { over in
            targeted = over
        }
        .animation(.easeOut(duration: 0.12), value: targeted)
    }

    private func drop(_ dropped: [String], above other: UUID?) -> Bool {
        guard let id = dropped.first.flatMap(UUID.init(uuidString:)), board.item(id) != nil, id != other else {
            return false
        }
        advanced.move(id, to: status, above: other, in: project.id)
        return true
    }
}

/// A task as a card: what it is, how much it matters, the model it is
/// given to, what it has used against what was expected, and, while a run
/// is going on, what the agent is doing.
struct TaskCard: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var advanced = Advanced.shared
    let project: Project
    let board: Board
    let item: WorkItem
    let used: UsageTotal
    @State private var hover = false

    private var selected: Bool { advanced.selectedItem == item.id }
    private var blockers: [WorkItem] { board.blockers(of: item) }
    /// The agent at work on this task, when one is.
    private var job: AgentJob? { item.activeRun.flatMap { app.jobs[$0.conversation] } }
    /// It waits for a yes or an answer that nobody gives in the person's
    /// place (the supervisor may be answering).
    private var waitingOnPerson: Bool { job?.waitsOnPerson ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(item.key)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                PriorityMark(priority: item.priority)
                Image(systemName: item.kind.icon)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                    .help(item.kind.title)
                if let milestone = item.milestone {
                    Text(milestone)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.ink.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                if let copy = item.workingCopy, copy.isOpen {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Theme.ink.opacity(0.45))
                        .help("Works in a copy of its own, on \(copy.branch), made from \(copy.base)")
                }
                if !blockers.isEmpty, item.status != .done {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Theme.amber)
                        .help("Waits on " + blockers.map(\.key).joined(separator: ", "))
                }
            }
            Text(item.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(item.status == .done ? 0.6 : 0.95))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.activeRun != nil {
                runLine
            } else if advanced.checkingWork.contains(item.id) {
                statusLine("Running its checks", mark: .working)
            } else if advanced.reviewing.contains(item.id) {
                statusLine("The supervisor is reviewing it", mark: .thinking)
            } else if advanced.preparing.contains(item.id) {
                statusLine("Readying its copy", mark: .working)
            } else if advanced.waitsForSlot(item.id, in: project.id) {
                HStack(spacing: 5) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.amber)
                    Text(RunLimit.waitingWords)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.amber)
                        .lineLimit(1)
                }
                .help("In line: it starts by itself when a slot frees, most pressing first (" + advanced.runLimit.reason + ").")
            } else if advanced.merging.contains(item.id) {
                statusLine("Merging its work", mark: .working)
            } else if board.mergeWaitsOnPerson(item) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.amber)
                    Text("Not merged")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.amber)
                        .lineLimit(1)
                }
                .help(item.workingCopy?.problem ?? "Nobody approved its work to be merged")
            } else if item.status == .review, let checks = item.runs.last?.checks, !Checks.letThrough(checks) {
                let failed = checks.filter { !$0.passed }
                HStack(spacing: 5) {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.rose)
                    Text(failed.count == 1 ? "\(failed[0].name) did not pass" : "\(failed.count) checks did not pass")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.rose)
                        .lineLimit(1)
                }
                .help(failed.map { "\($0.name) \(Checks.status($0))" }.joined(separator: "\n"))
            }
            HStack(spacing: 6) {
                ModelChip(assignment: item.assignment, limit: 18)
                Spacer(minLength: 2)
                tokens
            }
            if hover || selected {
                actions
                    .transition(.opacity)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .fill(Theme.shade.opacity(Theme.isLight ? 0.55 : 0.30)))
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .fill(Theme.ink.opacity(hover ? 0.07 : 0.04)))
        .glassBorder(radius: Theme.controlRadius, tint: selected ? Theme.accent : (waitingOnPerson ? Theme.amber : nil))
        .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        .onTapGesture { advanced.selectedItem = selected ? nil : item.id }
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.key), \(item.title), \(item.status.title), \(item.priority.title) priority")
    }

    /// What the agent is doing right now, or that it waits on the person.
    private var runLine: some View {
        Group {
            if waitingOnPerson {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.amber)
                    Text(job?.pendingQuestion != nil ? "Has a question for you" : "Waits for your OK")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.amber)
                        .lineLimit(1)
                }
            } else if job?.supervisorAnswering == true {
                statusLine("The supervisor is answering", mark: .thinking)
            } else {
                statusLine(job?.status ?? "Working", mark: .working)
            }
        }
    }

    private func statusLine(_ text: String, mark: LoadingMark.Phase) -> some View {
        HStack(spacing: 5) {
            LoadingMark(state: mark, size: 11)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink.opacity(0.62))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// Tokens used, against the estimate when there is one.
    private var tokens: some View {
        let estimate = item.estimateTokens ?? 0
        let over = estimate > 0 && used.tokens > estimate
        return Group {
            if used.isEmpty, estimate == 0 {
                EmptyView()
            } else {
                Text(used.isEmpty ? "est \(ContextUse.short(estimate))"
                     : (estimate > 0 ? "\(BoardText.tokens(used)) / \(ContextUse.short(estimate))" : BoardText.tokens(used)))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(over ? Theme.amber : Theme.ink.opacity(0.5))
                    .lineLimit(1)
                    .help(used.isEmpty
                          ? "Expected to take about \(ContextUse.short(estimate)) tokens."
                          : "Used \(BoardText.tokens(used)) tokens (\(Money.text(used.cost)))"
                            + (estimate > 0 ? " of an expected \(ContextUse.short(estimate))." : "."))
            }
        }
    }

    /// What can be done with the task from its card. Where the supervisor
    /// has looked at a finished run for the person who reviews it, the
    /// answer it recommends says so.
    private var actions: some View {
        HStack(alignment: .top, spacing: 5) {
            if let run = item.activeRun {
                BoardButton(waitingOnPerson ? "Answer" : "Open", icon: "bubble.left", tint: waitingOnPerson ? Theme.amber : nil) {
                    app.openConversation(run.conversation)
                }
                .help("Open the chat this run works in")
                BoardButton("Stop", icon: "stop.fill", tint: Theme.rose) { advanced.stop(item.id, in: project.id) }
            } else if item.status == .review {
                let advised = item.runs.last?.advice
                let redo = advised?.verdict == .changesRequested
                BoardButton("Approve", icon: "checkmark", tint: Theme.mint) { advanced.approve(item.id, in: project.id) }
                    .recommended(advised?.verdict == .approved, why: BoardText.why(advised))
                BoardButton("Redo", icon: "arrow.uturn.backward") {
                    // What the supervisor found goes to the next run.
                    advanced.requestChanges(item.id, notes: redo ? (advised?.notes ?? "") : "", in: project.id)
                }
                .help(redo ? "Send it back to To do, with what the supervisor found" : "Send it back to To do")
                .recommended(redo, why: BoardText.why(advised))
            } else if board.mergeWaitsOnPerson(item), !advanced.merging.contains(item.id) {
                BoardButton("Merge", icon: "arrow.triangle.merge", tint: Theme.amber) {
                    advanced.mergeNow(item.id, in: project.id)
                }
                .help((item.workingCopy?.problem.map { $0 + " " } ?? "") + "Merge its work now, as yours.")
            } else if item.status == .todo || item.status == .backlog, !advanced.preparing.contains(item.id) {
                BoardButton("Start", icon: "play.fill", tint: Theme.accent) {
                    advanced.startOrExplain(item.id, in: project.id)
                }
                .help(blockers.isEmpty ? "Start a run on this task with \(item.assignment?.label ?? "the model in use")"
                      : "Waits on " + blockers.map(\.key).joined(separator: ", "))
            }
            Spacer(minLength: 0)
            if let last = item.runs.last, !last.isRunning {
                BoardButton("", icon: "bubble.left") { app.openConversation(last.conversation) }
                    .help("Open the chat of the last run")
            }
        }
    }
}
