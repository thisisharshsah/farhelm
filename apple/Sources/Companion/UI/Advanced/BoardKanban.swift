import CompanionBoard
import SwiftUI

/// The board as columns, one for each status. A card is dragged to another
/// column to change its task's status, or onto another card to sit above it.
struct BoardKanban: View {
    let project: Project
    let board: Board
    let ledger: Ledger
    var filters = BoardFilters()

    @State private var visibleStatus: WorkStatus? = .backlog

    var body: some View {
        GeometryReader { geometry in
            let widthClass = Design.WidthClass(width: geometry.size.width)
            Group {
                switch widthClass {
                case .compact:
                    compactList
                case .regular:
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: Design.Space.xs) {
                            ForEach(WorkStatus.allCases) { status in
                                column(status)
                                    .containerRelativeFrame(.horizontal, count: 5, span: 2, spacing: Design.Space.xs)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                case .wide:
                    HStack(alignment: .top, spacing: Design.Space.xs) {
                        ForEach(WorkStatus.allCases) { status in
                            column(status)
                                .frame(minWidth: 0, maxWidth: .infinity)
                        }
                    }
                }
            }
            .environment(\.widthClass, widthClass)
            .padding(Design.Space.xs)
        }
    }

    private var compactList: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            SegmentedSwitcher("Jump to status", options: WorkStatus.allCases.map {
                SwitcherOption(id: $0, title: $0.title, symbol: $0.icon)
            }, selection: Binding(
                get: { visibleStatus ?? .backlog },
                set: { visibleStatus = $0 }
            ))
            .glassToolbarGroup()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Design.Space.m) {
                    ForEach(WorkStatus.allCases) { status in
                        column(status, isListSection: true)
                            .id(status)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $visibleStatus, anchor: .top)
        }
    }

    private func column(_ status: WorkStatus, isListSection: Bool = false) -> some View {
        BoardColumn(project: project, board: board, ledger: ledger, status: status,
                    isListSection: isListSection, matches: filters.matches)
    }
}

/// One status's column: its name and count, then its tasks, top to bottom.
private struct BoardColumn: View {
    @ObservedObject private var advanced = Advanced.shared
    let project: Project
    let board: Board
    let ledger: Ledger
    let status: WorkStatus
    var isListSection = false
    var matches: (WorkItem) -> Bool = { _ in true }
    @State private var targeted = false

    private var overLimit: Bool { status == .inProgress && board.overWipLimit }

    var body: some View {
        let allItems = board.items(in: status)
        let visible = allItems.filter(matches)
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.xxs) {
                WorkStatusPill(status: status)
                Text(visible.count, format: .number)
                    .textRole(.number, .secondary)
                    .accessibilityLabel("\(visible.count) visible tasks")
                if overLimit, let limit = board.settings.wipLimit {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Design.Tone.caution.color)
                        .help("\(allItems.count) tasks in progress, limit \(limit)")
                        .accessibilityLabel("\(allItems.count) tasks in progress, limit \(limit)")
                }
                Spacer(minLength: Design.Space.xxs)
                if status == .backlog || status == .todo {
                    IconButton("plus", help: "Add a task to \(status.title)") {
                        advanced.selectedItem = advanced.addTask(BoardRules.newTaskTitle, status: status, in: project.id)
                    }
                }
            }
            .padding(Design.Space.xxs)
            .glassToolbarGroup()

            if isListSection {
                cards(visible)
            } else {
                ScrollView(.vertical) { cards(visible) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: isListSection ? nil : .infinity, alignment: .topLeading)
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: Design.Radius.tile, style: .continuous)
                    .strokeBorder(status.tint)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { dropped, _ in
            drop(dropped, above: nil)
        } isTargeted: { over in
            targeted = over
        }
        .designAnimation(.quick, value: targeted)
    }

    private func cards(_ items: [WorkItem]) -> some View {
        LazyVStack(spacing: Design.Space.xs) {
            ForEach(items) { item in
                TaskCard(project: project, board: board, item: item, used: ledger.total(of: item))
                    .draggable(item.id.uuidString)
                    .dropDestination(for: String.self) { dropped, _ in
                        drop(dropped, above: item.id)
                    }
            }
        }
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
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            Text(item.title)
                .textRole(.label, item.status == .done ? .secondary : .primary)
                .fontWeight(.semibold)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(item.title)
            HStack(spacing: Design.Space.xxs) {
                PriorityMark(priority: item.priority)
                Image(systemName: item.kind.icon)
                    .iconWidth(.small)
                    .foregroundStyle(.secondary)
                    .help(item.kind.title)
                    .accessibilityLabel(item.kind.title)
                ModelChip(assignment: item.assignment)
                Spacer(minLength: 0)
                tokens
                    .layoutPriority(1)
            }
            HStack(spacing: Design.Space.xxs) {
                Text(item.key)
                if let milestone = item.milestone {
                    Text(milestone).lineLimit(1)
                }
                if let copy = item.workingCopy, copy.isOpen {
                    Image(systemName: "arrow.triangle.branch")
                        .help("Works in a copy of its own, on \(copy.branch), made from \(copy.base)")
                }
                if !blockers.isEmpty, item.status != .done {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(Design.Tone.caution.color)
                        .help("Waits on " + blockers.map(\.key).joined(separator: ", "))
                }
            }
            .textRole(.caption, .secondary)
            if item.activeRun != nil {
                runLine
            } else if advanced.checkingWork.contains(item.id) {
                statusLine("Running its checks", mark: .working)
            } else if advanced.reviewing.contains(item.id) {
                statusLine("The supervisor is reviewing it", mark: .thinking)
            } else if advanced.preparing.contains(item.id) {
                statusLine("Readying its copy", mark: .working)
            } else if advanced.waitsForSlot(item.id, in: project.id) {
                toneLine(RunLimit.waitingWords, symbol: "hourglass", tone: .caution)
                .help("In line: it starts by itself when a slot frees, most pressing first (" + advanced.runLimit.reason + ").")
            } else if advanced.merging.contains(item.id) {
                statusLine("Merging its work", mark: .working)
            } else if board.mergeWaitsOnPerson(item) {
                toneLine("Not merged", symbol: "arrow.triangle.merge", tone: .caution)
                .help(item.workingCopy?.problem ?? "Nobody approved its work to be merged")
            } else if item.status == .review, let checks = item.runs.last?.checks, !Checks.letThrough(checks) {
                let failed = checks.filter { !$0.passed }
                toneLine(failed.count == 1 ? "\(failed[0].name) did not pass" : "\(failed.count) checks did not pass",
                         symbol: "xmark.octagon.fill", tone: .critical)
                .help(failed.map { "\($0.name) \(Checks.status($0))" }.joined(separator: "\n"))
            } else if item.status == .review {
                reviewState
            }
            if hover || selected {
                actions
                    .transition(.opacity)
            }
        }
        .padding(Design.Space.xs)
        .background(Design.Fill.raised.style, in: Design.Radius.shape(Design.Radius.card))
        .overlay {
            let shape = Design.Radius.shape(Design.Radius.card)
            if waitingOnPerson || selected {
                shape.strokeBorder(waitingOnPerson ? Design.Tone.caution.color : Design.Tone.accent.color)
            } else {
                shape.strokeBorder(Design.Fill.line.style)
            }
        }
        .contentShape(Design.Radius.shape(Design.Radius.card))
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
                toneLine(job?.pendingQuestion != nil ? "Has a question for you" : "Waits for your OK",
                         symbol: "exclamationmark.bubble.fill", tone: .caution)
            } else if job?.supervisorAnswering == true {
                statusLine("The supervisor is answering", mark: .thinking)
            } else {
                statusLine(job?.status ?? "Working", mark: .working)
            }
        }
    }

    /// Where a card resting in Review stands: the review handed it to the
    /// person (and why, on hover), or its review has not come yet. A
    /// review going on right now has its own line above.
    @ViewBuilder
    private var reviewState: some View {
        let since = item.runs.last?.endedAt ?? item.runs.last?.startedAt ?? .distantPast
        let handed = item.notes.last { $0.date >= since && $0.text.hasPrefix("The review ") }
        toneLine(reviewWords(handed: handed != nil),
                 symbol: handed == nil ? "hourglass" : "person.crop.circle.badge.exclamationmark",
                 tone: handed == nil ? nil : .caution)
            .help(handed?.text ?? item.runs.last?.advice?.notes ?? "Open the card to approve it or ask for changes")
    }

    /// A one-line state under the card's badges: in a tone's color when it
    /// asks for attention, secondary text when it does not.
    private func toneLine(_ text: String, symbol: String, tone: Design.Tone?) -> some View {
        HStack(spacing: Design.Space.xxs) {
            Image(systemName: symbol)
                .iconWidth(.small)
            Text(text)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(Design.TextRole.caption.font)
        .foregroundStyle(tone.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
    }

    /// The card's line in Review: whether the work is done as far as the
    /// supervisor can tell, and what it would do in the person's place.
    private func reviewWords(handed: Bool) -> String {
        switch item.runs.last?.advice?.verdict {
        case .approved?: return "Done · approve it"
        case .changesRequested?: return "Not done · redo it"
        case nil:
            if handed { return "Reviewed: needs you" }
            return item.runs.last?.review == nil ? "Waiting for its review" : "Reviewed, waits for you"
        }
    }

    private func statusLine(_ text: String, mark: LoadingMark.Phase) -> some View {
        HStack(spacing: Design.Space.xxs) {
            LoadingMark(state: mark, size: Design.Icon.small.width - Design.Space.xxs)
            Text(text)
                .textRole(.caption, .secondary)
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
                    .font(Design.TextRole.caption.font)
                    .monospacedDigit()
                    .foregroundStyle(over ? AnyShapeStyle(Design.Tone.caution.color) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .help(used.isEmpty
                          ? "Expected to take about \(ContextUse.short(estimate)) tokens."
                          : "Used \(BoardText.tokens(used)) tokens (\(Money.text(used.cost)))"
                            + (estimate > 0 ? " of an expected \(ContextUse.short(estimate))." : "."))
            }
        }
    }

    /// The card's buttons, in words where the column is wide enough for
    /// them and as symbols alone where it is not: a row wider than the
    /// card pushed the whole card out past its column's edges.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            actionRow(words: true)
            actionRow(words: false)
        }
    }

    private func actionRow(words: Bool) -> some View {
        HStack(alignment: .top, spacing: Design.Space.xxs) {
            if let run = item.activeRun {
                BoardButton(!words ? "" : (waitingOnPerson ? "Answer" : "Open"), icon: "bubble.left",
                            tint: waitingOnPerson ? Design.Tone.caution.color : nil) {
                    app.openConversation(run.conversation)
                }
                .help("Open the chat this run works in")
                BoardButton(words ? "Stop" : "", icon: "stop.fill", tint: Design.Tone.critical.color) { advanced.stop(item.id, in: project.id) }
                    .help("Stop this run")
            } else if item.status == .review {
                let advised = item.runs.last?.advice
                let redo = advised?.verdict == .changesRequested
                BoardButton(words ? "Approve" : "", icon: "checkmark", tint: Design.Tone.positive.color) {
                    advanced.approve(item.id, in: project.id)
                }
                .help("Approve it: its work is merged and the task is done")
                .recommended(words && advised?.verdict == .approved, why: BoardText.why(advised))
                BoardButton(words ? "Redo" : "", icon: "arrow.uturn.backward") {
                    // What the supervisor found goes to the next run.
                    advanced.requestChanges(item.id, notes: redo ? (advised?.notes ?? "") : "", in: project.id)
                }
                .help(redo ? "Send it back to To do, with what the supervisor found" : "Send it back to To do")
                .recommended(words && redo, why: BoardText.why(advised))
            } else if board.mergeWaitsOnPerson(item), !advanced.merging.contains(item.id) {
                BoardButton(words ? "Merge" : "", icon: "arrow.triangle.merge", tint: Design.Tone.caution.color) {
                    advanced.mergeNow(item.id, in: project.id)
                }
                .help((item.workingCopy?.problem.map { $0 + " " } ?? "") + "Merge its work now, as yours.")
            } else if item.status == .todo || item.status == .backlog, !advanced.preparing.contains(item.id) {
                BoardButton(words ? "Start" : "", icon: "play.fill", tint: Design.Tone.accent.color) {
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
