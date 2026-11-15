import SwiftUI

/// The agent asking for the user, shown above the input. While it simply
/// works there is no card: the chat shows that under the task itself.
///
/// When the agent wants to do something that needs a yes, or has a
/// question, the card comes up: each step slides in as its own card with
/// Allow, Always allow and Deny underneath. A step that goes through flashes a
/// checkmark; one that fails shakes the card. Stopping is done from the
/// chat box, where the send button turns into Stop.
struct AgentCard: View {
    /// Allow, Always allow and Deny for what the agent asks to do.
    private func choices(_ proposal: AgentProposal, short: Bool) -> some View {
        HStack(spacing: short ? 6 : 8) {
            Button { app.decide(.allow) } label: { Chip("Allow", icon: "checkmark", tint: Theme.accent) }
                .buttonStyle(.plain)
                .help("Run this once (or say \"allow\")")
            if !proposal.remember.isEmpty || proposal.steps.contains(where: { $0.kind.usesKeyboard }) {
                Button { app.decide(.always) } label: { Chip(short ? "Always" : "Always allow", icon: "checkmark.circle") }
                    .buttonStyle(.plain)
                    .help(proposal.remember.isEmpty
                          ? "Run this, and stop asking about clicks and typing for the rest of this task"
                          : "Run this, and never ask again about: \(proposal.remember.joined(separator: ", "))")
            }
            Button { app.decide(.deny) } label: { Chip("Deny", icon: "xmark", tint: Theme.rose) }
                .buttonStyle(.plain)
                .help("Do not run this; the task stops (or say \"deny\")")
        }
    }

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
    /// Steps taken: what it said and its thinking are not steps.
    private var done: Int { app.agentLog.filter { !$0.hasPrefix("Said: ") && $0 != "Thinking" }.count }
    /// How tall the steps are, so the list is as tall as they are, up to a cap.
    @State private var listHeight: CGFloat = 0

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
            }

            if let question = app.pendingQuestion {
                // The agent stopped to ask. Pick an answer, or type one in
                // the chat box; it carries on from there.
                Text(question.question)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                // Its choices, as bubbles that arrive one after another;
                // one click answers.
                if !question.options.isEmpty {
                    ChoiceBubbles(question.options, numbered: true) { option in
                        app.answerAgent(option)
                    }
                    .id(question.id)
                }
                Text(question.options.isEmpty ? "Type your answer below." : "Or type your own answer below.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.48))
            } else if let proposal = app.pendingApproval {
                // The steps take the room they need up to a cap, then
                // scroll, so Allow and Deny below never leave the panel.
                ScrollView(.vertical, showsIndicators: listHeight > 260) {
                    stepList(proposal.steps, directory: proposal.directory, animating: proposal.id)
                        .background(GeometryReader { geometry in
                            Color.clear
                                .onAppear { listHeight = geometry.size.height }
                                .onChange(of: geometry.size.height) { _, height in listHeight = height }
                        })
                }
                .frame(height: min(max(listHeight, 30), 260))
                // In a narrow chat the middle one says less, so the three
                // always fit on their line.
                ViewThatFits(in: .horizontal) {
                    choices(proposal, short: false)
                    choices(proposal, short: true)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 13)
        // Working, it is a single line; it has room only when it asks.
        .padding(.vertical, waiting ? 11 : 7)
        // Solid enough that the conversation scrolling behind it never
        // shows through its words.
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .fill(Theme.shade.opacity(0.55)))
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .fill(.thickMaterial))
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
            // The user's move: the mark holds nearly still, in amber.
            LoadingMark(state: .waiting, size: 16)
                .transition(.opacity)
        } else {
            LoadingMark(state: .working, size: 16)
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
        case .delegate: return "person.2"
        case .browser: return "safari"
        case .terminal: return "terminal"
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
        case .delegate: return "Hand a question to a helper (it only reads and searches)"
        case .browser: return step.browserCommand?.args["in"] as? String == "chrome" ? "In your Chrome" : "In the browser beside the chat"
        case .terminal: return "Open a terminal beside the chat"
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
            .background(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous).fill(color.opacity(0.10)))
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
        .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).fill(Theme.shade.opacity(0.30)))
        .overlay(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
            .strokeBorder(Theme.ink.opacity(0.10), lineWidth: 0.5))
    }
}
