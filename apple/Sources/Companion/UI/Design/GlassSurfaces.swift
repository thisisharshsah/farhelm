import SwiftUI

// Glass for the navigation and control layer: floating panels, toolbar
// groups, section headers and buttons. On macOS 26 and later these are
// Apple's Liquid Glass (glassEffect, GlassEffectContainer, glassEffectID,
// the glass button styles); before that, the system's materials. Under
// Reduce Transparency every surface turns solid, under Increase Contrast it
// gets a firm edge, and under Reduce Motion morphs become fades. Glass is
// never put behind messages, code or documents, and never on other glass:
// a surface set inside one draws flat (`insideGlass`).

extension Design {
    enum ButtonEmphasis: String, CaseIterable {
        /// A secondary action on glass.
        case glass = "Glass"
        /// The one main action, filled with the accent.
        case prominent = "Prominent"
    }
}

private struct InsideGlassKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a glass surface, where another glass surface draws flat.
    var insideGlass: Bool {
        get { self[InsideGlassKey.self] }
        set { self[InsideGlassKey.self] = newValue }
    }
}

// MARK: - Surface

struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color?
    var interactive: Bool
    /// The material used before macOS 26.
    var fallback: Material
    var access = DesignAccess()
    @Environment(\.insideGlass) var insideGlass

    func body(content: Content) -> some View {
        surface(content).environment(\.insideGlass, true)
    }

    @ViewBuilder
    func surface(_ content: Content) -> some View {
        if insideGlass {
            content
        } else if access.solid {
            content
                .background(shape.fill(.background))
                .overlay(edge)
        } else {
            glass(content)
                .overlay {
                    if access.highContrast { edge }
                }
        }
    }

    @ViewBuilder
    func glass(_ content: Content) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            content.glassEffect(style, in: shape)
        } else {
            content
                .background(fallback, in: shape)
                .overlay(edge)
        }
    }

    @available(macOS 26.0, iOS 26.0, *)
    var style: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint.opacity(0.3)) }
        if interactive { glass = glass.interactive() }
        return glass
    }

    var edge: some View {
        shape
            .strokeBorder(Color.primary.opacity(access.highContrast ? 0.6 : 0.15),
                          lineWidth: access.highContrast ? 1 : 0.5)
            .allowsHitTesting(false)
    }
}

// MARK: - Buttons

struct GlassButton: ViewModifier {
    let emphasis: Design.ButtonEmphasis
    let size: Design.Control
    var access = DesignAccess()
    @Environment(\.insideGlass) var insideGlass

    func body(content: Content) -> some View {
        styled(content)
            .controlSize(size.system)
            .tint(emphasis == .prominent ? Design.Tone.accent.color : nil)
    }

    @ViewBuilder
    func styled(_ content: Content) -> some View {
        // On glass already, or with Reduce Transparency: the solid styles.
        if insideGlass || access.solid {
            bordered(content)
        } else {
            glassOrBordered(content)
        }
    }

    @ViewBuilder
    func glassOrBordered(_ content: Content) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            switch emphasis {
            case .glass: content.buttonStyle(.glass)
            case .prominent: content.buttonStyle(.glassProminent)
            }
        } else {
            bordered(content)
        }
    }

    @ViewBuilder
    func bordered(_ content: Content) -> some View {
        switch emphasis {
        case .glass: content.buttonStyle(.bordered)
        case .prominent: content.buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Morph

struct GlassMorph: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    var access = DesignAccess()

    @ViewBuilder
    func body(content: Content) -> some View {
        if access.reduceMotion {
            content.transition(.opacity)
        } else if access.solid {
            content.matchedGeometryEffect(id: id, in: namespace)
        } else {
            morph(content)
        }
    }

    @ViewBuilder
    func morph(_ content: Content) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            content.glassEffectID(id, in: namespace)
        } else {
            content.matchedGeometryEffect(id: id, in: namespace)
        }
    }
}

// MARK: - Section header

/// A header that stays over scrolling content, on glass.
struct GlassSectionHeader: View {
    let title: String
    var symbol: String?
    @Environment(\.density) var density

    init(_ title: String, symbol: String? = nil) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: Design.Space.xs) {
            if let symbol {
                Image(systemName: symbol)
                    .iconWidth(density.icon)
                    .foregroundStyle(.secondary)
            }
            Text(title).textRole(.heading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, density.inset)
        .frame(minHeight: density.control.height)
        .glassSurface(Design.Radius.shape(Design.Radius.control), fallback: .bar)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Modifiers

extension View {
    /// Glass of any shape. Prefer the named surfaces below.
    func glassSurface<S: InsettableShape>(_ shape: S, tint: Color? = nil, interactive: Bool = false,
                                          fallback: Material = .regularMaterial) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive, fallback: fallback))
    }

    /// A floating panel.
    func glassPanel(radius: CGFloat = Design.Radius.panel) -> some View {
        glassSurface(Design.Radius.shape(radius), fallback: .regularMaterial)
    }

    /// Icon buttons grouped into one capsule, as in a toolbar.
    func glassToolbarGroup() -> some View {
        padding(Design.Space.xxs)
            .glassSurface(Capsule(), fallback: .bar)
    }

    /// A button on glass: `.glass` for most, `.prominent` for the main action.
    func glassButton(_ emphasis: Design.ButtonEmphasis = .glass, size: Design.Control = .regular) -> some View {
        modifier(GlassButton(emphasis: emphasis, size: size))
    }

    /// Lets one glass shape morph into another with the same id inside a
    /// `GlassGroup`. Under Reduce Motion the two fade instead.
    func glassMorph(_ id: String, in namespace: Namespace.ID) -> some View {
        modifier(GlassMorph(id: id, namespace: namespace))
    }
}