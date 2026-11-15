import SwiftUI

/// Turns command output with ANSI escape codes into styled text: colours
/// (16, 256 and 24-bit) and bold are kept, other escape codes are dropped.
/// Runs with no colour are left plain so the view's own colour shows.
enum ANSI {
    static func styled(_ text: String) -> AttributedString {
        guard text.contains("\u{1B}") else { return AttributedString(text) }
        var result = AttributedString()
        var foreground: Color?
        var bold = false
        var chunk = ""

        func flush() {
            guard !chunk.isEmpty else { return }
            var piece = AttributedString(chunk)
            if let foreground { piece.foregroundColor = foreground }
            if bold { piece.inlinePresentationIntent = .stronglyEmphasized }
            result += piece
            chunk = ""
        }

        func apply(_ params: String) {
            let codes = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
            var k = 0
            while k < codes.count {
                let code = codes[k]
                switch code {
                case 0: foreground = nil; bold = false
                case 1: bold = true
                case 22: bold = false
                case 30...37: foreground = basic(code - 30)
                case 90...97: foreground = basic(code - 90 + 8)
                case 39: foreground = nil
                case 38, 48:
                    var picked: Color?
                    if k + 2 < codes.count, codes[k + 1] == 5 {
                        picked = indexed(codes[k + 2]); k += 2
                    } else if k + 4 < codes.count, codes[k + 1] == 2 {
                        picked = Color(red: Double(codes[k + 2]) / 255,
                                       green: Double(codes[k + 3]) / 255,
                                       blue: Double(codes[k + 4]) / 255)
                        k += 4
                    }
                    if code == 38, let picked { foreground = picked }
                default: break
                }
                k += 1
            }
        }

        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            guard scalar == "\u{1B}" else {
                chunk.unicodeScalars.append(scalar)
                i += 1
                continue
            }
            flush()
            i += 1
            guard i < scalars.count else { break }
            if scalars[i] == "[" {
                // Control sequence: parameters, then one final letter.
                i += 1
                var params = ""
                while i < scalars.count, !(0x40...0x7E).contains(scalars[i].value) {
                    params.unicodeScalars.append(scalars[i])
                    i += 1
                }
                guard i < scalars.count else { break }
                if scalars[i] == "m" { apply(params) }
                i += 1
            } else if scalars[i] == "]" {
                // Operating system command (a window title, a link): skipped.
                while i < scalars.count, scalars[i] != "\u{07}", scalars[i] != "\u{1B}" { i += 1 }
                if i < scalars.count, scalars[i] == "\u{07}" { i += 1 } else if i + 1 < scalars.count { i += 2 }
            } else if scalars[i] == "(" || scalars[i] == ")" {
                i += 2
            } else {
                i += 1
            }
        }
        flush()
        return result
    }

    private static func basic(_ n: Int) -> Color {
        switch n {
        case 0: return Color(white: 0.45)
        case 1: return Color(red: 0.87, green: 0.33, blue: 0.33)
        case 2: return Color(red: 0.40, green: 0.75, blue: 0.40)
        case 3: return Color(red: 0.85, green: 0.70, blue: 0.30)
        case 4: return Color(red: 0.40, green: 0.55, blue: 0.95)
        case 5: return Color(red: 0.78, green: 0.45, blue: 0.85)
        case 6: return Color(red: 0.35, green: 0.75, blue: 0.80)
        case 7: return Color(white: 0.80)
        case 8: return Color(white: 0.55)
        case 9: return Color(red: 1.0, green: 0.45, blue: 0.45)
        case 10: return Color(red: 0.50, green: 0.90, blue: 0.50)
        case 11: return Color(red: 1.0, green: 0.85, blue: 0.40)
        case 12: return Color(red: 0.55, green: 0.70, blue: 1.0)
        case 13: return Color(red: 0.92, green: 0.58, blue: 1.0)
        case 14: return Color(red: 0.45, green: 0.90, blue: 0.95)
        default: return Color(white: 0.95)
        }
    }

    private static func indexed(_ value: Int) -> Color {
        let n = max(0, min(255, value))
        if n < 16 { return basic(n) }
        if n >= 232 { return Color(white: Double(n - 232) / 23 * 0.9 + 0.05) }
        let c = n - 16
        func level(_ x: Int) -> Double { x == 0 ? 0 : (Double(x) * 40 + 55) / 255 }
        return Color(red: level(c / 36), green: level((c / 6) % 6), blue: level(c % 6))
    }
}
