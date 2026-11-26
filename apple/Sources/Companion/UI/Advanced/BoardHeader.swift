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

    /// A goal has been made: it has words, or work was planned for it.
    private var goalMade: Bool { !board.goal.isEmpty || !board.items.isEmpty }

    private func openGoals(new: Bool) {
        startingGoal = new
        showGoals = true
    }

    private var budgetState: BudgetState { board.budget.state(spent: ledger.total) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                projectMenu
                goal
                if goalMade { newGoalButton }
                Spacer(minLength: 4)
                // Back to the supervisor, when a run's chat is beside the board.
                if app.conversation.id != board.supervisorChat {
                    BoardButton("Supervisor", icon: "bubble.left.and.text.bubble.right", tint: Theme.accent) {
                        advanced.open(project)
                    }
                    .help("Back to the chat with this project's supervisor")
                }
                viewSwitcher
                ToolbarGroup {
                    IconButton("plus", help: "Add a task") {
                        advanced.selectedItem = advanced.addTask(BoardRules.newTaskTitle, status: .todo, in: project.id)
                    }
                    moreMenu
                }
            }
            HStack(spacing: 10) {
                progress
                spend
                if board.budget.isSet { budget }
                limitLabel
                gitLabel
                if let waiting = advanced.waiting[project.id] { waitingLabel(waiting) }
                Spacer(minLength: 4)
                supervisorMenu
                autopilot
            }
            if let notice = advanced.notices[project.id] {
                noticeBanner(notice)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
        HStack(spacing: 5) {
            if board.goals.count > 1 {
                Text(board.current.key)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.ink.opacity(0.55))
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(Capsule().fill(Theme.ink.opacity(0.08)))
                    .fixedSize()
            }
            Text(board.goal.isEmpty ? "No goal set" : board.goal)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink.opacity(board.goal.isEmpty ? 0.4 : 0.7))
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
                IconButton(kind.icon, help: kind.title, tint: viewName == kind.rawValue ? Theme.accent : nil) {
                    viewName = kind.rawValue
                }
            }
        }
    }

    private func check(_ on: Bool) -> String { on ? "  ✓" : "" }

    /// Opens the project's checks in the editor. Where there are none yet,
    /// a first file is written to make them from, with the build the app
    /// finds in the folder as its one check.
    private func openChecks() {
        guard let folder = project.folder else { return }
        let path = (folder as NSString).appendingPathComponent(Checks.file)
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            try? Checks.starter(build: ProblemsModel.buildCommand(in: folder))
                .write(toFile: path, atomically: true, encoding: .utf8)
        }
        app.openInWorkspace(path)
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

    private var moreMenu: some View {
        Menu {
            if goalMade {
                Button {
                    openGoals(new: true)
                } label: {
                    Label("New Goal…", systemImage: "flag")
                }
            }
            if board.goals.count > 1 {
                Button {
                    openGoals(new: false)
                } label: {
                    Label("Earlier Goals…", systemImage: "clock.arrow.circlepath")
                }
            }
            if goalMade || board.goals.count > 1 { Divider() }
            Button {
                app.tellSupervisor(BoardPrompts.report, project: project)
            } label: {
                Label("Status Report", systemImage: "chart.bar.doc.horizontal")
            }
            Button {
                app.tellSupervisor(BoardPrompts.assign, project: project)
            } label: {
                Label("Suggest Models for the Tasks", systemImage: "person.crop.circle.badge.checkmark")
            }
            Button {
                app.tellSupervisor(BoardPrompts.replan, project: project)
            } label: {
                Label("Tidy the Plan", systemImage: "wand.and.stars")
            }
            Divider()
            Button {
                advanced.change(project.id) { $0.settings.reviewGate.toggle() }
            } label: {
                Label("Review Finished Runs" + check(board.settings.reviewGate), systemImage: "checkmark.seal")
            }
            Button {
                openChecks()
            } label: {
                Label("Checks Before Review…", systemImage: "checklist")
            }
            .disabled(project.folder == nil)
            .help("The commands run on each task's work before it is reviewed (its build, its tests), written in \(Checks.file) in the project's folder. Work whose checks fail is never approved without you.")
            Button {
                advanced.setCopyPerTask(!board.settings.copyPerTask, in: project.id)
            } label: {
                Label("Give Each Task Its Own Branch" + check(board.settings.copyPerTask),
                      systemImage: "arrow.triangle.branch")
            }
            Button {
                // Without recommendations there is no answer to take.
                if board.settings.advice, board.settings.followsAdvice {
                    advanced.setFollowsAdvice(false, in: project.id)
                }
                advanced.change(project.id) { $0.settings.advice.toggle() }
            } label: {
                Label("Recommend an Answer Wherever I Am Asked" + check(board.settings.advice), systemImage: "star")
            }
            answersItem
            // Only a cost ceiling: how many run at once is the app's limit,
            // set from what is free, and this can only lower it.
            Menu("Cost Ceiling on Runs") {
                Button("None: Follow the App's Limit" + check(board.settings.runCeiling == nil)) {
                    advanced.change(project.id) { $0.settings.runCeiling = nil }
                    advanced.tick(project.id)
                }
                ForEach([1, 2, 4, 8], id: \.self) { count in
                    Button("At Most \(count)" + check(board.settings.runCeiling == count)) {
                        advanced.change(project.id) { $0.settings.runCeiling = count }
                        advanced.tick(project.id)
                    }
                }
            }
            .help("How many of this board's runs go at once is set for the whole app from what is free. A ceiling here only keeps the board's runs, and what they spend, below it.")
            Menu("Limit on In Progress") {
                Button("None" + check(board.settings.wipLimit == nil)) {
                    advanced.change(project.id) { $0.settings.wipLimit = nil }
                }
                ForEach([1, 2, 3, 4, 5, 8], id: \.self) { count in
                    Button("\(count)" + check(board.settings.wipLimit == count)) {
                        advanced.change(project.id) { $0.settings.wipLimit = count }
                    }
                }
            }
            Menu("What Runs May Do Unasked") {
                Button("As Set for New Chats" + check(board.settings.runAccess == nil)) {
                    advanced.change(project.id) { $0.settings.runAccess = nil }
                }
                ForEach(AgentAccess.allCases) { access in
                    Button(access.title + check(board.settings.runAccess == access.rawValue)) {
                        advanced.change(project.id) { $0.settings.runAccess = access.rawValue }
                    }
                }
            }
            Button {
                viewName = BoardViewKind.usage.rawValue
            } label: {
                Label("Budget and Usage…", systemImage: "gauge.with.dots.needle.50percent")
            }
            Divider()
            Button {
                let text = advanced.store.markdown(project.id, name: project.name)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Label("Copy the Board as Markdown", systemImage: "doc.on.doc")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.68))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .boardMenu()
        .help("Goals, reports, how the board is run, and copying it")
    }

    // MARK: Second line

    private var progress: some View {
        let done = board.count(in: .done)
        let running = board.running.count
        return HStack(spacing: 7) {
            ShareBar(fraction: board.doneFraction, tint: Theme.mint)
                .frame(width: 64)
            Text("\(done) of \(board.items.count) done")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.ink.opacity(0.8))
            if running > 0 {
                HStack(spacing: 4) {
                    LoadingMark(state: .working, size: 11)
                    Text("\(running) running")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink.opacity(0.65))
                }
            }
            if board.goalReached {
                Chip("Goal reached", icon: "checkmark.seal.fill", tint: Theme.mint)
                    .help("Every task of this goal is done. New goal starts the next one.")
            }
            if board.overWipLimit {
                Chip("Over the limit", icon: "exclamationmark.triangle", tint: Theme.amber)
                    .help("More tasks are in progress than the limit set for this board.")
            }
        }
        .fixedSize()
    }

    private var spend: some View {
        let total = ledger.total
        return Text("\(BoardText.tokens(total)) tokens · \(Money.text(total.cost))")
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(Theme.ink.opacity(0.65))
            .lineLimit(1)
            .help("Everything asked of any model for this project: \(total.requests) requests, \(ContextUse.short(total.inputTokens)) tokens in, \(ContextUse.short(total.output)) out."
                  + (total.isExact ? "" : " \(total.estimated) of them were estimated from the text, as their engine gave no count."))
    }

    private var budgetTint: Color {
        switch budgetState {
        case .none, .within: return Theme.mint
        case .near: return Theme.amber
        case .over: return Theme.rose
        }
    }

    private var budget: some View {
        let share = budgetState.fraction ?? 0
        return HStack(spacing: 6) {
            ShareBar(fraction: share, tint: budgetTint)
                .frame(width: 48)
            Text("\(Int((share * 100).rounded()))% of budget")
                .font(.system(size: 11, weight: .medium))
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
            HStack(spacing: 5) {
                EngineLogo(kind: engine.kind, tool: engine.tool, size: 10)
                Text("Supervisor: " + BoardText.modelName(engine.label) + (answers && !compact ? " · runs the board" : ""))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                // Standing in for a model that is out of its limit.
                if rest != nil {
                    Image(systemName: "hourglass")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.amber)
                }
                if answers {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.mint)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.6)
            }
            .foregroundStyle(Theme.ink.opacity(0.85))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill((answers ? Theme.mint : Theme.ink).opacity(answers ? 0.16 : 0.08)))
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
        let ceiling = board.settings.runCeiling.map { " This board keeps to at most \($0) at once (its cost ceiling)." } ?? ""
        return HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.5))
            Text("Up to \(limit.limit) at once · " + limit.reason)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Theme.ink.opacity(0.65))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .layoutPriority(-1)
        .help("One limit for the whole app, set from the Mac's free processors and memory, what is left of each plan, and how many tasks can start. Your own chats always get a slot; board runs share the rest, \(limit.forBoards) now. Work over the limit waits in line and starts by itself, most pressing first." + ceiling)
    }

    /// Why nothing runs while work is left, on a board where work starts
    /// by itself (`Advanced.waiting`).
    private func waitingLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "hourglass")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.amber)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.7))
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
            HStack(spacing: 5) {
                LoadingMark(state: .working, size: 11)
                Text(work)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.7))
                    .lineLimit(1)
            }
        } else if let git = advanced.folderGit[project.id] {
            if !git.changed.isEmpty {
                BoardButton("\(git.changed.count) to commit", icon: "tray.and.arrow.down", tint: Theme.amber) {
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
                BoardButton("\(git.ahead) to push", icon: "arrow.up.circle", tint: Theme.accent) {
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Commit to \(git.branch)")
                .font(.system(size: 12, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(git.changed, id: \.self) { path in
                        Text(path)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.ink.opacity(0.75))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            TextField("Message (left empty, the supervisor writes it)", text: $commitMessage)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
            Text("The project's checks run first. Files git does not track stay out, and nothing is pushed.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer(minLength: 4)
                BoardButton("Cancel") { showCommit = false }
                BoardButton("Commit", icon: "checkmark", prominent: true) {
                    showCommit = false
                    advanced.commitFolder(project.id, message: commitMessage)
                }
            }
        }
        .padding(12)
        .frame(width: 400)
    }

    /// What a push would send: each commit that waits, with its message.
    private func pushSheet(_ git: TaskCopies.FolderGit, upstream: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Push \(git.branch) to \(upstream)")
                .font(.system(size: 12, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(git.unpushed, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ink.opacity(0.85))
                            .lineLimit(2)
                    }
                    if git.ahead > git.unpushed.count {
                        Text("and \(git.ahead - git.unpushed.count) more")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.ink.opacity(0.55))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            Text("A push cannot be taken back, so it is only ever done by you, here.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer(minLength: 4)
                BoardButton("Cancel") { showPush = false }
                BoardButton("Push", icon: "arrow.up", prominent: true) {
                    showPush = false
                    advanced.pushFolder(project.id)
                }
            }
        }
        .padding(12)
        .frame(width: 440)
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.amber)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            IconButton("xmark", help: "Dismiss") { advanced.notices[project.id] = nil }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.amber.opacity(0.12)))
    }
}
