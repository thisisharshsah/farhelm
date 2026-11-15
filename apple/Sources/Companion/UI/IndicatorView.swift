import SwiftUI

/// The small glass circle that sits below the camera. Pulses while listening,
/// shows a dot when a suggestion is waiting and the panel is hidden.
/// Click to expand or collapse the main panel, drag to move it.
struct IndicatorView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var dock = OrbitDock.shared

    /// The mark's size, and its window's: a little room around the mark so
    /// its pulse is never cut off. The one place the circle's size is set.
    static let mark: CGFloat = 40
    static let side: CGFloat = 48

    /// Its mood: amber while it waits for you, mint or rose for a moment
    /// after a task, the look's own colors otherwise.
    private var mood: Color? {
        if !app.chatsWaiting.isEmpty { return Theme.amber }
        if !app.anyAgentRunning, let finished = dock.finished { return finished.failed ? Theme.rose : Theme.mint }
        return nil
    }
    private var waiting: Bool { !app.chatsWaiting.isEmpty }

    private var working: Bool { app.isReplying || app.isAnsweringScreen }
    /// Answering, or doing something on the Mac.
    private var busy: Bool { working || app.anyAgentRunning }

    var body: some View {
        ZStack {
            // Next to invisible, and there only so the whole circle takes the
            // mouse: a window passes clicks through wherever it is fully
            // clear, and the mark alone is mostly gaps.
            // 1/255: no visible background at all, yet the window still
            // takes clicks and drags across the whole circle.
            Circle()
                .fill(Color.black.opacity(1.0 / 255.0))
                .frame(width: Self.mark, height: Self.mark)
            // The mark floats bare: no disc, no ring, nothing behind it. It
            // is barely drifting when idle, turning while it listens, and
            // busy while it works.
            // Thinking turns slowly, working quickly, waiting on you almost
            // stops and turns amber.
            OrbitMark(speed: waiting ? 0.08 : (busy ? 2.6 : (app.isListening ? 1.0 : 0.12)),
                      dots: waiting ? 2 : (busy ? 7 : (app.isListening ? 4 : 3)),
                      lines: 7,
                      trail: !waiting && (busy || app.isListening),
                      pulse: waiting || busy || app.isListening,
                      tint: mood)
                .frame(width: Self.mark, height: Self.mark)
                .animation(.easeInOut(duration: 0.4), value: mood)

            if !app.panelVisible && app.hasUnseen {
                Circle()
                    .fill(Theme.accentGradient)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
                    .offset(x: Self.mark * 0.32, y: -Self.mark * 0.32)
            }
        }
        .frame(width: Self.side, height: Self.side)
        // The window handles clicks (toggle panel) and drags (move); SwiftUI
        // must not intercept the mouse.
        .allowsHitTesting(false)
    }
}
