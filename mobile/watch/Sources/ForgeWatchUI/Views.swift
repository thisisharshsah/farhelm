import ForgeWatchKit
import SwiftUI

/// The screens.
///
/// The design constraint that shapes all of them: a wrist is a *glance and a
/// tap*. Anything that needs reading belongs on the phone. So there is no output
/// tail, no diff, no cost dashboard — an approval card with two big buttons, and
/// a list that answers "where is it up to" without scrolling.

public struct RootView: View {
    @State private var store = WatchStore()

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                switch store.phase {
                case .loading:
                    ProgressView()
                case .unpaired, .pairing:
                    PairingView(store: store)
                case .ready:
                    FleetList(store: store)
                }
            }
            .navigationTitle("RelayForge")
        }
        .task { store.start() }
    }
}

/* ------------------------------------------------------------------ pairing */

struct PairingView: View {
    let store: WatchStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pair this watch")
                    .font(.headline)

                Text(
                    "Open RelayForge on your iPhone, go to Watch, and tap below. "
                        + "This watch makes its own key — the phone only carries the public half."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                if let error = store.pairingError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    store.beginPairing()
                } label: {
                    if store.phase == .pairing {
                        ProgressView()
                    } else {
                        Text("Pair")
                    }
                }
                .disabled(store.phase == .pairing)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 4)
        }
    }
}

/* -------------------------------------------------------------------- fleet */

struct FleetList: View {
    let store: WatchStore

    var body: some View {
        List {
            if let refusal = store.refusal {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Refused", systemImage: "hand.raised.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text(refusal)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("OK") { store.dismissRefusal() }
                    }
                }
            }

            if let fleet = store.fleet {
                let pending = fleet.pendingApprovals.filter { !store.acted.contains($0.id) }

                if !pending.isEmpty {
                    Section("Waiting on you") {
                        ForEach(pending) { approval in
                            NavigationLink {
                                ApprovalDetail(approval: approval, store: store)
                            } label: {
                                ApprovalRow(approval: approval)
                            }
                        }
                    }
                }

                Section("Sessions") {
                    if fleet.sessions.isEmpty {
                        Text("Nothing running.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(fleet.sessions) { session in
                        SessionRow(session: session)
                    }
                }
            } else {
                ProgressView()
            }

            Section {
                if store.connection != .open {
                    Label("Reconnecting…", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Unpair", role: .destructive) { store.unpair() }
                    .font(.footnote)
            }
        }
        .refreshable { await store.refresh() }
    }
}

struct ApprovalRow: View {
    let approval: ApprovalView

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(approval.repoName)
                    .font(.headline)
                    .lineLimit(1)
                if !approval.allowsWatchDecision {
                    // Says so before the tap, not after. The rule is enforced by
                    // the runner either way, but a button that cannot work
                    // should look like one.
                    Image(systemName: "iphone")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Text(approval.payload)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

struct SessionRow: View {
    let session: SessionView

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(session.repoName)
                    .font(.headline)
                    .lineLimit(1)
            }

            // Status is written, never carried by the dot alone.
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            BudgetBar(budget: session.budget)
        }
    }

    private var color: Color {
        switch session.status {
        case .running: return .green
        case .awaitingApproval: return .orange
        case .paused: return .secondary
        case .dead: return .red
        case .done: return .secondary
        }
    }

    private var subtitle: String {
        var parts = [session.status.label]
        if let plan = session.plan, plan.total > 0 {
            parts.append("Step \(plan.currentOrdinal ?? plan.settled)/\(plan.total)")
            if let title = plan.currentTitle { parts.append(title) }
        }
        return parts.joined(separator: " · ")
    }
}

struct BudgetBar: View {
    let budget: BudgetView

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * min(1, budget.pct ?? 0))
                }
            }
            .frame(height: 4)

            // The number always accompanies the bar. A bar alone is not a
            // reading, and a colour alone is not a signal.
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch budget.state {
        case .ok: return .green
        case .warn: return .orange
        case .stop: return .red
        }
    }

    private var caption: String {
        let spent = String(format: budget.spentUSD < 1 ? "$%.4f" : "$%.2f", budget.spentUSD)
        guard let cap = budget.capUSD else { return "\(spent) · no cap" }
        let capped = String(format: cap < 1 ? "$%.4f" : "$%.2f", cap)
        return "\(spent) of \(capped)"
    }
}

/* ----------------------------------------------------------------- approval */

struct ApprovalDetail: View {
    let approval: ApprovalView
    let store: WatchStore

    @Environment(\.dismiss) private var dismiss
    @State private var busy: Decision?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("wants to run \(approval.tool)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(approval.payload)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)

                // The moment of approval is the moment of spend.
                BudgetBar(budget: approval.budget)

                if approval.allowsWatchDecision {
                    HStack(spacing: 6) {
                        DecisionButton(
                            title: "Approve", tint: .green,
                            busy: busy == .approved, disabled: busy != nil
                        ) { act(.approved) }

                        DecisionButton(
                            title: "Deny", tint: .red,
                            busy: busy == .denied, disabled: busy != nil
                        ) { act(.denied) }
                    }
                } else {
                    // Deliberate friction, not an oversight — say which.
                    Label(
                        "Destructive. Approve this one from your phone.",
                        systemImage: "iphone"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(approval.repoName)
    }

    private func act(_ decision: Decision) {
        busy = decision
        Task {
            await store.decide(approval, decision)
            dismiss()
        }
    }
}

struct DecisionButton: View {
    let title: String
    let tint: Color
    let busy: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if busy {
                ProgressView()
            } else {
                Text(title).font(.footnote.weight(.semibold))
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .disabled(disabled)
    }
}
