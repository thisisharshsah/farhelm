import SwiftUI

/// A ball of fire in the look's own colors. `heat` runs from 0, an ember,
/// to 1, burning at its brightest: it grows a brighter heart and a wider
/// glow, and flickers faster.
public struct Fireball: View {
    var heat: Double
    var size: CGFloat = 14
    /// Whether it burns at all. Left to the model, it is a quiet ember.
    var alive = true
    /// Whether it flickers. A ball that sits in view all the time (the chat
    /// box's effort button) burns still and flickers only while looked at:
    /// a flicker redraws its window thirty times a second for as long as
    /// it runs.
    var flickers = true

    public init(heat: Double, size: CGFloat = 14, alive: Bool = true, flickers: Bool = true) {
        self.heat = heat
        self.size = size
        self.alive = alive
        self.flickers = flickers
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        Group {
            if alive && flickers && !reduceMotion {
                // The flicker is worked out from the clock each frame, not
                // animated: an animation would also catch the ball's place
                // when the window or the bar around it is resized, and
                // carry it across the screen.
                let period = 0.9 - 0.5 * min(max(heat, 0), 1)
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate / period * .pi
                    ball(beat: (sin(phase) + 1) / 2)
                }
            } else {
                ball(beat: 0)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }

    /// The ball at a point of its flicker, 0 to 1.
    private func ball(beat: Double) -> some View {
        let warmth = min(max(heat, 0), 1)
        let color = Theme.accent
        return ZStack {
            // The glow around it.
            Circle()
                .fill(RadialGradient(colors: [color.opacity(alive ? 0.30 + 0.35 * warmth : 0.12), color.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: size * (0.75 + 0.45 * warmth)))
                .frame(width: size * (1.5 + 0.9 * warmth), height: size * (1.5 + 0.9 * warmth))
                .scaleEffect(0.92 + 0.16 * beat)
            // The ball: a bright heart, the look's color, a soft edge.
            Circle()
                .fill(RadialGradient(stops: [
                    .init(color: Color.white.opacity(alive ? 0.55 + 0.45 * warmth : 0.25), location: 0),
                    .init(color: Theme.lilac.opacity(alive ? 0.95 : 0.5), location: 0.28 + 0.12 * warmth),
                    .init(color: color.opacity(alive ? 0.95 : 0.45), location: 0.68),
                    .init(color: color.opacity(0), location: 1)
                ], center: UnitPoint(x: 0.5, y: 0.52), startRadius: 0, endRadius: size / 2))
                .frame(width: size, height: size)
                .scaleEffect(0.97 + 0.07 * beat)
        }
        .frame(width: size, height: size)
    }
}

