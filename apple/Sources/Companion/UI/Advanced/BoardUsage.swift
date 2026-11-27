import AppKit
import CompanionBoard
import SwiftUI

/// What the project has cost: every request made for it, under all its
/// goals, added up per goal, model, task, chat, purpose and day, against
/// the budget. Counts come
/// from the engines where they give them; the rest are estimated from the
/// text and marked with a "~".
struct BoardUsage: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var advanced = Advanced.shared
    let project: Project
    let board: Board
    let ledger: Ledger

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                tiles
                BudgetEditor(project: project, board: board, spent: ledger.total)
                if ledger.total.isEmpty {
                    Text("Nothing has been asked of a model for this project yet. Every request shows here as it is made, with what it used.")
                        .textRole(.label, .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if board.goals.count > 1 { byGoal }
                    byModel
                    byTask
                    byChat
                    byPurpose
                    byDay
                    HStack {
                        BoardButton("Copy as CSV", icon: "doc.on.doc") { copyCSV() }
                            .help("Every request of this project, one a row, to paste into a spreadsheet")
                        Spacer()
                    }
                }
            }
            .padding(Design.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: The totals

    private var tiles: some View {
        let total = ledger.total
        // The project's cost is that of all its goals, so its finished
        // tasks are counted under all of them too.
        let done = board.allItems.filter { $0.status == .done }
        let plan = ledger.plan
        var doneTotal = UsageTotal()
        var doneCovered = UsageTotal()
        for item in done {
            doneTotal.add(ledger.total(of: item))
            doneCovered.add(plan.total(of: item))
        }
        let overhead = ledger.overheadShare(purposes: Advanced.overheadPurposes)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: Design.Space.xs)],
                         alignment: .leading, spacing: Design.Space.xs) {
            tile("Tokens", BoardText.tokens(total),
                 "\(ContextUse.short(total.inputTokens)) in · \(ContextUse.short(total.output)) out")
            tile("Cost", BoardCost.text(total, covered: plan.total),
                 total.cacheRead > 0 ? "\(ContextUse.short(total.cacheRead)) read from cache" : "at the prices in Settings")
            tile("Requests", "\(total.requests)",
                 total.requests > 0 ? "\(BoardText.duration(total.seconds)) of model time" : "none yet")
            tile("Supervising", "\(Int((overhead * 100).rounded()))%",
                 "of the tokens went on planning and review")
            tile("Per task done", done.isEmpty ? "n/a" : ContextUse.short(doneTotal.tokens / done.count),
                 done.isEmpty ? "no task is done yet" : "\(BoardCost.each(doneTotal, covered: doneCovered, count: done.count)), over \(done.count)")
        }
    }

    private func tile(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            BoardHeading(title)
            Text(value)
                .font(Design.TextRole.title.font.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .textRole(.caption, .secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Design.Space.s)
        .frame(maxWidth: .infinity, minHeight: Design.Space.xxl * 2.5, alignment: .topLeading)
        .background(Design.Fill.raised.style, in: Design.Radius.shape(Design.Radius.tile))
    }

    // MARK: Breakdowns

    /// The width of a breakdown's number columns, so they line up down the list.
    private static let numberWidth: CGFloat = 58
    /// Wide enough for "Covered by plan", so a row never changes height or shifts its columns.
    private static let costWidth: CGFloat = 96

    /// One line of a breakdown: its name, its share as a bar, its numbers.
    private func line(_ name: String, _ total: UsageTotal, covered: UsageTotal = UsageTotal(), most: Int,
                      tint: Color = Design.Tone.accent.color,
                      detail: String = "", action: (() -> Void)? = nil) -> some View {
        HStack(spacing: Design.Space.xs) {
            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                HStack(spacing: Design.Space.xxs) {
                    Text(name)
                        .textRole(.label, .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !detail.isEmpty {
                        Text(detail)
                            .textRole(.caption, .tertiary)
                            .lineLimit(1)
                    }
                }
                ShareBar(fraction: most > 0 ? Double(total.tokens) / Double(most) : 0, tint: tint,
                         height: Design.Space.xxs)
            }
            Text(BoardText.tokens(total))
                .textRole(.number, .primary)
                .frame(width: Self.numberWidth, alignment: .trailing)
            Text(BoardCost.text(total, covered: covered))
                .textRole(.number, .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: Self.costWidth, alignment: .trailing)
        }
        .padding(.vertical, Design.Space.xxs / 2)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            BoardHeading(title)
            content()
        }
    }

    /// What each goal took, the newest first: the one being worked toward
    /// and the ones before it.
    private var byGoal: some View {
        let used = board.usageByGoal(ledger)
        let onPlan = board.usageByGoal(ledger.plan)
        let goals = board.goals.sorted { $0.number > $1.number }
        let most = goals.compactMap { used[$0.id]?.tokens }.max() ?? 0
        return section("By goal") {
            ForEach(goals) { goal in
                let progress = board.progress(of: goal.id)
                line("\(goal.key) \(goal.text.isEmpty ? "Not put into words" : goal.text)", used[goal.id] ?? UsageTotal(),
                     covered: onPlan[goal.id] ?? UsageTotal(),
                     most: most, tint: goal.status.tint,
                     detail: "\(goal.status.title.lowercased()) · \(progress.done) of \(progress.all) done")
            }
        }
    }

    private var byModel: some View {
        let lines = ledger.byModel { engine, model in advanced.modelName(engine: engine, model: model) }
        let most = lines.first?.total.tokens ?? 0
        return section("By model") {
            ForEach(lines) { entry in
                let onPlan = entry.id.hasPrefix(LLMProviderKind.subscription.rawValue + "|")
                line(entry.name, entry.total, covered: onPlan ? entry.total : UsageTotal(),
                     most: most, detail: "\(entry.total.requests) requests")
            }
        }
    }

    private var byTask: some View {
        let used = board.allItems.map { (item: $0, total: ledger.total(of: $0)) }
            .filter { !$0.total.isEmpty }
            .sorted { $0.total.tokens > $1.total.tokens }
        let most = used.first?.total.tokens ?? 0
        let plan = ledger.plan
        return section("By task") {
            if used.isEmpty {
                Text("No run has been made on a task yet.")
                    .textRole(.label, .tertiary)
            }
            ForEach(used, id: \.item.id) { entry in
                let estimate = entry.item.estimateTokens ?? 0
                line("\(entry.item.key) \(entry.item.title)", entry.total, covered: plan.total(of: entry.item), most: most,
                     tint: estimate > 0 && entry.total.tokens > estimate ? Design.Tone.caution.color : entry.item.status.tint,
                     detail: estimate > 0 ? "est \(ContextUse.short(estimate))" : "") {
                    advanced.selectedItem = entry.item.id
                }
            }
        }
    }

    /// A chat's name: the supervisor's, a run's task, or its own title.
    private func chatName(_ id: UUID) -> String {
        if id == board.supervisorChat { return "Supervisor" }
        if let item = board.item(runIn: id) { return "\(item.key) \(item.title)" }
        return app.history.first { $0.id == id }?.title ?? (id == app.conversation.id ? app.conversation.title : "A chat no longer on the list")
    }

    private var byChat: some View {
        let chats = ledger.byConversation.map { (id: $0.key, total: $0.value) }
            .sorted { ($1.total.tokens, $0.id.uuidString) < ($0.total.tokens, $1.id.uuidString) }
        let most = chats.first?.total.tokens ?? 0
        let onPlan = ledger.plan.byConversation
        return section("By conversation") {
            ForEach(chats.prefix(40), id: \.id) { chat in
                line(chatName(chat.id), chat.total, covered: onPlan[chat.id] ?? UsageTotal(), most: most,
                     tint: Design.Tone.info.color,
                     detail: "\(chat.total.requests) requests") {
                    app.openConversation(chat.id)
                }
                .help("Open this chat")
            }
            if chats.count > 40 {
                Text("\(chats.count - 40) more, each smaller than these.")
                    .textRole(.caption, .tertiary)
            }
        }
    }

    private var byPurpose: some View {
        let lines = ledger.byPurpose
        let most = lines.first?.total.tokens ?? 0
        let onPlan = Dictionary(ledger.plan.byPurpose.map { ($0.id, $0.total) }, uniquingKeysWith: { first, _ in first })
        return section("By kind of work") {
            ForEach(lines) { entry in
                line(entry.name, entry.total, covered: onPlan[entry.id] ?? UsageTotal(), most: most,
                     tint: Advanced.overheadPurposes.contains(entry.name) ? Design.Tone.caution.color : Design.Tone.positive.color)
            }
        }
    }

    /// The tallest a day's bar grows, and the narrowest a day takes.
    private static let dayBarHeight = Design.Space.xxl * 1.75
    private static let dayWidth = Design.Space.m

    private var byDay: some View {
        let days = ledger.byDay(calendar: .current).suffix(21)
        let most = days.map(\.total.tokens).max() ?? 0
        let onPlan = Dictionary(ledger.plan.byDay(calendar: .current).map { ($0.day, $0.total) },
                                uniquingKeysWith: { first, _ in first })
        return section("By day") {
            HStack(alignment: .bottom, spacing: Design.Space.xxs) {
                ForEach(Array(days), id: \.day) { day in
                    let floor = Design.Space.xxs / 2
                    VStack(spacing: Design.Space.xxs) {
                        Capsule()
                            .fill(Design.Tone.accent.color)
                            .frame(height: max(floor, most > 0 ? CGFloat(day.total.tokens) / CGFloat(most) * Self.dayBarHeight : floor))
                        Text(day.day.formatted(.dateTime.day()))
                            .textRole(.caption, .tertiary)
                    }
                    .frame(width: Self.dayWidth)
                    .help("\(day.day.formatted(date: .abbreviated, time: .omitted)): \(BoardText.tokens(day.total)) tokens, \(BoardCost.text(day.total, covered: onPlan[day.day] ?? UsageTotal()))")
                }
                Spacer(minLength: 0)
            }
            .frame(height: Self.dayBarHeight + Design.Space.l, alignment: .bottom)
        }
    }

    private func copyCSV() {
        var rows = ["date,conversation,task,engine,model,purpose,input,cache_read,cache_write,output,exact,seconds,cost_usd"]
        let stamp = ISO8601DateFormatter()
        for entry in ledger.entries {
            let task = entry.workItem.flatMap { board.item($0)?.key } ?? ""
            rows.append([
                stamp.string(from: entry.date), entry.conversation?.uuidString ?? "", task, entry.engine,
                entry.model.isEmpty ? "auto" : entry.model, entry.purpose, "\(entry.input)", "\(entry.cacheRead)",
                "\(entry.cacheWrite)", "\(entry.output)", entry.exact ? "yes" : "estimated",
                String(format: "%.2f", entry.seconds), BoardCost.isPlan(entry) ? "" : String(format: "%.6f", entry.cost)
            ].joined(separator: ","))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rows.joined(separator: "\n"), forType: .string)
    }
}

/// The project's budget: a limit in tokens, in dollars, or both, with
/// where spending stands against it. No more runs start once it is used up.
private struct BudgetEditor: View {
    @ObservedObject private var advanced = Advanced.shared
    let project: Project
    let board: Board
    let spent: UsageTotal

    private var state: BudgetState { board.budget.state(spent: spent) }

    private var tint: Color {
        switch state {
        case .none, .within: return Design.Tone.positive.color
        case .near: return Design.Tone.caution.color
        case .over: return Design.Tone.critical.color
        }
    }

    /// The width of a budget's field: room for "1.5M" or "250.00".
    private static let fieldWidth = Design.Space.xxl * 3

    private var words: String {
        switch state {
        case .none: return "No budget is set. Runs start whatever they have cost."
        case .within(let share): return "\(Int((share * 100).rounded()))% used."
        case .near(let share): return "\(Int((share * 100).rounded()))% used: nearly all of it."
        case .over(let share): return "\(Int((share * 100).rounded()))% used. No more runs start until it is raised."
        }
    }

    private func setBudget(tokens: Int?, dollars: Double?) {
        advanced.change(project.id) { board in
            let next = Budget(tokens: tokens, dollars: dollars)
            guard next != board.budget else { return }
            board.budget = next
            board.log("Set the budget", by: .person, now: Date())
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            BoardHeading("Budget")
            HStack(spacing: Design.Space.xs) {
                Text("Tokens")
                    .textRole(.label, .secondary)
                CommitField(placeholder: "No limit", value: board.budget.tokens.map { ContextUse.short($0) } ?? "") { text in
                    setBudget(tokens: BoardText.parseTokens(text), dollars: board.budget.dollars)
                }
                .frame(width: Self.fieldWidth)
                Text("Dollars")
                    .textRole(.label, .secondary)
                CommitField(placeholder: "No limit",
                            value: board.budget.dollars.map { String(format: "%.2f", $0) } ?? "") { text in
                    let cleaned = text.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
                    setBudget(tokens: board.budget.tokens, dollars: Double(cleaned).flatMap { $0 > 0 ? $0 : nil })
                }
                .frame(width: Self.fieldWidth)
                Spacer(minLength: 0)
            }
            if board.budget.isSet {
                ShareBar(fraction: state.fraction ?? 0, tint: tint, height: Design.Space.xxs + Design.Space.xxs / 2)
                    .frame(maxWidth: Design.readableWidth)
            }
            Text(words)
                .font(Design.TextRole.label.font)
                .foregroundStyle(state.isOver ? AnyShapeStyle(Design.Tone.critical.color) : AnyShapeStyle(.secondary))
        }
    }
}
