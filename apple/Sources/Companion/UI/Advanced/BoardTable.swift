import CompanionBoard
import SwiftUI

/// The board as a table, in the manner of monday.com: every task a row
/// with its numbers, grouped by status (or by the plan's phases), each
/// group under its own heading with its totals. A group folds to its
/// heading with a click.
struct BoardTable: View {
    @ObservedObject private var advanced = Advanced.shared
    let project: Project
    let board: Board
    let ledger: Ledger
    @AppStorage("boardTableGroup") private var grouping = Grouping.status.rawValue
    @State private var folded: Set<String> = []

    enum Grouping: String, CaseIterable, Identifiable {
        case status, phase

        var id: String { rawValue }
        var title: String { self == .status ? "Status" : "Phase" }
    }

    private struct RowGroup: Identifiable {
        let id: String
        let title: String
        let tint: Color
        let items: [WorkItem]
    }

    private var groups: [RowGroup] {
        if grouping == Grouping.phase.rawValue, !board.milestones.isEmpty {
            var found = board.milestones.map { name in
                RowGroup(id: "phase." + name, title: name, tint: Theme.accent,
                      items: board.items.filter { $0.milestone == name }.sorted { $0.number < $1.number })
            }
            let loose = board.items.filter { ($0.milestone ?? "").isEmpty }.sorted { $0.number < $1.number }
            if !loose.isEmpty {
                found.append(RowGroup(id: "phase.none", title: "No phase", tint: Theme.ink.opacity(0.5), items: loose))
            }
            return found
        }
        return WorkStatus.allCases.map { status in
            RowGroup(id: status.rawValue, title: status.title, tint: status.tint, items: board.items(in: status))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Group by")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.55))
                ForEach(Grouping.allCases) { choice in
                    BoardButton(choice.title, tint: grouping == choice.rawValue ? Theme.accent : nil) {
                        grouping = choice.rawValue
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            GeometryReader { geometry in
                ScrollView([.vertical, .horizontal], showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(groups) { group in
                            if !group.items.isEmpty {
                                section(group)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                    // A table smaller than its panel sits at the top
                    // left, not in the middle.
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
            }
        }
    }

    private func section(_ group: RowGroup) -> some View {
        let isFolded = folded.contains(group.id)
        var total = UsageTotal()
        for item in group.items { total.add(ledger.total(of: item)) }
        let estimate = group.items.reduce(0) { $0 + ($1.estimateTokens ?? 0) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isFolded ? 0 : 90))
                    .foregroundStyle(group.tint)
                Text(group.title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(group.tint)
                Text("\(group.items.count)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink.opacity(0.5))
                if !total.isEmpty {
                    Text("\(BoardText.tokens(total)) tokens · \(Money.text(total.cost))")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink.opacity(0.5))
                }
                if estimate > 0 {
                    Text("est \(ContextUse.short(estimate))")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink.opacity(0.4))
                }
                Spacer(minLength: 0)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) {
                    if isFolded { folded.remove(group.id) } else { folded.insert(group.id) }
                }
            }
            if !isFolded {
                TableColumns.header
                ForEach(group.items) { item in
                    TableRow(project: project, board: board, item: item, used: ledger.total(of: item),
                             edge: group.tint)
                }
            }
        }
    }
}

/// The table's columns and their widths, in one place, so the heading and
/// every row line up.
private enum TableColumns {
    static let key: CGFloat = 48
    static let title: CGFloat = 250
    static let status: CGFloat = 104
    static let model: CGFloat = 170
    static let priority: CGFloat = 76
    static let kind: CGFloat = 80
    static let waits: CGFloat = 82
    static let estimate: CGFloat = 62
    static let used: CGFloat = 70
    static let cost: CGFloat = 62
    static let updated: CGFloat = 96

    private static func cell(_ text: String, _ width: CGFloat, trailing: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.ink.opacity(0.45))
            .frame(width: width, alignment: trailing ? .trailing : .leading)
    }

    static var header: some View {
        HStack(spacing: 8) {
            cell("", key)
            cell("Task", title)
            cell("Status", status)
            cell("Model", model)
            cell("Priority", priority)
            cell("Kind", kind)
            cell("Waits on", waits)
            cell("Estimate", estimate, trailing: true)
            cell("Used", used, trailing: true)
            cell("Cost", cost, trailing: true)
            cell("Updated", updated, trailing: true)
        }
        .padding(.leading, 11)
        .frame(height: 22)
    }
}

/// One task as a row. Its status and its model are changed right in the
/// row; a click anywhere else opens the task.
private struct TableRow: View {
    @ObservedObject private var advanced = Advanced.shared
    let project: Project
    let board: Board
    let item: WorkItem
    let used: UsageTotal
    /// The color of the group it is in, down its leading edge.
    let edge: Color
    @State private var hover = false

    private var selected: Bool { advanced.selectedItem == item.id }

    private func number(_ text: String, _ width: CGFloat, tint: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(tint ?? Theme.ink.opacity(0.75))
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }

    var body: some View {
        let estimate = item.estimateTokens ?? 0
        let over = estimate > 0 && used.tokens > estimate
        HStack(spacing: 8) {
            Text(item.key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.ink.opacity(0.45))
                .frame(width: TableColumns.key, alignment: .leading)
            HStack(spacing: 5) {
                if item.activeRun != nil {
                    LoadingMark(state: .working, size: 11)
                }
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink.opacity(item.status == .done ? 0.6 : 0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: TableColumns.title, alignment: .leading)
            StatusMenu(project: project, item: item)
                .frame(width: TableColumns.status, alignment: .leading)
            ModelMenu(project: project, item: item)
                .frame(width: TableColumns.model, alignment: .leading)
            PriorityMark(priority: item.priority, showsWord: true)
                .frame(width: TableColumns.priority, alignment: .leading)
            HStack(spacing: 4) {
                Image(systemName: item.kind.icon)
                    .font(.system(size: 9, weight: .medium))
                Text(item.kind.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.ink.opacity(0.7))
            .frame(width: TableColumns.kind, alignment: .leading)
            Text(item.dependsOn.isEmpty ? "" : item.dependsOn.map { "T-\($0)" }.joined(separator: ", "))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(board.blockers(of: item).isEmpty ? Theme.ink.opacity(0.5) : Theme.amber)
                .lineLimit(1)
                .frame(width: TableColumns.waits, alignment: .leading)
            number(estimate > 0 ? ContextUse.short(estimate) : "", TableColumns.estimate, tint: Theme.ink.opacity(0.5))
            number(used.isEmpty ? "" : BoardText.tokens(used), TableColumns.used, tint: over ? Theme.amber : nil)
            number(used.isEmpty ? "" : Money.text(used.cost), TableColumns.cost)
            number(BoardText.when(item.updatedAt), TableColumns.updated, tint: Theme.ink.opacity(0.5))
        }
        .padding(.leading, 8)
        .frame(height: 32)
        .background(Theme.ink.opacity(selected ? 0.11 : (hover ? 0.06 : 0.025)))
        .overlay(alignment: .leading) {
            Rectangle().fill(edge.opacity(0.85)).frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous))
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture { advanced.selectedItem = selected ? nil : item.id }
        .onHover { hover = $0 }
    }
}

/// A task's status as a pill that opens the other statuses to move it to.
struct StatusMenu: View {
    let project: Project
    let item: WorkItem

    var body: some View {
        Menu {
            ForEach(WorkStatus.allCases) { status in
                Button {
                    Advanced.shared.move(item.id, to: status, in: project.id)
                } label: {
                    Label(status.title + (status == item.status ? "  ✓" : ""), systemImage: status.icon)
                }
            }
        } label: {
            WorkStatusPill(status: item.status)
        }
        .boardMenu()
        .help("Move \(item.key) to another status")
    }
}

/// A task's model as a chip that opens the models it could be given to.
struct ModelMenu: View {
    @ObservedObject private var advanced = Advanced.shared
    let project: Project
    let item: WorkItem
    var limit = 20

    /// A model as a line of the menu: its name, where it runs and how
    /// capable it is, with a tick on the one the task has and a star on
    /// the one the supervisor picked for it.
    private func title(_ entry: ModelRoster.Entry) -> String {
        let place: String
        switch entry.profile.place {
        case .local: place = "on this Mac"
        case .account: place = "subscription"
        case .api: place = "API"
        }
        let chosen = item.assignment?.model == entry.engine.choice
        let advised = item.suggestion?.model == entry.engine.choice
        return "\(entry.profile.name) (\(place), \(entry.profile.tier.title.lowercased()))"
            + (advised ? "  ★ Recommended" : "") + (chosen ? "  ✓" : "")
    }

    var body: some View {
        Menu {
            if let assignment = item.assignment, !assignment.accepted, assignment.source != .person {
                Button {
                    advanced.change(project.id) { $0.acceptAssignment(item.id, now: Date()) }
                } label: {
                    Label("Confirm \(assignment.label)", systemImage: "checkmark")
                }
                Divider()
            }
            ForEach(advanced.roster) { entry in
                Button(title(entry)) {
                    advanced.assign(item.id, to: entry, in: project.id)
                }
            }
            if advanced.roster.isEmpty {
                Text("No engine is set up. Add one in Settings.")
            }
            Divider()
            Button {
                advanced.suggestByRule(item.id, in: project.id)
            } label: {
                Label("Suggest by Rule", systemImage: "wand.and.stars")
            }
        } label: {
            ModelChip(assignment: item.assignment, limit: limit)
        }
        .boardMenu()
        .onAppear { if advanced.roster.isEmpty { advanced.refreshRoster() } }
    }
}
