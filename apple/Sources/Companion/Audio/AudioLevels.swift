import Foundation

/// The live mic and system audio levels, for the level meter.
///
/// They change with every audio frame, about 30 times a second from each
/// source. Kept on AppState, every change re-ran every view that watches
/// the app; here the meter alone watches them, and only as often as it can
/// show a difference.
@MainActor
final class AudioLevels: ObservableObject {
    static let shared = AudioLevels()

    enum Source { case mic, system }

    /// The louder of the two.
    @Published private(set) var level: Float = 0

    private var mic: Float = 0
    private var system: Float = 0
    private var shownAt = ContinuousClock.now - .seconds(1)
    /// 20 a second: the meter eases from one to the next.
    private static let spacing: Duration = .milliseconds(50)

    private init() {}

    func take(_ value: Float, from source: Source) {
        switch source {
        case .mic: mic = value
        case .system: system = value
        }
        let loudest = max(mic, system)
        guard abs(loudest - level) >= 0.01 else { return }
        let now = ContinuousClock.now
        // Silence shows at once; anything else at most every `spacing`.
        guard loudest == 0 || now - shownAt >= Self.spacing else { return }
        shownAt = now
        level = loudest
    }

    func reset() {
        mic = 0
        system = 0
        if level != 0 { level = 0 }
    }
}
