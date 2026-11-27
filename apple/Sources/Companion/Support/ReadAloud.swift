import AVFoundation
import AppKit

/// Reads an answer aloud with the Mac's own voice: the speaker under an
/// answer starts it, and the same button stops it. One answer at a time.
@MainActor
final class ReadAloud: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = ReadAloud()

    /// The turn being read now, so its button shows as the one to stop.
    @Published private(set) var reading: UUID?

    private let voice = AVSpeechSynthesizer()

    private override init() {
        super.init()
        voice.delegate = self
    }

    /// Reads a turn's words, or stops when that turn is the one being read.
    func toggle(_ text: String, turn: UUID) {
        if reading == turn {
            stop()
            return
        }
        voice.stopSpeaking(at: .immediate)
        // Read as words, not as the symbols Markdown is written with.
        let plain = MarkdownNotes.plain(text)
        guard !plain.isEmpty else { return }
        reading = turn
        voice.speak(AVSpeechUtterance(string: plain))
    }

    func stop() {
        voice.stopSpeaking(at: .immediate)
        reading = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.reading = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in if !self.voice.isSpeaking { self.reading = nil } }
    }
}

/// A whole chat as plain text in a window of its own, where the cursor
/// selects across messages as in any document: the chat itself is drawn
/// message by message, and a selection there cannot cross from one to
/// the next.
@MainActor
enum ChatTextWindow {
    private static var window: NSWindow?

    static func show(title: String, text: String) {
        let scroll = NSTextView.scrollableTextView()
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.font = .systemFont(ofSize: 13)
            view.textContainerInset = NSSize(width: 16, height: 16)
            view.string = text
        }
        let made = window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 720),
                                      styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                      backing: .buffered, defer: false)
        made.title = title
        made.contentView = scroll
        made.isReleasedWhenClosed = false
        // Kept out of screen sharing like the rest of Companion.
        made.sharingType = AppSettings.shared.hideFromScreenShare ? .none : .readOnly
        if window == nil { made.center() }
        window = made
        made.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
