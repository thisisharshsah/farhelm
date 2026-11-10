import Foundation
import AppKit
import ScreenCaptureKit
import Vision

/// A monitor the screen reader can capture.
struct ScreenChoice: Identifiable, Hashable {
    /// The CoreGraphics display ID.
    let id: Int
    let name: String
}

/// Everything Companion knows about what the user is looking at, gathered
/// in one step: which app and window, the page address in a browser, and
/// the text in the window.
struct ScreenContext {
    let app: String
    let window: String
    let url: String
    let text: String

    /// The app, window and address as a few labeled lines.
    var header: String {
        var lines = ["App in front: \(app.isEmpty ? "unknown" : app)"]
        if !window.isEmpty { lines.append("Window: \(window)") }
        if !url.isEmpty { lines.append("URL: \(url)") }
        return lines.joined(separator: "\n")
    }
}

/// One-shot screen capture + OCR. Uses the same Screen Recording permission
/// as system audio. Companion's own windows have sharingType = .none, so
/// they never appear in these captures (no feedback loop).
enum ScreenReader {
    static func captureText() async throws -> String {
        try await capture().text
    }

    /// The monitors connected right now, for the picker.
    @MainActor
    static func screens() -> [ScreenChoice] {
        NSScreen.screens.compactMap { screen in
            guard let id = displayID(of: screen) else { return nil }
            return ScreenChoice(id: id, name: screen.localizedName)
        }
    }

    @MainActor
    private static func displayID(of screen: NSScreen) -> Int? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue
    }

    /// The monitor to read: the one chosen in Settings, or, on Automatic,
    /// the one the mouse pointer is on.
    @MainActor
    private static func preferredDisplayID() -> Int? {
        let chosen = AppSettings.shared.screenDisplayID
        if chosen != 0 { return chosen }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        return screen.flatMap(displayID(of:))
    }

    /// What to zoom in on: the frontmost window of another app under the
    /// mouse pointer. Its bounds are global, in points, with the origin at
    /// the top left of the main display. nil when there is no such window
    /// (then the whole monitor is captured).
    @MainActor
    private static func focusWindow(ownedBy owner: pid_t? = nil) -> (id: CGWindowID, bounds: CGRect)? {
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        let cocoa = NSEvent.mouseLocation
        let pointer = CGPoint(x: cocoa.x, y: mainHeight - cocoa.y)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        // The list is ordered front to back.
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width >= 320, bounds.height >= 220,
                  // Either the front window of a given app, or the window
                  // under the pointer.
                  owner.map({ (window[kCGWindowOwnerPID as String] as? Int32) == $0 }) ?? bounds.contains(pointer),
                  let number = window[kCGWindowNumber as String] as? UInt32 else { continue }
            return (CGWindowID(number), bounds)
        }
        return nil
    }

    /// Takes a picture of what the user is looking at and reads it.
    ///
    /// Instead of the whole monitor, it zooms in on the window under the
    /// mouse pointer and captures that at full resolution, so small text and
    /// diagrams keep their detail. The window itself is captured, not the
    /// patch of screen it sits on, so other windows overlapping it are left
    /// out and nothing they cover is lost. Returns the image (for the
    /// thumbnail and for engines that can look at pictures) and its OCR text.
    ///
    /// With `frontmost`, the window of the app in front is read instead of
    /// the one under the pointer.
    static func capture(frontmost: Bool = false) async throws -> (image: CGImage, text: String) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let preferred = await preferredDisplayID()
        // A chosen monitor that has been unplugged falls back to the first one.
        guard let display = content.displays.first(where: { Int($0.displayID) == preferred })
                ?? content.displays.first else {
            throw NSError(domain: "Companion", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No display found to capture."])
        }
        let whole = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
        let config = SCStreamConfiguration()
        config.captureResolution = .best
        config.showsCursor = false

        var owner: pid_t?
        if frontmost {
            owner = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        }
        if let focus = await focusWindow(ownedBy: owner) {
            // The part of the window that is on the chosen monitor.
            let local = focus.bounds.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY).intersection(whole)
            if local.width >= 320, local.height >= 220 {
                if let window = content.windows.first(where: { $0.windowID == focus.id }) {
                    // The window on its own, whatever is on top of it.
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let scale = CGFloat(filter.pointPixelScale)
                    config.width = max(1, Int(window.frame.width * scale))
                    config.height = max(1, Int(window.frame.height * scale))
                    if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                               configuration: config) {
                        return (image, try await recognizeText(in: image))
                    }
                }
                // The window could not be captured on its own: fall back to
                // the patch of screen it sits on.
                config.sourceRect = local
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let scale = CGFloat(filter.pointPixelScale)
                config.width = max(1, Int(local.width * scale))
                config.height = max(1, Int(local.height * scale))
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                return (image, try await recognizeText(in: image))
            }
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int(whole.width * scale))
        config.height = max(1, Int(whole.height * scale))
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let text = try await recognizeText(in: image)
        return (image, text)
    }

    /// Reads the screen in one step: the app in front, its window title,
    /// the page address when it is a browser, and the window's text.
    static func read() async -> ScreenContext {
        let info = await MainActor.run { frontInfo() }
        let text = (try? await capture(frontmost: true).text) ?? ""
        return ScreenContext(app: info.app, window: info.window, url: info.url, text: text)
    }

    /// The app in front, the title of its front window, and the address of
    /// the page when it is a browser.
    @MainActor
    static func frontInfo() -> (app: String, window: String, url: String) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return ("", "", "") }
        var title = ""
        if let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] {
            // Front to back: the first ordinary window of the app is its front one.
            title = windows.first(where: {
                ($0[kCGWindowLayer as String] as? Int) == 0
                    && ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier
                    && !(($0[kCGWindowName as String] as? String) ?? "").isEmpty
            })?[kCGWindowName as String] as? String ?? ""
        }
        return (app.localizedName ?? "", title, browserURL(bundleID: app.bundleIdentifier))
    }

    /// Asks a browser for the address of the page in its front window.
    /// Empty for other apps, and when the user has not allowed it.
    @MainActor
    private static func browserURL(bundleID: String?) -> String {
        guard let bundleID else { return "" }
        let source: String
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            source = "tell application id \"\(bundleID)\" to return URL of front document"
        case "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
             "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera":
            source = "tell application id \"\(bundleID)\" to return URL of active tab of front window"
        default:
            return ""
        }
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue ?? ""
    }

    /// A tiny capture of the whole monitor, cheap enough to take every few
    /// seconds just to notice that something changed.
    static func glance(width: Int = 96) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let preferred = await preferredDisplayID()
        guard let display = content.displays.first(where: { Int($0.displayID) == preferred })
                ?? content.displays.first else {
            throw NSError(domain: "Companion", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No display found to capture."])
        }
        let config = SCStreamConfiguration()
        config.width = width
        config.height = max(1, width * display.height / max(display.width, 1))
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []),
                                                          configuration: config)
    }

    /// The capture as a JPEG for a vision model: scaled so its longer side
    /// is at most `maxEdge` pixels, which keeps detail without a huge upload.
    static func jpeg(_ image: CGImage, maxEdge: CGFloat = 2200) -> Data? {
        let longest = CGFloat(max(image.width, image.height))
        let scale = min(1, maxEdge / longest)
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    static func recognizeText(in image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                    let observations = request.results ?? []
                    let lines = observations
                        .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                        .compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
