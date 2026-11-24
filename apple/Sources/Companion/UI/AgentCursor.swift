import AppKit
import SwiftUI

/// The agent's own pointer on the screen while it works in other apps:
/// it glides to the control it is about to press or the field it types
/// into, pulses on a press, and fades once the agent is still. It never
/// takes a click, and it is kept out of screen sharing whenever Companion
/// itself is (Settings).
@MainActor
final class AgentCursor {
    static let shared = AgentCursor()

    private let panel: NSPanel
    private let model = CursorModel()
    private var fade: Task<Void, Never>?
    private static let size = NSSize(width: 140, height: 64)

    private init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: CursorView(model: model))
    }

    /// Glides to `point` (Cocoa screen coordinates, from the bottom left)
    /// and waits for the glide, so the step after it is seen to follow.
    func move(to point: CGPoint, note: String, press: Bool) async {
        panel.sharingType = AppSettings.shared.hideFromScreenShare ? .none : .readOnly
        model.note = note
        let frame = NSRect(x: point.x - 4, y: point.y - Self.size.height + 2, width: Self.size.width, height: Self.size.height)
        if !panel.isVisible {
            // From the middle of the screen it is on, the first time.
            let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
            let middle = screen.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? point
            panel.setFrame(NSRect(x: middle.x, y: middle.y - Self.size.height, width: Self.size.width, height: Self.size.height), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        await NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.38
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            self.panel.animator().setFrame(frame, display: true)
            self.panel.animator().alphaValue = 1
        }, completionHandler: nil)
        try? await Task.sleep(nanoseconds: 400_000_000)
        if press { model.pressed += 1 }
        fadeLater()
    }

    private func fadeLater() {
        fade?.cancel()
        fade = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                self.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.panel.alphaValue == 0 else { return }
                    self.panel.orderOut(nil)
                }
            })
        }
    }
}

private final class CursorModel: ObservableObject {
    @Published var note = ""
    @Published var pressed = 0
}

private struct CursorView: View {
    @ObservedObject var model: CursorModel
    @State private var ring = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .strokeBorder(Theme.accent, lineWidth: 2)
                .frame(width: 30, height: 30)
                .scaleEffect(ring ? 1.7 : 0.3)
                .opacity(ring ? 0 : 0.95)
                .offset(x: -11, y: -13)
            CursorArrow()
                .fill(Theme.accent)
                .overlay(CursorArrow().stroke(Color.white, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round)))
                .frame(width: 22, height: 22)
            if !model.note.isEmpty {
                Text(model.note)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 7)
                    .frame(height: 19)
                    .background(Capsule().fill(Theme.accent))
                    .frame(maxWidth: 118, alignment: .leading)
                    .offset(x: 16, y: 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.pressed) { _, _ in
            ring = false
            withAnimation(.easeOut(duration: 0.55)) { ring = true }
        }
    }
}

/// An arrow pointer, its tip at the top left.
private struct CursorArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: 0.12 * w, y: 0.08 * h))
        path.addLine(to: CGPoint(x: 0.86 * w, y: 0.5 * h))
        path.addLine(to: CGPoint(x: 0.53 * w, y: 0.58 * h))
        path.addLine(to: CGPoint(x: 0.38 * w, y: 0.9 * h))
        path.closeSubpath()
        return path
    }
}
