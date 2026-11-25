import SwiftUI

// The team's side of the board: Workload with the automatic run limit, the
// board's rules as sentences, and a task's chat in its side panel.
// Findings and decisions: docs/design/board-concepts.md.

// MARK: - Workload

struct WorkloadMockup: View {
    var body: some View {
        MockScreen(selected: .workload) {
            VStack(alignment: .leading, spacing: Design.Space.l) {
                RunLimitCard()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Specialists").textRole(.heading).padding(.bottom, Design.Space.xs)
                    ForEach(MockBoard.specialists) { specialist in
                        Hairline()
                        WorkloadRow(specialist: specialist)
                    }
                }
            }
            .mockContent()
        }
    }
}

/// The automatic run limit made visible: a seat per run the board allows,
/// filled for each run going, with the rule that sets it in words.
struct RunLimitCard: View {
    private let limit = MockBoard.runLimit
    private let running = MockBoard.runningCount
    private let budgetShare = Double(MockBoard.sprintUsed) / Double(MockBoard.active.tokensPlan ?? 1)

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.xs) {
                Text("Run limit").textRole(.heading)
                Label("Set automatically", systemImage: "gauge.with.dots.needle.50percent")
                    .textRole(.caption, .secondary)
                Spacer(minLength: 0)
                Text("\(running) of \(limit) running").textRole(.label).monospacedDigit()
            }
            HStack(spacing: Design.Space.xxs) {
                ForEach(0..<limit, id: \.self) { seat in
                    Capsule()
                        .fill(seat < running ? AnyShapeStyle(Design.Tone.accent.color) : Design.Fill.line.style)
                        .frame(maxWidth: .infinity)
                        .frame(height: MockMetrics.bar)
                }
            }
            Text("One run per specialist, \(limit) on this team. Past 80% of the budget it drops to one at a time; \(Int(budgetShare * 100))% is used.")
                .textRole(.caption, .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Next to start: T-64 Workload view, when a Mac engineer is free.")
                .textRole(.caption, .secondary)
        }
        .padding(Design.Space.m)
        .background(Design.Radius.shape(Design.Radius.tile).fill(Design.Fill.raised.style))
    }
}

struct WorkloadRow: View {
    let specialist: MockSpecialist
    @Environment(\.widthClass) private var widthClass

    private var running: [MockTask] { MockBoard.running(specialist) }
    private var queued: [MockTask] { MockBoard.queued(for: specialist.role) }

    var body: some View {
        Group {
            if widthClass == .compact {
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    HStack {
                        identity
                        Spacer(minLength: Design.Space.xs)
                        queue
                    }
                    current
                    meter
                }
            } else {
                // The queue sits under the specialist rather than in a column
                // of its own, so the task it runs keeps room for its title.
                HStack(alignment: .top, spacing: Design.Space.m) {
                    VStack(alignment: .leading, spacing: Design.Space.xs) {
                        identity
                        queue
                    }
                    .frame(width: MockMetrics.workloadIdentity, alignment: .leading)
                    current.frame(maxWidth: .infinity, alignment: .leading)
                    meter.frame(width: MockMetrics.workloadMeter)
                }
            }
        }
        .padding(.vertical, Design.Space.s)
        .padding(.horizontal, Design.Space.xs)
    }

    private var identity: some View {
        HStack(spacing: Design.Space.xs) {
            Image(systemName: MockBoard.symbol(for: specialist.role))
                .iconWidth(.regular)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(specialist.title).textRole(.body)
                Text("Model \(specialist.model)").textRole(.caption, .secondary)
            }
        }
    }

    @ViewBuilder
    private var current: some View {
        if let task = running.first {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                if let state = task.state { StatePill(state: state) }
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.xs) {
                    Text(task.id).textRole(.caption, .secondary).monospacedDigit().fixedSize()
                    Text(task.title).textRole(.label).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                HStack(spacing: Design.Space.xs) {
                    Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
                    Text("Free").textRole(.label, .secondary)
                }
                // Its battery still counts work in Review as in progress, so
                // say which task that is, or "Free" would contradict the bar.
                if let waiting = inReview {
                    Text("\(waiting.id) waits for your review").textRole(.caption, .secondary)
                }
            }
        }
    }

    private var inReview: MockTask? {
        MockBoard.sprintTasks(of: specialist).first { $0.column == .review }
    }

    /// The queue belongs to the role, so it is listed under the role's first
    /// seat only; listing it on every seat read as two queues of the same work.
    private var queue: some View {
        let text: String
        if let seat = specialist.seat, seat > 1 {
            text = "Shares the \(specialist.role) queue"
        } else {
            text = queued.isEmpty ? "Nothing queued" : "Queued: " + queued.map(\.id).joined(separator: ", ")
        }
        return Text(text)
            .textRole(.caption, queued.isEmpty ? .tertiary : .secondary)
            .lineLimit(1)
    }

    private var meter: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            TaskBattery(tasks: MockBoard.sprintTasks(of: specialist))
            TokenMeter(used: MockBoard.used(by: specialist), plan: specialist.tokensPlan, noun: "planned")
        }
    }
}

// MARK: - Board Settings rules

/// A rule as a sentence. Even places are plain words, odd places the values
/// a person can change, so the values can be drawn as the editable part.
struct MockRule: Identifiable {
    let id: String
    let parts: [String]
    var on = true
    /// Kept in code (such as `Checks.letThrough`): shown, never switched off.
    var fixed = false
}

struct RulesMockup: View {
    private let groups: [(String, [MockRule])] = [
        ("Runs", [
            MockRule(id: "warn", parts: ["When a run passes ", "1.5x", " its estimate, ", "warn me on its card", "."]),
            MockRule(id: "check", parts: ["When a run passes ", "2x", " its estimate, ", "ask the Project Manager", " whether to go on."]),
            MockRule(id: "stop", parts: ["When a run passes ", "3x", " its estimate, ", "stop it and re-plan", "."]),
        ]),
        ("Review", [
            MockRule(id: "checks", parts: ["When a task's checks do not all pass, keep it for me to look at."], fixed: true),
            MockRule(id: "queue", parts: ["When a role has ", "3 tasks", " waiting for me in Review, ", "start no more of its work", "."]),
            MockRule(id: "redo", parts: ["When I send a task back ", "3 times", ", leave it for me."]),
        ]),
        ("Budget and team", [
            MockRule(id: "budget", parts: ["When ", "80%", " of the budget is used, ", "run one task at a time", "."]),
            MockRule(id: "idle", parts: ["When a specialist has had no run for ", "24 hours", ", ", "retire it", "."], on: false),
        ]),
    ]

    var body: some View {
        MockScreen(title: "Board Settings", subtitle: MockBoard.name, showsViews: false) {
            VStack(alignment: .leading, spacing: Design.Space.l) {
                VStack(alignment: .leading, spacing: Design.Space.xxs) {
                    Text("Rules").textRole(.heading)
                    Text("The board keeps these by itself. Purple words can be changed.")
                        .textRole(.caption, .secondary)
                }
                ForEach(groups, id: \.0) { group in
                    RuleGroup(title: group.0, rules: group.1)
                }
                SuggestedRule()
                Button {} label: { Label("Add a rule", systemImage: "plus") }
                    .glassButton(.glass)
            }
            .readableWidth()
            .mockContent()
        }
    }
}

struct RuleGroup: View {
    let title: String
    let rules: [MockRule]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).textRole(.label, .secondary).padding(.bottom, Design.Space.xxs)
            ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                if index > 0 { Hairline() }
                RuleRow(rule: rule)
            }
        }
        .padding(.horizontal, Design.Space.m)
        .padding(.vertical, Design.Space.s)
        .background(Design.Radius.shape(Design.Radius.tile).fill(Design.Fill.raised.style))
    }
}

struct RuleRow: View {
    let rule: MockRule

    var body: some View {
        HStack(spacing: Design.Space.s) {
            Text(sentence)
                .textRole(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if rule.fixed {
                Label("Always on", systemImage: "lock.fill")
                    .textRole(.caption, .secondary)
                    .fixedSize()
            } else {
                MockSwitch(on: rule.on)
            }
        }
        .padding(.vertical, Design.Space.s)
    }

    private var sentence: AttributedString {
        var text = AttributedString()
        for (index, part) in rule.parts.enumerated() {
            var piece = AttributedString(part)
            if index.isMultiple(of: 2) == false {
                piece.foregroundColor = Design.Tone.accent.color
                piece.font = Design.TextRole.body.font.weight(.semibold)
            }
            text += piece
        }
        return text
    }
}

/// A switch drawn from tokens. A window that is never shown is never the
/// key window, so the system's own switch draws grey whether on or off and
/// the pictures could not tell a rule that is on from one that is off.
struct MockSwitch: View {
    let on: Bool

    var body: some View {
        let height = Design.Control.small.height
        Capsule()
            .fill(on ? AnyShapeStyle(Design.Tone.accent.color) : Design.Fill.line.style)
            .frame(width: height * MockMetrics.switchAspect, height: height)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(Design.Fill.content.style)
                    .padding(MockMetrics.line * 2)
            }
            .accessibilityElement()
            .accessibilityLabel(on ? "On" : "Off")
    }
}

/// The Project Manager may suggest a rule; it is advice, and only a person
/// adds it.
struct SuggestedRule: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Label("The Project Manager suggests", systemImage: "lightbulb")
                .textRole(.label, .secondary)
            Text("When QA finds a failing test, give the fix to the task's own role.")
                .textRole(.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Design.Space.xs) {
                Button("Add this rule") {}.glassButton(.prominent, size: .small)
                Button("Not now") {}.glassButton(.glass, size: .small)
            }
        }
        .padding(Design.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Radius.shape(Design.Radius.tile)
            .strokeBorder(Design.Fill.line.style, lineWidth: MockMetrics.line))
    }
}

// MARK: - Task side panel

/// A task opens beside the board with its one chat, so the board stays in
/// view; on a compact window the panel takes the whole width instead.
struct SidePanelMockup: View {
    @Environment(\.widthClass) private var widthClass

    var body: some View {
        MockScreen(selected: .table) {
            if widthClass == .compact {
                TaskPanel(task: MockBoard.task("T-63"), compact: true)
            } else {
                HStack(alignment: .top, spacing: Design.Space.m) {
                    TableGroup(sprint: MockBoard.active, selected: "T-63", showsBattery: false)
                        .mockContent()
                        // Beside the panel the table keeps under 800 points even
                        // on a wide window; regular columns there squeezed titles
                        // into two lines while State and Specialist sat half
                        // empty, so the rows stack as on a compact window.
                        .environment(\.widthClass, .compact)
                    TaskPanel(task: MockBoard.task("T-63"), compact: false)
                        .frame(width: widthClass == .wide ? MockMetrics.sidePanelWide : MockMetrics.sidePanel)
                }
            }
        }
    }
}

struct TaskPanel: View {
    let task: MockTask
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(spacing: Design.Space.xs) {
                if compact {
                    Label("Board", systemImage: "chevron.left").textRole(.label, .secondary)
                }
                Text(task.id).textRole(.caption, .secondary).monospacedDigit()
                Spacer(minLength: 0)
                Image(systemName: compact ? "ellipsis" : "xmark").foregroundStyle(.secondary)
            }
            Text(task.title).textRole(.title).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Design.Space.xs) {
                if let state = task.state { StatePill(state: state, size: .regular) }
                SpecialistChip(role: task.role, model: task.model)
            }
            if let estimate = task.estimate {
                TokenMeter(used: task.used, plan: estimate, noun: "estimated", overText: "Over estimate")
            }
            PanelTabs()
            chat
            HStack(spacing: Design.Space.xs) {
                Text("Message this task's chat").textRole(.label, .tertiary)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.circle.fill")
                    .font(Design.Icon.large.font)
                    .foregroundStyle(Design.Tone.accent.color)
            }
            .padding(.horizontal, Design.Space.s)
            .frame(height: Design.Control.large.height)
            .background(Capsule().fill(Design.Fill.content.style))
            .overlay(Capsule().strokeBorder(Design.Fill.line.style, lineWidth: MockMetrics.line))
        }
        .padding(Design.Space.m)
        // A chat is content, and glass never goes behind messages
        // (apple/Design/README.md): the panel sits on the raised fill, and
        // only its tabs are on glass.
        .background(Design.Radius.shape(Design.Radius.panel).fill(Design.Fill.raised.style))
    }

    private var chat: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            RunDivider(text: "Run 1 · Mac engineer 2 · m2")
            ChatEntry(author: "Mac engineer 2", time: "10:14",
                      text: "The battery bar draws, but the snapshot check fails at compact width: the legend wraps under the bar.")
            BoardNotice(symbol: "hand.raised.fill",
                        text: "Board rule: this run passed 2x its estimate, so the Project Manager was asked whether to go on.")
            ChatEntry(author: "Project Manager", time: "10:15",
                      text: "Go on with a new estimate of 110k. If the legend still wraps, split it into its own task.")
            BoardNotice(symbol: "exclamationmark.triangle.fill",
                        text: "Stuck: 2 of 5 checks fail. It is not reviewed until they pass or you let it through.",
                        tone: .critical)
        }
        .padding(Design.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Radius.shape(Design.Radius.tile).fill(Design.Fill.content.style))
    }
}

struct PanelTabs: View {
    private let tabs = ["Chat", "Details", "Runs 1"]

    var body: some View {
        HStack(spacing: Design.Space.xxs) {
            ForEach(tabs, id: \.self) { tab in
                Text(tab)
                    .textRole(.label, tab == "Chat" ? .primary : .secondary)
                    .padding(.horizontal, Design.Control.small.padding)
                    .frame(height: Design.Control.regular.height)
                    .background {
                        if tab == "Chat" {
                            Capsule().fill(Design.Tone.accent.color.opacity(MockMetrics.tint))
                        }
                    }
            }
        }
        .glassToolbarGroup()
        .fixedSize()
    }
}

struct RunDivider: View {
    let text: String

    var body: some View {
        HStack(spacing: Design.Space.xs) {
            Hairline()
            Text(text).textRole(.caption, .tertiary).fixedSize()
            Hairline()
        }
    }
}

struct ChatEntry: View {
    let author: String
    let time: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            HStack(spacing: Design.Space.xs) {
                Text(author).textRole(.label)
                Text(time).textRole(.caption, .tertiary).monospacedDigit()
            }
            Text(text).textRole(.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What the board itself did, set apart from what people and models said.
struct BoardNotice: View {
    let symbol: String
    let text: String
    /// The tone of the state the notice reports, so a Stuck notice is as red
    /// as the Stuck pill and the five state colors keep one meaning each.
    var tone: Design.Tone = .caution

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.xs) {
            Image(systemName: symbol)
                .font(Design.Icon.small.font)
                .foregroundStyle(tone.color)
            Text(text).textRole(.caption, .secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Design.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Radius.shape(Design.Radius.control)
            .fill(tone.color.opacity(MockMetrics.tint / 2)))
    }
}