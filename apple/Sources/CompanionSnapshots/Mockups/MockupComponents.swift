import SwiftUI

// The pieces every board mock-up shares. Only tokens from apple/Design
// (Design.Space, Radius, TextRole, Tone, Fill, Control, Icon) and the glass
// modifiers are used: no drop shadows, no literal colors or font sizes.

/// Sizes the mock-ups need that the tokens do not have yet: column and
/// panel widths and how strongly a state tints its pill. Kept together so a
/// later task can move what proves right into Tokens.swift.
enum MockMetrics {
    static let tableID: CGFloat = 52
    static let tableState: CGFloat = 156
    static let tableSpecialist: CGFloat = 200
    static let tableTokens: CGFloat = 120
    static let sprintBattery: CGFloat = 320
    static let workloadIdentity: CGFloat = 190
    /// Wide enough for the battery's legend on one line.
    static let workloadMeter: CGFloat = 290
    static let sidePanel: CGFloat = 340
    static let sidePanelWide: CGFloat = 400
    static let sampleCard: CGFloat = 280
    /// Enough of a state's tone to tell the five apart at a glance, little
    /// enough that the word on it stays primary text in light and dark.
    static let tint: Double = 0.18
    static let bar: CGFloat = Design.Space.xs
    static let thinBar: CGFloat = Design.Space.xxs
    static let line: CGFloat = 1
    /// A switch is this many times as wide as it is high, as the system's is.
    static let switchAspect: CGFloat = 1.75
}

// MARK: - Status

/// A task's state as a solid tinted pill: the tone fills it, the symbol
/// takes the tone, and the word stays primary text so it reads on any look.
struct StatePill: View {
    let state: MockState
    var size: Design.Control = .small

    var body: some View {
        HStack(spacing: Design.Space.xxs) {
            Image(systemName: state.symbol)
                .font(size.icon.font)
                .foregroundStyle(state.tone.color)
            Text(state.rawValue)
                .font(size.textRole.font.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, size.padding)
        .frame(height: size.height)
        .background(Capsule().fill(state.tone.color.opacity(MockMetrics.tint)))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Who does a task: the role, then the model it runs on. Neutral, so it
/// never competes with the state pill for color.
struct SpecialistChip: View {
    let role: String?
    let model: String?

    var body: some View {
        HStack(spacing: Design.Space.xxs) {
            Image(systemName: MockBoard.symbol(for: role))
                .font(Design.Icon.small.font)
                .foregroundStyle(.secondary)
            Text(role ?? "Needs a role")
                .textRole(.caption, role == nil ? .secondary : .primary)
                .lineLimit(1)
            if let model {
                Text("·").textRole(.caption, .tertiary)
                Text(model).textRole(.caption, .secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, Design.Space.xs)
        .frame(height: Design.Control.small.height)
        .background(Design.Radius.shape(Design.Radius.chip).fill(Design.Fill.line.style))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Battery

struct BatterySegment {
    let share: Double
    let color: Color
}

/// One bar split by share, on the line fill for what is left.
struct BatteryBar: View {
    let segments: [BatterySegment]
    var height: CGFloat = MockMetrics.bar

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: proxy.size.width * min(max(segment.share, 0), 1))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(Capsule().fill(Design.Fill.line.style))
        .clipShape(Capsule())
    }
}

struct LegendItem: View {
    let tone: Design.Tone
    let text: String

    var body: some View {
        HStack(spacing: Design.Space.xxs) {
            Circle().fill(tone.color).frame(width: Design.Space.xs, height: Design.Space.xs)
            Text(text).textRole(.caption, .secondary).monospacedDigit()
        }
        .fixedSize()
    }
}

/// monday's battery, reduced to three of the five tones: done, in
/// progress and stuck. Everything not started is the empty part of the bar.
struct TaskBattery: View {
    let tasks: [MockTask]

    private var done: Int { tasks.filter { $0.state == .done }.count }
    private var moving: Int { tasks.filter { $0.state?.isMoving ?? false }.count }
    private var stuck: Int { tasks.filter { $0.state == .stuck }.count }

    var body: some View {
        let total = Double(max(tasks.count, 1))
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            BatteryBar(segments: [
                BatterySegment(share: Double(done) / total, color: Design.Tone.positive.color),
                BatterySegment(share: Double(moving) / total, color: Design.Tone.accent.color),
                BatterySegment(share: Double(stuck) / total, color: Design.Tone.critical.color),
            ])
            HStack(spacing: Design.Space.s) {
                LegendItem(tone: .positive, text: "\(done) done")
                LegendItem(tone: .accent, text: "\(moving) in progress")
                LegendItem(tone: .critical, text: "\(stuck) stuck")
                Text("of \(tasks.count)").textRole(.caption, .tertiary).fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Tokens used against a plan or an estimate, on a thin bar that turns
/// critical once it is passed.
struct TokenMeter: View {
    let used: Int
    let plan: Int
    var noun = "tokens"
    var overText = "Over plan"

    private var over: Bool { used > plan }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            HStack(spacing: Design.Space.xs) {
                Text("\(used.tokenText) of \(plan.tokenText) \(noun)")
                    .textRole(.caption, .secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 0)
                if over {
                    Label(overText, systemImage: "exclamationmark.triangle.fill")
                        .textRole(.caption, .primary)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(Design.Tone.critical.color)
                        .fixedSize()
                }
            }
            BatteryBar(segments: [
                BatterySegment(share: Double(used) / Double(max(plan, 1)),
                               color: over ? Design.Tone.critical.color : Design.Tone.accent.color),
            ], height: MockMetrics.thinBar)
        }
    }
}

/// A task's tokens in a card or a row: used of its estimate.
struct TaskTokens: View {
    let task: MockTask

    var body: some View {
        if let estimate = task.estimate {
            HStack(spacing: Design.Space.xxs) {
                if task.overEstimate {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Design.Icon.small.font)
                        .foregroundStyle(Design.Tone.critical.color)
                }
                Text(task.used > 0 ? "\(task.used.tokenText) of \(estimate.tokenText)" : "\(estimate.tokenText) planned")
                    .textRole(.caption, task.overEstimate ? .primary : .secondary)
                    .monospacedDigit()
            }
            .fixedSize()
        } else {
            Text("No estimate").textRole(.caption, .tertiary).fixedSize()
        }
    }
}

/// Where a task with no pill stands. Not started is not a state worth a
/// color, as monday leaves its default label blank.
struct QuietState: View {
    let task: MockTask

    var body: some View {
        Text(task.column == .todo ? "Queued" : "Not planned")
            .textRole(.caption, .tertiary)
            .fixedSize()
            // As tall as a pill, so a card without one lines up with its row.
            .frame(height: Design.Control.small.height)
    }
}

// MARK: - Card

struct TaskCard: View {
    let task: MockTask

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.xs) {
                Text(task.id).textRole(.caption, .secondary).monospacedDigit()
                Spacer(minLength: Design.Space.xs)
                if let state = task.state {
                    StatePill(state: state)
                } else {
                    QuietState(task: task)
                }
            }
            Text(task.title)
                .textRole(.body)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Design.Space.xs) {
                SpecialistChip(role: task.role, model: task.model)
                Spacer(minLength: Design.Space.xs)
                TaskTokens(task: task)
            }
        }
        .padding(Design.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Radius.shape(Design.Radius.card).fill(Design.Fill.content.style))
        .overlay(Design.Radius.shape(Design.Radius.card)
            .strokeBorder(Design.Fill.line.style, lineWidth: MockMetrics.line))
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Design.Fill.line.style).frame(height: MockMetrics.line)
    }
}

// MARK: - Screen

enum MockView: String, CaseIterable, Identifiable {
    case kanban = "Kanban"
    case table = "Table"
    case workload = "Workload"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .kanban: "rectangle.split.3x1"
        case .table: "tablecells"
        case .workload: "person.2"
        }
    }
}

/// The three views over one board, as one glass group in the toolbar.
struct ViewSwitcher: View {
    let selected: MockView?

    var body: some View {
        HStack(spacing: Design.Space.xxs) {
            ForEach(MockView.allCases) { view in
                Label(view.rawValue, systemImage: view.symbol)
                    .textRole(.label, view == selected ? .primary : .secondary)
                    .padding(.horizontal, Design.Control.regular.padding)
                    .frame(height: Design.Control.regular.height)
                    .background {
                        if view == selected {
                            Capsule().fill(Design.Tone.accent.color.opacity(MockMetrics.tint))
                        }
                    }
            }
        }
        .glassToolbarGroup()
        .fixedSize()
    }
}

/// A mock-up's window: the panel's ground, a glass toolbar and the content
/// layer under it.
struct MockScreen<Content: View>: View {
    var title = MockBoard.name
    var subtitle = "Companion"
    var selected: MockView?
    var showsViews = true
    let content: Content
    @Environment(\.widthClass) private var widthClass

    init(title: String = MockBoard.name, subtitle: String = "Companion", selected: MockView? = nil,
         showsViews: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.selected = selected
        self.showsViews = showsViews
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            if widthClass == .compact {
                VStack(alignment: .leading, spacing: Design.Space.s) {
                    heading
                    if showsViews { ViewSwitcher(selected: selected) }
                }
            } else {
                HStack(spacing: Design.Space.m) {
                    heading
                    Spacer(minLength: 0)
                    if showsViews { ViewSwitcher(selected: selected) }
                }
            }
            content
        }
        .padding(Design.Space.l)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(CompanionBackdrop())
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(subtitle).textRole(.caption, .secondary)
            Text(title).textRole(.title)
        }
    }
}

extension View {
    /// The content layer: cards, rows and messages sit on it, never on glass.
    func mockContent() -> some View {
        padding(Design.Space.m)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Design.Radius.shape(Design.Radius.panel).fill(Design.Fill.content.style))
    }
}

// MARK: - Sprint header

/// A sprint group's head: its name, its dates, and its battery of tasks and
/// tokens against plan.
struct SprintHeader: View {
    let sprint: MockSprint
    @Environment(\.widthClass) private var widthClass

    private var tasks: [MockTask] { MockBoard.tasks(in: sprint) }

    var body: some View {
        if widthClass == .compact {
            VStack(alignment: .leading, spacing: Design.Space.s) {
                title
                batteries
            }
        } else {
            HStack(alignment: .top, spacing: Design.Space.l) {
                title.frame(maxWidth: .infinity, alignment: .leading)
                batteries.frame(width: MockMetrics.sprintBattery)
            }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            HStack(spacing: Design.Space.xs) {
                Image(systemName: sprint.active ? "flag.fill" : "tray.full")
                    .iconWidth(.regular)
                    .foregroundStyle(sprint.active ? Design.Tone.accent.color : Color.secondary)
                Text(sprint.name).textRole(.heading)
                if sprint.active {
                    Text("Active").textRole(.caption, .secondary)
                }
            }
            Text(sprint.dates).textRole(.caption, .secondary)
        }
    }

    @ViewBuilder
    private var batteries: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            // Nothing in the backlog has started, so its battery would be an
            // empty bar of zeros; it shows what is planned instead.
            if sprint.active {
                TaskBattery(tasks: tasks)
            }
            if let plan = sprint.tokensPlan {
                TokenMeter(used: tasks.map(\.used).reduce(0, +), plan: plan)
            } else {
                let planned = tasks.compactMap(\.estimate).reduce(0, +)
                Text("\(planned.tokenText) tokens estimated, \(tasks.filter { $0.estimate == nil }.count) without an estimate")
                    .textRole(.caption, .secondary)
                    // Fills the column so it starts where the sprint's bars do.
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}