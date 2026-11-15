import AppKit
import Combine
import QuartzCore
import SwiftUI

// MARK: - Motion that runs in Core Animation
//
// SwiftUI draws its animations itself, a frame at a time: while one runs,
// its window is updated on every display frame, and on the Mac every update
// is a layout pass over the whole window. A dot that pulsed forever kept the
// main thread and the WindowServer busy for as long as it was on screen, and
// everything else in the app lagged behind it.
//
// The views here hand their motion to Core Animation instead. A layer
// animation runs in the render server once it is added, so the app does no
// work per frame, and values that change many times a second (the audio
// level) are set on layers directly, with no SwiftUI update at all. Anything
// that moves for as long as it is shown belongs here, never in a
// `repeatForever` animation.

/// A dot that breathes or ripples, or a ring that spreads, for as long as
/// it is shown.
struct Pulse: View {
    enum Kind: Equatable {
        /// The dot fades to `low` and back.
        case breathe(low: Float)
        /// A halo this wide grows out of the dot and fades.
        case ripple(halo: CGFloat)
        /// No dot: a ring with this line grows `grow` times as wide and fades.
        case ring(line: CGFloat, grow: CGFloat)
    }

    var kind: Kind
    var color: Color
    /// The dot's width, or the ring's.
    var size: CGFloat
    /// Seconds for one beat: one way for a breath, out and gone for the others.
    var period: Double
    /// Stopped, it holds still: a plain dot, or a still ring.
    var running = true

    var body: some View {
        PulseHost(kind: kind, color: color, size: size, period: period, running: running)
            .frame(width: side, height: side)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var side: CGFloat {
        if case .ripple(let halo) = kind { return max(size, halo) }
        return size
    }
}

private struct PulseHost: NSViewRepresentable {
    let kind: Pulse.Kind
    let color: Color
    let size: CGFloat
    let period: Double
    let running: Bool

    func makeNSView(context: Context) -> PulseView { PulseView() }

    func updateNSView(_ view: PulseView, context: Context) {
        let environment = context.environment
        view.show(PulseView.Beat(kind: kind, size: size, period: period,
                                 running: running && !environment.accessibilityReduceMotion),
                  color: color.resolve(in: environment).cgColor)
    }
}

private final class PulseView: NSView {
    struct Beat: Equatable {
        var kind: Pulse.Kind
        var size: CGFloat
        var period: Double
        var running: Bool
    }

    /// The dot, and the halo or ring around it.
    private let dot = CALayer()
    private let halo = CALayer()
    private var beat: Beat?
    private var color: CGColor?
    private static let key = "pulse"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // The layers go in whatever backing layer AppKit makes, every time.
    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.addSublayer(halo)
        layer.addSublayer(dot)
        return layer
    }

    /// It only shows: clicks and drags go to whatever is under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ beat: Beat, color: CGColor) {
        guard beat != self.beat || color != self.color else { return }
        let changed = beat != self.beat
        self.beat = beat
        self.color = color
        arrange()
        if changed { animate() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        arrange()
    }

    override func layout() {
        super.layout()
        arrange()
    }

    // The animation is added once the view is in a window, again whenever
    // it is put back in one, and taken off while it is out of them.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animate()
    }

    /// Where the layers sit and how they look at rest, with no implicit
    /// animation.
    private func arrange() {
        guard let beat, let color else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        dot.bounds = CGRect(x: 0, y: 0, width: beat.size, height: beat.size)
        dot.position = center
        dot.cornerRadius = beat.size / 2
        dot.backgroundColor = color

        switch beat.kind {
        case .breathe:
            dot.isHidden = false
            halo.isHidden = true
        case .ripple(let width):
            dot.isHidden = false
            halo.isHidden = false
            halo.bounds = CGRect(x: 0, y: 0, width: width, height: width)
            halo.cornerRadius = width / 2
            halo.backgroundColor = color.copy(alpha: color.alpha * 0.35)
            halo.borderWidth = 0
            // Seen only while it runs.
            halo.opacity = 0
        case .ring(let line, _):
            dot.isHidden = true
            halo.isHidden = false
            halo.bounds = CGRect(x: 0, y: 0, width: beat.size, height: beat.size)
            halo.cornerRadius = beat.size / 2
            halo.backgroundColor = nil
            halo.borderColor = color
            halo.borderWidth = line
            halo.opacity = beat.running ? 0 : 0.8
        }
        halo.position = center
        CATransaction.commit()
    }

    private func animate() {
        dot.removeAnimation(forKey: Self.key)
        halo.removeAnimation(forKey: Self.key)
        guard let beat, beat.running, window != nil else { return }
        switch beat.kind {
        case .breathe(let low):
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = Double(low)
            fade.autoreverses = true
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(Self.forever(fade, period: beat.period), forKey: Self.key)
        case .ripple:
            halo.add(Self.forever(Self.spread(from: 0.45, to: 1, fade: 0.9), period: beat.period), forKey: Self.key)
        case .ring(_, let grow):
            halo.add(Self.forever(Self.spread(from: 1, to: grow, fade: 0.8), period: beat.period), forKey: Self.key)
        }
    }

    /// Grows and fades out, easing off as it goes.
    private static func spread(from start: CGFloat, to end: CGFloat, fade: Double) -> CAAnimationGroup {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = start
        scale.toValue = end
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = fade
        opacity.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return group
    }

    private static func forever(_ animation: CAAnimation, period: Double) -> CAAnimation {
        animation.duration = period
        (animation as? CAAnimationGroup)?.animations?.forEach { $0.duration = period }
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        // A slow pulse looks the same at 30 frames a second as at 120, and
        // costs the WindowServer a quarter as much.
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        return animation
    }
}

// MARK: - Level meter

/// An audio level meter: five bars that rise and fall with the level.
///
/// With no level given it follows the live audio (the louder of the mic and
/// the Mac's own sound), setting the bars' layers directly while Core
/// Animation eases them, so a new level never asks SwiftUI to redraw
/// anything.
struct LevelBars: View {
    /// The level to show, 0 to 1; nil follows the live audio.
    var level: Float? = nil
    var color: Color = Theme.accent

    var body: some View {
        LevelHost(level: level, color: color)
            .frame(width: LevelView.width, height: LevelView.height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct LevelHost: NSViewRepresentable {
    let level: Float?
    let color: Color

    func makeNSView(context: Context) -> LevelView { LevelView() }

    func updateNSView(_ view: LevelView, context: Context) {
        view.color = color.resolve(in: context.environment).cgColor
        view.given = level
    }
}

private final class LevelView: NSView {
    /// Each bar's height at full level, as on a small equalizer.
    private static let shape: [CGFloat] = [0.4, 0.8, 1.0, 0.7, 0.5]
    private static let barWidth: CGFloat = 2
    private static let gap: CGFloat = 1.5
    static let height: CGFloat = 11
    static let width: CGFloat = CGFloat(shape.count) * barWidth + CGFloat(shape.count - 1) * gap

    private let bars: [CALayer] = LevelView.shape.map { _ in CALayer() }
    private var level: CGFloat = 0
    private var watch: AnyCancellable?

    /// A level set from outside; nil follows the live audio.
    var given: Float? {
        didSet {
            guard given != oldValue else { return }
            follow()
            if let given { show(CGFloat(given), eased: true) }
        }
    }

    var color: CGColor? {
        didSet {
            guard color != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let fill = color?.copy(alpha: (color?.alpha ?? 1) * 0.9)
            for bar in bars { bar.backgroundColor = fill }
            CATransaction.commit()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        for bar in bars {
            bar.cornerRadius = Self.barWidth / 2
            layer.addSublayer(bar)
        }
        return layer
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        follow()
    }

    /// The live levels are followed only while it is on screen and has no
    /// level given.
    private func follow() {
        watch = window == nil || given != nil ? nil : AudioLevels.shared.$level
            .sink { [weak self] level in self?.show(CGFloat(level), eased: true) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        show(level, eased: false)
    }

    override func layout() {
        super.layout()
        show(level, eased: false)
    }

    /// Each bar to its height for the level, eased from wherever it is now
    /// so a new level mid-move carries on smoothly.
    private func show(_ level: CGFloat, eased: Bool) {
        self.level = level
        let left = bounds.midX - Self.width / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            let height = 3 + 8 * min(1, level * 1.6 * Self.shape[index])
            let target = CGRect(x: 0, y: 0, width: Self.barWidth, height: height)
            let from = bar.presentation()?.bounds ?? bar.bounds
            bar.bounds = target
            bar.position = CGPoint(x: left + CGFloat(index) * (Self.barWidth + Self.gap) + Self.barWidth / 2,
                                   y: bounds.midY)
            guard eased, from != target else { continue }
            let ease = CABasicAnimation(keyPath: "bounds")
            ease.fromValue = NSValue(rect: from)
            ease.toValue = NSValue(rect: target)
            ease.duration = 0.12
            ease.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bar.add(ease, forKey: "level")
        }
        CATransaction.commit()
    }
}
