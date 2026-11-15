import AppKit
import SwiftUI

// MARK: - The orbit where the agent acts

/// What the agent is doing, for the orbit that shows it.
enum AgentAction {
    case click, type, open

    var label: String {
        switch self {
        case .click: return "Click"
        case .type: return "Type"
        case .open: return "Open"
        }
    }
}

@MainActor
private final class AgentOrbitModel: ObservableObject {
    @Published var action = AgentAction.click
    @Published var shown = false
    /// Bumped each time it plays, so the circles start afresh.
    @Published var run = 0
}

/// The orbit that appears on screen where the agent clicks, types or opens
/// something, so you can see what it is doing and where. It is a small
/// window of its own that never takes the mouse or the keyboard. While
/// typing it is small and rides along with the caret. Settings > Agent
/// turns it off.
@MainActor
final class AgentOrbit {
    static let shared = AgentOrbit()

    private let panel: NSPanel
    private let model = AgentOrbitModel()
    private var hiding: Task<Void, Never>?
    private var following: Task<Void, Never>?
    private static let side: CGFloat = 150

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let content = NSHostingView(rootView: AgentOrbitView(model: model))
        content.sizingOptions = []
        panel.contentView = content
    }

    private var enabled: Bool { AppSettings.shared.agentOrbit }

    /// Shows the orbit once at a place on screen (Cocoa coordinates), for a
    /// click or for something opened. With no place it uses the middle of
    /// the main screen.
    func flash(_ action: AgentAction, at point: CGPoint?) {
        guard enabled else { return }
        following?.cancel()
        show(action, at: point ?? fallback)
        hide(after: 1.25)
    }

    /// Typing has begun: the orbit, small, goes to the caret and stays with
    /// it until `endTyping()`.
    func beginTyping() {
        guard enabled else { return }
        hiding?.cancel()
        following?.cancel()
        show(.type, at: DeviceControl.shared.caretPoint() ?? DeviceControl.shared.focusPoint() ?? fallback)
        following = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 70_000_000)
                guard let self, !Task.isCancelled else { return }
                if let caret = DeviceControl.shared.caretPoint() { self.move(to: caret) }
            }
        }
    }

    func endTyping() {
        following?.cancel()
        following = nil
        guard model.shown else { return }
        hide(after: 0.3)
    }

    private var fallback: CGPoint {
        let frame = NSScreen.main?.visibleFrame ?? .zero
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func move(to point: CGPoint) {
        panel.setFrameOrigin(NSPoint(x: point.x - Self.side / 2, y: point.y - Self.side / 2))
    }

    private func show(_ action: AgentAction, at point: CGPoint) {
        hiding?.cancel()
        // Out of shared screens when Companion is.
        panel.sharingType = AppSettings.shared.hideFromScreenShare ? .none : .readOnly
        model.action = action
        model.run += 1
        move(to: point)
        panel.orderFrontRegardless()
        model.shown = true
    }

    private func hide(after delay: Double) {
        hiding?.cancel()
        hiding = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.model.shown = false
            // Gone from the screen once it has faded.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self.panel.orderOut(nil)
        }
    }
}

private struct AgentOrbitView: View {
    @ObservedObject var model: AgentOrbitModel

    private var typing: Bool { model.action == .type }

    var body: some View {
        // Small while typing, so it sits on the caret without covering the words.
        let size: CGFloat = typing ? 38 : 90
        ZStack {
            if !typing {
                // A ripple, as the action lands.
                Circle()
                    .strokeBorder(Theme.accent.opacity(model.shown ? 0 : 0.5), lineWidth: 1.5)
                    .frame(width: model.shown ? size * 1.25 : size * 0.5, height: model.shown ? size * 1.25 : size * 0.5)
                    .animation(.easeOut(duration: 0.9), value: model.shown)
            }
            OrbitMark(speed: 4.2, dots: typing ? 3 : 6, lines: typing ? 5 : 8, trail: true, pulse: false)
                .frame(width: size, height: size)
                .id(model.run)
            Text(model.action.label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 9)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(Color(red: 0.06, green: 0.05, blue: 0.10).opacity(0.92)))
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.55), lineWidth: 0.75))
                .offset(y: size / 2 + 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(model.shown ? 1 : 0.55)
        .opacity(model.shown ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: model.shown)
        .allowsHitTesting(false)
    }
}
