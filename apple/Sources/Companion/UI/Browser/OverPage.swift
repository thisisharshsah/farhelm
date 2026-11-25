import AppKit
import SwiftUI

/// Something over the page area of the browser, in a window of its own.
/// Chromium draws each page in a window over the pane (`ChromiumHost`),
/// above anything the pane itself draws, so what has to sit over a page
/// sits in a window over that one; WebKit's pages are covered the same way,
/// so both engines behave alike. The window covers the place it is given
/// exactly, follows it as the panel moves and resizes, keeps out of screen
/// shares whenever the panel does, and goes with it.
struct OverPage<Overlay: View>: NSViewRepresentable {
    /// Whether it shows.
    let shown: Bool
    /// Called when it is let go from outside: the person clicked somewhere
    /// else (the page, the chat), so its window gave up the keys.
    let dismiss: () -> Void
    @ViewBuilder let overlay: () -> Overlay

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ anchor: Anchor, context: Context) {
        anchor.dismiss = dismiss
        if shown {
            anchor.present(AnyView(overlay()
                .environmentObject(AppState.shared)
                .preferredColorScheme(Theme.isLight ? .light : .dark)))
        } else {
            anchor.close()
        }
    }

    static func dismantleNSView(_ anchor: Anchor, coordinator: ()) {
        anchor.close()
    }

    /// Holds the overlay's place in the pane. Clicks pass through it to the
    /// page: only the window over it takes them, while it shows.
    final class Anchor: NSView {
        var dismiss: () -> Void = {}
        private var panel: OverPagePanel?
        private var host: NSHostingView<AnyView>?
        private var resigned: NSObjectProtocol?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func present(_ content: AnyView) {
            if let host {
                host.rootView = content
            } else {
                let host = NSHostingView(rootView: content)
                let panel = OverPagePanel()
                panel.contentView = host
                self.host = host
                self.panel = panel
                resigned = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                  object: panel, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.dismiss() }
                }
            }
            place()
        }

        func close() {
            if let resigned { NotificationCenter.default.removeObserver(resigned) }
            resigned = nil
            guard let panel else { return }
            let parent = panel.parent
            // The keys go back to the panel only when they were here: a
            // click on the page keeps them in the page.
            let hadKeys = panel.isKeyWindow
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.panel = nil
            host = nil
            if hadKeys { parent?.makeKey() }
        }

        private var watching: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watching.forEach(NotificationCenter.default.removeObserver)
            watching = []
            if let window {
                watching.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                })
            }
            place()
        }

        override func layout() {
            super.layout()
            place()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            place()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            place()
        }

        private func place() {
            guard let panel else { return }
            guard let window, !isHiddenOrHasHiddenAncestor, bounds.width > 20, bounds.height > 20 else {
                if panel.isVisible {
                    panel.parent?.removeChildWindow(panel)
                    panel.orderOut(nil)
                }
                return
            }
            let frame = window.convertToScreen(convert(bounds, to: nil))
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            panel.sharingType = window.sharingType
            panel.appearance = window.appearance
            if panel.parent !== window || !panel.isVisible {
                panel.parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }
}

/// The window an overlay over a page sits in: borderless and clear, with
/// no shadow, taking the keys without bringing Companion forward (as the
/// panel does), and never a window of its own in Mission Control or the
/// window list.
final class OverPagePanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
