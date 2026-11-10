import Foundation
import CoreGraphics

/// Optional auto mode: looks at the screen every few seconds and fires when
/// a new question (a line ending in "?") has appeared.
///
/// Looking is cheap and reading is not, so it works in two stages. Each look
/// takes a tiny capture and compares it with the previous one. Only when the
/// screen has changed and then held still for one look (so a page that is
/// still loading or scrolling is never read half-way) does it take a full
/// capture and run text recognition. After a minute without change the looks
/// slow down, and speed up again on the first change.
@MainActor
final class ScreenWatcher {
    var onQuestion: ((String) -> Void)?

    private var loop: Task<Void, Never>?
    /// The previous look, to tell whether the screen is still moving.
    private var lastLook: [UInt8]?
    /// The screen as it was when it was last read.
    private var lastRead: [UInt8]?
    private var lastQuestions: Set<String> = []
    private var lastChange = Date()

    /// Mean difference per pixel (0 to 255) above which two looks differ.
    /// A blinking cursor or a ticking clock stays well under it.
    static let threshold = 1.2

    func start() {
        guard loop == nil else { return }
        lastChange = Date()
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.look()
                let base = Double(max(AppSettings.shared.screenWatchInterval, 1))
                let idle = Date().timeIntervalSince(self.lastChange) > 60
                let wait = idle ? max(base, 10) : base
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        lastLook = nil
        lastRead = nil
        lastQuestions = []
    }

    private func look() async {
        guard let small = try? await ScreenReader.glance(),
              let signature = Self.signature(of: small) else { return }
        let previous = lastLook
        lastLook = signature
        // Still changing since the last look: wait for it to settle.
        if let previous, Self.difference(previous, signature) > Self.threshold {
            lastChange = Date()
            return
        }
        // Settled, and the same as what was already read: nothing new.
        if let lastRead, Self.difference(lastRead, signature) <= Self.threshold {
            return
        }
        lastRead = signature
        lastChange = Date()
        guard let text = try? await ScreenReader.captureText() else { return }
        let questions = Set(
            text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count > 10 && $0.hasSuffix("?") }
        )
        let fresh = questions.subtracting(lastQuestions)
        lastQuestions = questions
        if !fresh.isEmpty {
            onQuestion?(text)
        }
    }

    /// Waits for whatever was just set in motion to finish: first for the
    /// screen to start changing (the user may still have to press Return),
    /// then for it to hold still for a few seconds. Gives up waiting after
    /// `limit` seconds, so a screen that never settles does not hang it.
    static func waitForScreenToSettle(startWithin: Double = 20, limit: Double = 120) async {
        func look() async -> [UInt8]? {
            guard let image = try? await ScreenReader.glance() else { return nil }
            return signature(of: image)
        }
        let began = Date()
        guard var previous = await look() else { return }
        // Phase one: something starts happening.
        var started = false
        while !Task.isCancelled, Date().timeIntervalSince(began) < startWithin {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let now = await look() else { return }
            let moved = difference(previous, now) > threshold
            previous = now
            if moved {
                started = true
                break
            }
        }
        guard started else { return }
        // Phase two: it stops. Two quiet looks in a row count as finished.
        var quiet = 0
        while !Task.isCancelled, Date().timeIntervalSince(began) < limit, quiet < 2 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let now = await look() else { return }
            quiet = difference(previous, now) > threshold ? 0 : quiet + 1
            previous = now
        }
    }

    /// The image reduced to a small grid of gray levels.
    static func signature(of image: CGImage) -> [UInt8]? {
        let width = 48
        let height = 30
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var total = 0
        for index in a.indices {
            total += abs(Int(a[index]) - Int(b[index]))
        }
        return Double(total) / Double(a.count)
    }
}
