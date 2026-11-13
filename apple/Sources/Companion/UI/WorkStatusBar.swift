import SwiftUI

/// What the agent is doing, on one line just above the chat box: the
/// working mark and its status at the left, and on the right the plan's
/// progress ring ("2 of 6"). A click on it opens the checklist right
/// above, over the chat box's edge; another click closes it.
/// The conversation itself keeps only what was said and done.
struct WorkStatusBar: View {
    @EnvironmentObject var app: AppState

    /// The reply being written now.
    private var turn: ChatTurn? {
        app.conversation.turns.last { app.streamingTurns.contains($0.id) }
    }

    private var working: Bool { app.agentHere || turn != nil }

    /// The plan of the newest reply: live while it runs, and kept (all
    /// ticked) until the next message, so it can still be looked over.
    private var plan: [PlanItem]? {
        if let live = turn?.plan, !live.isEmpty { return live }
        guard let last = app.conversation.turns.last, last.kind == .reply,
              let kept = last.plan, !kept.isEmpty else { return nil }
        return kept
    }

    /// The line has something on it: the status while working, or the
    /// ring while the plan is closed. Otherwise it takes no room at all.
    private var shown: Bool { working || (plan != nil && !planOpen) || jumpShown }

    /// Scrolled up: the arrow back to the newest sits on this line.
    private var jumpShown: Bool { app.chatScrolledUp && !app.conversation.turns.isEmpty }

    /// The checklist is open above the line.
    @State private var planOpen = false

    /// Before the first step the model is thinking; after it, working.
    private var thinking: Bool { !app.agentHere && turn?.steps == nil }

    private var status: String {
        thinking ? "Thinking…" : (app.agentStatus ?? "Working…")
    }

    var body: some View {
        VStack(spacing: 6) {
            if planOpen, let plan {
                PlanCard(plan: plan, current: PlanProgress.current(in: plan)) {
                    planOpen = false
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            line
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: planOpen)
        .onChange(of: plan == nil) { _, gone in if gone { planOpen = false } }
    }

    private var line: some View {
        ZStack {
            if working {
                // The shared status pill (as on the phone), floating over
                // the conversation at the left; clear of the ring.
                StatusPill(status, thinking: thinking, size: 11.5)
                    .animation(.easeOut(duration: 0.2), value: status)
                    .allowsHitTesting(false)
                .padding(.trailing, jumpShown ? 82 : 48)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: shown ? 28 : 0)
        .overlay(alignment: .trailing) {
            HStack(spacing: 6) {
                if jumpShown {
                    JumpToLatest { app.jumpToNewest += 1 }
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                // While the plan is open its progress is in the card's corner.
                if let plan, !planOpen {
                    PlanProgress(plan: plan, open: $planOpen)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
        .padding(.bottom, shown ? 4 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: working)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: plan == nil)
        .animation(.easeOut(duration: 0.18), value: jumpShown)
    }
}

/// The plan as a ring that fills as steps are done, with "2 of 6" beside
/// it. A click opens or closes the checklist.
private struct PlanProgress: View {
    let plan: [PlanItem]
    @Binding var open: Bool
    @State private var hover = false

    /// The step being worked on: the one marked doing, else the first not done.
    static func current(in plan: [PlanItem]) -> Int {
        if let doing = plan.firstIndex(where: { $0.state == .doing }) { return doing + 1 }
        return min(plan.filter { $0.state == .done }.count + 1, plan.count)
    }

    private var current: Int { Self.current(in: plan) }

    var body: some View {
        Button { open.toggle() } label: {
            // The shared ring; the count shows on hover (and while open).
            PlanRing(plan: plan.map(\.design), size: 15, showsCount: hover || open)
            .padding(.horizontal, hover || open ? 9 : 4.5)
            .frame(height: 24)
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: hover)
            .background(Capsule().fill((open ? Theme.accent : Theme.ink).opacity(open ? 0.16 : (hover ? 0.12 : 0.07))))
            // Glass under it, as it floats over the conversation.
            .background(Capsule().fill(Theme.shade.opacity(0.45)))
            .liquidGlass(in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(open ? "Close the plan" : "The plan: step \(current) of \(plan.count)")
    }
}

/// The checklist, ticked off as the agent goes.
private struct PlanCard: View {
    let plan: [PlanItem]
    let current: Int
    let close: () -> Void

    /// The list's own height, measured, so the card is only as tall as it
    /// needs up to `most`, and scrolls past that.
    @State private var listHeight: CGFloat = 0
    private let most: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Plan")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.95))
                Spacer()
                // Top right: how far along, then the way to close it.
                PlanRing(plan: plan.map(\.design), size: 15, showsCount: true)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(Theme.accent.opacity(0.16)))
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Theme.ink.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.ink.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close the plan")
            }
            // A long plan scrolls inside the card rather than covering the chat.
            ScrollView(.vertical) {
            PlanChecklist(plan: plan.map(\.design), textSize: 11.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { listHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, height in listHeight = height }
            })
            }
            .frame(height: min(max(listHeight, 1), most))
            .scrollIndicators(listHeight > most ? .automatic : .hidden)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The same glass as the chat box under it, so the two read as one
        // family. (The conversation ends above them, so nothing shows
        // through.)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.shade.opacity(0.45)))
        .liquidGlass(in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}


extension PlanItem {
    /// As the shared plan views take it.
    var design: PlanStep {
        PlanStep(text: text, state: PlanStep.State(rawValue: state.rawValue) ?? .todo)
    }
}
