import SwiftUI

/// The colors of the look in effect. The Mac app fills it from its Look
/// (the user's own colors, light or dark); the mobile apps use Companion's
/// own. Every shared view takes its colors from here.
public struct Palette: Sendable {
    public var isLight: Bool
    /// Text and lines.
    public var ink: Color
    /// What surfaces are deepened with.
    public var shade: Color
    /// The primary, and its partner in gradients.
    public var accent: Color
    public var lilac: Color
    public var violet: Color
    public var mint: Color
    public var amber: Color
    public var rose: Color
    /// How solid surfaces that hold content are, 0 to 1 (0.55 is the usual).
    public var contentDim: Double
    /// How solid the empty surfaces (a panel's base) are, 0 to 1 (0.55 is the usual).
    public var emptyDim: Double

    public init(isLight: Bool, ink: Color, shade: Color, accent: Color, lilac: Color,
                violet: Color, mint: Color, amber: Color, rose: Color, contentDim: Double = 0.55,
                emptyDim: Double = 0.55) {
        self.contentDim = contentDim
        self.emptyDim = emptyDim
        self.isLight = isLight
        self.ink = ink
        self.shade = shade
        self.accent = accent
        self.lilac = lilac
        self.violet = violet
        self.mint = mint
        self.amber = amber
        self.rose = rose
    }

    /// Companion's usual look on dark glass.
    public static let dark = Palette(
        isLight: false, ink: .white, shade: .black,
        accent: Color(red: 0.73, green: 0.63, blue: 1.0), lilac: Color(red: 0.93, green: 0.70, blue: 1.0),
        violet: Color(red: 0.60, green: 0.76, blue: 1.0), mint: Color(red: 0.62, green: 0.93, blue: 0.82),
        amber: Color(red: 1.0, green: 0.85, blue: 0.60), rose: Color(red: 1.0, green: 0.70, blue: 0.82))

    /// The same look on light glass, its hues deepened to stay readable.
    public static let light = Palette(
        isLight: true, ink: Color(red: 0.11, green: 0.10, blue: 0.17), shade: .white,
        accent: Color(red: 0.44, green: 0.31, blue: 0.87), lilac: Color(red: 0.70, green: 0.36, blue: 0.88),
        violet: Color(red: 0.20, green: 0.42, blue: 0.86), mint: Color(red: 0.04, green: 0.55, blue: 0.40),
        amber: Color(red: 0.72, green: 0.44, blue: 0.02), rose: Color(red: 0.82, green: 0.20, blue: 0.44))

    public var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, lilac], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Where the shared views find the look in effect, and the shapes every
/// surface shares.
public enum Design {
    /// The look in effect, asked each time a view is drawn, so a change
    /// shows at once. The Mac app sets it to its own Look at launch.
    nonisolated(unsafe) public static var palette: () -> Palette = { .dark }

    public static let cardRadius: CGFloat = 14
    public static let bubbleRadius: CGFloat = 9
    public static let gutter: CGFloat = 14
}

/// The shared views' names for the colors, as the Mac app's own views have
/// them, so the same code reads the same everywhere.
enum Theme {
    static var isLight: Bool { Design.palette().isLight }
    static var ink: Color { Design.palette().ink }
    static var shade: Color { Design.palette().shade }
    static var accent: Color { Design.palette().accent }
    static var lilac: Color { Design.palette().lilac }
    static var violet: Color { Design.palette().violet }
    static var mint: Color { Design.palette().mint }
    static var amber: Color { Design.palette().amber }
    static var rose: Color { Design.palette().rose }
    static var accentGradient: LinearGradient { Design.palette().accentGradient }
    static var bubbleRadius: CGFloat { Design.bubbleRadius }
}
