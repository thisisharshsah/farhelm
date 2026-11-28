import CompanionBoard
import SwiftUI

/// The rules for a task's token bar, kept apart from the view so they can
/// be tested. They follow the board's runaway rule (`Advanced.stopRunaways`):
/// reads served from the cache are left out, and a run is stopped at three
/// times its estimate.
enum TokenBar {
    enum Level: Equatable {
        case within, over, runaway

        /// The state colors the design system has: Caution is the warning
        /// color. The system has no separate Stuck color, so Stuck is Critical.
        var tone: Design.Tone {
            switch self {
            case .within: .accent
            case .over: .caution
            case .runaway: .critical
            }
        }
    }

    /// The tokens that count against an estimate.
    static func used(_ total: UsageTotal) -> Int {
        total.input + total.cacheWrite + total.output
    }

    /// Used over estimate, from 0 to 1. Past the estimate the bar is full;
    /// without an estimate there is nothing to measure against.
    static func fraction(used: Int, estimate: Int?) -> Double {
        guard let estimate, estimate > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(estimate)))
    }

    static func level(used: Int, estimate: Int?) -> Level {
        guard let estimate, estimate > 0 else { return .within }
        if used > 3 * estimate { return .runaway }
        return used > estimate ? .over : .within
    }
}

/// How full a subscription's plan window is, and the tint that says so.
enum PlanBar {
    /// The window the plan is judged by: the fullest one, as the app's run
    /// limit judges it (`Advanced.refreshLimit`), so both agree.
    static func fullest(_ windows: [PlanLimit]) -> PlanLimit? {
        windows.max { ($0.used ?? -1) < ($1.used ?? -1) }
    }

    static func tone(used: Double?) -> Design.Tone {
        guard let used else { return .accent }
        if used >= 0.995 { return .critical }
        return used >= 0.8 ? .caution : .accent
    }
}

/// One bar per subscription: plan used against its limit, with when it
/// starts over. The numbers are the ones the tools reported and T-52 reads.
struct PlanUsageBars: View {
    @ObservedObject private var agents = CLIAgents.shared

    private var plans: [(id: String, name: String, window: PlanLimit)] {
        agents.limits.compactMap { id, windows in
            PlanBar.fullest(windows).map { (id: id, name: agents.name(of: id), window: $0) }
        }.sorted { $0.name < $1.name }
    }

    var body: some View {
        let plans = plans
        if !plans.isEmpty {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                BoardHeading("Plan usage")
                ForEach(plans, id: \.id) { plan in
                    row(plan.name, plan.window)
                }
            }
        }
    }

    /// Two fixed lines, so a row keeps its height whatever it says and at
    /// any width: the words truncate, the bar never moves.
    private func row(_ name: String, _ window: PlanLimit) -> some View {
        let used = window.used
        let percent = used.map { "\(Int((min(max($0, 0), 1) * 100).rounded()))%" } ?? "within limit"
        return VStack(alignment: .leading, spacing: Design.Space.xxs) {
            HStack(spacing: Design.Space.xs) {
                Text("\(name) · \(window.name)")
                    .textRole(.label, .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Design.Space.xxs)
                Text(percent)
                    .textRole(.number, .primary)
                    .lineLimit(1)
                Text(window.restart.map { "resets \($0)" } ?? "")
                    .textRole(.caption, .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, alignment: .trailing)
                    .layoutPriority(-1)
            }
            ShareBar(fraction: used ?? 0, tint: PlanBar.tone(used: used).color,
                     height: Design.Space.xs)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(window.name): \(percent) used" + (window.restart.map { ", resets \($0)" } ?? ""))
    }
}