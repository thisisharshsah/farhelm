import AppKit
import SwiftUI
import Combine

/// Borderless, non-activating, always-on-top glass panel. Clicks work without
/// stealing focus from the app you're talking in, it joins full-screen spaces,
/// and with sharingType = .none it is invisible to screen sharing and recordings.
final class FloatingPanel: NSPanel {
    init(size: NSSize, movable: Bool, shadow: Bool = false, resizable: Bool = false) {
        var style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        if resizable { style.insert(.resizable) }
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: style,
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = shadow
        hidesOnDeactivate = false
        isMovableByWindowBackground = movable
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
    }

    /// While set, the panel cannot take keyboard focus. The agent sets it so
    /// the keys it presses can only land in the app underneath, never in
    /// Companion's own input box.
    var refusesKeyboard = false

    override var canBecomeKey: Bool { !refusesKeyboard }
    override var canBecomeMain: Bool { false }

    /// When set, the whole window drags with the mouse; a press that doesn't
    /// move counts as a click.
    var dragAnywhere = false
    var onClick: (() -> Void)?
    var onDragEnd: (() -> Void)?

    // sendEvent sees every event delivered to the window, regardless of
    // SwiftUI hit testing, so the drag can never be swallowed by the content.
    override func sendEvent(_ event: NSEvent) {
        guard dragAnywhere, event.type == .leftMouseDown else {
            super.sendEvent(event)
            return
        }
        let start = frame.origin
        performDrag(with: event)
        if abs(frame.origin.x - start.x) < 3, abs(frame.origin.y - start.y) < 3 {
            onClick?()
        } else {
            onDragEnd?()
        }
    }
}

@MainActor
final class OverlayController {
    private let app: AppState
    private let settings: AppSettings
    private let indicator: FloatingPanel
    private let main: FloatingPanel
    private var bag = Set<AnyCancellable>()

    private let indicatorSize: CGFloat = 72
    private let panelSize = NSSize(width: 560, height: 720)
    private let panelMinSize = NSSize(width: 460, height: 560)
    /// Once the user drags the panel itself, it stops following the circle
    /// until Reset Overlay Position.
    private var panelDetached = false
    private var lastProgrammaticOrigin = NSPoint.zero

    init(app: AppState, settings: AppSettings) {
        self.app = app
        self.settings = settings

        indicator = FloatingPanel(size: NSSize(width: indicatorSize, height: indicatorSize), movable: false)
        indicator.contentView = NSHostingView(
            rootView: IndicatorView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
        )

        main = FloatingPanel(size: panelSize, movable: true, shadow: false, resizable: true)
        main.minSize = panelMinSize
        main.contentView = NSHostingView(
            rootView: OverlayView()
                .environmentObject(app)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        )

        indicator.dragAnywhere = true
        indicator.onClick = { [weak self] in self?.togglePanel() }
        indicator.onDragEnd = { [weak self] in self?.snapIfAttached() }

        if !indicator.setFrameUsingName("CompanionIndicator") {
            positionIndicatorDefault()
        }
        indicator.setFrameAutosaveName("CompanionIndicator")
        _ = main.setFrameUsingName("CompanionPanel") // restores the chosen size
        if main.frame.width < panelMinSize.width || main.frame.height < panelMinSize.height {
            // A size saved by an older, smaller layout: fall back to the default.
            main.setFrame(NSRect(origin: main.frame.origin, size: panelSize), display: false)
        }
        main.setFrameAutosaveName("CompanionPanel")
        snapPanelToIndicator()
        applySharing(settings.hideFromScreenShare)
        indicator.orderFrontRegardless()

        settings.$hideFromScreenShare
            .removeDuplicates()
            .sink { [weak self] hide in self?.applySharing(hide) }
            .store(in: &bag)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.ensureOnScreen() }
        }
        // The panel follows the circle live while it is being dragged,
        // unless the user has placed the panel somewhere themselves.
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: indicator,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.snapIfAttached() }
        }
        // Dragging or edge-moving the panel itself detaches it from the circle.
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: main,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let origin = self.main.frame.origin
                if abs(origin.x - self.lastProgrammaticOrigin.x) > 0.5 ||
                    abs(origin.y - self.lastProgrammaticOrigin.y) > 0.5 {
                    self.panelDetached = true
                }
            }
        }
    }

    /// The screen with the camera (built-in display) when available.
    private var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.localizedName.lowercased().contains("built-in") }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Default spot: centered right below the camera/notch. The circle is
    /// draggable; its position is remembered across launches.
    func positionIndicatorDefault() {
        guard let screen = targetScreen else { return }
        let visible = screen.visibleFrame
        indicator.setFrame(NSRect(x: visible.midX - indicatorSize / 2,
                                  y: visible.maxY - indicatorSize - 2,
                                  width: indicatorSize,
                                  height: indicatorSize),
                           display: true)
    }

    /// Keeps the main panel anchored under the circle (above it when the
    /// circle sits near the bottom), clamped to the screen.
    func snapPanelToIndicator() {
        guard let visible = (indicator.screen ?? targetScreen)?.visibleFrame else { return }
        let size = main.frame.size
        var x = indicator.frame.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        var y = indicator.frame.minY - size.height - 2
        if y < visible.minY {
            y = min(indicator.frame.maxY + 2, visible.maxY - size.height)
        }
        setPanelFrame(NSRect(origin: CGPoint(x: x, y: y), size: size))
    }

    private func snapIfAttached() {
        if !panelDetached { snapPanelToIndicator() }
    }

    func resetPositions() {
        panelDetached = false
        positionIndicatorDefault()
        setPanelFrame(NSRect(origin: main.frame.origin, size: panelSize))
        snapPanelToIndicator()
    }

    private func ensureOnScreen() {
        let indicatorVisible = NSScreen.screens.contains { $0.visibleFrame.intersects(indicator.frame) }
        if !indicatorVisible { positionIndicatorDefault() }
        let panelOnScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(main.frame) }
        if !panelDetached || !panelOnScreen {
            snapPanelToIndicator()
        }
    }

    private func setPanelFrame(_ rect: NSRect) {
        lastProgrammaticOrigin = rect.origin
        main.setFrame(rect, display: true)
    }

    private var frameBeforeZoom: NSRect?
    private var frameBeforeCompact: NSRect?
    private let compactMinSize = NSSize(width: 380, height: 200)

    /// Enlarges the panel to fill most of the screen, or puts it back.
    func toggleZoom() {
        if app.compact { setCompact(false) }
        if let previous = frameBeforeZoom {
            frameBeforeZoom = nil
            app.zoomed = false
            setPanelFrame(previous)
            return
        }
        guard let visible = (main.screen ?? targetScreen)?.visibleFrame else { return }
        frameBeforeZoom = main.frame
        app.zoomed = true
        let width = min(visible.width - 80, 1000)
        let height = visible.height - 60
        setPanelFrame(NSRect(x: visible.midX - width / 2, y: visible.minY + 30, width: width, height: height))
    }

    /// Shrinks the panel to a strip with just the newest answer, keeping its
    /// top edge where it is, or restores it.
    func setCompact(_ on: Bool) {
        guard on != app.compact else { return }
        if on {
            if frameBeforeZoom != nil { toggleZoom() }
            let frame = main.frame
            frameBeforeCompact = frame
            app.compact = true
            main.minSize = compactMinSize
            let size = NSSize(width: min(frame.width, 520), height: 250)
            setPanelFrame(NSRect(x: frame.midX - size.width / 2,
                                 y: frame.maxY - size.height,
                                 width: size.width,
                                 height: size.height))
        } else {
            app.compact = false
            main.minSize = panelMinSize
            let top = main.frame.maxY
            let midX = main.frame.midX
            let size = frameBeforeCompact?.size ?? panelSize
            frameBeforeCompact = nil
            setPanelFrame(NSRect(x: midX - size.width / 2, y: top - size.height, width: size.width, height: size.height))
        }
    }

    /// Hands keyboard focus back to the app underneath, so keys typed for
    /// the user go there and not into Companion's own input box.
    func releaseKeyboard() {
        main.refusesKeyboard = true
        main.makeFirstResponder(nil)
        if main.isKeyWindow {
            main.resignKey()
            main.orderOut(nil)
            main.orderFrontRegardless()
        }
        // If Companion itself is the active app (its Settings window was
        // used last), step back so the app behind gets the keys.
        if NSApp.isActive {
            NSApp.deactivate()
        }
    }

    /// Shows the panel and gives it the keyboard, without activating
    /// Companion or taking the user out of the app they are in.
    func focusInput() {
        showPanel()
        main.makeKey()
    }

    /// Lets the panel take keyboard focus again, once the agent is done.
    func restoreKeyboard() {
        main.refusesKeyboard = false
    }

    var panelVisible: Bool { main.isVisible }

    func showPanel() {
        main.orderFrontRegardless()
        app.panelVisible = true
    }

    func hidePanel() {
        main.orderOut(nil)
        app.panelVisible = false
    }

    func togglePanel() {
        panelVisible ? hidePanel() : showPanel()
    }

    func applySharing(_ hide: Bool) {
        let type: NSWindow.SharingType = hide ? .none : .readOnly
        indicator.sharingType = type
        main.sharingType = type
    }

    /// Click-through: the panel ignores the mouse entirely so you can click
    /// and select whatever is behind it. The circle stays clickable.
    func applyClickThrough(_ on: Bool) {
        main.ignoresMouseEvents = on
    }
}
