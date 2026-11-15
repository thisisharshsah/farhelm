import AppKit
import SwiftUI

/// How solid and how blurred one part of the panel is.
struct ZoneStyle: Codable, Equatable {
    /// 0 lets the most through, 1 is nearly solid.
    var dim: Double
    /// 0 is no blur, 4 the most.
    var blur: Int
}

/// The panel's look: its two colors, and how see-through and how blurred
/// each part of it is. One value, so a look can be saved, named and put
/// back as a whole.
struct Look: Codable, Equatable {
    /// A preset's id, or "custom" for the user's own two colors.
    var preset: String
    /// The two colors as hex codes: the primary (buttons, highlights, your
    /// own lines) and the secondary (its partner in gradients and glows).
    var primary: String
    var secondary: String
    /// One setting for the whole panel, or a separate one for each part.
    var linked: Bool
    var all: ZoneStyle
    var top: ZoneStyle
    var center: ZoneStyle
    var bottom: ZoneStyle
    /// How solid the bubbles around what was said are, 0 to 1.
    var bubble: Double
    /// Surfaces that hold text or icons: headers, cards, lists, the ask bar.
    var content: ZoneStyle
    /// Surfaces with nothing on them: the panel's base behind everything.
    var empty: ZoneStyle

    static let usual = Look(preset: "violet", primary: "#BAA1FF", secondary: "#EDB3FF", linked: true,
                            all: ZoneStyle(dim: 0.55, blur: 4),
                            top: ZoneStyle(dim: 0.55, blur: 4),
                            center: ZoneStyle(dim: 0.55, blur: 4),
                            bottom: ZoneStyle(dim: 0.55, blur: 4),
                            bubble: 0.5,
                            content: ZoneStyle(dim: 0.55, blur: 4),
                            empty: ZoneStyle(dim: 0.55, blur: 4))

    enum Zone { case top, center, bottom }

    /// The style in effect for a part, whichever way they are set.
    func style(_ zone: Zone) -> ZoneStyle {
        if linked { return all }
        switch zone {
        case .top: return top
        case .center: return center
        case .bottom: return bottom
        }
    }
}

extension Look {
    private enum CodingKeys: String, CodingKey {
        case preset, primary, secondary, linked, all, top, center, bottom, bubble, content, empty
    }

    /// Reads a look saved before content and empty surfaces were split:
    /// content takes what the bars had, empty what the conversation had.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = try c.decode(String.self, forKey: .preset)
        primary = try c.decode(String.self, forKey: .primary)
        secondary = try c.decode(String.self, forKey: .secondary)
        linked = try c.decode(Bool.self, forKey: .linked)
        all = try c.decode(ZoneStyle.self, forKey: .all)
        top = try c.decode(ZoneStyle.self, forKey: .top)
        center = try c.decode(ZoneStyle.self, forKey: .center)
        bottom = try c.decode(ZoneStyle.self, forKey: .bottom)
        bubble = try c.decode(Double.self, forKey: .bubble)
        content = try c.decodeIfPresent(ZoneStyle.self, forKey: .content) ?? (linked ? all : top)
        empty = try c.decodeIfPresent(ZoneStyle.self, forKey: .empty) ?? (linked ? all : center)
    }
}

/// A ready-made pair of colors.
struct LookPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let primary: String
    let secondary: String

    static let all: [LookPreset] = [
        LookPreset(id: "violet", name: "Violet", primary: "#BAA1FF", secondary: "#EDB3FF"),
        LookPreset(id: "blue", name: "Blue", primary: "#7FB2FF", secondary: "#9AE0FF"),
        LookPreset(id: "teal", name: "Teal", primary: "#5FD6CB", secondary: "#8FE9A8"),
        LookPreset(id: "green", name: "Green", primary: "#8ADB7A", secondary: "#D2EC7E"),
        LookPreset(id: "amber", name: "Amber", primary: "#FFC36B", secondary: "#FF9E7A"),
        LookPreset(id: "rose", name: "Rose", primary: "#FF8FB1", secondary: "#FFB199"),
        LookPreset(id: "graphite", name: "Graphite", primary: "#C3C9D6", secondary: "#9FA8BA"),
    ]
}

/// A look the user named and kept.
struct SavedLook: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var look: Look
}

/// Where the look in effect is kept. `Theme` reads it for every color, so
/// it is held in memory and only written through here.
enum LookStore {
    private static let key = "look"
    private static let savedKey = "savedLooks"

    private(set) static var current: Look = load()

    private static func load() -> Look {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key), let look = try? JSONDecoder().decode(Look.self, from: data) {
            return look
        }
        // First run with looks: carry over the two older settings.
        var look = Look.usual
        if let darkness = defaults.object(forKey: "panelDarkness") as? Double {
            look.all.dim = min(1, max(0, (0.55 + 0.5 * darkness - 0.30) / 0.65))
        }
        if defaults.string(forKey: "panelStyle") == "clear" {
            look.all.blur = 0
        }
        look.top = look.all
        look.center = look.all
        look.bottom = look.all
        look.content = look.all
        look.empty = look.all
        return look
    }

    static func set(_ look: Look) {
        current = look
        if let data = try? JSONEncoder().encode(look) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static var saved: [SavedLook] {
        get {
            guard let data = UserDefaults.standard.data(forKey: savedKey),
                  let looks = try? JSONDecoder().decode([SavedLook].self, from: data) else { return [] }
            return looks
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: savedKey)
            }
        }
    }
}

// MARK: - Colors from hex codes

enum Hex {
    /// "#RRGGBB" or "RRGGBB" (also the three-digit short form) as red,
    /// green and blue from 0 to 1. nil when it is not a color code.
    static func parts(_ text: String) -> (red: Double, green: Double, blue: Double)? {
        var code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.hasPrefix("#") { code.removeFirst() }
        if code.count == 3 { code = code.map { "\($0)\($0)" }.joined() }
        guard code.count == 6, let value = UInt32(code, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    static func normalized(_ text: String) -> String? {
        guard let rgb = parts(text) else { return nil }
        return String(format: "#%02X%02X%02X", Int((rgb.red * 255).rounded()),
                      Int((rgb.green * 255).rounded()), Int((rgb.blue * 255).rounded()))
    }

    static func string(_ color: Color) -> String {
        let converted = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X", Int((converted.redComponent * 255).rounded()),
                      Int((converted.greenComponent * 255).rounded()), Int((converted.blueComponent * 255).rounded()))
    }

    /// The color's hue in degrees, 0 to 360. nil for a gray, which has none.
    static func hue(_ text: String) -> Double? {
        guard let rgb = parts(text) else { return nil }
        let source = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        source.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return saturation < 0.1 ? nil : Double(hue) * 360
    }

    /// The color exactly as written.
    static func color(_ text: String) -> Color {
        guard let rgb = parts(text) else { return .white }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// The color fitted to the glass it will sit on, so any choice stays
    /// readable: kept light and soft on dark glass, kept deep on light.
    static func fitted(_ text: String, light: Bool) -> Color {
        guard let rgb = parts(text) else { return .white }
        let source = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        source.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if light {
            // A gray stays a gray; a color is deepened.
            // Deep enough to read as text and icons on white.
            let deep = saturation < 0.08 ? saturation : max(saturation, 0.62)
            return Color(hue: Double(hue), saturation: Double(deep),
                         brightness: Double(min(brightness, saturation < 0.08 ? 0.45 : 0.62)))
        }
        return Color(hue: Double(hue), saturation: Double(min(saturation, 0.62)), brightness: Double(max(brightness, 0.90)))
    }
}

// MARK: - What the look means for each surface

extension Theme {
    static var look: Look { LookStore.current }

    /// How much the panel's base is deepened behind a part: the floor keeps
    /// text readable however far the slider goes.
    ///
    /// The light theme needs a much higher floor than the dark one. Dark
    /// text over a photograph is lost long before white text is, so on light
    /// glass the panel always keeps most of its white behind the words.
    /// Empty surfaces: the panel's base behind everything.
    static var baseDim: Double {
        let dim = look.empty.dim
        return isLight ? 0.80 + 0.18 * dim : 0.30 + 0.65 * dim
    }

    /// What code and files sit on: nearly solid whatever the look, so the
    /// desktop never shows through them.
    static var workSurface: Color { Design.palette().workSurface }

    /// How strongly the desktop behind the panel is blurred, 0 to 1.
    /// Empty surfaces.
    static var behindBlur: Double {
        [0, 0.35, 0.6, 0.8, 1][min(4, max(0, look.empty.blur))]
    }

    /// The blur a floating bar (the header, the ask bar) puts over the
    /// conversation passing under it. nil is none. Content surfaces.
    static var barMaterial: Material? {
        switch min(4, max(0, look.content.blur)) {
        case 0: return nil
        case 1: return .ultraThinMaterial
        case 2: return .thinMaterial
        case 3: return .regularMaterial
        default: return .thickMaterial
        }
    }

    /// How much a floating bar is deepened on top of its blur. Content
    /// surfaces.
    static var barDim: Double {
        let dim = look.content.dim
        return isLight ? 0.62 + 0.3 * dim : 0.7 * dim
    }

    /// The fill of a card or a row that sits on the panel. On dark glass a
    /// card is a faint lightening. On light glass the same trick would
    /// gray the white down and look muddy, so there a card is whiter than
    /// what is around it, as paper on a desk. Content surfaces: as solid
    /// as their transparency sets (the usual setting gives 0.62 and 0.05).
    static var card: Color {
        let dim = look.content.dim
        return isLight ? Color.white.opacity(0.40 + 0.40 * dim) : Color.white.opacity(0.02 + 0.055 * dim)
    }

    /// What sits under a bubble's own color, so the words in it read
    /// clearly over anything.
    static var bubbleShade: Color {
        shade.opacity(isLight ? 0.5 + 0.45 * look.bubble : 0.6 * look.bubble)
    }
}
