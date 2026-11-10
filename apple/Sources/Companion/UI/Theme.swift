import SwiftUI
import AppKit

// MARK: - Tokens

enum Theme {
    /// Placeholder app icon symbol. Swap this one constant when the final icon is decided.
    static let iconSymbol = "sparkles"

    // Palette: a light, soft set with purple as the primary. Every color is
    // pale enough to read as a tint on dark glass, never as a block of color.

    /// Primary: light purple. Replies, the main button, anything "yours".
    static let accent = Color(red: 0.73, green: 0.63, blue: 1.0)
    /// The primary's partner in gradients: a pink lilac.
    static let lilac = Color(red: 0.93, green: 0.70, blue: 1.0)
    /// Secondary: periwinkle blue. Screen answers and the mode chip, so
    /// they stay distinct from replies.
    static let violet = Color(red: 0.60, green: 0.76, blue: 1.0)
    static let mint = Color(red: 0.62, green: 0.93, blue: 0.82)
    static let amber = Color(red: 1.0, green: 0.85, blue: 0.60)
    static let rose = Color(red: 1.0, green: 0.70, blue: 0.82)

    // Shape and spacing. No surface casts a drop shadow: depth comes from
    // fills and hairline borders only.
    static let panelRadius: CGFloat = 28
    static let cardRadius: CGFloat = 20
    static let bubbleRadius: CGFloat = 16
    /// Space between the panel's edge and its content.
    static let gutter: CGFloat = 18

    static let accentGradient = LinearGradient(colors: [accent, lilac],
                                               startPoint: .topLeading,
                                               endPoint: .bottomTrailing)

    private static let speakerPalette: [Color] = [mint, amber, rose, violet]

    /// You = accent, system audio "Them" = mint, mic speakers P1, P2, ... get
    /// their own stable color.
    static func speakerColor(isMe: Bool, tag: String?) -> Color {
        if isMe { return accent }
        guard let tag, let number = Int(tag.dropFirst()), number > 0 else { return mint }
        return speakerPalette[(number - 1) % speakerPalette.count]
    }
}

// MARK: - Surfaces

/// Real behind-window glass blur (NSVisualEffectView), the base of every surface.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Layered glass edge: a gradient hairline plus a faint inner highlight.
/// Pass a tint to make the edge glow in that color (used for active cards).
struct GlassBorder: ViewModifier {
    var radius: CGFloat
    var tint: Color?

    func body(content: Content) -> some View {
        let colors: [Color] = tint.map { [$0.opacity(0.80), $0.opacity(0.16), $0.opacity(0.48)] }
            ?? [.white.opacity(0.42), .white.opacity(0.05), .white.opacity(0.18)]
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
                    .strokeBorder(.white.opacity(0.045), lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
    }
}

extension View {
    func glassBorder(radius: CGFloat, tint: Color? = nil) -> some View {
        modifier(GlassBorder(radius: radius, tint: tint))
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

    init(_ text: String, icon: String? = nil, tint: Color? = nil) {
        self.text = text
        self.icon = icon
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(tint ?? Color.white.opacity(0.78))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill((tint ?? .white).opacity(tint == nil ? 0.07 : 0.14)))
        .overlay(Capsule().strokeBorder((tint ?? .white).opacity(tint == nil ? 0.14 : 0.30), lineWidth: 0.75))
        .fixedSize()
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
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
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
                    .strokeBorder(.white.opacity(0.28), lineWidth: 0.5)
            )
    }
}

/// Who is speaking, as a fixed-width colored pill so transcript text aligns.
struct SpeakerBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: 38)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(color.opacity(0.30), lineWidth: 0.5))
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
                .foregroundStyle(tint ?? Color.white.opacity(hover ? 1 : 0.68))
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill((tint ?? .white).opacity(hover ? 0.16 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Groups icon buttons into one pill-shaped control.
struct ToolbarGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 1) { content }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

struct StatusDot: View {
    var active: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(active ? Theme.mint : Color.white.opacity(0.3))
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

/// Light sweep across the suggestion card while the model is generating.
struct ShimmerOverlay: View {
    var active: Bool
    @State private var phase: CGFloat = -0.7

    var body: some View {
        GeometryReader { geo in
            if active {
                LinearGradient(colors: [.clear, .white.opacity(0.10), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: phase * geo.size.width)
                    .onAppear {
                        phase = -0.7
                        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                            phase = 1.1
                        }
                    }
            }
        }
        .allowsHitTesting(false)
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
