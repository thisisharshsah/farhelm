import SwiftUI

// Two views over one board's tasks, Kanban and Table grouped by sprint, and
// the card they share. Findings and decisions: docs/design/board-concepts.md.

// MARK: - Kanban

struct KanbanMockup: View {
    @Environment(\.widthClass) private var widthClass
    private let sprint = MockBoard.active

    /// Four columns side by side only where each keeps a card's width;
    /// narrower, they wrap and then stack, so nothing scrolls out of sight.
    private var perRow: Int {
        switch widthClass {
        case .compact: 1
        case .regular: 2
        case .wide: 4
        }
    }

    var body: some View {
        MockScreen(selected: .kanban) {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                SprintHeader(sprint: sprint)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Design.Space.s, alignment: .top),
                                         count: perRow),
                          alignment: .leading, spacing: Design.Space.s) {
                    ForEach([MockColumn.todo, .inProgress, .review, .done]) { column in
                        KanbanColumn(column: column,
                                     tasks: MockBoard.tasks(in: sprint).filter { $0.column == column })
                    }
                }
            }
            .mockContent()
        }
    }
}

struct KanbanColumn: View {
    let column: MockColumn
    let tasks: [MockTask]

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.xs) {
                Text(column.rawValue).textRole(.heading)
                Text("\(tasks.count)").textRole(.caption, .secondary).monospacedDigit()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Design.Space.xxs)
            ForEach(tasks) { TaskCard(task: $0) }
            if tasks.isEmpty {
                Text("Nothing here").textRole(.caption, .tertiary)
            }
        }
        .padding(Design.Space.s)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Design.Radius.shape(Design.Radius.tile).fill(Design.Fill.raised.style))
    }
}

// MARK: - Table grouped by sprint

struct TableMockup: View {
    var body: some View {
        MockScreen(selected: .table) {
            VStack(alignment: .leading, spacing: Design.Space.xl) {
                ForEach(MockBoard.sprints) { TableGroup(sprint: $0) }
            }
            .mockContent()
        }
    }
}

/// One sprint as a group: the active sprint first, the backlog under it.
struct TableGroup: View {
    let sprint: MockSprint
    var selected: String?
    var showsBattery = true
    @Environment(\.widthClass) private var widthClass

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsBattery {
                SprintHeader(sprint: sprint).padding(.bottom, Design.Space.s)
            } else {
                Text(sprint.name).textRole(.heading).padding(.bottom, Design.Space.xs)
            }
            if widthClass != .compact {
                TableHeaderRow()
            }
            ForEach(MockBoard.tasks(in: sprint)) { task in
                Hairline()
                TableRow(task: task, selected: task.id == selected)
            }
        }
    }
}

struct TableHeaderRow: View {
    @Environment(\.widthClass) private var widthClass

    var body: some View {
        HStack(spacing: Design.Space.s) {
            if widthClass == .wide {
                Text("Task").frame(width: MockMetrics.tableID, alignment: .leading)
                Text("").frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Task").frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("State").frame(width: MockMetrics.tableState, alignment: .leading)
            Text("Specialist").frame(width: MockMetrics.tableSpecialist, alignment: .leading)
            Text("Tokens").frame(width: tokenWidth, alignment: .trailing)
        }
        .textRole(.caption, .tertiary)
        .padding(.horizontal, Design.Space.xs)
        .padding(.bottom, Design.Space.xxs)
    }

    private var tokenWidth: CGFloat {
        widthClass == .wide ? MockMetrics.tableTokens : MockMetrics.tableID * 2
    }
}

/// A row with room around it and no grid lines between cells: the columns
/// line up by width alone, which keeps it from reading as a spreadsheet.
struct TableRow: View {
    let task: MockTask
    var selected = false
    @Environment(\.widthClass) private var widthClass

    var body: some View {
        Group {
            switch widthClass {
            case .compact: stacked
            case .regular: row(showsID: false)
            case .wide: row(showsID: true)
            }
        }
        .padding(.horizontal, Design.Space.xs)
        .padding(.vertical, Design.Space.xs)
        .frame(minHeight: Design.Density.regular.rowHeight)
        .background {
            if selected {
                Design.Radius.shape(Design.Radius.control)
                    .fill(Design.Tone.accent.color.opacity(MockMetrics.tint))
            }
        }
    }

    private func row(showsID: Bool) -> some View {
        HStack(spacing: Design.Space.s) {
            if showsID {
                Text(task.id).textRole(.caption, .secondary).monospacedDigit()
                    .frame(width: MockMetrics.tableID, alignment: .leading)
                // Two lines rather than an ellipsis: a title is what a person
                // scans the table for, so it keeps its words before its width.
                Text(task.title).textRole(.body).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.xs) {
                    Text(task.id).textRole(.caption, .secondary).monospacedDigit().fixedSize()
                    Text(task.title).textRole(.body).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            state.frame(width: MockMetrics.tableState, alignment: .leading)
            SpecialistChip(role: task.role, model: task.model)
                .frame(width: MockMetrics.tableSpecialist, alignment: .leading)
            TaskTokens(task: task)
                .frame(width: showsID ? MockMetrics.tableTokens : MockMetrics.tableID * 2, alignment: .trailing)
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.xs) {
                Text(task.id).textRole(.caption, .secondary).monospacedDigit()
                Text(task.title).textRole(.body).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Design.Space.xs) {
                state
                SpecialistChip(role: task.role, model: task.model)
                Spacer(minLength: Design.Space.xs)
                TaskTokens(task: task)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var state: some View {
        if let state = task.state {
            StatePill(state: state)
        } else {
            QuietState(task: task)
        }
    }
}

// MARK: - Card

/// A card at its board width, then every state pill and specialist chip.
struct CardMockup: View {
    var body: some View {
        MockScreen(title: "Card", subtitle: MockBoard.name, selected: .kanban) {
            VStack(alignment: .leading, spacing: Design.Space.xl) {
                section("A card") {
                    // A grid rather than a row, so the same three cards fill
                    // the frame at every width: three across when wide, fewer
                    // and wider below that, never stopping short of the edge.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: MockMetrics.sampleCard),
                                                 spacing: Design.Space.s, alignment: .top)],
                              alignment: .leading, spacing: Design.Space.s) {
                        ForEach(["T-63", "T-65", "T-64"], id: \.self) {
                            TaskCard(task: MockBoard.task($0))
                        }
                    }
                }
                section("Five states, five fixed colors") {
                    AdaptiveStack(spacing: Design.Space.xs) {
                        ForEach(MockState.allCases) { StatePill(state: $0, size: .regular) }
                    }
                }
                section("Specialist: role, then model") {
                    AdaptiveStack(spacing: Design.Space.xs) {
                        ForEach(MockBoard.specialists.filter { $0.seat != 2 }) {
                            SpecialistChip(role: $0.role, model: $0.model)
                        }
                        SpecialistChip(role: nil, model: nil)
                    }
                }
            }
            .mockContent()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text(title).textRole(.heading)
            content()
        }
    }
}