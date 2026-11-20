import CompanionBoard
import SwiftUI

// The small pieces every view of the board is made of: how a status, a
// priority, a model and an amount of tokens look, wherever they are shown.

extension WorkStatus {
    /// The status's own color. It never stands alone: the word is always
    /// shown with it.
    var tint: Color {
        switch self {
        case .backlog: return Theme.ink.opacity(0.55)
        case .todo: return Theme.violet
        case .inProgress: return Theme.accent
        case .review: return Theme.amber
        case .done: return Theme.mint
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
        case .low: return Theme.ink.opacity(0.45)
        case .medium: return Theme.violet
        case .high: return Theme.amber
        case .urgent: return Theme.rose
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

extension BoardGoal.Status {
    var tint: Color {
        switch self {
        case .active: return Theme.accent
        case .reached: return Theme.mint
        case .setAside: return Theme.ink.opacity(0.55)
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
        HStack(spacing: 4) {
            Image(systemName: status.icon)
                .font(.system(size: 8.5, weight: .bold))
            Text(status.title)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(status.tint.opacity(0.16)))
        .fixedSize()
        .accessibilityLabel(status.title)
    }
}

/// A status as a filled pill with its word.
struct WorkStatusPill: View {
    let status: WorkStatus
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.icon)
                .font(.system(size: 8.5, weight: .bold))
            if !compact {
                Text(status.title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, compact ? 6 : 8)
        .frame(height: 20)
        .background(Capsule().fill(status.tint.opacity(0.16)))
        .fixedSize()
        .accessibilityLabel(status.title)
    }
}

/// A priority as its arrow and, with room, its word.
struct PriorityMark: View {
    let priority: WorkPriority
    var showsWord = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: priority.icon)
                .font(.system(size: 8.5, weight: .bold))
            if showsWord {
                Text(priority.title)
                    .font(.system(size: 10.5, weight: .medium))
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
        HStack(spacing: 4) {
            if let assignment, let engine = EngineChoice(assignment.model) {
                EngineLogo(kind: engine.kind, tool: engine.tool, size: 10)
            } else {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            Text(name)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.ink.opacity(assignment == nil ? 0.5 : 0.82))
        .padding(.horizontal, 7)
        .frame(height: 20)
        .fixedSize()
        .background(Capsule().fill(Theme.ink.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.22),
                                        style: StrokeStyle(lineWidth: 0.75, dash: accepted ? [] : [3, 2])))
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
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: 7, weight: .bold))
            Text("Recommended")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 5)
        .frame(height: 14)
        .background(Capsule().fill(Theme.accent.opacity(0.14)))
        .fixedSize()
        .accessibilityLabel("Recommended by the supervisor")
    }
}

/// Puts "Recommended" under an option when it is the one recommended.
private struct RecommendedMark: ViewModifier {
    let on: Bool
    let why: String

    func body(content: Content) -> some View {
        VStack(spacing: 3) {
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
    var tint: Color = Theme.accent
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.ink.opacity(0.10))
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
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9.5, weight: .semibold))
                }
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(prominent ? Color.black.opacity(0.82) : (tint ?? Theme.ink.opacity(0.85)))
            .padding(.horizontal, title.isEmpty ? 7 : 9)
            .frame(height: 24)
            .background {
                if prominent {
                    Capsule().fill(Theme.accentGradient)
                } else {
                    Capsule().fill((tint ?? Theme.ink).opacity(hover ? 0.18 : 0.09))
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
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.ink.opacity(0.5))
            .textCase(.uppercase)
            .kerning(0.4)
    }
}

/// The label of a menu drawn as one of the board's own controls.
struct BoardMenuLabel: View {
    let text: String
    var icon: String?

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .opacity(0.6)
        }
        .foregroundStyle(Theme.ink.opacity(0.85))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Capsule().fill(Theme.ink.opacity(0.08)))
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
            .font(.system(size: 12))
            .foregroundStyle(Theme.ink.opacity(0.95))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(Theme.ink.opacity(0.07)))
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
