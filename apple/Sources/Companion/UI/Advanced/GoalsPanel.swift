import CompanionBoard
import SwiftUI

/// A project's goals, opened from the goal at the top of the board: the
/// goal being worked toward, to read in full and put in other words; a
/// new goal to turn the board to; and the goals before it, each with its
/// tasks, how far it got and what it cost. Any of those can be gone back to.
struct GoalsPanel: View {
    @ObservedObject private var advanced = Advanced.shared
    let project: Project
    let board: Board
    let ledger: Ledger
    /// Opened to start a new goal, not to read the one there is.
    let startsNew: Bool
    let close: () -> Void

    /// The new goal's form is showing in place of the goal there is.
    @State private var starting = false
    /// The goal there is, as it is being reworded.
    @State private var words = ""
    /// The new goal, as it is being written.
    @State private var draft = ""
    /// The open tasks of the goal there is go to the new one.
    @State private var bring = false
    /// The earlier goal whose tasks are showing.
    @State private var expanded: UUID?
    /// The list's own height, measured, so the panel is only as tall as
    /// it needs up to `mostList`, and scrolls past that.
    @State private var listHeight: CGFloat = 0
    @FocusState private var typing: Bool

    private let mostList: CGFloat = 300

    /// There is a goal to keep: it has words, or work was planned for it.
    private var goalMade: Bool { !board.goal.isEmpty || !board.items.isEmpty }

    var body: some View {
        let used = board.usageByGoal(ledger)
        let earlier = board.earlierGoals
        VStack(alignment: .leading, spacing: Design.Space.s) {
            if starting {
                newGoal
            } else {
                current(used[board.currentGoal] ?? UsageTotal())
            }
            if !earlier.isEmpty {
                history(earlier, used: used)
            }
        }
        .padding(Design.Space.s)
        .frame(width: 400, alignment: .leading)
        .onAppear {
            words = board.goal
            starting = startsNew && goalMade
            typing = starting
        }
        .onChange(of: board.goal) { _, fresh in words = fresh }
    }

    // MARK: The goal being worked toward

    private func current(_ total: UsageTotal) -> some View {
        let progress = board.progress(of: board.currentGoal)
        let reworded = words.trimmingCharacters(in: .whitespacesAndNewlines) != board.goal
        return VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.xs) {
                BoardHeading(board.goals.count > 1 ? "Goal \(board.current.key)" : "Goal")
                if board.goalReached { GoalStatusPill(status: .reached) }
                Spacer(minLength: Design.Space.xs)
                if goalMade {
                    BoardButton("New goal", icon: "plus") {
                        starting = true
                        typing = true
                    }
                    .help("Turn the board to a new goal. This one is kept, with its tasks, and can be gone back to.")
                }
            }
            TextField("", text: $words, prompt: Text("What should this project achieve?").foregroundStyle(.tertiary), axis: .vertical)
                .lineLimit(2...8)
                .boardField()
            HStack(spacing: Design.Space.xs) {
                Text(Self.facts(progress: progress, total: total, days: ""))
                    .font(Design.TextRole.caption.font)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: Design.Space.xs)
                if reworded {
                    BoardButton("Save", prominent: true) {
                        advanced.setGoal(words, in: project.id)
                    }
                    .help("Keep these words for the goal. It stays the same goal, with its tasks.")
                }
            }
        }
    }

    /// "Nov 3 to Nov 9 · 4 of 6 done · 412k tokens · $3.10"
    fileprivate static func facts(progress: (done: Int, all: Int), total: UsageTotal, days: String) -> String {
        var parts: [String] = []
        if !days.isEmpty { parts.append(days) }
        parts.append(progress.all == 0 ? "no tasks" : "\(progress.done) of \(progress.all) done")
        if !total.isEmpty { parts.append("\(BoardText.tokens(total)) tokens · \(Money.text(total.cost))") }
        return parts.joined(separator: " · ")
    }

    // MARK: A new goal

    private var newGoal: some View {
        let stillOpen = board.unfinished.count
        let said = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: Design.Space.xs) {
            BoardHeading("New goal")
            TextField("", text: $draft, prompt: Text("What should this project achieve next?").foregroundStyle(.tertiary), axis: .vertical)
                .lineLimit(2...8)
                .boardField()
                .focused($typing)
            if stillOpen > 0 {
                Button {
                    bring.toggle()
                } label: {
                    HStack(spacing: Design.Space.xs) {
                        Image(systemName: bring ? "checkmark.square.fill" : "square")
                            .font(Design.TextRole.label.font.weight(.medium))
                            .foregroundStyle(bring ? AnyShapeStyle(Design.Tone.accent.color) : AnyShapeStyle(.secondary))
                        Text(stillOpen == 1 ? "Bring the 1 unfinished task along" : "Bring the \(stillOpen) unfinished tasks along")
                            .textRole(.label, .primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("The tasks of the goal there is that are not done move to the new goal. Left unticked, they stay with the goal they were planned for.")
            }
            Text(keptNote)
                .textRole(.caption, .secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Design.Space.xs) {
                Spacer(minLength: 0)
                BoardButton("Cancel") {
                    if startsNew { close() } else { starting = false }
                }
                BoardButton("Start") { start(plan: false) }
                    .opacity(said ? 1 : 0.45)
                    .disabled(!said)
                    .help("Turn the board to this goal. Plan it yourself, or ask the supervisor when you are ready.")
                BoardButton("Start and plan it", icon: "wand.and.stars", prominent: true) { start(plan: true) }
                    .opacity(said ? 1 : 0.45)
                    .disabled(!said)
                    .help("Turn the board to this goal and have the supervisor break it into tasks.")
            }
        }
    }

    /// What becomes of the goal there is.
    private var keptNote: String {
        let key = board.current.key
        return board.goalReached
            ? "\(key) is kept as reached, with its tasks. You can look at it here and go back to it at any time."
            : "\(key) is kept as set aside, with its tasks. You can look at it here and go back to it at any time."
    }

    private func start(plan: Bool) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let carry = bring
        close()
        advanced.startGoal(text, bringUnfinished: carry, plan: plan, in: project)
    }

    // MARK: The goals before it

    private func history(_ earlier: [BoardGoal], used: [UUID: UsageTotal]) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            BoardHeading(earlier.count == 1 ? "Earlier goal" : "Earlier goals (\(earlier.count))")
            ScrollView(.vertical) {
                VStack(spacing: Design.Space.xs) {
                    ForEach(earlier) { goal in
                        GoalRow(board: board, goal: goal, used: used[goal.id] ?? UsageTotal(),
                                expanded: expanded == goal.id,
                                toggle: { expanded = expanded == goal.id ? nil : goal.id },
                                resume: {
                                    close()
                                    advanced.resumeGoal(goal.id, in: project.id)
                                },
                                remove: { advanced.removeGoal(goal.id, in: project.id) })
                    }
                }
                .background(GeometryReader { geometry in
                    Color.clear
                        .onAppear { listHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, height in listHeight = height }
                })
            }
            .frame(height: min(max(listHeight, 1), mostList))
            .scrollIndicators(listHeight > mostList ? .automatic : .hidden)
        }
    }
}

/// An earlier goal: what it was, how it was left, how far it got and what
/// it cost. A click shows its tasks and the way back to it.
private struct GoalRow: View {
    let board: Board
    let goal: BoardGoal
    let used: UsageTotal
    let expanded: Bool
    let toggle: () -> Void
    let resume: () -> Void
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        let progress = board.progress(of: goal.id)
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: Design.Space.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: Design.Space.xs) {
                        Text(goal.key)
                            .font(Design.TextRole.caption.font.monospaced().weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(goal.text.isEmpty ? "Never put into words" : goal.text)
                            .font(Design.TextRole.label.font.weight(.medium))
                            .foregroundStyle(goal.text.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                            .lineLimit(expanded ? 8 : 1)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        GoalStatusPill(status: goal.status)
                    }
                    Text(GoalsPanel.facts(progress: progress, total: used,
                                          days: BoardText.days(from: goal.startedAt, to: goal.closedAt)))
                        .font(Design.TextRole.caption.font)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide its tasks" : "Show its tasks, and the way back to it")
            if expanded {
                tasks
                HStack(spacing: Design.Space.xs) {
                    BoardButton("Work on it again", icon: "arrow.uturn.backward", tint: Design.Tone.accent.color, action: resume)
                        .help("Turn the board back to this goal, with its tasks as they were left. The goal there is now is kept the same way.")
                    if progress.all == 0 {
                        BoardButton("Remove", icon: "trash", action: remove)
                            .help("Take this goal out of the list. Nothing was planned for it, so nothing is lost.")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(Design.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hover || expanded ? Design.Fill.raised.style : Design.Fill.content.style,
                    in: Design.Radius.shape(Design.Radius.control))
        .onHover { hover = $0 }
    }

    /// Its tasks, in the order they were made, each as it was left.
    @ViewBuilder
    private var tasks: some View {
        let items = board.items(of: goal.id)
        if items.isEmpty {
            Text("Nothing was planned for it.")
                .textRole(.label, .tertiary)
        } else {
            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                ForEach(Array(items.prefix(40))) { item in
                    HStack(spacing: Design.Space.xs) {
                        WorkStatusPill(status: item.status, compact: true)
                        Text("\(item.key) \(item.title)")
                            .textRole(.label, .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                }
                if items.count > 40 {
                    Text("\(items.count - 40) more.")
                        .textRole(.caption, .tertiary)
                }
            }
        }
    }
}
