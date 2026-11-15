import AppKit

/// Companion's panel can float above every other window. Whatever
/// Companion opens while it does (a dialog, an Open or Save panel, a
/// preview, a window of its own) goes above the panel, so nothing it shows
/// ever waits unseen behind it. When the panel sits with ordinary windows
/// again, those windows go back to their own level.
@MainActor
enum WindowStacking {
    /// The panel's level while it floats; nil while it sits with ordinary windows.
    private(set) static var panelLevel: NSWindow.Level? = .statusBar

    /// The level for anything opened while the panel floats.
    static var above: NSWindow.Level {
        NSWindow.Level(rawValue: (panelLevel ?? .normal).rawValue + 1)
    }

    /// Windows raised, with the level each had, to give back later.
    private static let raised = NSMapTable<NSWindow, NSNumber>.weakToStrongObjects()
    private static var observers: [NSObjectProtocol] = []

    /// Watches every window of the app as it shows or takes focus.
    static func start() {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { raise(window) }
            })
        }
    }

    /// Called when the panel's place changes (Settings > Look).
    static func panelFloats(_ floats: Bool) {
        panelLevel = floats ? .statusBar : nil
        if floats {
            for window in NSApp.windows where window.isVisible { raise(window) }
        } else {
            // Back where they were.
            for window in raised.keyEnumerator().allObjects.compactMap({ $0 as? NSWindow }) {
                if let level = raised.object(forKey: window) { window.level = NSWindow.Level(rawValue: level.intValue) }
            }
            raised.removeAllObjects()
        }
    }

    private static func raise(_ window: NSWindow) {
        guard let panelLevel, window.isVisible,
              // The panel, the floating circle and their kind place themselves.
              !(window is FloatingPanel),
              // Popovers and other child windows move with their parent.
              window.parent == nil, window.sheetParent == nil, !window.isSheet,
              // Menus, tooltips and the like are above already.
              window.level.rawValue < panelLevel.rawValue else { return }
        if raised.object(forKey: window) == nil {
            raised.setObject(NSNumber(value: window.level.rawValue), forKey: window)
        }
        window.level = above
        window.orderFront(nil)
    }
}
