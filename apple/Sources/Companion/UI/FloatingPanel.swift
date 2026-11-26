import AppKit
import QuartzCore
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

    // MARK: What is attached to the panel

    // Windows attached to the panel are part of it: Chromium's pages, each
    // drawn in a window of its own laid over the browser pane (CEFKit's
    // `showAbove`), and what sits over a page (`OverPage`). AppKit moves,
    // hides and minimizes them with the panel; the panel also gives them its
    // level and its desktops, when they are attached and whenever these
    // change, and `OverlayController.fade` fades them with it. So none is
    // left above other apps once the panel is not, behind on another
    // desktop, or showing while the panel fades.
    //
    // The overrides of properties below are `dynamic`, and the panel's
    // fading is not overridden at all. In a final class Swift calls an
    // override directly instead of sending the message, so a property set
    // through the panel's `animator()` proxy would run the override on the
    // proxy, which crashed Companion at launch, and observers of the
    // property would never hear of the change.

    override func addChildWindow(_ child: NSWindow, ordered place: NSWindow.OrderingMode) {
        Self.attach(child, to: self)
        super.addChildWindow(child, ordered: place)
    }

    override dynamic var level: NSWindow.Level {
        didSet { childWindows?.forEach { Self.attach($0, to: self) } }
    }

    override dynamic var collectionBehavior: NSWindow.CollectionBehavior {
        didSet { childWindows?.forEach { Self.attach($0, to: self) } }
    }

    /// Gives a window attached to the panel the panel's level, desktops and
    /// fading. It is never a window of its own in Mission Control or the
    /// window cycle.
    static func attach(_ child: NSWindow, to panel: NSWindow) {
        let desktops: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .moveToActiveSpace, .fullScreenAuxiliary, .fullScreenNone]
        let behavior = panel.collectionBehavior.intersection(desktops).union([.transient, .ignoresCycle])
        if child.collectionBehavior != behavior { child.collectionBehavior = behavior }
        if child.level != panel.level { child.level = panel.level }
        if child.alphaValue != panel.alphaValue { child.alphaValue = panel.alphaValue }
    }

    override var canBecomeKey: Bool { !refusesKeyboard }
    override var canBecomeMain: Bool { false }

    /// A borderless panel has no close, minimize or zoom button. Without
    /// this, AppKit looked for them through every view in the panel each
    /// time it laid the panel out (to work out the title bar's and the
    /// edges' regions), which with the panel's many views took a real
    /// share of the Mac's time.
    override func standardWindowButton(_ button: NSWindow.ButtonType) -> NSButton? { nil }

    /// When set, the whole window drags with the mouse; a press that doesn't
    /// move counts as a click.
    var dragAnywhere = false
    var onClick: (() -> Void)?
    var onDragEnd: (() -> Void)?

    // sendEvent sees every event delivered to the window, regardless of
    // SwiftUI hit testing, so the drag can never be swallowed by the content.
    /// A click in the panel makes Companion the active app, as a click in
    /// any app's window does. Without this the app you were in before stays
    /// active while you use the panel, so Cmd+Q and other shortcuts go to
    /// that app instead: quitting Companion would quit something else.
    /// Showing the panel still does not take focus; only clicking in it does.
    var activatesOnClick = false

    override func sendEvent(_ event: NSEvent) {
        if activatesOnClick, event.type == .leftMouseDown || event.type == .rightMouseDown, !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            makeKey()
        }
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

/// Holds the panel to its smallest size while its edge is dragged. A
/// borderless panel does not reliably keep to `minSize` on its own, and a
/// panel dragged narrower than its content shows a slice of it.
@MainActor
private final class ResizeFloor: NSObject, NSWindowDelegate {
    var size = NSSize.zero

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: max(frameSize.width, size.width), height: max(frameSize.height, size.height))
    }
}

@MainActor
final class OverlayController {
    private let floor = ResizeFloor()

    /// The smallest the panel may be: asked of the window every way it can
    /// be, since any one of them alone has let it through.
    private func setFloor(_ size: NSSize) {
        floor.size = size
        main.minSize = size
        main.contentMinSize = size
    }

    private let app: AppState
    private let settings: AppSettings
    private let indicator: FloatingPanel
    private let main: FloatingPanel
    private var bag = Set<AnyCancellable>()

    private let indicatorSize = IndicatorView.side
    private let panelSize = NSSize(width: 560, height: 720)
    // Wide enough that the top bar's buttons always fit side by side.
    private let panelMinSize = NSSize(width: 540, height: 560)

    // The narrowest each column can usefully be. Below these, content is
    // cut off at the panel's edges instead of fitting.
    static let chatLeast: CGFloat = 320
    static let sidebarLeast: CGFloat = 170
    static func sideLeast(_ mode: SidePanelMode) -> CGFloat { mode == .details ? 220 : 320 }
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

        // Not movable by its background: the top bar moves it by hand
        // (TitleBarArea) and the pill has its own handle (DragHandle). Left
        // movable, AppKit worked out after every layout which parts of the
        // panel may drag it, walking the whole view tree each time.
        main = FloatingPanel(size: panelSize, movable: false, shadow: false, resizable: true)
        main.activatesOnClick = true
        setFloor(panelMinSize)
        let content = FirstClickHostingView(
            rootView: OverlayView()
                .environmentObject(app)
                .environmentObject(settings)
        )
        // The controller alone decides the panel's size. Left to itself the
        // hosting view also sizes the window from its content, and the two
        // pull against each other when a column opens.
        content.sizingOptions = []
        main.contentView = content

        indicator.dragAnywhere = true
        // A tap on the circle closes the panel when it is open, and never
        // opens it: with the panel away it brings up the toolbar, whose
        // arrow opens the panel.
        indicator.onClick = { [weak self] in
            guard let self else { return }
            if self.app.panelVisible { self.hidePanel() } else { OrbitDock.shared.reveal() }
        }
        indicator.onDragEnd = { [weak self] in
            guard let self else { return }
            // The circle stays wherever it was put. Only if it was dropped
            // on the panel does it slide to the nearest clear place.
            self.keepIndicatorClear()
        }

        if !indicator.setFrameUsingName("CompanionIndicator") {
            positionIndicatorDefault()
        } else if indicator.frame.size != NSSize(width: indicatorSize, height: indicatorSize) {
            // Saved at another size (a bigger circle before): it stays where
            // it was, centered on the same point, at today's size.
            let saved = indicator.frame
            indicator.setFrame(NSRect(x: saved.midX - indicatorSize / 2,
                                      y: saved.midY - indicatorSize / 2,
                                      width: indicatorSize,
                                      height: indicatorSize),
                               display: false)
        }
        indicator.setFrameAutosaveName("CompanionIndicator")
        // The toolbar and status pill that ride with the circle while the
        // panel is hidden.
        OrbitDock.shared.attach(to: indicator, app: app)
        _ = main.setFrameUsingName("CompanionPanel") // restores the chosen size
        if main.frame.width < panelMinSize.width || main.frame.height < panelMinSize.height {
            // A size saved by an older, smaller layout: fall back to the default.
            main.setFrame(NSRect(origin: main.frame.origin, size: panelSize), display: false)
        }
        main.setFrameAutosaveName("CompanionPanel")
        // A panel the person had moved somewhere of its own opens there
        // again; only one still following the circle is placed beside it.
        // Read before anything moves the panel: the autosave would write
        // the new place over the saved one.
        panelDetached = UserDefaults.standard.bool(forKey: Session.detached)
            && NSScreen.screens.contains { $0.visibleFrame.intersects(main.frame) }
        if !panelDetached { snapPanelToIndicator() }
        lastPanelOrigin = main.frame.origin
        applySharing(settings.hideFromScreenShare)
        indicator.orderFrontRegardless()

        settings.$hideFromScreenShare
            .removeDuplicates()
            .sink { [weak self] hide in self?.applySharing(hide) }
            .store(in: &bag)

        applyPlacement(onTop: settings.keepOnTop, everywhere: settings.onAllDesktops)
        settings.$keepOnTop
            .removeDuplicates()
            .sink { [weak self] onTop in
                guard let self else { return }
                self.applyPlacement(onTop: onTop, everywhere: self.settings.onAllDesktops)
            }
            .store(in: &bag)
        settings.$onAllDesktops
            .removeDuplicates()
            .sink { [weak self] everywhere in
                guard let self else { return }
                self.applyPlacement(onTop: self.settings.keepOnTop, everywhere: everywhere)
            }
            .store(in: &bag)

        // The session is saved again when the open chat, the sidebar or the
        // zoom changes; the frame's own changes are watched below.
        app.$conversation
            .map(\.id)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleSessionSave() }
            .store(in: &bag)
        app.$sidebarPinned
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleSessionSave() }
            .store(in: &bag)
        app.$zoomed
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleSessionSave() }
            .store(in: &bag)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.ensureOnScreen() }
        }
        // The two follow each other. The panel follows the circle live
        // while the circle is being dragged; the circle follows the panel
        // when it is the panel that moves (see `keepIndicatorClear`).
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: indicator,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Moved from here, to keep clear of the panel: there is
                // nothing for the panel to follow.
                let origin = self.indicator.frame.origin
                if abs(origin.x - self.lastIndicatorOrigin.x) < 0.5, abs(origin.y - self.lastIndicatorOrigin.y) < 0.5 {
                    return
                }
                // Dragged by the user. The panel stays where it is; while it
                // is put away, it will open beside the circle's new place.
                if !self.app.panelVisible {
                    self.panelDetached = false
                    // The panel did not move, so nothing else saves this.
                    self.scheduleSessionSave()
                }
            }
        }
        main.delegate = floor
        NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification,
                                               object: main,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.enforceFit() }
        }
        // However the panel came by its size, it is never left narrower
        // than the columns that are open.
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                               object: main,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let content = self.main.contentView?.frame ?? .zero
                if !self.main.inLiveResize { self.trace("resized frame=\(Self.text(self.main.frame)) content=\(Self.text(content)) live=\(self.main.inLiveResize)") }
                self.enforceFit()
                self.keepIndicatorClear()
                self.scheduleSessionSave()
            }
        }
        // Dragging or edge-moving the panel itself detaches it from the circle.
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: main,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.scheduleSessionSave()
                // Frames passed through while the panel animates are not the user's doing.
                guard !self.animatingFrame else { return }
                let origin = self.main.frame.origin
                let byUser = abs(origin.x - self.lastProgrammaticOrigin.x) > 0.5 ||
                    abs(origin.y - self.lastProgrammaticOrigin.y) > 0.5
                let delta = CGPoint(x: origin.x - self.lastPanelOrigin.x, y: origin.y - self.lastPanelOrigin.y)
                self.lastPanelOrigin = origin
                if byUser {
                    self.panelDetached = true
                    // The circle moves with the panel, keeping its own place
                    // beside it, wherever that is.
                    if self.carryIndicator(by: delta) { return }
                }
                // Dragged by the user, the circle goes with it; placed by
                // the app, the circle stays where it is if it is clear.
                self.keepIndicatorClear(follow: byUser)
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
        // While the panel animates, its size is the one it is headed for.
        let size = animatingFrame ? (targetFrame?.size ?? main.frame.size) : main.frame.size
        let orbit = indicator.frame
        let gap = followGap
        /// Kept on the screen.
        func onScreen(_ rect: NSRect) -> NSRect {
            var rect = rect
            rect.origin.x = min(max(rect.minX, visible.minX + 8), max(visible.minX + 8, visible.maxX - rect.width - 8))
            rect.origin.y = min(max(rect.minY, visible.minY), max(visible.minY, visible.maxY - rect.height))
            return rect
        }
        // The circle stays where it is; the panel takes the first side of it
        // that has room: below, above, to the right, to the left.
        let sides = [
            NSRect(x: orbit.midX - size.width / 2, y: orbit.minY - gap - size.height, width: size.width, height: size.height),
            NSRect(x: orbit.midX - size.width / 2, y: orbit.maxY + gap, width: size.width, height: size.height),
            NSRect(x: orbit.maxX + gap, y: orbit.maxY - size.height, width: size.width, height: size.height),
            NSRect(x: orbit.minX - gap - size.width, y: orbit.maxY - size.height, width: size.width, height: size.height)
        ]
        let clear = orbit.insetBy(dx: -(gap - 1), dy: -(gap - 1))
        for side in sides {
            let placed = onScreen(side)
            if !placed.intersects(clear) {
                setPanelFrame(placed)
                return
            }
        }
        // No side has room (a panel nearly the size of the screen): below,
        // and the circle steps aside.
        setPanelFrame(onScreen(sides[0]))
    }

    private func snapIfAttached() {
        if !panelDetached { snapPanelToIndicator() }
    }

    // MARK: The circle and the panel keep clear of each other
    //
    // The two travel together and never overlap. Whichever one the user
    // moves leads: drag the circle and the panel goes with it; move, resize
    // or enlarge the panel and the circle takes the nearest free place
    // beside it. When the panel leaves no room on its screen at all (filling
    // it), the circle is put away until there is room again.

    /// The circle's place as last set from here, so its own moves are told
    /// apart from the user's.
    private var lastIndicatorOrigin = NSPoint(x: -1, y: -1)
    /// The circle was put away because the panel left it no room.
    private var indicatorAway = false

    // The circle glides after the panel instead of jumping: each frame it
    // closes part of the distance to its place, so it trails the panel a
    // little and settles softly. It never passes over the panel: if the
    // panel grows into it, it is put clear at once, and when it changes
    // sides it fades across rather than sliding through.
    private var followTarget: NSRect?
    private var followSide = -1
    private var followTimer: Timer?
    private var followLast = Date()
    /// Room kept between the circle and the panel.
    private let followGap: CGFloat = 10

    /// The free places for the circle beside the panel: above it, below
    /// it, and level with its top on either side. Of those that are on the
    /// screen and clear of the panel, the one nearest to where the circle is
    /// now, so it keeps its side while it can and changes when it must.
    private func indicatorSpot(beside panel: NSRect) -> NSRect? {
        guard let visible = (main.screen ?? indicator.screen ?? targetScreen)?.visibleFrame else { return nil }
        let side = indicatorSize
        let gap = followGap
        func within(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            min(max(value, low), max(low, high))
        }
        let across = within(panel.midX - side / 2, visible.minX, visible.maxX - side)
        let level = within(panel.maxY - side, visible.minY, visible.maxY - side)
        let spots = [
            NSRect(x: across, y: panel.maxY + gap, width: side, height: side),
            NSRect(x: across, y: panel.minY - gap - side, width: side, height: side),
            NSRect(x: panel.maxX + gap, y: level, width: side, height: side),
            NSRect(x: panel.minX - gap - side, y: level, width: side, height: side)
        ]
        let here = indicator.frame
        func distance(_ spot: NSRect) -> CGFloat {
            abs(spot.midX - here.midX) + abs(spot.midY - here.midY)
        }
        // Keeping to the side it is on is worth some distance, so a small
        // move of the panel does not flip it to the other side.
        let ranked = spots.enumerated()
            .filter { visible.contains($0.element) && !$0.element.intersects(panel) }
            .min { a, b in
                let da = distance(a.element) - (a.offset == followSide ? 140 : 0)
                let db = distance(b.element) - (b.offset == followSide ? 140 : 0)
                return da < db
            }
        guard let ranked else { return nil }
        pendingSide = ranked.offset
        return ranked.element
    }
    /// Which spot `indicatorSpot` chose last (0 above, 1 below, 2 right, 3 left).
    private var pendingSide = -1

    /// Puts the circle beside the panel, clear of it. Called whenever the
    /// panel moves, changes size, shows or hides.
    /// `follow`: the user moved the panel, and the circle goes with it.
    /// Otherwise the circle is left where it is unless the panel is in its
    /// way, so opening the panel or a column never moves it.
    func keepIndicatorClear(follow: Bool = false) {
        guard app.panelVisible, main.isVisible else {
            // With no panel in the way the circle is always there.
            if indicatorAway {
                indicatorAway = false
                indicator.orderFrontRegardless()
            }
            return
        }
        // The user has hold of the circle: it leads, and the panel follows.
        if NSEvent.pressedMouseButtons != 0, indicator.frame.contains(NSEvent.mouseLocation) { return }
        // Already clear of the panel and on its screen: it stays put.
        if !follow, !indicatorAway, followTarget == nil,
           let visible = (indicator.screen ?? main.screen)?.visibleFrame,
           visible.contains(indicator.frame),
           !indicator.frame.insetBy(dx: -(followGap - 1), dy: -(followGap - 1)).intersects(main.frame) {
            return
        }
        guard let spot = indicatorSpot(beside: main.frame) else {
            if !indicatorAway {
                indicatorAway = true
                indicator.orderOut(nil)
            }
            return
        }
        if indicatorAway {
            indicatorAway = false
            // Back from being put away: it appears in its place.
            placeIndicator(at: spot.origin)
            indicator.alphaValue = 1
            indicator.orderFrontRegardless()
            followSide = pendingSide
            return
        }
        // `self.`: the `follow` parameter would hide the method.
        self.follow(to: spot, side: pendingSide)
    }

    /// Sets where the circle goes; the glide gets it there.
    private func follow(to spot: NSRect, side: Int) {
        let here = indicator.frame
        // Another side of the panel: fade out, move, fade in, so it is never
        // seen crossing the panel.
        if followSide != -1, side != followSide {
            followSide = side
            followTarget = nil
            followTimer?.invalidate()
            followTimer = nil
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.1
                indicator.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.placeIndicator(at: spot.origin)
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.16
                        self.indicator.animator().alphaValue = 1
                    }
                }
            })
            return
        }
        followSide = side
        guard abs(spot.minX - here.minX) > 0.5 || abs(spot.minY - here.minY) > 0.5 else { return }
        followTarget = spot
        // The panel has grown into it: out of the way now, no glide.
        if here.intersects(main.frame) {
            placeIndicator(at: spot.origin)
            followTarget = nil
            return
        }
        if followTimer == nil {
            followLast = Date()
            // Common modes, so it keeps gliding while a window is dragged.
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.followStep() }
            }
            RunLoop.main.add(timer, forMode: .common)
            followTimer = timer
        }
    }

    /// One frame of the glide: a share of the distance, set by the time
    /// passed, so it moves the same at any frame rate.
    private func followStep() {
        guard let target = followTarget else {
            followTimer?.invalidate()
            followTimer = nil
            return
        }
        let now = Date()
        let dt = min(now.timeIntervalSince(followLast), 0.05)
        followLast = now
        let here = indicator.frame.origin
        let share = CGFloat(1 - exp(-dt / 0.085))
        var next = NSPoint(x: here.x + (target.minX - here.x) * share,
                           y: here.y + (target.minY - here.y) * share)
        let done = abs(target.minX - next.x) < 0.5 && abs(target.minY - next.y) < 0.5
        // Never over the panel, however the glide is caught.
        let landing = NSRect(origin: next, size: target.size)
        if done || landing.intersects(main.frame) { next = target.origin }
        placeIndicator(at: next)
        if next == target.origin {
            followTarget = nil
            followTimer?.invalidate()
            followTimer = nil
        }
    }

    /// Where the panel was last, to move the circle by as much as it moves.
    private var lastPanelOrigin: NSPoint = .zero

    /// Moves the circle by the panel's move, keeping it where it was beside
    /// the panel. False when that would put it off the screen or on the
    /// panel; then it finds a clear place instead.
    private func carryIndicator(by delta: CGPoint) -> Bool {
        guard app.panelVisible, !indicatorAway, delta != .zero,
              let visible = (main.screen ?? indicator.screen)?.visibleFrame else { return false }
        let moved = indicator.frame.offsetBy(dx: delta.x, dy: delta.y)
        guard visible.contains(moved),
              !moved.insetBy(dx: -(followGap - 1), dy: -(followGap - 1)).intersects(main.frame) else { return false }
        followTarget = nil
        followTimer?.invalidate()
        followTimer = nil
        placeIndicator(at: moved.origin)
        return true
    }

    /// Moves the circle, noting it as this code's own move so it is not
    /// taken for the user dragging it.
    private func placeIndicator(at origin: NSPoint) {
        let rounded = NSPoint(x: origin.x.rounded(), y: origin.y.rounded())
        lastIndicatorOrigin = rounded
        indicator.setFrameOrigin(rounded)
    }

    func resetPositions() {
        panelDetached = false
        positionIndicatorDefault()
        setPanelFrame(NSRect(origin: main.frame.origin, size: panelSize))
        // Back to the standard chat size, then whatever columns are open.
        appliedLeft = 0
        appliedRight = 0
        appliedSettings = 0
        applyLayout()
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

    private var animatingFrame = false
    /// Where the panel is headed, which is its frame once any animation ends.
    private var targetFrame: NSRect?

    /// Moves or resizes the panel, in one step. The frame is never
    /// animated: an animated window frame passes through sizes the content
    /// does not fit, and can be left at one of them.
    private func setPanelFrame(_ wanted: NSRect, animated: Bool = false, _ why: String = #function) {
        // Never past the screen's edges, whatever asked for the size: the
        // panes share the room that fits instead.
        var rect = wanted
        if let visible = (main.screen ?? targetScreen)?.visibleFrame {
            rect = PaneWidths.clamp(wanted, to: visible)
        }
        lastProgrammaticOrigin = rect.origin
        targetFrame = rect
        // The frame is set and the content laid out on its own next pass,
        // not inside this call.
        main.setFrame(rect, display: false)
        trace("set \(why) want=\(Self.text(rect)) got=\(Self.text(main.frame))")
        keepIndicatorClear()
    }

    // MARK: Layout trace
    //
    // Every change of the panel's frame is written to layout.log beside the
    // app, so a wrong size can be traced to what asked for it.

    private static let traceURL = Bundle.main.bundleURL.deletingLastPathComponent()
        .appendingPathComponent("layout.log")
    private var traceStarted = false

    private static func text(_ rect: NSRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
    }

    /// A line in the layout trace from outside the controller.
    func note(_ message: String) { trace(message) }

    private func trace(_ message: String) {
        let state = "side=\(app.sidePanel.map { "\($0)" } ?? "none") bar=\(app.sidebarPinned) "
            + "settings=\(app.showSettings) compact=\(app.compact) open=\(app.pillExpanded) zoom=\(frameBeforeZoom != nil)"
        let stamp = String(format: "%.2f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        let line = "\(stamp) \(message) | \(state)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !traceStarted {
            traceStarted = true
            try? data.write(to: Self.traceURL)
            return
        }
        if let handle = try? FileHandle(forWritingTo: Self.traceURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }

    /// The usual width of the pinned sidebar.
    static let sidebarWidth: CGFloat = 236

    /// Width the right column takes now, 0 when it is closed.
    private var sideWidth: CGFloat {
        app.sidePanel.map { app.width(of: $0) } ?? 0
    }

    /// A divider was dragged: the sidebar's (left) or the right column's.
    /// The column takes the width asked for, within limits. The chat column
    /// gives up the room until it is at its narrowest, and from there the
    /// panel itself grows on that side, as far as the screen allows.
    func dragColumn(left: Bool, to wanted: CGFloat) {
        // Works at any panel size, the full screen included. The panel
        // itself stays as it is: the divider follows the pointer and the
        // chat column gives up or takes back the room.
        if app.compact, !app.pillExpanded { return }
        if left, !app.sidebarPinned { return }
        guard left || app.sidePanel != nil else { return }
        let wide = app.sidePanel == .browser || app.sidePanel == .workspace || app.sidePanel == .board
        let least: CGFloat = left ? Self.sidebarLeast : (wide ? 320 : 220)
        let other = left ? appliedRight : appliedLeft
        // The chat column is always left with at least its narrowest, and
        // the gaps between the panels their room.
        let room = main.frame.width - other - Self.chatLeast - gapsWidth

        // Dragged nearly all the way across: the browser or workspace takes
        // the whole panel and the chat steps aside, as a pane collapses in
        // an editor. The chat comes back from the button in the top bar.
        if !left, wide, wanted > main.frame.width - other - 150 {
            if !app.sideFull { app.sideFull = true }
            return
        }

        let most = left ? min(400, room) : room
        let width = max(least, min(wanted, max(least, most)))
        if left {
            app.sidebarWidth = width
            appliedLeft = width
        } else {
            if let mode = app.sidePanel { app.setWidth(width, of: mode) }
            appliedRight = width
        }
    }

    /// A divider was double-clicked: the column goes back to its usual width.
    func resetColumn(left: Bool) {
        if left {
            app.sidebarWidth = Self.sidebarWidth
        } else if let mode = app.sidePanel {
            app.setWidth(mode.width, of: mode)
        }
        applyLayout()
    }

    // MARK: Layout: one size for each arrangement
    //
    // The panel is made of up to three columns: the sidebar, the chat, and
    // the column on the right (details or the browser). Each has a set
    // width, and the panel is always exactly their sum, so every
    // arrangement has a proper size instead of whatever was left over from
    // the last one:
    //
    //   chat only                     560
    //   sidebar + chat                236 + 560
    //   chat + details                560 + 300
    //   chat + browser                560 + 460
    //   sidebar + chat + browser      236 + 560 + 460
    //   settings                      at least 700 for the chat column
    //
    // The chat column stays where it is on screen: the sidebar opens to its
    // left and the right column to its right. Dragging the panel's edge
    // changes the chat column's width, which is then kept.

    /// The chat column's width when nothing has resized it.
    private static let chatWidth: CGFloat = 560
    /// The widest the chat column is kept at when columns open or close.
    private static let chatMaxWidth: CGFloat = 900
    /// Width Settings are laid out for.
    private static let settingsWidth: CGFloat = 700
    /// Height the browser needs to be useful.
    private static let browserMinHeight: CGFloat = 680

    /// What the last layout added around the chat column.
    private var appliedLeft: CGFloat = 0
    private var appliedRight: CGFloat = 0
    private var appliedSettings: CGFloat = 0

    /// Notes which columns are open. The panel is never resized for them:
    /// opening Settings, the sidebar, details or the browser leaves the
    /// panel exactly the size it is, and the columns share the room it has.
    /// Its size changes only by hand: dragging an edge or a divider, the
    /// green button, a double-click on the top bar.
    ///
    /// `base` is a frame to go to when the panel is coming back from the
    /// pill or from filling the screen; that is putting a size back, not
    /// choosing a new one.
    func applyLayout(from base: NSRect? = nil) {
        if app.compact, !app.pillExpanded { return }
        appliedLeft = app.sidebarPinned ? app.sidebarWidth : 0
        appliedRight = sideWidth
        appliedSettings = 0
        // The panel may not be narrower than its open columns at their
        // narrowest. That is the one case it is widened without being
        // asked: by just enough that nothing is cut off, never to a
        // "preferred" size.
        // Capped to the screen: a floor wider than the screen held the
        // panel past its right edge. Past that, panes are put away instead.
        let screenWidth = (main.screen ?? targetScreen)?.visibleFrame.width ?? .greatestFiniteMagnitude
        setFloor(NSSize(width: min(neededWidth, screenWidth), height: panelMinSize.height))
        if let base {
            setPanelFrame(base)
        }
        enforceFit()
    }

    /// The least width the open columns need, with the gaps between them.
    private var neededWidth: CGFloat {
        if app.codeMode, app.sidePanel == .workspace, !app.showSettings {
            // In code the workspace needs its activity bar, the file list
            // and room for the code, and the details (when open) sit
            // beside it at their own width. The sidebar is counted at its
            // set width, which it keeps while the panel has room.
            let left = app.sidebarPinned ? max(Self.sidebarLeast, app.sidebarWidth) : 0
            var right = Self.codeWorkspaceLeast
            if app.codeDetails {
                let stored = UserDefaults.standard.object(forKey: "codeDetailsWidth") as? Double ?? 280
                right += CGFloat(min(max(stored, 220), 460)) + Theme.panelGap
            }
            return max(panelMinSize.width, left + Self.chatLeast + right + gapsWidth)
        }
        if app.advancedMode, app.sidePanel == .board, !app.showSettings {
            // In Advanced the board has the middle, as the workspace has
            // in code, and needs room for two of its columns at least.
            let left = app.sidebarPinned ? max(Self.sidebarLeast, app.sidebarWidth) : 0
            return max(panelMinSize.width, left + Self.chatLeast + Self.boardLeast + gapsWidth)
        }
        let left = app.sidebarPinned ? Self.sidebarLeast : 0
        let right = app.sidePanel.map(Self.sideLeast) ?? 0
        return max(panelMinSize.width, left + Self.chatLeast + right + gapsWidth)
    }

    /// The least the workspace takes in code: the activity bar, the files
    /// and room for the code beside them.
    static var codeWorkspaceLeast: CGFloat { 40 + 150 + Theme.panelGap + 320 }

    /// The least the board takes in Advanced: its header on one line and
    /// two columns of tasks side by side.
    static let boardLeast: CGFloat = 520

    /// The room the gaps between the panels take: one at each side of the
    /// window and one between every two columns.
    private var gapsWidth: CGFloat {
        let columns = 1 + (app.sidebarPinned ? 1 : 0) + (app.sidePanel != nil ? 1 : 0)
        return CGFloat(columns + 1) * Theme.panelGap
    }

    /// Widens the panel if it has ended up too narrow for its columns.
    private func enforceFit() {
        guard !animatingFrame, !main.inLiveResize else { return }
        if app.compact, !app.pillExpanded { return }
        var frame = main.frame
        var needed = neededWidth
        if let screen = main.screen?.visibleFrame { needed = min(needed, screen.width) }
        let tooShort = frame.height < panelMinSize.height - 0.5
        guard frame.width < needed - 0.5 || tooShort else { return }
        frame.size.width = max(frame.width, needed)
        if tooShort {
            // The top edge stays where it is.
            frame.origin.y = frame.maxY - panelMinSize.height
            frame.size.height = panelMinSize.height
        }
        if let screen = main.screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, screen.minX), screen.maxX - frame.width)
        }
        setPanelFrame(frame)
    }

    /// The sidebar was pinned or unpinned.
    func setSidebar(_ open: Bool) {
        applyLayout()
    }

    /// The column on the right opened, closed or changed kind.
    func setRightRoom(_ width: CGFloat) {
        applyLayout()
    }

    /// Settings opened or closed.
    func setSettingsRoom(_ wanted: Bool) {
        applyLayout()
    }

    private var frameBeforeZoom: NSRect?
    private var frameBeforeCompact: NSRect?
    /// The pill the panel shrinks to in compact mode.
    private let pillSize = NSSize(width: 320, height: 46)
    private var hoverWork: Task<Void, Never>?

    /// Enlarges the panel to fill most of the screen, or puts it back.
    func toggleZoom() {
        trace("zoom asked")
        if app.compact { setCompact(false) }
        if let previous = frameBeforeZoom {
            frameBeforeZoom = nil
            app.zoomed = false
            // Back to the size it had, then fitted to the columns open now,
            // which may have changed while it was enlarged.
            applyLayout(from: previous)
            return
        }
        guard let visible = (main.screen ?? targetScreen)?.visibleFrame else { return }
        frameBeforeZoom = main.frame
        app.zoomed = true
        // The whole screen under the menu bar, as the green button and a
        // double-click on a title bar do in any Mac app.
        trace("zoom to \(Self.text(visible))")
        setPanelFrame(visible, animated: true)
    }

    // MARK: The session kept between launches
    //
    // Which chat is open, the sidebar, where the panel sits and whether it
    // fills the screen are saved a moment after any of them changes, not
    // only on quitting: a force-quit or a crash never reaches
    // applicationWillTerminate. AppKit keeps the frame under
    // "CompanionPanel" as it changes; it is saved again here with the rest.

    private enum Session {
        static let chat = "sessionOpenChat"
        static let sidebar = "sessionSidebarPinned"
        static let detached = "sessionPanelDetached"
        static let zoomedFrom = "sessionFrameBeforeZoom"
    }
    private var sessionSave: Task<Void, Never>?

    /// Puts back the chat, the sidebar and the zoom saved last time. The
    /// frame and where the panel sits are put back as the panel is made.
    /// Called once at launch, after AppState is set up, since opening a
    /// chat goes through AppState.
    func restoreSession() {
        let d = UserDefaults.standard
        if let saved = d.string(forKey: Session.chat), let id = UUID(uuidString: saved) {
            // A chat deleted since, or one never written because nothing was
            // said in it, is not found and the new chat stays.
            app.openConversation(id)
        }
        if d.bool(forKey: Session.sidebar), !app.sidebarPinned {
            app.sidebarPinned = true
            setSidebar(true)
        }
        if frameBeforeZoom == nil, let saved = d.string(forKey: Session.zoomedFrom),
           let visible = (main.screen ?? targetScreen)?.visibleFrame {
            let before = NSRectFromString(saved)
            // The size to go back to must still be usable on a screen
            // attached now, or leaving the zoom would lose the panel.
            if before.width >= panelMinSize.width, before.height >= panelMinSize.height,
               NSScreen.screens.contains(where: { $0.visibleFrame.intersects(before) }) {
                frameBeforeZoom = before
                app.zoomed = true
                // Fitted to this screen, which may not be the one it filled before.
                setPanelFrame(visible)
            }
        }
    }

    /// Saves the session once things settle, so a drag or a resize writes
    /// once at its end and not on every frame it passes through.
    private func scheduleSessionSave() {
        sessionSave?.cancel()
        sessionSave = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.saveSession()
        }
    }

    /// Saves the session now: when the wait above ends, and on quitting.
    func saveSession() {
        sessionSave?.cancel()
        sessionSave = nil
        let d = UserDefaults.standard
        d.set(app.conversation.id.uuidString, forKey: Session.chat)
        d.set(app.sidebarPinned, forKey: Session.sidebar)
        d.set(panelDetached, forKey: Session.detached)
        if let before = frameBeforeZoom {
            d.set(NSStringFromRect(before), forKey: Session.zoomedFrom)
        } else {
            d.removeObject(forKey: Session.zoomedFrom)
        }
        main.saveFrame(usingName: "CompanionPanel")
    }

    /// Compact mode: the panel shrinks to a small pill at its top edge, or
    /// comes back to full size. The pill opens while the pointer is on it.
    func setCompact(_ on: Bool) {
        guard on != app.compact else { return }
        hoverWork?.cancel()
        if on {
            if frameBeforeZoom != nil { toggleZoom() }
            frameBeforeCompact = main.frame
            app.compact = true
            app.pillExpanded = false
            setFloor(pillSize)
            setPanelFrame(pillFrame(under: main.frame), animated: true)
        } else {
            let anchor = main.frame
            app.compact = false
            app.pillExpanded = false
            setFloor(panelMinSize)
            let full = fullFrame(under: anchor)
            frameBeforeCompact = nil
            applyLayout(from: full)
        }
    }

    /// The pointer came onto the pill or left the opened panel. Opening is
    /// immediate; closing waits a moment, and does not happen while the
    /// user is typing in the panel or the agent is waiting for an answer.
    func hoverPill(_ inside: Bool) {
        guard app.compact else { return }
        hoverWork?.cancel()
        if inside {
            guard !app.pillExpanded else { return }
            let anchor = main.frame
            app.pillExpanded = true
            setFloor(panelMinSize)
            // Fitted to the columns open now, which may have changed while
            // it was a pill.
            applyLayout(from: fullFrame(under: anchor))
        } else if app.pillExpanded {
            hoverWork = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self, !Task.isCancelled, self.app.compact, self.app.pillExpanded,
                      !self.main.isKeyWindow, self.app.pendingApproval == nil, self.app.pendingQuestion == nil,
                      !self.main.frame.contains(NSEvent.mouseLocation) else { return }
                let anchor = self.main.frame
                self.app.pillExpanded = false
                self.setFloor(self.pillSize)
                self.setPanelFrame(self.pillFrame(under: anchor), animated: true)
            }
        }
    }

    /// The pill, centered on a frame's top edge.
    private func pillFrame(under frame: NSRect) -> NSRect {
        NSRect(x: frame.midX - pillSize.width / 2,
               y: frame.maxY - pillSize.height,
               width: pillSize.width,
               height: pillSize.height)
    }

    /// The full panel hanging from a frame's top edge, kept on screen.
    private func fullFrame(under frame: NSRect) -> NSRect {
        let size = frameBeforeCompact?.size ?? panelSize
        var rect = NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                          width: size.width, height: size.height)
        if let visible = (main.screen ?? targetScreen)?.visibleFrame {
            rect.origin.x = min(max(rect.origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            rect.origin.y = max(rect.origin.y, visible.minY + 8)
        }
        return rect
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

    /// Shows the panel: the window fades in while its content springs up
    /// to full size (the content watches `panelVisible`).
    func showPanel() {
        guard !main.isVisible else {
            // Already up, or caught half-way through fading out.
            main.orderFrontRegardless()
            fade(to: 1)
            app.panelVisible = true
            return
        }
        // Placed beside the circle, on a side with room, so the circle
        // never has to move (once the panel was dragged, it stays put).
        if !panelDetached { snapPanelToIndicator() }
        main.alphaValue = 0
        main.childWindows?.forEach { $0.alphaValue = 0 }
        main.orderFrontRegardless()
        app.panelVisible = true
        keepIndicatorClear()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            fade(to: 1)
        }, completionHandler: { [weak self] in
            // What is attached to the panel ends where the panel does,
            // however the fade went.
            Task { @MainActor in
                guard let self else { return }
                self.main.childWindows?.forEach { FloatingPanel.attach($0, to: self.main) }
            }
        })
    }

    /// Hides the panel: the content settles back and the window fades out.
    func hidePanel() {
        guard main.isVisible else {
            app.panelVisible = false
            return
        }
        app.panelVisible = false
        keepIndicatorClear()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            fade(to: 0)
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.app.panelVisible else { return }
                self.main.orderOut(nil)
                self.main.alphaValue = 1
                self.main.childWindows?.forEach { FloatingPanel.attach($0, to: self.main) }
            }
        })
    }

    /// Fades the panel, and the windows attached to it with it, in the
    /// animation under way. Always through `animator()`: setting a window's
    /// `alphaValue` on its own jumps there at once.
    private func fade(to alpha: CGFloat) {
        main.animator().alphaValue = alpha
        main.childWindows?.forEach { $0.animator().alphaValue = alpha }
    }

    func togglePanel() {
        app.panelVisible ? hidePanel() : showPanel()
    }

    /// Where the panel and the floating circle sit among other windows:
    /// above everything or level with ordinary windows, and on every
    /// desktop or only the one they are on.
    func applyPlacement(onTop: Bool, everywhere: Bool) {
        OrbitDock.shared.setLevel(onTop ? .statusBar : .normal)
        WindowStacking.panelFloats(onTop)
        for window in [main, indicator] {
            window.isFloatingPanel = onTop
            window.level = onTop ? .statusBar : .normal
            window.collectionBehavior = everywhere
                ? [.canJoinAllSpaces, .fullScreenAuxiliary]
                : [.managed, .fullScreenAuxiliary]
        }
        // A change of level takes effect at once only if the windows are
        // put back in order.
        if !indicatorAway { indicator.orderFrontRegardless() }
        if app.panelVisible { main.orderFrontRegardless() }
    }

    func applySharing(_ hide: Bool) {
        let type: NSWindow.SharingType = hide ? .none : .readOnly
        indicator.sharingType = type
        main.sharingType = type
    }

    private var clickThroughMonitor: Any?

    /// Click-through: the panel ignores the mouse entirely so you can click
    /// and select whatever is behind it. The circle stays clickable.
    ///
    /// One spot still answers: the click-through button itself. The panel
    /// cannot receive the click while it ignores the mouse, so clicks are
    /// watched from outside, and one that lands on the button turns
    /// click-through off again.
    func applyClickThrough(_ on: Bool) {
        main.ignoresMouseEvents = on
        if let monitor = clickThroughMonitor {
            NSEvent.removeMonitor(monitor)
            clickThroughMonitor = nil
        }
        guard on else { return }
        clickThroughMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.app.panelVisible else { return }
                let point = NSEvent.mouseLocation
                let frame = self.main.frame
                // The button's frame is measured from the panel's top left.
                let local = CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
                if self.app.clickThroughButtonFrame.insetBy(dx: -4, dy: -4).contains(local) {
                    self.app.clickThrough = false
                }
            }
        }
    }
}


/// The panel's content takes the first click as a click, also when the
/// panel was not the window in front: otherwise a click on a chat in the
/// sidebar only brought the panel forward and a second click was needed.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
