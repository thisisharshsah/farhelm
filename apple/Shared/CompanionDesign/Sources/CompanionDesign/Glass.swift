import SwiftUI

/// Layered glass edge: a gradient hairline plus a faint inner highlight.
/// Pass a tint to make the edge glow in that color (used for active cards).
public struct GlassBorder: ViewModifier {
    public init(radius: CGFloat, tint: Color? = nil) {
        self.radius = radius
        self.tint = tint
    }

    var radius: CGFloat
    var tint: Color?

    public func body(content: Content) -> some View {
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
    public func glassBorder(radius: CGFloat, tint: Color? = nil) -> some View {
        modifier(GlassBorder(radius: radius, tint: tint))
    }
}

// MARK: - Liquid Glass

/// Apple's Liquid Glass (the iOS 26 / macOS 26 system material) for the
/// navigation and control layer: toolbars, tab bars, the chip row, the chat
/// box. Content (the conversation, cards of settings) stays on plain
/// surfaces, as the system's own apps do. On macOS 14 and 15, where the
/// material does not exist, the same shapes fall back to the tinted
/// hairline surface used before.
#if !os(watchOS)
@available(macOS 26.0, iOS 26.0, *)
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
#endif

extension View {
    /// Puts the view on Liquid Glass of the given shape. `interactive`
    /// makes the glass respond to presses, for buttons.
    @ViewBuilder
    public func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if os(watchOS)
        self
            .background(shape.fill((tint ?? Theme.ink).opacity(tint == nil ? 0.07 : 0.14)))
            .overlay(shape.stroke((tint ?? Theme.ink).opacity(tint == nil ? 0.16 : 0.30), lineWidth: 0.75))
        #else
        if #available(macOS 26.0, iOS 26.0, *) {
            self.glassEffect(liquidGlassStyle(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background(shape.fill((tint ?? Theme.ink).opacity(tint == nil ? 0.07 : 0.14)))
                .overlay(shape.stroke((tint ?? Theme.ink).opacity(tint == nil ? 0.16 : 0.30), lineWidth: 0.75))
        }
        #endif
    }
}

/// Groups neighbouring glass shapes so they blend and morph into one
/// another, as the system's own bars do.
public struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    var content: Content

    public init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        #if os(watchOS)
        content
        #else
        if #available(macOS 26.0, iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #endif
    }
}

