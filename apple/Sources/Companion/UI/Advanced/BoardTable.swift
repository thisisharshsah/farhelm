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
    var filters = BoardFilters()
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
            let visible = board.items.filter(filters.matches).sorted { $0.number < $1.number }
            var found = board.milestones.map { name in
                RowGroup(id: "phase." + name, title: name, tint: Design.Tone.accent.color,
                         items: visible.filter { $0.milestone == name })
            }
            let loose = visible.filter { ($0.milestone ?? "").isEmpty }
            if !loose.isEmpty {
                found.append(RowGroup(id: "phase.none", title: "No phase", tint: .secondary, items: loose))
            }
            return found
        }
        return WorkStatus.allCases.map { status in
            RowGroup(id: status.rawValue, title: status.title, tint: status.tint,
                     items: board.items(in: status).filter(filters.matches))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Design.Space.xs) {
                Text("Group by")
                    .textRole(.label, .secondary)
                ForEach(Grouping.allCases) { choice in
                    BoardButton(choice.title, tint: grouping == choice.rawValue ? Design.Tone.accent.color : nil) {
                        grouping = choice.rawValue
                    }
                }
                Spacer()
            }
            .padding(.horizontal, Design.Space.s)
            .padding(.vertical, Design.Space.xxs)
            .glassToolbarGroup()
            .padding(.horizontal, Design.Space.xs)
            .padding(.top, Design.Space.xs)
            .padding(.bottom, Design.Space.xxs)
            GeometryReader { geometry in
                ScrollView([.vertical, .horizontal], showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Design.Space.s) {
                        ForEach(groups) { group in
                            if !group.items.isEmpty {
                                section(group)
                            }
                        }
                    }
                    .padding(.horizontal, Design.Space.s)
                    .padding(.bottom, Design.Space.l)
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
            HStack(spacing: Design.Space.xs) {
                Image(systemName: "chevron.right")
                    .font(Design.TextRole.caption.font.weight(.bold))
                    .rotationEffect(.degrees(isFolded ? 0 : 90))
                    .foregroundStyle(group.tint)
                Text(group.title)
                    .font(Design.TextRole.label.font.weight(.semibold))
                    .foregroundStyle(group.tint)
                Text("\(group.items.count)")
                    .font(Design.TextRole.caption.font.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if !total.isEmpty {
                    Text("\(BoardText.tokens(total)) tokens · \(Money.text(total.cost))")
                        .font(Design.TextRole.caption.font)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if estimate > 0 {
                    Text("est \(ContextUse.short(estimate))")
                        .font(Design.TextRole.caption.font)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Design.Space.xs)
            .frame(height: Design.Control.regular.height)
            .glassToolbarGroup()
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
            .font(Design.TextRole.caption.font.weight(.semibold))
            .foregroundStyle(.tertiary)
            .frame(width: width, alignment: trailing ? .trailing : .leading)
    }

    static var header: some View {
        HStack(spacing: Design.Space.xs) {
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
        .padding(.leading, Design.Space.s)
        .frame(height: Design.Control.small.height)
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

    private func number(_ text: String, _ width: CGFloat, tint: Color? = nil, faint: Bool = false) -> some View {
        Text(text)
            .font(Design.TextRole.label.font)
            .monospacedDigit()
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? (faint ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary)))
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }

    var body: some View {
        let estimate = item.estimateTokens ?? 0
        let over = estimate > 0 && used.tokens > estimate
        HStack(spacing: Design.Space.xs) {
            Text(item.key)
                .font(Design.TextRole.caption.font.monospaced().weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: TableColumns.key, alignment: .leading)
            HStack(spacing: Design.Space.xxs) {
                if item.activeRun != nil {
                    LoadingMark(state: .working, size: Design.Icon.small.width - Design.Space.xxs)
                }
                Text(item.title)
                    .textRole(.label, item.status == .done ? .secondary : .primary)
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
            HStack(spacing: Design.Space.xxs) {
                Image(systemName: item.kind.icon)
                    .font(Design.TextRole.caption.font.weight(.medium))
                Text(item.kind.title)
                    .font(Design.TextRole.label.font)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .frame(width: TableColumns.kind, alignment: .leading)
            Text(item.dependsOn.isEmpty ? "" : item.dependsOn.map { "T-\($0)" }.joined(separator: ", "))
                .font(Design.TextRole.caption.font.monospaced())
                .foregroundStyle(board.blockers(of: item).isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Design.Tone.caution.color))
                .lineLimit(1)
                .frame(width: TableColumns.waits, alignment: .leading)
            number(estimate > 0 ? ContextUse.short(estimate) : "", TableColumns.estimate, faint: true)
            number(used.isEmpty ? "" : BoardText.tokens(used), TableColumns.used, tint: over ? Design.Tone.caution.color : nil)
            number(used.isEmpty ? "" : Money.text(used.cost), TableColumns.cost)
            number(BoardText.when(item.updatedAt), TableColumns.updated, faint: true)
        }
        .padding(.leading, Design.Space.xs)
        .frame(height: Design.Control.large.height)
        .background(selected ? AnyShapeStyle(Design.Tone.accent.color.opacity(0.16))
                    : AnyShapeStyle(hover ? Design.Fill.raised.style : Design.Fill.content.style))
        .overlay(alignment: .leading) {
            Rectangle().fill(edge).frame(width: Design.Space.xxs - 1)
        }
        .clipShape(Design.Radius.shape(Design.Radius.chip))
        .padding(.vertical, Design.Space.xxs / 4)
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
        let entries = WorkStatus.allCases.map { status in
            MenuEntry(status.title, symbol: status.icon, selected: status == item.status) {
                Advanced.shared.move(item.id, to: status, in: project.id)
            }
        }
        SectionedMenu(item.status.title, symbol: item.status.icon,
                      groups: [MenuGroup("Status", entries: entries)])
            .help("Move \(item.key) to another status")
    }
}

/// The board's models as the searchable picker lists them: grouped by
/// where they run, each with badges for its source, its cost and how much
/// it holds, and its tier and the supervisor's pick in the line under it.
@MainActor
enum BoardModelChoices {
    /// The row that confirms a model the supervisor or a rule chose.
    static let confirmID = "\u{1F}confirm"

    private static func price(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    static func source(_ place: ModelProfile.Place) -> SelectionBadge {
        switch place {
        case .local: return SelectionBadge("Local", symbol: "lock", tone: .positive)
        case .api: return SelectionBadge("API", symbol: "cloud", tone: .info)
        case .account: return SelectionBadge("Account", symbol: "person", tone: .neutral)
        }
    }

    static func cost(_ profile: ModelProfile) -> SelectionBadge {
        let free = profile.inputPrice == 0 && profile.outputPrice == 0
        let perMillion = "$\(price(profile.inputPrice)) in, $\(price(profile.outputPrice)) out per 1M"
        switch profile.place {
        case .local: return free ? SelectionBadge("Free", tone: .positive) : SelectionBadge(perMillion, tone: .caution)
        case .account: return SelectionBadge("In your plan", tone: .neutral)
        case .api: return free ? SelectionBadge("Price not set", tone: .caution) : SelectionBadge(perMillion, tone: .caution)
        }
    }

    static func window(_ tokens: Int) -> SelectionBadge {
        let text = tokens >= 1_000_000
            ? "\(price(Double(tokens) / 1_000_000))M window"
            : "\(tokens / 1_000)k window"
        return SelectionBadge(text, symbol: "text.alignleft", tone: .neutral)
    }

    static func sections(_ roster: [ModelRoster.Entry], for item: WorkItem) -> [SelectionSection<String>] {
        var result: [SelectionSection<String>] = []
        if let assignment = item.assignment, !assignment.accepted, assignment.source != .person {
            result.append(SelectionSection(id: "confirm", title: "Waiting for you", symbol: "checkmark.circle", items: [
                SelectionItem(id: confirmID, title: "Confirm \(BoardText.modelName(assignment.label))",
                              subtitle: "Keep the model this task was given", symbol: "checkmark"),
            ]))
        }
        let places: [(ModelProfile.Place, String, String)] = [
            (.local, "On this Mac", "lock"), (.api, "API", "cloud"), (.account, "Your accounts", "person"),
        ]
        for (place, title, symbol) in places {
            let items = roster.filter { $0.profile.place == place }.map { entry -> SelectionItem<String> in
                let profile = entry.profile
                let advised = item.suggestion?.model == entry.engine.choice
                var detail = [profile.tier.title]
                if !profile.tools { detail.append("no native tool calls") }
                if advised { detail.append("Recommended by the supervisor") }
                return SelectionItem(id: profile.choice.key, title: profile.name,
                                     subtitle: detail.joined(separator: " \u{00B7} "),
                                     symbol: advised ? "star" : nil,
                                     badges: [source(place), cost(profile), window(profile.window)],
                                     keywords: [profile.tier.title, place.rawValue])
            }
            if !items.isEmpty {
                result.append(SelectionSection(id: place.rawValue, title: title, symbol: symbol, items: items))
            }
        }
        return result
    }
}

/// A task's model as a chip that opens the searchable picker of the models
/// it could be given to.
struct ModelMenu: View {
    @ObservedObject private var advanced = Advanced.shared
    let project: Project
    let item: WorkItem
    var limit = 20
    @State private var isOpen = false

    private static let recent = RecentChoices(key: "board.modelPicker.recent")

    private func choose(_ id: String) {
        isOpen = false
        if id == BoardModelChoices.confirmID {
            advanced.change(project.id) { $0.acceptAssignment(item.id, now: Date()) }
            return
        }
        guard let entry = advanced.roster.first(where: { $0.profile.choice.key == id }) else { return }
        Self.recent.record(id)
        advanced.assign(item.id, to: entry, in: project.id)
    }

    var body: some View {
        Button { isOpen.toggle() } label: {
            ModelChip(assignment: item.assignment, limit: limit)
        }
        .buttonStyle(.plain)
        .help("Choose the model for \(item.key)")
        .accessibilityLabel("Model for \(item.key)")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            SearchablePicker(
                title: "Model", sections: BoardModelChoices.sections(advanced.roster, for: item),
                selection: item.assignment?.model.key, recents: Self.recent.ids(),
                prompt: "Search models", maxHeight: 320, framed: false,
                footer: SelectionFooter("Suggest by rule", symbol: "wand.and.stars") {
                    isOpen = false
                    advanced.suggestByRule(item.id, in: project.id)
                },
                onSelect: choose, onClose: { isOpen = false })
                .environment(\.density, .compact)
                .frame(width: 380)
        }
        .onAppear { if advanced.roster.isEmpty { advanced.refreshRoster() } }
    }
}
