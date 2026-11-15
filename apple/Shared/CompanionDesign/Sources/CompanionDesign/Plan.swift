import SwiftUI

/// One item of an agent's plan, as the shared views show it.
public struct PlanStep: Hashable, Sendable {
    public enum State: String, Sendable { case todo, doing, done }
    public var text: String
    public var state: State

    public init(text: String, state: State) {
        self.text = text
        self.state = state
    }
}

extension Array where Element == PlanStep {
    /// The step being worked on (1-based): the one marked doing, else the
    /// first not done.
    public var currentStep: Int {
        if let doing = firstIndex(where: { $0.state == .doing }) { return doing + 1 }
        return Swift.min(filter { $0.state == .done }.count + 1, count)
    }

    public var doneFraction: CGFloat {
        isEmpty ? 0 : CGFloat(filter { $0.state == .done }.count) / CGFloat(count)
    }
}

/// The plan's progress as a ring that fills as steps are done, with
/// "2 of 6" beside it when asked for.
public struct PlanRing: View {
    let plan: [PlanStep]
    var size: CGFloat
    var showsCount: Bool

    public init(plan: [PlanStep], size: CGFloat = 15, showsCount: Bool = false) {
        self.plan = plan
        self.size = size
        self.showsCount = showsCount
    }

    public var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Theme.ink.opacity(0.14), lineWidth: size * 0.17)
                Circle()
                    .trim(from: 0, to: Swift.max(plan.doneFraction, 0.02))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: size * 0.17, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: plan.doneFraction)
            }
            .frame(width: size, height: size)
            if showsCount {
                Text("\(plan.currentStep) of \(plan.count)")
                    .font(.system(size: size * 0.75, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink.opacity(0.85))
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Plan, step \(plan.currentStep) of \(plan.count)")
    }
}

/// The plan as a checklist, ticked off as the agent goes.
public struct PlanChecklist: View {
    let plan: [PlanStep]
    var textSize: CGFloat

    public init(plan: [PlanStep], textSize: CGFloat = 12) {
        self.plan = plan
        self.textSize = textSize
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: textSize * 0.55) {
            ForEach(Array(plan.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: item.state == .done ? "checkmark.circle.fill"
                          : (item.state == .doing ? "circle.dotted.circle" : "circle"))
                        .font(.system(size: textSize * 0.92, weight: .semibold))
                        .foregroundStyle(item.state == .done ? Theme.mint
                                         : (item.state == .doing ? Theme.accent : Theme.ink.opacity(0.35)))
                    Text(item.text)
                        .font(.system(size: textSize, weight: item.state == .doing ? .semibold : .regular))
                        .foregroundStyle(Theme.ink.opacity(item.state == .done ? 0.5 : 0.9))
                        .strikethrough(item.state == .done, color: Theme.ink.opacity(0.3))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
