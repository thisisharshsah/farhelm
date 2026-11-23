import CompanionBoard
import SwiftUI

/// The ways a board can be looked at.
enum BoardViewKind: String, CaseIterable, Identifiable {
    /// Columns by status, cards dragged between them.
    case board
    /// Every task as a row, grouped by status, with its numbers.
    case table
    /// Tasks along a line of time: when each waited, was worked on, ended.
    case timeline
    /// What the work cost: per model, task, chat and day.
    case usage

    var id: String { rawValue }

    /// Where the view in use is kept, so another part of the app (a
    /// project's page) can open the board on a given view.
    static let storageKey = "boardView"

    var title: String {
        switch self {
        case .board: return "Board"
        case .table: return "Table"
        case .timeline: return "Timeline"
        case .usage: return "Usage"
        }
    }

    var icon: String {
        switch self {
        case .board: return "rectangle.split.3x1"
        case .table: return "tablecells"
        case .timeline: return "chart.bar.xaxis"
        case .usage: return "gauge.with.dots.needle.50percent"
        }
    }
}

/// Advanced mode's middle column: one project's board. Like the workspace,
/// it is several panels a gap apart: the header (the project, its
/// progress, its cost and how it is run), the view chosen (board, table,
/// timeline or usage), and beside it the task that is selected.
struct BoardPane: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var advanced = Advanced.shared
    @ObservedObject private var store = BoardStore.shared
    /// Watched so the numbers follow the requests as they are made.
    @ObservedObject private var usage = UsageStore.shared
    @AppStorage(BoardViewKind.storageKey) private var viewName = BoardViewKind.board.rawValue

    /// The board's project: the open chat's, or the last one shown while
    /// a chat outside any project is open.
    private var project: Project? { app.currentProject ?? advanced.lastProject }

    private var kind: BoardViewKind { BoardViewKind(rawValue: viewName) ?? .board }

    var body: some View {
        Group {
            if let project {
                if let board = store.boards[project.id] {
                    loaded(project, board)
                } else {
                    // Read as soon as the pane is on screen.
                    Color.clear
                }
            } else {
                ProjectChooser()
                    .panelCard()
            }
        }
        .onAppear { follow() }
        .onChange(of: app.currentProject?.id) { _, _ in follow() }
    }

    /// The board follows the open chat's project.
    private func follow() {
        if let project = app.currentProject ?? advanced.lastProject {
            advanced.follow(project)
        }
    }

    private func loaded(_ project: Project, _ board: Board) -> some View {
        let ledger = advanced.ledger(for: project.id)
        let selected = advanced.selectedItem.flatMap { board.item($0) }
        return GeometryReader { geometry in
            // A task's details sit beside the view when there is room for
            // both; in a narrow pane they take its place.
            let beside = geometry.size.width >= 760
            VStack(spacing: Theme.panelGap) {
                BoardHeader(project: project, board: board, ledger: ledger, compact: geometry.size.width < 640,
                            viewName: $viewName)
                    .panelCard()
                HStack(spacing: Theme.panelGap) {
                    if selected == nil || beside {
                        content(project, board, ledger)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .panelCard()
                    }
                    if let selected {
                        TaskInspector(project: project, board: board, item: selected, used: ledger.total(of: selected))
                            .frame(maxHeight: .infinity, alignment: .top)
                            .frame(width: beside ? 312 : nil)
                            .frame(maxWidth: beside ? nil : .infinity)
                            .panelCard()
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: advanced.selectedItem)
        }
    }

    @ViewBuilder
    private func content(_ project: Project, _ board: Board, _ ledger: Ledger) -> some View {
        if board.items.isEmpty, kind != .usage {
            EmptyBoard(project: project, board: board)
        } else {
            switch kind {
            case .board: BoardKanban(project: project, board: board, ledger: ledger)
            case .table: BoardTable(project: project, board: board, ledger: ledger)
            case .timeline: BoardTimeline(project: project, board: board)
            case .usage: BoardUsage(project: project, board: board, ledger: ledger)
            }
        }
    }
}

/// No project is open: the projects there are, to choose the one to run.
private struct ProjectChooser: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var advanced = Advanced.shared

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: AppMode.advanced.icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Choose a project to run")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.ink.opacity(0.95))
            Text("A supervisor plans the project as a board of tasks, gives each to the model that suits it, and tracks what every one costs.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            VStack(spacing: 4) {
                // A project that is off the list with its board still
                // here: put back as it was, and opened.
                ForEach(advanced.lostProjects) { lost in
                    Button {
                        advanced.bringBack(lost)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.amber)
                            Text("Bring back \(lost.name)")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Theme.ink.opacity(0.92))
                            Spacer(minLength: 8)
                            Text(lost.tasks == 1 ? "1 task" : "\(lost.tasks) tasks, \(lost.done) done")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.ink.opacity(0.5))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                            .fill(Theme.amber.opacity(0.14)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("It was taken off the list, which left its board and its chats without it. This puts it back as it was.")
                }
                ForEach(app.projects) { project in
                    Button {
                        Advanced.shared.open(project)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.ink.opacity(0.55))
                            Text(project.name)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Theme.ink.opacity(0.92))
                            Spacer(minLength: 8)
                            Text(project.abbreviatedFolder ?? "No folder")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.ink.opacity(0.45))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                            .fill(Theme.ink.opacity(0.07)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 420)
            BoardButton("Add a project folder", icon: "plus") { app.addProject() }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { advanced.lookForLostProjects() }
    }
}

/// A board with nothing on it yet. With no goal, it asks what the project
/// should achieve, and the supervisor plans it. With a goal that has its
/// words but no tasks (one just started, say), it offers to have that
/// goal planned.
private struct EmptyBoard: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var advanced = Advanced.shared
    let project: Project
    let board: Board
    @State private var goal = ""
    @FocusState private var focused: Bool

    /// The goal being worked toward has been put into words.
    private var said: Bool { !board.goal.isEmpty }

    private var ready: Bool { said || !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func plan() {
        guard ready else { return }
        if said {
            app.tellSupervisor(BoardPrompts.planGoal(board.goal, carried: 0), project: project)
        } else {
            app.tellSupervisor(BoardPrompts.plan(goal.trimmingCharacters(in: .whitespacesAndNewlines)), project: project)
            goal = ""
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            // A board that belongs to no project on the list: this
            // project's, from before it was taken off the list and added
            // again. Bringing it back comes before planning anything new.
            if board.isUnplanned, !advanced.strays.isEmpty {
                StrayBoards(project: project, strays: advanced.strays)
            }
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(said ? "Nothing is planned for this goal yet" : "Nothing is planned for \(project.name) yet")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.ink.opacity(0.95))
            if said {
                Text(board.goal)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
                    .frame(maxWidth: 440)
                    .textSelection(.enabled)
                Text("The supervisor breaks it into tasks, says what done means for each, and suggests a model for each one. You can also talk it through in the chat on the right first.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            } else {
                Text("Say what the project should achieve. The supervisor breaks it into tasks, says what done means for each, and suggests a model for each one. You can also talk it through in the chat on the right first.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                TextField("What should this project achieve?", text: $goal, axis: .vertical)
                    .lineLimit(2...6)
                    .boardField()
                    .focused($focused)
                    .frame(maxWidth: 440)
                    .onSubmit { plan() }
            }
            HStack(spacing: 8) {
                BoardButton("Plan it", icon: "wand.and.stars", prominent: true) { plan() }
                    .opacity(ready ? 1 : 0.45)
                    .disabled(!ready)
                BoardButton("Add a task by hand", icon: "plus") {
                    Advanced.shared.selectedItem = Advanced.shared.addTask(BoardRules.newTaskTitle, status: .todo, in: project.id)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Boards that belong to no project on the list, offered on a project
/// whose own board has nothing on it. Each says what it was for, how far
/// it got and when it was last changed, so the right one is plain to see.
/// Bringing one back makes it this project's board again, with its goals,
/// its tasks and the chats that were its.
private struct StrayBoards: View {
    @ObservedObject private var advanced = Advanced.shared
    let project: Project
    let strays: [Board]

    private func facts(_ board: Board) -> String {
        let done = board.allItems.filter { $0.status == .done }.count
        var parts = [board.allItems.count == 1 ? "1 task" : "\(board.allItems.count) tasks", "\(done) done"]
        if board.goals.count > 1 { parts.append("\(board.goals.count) goals") }
        parts.append("last changed \(BoardText.when(board.updatedAt))")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.amber)
                Text(strays.count == 1 ? "A board was left behind" : "\(strays.count) boards were left behind")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.95))
            }
            Text("It belongs to no project on the list: its project was taken off the list. Bring it back and it is this project's board again, with its tasks and its goals, and its chats go back inside the project.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(strays.prefix(4)), id: \.project) { stray in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stray.goal.isEmpty ? (stray.allItems.first?.title ?? "A board with no goal in words") : stray.goal)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.ink.opacity(0.92))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(facts(stray))
                            .font(.system(size: 10.5))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink.opacity(0.5))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    BoardButton("Bring it back", icon: "arrow.uturn.backward", prominent: true) {
                        advanced.restore(stray.project, to: project)
                    }
                    .help("Make this the board of \(project.name) again, and put its chats back inside the project.")
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(Theme.ink.opacity(0.06)))
            }
        }
        .padding(12)
        .frame(maxWidth: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).fill(Theme.amber.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
            .strokeBorder(Theme.amber.opacity(0.35), lineWidth: 0.75))
        .padding(.bottom, 6)
    }
}
