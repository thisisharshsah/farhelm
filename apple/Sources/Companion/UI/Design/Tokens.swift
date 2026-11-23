import SwiftUI

// Companion's design tokens: the spacing, corners, type, colors, control and
// icon sizes and motion every screen takes its look from. Plain SwiftUI with
// nothing from AppKit, written as an extension of the shared package's
// `Design`, so this file can move into apple/Shared/CompanionDesign unchanged
// when the iPhone, iPad and Watch apps want it. The rules for using them are
// in apple/Design/README.md.

extension Design {
    /// One named step of a scale, for the gallery.
    struct Measure: Hashable {
        let name: String
        let value: CGFloat
    }

    // MARK: Spacing

    /// The spacing scale. Every gap, margin and padding is one of these.
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32

        static let all: [Measure] = [
            Measure(name: "xxs", value: xxs), Measure(name: "xs", value: xs), Measure(name: "s", value: s),
            Measure(name: "m", value: m), Measure(name: "l", value: l), Measure(name: "xl", value: xl),
            Measure(name: "xxl", value: xxl),
        ]
    }

    // MARK: Corners

    /// The corner scale, smallest to largest, always drawn with the
    /// continuous curve. A shape set inside another takes
    /// `concentric(_:inset:)`, so the two curves stay parallel.
    enum Radius {
        static let chip: CGFloat = Design.chipRadius
        static let control: CGFloat = Design.controlRadius
        static let tile: CGFloat = Design.tileRadius
        static let card: CGFloat = Design.cardRadius
        /// A floating panel or another surface the size of a window.
        static let panel: CGFloat = 20

        static let all: [Measure] = [
            Measure(name: "chip", value: chip), Measure(name: "control", value: control),
            Measure(name: "tile", value: tile), Measure(name: "card", value: card),
            Measure(name: "panel", value: panel),
        ]

        /// The corner of a shape set `inset` points inside one whose corner is `outer`.
        static func concentric(_ outer: CGFloat, inset: CGFloat) -> CGFloat {
            max(outer - inset, 0)
        }

        static func shape(_ radius: CGFloat) -> RoundedRectangle {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
        }
    }

    // MARK: Type

    /// What a piece of text is, mapped onto the system's text styles so it
    /// follows the platform's sizes. Numbers use monospaced digits, so
    /// columns of them line up.
    enum TextRole: String, CaseIterable {
        case largeTitle = "Large title"
        case title = "Title"
        case heading = "Heading"
        case body = "Body"
        case label = "Label"
        case caption = "Caption"
        case code = "Code"
        case number = "Number"

        var font: Font {
            switch self {
            case .largeTitle: .largeTitle
            case .title: .title2
            case .heading: .headline
            case .body: .body
            case .label: .callout
            case .caption: .caption
            case .code: .body.monospaced()
            case .number: .body.monospacedDigit()
            }
        }

        var sample: String {
            switch self {
            case .largeTitle: "Companion"
            case .title: "Design system"
            case .heading: "Section heading"
            case .body: "Body text reads at the system size."
            case .label: "Label beside a control"
            case .caption: "Caption under a value"
            case .code: "let gap = Design.Space.m"
            case .number: "1,204.50"
            }
        }
    }

    /// How prominent text is. Hierarchical styles, so text stays legible on
    /// glass and on any background; Increase Contrast moves each level up.
    enum TextLevel: String, CaseIterable {
        case primary = "Primary"
        case secondary = "Secondary"
        case tertiary = "Tertiary"
    }

    // MARK: Color

    /// Colors by what they mean, never by value. Status colors are the
    /// system's own, which adapt to light, dark and Increase Contrast; the
    /// accent is the look's main color (Settings > Look).
    enum Tone: String, CaseIterable {
        case accent = "Accent"
        case neutral = "Neutral"
        case positive = "Positive"
        case caution = "Caution"
        case critical = "Critical"
        case info = "Info"

        var color: Color {
            switch self {
            case .accent: Design.palette().accent
            case .neutral: .secondary
            case .positive: .green
            case .caution: .orange
            case .critical: .red
            case .info: .blue
            }
        }
    }

    /// Fills for the content layer: what messages, code and documents sit on.
    enum Fill: String, CaseIterable {
        case content = "Content"
        case raised = "Raised"
        case line = "Line"

        var style: AnyShapeStyle {
            switch self {
            case .content: AnyShapeStyle(.background)
            case .raised: AnyShapeStyle(.background.secondary)
            case .line: AnyShapeStyle(.quaternary)
            }
        }
    }

    // MARK: Controls and icons

    /// The three control sizes. `system` is the matching SwiftUI size for
    /// native controls; the rest is for components drawn here.
    enum Control: String, CaseIterable {
        case small = "Small"
        case regular = "Regular"
        case large = "Large"

        var height: CGFloat {
            switch self {
            case .small: 22
            case .regular: 28
            case .large: 36
            }
        }

        var padding: CGFloat {
            switch self {
            case .small: Space.xs
            case .regular: Space.s
            case .large: Space.m
            }
        }

        var icon: Icon {
            switch self {
            case .small: .small
            case .regular: .regular
            case .large: .large
            }
        }

        var textRole: TextRole {
            switch self {
            case .small: .caption
            case .regular: .label
            case .large: .body
            }
        }

        var system: ControlSize {
            switch self {
            case .small: .small
            case .regular: .regular
            case .large: .large
            }
        }
    }

    /// Icon sizes with a fixed width, so labels after icons of different
    /// shapes start at the same place.
    enum Icon: String, CaseIterable {
        case small = "Small"
        case regular = "Regular"
        case large = "Large"

        var width: CGFloat {
            switch self {
            case .small: 14
            case .regular: 18
            case .large: 24
            }
        }

        var font: Font {
            switch self {
            case .small: .caption
            case .regular: .body
            case .large: .title3
            }
        }
    }

    // MARK: Motion

    /// Springs for things that move. Under Reduce Motion every one of them
    /// becomes `reduced`, a short fade with nothing travelling.
    enum Motion: String, CaseIterable {
        /// A press, a toggle, a hover.
        case quick = "Quick"
        /// Something appearing, moving or changing size.
        case standard = "Standard"
        /// A large surface settling, such as a panel opening.
        case gentle = "Gentle"
        /// One glass shape turning into another.
        case morph = "Morph"

        var animation: Animation {
            switch self {
            case .quick: .spring(duration: 0.2, bounce: 0)
            case .standard: .spring(duration: 0.35, bounce: 0.1)
            case .gentle: .spring(duration: 0.5, bounce: 0.15)
            case .morph: .spring(duration: 0.45, bounce: 0.25)
            }
        }

        static let reduced: Animation = .easeInOut(duration: 0.2)

        func animation(reduceMotion: Bool) -> Animation {
            reduceMotion ? Self.reduced : animation
        }
    }
}

// MARK: - Accessibility

/// Accessibility settings forced on to preview them (the Design Gallery
/// does). The system's own settings always apply as well.
struct DesignAccessibility: Equatable {
    var reduceTransparency = false
    var increaseContrast = false
    var reduceMotion = false
}

private struct DesignPreviewKey: EnvironmentKey {
    static let defaultValue = DesignAccessibility()
}

extension EnvironmentValues {
    var designPreview: DesignAccessibility {
        get { self[DesignPreviewKey.self] }
        set { self[DesignPreviewKey.self] = newValue }
    }
}

/// The accessibility settings in effect for one view: the system's, or a
/// preview forced on above it. Every design component reads them here.
struct DesignAccess: DynamicProperty {
    @Environment(\.accessibilityReduceTransparency) var systemReduceTransparency
    @Environment(\.colorSchemeContrast) var systemContrast
    @Environment(\.accessibilityReduceMotion) var systemReduceMotion
    @Environment(\.designPreview) var preview

    init() {}

    /// Glass becomes a solid surface.
    var solid: Bool { systemReduceTransparency || preview.reduceTransparency }
    /// Edges get stronger and text moves up a level.
    var highContrast: Bool { systemContrast == .increased || preview.increaseContrast }
    /// Motion becomes a fade.
    var reduceMotion: Bool { systemReduceMotion || preview.reduceMotion }
}

// MARK: - Modifiers

struct TextRoleModifier: ViewModifier {
    let role: Design.TextRole
    let level: Design.TextLevel
    var access = DesignAccess()

    func body(content: Content) -> some View {
        content.font(role.font).foregroundStyle(style)
    }

    var style: HierarchicalShapeStyle {
        switch level {
        case .primary: .primary
        case .secondary: access.highContrast ? .primary : .secondary
        case .tertiary: access.highContrast ? .secondary : .tertiary
        }
    }
}

struct DesignAnimation<Value: Equatable>: ViewModifier {
    let motion: Design.Motion
    let value: Value
    var access = DesignAccess()

    func body(content: Content) -> some View {
        content.animation(motion.animation(reduceMotion: access.reduceMotion), value: value)
    }
}

extension View {
    /// Text in a role of the type scale, at a level of prominence.
    func textRole(_ role: Design.TextRole, _ level: Design.TextLevel = .primary) -> some View {
        modifier(TextRoleModifier(role: role, level: level))
    }

    /// A symbol at an icon size, in a frame of that size's fixed width.
    func iconWidth(_ icon: Design.Icon = .regular) -> some View {
        font(icon.font).frame(width: icon.width)
    }

    /// Animates changes of `value` with a motion token, or fades them under Reduce Motion.
    func designAnimation<V: Equatable>(_ motion: Design.Motion, value: V) -> some View {
        modifier(DesignAnimation(motion: motion, value: value))
    }
}