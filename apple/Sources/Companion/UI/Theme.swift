import SwiftUI
import AppKit

// MARK: - Tokens

enum Theme {
    /// Placeholder app icon symbol. Swap this one constant when the final icon is decided.
    static let iconSymbol = "sparkles"

    // Appearance. Two themes share one set of names: every color below
    // resolves for the theme in effect, so views never branch on it.

    /// Whether the light theme is in effect ("appearance" in Settings:
    /// dark, light, or follow the system).
    static var isLight: Bool {
        switch UserDefaults.standard.string(forKey: "appearance") ?? "dark" {
        case "light": return true
        case "system": return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") != "Dark"
        default: return false
        }
    }

    /// Text and line color: white on the dark glass, near-black on the light.
    static var ink: Color { isLight ? Color(red: 0.11, green: 0.10, blue: 0.17) : .white }
    /// What surfaces are deepened with: black on dark glass, white on light.
    static var shade: Color { isLight ? .white : .black }

    // Palette: purple is the primary. On dark glass every color is a pale
    // tint; on light glass the same hues are deepened so they stay readable.

    /// Primary: purple. Replies, the main button, anything "yours".
    /// The usual look keeps its hand-tuned purple; any other choice is the
    /// user's color, fitted to the glass so it stays readable.
    static var accent: Color {
        if look.preset != Look.usual.preset { return Hex.fitted(look.primary, light: isLight) }
        return isLight ? Color(red: 0.44, green: 0.31, blue: 0.87) : Color(red: 0.73, green: 0.63, blue: 1.0)
    }
    /// The primary's partner in gradients: a pink lilac.
    static var lilac: Color {
        if look.preset != Look.usual.preset { return Hex.fitted(look.secondary, light: isLight) }
        return isLight ? Color(red: 0.70, green: 0.36, blue: 0.88) : Color(red: 0.93, green: 0.70, blue: 1.0)
    }
    /// Secondary: periwinkle blue. Screen answers and the mode chip, so
    /// they stay distinct from replies.
    static var violet: Color {
        isLight ? Color(red: 0.20, green: 0.42, blue: 0.86) : Color(red: 0.60, green: 0.76, blue: 1.0)
    }
    static var mint: Color {
        isLight ? Color(red: 0.04, green: 0.55, blue: 0.40) : Color(red: 0.62, green: 0.93, blue: 0.82)
    }
    static var amber: Color {
        isLight ? Color(red: 0.72, green: 0.44, blue: 0.02) : Color(red: 1.0, green: 0.85, blue: 0.60)
    }
    static var rose: Color {
        isLight ? Color(red: 0.82, green: 0.20, blue: 0.44) : Color(red: 1.0, green: 0.70, blue: 0.82)
    }

    // Shape and spacing. Nothing casts a drop shadow, the panel included:
    // depth comes from the glass and its hairline edge.
    static let panelRadius: CGFloat = 20
    static let cardRadius: CGFloat = 14
    static let bubbleRadius: CGFloat = 9
    /// Space between the panel's edge and its content.
    static let gutter: CGFloat = 14

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, lilac], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Colors for the other speakers. Any that sit close to the look's main
    /// color are left out, so "you" and "them" can always be told apart:
    /// with a green look, nobody else is green.
    private static var speakerPalette: [Color] {
        let all: [(color: Color, hue: Double)] = [(mint, 160), (amber, 38), (rose, 336), (violet, 216)]
        guard look.preset != Look.usual.preset, let mine = Hex.hue(look.primary) else {
            return all.map(\.color)
        }
        let apart = all.filter { entry in
            let gap = abs(entry.hue - mine).truncatingRemainder(dividingBy: 360)
            return min(gap, 360 - gap) >= 60
        }
        return (apart.count >= 2 ? apart : all).map(\.color)
    }

    /// You = accent, system audio "Them" = the first of the other colors,
    /// mic speakers P1, P2, ... each get their own stable color.
    static func speakerColor(isMe: Bool, tag: String?) -> Color {
        if isMe { return accent }
        let palette = speakerPalette
        guard let tag, let number = Int(tag.dropFirst()), number > 0 else { return palette[0] }
        return palette[(number - 1) % palette.count]
    }
}

// MARK: - Surfaces

/// Real behind-window glass blur (NSVisualEffectView), the base of every surface.
struct VisualEffectView: NSViewRepresentable {
    /// Light glass or dark glass.
    var light = false
    /// How much of the blur shows, 0 to 1.
    var strength: Double = 1

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: NSVisualEffectView) {
        view.material = light ? .popover : .hudWindow
        view.appearance = NSAppearance(named: light ? .vibrantLight : .vibrantDark)
        view.alphaValue = strength
    }
}

/// A quick side-to-side shake, for something that just failed. Animate
/// `animatableData` from one whole number to the next to play it once.
struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 7
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * 4), y: 0))
    }
}

/// A dot that breathes, for "live right now".
struct PulsingDot: View {
    var color: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: 14, height: 14)
                .scaleEffect(pulse ? 1 : 0.45)
                .opacity(pulse ? 0 : 0.9)
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

/// Layered glass edge: a gradient hairline plus a faint inner highlight.
/// Pass a tint to make the edge glow in that color (used for active cards).
struct GlassBorder: ViewModifier {
    var radius: CGFloat
    var tint: Color?

    func body(content: Content) -> some View {
        let colors: [Color] = tint.map { [$0.opacity(0.80), $0.opacity(0.16), $0.opacity(0.48)] }
            // On light glass an edge that fades to almost nothing loses the
            // card altogether, so it is kept even all the way round.
            ?? (Theme.isLight
                ? [Theme.ink.opacity(0.20), Theme.ink.opacity(0.11), Theme.ink.opacity(0.16)]
                : [Theme.ink.opacity(0.42), Theme.ink.opacity(0.05), Theme.ink.opacity(0.18)])
        return content
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: colors,
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing),
                                  lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: max(radius - 1.5, 0), style: .continuous)
                    .inset(by: 1.5)
                    .strokeBorder(Theme.ink.opacity(0.045), lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
    }
}

extension View {
    func glassBorder(radius: CGFloat, tint: Color? = nil) -> some View {
        modifier(GlassBorder(radius: radius, tint: tint))
    }
}

// MARK: - Content zoom

/// Draws a view larger or smaller while it keeps filling the same space:
/// the view is laid out in a space that is smaller (or larger) by the zoom,
/// then scaled up (or down) to fit. Text, spacing and pictures all scale
/// together and stay sharp, and text still wraps at the edge.
struct ContentZoom: ViewModifier {
    let zoom: CGFloat

    func body(content: Content) -> some View {
        // The same structure at every zoom, 100% included, so changing the
        // zoom never rebuilds the view and loses its place.
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width / zoom, height: geometry.size.height / zoom)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }
}

extension View {
    func contentZoom(_ zoom: Double) -> some View {
        modifier(ContentZoom(zoom: CGFloat(zoom)))
    }
}

// MARK: - Liquid Glass

/// Apple's Liquid Glass (the iOS 26 / macOS 26 system material) for the
/// navigation and control layer: toolbars, tab bars, the chip row, the chat
/// box. Content (the conversation, cards of settings) stays on plain
/// surfaces, as the system's own apps do. On macOS 14 and 15, where the
/// material does not exist, the same shapes fall back to the tinted
/// hairline surface used before.
@available(macOS 26.0, *)
private func liquidGlassStyle(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint {
        glass = glass.tint(tint.opacity(0.32))
    }
    if interactive {
        glass = glass.interactive()
    }
    return glass
}

extension View {
    /// Puts the view on Liquid Glass of the given shape. `interactive`
    /// makes the glass respond to presses, for buttons.
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(liquidGlassStyle(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background(shape.fill((tint ?? Theme.ink).opacity(tint == nil ? 0.07 : 0.14)))
                .overlay(shape.stroke((tint ?? Theme.ink).opacity(tint == nil ? 0.16 : 0.30), lineWidth: 0.75))
        }
    }
}

/// Groups neighbouring glass shapes so they blend and morph into one
/// another, as the system's own bars do.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

private struct GlassChipsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Chips inside a control bar sit on glass; chips used as status labels
    /// inside content do not.
    var glassChips: Bool {
        get { self[GlassChipsKey.self] }
        set { self[GlassChipsKey.self] = newValue }
    }
}

/// Invisible AppKit view that drags its window when pressed. Used as the
/// background of areas that should move the panel; controls above it still
/// receive their clicks.
struct DragHandle: NSViewRepresentable {
    final class HandleView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView { HandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Components

/// Small status pill. Neutral by default, or tinted to carry meaning.
struct Chip: View {
    var icon: String?
    let text: String
    var tint: Color?
    @Environment(\.glassChips) private var onGlass

    init(_ text: String, icon: String? = nil, tint: Color? = nil) {
        self.text = text
        self.icon = icon
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: text.isEmpty ? 10 : 9, weight: .semibold))
            }
            // An icon that says enough on its own carries no label.
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(tint ?? Theme.ink.opacity(0.78))
        .padding(.horizontal, text.isEmpty ? 9 : 10)
        .padding(.vertical, 5)
        .modifier(ChipSurface(tint: tint, glass: onGlass))
        .fixedSize()
    }
}

private struct ChipSurface: ViewModifier {
    var tint: Color?
    var glass: Bool

    func body(content: Content) -> some View {
        if glass {
            content.liquidGlass(in: Capsule(), tint: tint, interactive: true)
        } else {
            content
                .background(Capsule().fill((tint ?? Theme.ink).opacity(tint == nil ? 0.07 : 0.14)))
                .overlay(Capsule().strokeBorder((tint ?? Theme.ink).opacity(tint == nil ? 0.14 : 0.30), lineWidth: 0.75))
        }
    }
}

/// Keyboard shortcut hint: a keycap plus what it does.
struct KeyCap: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.ink.opacity(0.72))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(Theme.ink.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(Theme.ink.opacity(0.16), lineWidth: 0.5))
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.42))
        }
        .fixedSize()
    }
}

/// Rounded gradient tile holding a symbol; anchors headers and card titles.
struct IconTile: View {
    let symbol: String
    var tint: Color = Theme.accent
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.50, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.45)],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .strokeBorder(Theme.ink.opacity(0.28), lineWidth: 0.5)
            )
    }
}

/// Who is speaking, as a fixed-width colored pill so transcript text aligns.
struct SpeakerBadge: View {
    let label: String
    let color: Color

    var body: some View {
        // Just the name, in the speaker's color: the words are what matter.
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .frame(width: 36, alignment: .leading)
    }
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    var tint: Color?
    let action: () -> Void
    @State private var hover = false

    init(_ symbol: String, help: String = "", tint: Color? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint ?? Theme.ink.opacity(hover ? 1 : 0.68))
                // A circle, the same shape as the rounded ends of the group
                // it sits in, so the highlight under the pointer fits its
                // container instead of showing a square inside an oval.
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill((tint ?? Theme.ink).opacity(hover ? 0.18 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(help)
    }
}

/// Groups icon buttons into one pill-shaped control.
struct ToolbarGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        // The same margin on every side, so an icon's round highlight sits
        // evenly inside the group, and a group of one is a true circle.
        HStack(spacing: 1) { content }
            .padding(2)
            .liquidGlass(in: Capsule())
    }
}

struct StatusDot: View {
    var active: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(active ? Theme.mint : Theme.ink.opacity(0.3))
            .frame(width: 6, height: 6)
            .opacity(active && pulse ? 0.45 : 1)
            .animation(active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = true }
    }
}

/// Tiny audio level meter, reacts to live mic/system RMS.
struct LevelBars: View {
    var level: Float
    var color: Color = Theme.accent
    private let shape: [Float] = [0.4, 0.8, 1.0, 0.7, 0.5]

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(color.opacity(0.9))
                    .frame(width: 2, height: CGFloat(3 + 8 * min(1, level * 1.6 * shape[i])))
            }
        }
        .frame(height: 11)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

struct PulseRing: View {
    var color: Color = Theme.accent
    @State private var animate = false

    var body: some View {
        Circle()
            .stroke(color.opacity(0.6), lineWidth: 2)
            .frame(width: 52, height: 52)
            .scaleEffect(animate ? 1.35 : 1.0)
            .opacity(animate ? 0 : 0.8)
            .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: animate)
            .onAppear { animate = true }
    }
}
