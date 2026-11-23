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
    /// Throw Away was pressed once: the next press throws the copy away.
    @State private var confirmingDiscard = false
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
                VStack(alignment: .leading, spacing: 14) {
                    actions
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
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
        // A task's own drafts never carry over to the next one opened.
        .id(item.id)
    }

    // MARK: The top line

    private var top: some View {
        HStack(spacing: 6) {
            Text(item.key)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.ink.opacity(0.5))
            StatusMenu(project: project, item: item)
            Spacer(minLength: 2)
            IconButton("xmark", help: "Close") { advanced.selectedItem = nil }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.top, 8)
        .padding(.bottom, 6)
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    LoadingMark(state: (job?.waitsOnPerson ?? false) ? .waiting : .working, size: 13)
                    Text(runStatus)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.ink.opacity(0.9))
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    BoardButton("Open the Chat", icon: "bubble.left", prominent: true) {
                        app.openConversation(run.conversation)
                    }
                    BoardButton("Stop", icon: "stop.fill", tint: Theme.rose) { advanced.stop(item.id, in: project.id) }
                }
            }
        } else if item.status == .review {
            VStack(alignment: .leading, spacing: 6) {
                if advanced.reviewing.contains(item.id) {
                    let checking = advanced.checkingWork.contains(item.id)
                    HStack(spacing: 6) {
                        LoadingMark(state: checking ? .working : .thinking, size: 13)
                        Text(checking ? "Running the project's checks on its work" : "The supervisor is reviewing the run")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.ink.opacity(0.75))
                    }
                }
                // What the supervisor makes of the run, for the person
                // who reviews it: the answer it recommends says so.
                let advised = item.runs.last?.advice
                let redo = advised?.verdict == .changesRequested
                HStack(alignment: .top, spacing: 6) {
                    BoardButton("Approve", icon: "checkmark", prominent: true) { advanced.approve(item.id, in: project.id) }
                        .recommended(advised?.verdict == .approved, why: BoardText.why(advised))
                    BoardButton("Ask for Changes", icon: "arrow.uturn.backward") {
                        // What the supervisor found is where the note starts.
                        if !askingForChanges, redo, changeNote.isEmpty { changeNote = advised?.notes ?? "" }
                        askingForChanges.toggle()
                    }
                    .recommended(redo, why: BoardText.why(advised))
                }
                if let advised {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .padding(.top, 2.5)
                        Text("The supervisor recommends " + (redo ? "asking for changes" : "approving it")
                             + (advised.notes.isEmpty ? "." : ": " + advised.notes))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ink.opacity(0.75))
                            .lineLimit(8)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .help("From \(advised.by), this project's supervisor. It is advice: you decide.")
                }
                if askingForChanges {
                    TextField("What should change? The next run is given this.", text: $changeNote, axis: .vertical)
                        .lineLimit(2...6)
                        .boardField()
                    BoardButton("Send Back to To do", icon: "arrow.uturn.backward", tint: Theme.amber) {
                        advanced.requestChanges(item.id, notes: changeNote.trimmingCharacters(in: .whitespacesAndNewlines),
                                                in: project.id)
                        changeNote = ""
                        askingForChanges = false
                    }
                }
            }
        } else if advanced.preparing.contains(item.id) {
            HStack(spacing: 6) {
                LoadingMark(state: .working, size: 13)
                Text("Readying its copy of the repository, then the run starts")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink.opacity(0.75))
            }
        } else if item.status != .done {
            VStack(alignment: .leading, spacing: 5) {
                BoardButton(item.runs.isEmpty ? "Start a Run" : "Run It Again", icon: "play.fill", prominent: true) {
                    advanced.startOrExplain(item.id, in: project.id)
                }
                .opacity(blockers.isEmpty ? 1 : 0.5)
                if !blockers.isEmpty {
                    Text("Waits on " + blockers.map(\.key).joined(separator: ", ") + ".")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.amber)
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
            VStack(alignment: .leading, spacing: 6) {
                BoardHeading("Its Branch")
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.ink.opacity(0.55))
                    Text(copy.branch)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.ink.opacity(copy.isOpen ? 0.9 : 0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text("from \(copy.base)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink.opacity(0.5))
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
            HStack(spacing: 6) {
                LoadingMark(state: .working, size: 12)
                Text(busy)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.75))
            }
        } else {
            let line = standing(of: copy)
            Text(line.text)
                .font(.system(size: 11))
                .foregroundStyle(line.warn ? Theme.amber : Theme.ink.opacity(0.65))
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
            VStack(alignment: .leading, spacing: 2) {
                Text(changes.files.isEmpty ? "No changes yet."
                     : "\(changes.files.count == 1 ? "1 file" : "\(changes.files.count) files") · +\(changes.added) −\(changes.removed)")
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink.opacity(0.6))
                ForEach(changes.files.prefix(12)) { file in
                    Button {
                        advanced.showChange(file, of: item.id, in: project.id)
                    } label: {
                        HStack(spacing: 6) {
                            Text(file.path)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.ink.opacity(0.8))
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 4)
                            Text(file.untracked ? "new" : (file.added.map { "+\($0) −\(file.removed ?? 0)" } ?? "binary"))
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .foregroundStyle(Theme.ink.opacity(0.5))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show \(file.path) beside how it was where the branch began")
                }
                if changes.files.count > 12 {
                    Text("and \(changes.files.count - 12) more")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink.opacity(0.45))
                }
            }
        }
    }

    @ViewBuilder
    private func copyButtons(_ copy: WorkingCopy) -> some View {
        let busy = item.activeRun != nil || advanced.preparing.contains(item.id) || advanced.merging.contains(item.id)
            || advanced.discarding.contains(item.id)
        HStack(spacing: 6) {
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
            Spacer(minLength: 2)
            if !busy {
                BoardButton(confirmingDiscard ? "Throw Away for Good" : "Throw Away", icon: "trash", tint: Theme.rose) {
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
    }

    // MARK: Its facts

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.5))
                .frame(width: 66, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .frame(minHeight: 24)
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 4) {
            CommitField(placeholder: "Title", value: item.title) { text in
                edit { $0.title = text }
            }
            row("Priority") {
                Menu {
                    ForEach(WorkPriority.allCases.reversed()) { priority in
                        Button {
                            edit { $0.priority = priority }
                        } label: {
                            Label(priority.title + (priority == item.priority ? "  ✓" : ""), systemImage: priority.icon)
                        }
                    }
                } label: {
                    PriorityMark(priority: item.priority, showsWord: true)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(Theme.ink.opacity(0.07)))
                }
                .boardMenu()
            }
            row("Kind") {
                Menu {
                    ForEach(WorkKind.allCases) { kind in
                        Button {
                            edit { $0.kind = kind }
                        } label: {
                            Label(kind.title + (kind == item.kind ? "  ✓" : ""), systemImage: kind.icon)
                        }
                    }
                } label: {
                    BoardMenuLabel(text: item.kind.title, icon: item.kind.icon)
                }
                .boardMenu()
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
                .frame(width: 130)
            }
            row("Used") {
                Text(used.isEmpty ? "Nothing yet" : "\(BoardText.tokens(used)) tokens · \(Money.text(used.cost)) · \(used.requests) requests")
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink.opacity(used.isEmpty ? 0.45 : 0.85))
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
        VStack(alignment: .leading, spacing: 5) {
            BoardHeading("What to do")
            CommitField(placeholder: "What the agent should do, and where. It reads this, the lines under Done means, and the project's own instructions.",
                        value: item.details, multiline: true) { text in
                edit { $0.details = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            BoardHeading("Done means")
                .padding(.top, 4)
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
        return VStack(alignment: .leading, spacing: 5) {
            BoardHeading("Waits on")
            ForEach(item.dependsOn, id: \.self) { number in
                HStack(spacing: 6) {
                    if let other = board.item(number: number) {
                        WorkStatusPill(status: other.status, compact: true)
                        Text("\(other.key) \(other.title)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.ink.opacity(0.85))
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
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink.opacity(0.45))
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
        VStack(alignment: .leading, spacing: 5) {
            BoardHeading("Model")
            HStack(spacing: 6) {
                ModelMenu(project: project, item: item, limit: 30)
                if let assignment = item.assignment, !assignment.accepted, assignment.source != .person {
                    BoardButton("Confirm", icon: "checkmark", tint: Theme.mint) {
                        advanced.change(project.id) { $0.acceptAssignment(item.id, now: Date()) }
                    }
                }
            }
            if let assignment = item.assignment {
                Text(source(assignment) + (assignment.reason.isEmpty ? "" : " " + assignment.reason))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("None yet. A run uses the model in the chat box until one is chosen; the supervisor suggests one when it plans.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.5))
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
        case .running: return Theme.accent
        case .succeeded: return Theme.mint
        case .failed: return Theme.rose
        case .stopped: return Theme.ink.opacity(0.5)
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
        return VStack(alignment: .leading, spacing: 6) {
            BoardHeading(item.runs.isEmpty ? "Runs" : "Runs (\(item.runs.count))")
            if item.runs.isEmpty {
                Text("None yet. Each run is one agent's attempt; all of a task's runs share its chat.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(item.runs.reversed()) { run in
                runCard(run, chat: ledger.total(of: run, now: Date()))
            }
        }
    }

    private func runCard(_ run: WorkRun, chat: UsageTotal?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(outcomeWord(run.outcome))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(outcomeTint(run.outcome))
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(Capsule().fill(outcomeTint(run.outcome).opacity(0.16)))
                Text(BoardText.modelName(run.modelLabel))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 2)
                IconButton("bubble.left", help: "Open the task's chat") {
                    app.openConversation(run.conversation)
                }
            }
            Text(runFacts(run, chat: chat))
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(Theme.ink.opacity(0.55))
                .lineLimit(2)
            if let report = run.report, !report.isEmpty {
                Text(report)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.75))
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(report)
            }
            if let checks = run.checks, !checks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                        checkLine(check)
                    }
                }
            }
            if let review = run.review {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: review.verdict == .approved ? "checkmark.seal.fill" : "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(review.verdict == .approved ? Theme.mint : Theme.amber)
                        .padding(.top, 1)
                    Text("\(review.verdict == .approved ? "Approved" : "Changes asked for") by \(BoardText.modelName(review.by))"
                         + (review.notes.isEmpty ? "." : ": " + review.notes))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink.opacity(0.75))
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.ink.opacity(0.05)))
    }

    /// One of the project's checks on a run's work: how it went, and for
    /// one that did not pass, what it said, to read or copy.
    private func checkLine(_ check: CheckResult) -> some View {
        let said = check.problems.isEmpty
            ? check.output.split(separator: "\n", omittingEmptySubsequences: false).suffix(30).joined(separator: "\n")
            : check.problems.joined(separator: "\n")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(check.passed ? Theme.mint : Theme.rose)
                    .padding(.top, 1)
                Text("\(check.name) \(Checks.status(check))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.75))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(check.command.isEmpty ? check.name : check.command)
            }
            if !check.passed, !said.isEmpty {
                ScrollView {
                    Text(said)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.ink.opacity(0.7))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.ink.opacity(0.05)))
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
        VStack(alignment: .leading, spacing: 5) {
            BoardHeading("Notes")
            ForEach(item.notes.suffix(12)) { note in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(BoardText.modelName(note.author)) · \(BoardText.when(note.date))")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ink.opacity(0.45))
                    Text(note.text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink.opacity(0.85))
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
        return VStack(alignment: .leading, spacing: 3) {
            if !lines.isEmpty {
                BoardHeading("History")
                ForEach(Array(lines.reversed())) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(BoardText.when(line.date))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink.opacity(0.4))
                            .frame(width: 74, alignment: .leading)
                        Text("\(line.actor.title): \(line.text)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.ink.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("Made \(BoardText.when(item.createdAt))")
                .font(.system(size: 10))
                .foregroundStyle(Theme.ink.opacity(0.4))
            Spacer()
            BoardButton(confirmingDelete ? "Delete for Good" : "Delete", icon: "trash", tint: Theme.rose) {
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
        TextField("Add a note", text: $text, axis: .vertical)
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
