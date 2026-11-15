import SwiftUI

/// What a panel is made of.
public enum PanelSurface: Sendable {
    /// Glass: the conversation, the list of chats, details, the browser's
    /// frame. The desktop's blur shows through, a shade lighter than the
    /// gaps around it.
    case glass
    /// Nearly solid, for code, files and the terminal: no one can read
    /// code over the desktop.
    case work
}

extension Design {
    /// The gap between two panels, and between a panel and the window's
    /// edge. The gaps between panels are also what resizes them.
    public static let panelGap: CGFloat = 6
    /// The corner of something set into a panel by one gap, so its corner
    /// follows the panel's own.
    public static let innerRadius: CGFloat = cardRadius - panelGap
}

extension Palette {
    /// A glass panel: a faint lightening on dark glass; on light glass a
    /// little whiter than around it, as paper on a desk.
    /// Follows the content surfaces' transparency.
    public var panelGlass: Color {
        isLight ? Color.white.opacity(0.08 + 0.40 * contentDim) : Color.white.opacity(0.0055 * contentDim / 0.1)
    }

    /// What code and files sit on: the panel glass, deepened by the empty
    /// surfaces' transparency. At the usual setting it is the frosted base
    /// code has always had; turned fully see-through it is the same glass as
    /// every other panel, over the window's own base, which keeps text readable.
    public var workSurface: Color {
        let solid = min(1, max(0, emptyDim / 0.55))
        return isLight
            ? Color.white.opacity(0.08 + 0.40 * contentDim + (0.80 - 0.08 - 0.40 * contentDim) * solid * 0.9)
            : Color(red: 0.07, green: 0.07, blue: 0.09).opacity(0.78 * solid)
    }
}

/// A panel of its own, as every part of the window is: rounded, on its
/// surface, with the glass edge, light caught in its top corner and a sheen
/// along its top, the way light sits on water. What it holds stays inside
/// its corners.
public struct PanelCard: ViewModifier {
    var surface: PanelSurface
    var radius: CGFloat
    var tint: Color?

    public init(surface: PanelSurface = .glass, radius: CGFloat = Design.cardRadius, tint: Color? = nil) {
        self.surface = surface
        self.radius = radius
        self.tint = tint
    }

    public func body(content: Content) -> some View {
        let palette = Design.palette()
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background {
                ZStack {
                    switch surface {
                    case .glass:
                        palette.panelGlass
                        RadialGradient(colors: [palette.accent.opacity(palette.isLight ? 0.05 : 0.07), .clear],
                                       center: .topLeading, startRadius: 0, endRadius: 240)
                    case .work:
                        palette.workSurface
                        palette.accent.opacity(0.03)
                    }
                    LinearGradient(colors: [Color.white.opacity(palette.isLight ? 0.5 : 0.045), .clear],
                                   startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.12))
                }
                .allowsHitTesting(false)
            }
            // Every panel is glass of its own, under its tint and sheen.
            .liquidGlass(in: shape)
            .clipShape(shape)
            .glassBorder(radius: radius, tint: tint)
    }
}

extension View {
    /// Makes the view a panel of its own (see `PanelCard`).
    public func panelCard(_ surface: PanelSurface = .glass, radius: CGFloat = Design.cardRadius,
                          tint: Color? = nil) -> some View {
        modifier(PanelCard(surface: surface, radius: radius, tint: tint))
    }
}

/// The grip in the gap between two panels: three dots across its middle,
/// faint until the pointer finds them, the way a handle shows where to take
/// hold. Under the pointer they spread a little and sit in a soft pill of
/// the primary; while dragged, the whole edge glows along its length,
/// brightest at the grip and fading toward its ends.
public struct DividerGrip: View {
    /// The way the gap runs: `.vertical` between two columns, `.horizontal`
    /// between a panel and the one under it.
    var axis: Axis
    var hover: Bool
    var dragging: Bool

    public init(axis: Axis, hover: Bool = false, dragging: Bool = false) {
        self.axis = axis
        self.hover = hover
        self.dragging = dragging
    }

    private var lit: Bool { hover || dragging }

    public var body: some View {
        let palette = Design.palette()
        let along = axis == .vertical
        return ZStack {
            if dragging {
                LinearGradient(colors: [.clear, palette.accent.opacity(0.55), .clear],
                               startPoint: along ? .top : .leading,
                               endPoint: along ? .bottom : .trailing)
                    .frame(width: along ? 2 : nil, height: along ? nil : 2)
                    .clipShape(Capsule())
                    .transition(.opacity)
            }
            Capsule()
                .fill(palette.accent.opacity(dragging ? 0.22 : (hover ? 0.14 : 0)))
                .frame(width: along ? 6 : 34, height: along ? 34 : 6)
            dots(palette, along: along)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: hover)
        .animation(.easeOut(duration: 0.16), value: dragging)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func dots(_ palette: Palette, along: Bool) -> some View {
        let spacing: CGFloat = lit ? 3.5 : 2.5
        let dot = Circle()
            .fill(lit ? palette.accent : palette.ink.opacity(palette.isLight ? 0.32 : 0.28))
            .frame(width: 3, height: 3)
        if along {
            VStack(spacing: spacing) { dot; dot; dot }
        } else {
            HStack(spacing: spacing) { dot; dot; dot }
        }
    }
}
