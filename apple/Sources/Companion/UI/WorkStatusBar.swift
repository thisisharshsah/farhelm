import SwiftUI

/// What the agent is doing, on one line just above the chat box (above
/// the agent's card, when that is open): the working mark and its status
/// at the left, and on the right the plan's progress ring ("2 of 6"). A
/// click on it opens the checklist right above; another click closes it.
/// The conversation itself keeps only what was said and done.
struct WorkStatusBar: View {
    @EnvironmentObject var app: AppState

    /// The reply being written now.
    private var turn: ChatTurn? {
        app.conversation.turns.last { app.streamingTurns.contains($0.id) }
    }

    /// The agent has stopped for a yes or an answer. Its card, right under
    /// this line, says so and has the buttons, so the status is left out
    /// rather than said twice.
    private var asking: Bool { app.pendingApproval != nil || app.pendingQuestion != nil }

    private var working: Bool { !asking && (app.agentHere || turn != nil) }

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
    private var shown: Bool { working || (plan != nil && !planOpen) }

    /// The checklist is open above the line.
    @State private var planOpen = false

    /// Before the first step the model is thinking; after it, working.
    private var thinking: Bool { !app.agentHere && turn?.steps == nil }

    private var status: String {
        thinking ? "Thinking…" : (app.agentStatus ?? "Working…")
    }

    @ObservedObject private var checkIns = CheckIns.shared

    var body: some View {
        VStack(spacing: 6) {
            // A check-in this chat waits for: when, for what, and the way
            // to have it now or call it off.
            ForEach(checkIns.pending(in: app.conversation.id)) { checkIn in
                CheckInBar(checkIn: checkIn)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
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

    /// What comes after the step under way, from the plan: the "Now"
    /// line says what it does, this says where it goes next.
    private var nextStep: String? {
        guard working, let plan, !plan.isEmpty else { return nil }
        let doing = plan.firstIndex { $0.state == .doing } ?? plan.firstIndex { $0.state == .todo }
        guard let doing else { return nil }
        let rest = plan[(doing + 1)...]
        return rest.first { $0.state != .done }?.text
    }

    private var line: some View {
        VStack(alignment: .leading, spacing: 2) {
            lineNow
            if let nextStep {
                Text("Then: " + nextStep)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 10)
                    .padding(.trailing, 48)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: nextStep)
    }

    private var lineNow: some View {
        ZStack {
            if working {
                // The shared status pill (as on the phone), floating over
                // the conversation at the left; clear of the ring.
                Group {
                    if let until = app.agentStatusUntil, !thinking {
                        // Only this line ticks, once a second.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            StatusPill(status + " in " + WorkTrail.duration(until.timeIntervalSince(context.date)),
                                       thinking: false, size: 11.5)
                        }
                    } else {
                        StatusPill(status, thinking: thinking, size: 11.5)
                            .animation(.easeOut(duration: 0.2), value: status)
                    }
                }
                    .allowsHitTesting(false)
                .padding(.trailing, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: shown ? 28 : 0)
        .overlay(alignment: .trailing) {
            HStack(spacing: 6) {
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
            .padding(.horizontal, hover || open ? 7 : 0)
            .frame(minWidth: CardIconButton.size, minHeight: CardIconButton.size, maxHeight: CardIconButton.size)
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: hover)
            // The same glass, size and corner as the other icons here.
            .cardIconSurface(hover: hover, lit: open)
            .contentShape(RoundedRectangle(cornerRadius: CardIconButton.radius, style: .continuous))
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
        .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).fill(Theme.shade.opacity(0.45)))
        .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
    }
}


extension PlanItem {
    /// As the shared plan views take it.
    var design: PlanStep {
        PlanStep(text: text, state: PlanStep.State(rawValue: state.rawValue) ?? .todo)
    }
}

/// While the agent is acting in the browser or on the Mac, a strip across
/// the top of the chat says so, with Stop, the way an assistant that uses
/// the computer shows it: whoever looks at the panel knows who is moving
/// the page, and can take it back in one click.
struct AgentUseBanner: View {
    @EnvironmentObject var app: AppState
    @State private var pulse = false

    /// "the browser" or "your computer" while the agent acts there.
    private var place: String? {
        guard app.agentHere,
              let turn = app.conversation.turns.last(where: { app.streamingTurns.contains($0.id) }),
              let last = turn.steps?.last(where: { $0.kind != .note && $0.kind != .think }) else { return nil }
        if last.inBrowser { return last.title.hasPrefix("Chrome: ") ? "Chrome" : "the browser" }
        switch last.kind {
        case .open, .click, .type, .key: return "your computer"
        default: return nil
        }
    }

    var body: some View {
        if let place {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.amber)
                    .frame(width: 7, height: 7)
                    .opacity(pulse ? 1 : 0.45)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                Text("Using \(place)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.amber)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Button { app.stopAgent() } label: {
                    Text("Stop")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.ink.opacity(0.9))
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.ink.opacity(0.1)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Stop the agent here (it keeps what it has done)")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.amber.opacity(0.1)))
            // Solid under its tint, so the chat never shows through it.
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.shade.opacity(0.96)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.amber.opacity(0.22), lineWidth: 0.5))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}


/// A check-in the chat waits for, above the chat box: a clock, when it
/// comes and the time left, what it will check, and Check now and Cancel.
struct CheckInBar: View {
    let checkIn: CheckIn

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "alarm")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.amber)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, checkIn.due.timeIntervalSince(context.date))
                (Text("Checking at \(CheckIns.time(checkIn.due))").fontWeight(.semibold)
                 + Text("  \(WorkTrail.duration(left)) left  \u{00B7}  \(checkIn.note)"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .monospacedDigit()
            }
            Spacer(minLength: 6)
            Button { CheckIns.shared.checkNow(checkIn.id) } label: {
                Text("Check now")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.accent.opacity(0.14)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Have the agent check now")
            Button { CheckIns.shared.cancel(checkIn.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.ink.opacity(0.08)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cancel this check-in")
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.amber.opacity(0.1)))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.shade.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.amber.opacity(0.22), lineWidth: 0.5))
    }
}
