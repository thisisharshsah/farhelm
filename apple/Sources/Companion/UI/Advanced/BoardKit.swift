import CompanionBoard
import SwiftUI

// The small pieces every view of the board is made of: how a status, a
// priority, a model and an amount of tokens look, wherever they are shown.

extension WorkStatus {
    /// The status's own color. It never stands alone: the word is always
    /// shown with it.
    var tint: Color {
        switch self {
        case .backlog: return Design.Tone.neutral.color
        case .todo: return Design.Tone.info.color
        case .inProgress: return Design.Tone.accent.color
        case .review: return Design.Tone.caution.color
        case .done: return Design.Tone.positive.color
        }
    }

    var icon: String {
        switch self {
        case .backlog: return "tray"
        case .todo: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .review: return "eye"
        case .done: return "checkmark.circle.fill"
        }
    }
}

extension WorkPriority {
    var tint: Color {
        switch self {
        case .low: return Design.Tone.neutral.color
        case .medium: return Design.Tone.info.color
        case .high: return Design.Tone.caution.color
        case .urgent: return Design.Tone.critical.color
        }
    }

    var icon: String {
        switch self {
        case .low: return "arrow.down"
        case .medium: return "equal"
        case .high: return "arrow.up"
        case .urgent: return "exclamationmark.2"
        }
    }
}

extension WorkKind {
    var icon: String {
        switch self {
        case .feature: return "sparkles"
        case .bug: return "ladybug"
        case .refactor: return "arrow.triangle.2.circlepath"
        case .test: return "testtube.2"
        case .docs: return "doc.text"
        case .research: return "magnifyingglass"
        case .design: return "ruler"
        case .ops: return "shippingbox"
        case .chore: return "wrench.and.screwdriver"
        }
    }
}

extension ReviewRecommendation {
    var title: String {
        switch self {
        case .approve: return "Approve"
        case .askForChanges: return "Ask for Changes"
        case .throwAway: return "Throw Away"
        }
    }

    var icon: String {
        switch self {
        case .approve: return "checkmark.circle.fill"
        case .askForChanges: return "arrow.uturn.backward.circle.fill"
        case .throwAway: return "trash.fill"
        }
    }

    var tone: Design.Tone {
        switch self {
        case .approve: return .positive
        case .askForChanges: return .caution
        case .throwAway: return .critical
        }
    }
}

extension BoardGoal.Status {
    var tint: Color {
        switch self {
        case .active: return Design.Tone.accent.color
        case .reached: return Design.Tone.positive.color
        case .setAside: return Design.Tone.neutral.color
        }
    }

    var icon: String {
        switch self {
        case .active: return "target"
        case .reached: return "checkmark.seal.fill"
        case .setAside: return "pause.circle"
        }
    }
}

/// How a goal stands, as a pill with its word.
struct GoalStatusPill: View {
    let status: BoardGoal.Status

    var body: some View {
        HStack(spacing: Design.Space.xxs) {
            Image(systemName: status.icon)
                .font(Design.Icon.small.font.weight(.bold))
                .imageScale(.small)
            Text(status.title)
                .font(Design.TextRole.caption.font.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, Design.Space.xs)
        .frame(minHeight: Design.Control.small.height)
        .background(status.tint.opacity(0.16), in: Capsule())
        .fixedSize()
        .accessibilityLabel(status.title)
    }
}

/// A status as a filled pill with its word.
struct WorkStatusPill: View {
    let status: WorkStatus
    var compact = false

    var body: some View {
        HStack(spacing: Design.Space.xxs) {
            Image(systemName: status.icon)
                .font(Design.Icon.small.font.weight(.bold))
                .imageScale(.small)
            if !compact {
                Text(status.title)
                    .font(Design.TextRole.caption.font.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, compact ? Design.Space.xxs : Design.Space.xs)
        .frame(minHeight: Design.Control.small.height)
        .background(status.tint.opacity(0.16), in: Capsule())
        .fixedSize()
        .accessibilityLabel(status.title)
    }
}

/// A priority as its arrow and, with room, its word.
struct PriorityMark: View {
    let priority: WorkPriority
    var showsWord = false

    var body: some View {
        HStack(spacing: Design.Space.xxs) {
            Image(systemName: priority.icon)
                .font(Design.Icon.small.font.weight(.bold))
                .imageScale(.small)
            if showsWord {
                Text(priority.title)
                    .font(Design.TextRole.caption.font.weight(.medium))
            }
        }
        .foregroundStyle(priority.tint)
        .fixedSize()
        .help("\(priority.title) priority")
        .accessibilityLabel("\(priority.title) priority")
    }
}

/// The model a task is given to: its engine's logo and its name. A
/// suggestion nobody has answered yet is drawn with a dashed edge.
struct ModelChip: View {
    let assignment: Assignment?
    /// The most letters of the model's name that are shown.
    var limit = 26

    private var name: String {
        guard let assignment else { return "No model" }
        let full = BoardText.modelName(assignment.label)
        return full.count > limit ? String(full.prefix(limit - 1)) + "…" : full
    }

    var body: some View {
        HStack(spacing: Design.Space.xxs) {
            if let assignment, let engine = EngineChoice(assignment.model) {
                EngineLogo(kind: engine.kind, tool: engine.tool, size: Design.Icon.small.width - Design.Space.xxs)
            } else {
                Image(systemName: "questionmark.circle")
                    .font(Design.Icon.small.font)
            }
            Text(name)
                .font(Design.TextRole.caption.font.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Design.Space.xxs)
        .frame(minHeight: Design.Control.small.height)
        .background(Design.Fill.raised.style, in: Capsule())
        .overlay(Capsule().strokeBorder(Design.Fill.line.style,
                                        style: StrokeStyle(lineWidth: 1, dash: accepted ? [] : [3, 2])))
        .help(help)
    }

    private var accepted: Bool { assignment?.accepted ?? true }

    private var help: String {
        guard let assignment else { return "No model yet. The supervisor suggests one, or choose one yourself." }
        let who: String
        switch assignment.source {
        case .supervisor: who = "Suggested by the supervisor"
        case .rule: who = "Suggested by rule"
        case .person: who = "Chosen by you"
        }
        let state = assignment.accepted || assignment.source == .person ? "" : " (not confirmed yet; it is used unless you change it)"
        return "\(assignment.label)\n\(who)\(state)\(assignment.reason.isEmpty ? "" : "\n" + assignment.reason)"
    }
}

/// The mark on the option the supervisor recommends, wherever a person is
/// asked to choose: a step that needs a yes, an agent's question, a task
/// waiting in Review.
struct RecommendedTag: View {
    var body: some View {
        HStack(spacing: Design.Space.xxs) {
            Image(systemName: "star.fill")
                .font(Design.TextRole.caption.font.weight(.bold))
                .imageScale(.small)
            Text("Recommended")
                .font(Design.TextRole.caption.font.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Design.Tone.accent.color)
        .padding(.horizontal, Design.Space.xxs)
        .background(Design.Tone.accent.color.opacity(0.14), in: Capsule())
        .fixedSize()
        .accessibilityLabel("Recommended by the supervisor")
    }
}

/// Puts "Recommended" under an option when it is the one recommended.
private struct RecommendedMark: ViewModifier {
    let on: Bool
    let why: String

    func body(content: Content) -> some View {
        VStack(spacing: Design.Space.xxs) {
            content
            if on {
                RecommendedTag()
                    .help(why.isEmpty ? "The supervisor recommends this answer. You decide." : why)
                    .transition(.opacity.combined(with: .offset(y: -3)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: on)
    }
}

extension View {
    /// Marks an option as the one the supervisor recommends. `why` is
    /// shown when the pointer rests on the mark.
    func recommended(_ on: Bool, why: String = "") -> some View {
        modifier(RecommendedMark(on: on, why: why))
    }
}

/// A bar that fills from the left: a share of something.
struct ShareBar: View {
    /// 0 to 1; anything past 1 fills the bar.
    let fraction: Double
    var tint: Color = Design.Tone.accent.color
    var height: CGFloat = Design.Space.xxs

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Design.Fill.line.style)
                Capsule().fill(tint)
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A small button with a word and, if wanted, a symbol: the board's own
/// button, the same wherever one is needed.
struct BoardButton: View {
    let title: String
    var icon: String?
    var tint: Color?
    var prominent = false
    let action: () -> Void
    @State private var hover = false

    init(_ title: String, icon: String? = nil, tint: Color? = nil, prominent: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.Space.xxs) {
                if let icon {
                    Image(systemName: icon)
                        .font(Design.Icon.small.font.weight(.semibold))
                }
                if !title.isEmpty {
                    Text(title)
                        .font(Design.TextRole.caption.font.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(prominent ? AnyShapeStyle(.background) : (tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary)))
            .padding(.horizontal, title.isEmpty ? Design.Space.xxs + Design.Space.xxs / 2 : Design.Space.xs)
            .frame(minHeight: Design.Control.small.height)
            .background {
                if prominent {
                    Capsule().fill(Design.Tone.accent.color)
                } else {
                    Capsule().fill((tint ?? Color.primary).opacity(hover ? 0.18 : 0.09))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .fixedSize()
    }
}

/// A quiet heading over a part of a panel.
struct BoardHeading: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .textRole(.caption, .secondary)
            .fontWeight(.semibold)
            .textCase(.uppercase)
            .kerning(0.4)
    }
}

/// The label of a menu drawn as one of the board's own controls.
struct BoardMenuLabel: View {
    let text: String
    var icon: String?

    var body: some View {
        HStack(spacing: Design.Space.xxs) {
            if let icon {
                Image(systemName: icon)
                    .iconWidth(.small)
            }
            Text(text)
                .font(Design.TextRole.caption.font.weight(.medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(Design.TextRole.caption.font.weight(.bold))
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, Design.Space.xs)
        .frame(minHeight: Design.Control.small.height)
        .background(Design.Fill.raised.style, in: Capsule())
        .contentShape(Capsule())
    }
}

extension View {
    /// A menu's label as the board draws its controls: no system button
    /// around it and no arrow of the system's.
    func boardMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }

    /// A field the board edits text in.
    func boardField() -> some View {
        textFieldStyle(.plain)
            .textRole(.label)
            .padding(.horizontal, Design.Space.xs)
            .padding(.vertical, Design.Space.xxs)
            .background(Design.Fill.raised.style, in: Design.Radius.shape(Design.Radius.control))
            .overlay(Design.Radius.shape(Design.Radius.control).strokeBorder(Design.Fill.line.style))
    }
}

/// Words and numbers as the board writes them.
enum BoardText {
    /// "148k", with a mark when part of it is an estimate.
    static func tokens(_ total: UsageTotal) -> String {
        (total.isExact ? "" : "~") + ContextUse.short(total.tokens)
    }

    /// A model's name without its engine, where the engine's logo is
    /// already beside it: "Claude · Sonnet 5.5" reads "Sonnet 5.5".
    static func modelName(_ label: String) -> String {
        let parts = label.components(separatedBy: " · ")
        return parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : label
    }

    /// A number of tokens as a person types it: "200000", "200k", "1.5m",
    /// "2,000,000". nil for nothing, zero or anything else.
    static func parseTokens(_ text: String) -> Int? {
        let cleaned = text.lowercased().replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        let digits = cleaned.prefix { $0.isNumber || $0 == "." }
        guard let base = Double(digits) else { return nil }
        let scale: Double
        switch cleaned.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).first {
        case "k": scale = 1_000
        case "m": scale = 1_000_000
        default: scale = 1
        }
        let value = base * scale
        return value >= 1 && value < 1e13 ? Int(value.rounded()) : nil
    }

    /// How long something took: "4 min", "1 h 20 min", "32 s".
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        if whole < 60 { return "\(whole) s" }
        if whole < 3_600 { return "\(whole / 60) min" }
        let minutes = (whole % 3_600) / 60
        return minutes == 0 ? "\(whole / 3_600) h" : "\(whole / 3_600) h \(minutes) min"
    }

    /// Why an answer to a task's review carries "Recommended": who
    /// recommends it, and what they found.
    static func why(_ advice: Review?) -> String {
        guard let advice else { return "" }
        return "Recommended by the supervisor (\(advice.by))." + (advice.notes.isEmpty ? "" : " " + advice.notes)
    }

    /// A day, short, with its year when that is not this one.
    private static func day(_ date: Date) -> String {
        Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// The days something went on for: "Nov 3 to Nov 9", "Nov 3", or
    /// "since Nov 3" while it still does. Empty when it never began.
    static func days(from start: Date?, to end: Date?) -> String {
        guard let start else { return "" }
        let first = day(start)
        guard let end else { return "since \(first)" }
        let last = day(end)
        return first == last ? first : "\(first) to \(last)"
    }

    /// A day and time, short: today's as a time, others with the day.
    static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

/// A field that edits a copy of a text and hands it back when the person
/// is done with it (Return, or leaving the field). What is being typed is
/// never changed under the cursor, and the board is saved once, not at
/// every letter.
struct CommitField: View {
    let placeholder: String
    /// The text as the board has it.
    let value: String
    /// Grows downward with what is written, to a dozen lines.
    var multiline = false
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private func done() {
        if text != value { commit(text) }
    }

    var body: some View {
        TextField(placeholder, text: $text, axis: multiline ? .vertical : .horizontal)
            .lineLimit(multiline ? 1...12 : 1...1)
            // A long title shows its start and its end rather than
            // running off the panel's edge, as the branch name and file
            // rows beside it already do.
            .truncationMode(multiline ? .tail : .middle)
            .boardField()
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { _, fresh in
                if !focused { text = fresh }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { done() }
            }
            .onSubmit { done() }
    }
}
