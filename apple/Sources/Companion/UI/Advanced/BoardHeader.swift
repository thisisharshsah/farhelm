import AppKit
import CompanionBoard
import SwiftUI

/// The top of the board: which project it is and what it is for (its goal,
/// with the way to a new one and to the goals before it), how far along
/// it is and what it has cost, and how it is run (which model supervises
/// and whether it answers in the person's place, whether Autopilot starts
/// work, the budget).
struct BoardHeader: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var advanced = Advanced.shared
    let project: Project
    let board: Board
    let ledger: Ledger
    /// The pane is narrow: controls that can do without their words do.
    var compact = false
    @Binding var viewName: String
    /// The project's goals are open, under the goal.
    @State private var showGoals = false
    /// The commit and the push are two steps, each shown before it is
    /// done: what goes in and under which message, then what is sent.
    @State private var showCommit = false
    @State private var showPush = false
    @State private var commitMessage = ""
    /// They were opened to start a new goal.
    @State private var startingGoal = false
    /// The Board Settings sheet is shown.
    @State private var showSettings = false

    /// A goal has been made: it has words, or work was planned for it.
    private var goalMade: Bool { !board.goal.isEmpty || !board.items.isEmpty }

    private func openGoals(new: Bool) {
        startingGoal = new
        showGoals = true
    }

    private var budgetState: BudgetState { board.budget.state(spent: ledger.total) }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.xs) {
                projectMenu
                goal
                if goalMade { newGoalButton }
                Spacer(minLength: Design.Space.xxs)
                // Back to the supervisor, when a run's chat is beside the board.
                if app.conversation.id != board.supervisorChat {
                    BoardButton("Supervisor", icon: "bubble.left.and.text.bubble.right", tint: Design.Tone.accent.color) {
                        advanced.open(project)
                    }
                    .help("Back to the chat with this project's supervisor")
                }
                viewSwitcher
                ToolbarGroup {
                    IconButton("plus", help: "Add a task") {
                        advanced.selectedItem = advanced.addTask(BoardRules.newTaskTitle, status: .todo, in: project.id)
                    }
                    // One click to every setting and limit: the sheet
                    // groups what the three-dot menu used to mix together.
                    IconButton("slider.horizontal.3", help: "Board Settings") {
                        showSettings = true
                    }
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                        BoardSettingsSheet(project: project, board: board) { showSettings = false }
                    }
                    moreMenu
                }
            }
            HStack(spacing: Design.Space.xs) {
                progress
                spend
                if board.budget.isSet { budget }
                limitLabel
                gitLabel
                if let waiting = advanced.waiting[project.id] { waitingLabel(waiting) }
                Spacer(minLength: Design.Space.xxs)
                supervisorMenu
                if BoardAutoBadge.shouldShow(for: board.settings) { autoBadge }
                autopilot
            }
            if let notice = advanced.notices[project.id] {
                noticeBanner(notice)
            }
        }
        .padding(.horizontal, Design.Space.s)
        .padding(.vertical, Design.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: First line

    private var projectMenu: some View {
        Menu {
            ForEach(app.projects) { other in
                Button {
                    advanced.open(other)
                } label: {
                    Label(other.name + (other.id == project.id ? "  ✓" : ""), systemImage: "folder")
                }
            }
            Divider()
            Button("Add Project Folder…") { app.addProject() }
        } label: {
            BoardMenuLabel(text: project.name, icon: "folder")
        }
        .boardMenu()
        .help(project.folder ?? "No folder set")
    }

    /// The goal on one line, with its number once the project has had
    /// more than one. A click opens the project's goals: this one, to
    /// read in full and change; a new one to start; and the ones before.
    private var goal: some View {
        HStack(spacing: Design.Space.xxs) {
            if board.goals.count > 1 {
                Text(board.current.key)
                    .font(Design.TextRole.caption.font.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Design.Space.xxs)
                    .padding(.vertical, Design.Space.xxs / 2)
                    .background(Capsule().fill(Design.Fill.raised.style))
                    .fixedSize()
            }
            Text(board.goal.isEmpty ? "No goal set" : board.goal)
                .textRole(.label, board.goal.isEmpty ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .layoutPriority(-1)
        .contentShape(Rectangle())
        .onTapGesture { openGoals(new: false) }
        .help(goalHelp)
        .popover(isPresented: $showGoals, arrowEdge: .bottom) {
            GoalsPanel(project: project, board: board, ledger: ledger, startsNew: startingGoal) {
                showGoals = false
            }
        }
    }

    private var goalHelp: String {
        guard !board.goal.isEmpty else { return "Click to say what this project should achieve" }
        let earlier = board.goals.count - 1
        let rest = earlier == 0 ? "." : (earlier == 1 ? ", or see the goal before it." : ", or see the \(earlier) goals before it.")
        return board.goal + "\nClick to change it or start a new goal" + rest
    }

    /// The way to a new goal: quiet while this one is being worked on,
    /// and in the goal's own green once every task of it is done.
    @ViewBuilder
    private var newGoalButton: some View {
        let reached = board.goalReached
        let help = reached
            ? "Every task of this goal is done. Start the next one: this one is kept, with its tasks, and can be gone back to."
            : "Turn the board to a new goal. This one is kept, with its tasks, and can be gone back to."
        if compact {
            ToolbarGroup {
                IconButton(reached ? "flag.checkered" : "flag", help: "New goal. " + help,
                           tint: reached ? Theme.mint : nil) {
                    openGoals(new: true)
                }
            }
        } else {
            BoardButton("New goal", icon: reached ? "flag.checkered" : "plus", tint: reached ? Theme.mint : nil) {
                openGoals(new: true)
            }
            .help(help)
        }
    }

    private var viewSwitcher: some View {
        ToolbarGroup {
            ForEach(BoardViewKind.allCases) { kind in
                IconButton(kind.icon, help: kind.title, tint: viewName == kind.rawValue ? Design.Tone.accent.color : nil) {
                    viewName = kind.rawValue
                }
            }
        }
    }

    private func check(_ on: Bool) -> String { on ? "  ✓" : "" }

    /// The small badge in the second line while the board's Auto grant is
    /// on. The rule is `BoardAutoBadge.shouldShow(for:)`, pinned by a
    /// unit test: the badge shows when, and only when, Auto is on.
    private var autoBadge: some View {
        Chip("Auto", icon: "bolt.shield.fill", tint: Design.Tone.positive.color)
            .help("Auto is on for this board. Every run it starts, its supervisor and every chat in the project may edit, run commands, build, test and commit on their own branches without asking. Merging into main, pushing, deleting files or tasks outside the board's own cleanup, and anything touching keys still wait for you.")
    }

    /// What the supervisor running the board comes to, for the help on
    /// the ways to switch it.
    private static let answersHelp = "Supervisor mode: the supervisor runs the board for you. It starts tasks that are ready, never two that change the same files at once, answers for you (a step that needs a yes, an agent's question, a task in Review), and merges approved work one task at a time, with conflicts settled by the task's own agent. Where work stopped halfway it says \"continue\" in that chat. Steps that name keys, act on the system, send work off this Mac, work other apps or reach outside the project's folder still wait for you."

    /// The way to switch that on and off: the same item in both menus.
    private var answersItem: some View {
        Button {
            advanced.setFollowsAdvice(!board.settings.supervisorAnswers, in: project.id)
        } label: {
            Label("Supervisor Mode: Let It Run the Board" + check(board.settings.supervisorAnswers), systemImage: "star.fill")
        }
        .help(Self.answersHelp)
    }

    /// The three-dot menu: three actions and nothing else. Every setting
    /// and limit that used to be here now lives in Board Settings; New
    /// Goal already has its own button on the first line. Goals and
    /// Earlier Goals are reached by clicking the goal itself.
    private var moreMenu: some View {
        Menu {
            Button {
                app.tellSupervisor(BoardPrompts.report, project: project)
            } label: {
                Label("Status Report", systemImage: "chart.bar.doc.horizontal")
            }
            Button {
                app.tellSupervisor(BoardPrompts.replan, project: project)
            } label: {
                Label("Tidy the Plan", systemImage: "wand.and.stars")
            }
            Button {
                let text = advanced.store.markdown(project.id, name: project.name)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Label("Copy as Markdown", systemImage: "doc.on.doc")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(Design.TextRole.label.font.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: Design.Control.regular.height, height: Design.Control.regular.height)
                .contentShape(Circle())
        }
        .boardMenu()
        .help("Status Report, Tidy the Plan, Copy as Markdown")
    }

    // MARK: Second line

    private var progress: some View {
        let done = board.count(in: .done)
        let running = board.running.count
        return HStack(spacing: Design.Space.xs) {
            ShareBar(fraction: board.doneFraction, tint: Design.Tone.positive.color)
                .frame(width: Design.Space.xxl * 2)
            Text("\(done) of \(board.items.count) done")
                .textRole(.number, .primary)
                .fontWeight(.medium)
            if running > 0 {
                HStack(spacing: Design.Space.xxs) {
                    LoadingMark(state: .working, size: Design.Icon.small.width - Design.Space.xxs)
                    Text("\(running) running")
                        .textRole(.label, .secondary)
                }
            }
            if board.goalReached {
                Chip("Goal reached", icon: "checkmark.seal.fill", tint: Design.Tone.positive.color)
                    .help("Every task of this goal is done. New goal starts the next one.")
            }
            if board.overWipLimit {
                Chip("Over the limit", icon: "exclamationmark.triangle", tint: Design.Tone.caution.color)
                    .help("More tasks are in progress than the limit set for this board.")
            }
        }
        .fixedSize()
    }

    private var spend: some View {
        let total = ledger.total
        return Text("\(BoardText.tokens(total)) tokens · \(BoardCost.text(ledger))")
            .textRole(.number, .secondary)
            .lineLimit(1)
            .help("Everything asked of any model for this project: \(total.requests) requests, \(ContextUse.short(total.inputTokens)) tokens in, \(ContextUse.short(total.output)) out."
                  + (total.isExact ? "" : " \(total.estimated) of them were estimated from the text, as their engine gave no count."))
    }

    private var budgetTint: Color {
        switch budgetState {
        case .none, .within: return Design.Tone.positive.color
        case .near: return Design.Tone.caution.color
        case .over: return Design.Tone.critical.color
        }
    }

    private var budget: some View {
        let share = budgetState.fraction ?? 0
        return HStack(spacing: Design.Space.xs) {
            ShareBar(fraction: share, tint: budgetTint)
                .frame(width: Design.Space.xxl * 1.5)
            Text("\(Int((share * 100).rounded()))% of budget")
                .font(Design.TextRole.label.font.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(budgetTint)
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture { viewName = BoardViewKind.usage.rawValue }
        .help(budgetState.isOver ? "The budget is used up: no more runs start until it is raised."
              : "Spending against this project's budget. Click to see it and change it.")
    }

    /// What the supervisor's control says when the pointer rests on it:
    /// what it does, who stands in while its model cannot answer, and
    /// whether it answers for the person.
    private func supervisorHelp(chosen: EngineChoice, shown: EngineChoice, rest: Advanced.Rest?, answers: Bool) -> String {
        var text = "The model that plans this project, keeps its board and reviews finished runs."
        let name = BoardText.modelName(chosen.label)
        if let rest {
            let back = BoardText.when(rest.until)
            text += shown == chosen
                ? " \(name) is \(rest.trouble.words) until \(back), and no other model can be asked."
                : " \(name) is \(rest.trouble.words), so \(BoardText.modelName(shown.label)) answers until \(back); then \(name) is asked again."
        } else {
            text += " When its model is out of its limit, the next model that can be asked answers until it is back."
        }
        return text + (answers ? " " + Self.answersHelp
                       : " It can also run the board for you, Supervisor mode: see this menu.")
    }

    private var supervisorMenu: some View {
        let chosen = advanced.supervisorEngine(for: project.id)
        // While the chosen model cannot answer, the one standing in.
        let rest = advanced.rest(of: chosen)
        let engine = rest == nil ? chosen : advanced.currentSupervisor(for: project.id)
        // It answers in the person's place: said on the control itself,
        // so it is never on without being seen.
        let answers = board.settings.supervisorAnswers
        return Menu {
            Button("The Chat Box's Model" + check(board.supervisor == nil)) {
                advanced.setSupervisor(nil, for: project.id)
            }
            Divider()
            ForEach(advanced.roster) { entry in
                Button(entry.profile.name + check(board.supervisor == entry.engine.choice)) {
                    advanced.setSupervisor(entry.engine, for: project.id)
                }
            }
            Divider()
            answersItem
        } label: {
            HStack(spacing: Design.Space.xxs) {
                EngineLogo(kind: engine.kind, tool: engine.tool, size: Design.Icon.small.width - Design.Space.xxs)
                Text("Supervisor: " + BoardText.modelName(engine.label) + (answers && !compact ? " · runs the board" : ""))
                    .font(Design.TextRole.label.font.weight(.medium))
                    .lineLimit(1)
                // Standing in for a model that is out of its limit.
                if rest != nil {
                    Image(systemName: "hourglass")
                        .font(Design.TextRole.caption.font.weight(.bold))
                        .foregroundStyle(Design.Tone.caution.color)
                }
                if answers {
                    Image(systemName: "star.fill")
                        .font(Design.TextRole.caption.font.weight(.bold))
                        .foregroundStyle(Design.Tone.positive.color)
                }
                Image(systemName: "chevron.down")
                    .font(Design.TextRole.caption.font.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, Design.Space.xs)
            .frame(height: Design.Control.small.height)
            .glassToolbarGroup()
            .background(Capsule().fill(answers ? Design.Tone.positive.color.opacity(0.16) : Color.clear))
            .contentShape(Capsule())
        }
        .boardMenu()
        .help(supervisorHelp(chosen: chosen, shown: engine, rest: rest, answers: answers))
    }

    private var autopilot: some View {
        let on = board.settings.startsWorkByItself
        // In Supervisor mode the supervisor starts the work itself.
        let byMode = board.settings.supervisorAnswers
        return BoardButton("Autopilot", icon: on ? "bolt.fill" : "bolt.slash", tint: on ? Theme.mint : nil) {
            advanced.setAutopilot(!board.settings.autopilot, in: project.id)
        }
        .disabled(byMode)
        .help(byMode
              ? "The supervisor runs the board (Supervisor mode), so tasks that are ready start by themselves, as many as the app's run limit allows. Switch Supervisor mode off in the supervisor's menu to start them yourself."
              : on
              ? "Autopilot is on: tasks that are ready start by themselves, as many as the app's run limit allows, while the budget lasts, never two that change the same files at once. Click to switch it off."
              : "Autopilot is off: a task runs when you start it. Click to let tasks that are ready start by themselves.")
    }

    /// The app's run limit as it stands and why (`Advanced.runLimit`). It
    /// is one limit for every board and chat, so it is said where the
    /// board's own runs are, as the reason they wait.
    private var limitLabel: some View {
        let limit = advanced.runLimit
        let text = "\(limit.limit) running: " + limit.reason
        let ceiling = board.settings.runCeiling.map { " This board keeps to at most \($0) at once (its cost ceiling)." } ?? ""
        return HStack(spacing: Design.Space.xxs) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(Design.TextRole.caption.font.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(text)
                .textRole(.number, .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .layoutPriority(-1)
        .help(text + "." + ceiling)
    }

    /// Why nothing runs while work is left, on a board where work starts
    /// by itself (`Advanced.waiting`).
    private func waitingLabel(_ text: String) -> some View {
        HStack(spacing: Design.Space.xxs) {
            Image(systemName: "hourglass")
                .font(Design.TextRole.caption.font.weight(.semibold))
                .foregroundStyle(Design.Tone.caution.color)
            Text(text)
                .textRole(.label, .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .layoutPriority(-1)
        .help(text)
    }

    /// Where the project's folder stands with git, in the order it goes:
    /// what waits to be committed, then what waits to be pushed, each
    /// with the button that does it. Nothing shows when both are empty.
    @ViewBuilder
    private var gitLabel: some View {
        if let work = advanced.gitWork[project.id] {
            HStack(spacing: Design.Space.xxs) {
                LoadingMark(state: .working, size: Design.Icon.small.width - Design.Space.xxs)
                Text(work)
                    .textRole(.label, .secondary)
                    .lineLimit(1)
            }
        } else if let git = advanced.folderGit[project.id] {
            if !git.changed.isEmpty {
                BoardButton("\(git.changed.count) to commit", icon: "tray.and.arrow.down", tint: Design.Tone.caution.color) {
                    commitMessage = ""
                    showCommit = true
                }
                .popover(isPresented: $showCommit, arrowEdge: .bottom) { commitSheet(git) }
                .help("Waiting to commit on \(git.branch):\n" + git.changed.prefix(12).joined(separator: "\n")
                      + (git.changed.count > 12 ? "\nand \(git.changed.count - 12) more" : "")
                      + "\n\nThe project's checks run first. Files git does not track are left alone, and nothing is pushed."
                      + (board.settings.supervisorAnswers ? "\nThe supervisor commits them itself once they have not changed for a few minutes." : ""))
            }
            if git.ahead > 0, let upstream = git.upstream {
                BoardButton("\(git.ahead) to push", icon: "arrow.up.circle", tint: Design.Tone.accent.color) {
                    showPush = true
                }
                .popover(isPresented: $showPush, arrowEdge: .bottom) { pushSheet(git, upstream: upstream) }
                .help("\(git.ahead == 1 ? "1 commit waits" : "\(git.ahead) commits wait") to be pushed from \(git.branch) to \(upstream). Pushing is only ever done by you, here.")
            }
        }
    }

    /// What a commit would take in, and the message it goes under: the
    /// person's own, or the supervisor's when the field is left empty.
    private func commitSheet(_ git: TaskCopies.FolderGit) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            Text("Commit to \(git.branch)")
                .textRole(.label, .primary)
                .fontWeight(.semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.xxs / 2) {
                    ForEach(git.changed, id: \.self) { path in
                        Text(path)
                            .font(Design.TextRole.caption.font.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Self.sheetListHeight)
            TextField("Message (left empty, the supervisor writes it)", text: $commitMessage)
                .textFieldStyle(.roundedBorder)
                .font(Design.TextRole.label.font)
            Text("The project's checks run first. Files git does not track stay out, and nothing is pushed.")
                .textRole(.caption, .secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Design.Space.xs) {
                Spacer(minLength: Design.Space.xxs)
                BoardButton("Cancel") { showCommit = false }
                BoardButton("Commit", icon: "checkmark", prominent: true) {
                    showCommit = false
                    advanced.commitFolder(project.id, message: commitMessage)
                }
            }
        }
        .padding(Design.Space.s)
        .frame(width: Self.sheetWidth)
    }

    /// The commit and push sheets' width, and the most their lists grow.
    private static let sheetWidth: CGFloat = 420
    private static let sheetListHeight: CGFloat = 180

    /// What a push would send: each commit that waits, with its message.
    private func pushSheet(_ git: TaskCopies.FolderGit, upstream: String) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            Text("Push \(git.branch) to \(upstream)")
                .textRole(.label, .primary)
                .fontWeight(.semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.xxs) {
                    ForEach(git.unpushed, id: \.self) { line in
                        Text(line)
                            .textRole(.label, .primary)
                            .lineLimit(2)
                    }
                    if git.ahead > git.unpushed.count {
                        Text("and \(git.ahead - git.unpushed.count) more")
                            .textRole(.caption, .secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Self.sheetListHeight)
            Text("A push cannot be taken back, so it is only ever done by you, here.")
                .textRole(.caption, .secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Design.Space.xs) {
                Spacer(minLength: Design.Space.xxs)
                BoardButton("Cancel") { showPush = false }
                BoardButton("Push", icon: "arrow.up", prominent: true) {
                    showPush = false
                    advanced.pushFolder(project.id)
                }
            }
        }
        .padding(Design.Space.s)
        .frame(width: Self.sheetWidth)
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Design.TextRole.caption.font)
                .foregroundStyle(Design.Tone.caution.color)
            Text(text)
                .textRole(.label, .primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Design.Space.xxs)
            IconButton("xmark", help: "Dismiss") { advanced.notices[project.id] = nil }
        }
        .padding(.leading, Design.Space.s)
        .padding(.trailing, Design.Space.xxs)
        .padding(.vertical, Design.Space.xxs)
        .background(Design.Tone.caution.color.opacity(0.12), in: Design.Radius.shape(Design.Radius.chip))
    }
}
