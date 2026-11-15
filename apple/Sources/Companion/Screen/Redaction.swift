import AppKit
import ApplicationServices
import Vision

/// What may leave this Mac in a picture of the screen: Orbit's redaction,
/// carried into Companion. Every picture or screen text that can reach a
/// model comes from `ScreenReader.capture`, which runs this before anything
/// else sees the pixels:
///
/// - Password managers are never pictured (`Withheld`), and a picture of
///   the whole screen leaves out their windows and the banners that preview
///   messages.
/// - Password fields are blacked out, found through the accessibility tree.
/// - Card numbers (13 to 19 digits that pass the Luhn check, which keeps
///   order and phone numbers visible) are blacked out in the picture and
///   replaced in the text.
///
/// It fails closed: when text recognition does not finish, or the picture
/// cannot be redrawn, nothing is released. Password fields can only be
/// found with the Accessibility permission; without it macOS still draws
/// them as dots.
enum Redaction {
    /// Apps never shown to a model, by bundle identifier. Settings can add
    /// more (`AppSettings.privateApps`), never take these away.
    static let defaultPrivateApps = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords", "org.keepassxc.keepassxc"
    ]

    /// Also left out of pictures of the whole screen: notification banners,
    /// which preview messages.
    static let leftOutOfScreen = ["com.apple.notificationcenterui"]

    /// Margin around a blacked-out field, in points: focus rings bleed past
    /// a field's own frame.
    private static let padding: CGFloat = 4

    /// Why no picture was taken.
    struct Withheld: LocalizedError {
        let app: String
        var errorDescription: String? { "Not looking: \(app) stays private." }
    }

    /// The bundle identifiers that are never pictured, in lower case.
    @MainActor
    static func privateApps() -> Set<String> {
        Set((defaultPrivateApps + AppSettings.shared.privateApps).map { $0.lowercased() })
    }

    /// Takes a capture and returns what may leave the Mac: the picture with
    /// password fields and card numbers blacked out, and its text with card
    /// numbers replaced. `area` is the part of the screen the picture shows,
    /// in points from the top left of the main display; `owner` is the app
    /// whose password fields are looked for.
    static func release(_ image: CGImage, area: CGRect, owner: pid_t?) async throws -> (image: CGImage, text: String) {
        let lines = try await recognize(in: image)
        var black = lines.flatMap(\.cards)
        if let owner, area.width > 0 {
            let scale = CGFloat(image.width) / area.width
            for field in secureFields(of: owner) {
                let local = CGRect(x: (field.minX - area.minX) * scale, y: (field.minY - area.minY) * scale,
                                   width: field.width * scale, height: field.height * scale)
                black.append(local.insetBy(dx: -padding * scale, dy: -padding * scale))
            }
        }
        let text = lines.map { masked($0.text, $0.ranges) }.joined(separator: "\n")
        guard !black.isEmpty else { return (image, text) }
        let painted = try paint(image, black: black)
        return (painted, text)
    }

    // MARK: - Card numbers

    /// One recognized line: its text, where card numbers are in it, and
    /// where those are in the picture (pixels from the top left).
    private struct Line {
        let text: String
        let ranges: [Range<String.Index>]
        let cards: [CGRect]
    }

    /// Text recognition that also finds card numbers. Lines come top to
    /// bottom, as `ScreenReader.recognizeText` gives them.
    private static func recognize(in image: CGImage) async throws -> [Line] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                    let width = CGFloat(image.width)
                    let height = CGFloat(image.height)
                    // Vision measures from the bottom left, 0 to 1.
                    func pixels(_ box: CGRect) -> CGRect {
                        CGRect(x: box.minX * width, y: (1 - box.maxY) * height,
                               width: box.width * width, height: box.height * height)
                    }
                    let lines = (request.results ?? [])
                        .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                        .compactMap { observation -> Line? in
                            guard let candidate = observation.topCandidates(1).first else { return nil }
                            let ranges = Redaction.cardNumbers(in: candidate.string)
                            let cards = ranges.map { range -> CGRect in
                                // Only the number when Vision can place it, else the whole line.
                                if let box = (try? candidate.boundingBox(for: range))?.boundingBox { return pixels(box) }
                                return pixels(observation.boundingBox)
                            }
                            return Line(text: candidate.string, ranges: ranges, cards: cards)
                        }
                    continuation.resume(returning: lines)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Where card numbers are in a line: runs of 13 to 19 digits, with
    /// single spaces or dashes allowed between them, that pass the Luhn check.
    static func cardNumbers(in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var digits: [Int] = []
        var first: String.Index?
        var last: String.Index?
        var afterSeparator = false
        func close() {
            if let first, let last, (13...19).contains(digits.count), Redaction.luhn(digits) {
                found.append(first..<text.index(after: last))
            }
            digits = []
            first = nil
            last = nil
            afterSeparator = false
        }
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isASCII, let digit = character.wholeNumberValue {
                if first == nil { first = index }
                last = index
                digits.append(digit)
                afterSeparator = false
            } else if character == " " || character == "-", !digits.isEmpty, !afterSeparator {
                afterSeparator = true
            } else {
                close()
            }
            index = text.index(after: index)
        }
        close()
        return found
    }

    /// The Luhn check that card numbers pass and most other digit runs do not.
    static func luhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    /// A line with its card numbers replaced.
    private static func masked(_ text: String, _ ranges: [Range<String.Index>]) -> String {
        guard !ranges.isEmpty else { return text }
        var out = ""
        var cursor = text.startIndex
        for range in ranges {
            out += text[cursor..<range.lowerBound]
            out += "[card number hidden]"
            cursor = range.upperBound
        }
        out += text[cursor...]
        return out
    }

    // MARK: - Password fields

    /// Password fields in an app's windows, in points from the top left of
    /// the main display. The focused field comes first, since it is the one
    /// being typed into; the rest of the tree is walked within a bound, so a
    /// huge page cannot stall the capture.
    static func secureFields(of pid: pid_t, limit: Int = 1500) -> [CGRect] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var found: [CGRect] = []
        if let focused = element(app, kAXFocusedUIElementAttribute), isSecure(focused), let rect = frame(of: focused) {
            found.append(rect)
        }
        var queue = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var next = 0
        while next < queue.count, next < limit {
            let current = queue[next]
            next += 1
            if isSecure(current), let rect = frame(of: current), !found.contains(rect) {
                found.append(rect)
            }
            queue.append(contentsOf: (attribute(current, kAXChildrenAttribute) as? [AXUIElement]) ?? [])
        }
        return found
    }

    /// Whether an element is a password field.
    static func isSecure(_ element: AXUIElement) -> Bool {
        (attribute(element, kAXSubroleAttribute) as? String) == "AXSecureTextField"
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// An element's frame, in points from the top left of the main display.
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    // MARK: - Drawing

    /// The picture with the given rectangles (pixels from the top left)
    /// filled black.
    private static func paint(_ image: CGImage, black rects: [CGRect]) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw unchecked
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: bounds)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for rect in rects {
            // Core Graphics counts from the bottom left.
            let flipped = CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
            let clipped = flipped.intersection(bounds)
            if !clipped.isNull, !clipped.isEmpty { context.fill(clipped) }
        }
        guard let painted = context.makeImage() else { throw unchecked }
        return painted
    }

    private static var unchecked: NSError {
        NSError(domain: "Companion", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "The screen picture could not be checked for private details, so it was not used."
        ])
    }
}
