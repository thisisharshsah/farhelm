import SwiftUI

/// One choice offered as a bubble: its words, with a symbol or a few
/// dimmer words beside them when it has them.
public struct Bubble: Hashable, Sendable {
    public var title: String
    /// An SF Symbol shown before the words.
    public var icon: String?
    /// A few words after the title, dimmer, saying a little more.
    public var detail: String?

    public init(_ title: String, icon: String? = nil, detail: String? = nil) {
        self.title = title
        self.icon = icon
        self.detail = detail
    }
}

/// Choices the AI offers, as bubbles answered with one tap or click.
///
/// They arrive the way a thought does: each rises into place a moment
/// after the one before, out of a little blur, and a light passes over it
/// as it lands. Under the pointer one lifts and glows, and its edge turns
/// slowly through the look's colors; pressed, it gives a little. The one
/// picked fills with the primary, shows a check and sends a ring out while
/// the others fall away, and then it is acted on. With Reduce Motion on,
/// they simply fade in and out.
///
/// Give the view a new identity (`.id`) for each new set of choices, so
/// each set arrives afresh.
public struct ChoiceBubbles: View {
    let bubbles: [Bubble]
    let tint: Color?
    let numbered: Bool
    let size: CGFloat
    let pick: (Int) -> Void

    /// Bubbles; `pick` gets the place of the one chosen.
    public init(_ bubbles: [Bubble], tint: Color? = nil, numbered: Bool = false, size: CGFloat = 12,
                pick: @escaping (Int) -> Void) {
        self.bubbles = bubbles
        self.tint = tint
        self.numbered = numbered
        self.size = size
        self.pick = pick
    }

    /// Plain words, a bubble each; `pick` gets the words chosen.
    public init(_ options: [String], tint: Color? = nil, numbered: Bool = false, size: CGFloat = 12,
                pick: @escaping (String) -> Void) {
        self.init(options.map { Bubble($0) }, tint: tint, numbered: numbered, size: size) { index in
            pick(options[index])
        }
    }

    @State private var arrived = false
    @State private var picked: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        let color = tint ?? Theme.accent
        BubbleFlow(spacing: size * 0.5, lineSpacing: size * 0.5) {
            ForEach(Array(bubbles.enumerated()), id: \.offset) { index, bubble in
                let away = picked != nil && picked != index
                ChoiceBubble(bubble: bubble,
                             number: numbered ? index + 1 : nil,
                             tint: color,
                             size: size,
                             picked: picked == index,
                             landing: delay(index),
                             moving: !reduceMotion) {
                    choose(index)
                }
                .opacity(arrived ? (away ? 0.3 : 1) : 0)
                .scaleEffect(arrived || reduceMotion ? (away ? 0.95 : 1) : 0.86, anchor: .bottomLeading)
                .offset(y: arrived || reduceMotion ? 0 : 10)
                .blur(radius: arrived || reduceMotion ? (away ? 1.2 : 0) : 5)
                .animation(arrival(index), value: arrived)
                .animation(.spring(response: 0.34, dampingFraction: 0.7), value: picked)
                .allowsHitTesting(picked == nil)
            }
        }
        .onAppear { arrived = true }
        .sensoryFeedback(.selection, trigger: picked) { _, now in now != nil }
    }

    /// Each bubble lands a moment after the one before.
    private func delay(_ index: Int) -> Double {
        Double(min(index, 8)) * 0.06
    }

    /// How a bubble arrives: rising on a spring in its turn, or with
    /// Reduce Motion simply fading in.
    private func arrival(_ index: Int) -> Animation {
        if reduceMotion { return Animation.easeOut(duration: 0.2) }
        return Animation.spring(response: 0.46, dampingFraction: 0.76).delay(delay(index))
    }

    /// Shows the choice for a moment, then acts on it. If the bubbles are
    /// still here a little later (acting did not take them away), they can
    /// be chosen from again.
    private func choose(_ index: Int) {
        guard picked == nil else { return }
        picked = index
        let show: UInt64 = reduceMotion ? 50_000_000 : 300_000_000
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: show)
            pick(index)
            try? await Task.sleep(nanoseconds: 900_000_000)
            picked = nil
        }
    }
}

/// One bubble: the whole of it is the button, so it gives as a whole when
/// pressed.
private struct ChoiceBubble: View {
    let bubble: Bubble
    let number: Int?
    let tint: Color
    let size: CGFloat
    let picked: Bool
    /// When it lands, for the light that passes over it then.
    let landing: Double
    /// Whether things move at all (Reduce Motion is off).
    let moving: Bool
    let action: () -> Void

    @State private var hover = false
    @State private var swept = false
    @State private var ring = false

    private var radius: CGFloat { size * 1.25 }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
    /// Words on the primary, once picked: dark on the pale primary of dark
    /// glass, white on the deep one of light glass.
    private var onTint: Color { Theme.isLight ? .white : Color.black.opacity(0.82) }

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, size * 0.92)
                .padding(.vertical, size * 0.48)
                .frame(minHeight: size * 2.5)
                .background(fill)
                .overlay(edge)
                .overlay(sweep)
                .overlay(pulse)
                .contentShape(shape)
                .scaleEffect(picked ? 1.04 : (hover ? 1.025 : 1))
                .offset(y: hover && !picked ? -1 : 0)
                .shadow(color: tint.opacity(hover || picked ? 0.34 : 0), radius: hover || picked ? 9 : 0)
                .animation(.spring(response: 0.3, dampingFraction: 0.72), value: hover)
                .animation(.spring(response: 0.32, dampingFraction: 0.62), value: picked)
        }
        .buttonStyle(BubblePress())
        .whenHovered { hover = $0 }
        .onAppear {
            guard moving else { return }
            withAnimation(.easeInOut(duration: 0.9).delay(landing + 0.2)) { swept = true }
        }
        .accessibilityLabel(bubble.detail.map { "\(bubble.title), \($0)" } ?? bubble.title)
    }

    private var label: some View {
        HStack(spacing: size * 0.55) {
            if picked {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.8, weight: .bold))
                    .foregroundStyle(onTint)
                    .frame(width: size * 1.4, height: size * 1.4)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else if let number {
                Text("\(number)")
                    .font(.system(size: size * 0.8, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .frame(width: size * 1.4, height: size * 1.4)
                    .background(Circle().fill(tint.opacity(hover ? 0.26 : 0.16)))
            } else if let icon = bubble.icon {
                Image(systemName: icon)
                    .font(.system(size: size * 0.85, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: size * 1.25)
            }
            words
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var words: Text {
        let title: Text = Text(bubble.title)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(picked ? onTint : Theme.ink.opacity(0.92))
        guard let detail = bubble.detail, !detail.isEmpty else { return title }
        return title + Text("  " + detail)
            .font(.system(size: size * 0.92))
            .foregroundStyle(picked ? onTint.opacity(0.75) : Theme.ink.opacity(0.5))
    }

    /// Glass with a breath of the primary in it; filled with the primary
    /// once picked.
    private var fill: some View {
        ZStack {
            BubbleFill(shape: shape, tint: tint, lit: false, hover: hover)
            if picked {
                shape.fill(LinearGradient(colors: [tint, Theme.lilac], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .transition(.opacity)
            }
        }
    }

    /// At rest, a soft gradient edge; under the pointer its colors turn.
    private var edge: some View {
        BubbleEdge(shape: shape, tint: tint, lit: picked, turning: hover && moving && !picked)
    }

    /// The light that passes over the bubble once, as it lands.
    private var sweep: some View {
        GeometryReader { geometry in
            let band = max(28, geometry.size.width * 0.42)
            LinearGradient(colors: [.clear,
                                    Theme.isLight ? tint.opacity(0.22) : Color.white.opacity(0.24),
                                    .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: band, height: geometry.size.height * 1.6)
                .rotationEffect(.degrees(16))
                .offset(x: swept ? geometry.size.width + band * 0.2 : -band * 1.2,
                        y: -geometry.size.height * 0.3)
        }
        .clipShape(shape)
        .opacity(swept && moving ? 1 : 0)
        .allowsHitTesting(false)
    }

    /// The ring that goes out from the bubble picked.
    @ViewBuilder
    private var pulse: some View {
        if picked && moving {
            shape.stroke(tint.opacity(ring ? 0 : 0.7), lineWidth: 1.5)
                .padding(ring ? -8 : 0)
                .onAppear { withAnimation(.easeOut(duration: 0.55)) { ring = true } }
                .onDisappear { ring = false }
                .allowsHitTesting(false)
        }
    }
}

/// The look every bubble shares, the choices the AI offers and the pickers
/// under the chat box alike: glass with a breath of its color and a soft
/// gradient edge. Under the pointer it lifts a little and glows, and its
/// edge turns slowly through the look's colors. Lit (chosen, open or on)
/// it holds more of its color. With no color it is a quiet, neutral bubble.
public struct BubbleSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let lit: Bool
    /// Whether it lifts under the pointer. A switch with parts of its own
    /// glows without moving.
    let lifts: Bool

    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(shape: S, tint: Color? = nil, lit: Bool = false, lifts: Bool = true) {
        self.shape = shape
        self.tint = tint
        self.lit = lit
        self.lifts = lifts
    }

    public func body(content: Content) -> some View {
        content
            .background(BubbleFill(shape: shape, tint: tint, lit: lit, hover: hover))
            .overlay(BubbleEdge(shape: shape, tint: tint, lit: lit, turning: hover && !reduceMotion))
            .scaleEffect(hover && lifts && !reduceMotion ? 1.03 : 1)
            .shadow(color: (tint ?? Theme.accent).opacity(hover ? 0.28 : 0), radius: hover ? 7 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.72), value: hover)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: lit)
            .whenHovered { hover = $0 }
    }
}

extension View {
    /// Draws the view as a bubble of the given shape (see `BubbleSurface`).
    public func bubbleSurface<S: InsettableShape>(_ shape: S, tint: Color? = nil, lit: Bool = false,
                                                  lifts: Bool = true) -> some View {
        modifier(BubbleSurface(shape: shape, tint: tint, lit: lit, lifts: lifts))
    }

    /// Draws the view as a capsule bubble (see `BubbleSurface`).
    public func bubbleSurface(tint: Color? = nil, lit: Bool = false, lifts: Bool = true) -> some View {
        modifier(BubbleSurface(shape: Capsule(), tint: tint, lit: lit, lifts: lifts))
    }
}

/// A bubble's glass: a little lighter than what it sits on, with a breath
/// of its color, more of it under the pointer and more again when lit.
struct BubbleFill<S: Shape>: View {
    let shape: S
    let tint: Color?
    let lit: Bool
    let hover: Bool

    var body: some View {
        let color = tint ?? Theme.ink
        let amount = tint == nil ? (lit ? 0.12 : (hover ? 0.08 : 0.04)) : (lit ? 0.18 : (hover ? 0.15 : 0.08))
        ZStack {
            shape.fill(Theme.isLight ? Color.white.opacity(0.72) : Theme.ink.opacity(0.06))
            shape.fill(color.opacity(amount))
        }
    }
}

/// A bubble's edge: a soft gradient of its color at rest, a hairline when
/// it has none, and, while `turning`, the look's colors going slowly round
/// it. Only a turning edge redraws on its own, so bubbles at rest cost
/// nothing.
struct BubbleEdge<S: InsettableShape>: View {
    let shape: S
    let tint: Color?
    let lit: Bool
    let turning: Bool

    var body: some View {
        Group {
            if turning {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6) / 2.6
                    let lead = tint ?? Theme.accent
                    shape.strokeBorder(AngularGradient(colors: [lead, Theme.lilac, Theme.violet, Theme.mint, lead],
                                                       center: .center,
                                                       angle: .degrees(turn * 360)),
                                       lineWidth: 1.2)
                }
                .transition(.opacity)
            } else if let tint {
                shape.strokeBorder(LinearGradient(colors: [tint.opacity(lit ? 0.9 : 0.55),
                                                           Theme.lilac.opacity(lit ? 0.5 : 0.18),
                                                           tint.opacity(lit ? 0.7 : 0.32)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing),
                                   lineWidth: 0.85)
            } else {
                shape.strokeBorder(Theme.ink.opacity(lit ? 0.3 : (Theme.isLight ? 0.18 : 0.16)), lineWidth: 0.75)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Pressed, the bubble gives a little.
private struct BubblePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Lays bubbles out as words on a line: as many to a row as fit, the rest
/// on the next. One too long for a row has a row of its own and wraps.
struct BubbleFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width)
        let height = rows.last.map { $0.top + $0.height } ?? 0
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width.map { min($0, widest) } ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for item in row.items {
                // Each bubble sits in the middle of its row's height.
                let top = bounds.minY + row.top + (row.height - item.size.height) / 2
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: top),
                                           anchor: .topLeading,
                                           proposal: ProposedViewSize(item.size))
            }
        }
    }

    private struct Item {
        let index: Int
        let x: CGFloat
        let size: CGSize
    }

    private struct Row {
        var top: CGFloat
        var width: CGFloat = 0
        var height: CGFloat = 0
        var items: [Item] = []
    }

    private func arrange(_ subviews: Subviews, width: CGFloat?) -> [Row] {
        let limit = width ?? .infinity
        var rows: [Row] = []
        var row = Row(top: 0)
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            size.width = min(size.width, limit)
            if !row.items.isEmpty, row.width + spacing + size.width > limit {
                rows.append(row)
                row = Row(top: row.top + row.height + lineSpacing)
            }
            let x = row.items.isEmpty ? 0 : row.width + spacing
            row.items.append(Item(index: index, x: x, size: size))
            row.width = x + size.width
            row.height = max(row.height, size.height)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
