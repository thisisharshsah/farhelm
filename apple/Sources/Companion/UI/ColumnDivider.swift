import AppKit
import SwiftUI

/// The gap between two columns, which is also what resizes them: three dots
/// in its middle show where to take hold (see `DividerGrip`). Drag it to
/// give one column more room and the other less; double-click to put the
/// column back to its usual width. The pointer turns into the resize cursor
/// over it.
struct ColumnDivider: View {
    /// The column's width now, read when a drag starts.
    let width: () -> CGFloat
    /// +1 when dragging right widens the column, -1 when it narrows it.
    let direction: CGFloat
    /// Asks for a new width while the divider is dragged.
    let resize: (CGFloat) -> Void
    /// Double-click: back to the usual width.
    let reset: () -> Void
    /// The drag ended; the width can be saved.
    let done: () -> Void

    @State private var hover = false
    @State private var dragging = false
    @State private var start: CGFloat = 0

    var body: some View {
        Color.clear
            .frame(width: Theme.panelGap)
            .frame(maxHeight: .infinity)
            .overlay { DividerGrip(axis: .vertical, hover: hover, dragging: dragging) }
            // The gap is narrow; the part that takes the pointer reaches a
            // little into the panels on either side.
            .overlay {
                DividerHandle(
                    hover: { hover = $0 },
                    began: {
                        start = width()
                        dragging = true
                    },
                    moved: { resize(start + direction * $0) },
                    ended: {
                        dragging = false
                        done()
                    },
                    doubleClick: reset
                )
                .frame(width: Theme.panelGap + 6)
            }
            .zIndex(3)
    }
}

/// The gap between what is above and a panel below it, with the same grip
/// across its middle. Drag it up or down to give the panel more or less
/// height; double-click for the usual one.
struct RowDivider: View {
    /// The panel's height now, read when a drag starts.
    let height: () -> CGFloat
    /// Asks for a new height while the divider is dragged.
    let resize: (CGFloat) -> Void
    let reset: () -> Void
    let done: () -> Void

    @State private var hover = false
    @State private var dragging = false
    @State private var start: CGFloat = 0

    var body: some View {
        Color.clear
            .frame(height: Theme.panelGap)
            .frame(maxWidth: .infinity)
            .overlay { DividerGrip(axis: .horizontal, hover: hover, dragging: dragging) }
            .overlay {
                // Up on the screen is a taller panel.
                DividerHandle(
                    vertical: true,
                    hover: { hover = $0 },
                    began: {
                        start = height()
                        dragging = true
                    },
                    moved: { resize(start + $0) },
                    ended: {
                        dragging = false
                        done()
                    },
                    doubleClick: reset
                )
                .frame(height: Theme.panelGap + 6)
            }
            .zIndex(3)
    }
}

/// Takes the mouse for a divider. It is an AppKit view so that a press on
/// it is never taken for a drag of the whole panel, and so the pointer's
/// place on the screen can be followed while the panel itself resizes.
private struct DividerHandle: NSViewRepresentable {
    /// A line across, dragged up and down, instead of one dragged sideways.
    var vertical = false
    let hover: (Bool) -> Void
    let began: () -> Void
    let moved: (CGFloat) -> Void
    let ended: () -> Void
    let doubleClick: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.handle = self
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.handle = self
    }

    final class HandleView: NSView {
        var handle: DividerHandle?
        private var startX: CGFloat = 0
        private var dragging = false
        /// The pointer's place on the screen, along the way the line moves.
        private var place: CGFloat {
            handle?.vertical == true ? NSEvent.mouseLocation.y : NSEvent.mouseLocation.x
        }
        private var inside = false
        private var area: NSTrackingArea?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: handle?.vertical == true ? .resizeUpDown : .resizeLeftRight)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let fresh = NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self)
            addTrackingArea(fresh)
            area = fresh
        }

        override func mouseEntered(with event: NSEvent) {
            inside = true
            handle?.hover(true)
        }

        override func mouseExited(with event: NSEvent) {
            inside = false
            if !dragging { handle?.hover(false) }
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                handle?.doubleClick()
                handle?.ended()
                return
            }
            startX = place
            dragging = true
            handle?.began()
            handle?.hover(true)
        }

        override func mouseDragged(with event: NSEvent) {
            guard dragging else { return }
            handle?.moved(place - startX)
        }

        override func mouseUp(with event: NSEvent) {
            guard dragging else { return }
            dragging = false
            handle?.ended()
            if !inside { handle?.hover(false) }
        }
    }
}
