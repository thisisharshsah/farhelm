import CompanionDesign
import CompanionKit
import SwiftUI

/// One screen: the chat's state and plan, the last reply, Stop while it
/// works, and a reply by voice or a quick choice.
struct WatchView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @State private var reply = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let summary = model.summary {
                        header(summary)
                        if !summary.plan.isEmpty { plan(summary.plan) }
                        if let question = summary.question { ask(question, summary.options) }
                        if summary.awaitingApproval {
                            Label("Approve on your Mac", systemImage: "hand.raised")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        if summary.busy {
                            Button(role: .destructive) {
                                Task { await model.stop() }
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .tint(.red)
                        }
                        if !summary.lastReply.isEmpty {
                            Text(summary.lastReply)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        TextField("Reply", text: $reply)
                            .onSubmit {
                                let text = reply
                                reply = ""
                                Task { await model.say(text) }
                            }
                    } else {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text(model.macs.isEmpty ? "Pair a Mac in Companion on your iPhone." : "Reaching \(model.macs.first ?? "your Mac")…")
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    if let problem = model.problem {
                        Text(problem)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 4)
            }
            .navigationTitle("Companion")
            .background(CompanionBackdrop(depth: 1))
        }
        .tint(Design.palette().accent)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
        .onChange(of: phase) { _, phase in
            if phase == .active { model.startPolling() } else { model.stopPolling() }
        }
    }

    private func header(_ summary: WatchRelay.Summary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.title)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 6) {
                LoadingMark(state: summary.awaitingApproval || summary.question != nil ? .waiting
                            : (summary.busy ? .working : .idle), size: 16)
                Text(summary.status)
                    .font(.footnote)
                    .foregroundStyle(summary.busy ? Design.palette().accent : Color.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func plan(_ items: [PlanItem]) -> some View {
        let steps = items.map { PlanStep(text: $0.text, state: PlanStep.State(rawValue: $0.state.rawValue) ?? .todo) }
        return VStack(alignment: .leading, spacing: 4) {
            PlanRing(plan: steps, size: 16, showsCount: true)
            if let now = items.first(where: { $0.state == .doing }) ?? items.first(where: { $0.state == .todo }) {
                Text(now.text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func ask(_ question: String, _ options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question)
                .font(.footnote.weight(.medium))
            // The same bubbles as on the Mac and the phone.
            ChoiceBubbles(options, size: 15) { option in
                Task { await model.say(option) }
            }
            .id(question)
        }
    }
}
