import AppKit
import SwiftUI

/// Makes the space behind the top bar behave like a Mac title bar: drag it
/// to move the panel, double-click it to do what the system is set to do on
/// a title bar (fill the screen by default, or minimize, or nothing).
/// Buttons and fields drawn over it keep their own clicks.
struct TitleBarArea: NSViewRepresentable {
    /// Fill the screen, or go back.
    let zoom: () -> Void
    let minimize: () -> Void

    func makeNSView(context: Context) -> AreaView {
        let view = AreaView()
        view.area = self
        return view
    }

    func updateNSView(_ view: AreaView, context: Context) {
        view.area = self
    }

    final class AreaView: NSView {
        var area: TitleBarArea?

        // The panel is moved by hand below, a step per mouse movement, so
        // a double-click is seen here and nothing ever waits on the mouse.
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private var grabbedAt: NSPoint?
        private var originAtGrab = NSPoint.zero

        override func mouseDown(with event: NSEvent) {
            AppState.shared.overlay?.note("title bar press, clicks=\(event.clickCount)")
            if event.clickCount == 2 {
                grabbedAt = nil
                // System Settings > Desktop & Dock > "Double-click a window's
                // title bar to".
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                let area = self.area
                // After this click has finished being handled, not inside it.
                DispatchQueue.main.async {
                    switch action {
                    case "None": break
                    case "Minimize": area?.minimize()
                    default: area?.zoom()
                    }
                }
                return
            }
            grabbedAt = NSEvent.mouseLocation
            originAtGrab = window?.frame.origin ?? .zero
        }

        override func mouseDragged(with event: NSEvent) {
            guard let grabbedAt, let window else { return }
            let now = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: originAtGrab.x + now.x - grabbedAt.x,
                                          y: originAtGrab.y + now.y - grabbedAt.y))
        }

        override func mouseUp(with event: NSEvent) {
            grabbedAt = nil
        }
    }
}
