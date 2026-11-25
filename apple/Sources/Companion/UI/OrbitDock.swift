import AppKit
import Combine
import SwiftUI

/// How the last agent task ended, for the orbit's brief done or failed look.
struct AgentFinish: Equatable {
    let id = UUID()
    let failed: Bool
    let task: String
    let answer: String
}

/// What rides with the orbit while the panel is hidden: a status card with
/// the chat's name and what the agent is doing, waiting on or has just
/// finished. It shows while there is something to say, and when the
/// pointer is on the orbit (or it is tapped); clicking it opens the chat.
/// It lives in a window of its own that moves with the orbit, below it
/// (above it near the bottom of the screen), and is gone whenever the
/// panel is showing, so it can never cover the panel.
@MainActor
final class OrbitDock: ObservableObject {
    static let shared = OrbitDock()

    /// The pointer is on the orbit or the toolbar.
    @Published private(set) var hovering = false
    /// The dock sits above the orbit, so its content hangs from the bottom.
    @Published private(set) var above = false
    /// The task that just ended, shown for a few seconds.
    @Published private(set) var finished: AgentFinish?

    private var window: FloatingPanel?
    private weak var orbit: NSWindow?
    private weak var app: AppState?
    private var bag = Set<AnyCancellable>()
    private var hoverTimer: Timer?
    private var lastInside = Date.distantPast
    private var clearFinished: Task<Void, Never>?

    static let size = NSSize(width: 330, height: 64)

    private init() {}

    /// Starts riding with the orbit's window.
    func attach(to orbit: NSWindow, app: AppState) {
        self.orbit = orbit
        self.app = app
        let window = FloatingPanel(size: Self.size, movable: false)
        window.contentView = NSHostingView(rootView: OrbitDockView()
            .environmentObject(app)
            .preferredColorScheme(.dark))
        window.level = orbit.level
        self.window = window

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: orbit,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.place() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: orbit,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        // Anything that changes what it should show.
        app.$panelVisible.sink { [weak self] _ in Task { @MainActor in self?.update() } }.store(in: &bag)
        // Tasks in every chat: their changes reach the app's own, which
        // is looked at a few times a second at most.
        app.objectWillChange
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in Task { @MainActor in self?.update() } }
            .store(in: &bag)
        update()
    }

    /// A task ended: the orbit shows how, in color, for a few seconds.
    func noteFinished(_ finish: AgentFinish) {
        finished = finish
        clearFinished?.cancel()
        clearFinished = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled else { return }
            self.finished = nil
            self.update()
        }
        update()
    }

    /// Shows the toolbar now, as a tap on the orbit does; it goes again
    /// once the pointer has left.
    func reveal() {
        lastInside = Date()
        if !hovering {
            hovering = true
            update()
        }
    }

    /// Something to say: the agent at work, waiting, or just finished.
    var hasStatus: Bool {
        guard let app else { return false }
        return app.anyAgentRunning || app.leadJob?.pendingApproval != nil || app.leadJob?.pendingQuestion != nil || finished != nil
    }

    /// The level follows the orbit's (on top of everything, or not).
    func setLevel(_ level: NSWindow.Level) {
        window?.level = level
    }

    // MARK: Showing and hiding

    private func update() {
        guard let app, let window, let orbit else { return }
        let hidden = !app.panelVisible && orbit.isVisible
        // While the panel is hidden the pointer is watched, a few times a
        // second, to tell when it is on the orbit.
        if hidden, hoverTimer == nil {
            let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.watchPointer() }
            }
            RunLoop.main.add(timer, forMode: .common)
            hoverTimer = timer
        } else if !hidden {
            hoverTimer?.invalidate()
            hoverTimer = nil
            hovering = false
        }
        let show = hidden && (hovering || hasStatus)
        if show {
            place()
            if !window.isVisible {
                window.alphaValue = 0
                window.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    window.animator().alphaValue = 1
                }
            }
        } else if window.isVisible {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.14
                window.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, let window = self.window else { return }
                    // Shown again while it faded: leave it.
                    if window.alphaValue < 0.05 { window.orderOut(nil) }
                }
            })
        }
    }

    private func watchPointer() {
        guard let orbit, let window else { return }
        let point = NSEvent.mouseLocation
        var inside = orbit.frame.insetBy(dx: -4, dy: -4).contains(point)
        // Once it is showing, moving down onto the toolbar keeps it.
        if hovering, window.isVisible, window.frame.contains(point) { inside = true }
        if inside { lastInside = Date() }
        // A moment's grace, so crossing the gap does not close it.
        let now = inside || Date().timeIntervalSince(lastInside) < 0.35
        if now != hovering {
            hovering = now
            update()
        }
    }

    /// Below the orbit, centered on it; above it when there is no room below.
    private func place() {
        guard let orbit, let window,
              let visible = (orbit.screen ?? NSScreen.main)?.visibleFrame else { return }
        let size = Self.size
        var x = orbit.frame.midX - size.width / 2
        x = min(max(x, visible.minX + 6), visible.maxX - size.width - 6)
        let gap: CGFloat = 2
        var y = orbit.frame.minY - gap - size.height
        let up = y < visible.minY
        if up { y = orbit.frame.maxY + gap }
        if up != above { above = up }
        window.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }
}

/// The dock's content: the status card, hanging from the edge nearest the
/// orbit. Everywhere else it is clear, and clicks there go to whatever is
/// underneath.
struct OrbitDockView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var dock = OrbitDock.shared

    var body: some View {
        VStack(spacing: 0) {
            if dock.above { Spacer(minLength: 0) }
            card
            if !dock.above { Spacer(minLength: 0) }
        }
        .frame(width: OrbitDock.size.width, height: OrbitDock.size.height)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: dock.hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: dock.hasStatus)
    }

    private enum Status {
        case idle, working, waiting, done, failed
    }

    private var status: Status {
        // Waiting on the person, not on a supervisor answering for them.
        if app.leadJob?.waitsOnPerson == true { return .waiting }
        if app.anyAgentRunning { return .working }
        if let finished = dock.finished { return finished.failed ? .failed : .done }
        return .idle
    }

    /// The chat's name, which says what it is about better than the start
    /// of a long message; the task's first line when the chat has no name.
    private var title: String {
        let name = app.conversation.title
        if !name.isEmpty, name != Conversation.defaultTitle { return name }
        let task = app.anyAgentRunning ? (app.leadJob?.task ?? "") : (dock.finished?.task ?? app.leadJob?.task ?? "")
        let line = task.components(separatedBy: .newlines).first ?? ""
        return line.isEmpty ? "Companion" : line
    }

    private var subtitle: String {
        if let job = app.leadJob, job.waitsOnPerson {
            if let question = job.pendingQuestion { return question.question }
            return "Waiting for you to allow a step"
        }
        if app.anyAgentRunning { return app.leadJob?.status ?? "Working" }
        if let finished = dock.finished {
            let first = finished.answer.components(separatedBy: .newlines)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            return (finished.failed ? "Stopped · " : "Done · ") + MarkdownNotes.plain(first)
        }
        return "Click to open the chat"
    }

    private var tint: Color? {
        switch status {
        case .waiting: return Theme.amber
        case .done: return Theme.mint
        case .failed: return Theme.rose
        default: return nil
        }
    }

    private var phase: LoadingMark.Phase {
        switch status {
        case .idle: return .idle
        case .working: return .working
        case .waiting: return .waiting
        case .done: return .done
        case .failed: return .failed
        }
    }

    @ViewBuilder
    private var card: some View {
        if dock.hovering || dock.hasStatus {
            Button { app.overlay?.showPanel() } label: {
                HStack(spacing: 10) {
                    LoadingMark(state: phase, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ink.opacity(0.95))
                            .lineLimit(1)
                        Group {
                            if app.anyAgentRunning, app.leadJob?.waitsOnPerson != true,
                               let until = app.leadJob?.statusUntil {
                                // A wait in place counts down here alone.
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text(subtitle + " in " + WorkTrail.duration(until.timeIntervalSince(context.date)))
                                }
                            } else {
                                Text(subtitle)
                            }
                        }
                            .font(.system(size: 12))
                            .foregroundStyle(tint ?? Theme.ink.opacity(0.6))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(height: 52)
                .frame(maxWidth: OrbitDock.size.width - 8)
                .background(Capsule().fill(Theme.shade.opacity(0.55)))
                .liquidGlass(in: Capsule())
                .overlay(Capsule().strokeBorder((tint ?? Color.white).opacity(tint == nil ? 0.14 : 0.45), lineWidth: 0.8))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Open the chat")
            .transition(.scale(scale: 0.95, anchor: dock.above ? .bottom : .top).combined(with: .opacity))
        }
    }
}
