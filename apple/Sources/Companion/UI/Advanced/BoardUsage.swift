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
            VStack(alignment: .leading, spacing: 16) {
                tiles
                BudgetEditor(project: project, board: board, spent: ledger.total)
                if ledger.total.isEmpty {
                    Text("Nothing has been asked of a model for this project yet. Every request shows here as it is made, with what it used.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink.opacity(0.55))
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
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: The totals

    private var tiles: some View {
        let total = ledger.total
        // The project's cost is that of all its goals, so its finished
        // tasks are counted under all of them too.
        let done = board.allItems.filter { $0.status == .done }
        var doneTotal = UsageTotal()
        for item in done { doneTotal.add(ledger.total(of: item)) }
        let overhead = ledger.overheadShare(purposes: Advanced.overheadPurposes)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], alignment: .leading, spacing: 8) {
            tile("Tokens", BoardText.tokens(total),
                 "\(ContextUse.short(total.inputTokens)) in · \(ContextUse.short(total.output)) out")
            tile("Cost", Money.text(total.cost),
                 total.cacheRead > 0 ? "\(ContextUse.short(total.cacheRead)) read from cache" : "at the prices in Settings")
            tile("Requests", "\(total.requests)",
                 total.requests > 0 ? "\(BoardText.duration(total.seconds)) of model time" : "none yet")
            tile("Supervising", "\(Int((overhead * 100).rounded()))%",
                 "of the tokens went on planning and review")
            tile("Per task done", done.isEmpty ? "n/a" : ContextUse.short(doneTotal.tokens / done.count),
                 done.isEmpty ? "no task is done yet" : "\(Money.text(doneTotal.cost / Double(done.count))) each, over \(done.count)")
        }
    }

    private func tile(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            BoardHeading(title)
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.ink.opacity(0.96))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink.opacity(0.5))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).fill(Theme.ink.opacity(0.05)))
    }

    // MARK: Breakdowns

    /// One line of a breakdown: its name, its share as a bar, its numbers.
    private func line(_ name: String, _ total: UsageTotal, most: Int, tint: Color = Theme.accent,
                      detail: String = "", action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.ink.opacity(0.45))
                            .lineLimit(1)
                    }
                }
                ShareBar(fraction: most > 0 ? Double(total.tokens) / Double(most) : 0, tint: tint, height: 4)
            }
            Text(BoardText.tokens(total))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Theme.ink.opacity(0.8))
                .frame(width: 58, alignment: .trailing)
            Text(Money.text(total.cost))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Theme.ink.opacity(0.6))
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            BoardHeading(title)
            content()
        }
    }

    /// What each goal took, the newest first: the one being worked toward
    /// and the ones before it.
    private var byGoal: some View {
        let used = board.usageByGoal(ledger)
        let goals = board.goals.sorted { $0.number > $1.number }
        let most = goals.compactMap { used[$0.id]?.tokens }.max() ?? 0
        return section("By goal") {
            ForEach(goals) { goal in
                let progress = board.progress(of: goal.id)
                line("\(goal.key) \(goal.text.isEmpty ? "Not put into words" : goal.text)", used[goal.id] ?? UsageTotal(),
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
                line(entry.name, entry.total, most: most, detail: "\(entry.total.requests) requests")
            }
        }
    }

    private var byTask: some View {
        let used = board.allItems.map { (item: $0, total: ledger.total(of: $0)) }
            .filter { !$0.total.isEmpty }
            .sorted { $0.total.tokens > $1.total.tokens }
        let most = used.first?.total.tokens ?? 0
        return section("By task") {
            if used.isEmpty {
                Text("No run has been made on a task yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.45))
            }
            ForEach(used, id: \.item.id) { entry in
                let estimate = entry.item.estimateTokens ?? 0
                line("\(entry.item.key) \(entry.item.title)", entry.total, most: most,
                     tint: estimate > 0 && entry.total.tokens > estimate ? Theme.amber : entry.item.status.tint,
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
        return section("By conversation") {
            ForEach(chats.prefix(40), id: \.id) { chat in
                line(chatName(chat.id), chat.total, most: most, tint: Theme.violet,
                     detail: "\(chat.total.requests) requests") {
                    app.openConversation(chat.id)
                }
                .help("Open this chat")
            }
            if chats.count > 40 {
                Text("\(chats.count - 40) more, each smaller than these.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.45))
            }
        }
    }

    private var byPurpose: some View {
        let lines = ledger.byPurpose
        let most = lines.first?.total.tokens ?? 0
        return section("By kind of work") {
            ForEach(lines) { entry in
                line(entry.name, entry.total, most: most,
                     tint: Advanced.overheadPurposes.contains(entry.name) ? Theme.amber : Theme.mint)
            }
        }
    }

    private var byDay: some View {
        let days = ledger.byDay(calendar: .current).suffix(21)
        let most = days.map(\.total.tokens).max() ?? 0
        return section("By day") {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(days), id: \.day) { day in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Theme.accent.opacity(0.8))
                            .frame(height: max(2, most > 0 ? CGFloat(day.total.tokens) / CGFloat(most) * 56 : 2))
                        Text(day.day.formatted(.dateTime.day()))
                            .font(.system(size: 8.5))
                            .foregroundStyle(Theme.ink.opacity(0.4))
                    }
                    .frame(width: 16)
                    .help("\(day.day.formatted(date: .abbreviated, time: .omitted)): \(BoardText.tokens(day.total)) tokens, \(Money.text(day.total.cost))")
                }
                Spacer(minLength: 0)
            }
            .frame(height: 74, alignment: .bottom)
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
                String(format: "%.2f", entry.seconds), String(format: "%.6f", entry.cost)
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
        case .none, .within: return Theme.mint
        case .near: return Theme.amber
        case .over: return Theme.rose
        }
    }

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
        VStack(alignment: .leading, spacing: 6) {
            BoardHeading("Budget")
            HStack(spacing: 8) {
                Text("Tokens")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink.opacity(0.7))
                CommitField(placeholder: "No limit", value: board.budget.tokens.map { ContextUse.short($0) } ?? "") { text in
                    setBudget(tokens: BoardText.parseTokens(text), dollars: board.budget.dollars)
                }
                .frame(width: 96)
                Text("Dollars")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink.opacity(0.7))
                CommitField(placeholder: "No limit",
                            value: board.budget.dollars.map { String(format: "%.2f", $0) } ?? "") { text in
                    let cleaned = text.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
                    setBudget(tokens: board.budget.tokens, dollars: Double(cleaned).flatMap { $0 > 0 ? $0 : nil })
                }
                .frame(width: 96)
                Spacer(minLength: 0)
            }
            if board.budget.isSet {
                ShareBar(fraction: state.fraction ?? 0, tint: tint, height: 6)
                    .frame(maxWidth: 420)
            }
            Text(words)
                .font(.system(size: 11))
                .foregroundStyle(state.isOver ? Theme.rose : Theme.ink.opacity(0.55))
        }
    }
}
