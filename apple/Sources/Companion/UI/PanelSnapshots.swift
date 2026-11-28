import AppKit
import ScreenCaptureKit
import SwiftUI

struct PanelSnapshotsApp: App {
    @NSApplicationDelegateAdaptor(PanelSnapshots.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class PanelSnapshots: NSObject, NSApplicationDelegate {
    static var outputDirectory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--panel-snapshots"),
              arguments.indices.contains(flag + 1) else { return nil }
        return URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                if let output = Self.outputDirectory {
                    try await capture(to: output)
                }
                NSApp.terminate(nil)
            } catch {
                FileHandle.standardError.write(Data("Panel snapshots: \(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
    }

    private func capture(to output: URL) async throws {
        guard let screen = NSScreen.main,
              let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { throw failure("No display is available.") }

        let visible = screen.visibleFrame
        let backdrop = NSWindow(contentRect: visible, styleMask: .borderless,
                                backing: .buffered, defer: false)
        backdrop.level = .floating
        backdrop.contentView = NSHostingView(rootView:
            LinearGradient(colors: [.blue, .purple, .orange],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        backdrop.orderFrontRegardless()

        let panel = FloatingPanel(size: FloatingPanelSize.standard, movable: false)
        let view = NSHostingView(rootView: OverlayView()
            .environmentObject(AppState.shared)
            .environmentObject(AppSettings.shared)
            .environmentObject(PanelMorphLayout()))
        view.sizingOptions = []
        panel.contentView = view
        panel.orderFrontRegardless()
        defer {
            panel.orderOut(nil)
            backdrop.orderOut(nil)
        }

        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sizes = [
            ("minimum", FloatingPanelSize.minimum),
            ("default", FloatingPanelSize.standard),
            ("maximum", visible.size)
        ]
        let appearance = Theme.isLight ? "light" : "dark"
        for (name, requested) in sizes {
            let size = NSSize(width: min(requested.width, visible.width),
                              height: min(requested.height, visible.height))
            let frame = NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                               width: size.width, height: size.height)
            panel.setFrame(frame, display: true)
            try await Task.sleep(for: .milliseconds(500))
            let name = "floating-panel-\(name)-\(appearance).png"
            try await save(panel: panel, backdrop: backdrop, displayID: displayNumber.uint32Value,
                           to: output.appendingPathComponent(name))
        }
    }

    private func save(panel: NSWindow, backdrop: NSWindow, displayID: CGDirectDisplayID, to file: URL) async throws {
        guard #available(macOS 14.4, *) else {
            throw failure("Panel snapshots require macOS 14.4 or later.")
        }
        let content = try await SCShareableContent.currentProcess
        guard let display = content.displays.first(where: { $0.displayID == displayID }),
              let foreground = content.windows.first(where: { Int($0.windowID) == panel.windowNumber }),
              let background = content.windows.first(where: { Int($0.windowID) == backdrop.windowNumber })
        else { throw failure("ScreenCaptureKit could not find both snapshot windows on the display.") }

        let filter = SCContentFilter(display: display, including: [background, foreground])
        let crop = foreground.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = crop
        configuration.width = Int((crop.width * scale).rounded())
        configuration.height = Int((crop.height * scale).rounded())
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw failure("Could not encode \(file.lastPathComponent).") }
        try png.write(to: file, options: .atomic)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "PanelSnapshots", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}