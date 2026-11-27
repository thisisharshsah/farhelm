import AppKit
import CompanionBoard
import SwiftUI

/// A task in full, beside the board: what it is and what done means, the
/// copy of the repository it works in and what that holds, the model it
/// is given to and why, its runs with what each cost and how it ended,
/// what was said about it, and what can be done with it now.
struct TaskInspector: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var advanced = Advanced.shared
    let project: Project
    let board: Board
    let item: WorkItem
    let used: UsageTotal
    /// Delete was pressed once: the next press deletes.
    @State private var confirmingDelete = false
    /// Throw Away was pressed once: the next press throws the copy away (copy section).
    @State private var confirmingDiscard = false
    /// Throw Away was pressed once in the review section: the next press discards.
    @State private var confirmingReviewDiscard = false
    @State private var changeNote = ""
    @State private var askingForChanges = false

    private var blockers: [WorkItem] { board.blockers(of: item) }
    private var job: AgentJob? { item.activeRun.flatMap { app.jobs[$0.conversation] } }

    /// Changes this task on the board.
    private func edit(_ change: @escaping (inout WorkItem) -> Void) {
        advanced.change(project.id) { board in
            board.update(item.id, now: Date(), change)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            top
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Design.Space.m) {
                    // A floor from the design tokens, so this does not
                    // collapse to nothing for a done task with no run and
                    // make the rows under it jump up while the panel is open.
                    actions
                        .frame(minHeight: Design.Control.large.height, alignment: .top)
                    copy
                    facts
                    writing
                    waits
                    model
                    runs
                    notes
                    history
                    footer
                }
                .padding(.horizontal, Design.Space.s)
                .padding(.bottom, Design.Space.m)
            }
        }
        // A task's own drafts never carry over to the next one opened.
        .id(item.id)
    }

    // MARK: The top line

    private var top: some View {
        HStack(spacing: Design.Space.xs) {
            Text(item.key)
                .font(Design.TextRole.label.font.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
            StatusMenu(project: project, item: item)
            Spacer(minLength: Design.Space.xxs)
            // It is the only way to close the panel: never clipped.
            IconButton("xmark", help: "Close") { advanced.selectedItem = nil }
                .layoutPriority(1)
        }
        .padding(.leading, Design.Space.s)
        .padding(.trailing, Design.Space.xs)
        .padding(.vertical, Design.Space.xs)
        .glassToolbarGroup()
    }

    // MARK: What can be done now

    /// What the run is at, in a line.
    private var runStatus: String {
        guard let job else { return "Working" }
        if job.supervisorAnswering { return "The supervisor is answering for you" }
        if job.pendingQuestion != nil { return "The agent has a question for you" }
        if job.pendingApproval != nil { return "The agent waits for your OK" }
        return job.status ?? "Working"
    }

    @ViewBuilder
    private var actions: some View {
        if let run = item.activeRun {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                HStack(spacing: Design.Space.xs) {
                    LoadingMark(state: (job?.waitsOnPerson ?? false) ? .waiting : .working, size: Design.Icon.small.width)
                    Text(runStatus)
                        .textRole(.label, .primary)
                        .fontWeight(.medium)
                        .lineLimit(2)
                }
                HStack(spacing: Design.Space.xs) {
                    BoardButton("Open the Chat", icon: "bubble.left", prominent: true) {
                        app.openConversation(run.conversation)
                    }
                    BoardButton("Stop", icon: "stop.fill", tint: Design.Tone.critical.color) { advanced.stop(item.id, in: project.id) }
                }
            }
        } else if item.status == .review {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                if advanced.reviewing.contains(item.id) || advanced.checkingWork.contains(item.id) {
                    let checking = advanced.checkingWork.contains(item.id)
                    HStack(spacing: Design.Space.xs) {
                        LoadingMark(state: checking ? .working : .thinking, size: Design.Icon.small.width)
                        Text(checking ? "Running the project's checks on its work" : "The supervisor is reviewing the run")
                            .textRole(.label, .secondary)
                    }
                }
                // The recommendation leads: icon, title and reason from checks and advice.
                let rec = item.runs.last?.runRecommendation()
                if let rec {
                    HStack(spacing: Design.Space.xxs) {
                        Image(systemName: rec.action.icon)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(rec.action.tone.color)
                        Text(rec.action.title)
                            .font(Design.TextRole.label.font.weight(.semibold))
                            .foregroundStyle(rec.action.tone.color)
                            .lineLimit(1)
                        Text("recommended")
                            .textRole(.caption, .secondary)
                            .lineLimit(1)
                    }
                    Text(rec.reason)
                        .textRole(.label, .secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    HStack(spacing: Design.Space.xs) {
                        Image(systemName: "hourglass")
                            .foregroundStyle(.secondary)
                        Text("No recommendation yet")
                            .textRole(.label, .secondary)
                            .lineLimit(1)
                    }
                }
                // The recommended action is prominent; the other two are one click away.
                HStack(alignment: .top, spacing: Design.Space.xs) {
                    BoardButton("Approve", icon: "checkmark",
                                prominent: rec?.action == .approve) {
                        advanced.approve(item.id, in: project.id)
                    }
                    BoardButton("Ask for Changes", icon: "arrow.uturn.backward",
                                prominent: rec?.action == .askForChanges) {
                        if !askingForChanges {
                            changeNote = rec?.reason ?? (item.runs.last?.advice?.notes ?? "")
                        }
                        askingForChanges.toggle()
                    }
                    if item.workingCopy?.isOpen == true {
                        BoardButton(confirmingReviewDiscard ? "Throw Away for Good" : "Throw Away",
                                    icon: "trash", tint: Design.Tone.critical.color,
                                    prominent: rec?.action == .throwAway) {
                            if confirmingReviewDiscard {
                                confirmingReviewDiscard = false
                                advanced.discardCopy(item.id, in: project.id)
                            } else {
                                confirmingReviewDiscard = true
                            }
                        }
                        .help("Delete the copy and its branch, with all the work on them")
                    }
                }
                if askingForChanges {
                    TextField("", text: $changeNote, prompt: Text("What should change? The next run is given this.").foregroundStyle(.tertiary), axis: .vertical)
                        .lineLimit(2...6)
                        .boardField()
                    BoardButton("Send Back to To do", icon: "arrow.uturn.backward", tint: Design.Tone.caution.color) {
                        advanced.requestChanges(item.id, notes: changeNote.trimmingCharacters(in: .whitespacesAndNewlines),
                                                in: project.id)
                        changeNote = ""
                        askingForChanges = false
                    }
                }
            }
        } else if advanced.preparing.contains(item.id) {
            HStack(spacing: Design.Space.xs) {
                LoadingMark(state: .working, size: Design.Icon.small.width)
                Text("Readying its copy of the repository, then the run starts")
                    .textRole(.label, .secondary)
            }
        } else if item.status != .done {
            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                BoardButton(item.runs.isEmpty ? "Start a Run" : "Run It Again", icon: "play.fill", prominent: true) {
                    advanced.startOrExplain(item.id, in: project.id)
                }
                .opacity(blockers.isEmpty ? 1 : 0.5)
                if !blockers.isEmpty {
                    Text("Waits on " + blockers.map(\.key).joined(separator: ", ") + ".")
                        .font(Design.TextRole.label.font)
                        .foregroundStyle(Design.Tone.caution.color)
                }
            }
        }
    }

    // MARK: Its own copy

    /// When to look again at what its copy holds: a run ended or began,
    /// or the copy changed hands.
    private var copyLook: String {
        "\(item.runs.count)|\(item.activeRun == nil)|\(item.workingCopy?.state.rawValue ?? "")|\(item.workingCopy?.branch ?? "")"
    }

    /// The copy of the repository the task works in, on its own branch:
    /// how it stands, what it holds, and what can be done with it.
    @ViewBuilder
    private var copy: some View {
        if let copy = item.workingCopy {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                BoardHeading("Its Branch")
                HStack(spacing: Design.Space.xxs) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(Design.TextRole.caption.font.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(copy.branch)
                        .font(Design.TextRole.label.font.monospaced().weight(.medium))
                        .foregroundStyle(copy.isOpen ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text("from \(copy.base)")
                        .textRole(.label, .tertiary)
                        .lineLimit(1)
                }
                copyStanding(copy)
                if copy.isOpen {
                    copyFiles(copy)
                    copyButtons(copy)
                }
            }
            .task(id: copyLook) { advanced.refreshChanges(of: item.id, in: project.id) }
        }
    }

    /// How the copy stands, in a line or two.
    @ViewBuilder
    private func copyStanding(_ copy: WorkingCopy) -> some View {
        let busy: String? = advanced.merging.contains(item.id) ? "Merging its work into \(copy.base)"
            : (advanced.discarding.contains(item.id) ? "Throwing its copy away" : nil)
        if let busy {
            HStack(spacing: Design.Space.xs) {
                LoadingMark(state: .working, size: Design.Icon.small.width)
                Text(busy)
                    .textRole(.label, .secondary)
            }
        } else {
            let line = standing(of: copy)
            Text(line.text)
                .font(Design.TextRole.label.font)
                .foregroundStyle(line.warn ? AnyShapeStyle(Design.Tone.caution.color) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func standing(of copy: WorkingCopy) -> (text: String, warn: Bool) {
        switch copy.state {
        case .merged:
            let commit = copy.mergeCommit.map { " as \($0)" } ?? ""
            let when = copy.closedAt.map { " " + BoardText.when($0) } ?? ""
            return (copy.mergeCommit == nil ? "Nothing on it needed merging; its copy was taken down\(when)."
                    : "Merged into \(copy.base)\(commit)\(when). Its copy and branch are gone.", false)
        case .discarded:
            return ("Thrown away" + (copy.closedAt.map { " " + BoardText.when($0) } ?? "")
                    + ". Its next run starts again in a new copy.", false)
        case .open:
            if let problem = copy.problem { return ("Approved, but not merged: " + problem, true) }
            if item.status == .done {
                return copy.approvedBy == nil ? ("Done, but nobody approved its work to be merged.", true)
                    : ("Approved: its work is merged into \(copy.base) in a moment.", false)
            }
            if !copy.conflicts.isEmpty {
                return ("\(copy.base) has moved on and conflicts with it in \(copy.conflicts.count == 1 ? "1 file" : "\(copy.conflicts.count) files"). The next run brings \(copy.base) in and settles them.", true)
            }
            return ("Its runs work in a copy of the repository of its own, made \(BoardText.when(copy.madeAt)). Approved, its branch is merged into \(copy.base).", false)
        }
    }

    /// What the copy holds against where its branch began; a file opens
    /// side by side with how it was.
    @ViewBuilder
    private func copyFiles(_ copy: WorkingCopy) -> some View {
        if let changes = advanced.copyChanges[item.id] {
            VStack(alignment: .leading, spacing: Design.Space.xxs / 2) {
                Text(changes.files.isEmpty ? "No changes yet."
                     : "\(changes.files.count == 1 ? "1 file" : "\(changes.files.count) files") · +\(changes.added) −\(changes.removed)")
                    .font(Design.TextRole.caption.font.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                ForEach(changes.files.prefix(12)) { file in
                    Button {
                        advanced.showChange(file, of: item.id, in: project.id)
                    } label: {
                        HStack(spacing: Design.Space.xs) {
                            Text(file.path)
                                .font(Design.TextRole.caption.font.monospaced())
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: Design.Space.xxs)
                            Text(file.untracked ? "new" : (file.added.map { "+\($0) −\(file.removed ?? 0)" } ?? "binary"))
                                .font(Design.TextRole.caption.font)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                                // Never the one that gives way to a long path.
                                .layoutPriority(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show \(file.path) beside how it was where the branch began")
                }
                if changes.files.count > 12 {
                    Text("and \(changes.files.count - 12) more")
                        .textRole(.caption, .tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func copyButtons(_ copy: WorkingCopy) -> some View {
        let busy = item.activeRun != nil || advanced.preparing.contains(item.id) || advanced.merging.contains(item.id)
            || advanced.discarding.contains(item.id)
        // A row when there is room for all three; a column, Throw Away
        // last, when there is not, rather than letting it run off the
        // edge: none of these buttons truncates its own word.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Design.Space.xs) {
                copyLeftButtons(copy, busy: busy)
                Spacer(minLength: 2)
                copyDiscardButton(busy: busy)
            }
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                HStack(spacing: Design.Space.xs) { copyLeftButtons(copy, busy: busy) }
                copyDiscardButton(busy: busy)
            }
        }
    }

    @ViewBuilder
    private func copyLeftButtons(_ copy: WorkingCopy, busy: Bool) -> some View {
        if board.mergeWaitsOnPerson(item), !busy {
            BoardButton("Merge Now", icon: "arrow.triangle.merge", prominent: true) {
                advanced.mergeNow(item.id, in: project.id)
            }
            .help("Merge its work into \(copy.base) now, as yours")
        }
        BoardButton("Show in Finder", icon: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: copy.directory)])
        }
        .help(copy.directory)
    }

    @ViewBuilder
    private func copyDiscardButton(busy: Bool) -> some View {
        if !busy {
            BoardButton(confirmingDiscard ? "Throw Away for Good" : "Throw Away", icon: "trash",
                        tint: Design.Tone.critical.color) {
                if confirmingDiscard {
                    confirmingDiscard = false
                    advanced.discardCopy(item.id, in: project.id)
                } else {
                    confirmingDiscard = true
                }
            }
            .help("Delete its copy and its branch, with all the work on them. Its next run starts again in a new copy.")
        }
    }

    // MARK: Its facts

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: Design.Space.xs) {
            Text(label)
                .textRole(.label, .secondary)
                .frame(width: Self.labelWidth, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .frame(minHeight: Design.Control.regular.height)
    }

    /// The width of a fact's name, so the values line up down the list.
    private static let labelWidth: CGFloat = 66

    private var facts: some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            CommitField(placeholder: "Title", value: item.title) { text in
                // A card cannot be saved without a title: a blank is not
                // written, and the card keeps the title it had.
                let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                edit { $0.title = title }
            }
            row("Priority") {
                let entries = WorkPriority.allCases.reversed().map { priority in
                    MenuEntry(priority.title, symbol: priority.icon, selected: priority == item.priority) {
                        edit { $0.priority = priority }
                    }
                }
                SectionedMenu(item.priority.title, symbol: item.priority.icon,
                              groups: [MenuGroup("Priority", entries: entries)])
            }
            row("Kind") {
                let entries = WorkKind.allCases.map { kind in
                    MenuEntry(kind.title, symbol: kind.icon, selected: kind == item.kind) {
                        edit { $0.kind = kind }
                    }
                }
                SectionedMenu(item.kind.title, symbol: item.kind.icon,
                              groups: [MenuGroup("Kind", entries: entries)])
            }
            row("Phase") {
                CommitField(placeholder: "None", value: item.milestone ?? "") { text in
                    let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    edit { $0.milestone = name.isEmpty ? nil : String(name.prefix(60)) }
                }
            }
            row("Estimate") {
                CommitField(placeholder: "Tokens, such as 40k",
                            value: item.estimateTokens.map { ContextUse.short($0) } ?? "") { text in
                    let tokens = BoardText.parseTokens(text)
                    edit { $0.estimateTokens = tokens }
                }
                .frame(width: Design.Space.xxl * 4)
            }
            row("Used") {
                Text(used.isEmpty ? "Nothing yet" : "\(BoardText.tokens(used)) tokens · \(Money.text(used.cost)) · \(used.requests) requests")
                    .textRole(.number, used.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
            }
            row("Due") { due }
        }
    }

    /// The day the task is wanted by: none until one is set.
    @ViewBuilder
    private var due: some View {
        if let date = item.dueAt {
            DatePicker("", selection: Binding(get: { date }, set: { fresh in edit { $0.dueAt = fresh } }),
                       displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .controlSize(.small)
            IconButton("xmark.circle", help: "No due date") { edit { $0.dueAt = nil } }
        } else {
            BoardButton("Set a Day") {
                let week = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
                edit { $0.dueAt = week }
            }
        }
    }

    // MARK: What is to be done

    private var writing: some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            BoardHeading("What to do")
            CommitField(placeholder: "What the agent should do, and where. It reads this, the lines under Done means, and the project's own instructions.",
                        value: item.details, multiline: true) { text in
                edit { $0.details = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            BoardHeading("Done means")
                .padding(.top, Design.Space.xxs)
            CommitField(placeholder: "One line each: what can be checked when it is done.",
                        value: item.acceptance.joined(separator: "\n"), multiline: true) { text in
                let lines = text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-*•")) }
                    .filter { !$0.isEmpty }
                edit { $0.acceptance = lines }
            }
        }
    }

    // MARK: What it waits on

    private var waits: some View {
        // A task waits only on tasks under its own goal.
        let others = board.allItems
            .filter { $0.goal == item.goal && $0.id != item.id && !item.dependsOn.contains($0.number) }
            .sorted { $0.number < $1.number }
        return VStack(alignment: .leading, spacing: Design.Space.xxs) {
            BoardHeading("Waits on")
            ForEach(item.dependsOn, id: \.self) { number in
                HStack(spacing: Design.Space.xs) {
                    if let other = board.item(number: number) {
                        WorkStatusPill(status: other.status, compact: true)
                        Text("\(other.key) \(other.title)")
                            .textRole(.label, .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .onTapGesture { advanced.selectedItem = other.id }
                    }
                    Spacer(minLength: 2)
                    IconButton("xmark", help: "It no longer waits on this") {
                        setWaits(item.dependsOn.filter { $0 != number })
                    }
                }
            }
            if !others.isEmpty {
                Menu {
                    ForEach(others) { other in
                        Button("\(other.key) \(other.title)") { setWaits(item.dependsOn + [other.number]) }
                    }
                } label: {
                    BoardMenuLabel(text: item.dependsOn.isEmpty ? "Nothing. Add a task" : "Add a task", icon: "plus")
                }
                .boardMenu()
            } else if item.dependsOn.isEmpty {
                Text("Nothing.")
                    .textRole(.label, .tertiary)
            }
        }
    }

    private func setWaits(_ numbers: [Int]) {
        var refused: [Int] = []
        advanced.change(project.id) { refused = $0.setDependencies(item.id, to: numbers, now: Date()) }
        if !refused.isEmpty {
            advanced.notices[project.id] = "\(item.key) cannot wait on \(refused.map { "T-\($0)" }.joined(separator: ", ")): that would make a circle, where each waits on the other."
        }
    }

    // MARK: Its model

    private var model: some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            BoardHeading("Model")
            HStack(spacing: Design.Space.xs) {
                ModelMenu(project: project, item: item, limit: 30)
                if let assignment = item.assignment, !assignment.accepted, assignment.source != .person {
                    BoardButton("Confirm", icon: "checkmark", tint: Design.Tone.positive.color) {
                        advanced.change(project.id) { $0.acceptAssignment(item.id, now: Date()) }
                    }
                }
            }
            if let assignment = item.assignment {
                Text(source(assignment) + (assignment.reason.isEmpty ? "" : " " + assignment.reason))
                    .textRole(.label, .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("None yet. A run uses the model in the chat box until one is chosen; the supervisor suggests one when it plans.")
                    .textRole(.label, .tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func source(_ assignment: Assignment) -> String {
        switch assignment.source {
        case .supervisor: return assignment.accepted ? "Suggested by the supervisor, confirmed by you." : "Suggested by the supervisor."
        case .rule: return assignment.accepted ? "Suggested by rule, confirmed by you." : "Suggested by rule."
        case .person: return "Chosen by you."
        }
    }

    // MARK: Its runs

    private func outcomeTint(_ outcome: WorkRun.Outcome) -> Color {
        switch outcome {
        case .running: return Design.Tone.accent.color
        case .succeeded: return Design.Tone.positive.color
        case .failed: return Design.Tone.critical.color
        case .stopped: return Design.Tone.neutral.color
        }
    }

    private func outcomeWord(_ outcome: WorkRun.Outcome) -> String {
        switch outcome {
        case .running: return "Running"
        case .succeeded: return "Finished"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }

    private var runs: some View {
        let ledger = advanced.ledger(for: project.id)
        return VStack(alignment: .leading, spacing: Design.Space.xs) {
            BoardHeading(item.runs.isEmpty ? "Runs" : "Runs (\(item.runs.count))")
            if item.runs.isEmpty {
                Text("None yet. Each run is one agent's attempt; all of a task's runs share its chat.")
                    .textRole(.label, .tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(item.runs.reversed()) { run in
                runCard(run, chat: ledger.total(of: run, now: Date()))
            }
        }
    }

    private func runCard(_ run: WorkRun, chat: UsageTotal?) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            HStack(spacing: Design.Space.xs) {
                Text(outcomeWord(run.outcome))
                    .font(Design.TextRole.caption.font.weight(.semibold))
                    .foregroundStyle(outcomeTint(run.outcome))
                    .padding(.horizontal, Design.Space.xs)
                    .padding(.vertical, Design.Space.xxs / 2)
                    .background(Capsule().fill(outcomeTint(run.outcome).opacity(0.16)))
                Text(BoardText.modelName(run.modelLabel))
                    .textRole(.label, .primary)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: Design.Space.xxs)
                IconButton("bubble.left", help: "Open the task's chat") {
                    app.openConversation(run.conversation)
                }
            }
            Text(runFacts(run, chat: chat))
                .textRole(.number, .secondary)
                .font(Design.TextRole.caption.font)
                .lineLimit(2)
            if let report = run.report, !report.isEmpty {
                Text(report)
                    .textRole(.label, .secondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(report)
            }
            if let checks = run.checks, !checks.isEmpty {
                VStack(alignment: .leading, spacing: Design.Space.xxs) {
                    ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                        checkLine(check)
                    }
                }
            }
            if let review = run.review {
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.xxs) {
                    Image(systemName: review.verdict == .approved ? "checkmark.seal.fill" : "arrow.uturn.backward.circle.fill")
                        .font(Design.TextRole.caption.font)
                        .foregroundStyle(review.verdict == .approved ? Design.Tone.positive.color : Design.Tone.caution.color)
                    Text("\(review.verdict == .approved ? "Approved" : "Changes asked for") by \(BoardText.modelName(review.by))"
                         + (review.notes.isEmpty ? "." : ": " + review.notes))
                        .textRole(.label, .secondary)
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Design.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Fill.raised.style, in: Design.Radius.shape(Design.Radius.card))
    }

    /// One of the project's checks on a run's work: how it went, and for
    /// one that did not pass, what it said, to read or copy.
    private func checkLine(_ check: CheckResult) -> some View {
        let said = check.problems.isEmpty
            ? check.output.split(separator: "\n", omittingEmptySubsequences: false).suffix(30).joined(separator: "\n")
            : check.problems.joined(separator: "\n")
        return VStack(alignment: .leading, spacing: Design.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.xxs) {
                Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(Design.TextRole.caption.font)
                    .foregroundStyle(check.passed ? Design.Tone.positive.color : Design.Tone.critical.color)
                Text("\(check.name) \(Checks.status(check))")
                    .textRole(.label, .secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(check.command.isEmpty ? check.name : check.command)
            }
            if !check.passed, !said.isEmpty {
                ScrollView {
                    Text(said)
                        .font(Design.TextRole.code.font)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: Design.Space.xxl * 4)
                .padding(Design.Space.xs)
                .background(Design.Fill.content.style, in: Design.Radius.shape(Design.Radius.chip))
            }
        }
    }

    /// When a run began, how long it took, and what it used.
    private func runFacts(_ run: WorkRun, chat: UsageTotal?) -> String {
        var parts = [BoardText.when(run.startedAt)]
        parts.append(BoardText.duration((run.endedAt ?? Date()).timeIntervalSince(run.startedAt)))
        if let chat, !chat.isEmpty {
            parts.append("\(BoardText.tokens(chat)) tokens")
            parts.append(Money.text(chat.cost))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: What was said, and what happened

    private var notes: some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            BoardHeading("Notes")
            ForEach(item.notes.suffix(12)) { note in
                VStack(alignment: .leading, spacing: Design.Space.xxs / 2) {
                    Text("\(BoardText.modelName(note.author)) · \(BoardText.when(note.date))")
                        .textRole(.caption, .tertiary)
                    Text(note.text)
                        .textRole(.label, .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            NoteField { text in
                advanced.change(project.id) { $0.note(item.id, text, author: "You", now: Date()) }
            }
        }
    }

    private var history: some View {
        let lines = board.activity.filter { $0.item == item.number }.suffix(8)
        return VStack(alignment: .leading, spacing: Design.Space.xxs) {
            if !lines.isEmpty {
                BoardHeading("History")
                ForEach(Array(lines.reversed())) { line in
                    HStack(alignment: .firstTextBaseline, spacing: Design.Space.xs) {
                        Text(BoardText.when(line.date))
                            .font(Design.TextRole.caption.font)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .frame(width: Self.whenWidth, alignment: .leading)
                        Text("\(line.actor.title): \(line.text)")
                            .textRole(.caption, .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The width of a history line's time, so the lines after it align.
    private static let whenWidth: CGFloat = 74

    private var footer: some View {
        HStack(spacing: Design.Space.xs) {
            Text("Made \(BoardText.when(item.createdAt))")
                .textRole(.caption, .tertiary)
            Spacer()
            if !item.runs.isEmpty, item.activeRun == nil {
                BoardButton("Archive", icon: "archivebox") {
                    advanced.archive(item.id, in: project.id)
                }
                .help("Move it off the board. Its runs and their chats stay in the project's history.")
            }
            BoardButton(confirmingDelete ? "Delete for Good" : "Delete", icon: "trash", tint: Design.Tone.critical.color) {
                if confirmingDelete {
                    advanced.remove(item.id, in: project.id)
                } else {
                    confirmingDelete = true
                }
            }
            .help(item.runs.isEmpty ? "Take this task off the board"
                  : "Take this task off the board. Its runs' chats are kept.")
        }
    }
}

/// A line to add a note with: written, then sent with Return.
private struct NoteField: View {
    let add: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField("", text: $text, prompt: Text("Add a note").foregroundStyle(.tertiary), axis: .vertical)
            .lineLimit(1...5)
            .boardField()
            .onSubmit {
                let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !note.isEmpty else { return }
                add(note)
                text = ""
            }
    }
}
