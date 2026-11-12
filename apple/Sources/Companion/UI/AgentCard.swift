import SwiftUI

/// The agent at work, shown above the input for as long as a task runs.
///
/// It always carries a Stop button. A thin bar shows how far along the task
/// is. When the agent wants to do something that needs a yes, each step
/// slides in as its own card with Allow, Always allow and Deny underneath.
/// A step that goes through flashes a checkmark; one that fails shakes the
/// whole card.
struct AgentCard: View {
    @EnvironmentObject var app: AppState
    @State private var showCheck = false
    @State private var checkWork: Task<Void, Never>?
    /// The file steps whose full change is open. None are to begin with.
    @State private var expandedSteps: Set<ActionStep.ID> = []

    /// The steps waiting for a yes, one card each.
    private func stepList<Value: Equatable>(_ steps: [ActionStep], directory: String, animating value: Value) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                StepCard(step: step, directory: directory, expanded: Binding(
                    get: { expandedSteps.contains(step.id) },
                    set: { open in
                        if open { expandedSteps.insert(step.id) } else { expandedSteps.remove(step.id) }
                    }))
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity))
                    .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(Double(index) * 0.07),
                               value: value)
            }
        }
    }

    private var waiting: Bool { app.pendingApproval != nil || app.pendingQuestion != nil }
    private var tint: Color { waiting ? Theme.amber : Theme.accent }
    private var done: Int { app.agentLog.count }

    /// How far along the task is. The end is not known in advance, so the
    /// bar fills toward it without reaching it until the task is over.
    private var progress: Double {
        let ahead = Double(app.pendingApproval?.steps.count ?? 0) + 1.5
        return Double(done) / (Double(done) + ahead)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                status
                    .frame(width: 16, height: 16)
                Text(app.pendingQuestion != nil
                     ? "Companion has a question"
                     : (waiting ? "Companion wants to do this" : (app.agentStatus ?? "Working")))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Spacer(minLength: 6)
                if done > 0 {
                    Text("\(done) done")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink.opacity(0.45))
                }
                Button { app.stopAgent() } label: { Chip("Stop", icon: "stop.fill", tint: Theme.rose) }
                    .buttonStyle(.plain)
                    .help("Stop the agent (\(Shortcuts.shared.label(.stopAgent)))")
            }

            // Progress through the task.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ink.opacity(0.10))
                    Capsule()
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.6)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geometry.size.width * progress))
                }
            }
            .frame(height: 3)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: progress)

            if let question = app.pendingQuestion {
                // The agent stopped to ask. Pick an answer, or type one in
                // the chat box; it carries on from there.
                Text(question.question)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        Button {
                            app.answerAgent(option)
                        } label: {
                            HStack(spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 18, height: 18)
                                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.accent.opacity(0.16)))
                                Text(option)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.ink.opacity(0.92))
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(0.06)))
                            .glassBorder(radius: 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(question.options.isEmpty ? "Type your answer below." : "Or type your own answer below.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.48))
            } else if let proposal = app.pendingApproval {
                // The steps take the room they need up to a cap, then
                // scroll, so Allow and Deny below never leave the panel.
                ViewThatFits(in: .vertical) {
                    stepList(proposal.steps, directory: proposal.directory, animating: proposal.id)
                    ScrollView(.vertical) {
                        stepList(proposal.steps, directory: proposal.directory, animating: proposal.id)
                    }
                }
                .frame(maxHeight: 260)
                HStack(spacing: 8) {
                    Button { app.decide(.allow) } label: { Chip("Allow", icon: "checkmark", tint: Theme.accent) }
                        .buttonStyle(.plain)
                        .help("Run this once (or say \"allow\")")
                    if !proposal.remember.isEmpty || proposal.steps.contains(where: { $0.kind.usesKeyboard }) {
                        Button { app.decide(.always) } label: { Chip("Always allow", icon: "checkmark.circle") }
                            .buttonStyle(.plain)
                            .help(proposal.remember.isEmpty
                                  ? "Run this, and stop asking about clicks and typing for the rest of this task"
                                  : "Run this, and never ask again about: \(proposal.remember.joined(separator: ", "))")
                    }
                    Button { app.decide(.deny) } label: { Chip("Deny", icon: "xmark", tint: Theme.rose) }
                        .buttonStyle(.plain)
                        .help("Do not run this; the task stops (or say \"deny\")")
                }
                .transition(.opacity)
            } else if let last = app.agentLog.last {
                Text(MarkdownNotes.plain(last))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.55))
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .fill(Theme.shade.opacity(0.28)))
        .glassBorder(radius: Theme.cardRadius, tint: tint)
        // A failed step shakes the card.
        .modifier(ShakeEffect(animatableData: CGFloat(app.stepFailures)))
        .animation(.linear(duration: 0.45), value: app.stepFailures)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: app.pendingApproval?.id)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: app.pendingQuestion?.id)
        // A step that went through shows a checkmark for a moment.
        .onChange(of: app.stepSuccesses) { _, _ in
            checkWork?.cancel()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { showCheck = true }
            checkWork = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { showCheck = false }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if showCheck {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.mint)
                .transition(.scale(scale: 0.3).combined(with: .opacity))
        } else if waiting {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.amber)
                .transition(.opacity)
        } else {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .transition(.opacity)
        }
    }
}

/// One step the agent is asking to take.
private struct StepCard: View {
    let step: ActionStep
    let directory: String

    private var icon: String {
        switch step.kind {
        case .run: return "terminal"
        case .click: return "cursorarrow.click"
        case .open: return "macwindow"
        case .type: return "keyboard"
        case .key: return "command"
        case .read: return "doc.text"
        case .search: return "magnifyingglass"
        case .write: return "doc.badge.plus"
        case .edit: return "pencil"
        case .fetch, .web: return "globe"
        case .wait, .done, .ask, .plan: return "circle"
        }
    }

    private var title: String {
        switch step.kind {
        case .run: return "Run a shell command"
        case .click: return "Click"
        case .open: return "Open an app"
        case .type: return "Type"
        case .key: return "Press"
        case .read: return "Read a file"
        case .search: return "Search files"
        case .write: return "Create or replace a file"
        case .edit: return "Change a file"
        case .fetch: return "Read a web page"
        case .web: return "Search the web"
        case .wait, .done, .ask, .plan: return ""
        }
    }

    /// The first lines of a piece of text, each with a mark in front.
    private func excerpt(_ text: String, mark: String, color: Color) -> some View {
        let lines = text.components(separatedBy: "\n")
        let shown = lines.prefix(10).map { "\(mark) \($0)" }.joined(separator: "\n")
            + (lines.count > 10 ? "\n\(mark) … \(lines.count - 10) more lines" : "")
        return Text(shown)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.10)))
    }

    /// Whether the full change of a file step is shown; the card that
    /// lists the steps keeps this, one entry per step.
    @Binding var expanded: Bool

    private var isFileStep: Bool { step.kind == .edit || step.kind == .write }

    private func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.components(separatedBy: "\n").count
    }

    /// Lines the step puts into the file, and lines it takes out.
    private var added: Int { lineCount(step.kind == .edit ? step.replacement : step.body) }
    private var removed: Int { step.kind == .edit ? lineCount(step.body) : 0 }

    /// A file step on one line: icon, file name, line counts, and a
    /// chevron that opens the full change.
    private var fileRow: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.55))
            Text((step.value as NSString).lastPathComponent)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.95))
                .lineLimit(1)
                .truncationMode(.middle)
                .help("\(title): \(step.value)")
            Spacer(minLength: 4)
            Text("+\(added)")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.mint)
            Text("-\(removed)")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.rose)
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.55))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the change" : "Show the change")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if isFileStep {
                fileRow
                // Opened, a change to a file is shown as it will be made:
                // what goes (red) and what comes in its place (green).
                if expanded {
                    if step.kind == .edit {
                        excerpt(step.body, mark: "-", color: Theme.rose)
                        excerpt(step.replacement, mark: "+", color: Theme.mint)
                    } else {
                        excerpt(step.body, mark: "+", color: Theme.mint)
                    }
                }
            } else {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(title)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                    if step.kind == .run {
                        Text("in \(directory)")
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .opacity(0.7)
                    }
                }
                .foregroundStyle(Theme.ink.opacity(0.55))
                Text(step.value)
                    .font(step.kind == .run ? .system(size: 12, design: .monospaced) : .system(size: 12.5))
                    .foregroundStyle(Theme.ink.opacity(0.95))
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.shade.opacity(0.30)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.ink.opacity(0.10), lineWidth: 0.5))
    }
}
