import SwiftUI

// MARK: - The orbit mark

/// One of the small circles running along the ball's lines. Each picks its
/// line, direction and speed at random, and picks again when its time is up,
/// so the mark never repeats itself.
private struct OrbitDot {
    var line: Int
    var direction: Double
    var rate: Double
    var start: Double
    var born: Double
    var life: Double

    static func random(lines: Int, now: Double) -> OrbitDot {
        OrbitDot(line: Int.random(in: 0..<max(1, lines)),
                 direction: Bool.random() ? 1 : -1,
                 rate: Double.random(in: 0.6...1.5),
                 start: Double.random(in: 0...(2 * Double.pi)),
                 born: now,
                 life: Double.random(in: 2.5...7))
    }
}

/// What a mark remembers between frames.
private final class OrbitMemory {
    var dots: [OrbitDot] = []
    let began = Date()
}

/// Companion's mark: a ball of orbit lines around a soft source of light.
/// The ball turns, small circles run along its lines in directions picked at
/// random, and the source feeds each of them through a thin beam with pulses
/// of light travelling out along it. It is drawn as shapes, so it is sharp
/// at any size, and it takes the two colors of the look in effect.
public struct OrbitMark: View {
    /// How lively it is: 0 is still, 1 a calm turn, 4 busy.
    var speed: Double = 1
    /// How many circles run along the lines.
    var dots = 4
    /// How many lines make up the ball.
    var lines = 7
    /// Circles leave a fading trail.
    var trail = true
    /// The source beats.
    var pulse = true
    /// Whether it moves at all.
    var moving = true
    /// One color for all of it, in place of the look's own three.
    var tint: Color?
    /// Frames a second while it moves; nil picks by speed (30 lively, 15
    /// calm). Small marks need far fewer than large ones to look smooth,
    /// and every frame redraws the window they are in.
    var frameRate: Double?

    @State private var memory = OrbitMemory()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(speed: Double = 1, dots: Int = 4, lines: Int = 7, trail: Bool = true, pulse: Bool = true, moving: Bool = true,
         tint: Color? = nil, frameRate: Double? = nil) {
        self.tint = tint
        self.frameRate = frameRate
        self.speed = speed
        self.dots = dots
        self.lines = lines
        self.trail = trail
        self.pulse = pulse
        self.moving = moving
    }

    public var body: some View {
        let still = !moving || reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / (frameRate ?? (speed > 0.5 ? 30 : 15)), paused: still)) { timeline in
            Canvas { context, size in
                let time = still ? 1.0 : timeline.date.timeIntervalSince(memory.began)
                draw(&context, size: size, time: time, still: still)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, time: Double, still: Bool) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // Room is left around the ball for its glow.
        let radius = min(size.width, size.height) / 2 * 0.8
        let count = max(3, lines)
        let light = Theme.isLight
        let first = tint ?? Theme.accent
        let second = tint ?? Theme.lilac
        let third = tint ?? Theme.mint

        let spin = time * (0.18 + speed * 0.16) + 0.6
        let lean = 0.42 + (still ? 0 : sin(time * 0.3) * 0.08)
        let cosSpin = cos(spin), sinSpin = sin(spin), cosLean = cos(lean), sinLean = sin(lean)

        // A point at angle t on line i, turned with the ball: where it is on
        // screen, and how near the viewer it is (-1 far, 1 near).
        func point(_ line: Int, _ t: Double) -> (at: CGPoint, depth: Double) {
            let tilt = Double.pi * (Double(line) + 0.5) / Double(count)
            let facing = Double(line) * 2.399963
            let x = cos(t), y = sin(t) * cos(tilt), z = sin(t) * sin(tilt)
            let x1 = x * cos(facing) + z * sin(facing), z1 = -x * sin(facing) + z * cos(facing)
            let x2 = x1 * cosSpin + z1 * sinSpin, z2 = -x1 * sinSpin + z1 * cosSpin
            let y3 = y * cosLean - z2 * sinLean, z3 = y * sinLean + z2 * cosLean
            return (CGPoint(x: center.x + x2 * radius, y: center.y + y3 * radius), z3)
        }

        func circle(_ at: CGPoint, _ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2))
        }

        // The circles: keep the right number, and replace the ones whose time is up.
        if memory.dots.count > dots { memory.dots.removeLast(memory.dots.count - dots) }
        while memory.dots.count < dots {
            memory.dots.append(OrbitDot.random(lines: count, now: time - Double.random(in: 0...3)))
        }
        if !still {
            for index in memory.dots.indices where time - memory.dots[index].born > memory.dots[index].life {
                memory.dots[index] = OrbitDot.random(lines: count, now: time)
            }
        }
        for index in memory.dots.indices where memory.dots[index].line >= count {
            memory.dots[index].line = memory.dots[index].line % count
        }

        // Soft light inside the ball.
        let beat = (pulse && !still) ? 0.5 + 0.5 * sin(time * (1.6 + speed * 0.5)) : 0.5
        let glow = radius * (1.18 + (pulse ? 0.08 * beat : 0))
        context.fill(circle(center, glow),
                     with: .radialGradient(Gradient(colors: [first.opacity(0.22), second.opacity(0.08), first.opacity(0)]),
                                           center: center, startRadius: 0, endRadius: glow))

        // On dark glass, crossing lines brighten each other.
        if !light { context.blendMode = .plusLighter }
        let steps = radius < 30 ? 44 : (radius < 60 ? 64 : 120)
        let weight = max(0.6, radius * 0.014)
        let dotSize = max(1.1, radius * 0.05)
        let head = light ? first : Color.white

        for pass in 0..<2 {
            let nearPass = pass == 1
            // The lines: the far half first, the near half over the source.
            for line in 0..<count {
                let color = line % 3 == 2 ? third : (line % 2 == 0 ? first : second)
                var previous = point(line, 0)
                for step in 1...steps {
                    let current = point(line, Double(step) / Double(steps) * 2 * .pi)
                    let depth = (previous.depth + current.depth) / 2
                    if (depth >= 0) == nearPass {
                        let near = (depth + 1) / 2
                        var segment = Path()
                        segment.move(to: previous.at)
                        segment.addLine(to: current.at)
                        // On light glass nothing brightens by overlapping, so
                        // the lines are drawn firmer and a little heavier.
                        let strength = light ? 0.24 + 0.74 * pow(near, 1.5) : 0.07 + 0.78 * pow(near, 2.2)
                        context.stroke(segment,
                                       with: .color(color.opacity(strength)),
                                       lineWidth: weight * (0.55 + 1.15 * near) * (light ? 1.3 : 1))
                    }
                    previous = current
                }
            }

            // The circles, each fed by the source.
            for (index, dot) in memory.dots.enumerated() {
                let age = still ? 1 : time - dot.born
                let seen = still ? 1 : max(0, min(1, age / 0.45, (dot.life - age) / 0.45))
                guard seen > 0 else { continue }
                let angle = dot.start + dot.direction * dot.rate * speed * age
                let place = point(dot.line, angle)
                if (place.depth >= 0) == nearPass {
                    let near = (0.4 + 0.6 * (place.depth + 1) / 2) * seen
                    // The beam from the source, and the pulses travelling out along it.
                    var beam = Path()
                    beam.move(to: center)
                    beam.addLine(to: place.at)
                    context.stroke(beam,
                                   with: .linearGradient(Gradient(colors: [second.opacity(0.42 * near), first.opacity(0.1 * near)]),
                                                         startPoint: center, endPoint: place.at),
                                   lineWidth: max(0.5, radius * 0.011))
                    for wave in 0..<2 {
                        let along = still
                            ? 0.35 + Double(wave) * 0.4
                            : (time * (0.8 + speed * 0.22) + Double(index) * 0.37 + Double(wave) * 0.5)
                                .truncatingRemainder(dividingBy: 1)
                        let spot = CGPoint(x: center.x + (place.at.x - center.x) * along,
                                           y: center.y + (place.at.y - center.y) * along)
                        context.fill(circle(spot, max(0.6, dotSize * 0.3)),
                                     with: .color(head.opacity(0.8 * sin(along * .pi) * near)))
                    }
                }
                let tail = trail && !still ? 12 : 1
                for back in stride(from: tail - 1, through: 0, by: -1) {
                    let spot = point(dot.line, angle - Double(back) * 0.05 * dot.direction)
                    guard (spot.depth >= 0) == nearPass else { continue }
                    let near = (spot.depth + 1) / 2 * seen
                    let fade = back == 0 ? 1 : 1 - Double(back) / Double(tail) * 0.65
                    let size = dotSize * (0.5 + 0.7 * near) * fade
                    if back == 0 {
                        // The circle itself, in a small halo.
                        context.fill(circle(spot.at, size * 3),
                                     with: .radialGradient(Gradient(colors: [second.opacity(0.5 * near), second.opacity(0)]),
                                                           center: spot.at, startRadius: 0, endRadius: size * 3))
                        context.fill(circle(spot.at, size), with: .color(head.opacity(0.35 + 0.65 * near)))
                    } else {
                        context.fill(circle(spot.at, size),
                                     with: .color(second.opacity((1 - Double(back) / Double(tail)) * 0.45 * (0.3 + 0.7 * near))))
                    }
                }
            }

            // The source sits inside the ball: over the far lines, under the near ones.
            if pass == 0 {
                let core = radius * (0.17 + 0.02 * beat)
                if !still {
                    // A faint wave of light, swelling out to the lines.
                    for wave in 0..<2 {
                        let along = (time * (0.35 + speed * 0.12) + Double(wave) * 0.5).truncatingRemainder(dividingBy: 1)
                        context.stroke(circle(center, core + (radius - core) * along),
                                       with: .color(second.opacity(0.2 * (1 - along) * (1 - along))),
                                       lineWidth: max(0.5, radius * 0.012))
                    }
                }
                context.fill(circle(center, core * 2.6),
                             with: .radialGradient(Gradient(colors: [second.opacity(0.3 + 0.1 * beat), first.opacity(0.14), first.opacity(0)]),
                                                   center: center, startRadius: 0, endRadius: core * 2.6))
                // Glowing, not glaring: the look's own color, a little lighter at its heart.
                context.fill(circle(center, core),
                             with: .radialGradient(Gradient(stops: [
                                .init(color: head.opacity(0.42 + 0.12 * beat), location: 0),
                                .init(color: second.opacity(0.62), location: 0.3),
                                .init(color: first.opacity(0.34), location: 0.7),
                                .init(color: first.opacity(0), location: 1),
                             ]), center: center, startRadius: 0, endRadius: core))
                let streak = Path(ellipseIn: CGRect(x: center.x - radius * 0.5, y: center.y - max(0.5, radius * 0.009),
                                                    width: radius, height: max(1, radius * 0.018)))
                context.fill(streak,
                             with: .linearGradient(Gradient(colors: [second.opacity(0), second.opacity(0.16 + 0.08 * beat), second.opacity(0)]),
                                                   startPoint: CGPoint(x: center.x - radius * 0.5, y: center.y),
                                                   endPoint: CGPoint(x: center.x + radius * 0.5, y: center.y)))
            }
        }
    }
}

// MARK: - The orbit as the sign that something is going on

/// Companion's one sign of work in progress, wherever a spinner would be:
/// its own mark, small. How it moves says what is happening, so it reads
/// without the words beside it.
///
/// - thinking: a slow turn, while a model has not answered yet
/// - working: a quick turn with circles running, while something runs
/// - waiting: nearly still and amber, when it is the user's move
/// - done, failed: a ring in mint or rose, for the moment after
/// - idle: still and quiet
///
/// It is drawn simpler the smaller it is, so it stays clean at the size of
/// a line of text. With Reduce Motion on it does not turn.
public struct LoadingMark: View {
    public enum Phase: Sendable { case idle, thinking, working, waiting, done, failed }

    var state: Phase = .working
    /// The side of the square it is drawn in.
    var size: CGFloat = 14

    public init(state: Phase = .working, size: CGFloat = 14) {
        self.state = state
        self.size = size
    }

    /// Fewer lines and circles when there is little room for them.
    private var lines: Int { size < 18 ? 3 : (size < 40 ? 5 : 7) }

    private var dots: Int {
        switch state {
        case .working: return size < 18 ? 2 : (size < 40 ? 3 : 5)
        case .thinking: return size < 18 ? 1 : 2
        case .idle, .waiting, .done, .failed: return 0
        }
    }

    private var speed: Double {
        switch state {
        case .working: return 2.6
        case .thinking: return 0.9
        case .waiting: return 0.2
        case .idle, .done, .failed: return 0
        }
    }

    public var body: some View {
        Group {
            switch state {
            case .done, .failed:
                // The lines settle into one ring around the source.
                let color = state == .done ? Theme.mint : Theme.rose
                ZStack {
                    Circle()
                        .strokeBorder(color.opacity(0.9), lineWidth: max(1, size * 0.09))
                    Circle()
                        .fill(color)
                        .frame(width: size * 0.3, height: size * 0.3)
                }
                .padding(size * 0.08)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .idle, .thinking, .working, .waiting:
                turning
                    .opacity(state == .idle ? 0.55 : 1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(label)
    }

    /// The ball itself. Small and moving, Core Animation turns it (see
    /// `SpinMark`); large or still, it is the drawn one.
    @ViewBuilder
    private var turning: some View {
        #if os(macOS)
        if state != .idle, size < 24 {
            SpinMark(lines: lines, dots: dots, speed: speed, pulse: true,
                     tint: state == .waiting ? Theme.amber : nil)
        } else {
            drawn
        }
        #else
        drawn
        #endif
    }

    private var drawn: some View {
        // A mark the size of a line of text looks just as smooth at
        // half the frames.
        IsolatedAnimation(OrbitMark(speed: speed, dots: dots, lines: lines, trail: size >= 20,
                                    pulse: state != .idle, moving: state != .idle,
                                    tint: state == .waiting ? Theme.amber : nil,
                                    frameRate: size < 24 ? 15 : nil))
    }

    private var label: String {
        switch state {
        case .idle: return "Idle"
        case .thinking: return "Thinking"
        case .working: return "Working"
        case .waiting: return "Waiting for you"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }
}



/// An animated view drawn in a host of its own. Every frame of an
/// animation in a window lays out and redraws the whole view tree it is
/// part of: a small spinner in a long chat made the chat, the sidebar and
/// the browser beside it all work fifteen times a second, and typing
/// lagged. In a host of its own, a frame touches only its own few pixels.
public struct IsolatedAnimation<Content: View>: View {
    let content: Content

    public init(_ content: Content) {
        self.content = content
    }

    public var body: some View {
        #if os(macOS)
        IsolatedHost(content: content)
        #else
        content
        #endif
    }
}

#if os(macOS)
import AppKit

private struct IsolatedHost<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let host = NSHostingView(rootView: content)
        // Its size is the one it is given; it never asks the window above
        // it for another layout.
        host.sizingOptions = []
        return host
    }

    func updateNSView(_ host: NSHostingView<Content>, context: Context) {
        host.rootView = content
    }
}
#endif

// MARK: - Motion that costs the app nothing

/// Makes a view breathe: from full strength down to `low` and back, for as
/// long as it is on screen. On the Mac the fade is handed to Core Animation,
/// which runs it outside the app: a SwiftUI `repeatForever` animation
/// redraws on the main thread at the display's full rate, and a few of them
/// on screen left no time for typing or clicks.
public struct Breathing<Content: View>: View {
    let content: Content
    var low: Double
    var period: Double

    public init(low: Double = 0.35, period: Double = 0.9, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.low = low
        self.period = period
    }

    public var body: some View {
        #if os(macOS)
        BreathingHost(content: content, low: low, period: period)
        #else
        TimelineView(.animation(minimumInterval: 1.0 / 15)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period * 2) / (period * 2)
            content.opacity(low + (1 - low) * (1 + cos(turn * 2 * .pi)) / 2)
        }
        #endif
    }
}

#if os(macOS)
import QuartzCore

private final class BreathingHostView<Content: View>: NSHostingView<Content> {
    var low: Double = 0.35
    var period: Double = 0.9

    // Core Animation drops a layer's animations when its view leaves the
    // window, so the fade starts again each time it comes back.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        breathe()
    }

    // What breathes is decoration: clicks go to what is under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func breathe() {
        wantsLayer = true
        guard let layer = self.layer else { return }
        layer.removeAnimation(forKey: "breath")
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = low
        fade.duration = period
        fade.autoreverses = true
        fade.repeatCount = .infinity
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "breath")
    }
}

private struct BreathingHost<Content: View>: NSViewRepresentable {
    let content: Content
    let low: Double
    let period: Double

    func makeNSView(context: Context) -> BreathingHostView<Content> {
        let host = BreathingHostView(rootView: content)
        host.sizingOptions = []
        host.low = low
        host.period = period
        host.breathe()
        return host
    }

    func updateNSView(_ host: BreathingHostView<Content>, context: Context) {
        host.rootView = content
        if host.low != low || host.period != period {
            host.low = low
            host.period = period
            host.breathe()
        }
    }
}

/// The small mark (the size of a line of text), turned by Core Animation.
/// The drawn mark works out every line of the ball on the main thread for
/// each frame; with a mark on every running task, every busy row and the
/// status line, that was most of what the app did while the agent worked.
/// Here the ball is built once out of layers and the turning is left to
/// Core Animation, outside the app. Larger marks keep the drawn ball, with
/// its depth and trails, which a mark this small cannot show anyway.
struct SpinMark: NSViewRepresentable {
    let lines: Int
    let dots: Int
    let speed: Double
    let pulse: Bool
    let tint: Color?

    func makeNSView(context: Context) -> SpinMarkView {
        let view = SpinMarkView()
        view.apply(spec)
        return view
    }

    func updateNSView(_ view: SpinMarkView, context: Context) {
        view.apply(spec)
    }

    private var spec: SpinMarkView.Spec {
        let first = tint ?? Theme.accent
        let second = tint ?? Theme.lilac
        let third = tint ?? Theme.mint
        let light = Theme.isLight
        return SpinMarkView.Spec(
            key: "\(lines)|\(dots)|\(speed)|\(pulse)|\(light)|\(first)|\(second)|\(third)",
            lines: max(3, lines), dots: dots, speed: speed, pulse: pulse, light: light,
            first: NSColor(first).cgColor, second: NSColor(second).cgColor, third: NSColor(third).cgColor)
    }
}

final class SpinMarkView: NSView {
    struct Spec {
        var key: String
        var lines: Int
        var dots: Int
        var speed: Double
        var pulse: Bool
        var light: Bool
        var first: CGColor
        var second: CGColor
        var third: CGColor
    }

    private var spec: Spec?
    /// What the layers were last built for: the look and the size.
    private var built = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { return nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ new: Spec) {
        guard new.key != spec?.key else { return }
        spec = new
        needsLayout = true
    }

    override func layout() {
        super.layout()
        build()
    }

    // Animations are dropped when the view leaves its window; they are put
    // back when it returns.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        built = ""
        needsLayout = true
    }

    private func build() {
        guard let spec, let root = layer, bounds.width > 1, bounds.height > 1 else { return }
        let stamp = "\(spec.key)|\(bounds.width)x\(bounds.height)"
        guard stamp != built else { return }
        built = stamp
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || spec.speed <= 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayers?.forEach { $0.removeFromSuperlayer() }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 * 0.8
        let square = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

        // Soft light behind the ball.
        let glow = CAGradientLayer()
        glow.type = .radial
        let reach = radius * 1.22
        glow.frame = CGRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2)
        glow.colors = [spec.first.copy(alpha: 0.26) ?? spec.first, spec.first.copy(alpha: 0) ?? spec.first]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        root.addSublayer(glow)

        // The ball: leaning a little toward the viewer, turning about its
        // own upright axis.
        let lean = CATransformLayer()
        lean.frame = bounds
        lean.transform = CATransform3DMakeRotation(0.42, 1, 0, 0)
        let ball = CATransformLayer()
        ball.frame = bounds
        lean.addSublayer(ball)
        root.addSublayer(lean)

        let weight = max(0.7, radius * 0.11)
        var rings: [CAShapeLayer] = []
        for line in 0..<spec.lines {
            let color = line % 3 == 2 ? spec.third : (line % 2 == 0 ? spec.first : spec.second)
            let ring = CAShapeLayer()
            ring.frame = square
            ring.path = CGPath(ellipseIn: CGRect(origin: .zero, size: square.size), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = color
            ring.lineWidth = weight
            ring.opacity = spec.light ? 0.85 : 0.75
            ring.isDoubleSided = true
            // The same planes as the drawn ball: tilted, then faced round
            // the upright axis by the golden angle.
            let tilt = Double.pi * (Double(line) + 0.5) / Double(spec.lines)
            let facing = Double(line) * 2.399963
            ring.transform = CATransform3DRotate(CATransform3DMakeRotation(facing, 0, 1, 0), tilt, 1, 0, 0)
            ball.addSublayer(ring)
            rings.append(ring)
        }

        // The circles running along the lines.
        let head = spec.light ? spec.first : CGColor(gray: 1, alpha: 1)
        let dotSide = max(1.6, radius * 0.34)
        for index in 0..<max(0, spec.dots) {
            let ring = rings[index % rings.count]
            let runner = CALayer()
            runner.frame = CGRect(origin: .zero, size: square.size)
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: dotSide, height: dotSide)
            dot.cornerRadius = dotSide / 2
            dot.backgroundColor = head
            dot.position = CGPoint(x: square.width, y: square.height / 2)
            runner.addSublayer(dot)
            ring.addSublayer(runner)
            let start = Double.random(in: 0...(2 * Double.pi))
            runner.setAffineTransform(CGAffineTransform(rotationAngle: start))
            if !still {
                let direction: Double = Bool.random() ? 1 : -1
                let rate = Double.random(in: 0.6...1.5) * max(0.4, spec.speed)
                let run = CABasicAnimation(keyPath: "transform.rotation.z")
                run.fromValue = start
                run.toValue = start + direction * 2 * Double.pi
                run.duration = 2 * Double.pi / rate
                run.repeatCount = .infinity
                runner.add(run, forKey: "run")
            }
        }

        // The source of light at the heart of it.
        let coreSide = max(2, radius * 0.5)
        let core = CALayer()
        core.bounds = CGRect(x: 0, y: 0, width: coreSide, height: coreSide)
        core.position = center
        core.cornerRadius = coreSide / 2
        core.backgroundColor = spec.second
        core.opacity = 0.7
        root.addSublayer(core)

        if !still {
            let turn = CABasicAnimation(keyPath: "transform.rotation.y")
            turn.fromValue = 0
            turn.toValue = 2 * Double.pi
            turn.duration = 2 * Double.pi / (0.18 + spec.speed * 0.16)
            turn.repeatCount = .infinity
            ball.add(turn, forKey: "turn")
            if spec.pulse {
                let beat = CABasicAnimation(keyPath: "opacity")
                beat.fromValue = 0.45
                beat.toValue = 0.9
                beat.duration = Double.pi / (1.6 + spec.speed * 0.5)
                beat.autoreverses = true
                beat.repeatCount = .infinity
                beat.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                core.add(beat, forKey: "beat")
            }
        }
        CATransaction.commit()
    }
}
#endif
