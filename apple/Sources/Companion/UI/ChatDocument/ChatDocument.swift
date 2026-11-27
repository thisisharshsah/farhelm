import Foundation

/// The conversation as one HTML document, for the chat drawn as one page
/// (`ChatDocumentPane`), so a selection can run across messages, code and
/// pictures. Every turn is one `<article>` whose id comes from the turn's
/// own id, with its request and answer as `-prompt` and `-answer` inside:
/// later work replaces a single element by its id instead of the whole page.
struct ChatDocument {
    var turns: [ChatTurn]
    /// Turns whose answer is still being written.
    var streaming: Set<UUID> = []
    /// Where a turn's screen capture is on this Mac.
    var picture: (ChatTurn) -> URL? = { _ in nil }

    static func elementID(_ turn: UUID) -> String { "turn-\(turn.uuidString)" }

    var html: String {
        Self.ordered(turns)
            .map { Self.html(for: $0, picture: picture($0), streaming: streaming.contains($0.id)) }
            .joined(separator: "\n")
    }

    /// In the order they happened, as the message list puts them: by the
    /// line each one answers, then as they were added.
    static func ordered(_ turns: [ChatTurn]) -> [ChatTurn] {
        turns.enumerated()
            .sorted { a, b in
                let left = a.element.anchor ?? a.element.date
                let right = b.element.anchor ?? b.element.date
                return left == right ? a.offset < b.offset : left < right
            }
            .map(\.element)
    }

    /// The content inside a turn's answer section, without the `<section>` tag.
    static func answerInnerHTML(for turn: ChatTurn, streaming: Bool = false) -> String {
        var answer = ChatMarkdown.html(turn.answer)
        if answer.isEmpty, streaming { answer = "<p class=\"pending\">Writing\u{2026}</p>" }
        if let error = turn.error, !error.isEmpty {
            answer += "<p class=\"error\">\(ChatMarkdown.escape(error))</p>"
        }
        if !turn.model.isEmpty, !turn.answer.isEmpty, !streaming {
            answer += "<p class=\"model\">\(ChatMarkdown.escape(turn.model))</p>"
        }
        return answer
    }

    static func html(for turn: ChatTurn, picture: URL? = nil, streaming: Bool = false) -> String {
        let id = elementID(turn.id)
        var parts: [String] = []
        // A reply to something heard has no request of its own to show; one
        // typed or a screen capture does, as the message list shows it.
        if turn.origin == .typed || turn.kind == .screen {
            var request = ""
            if let picture, let tag = ChatMarkdown.media(picture, alt: "Screen capture") { request += tag }
            if let attached = turn.attached, !attached.isEmpty {
                request += "<ul class=\"attached\">"
                    + attached.map { "<li>\(ChatMarkdown.escape($0))</li>" }.joined()
                    + "</ul>"
            }
            // What the person typed is shown as typed, not read as Markdown.
            if !turn.prompt.isEmpty {
                request += "<div class=\"bubble\">\(ChatMarkdown.escape(turn.prompt))</div>"
            }
            parts.append("<section class=\"prompt\" id=\"\(id)-prompt\">\(request)</section>")
        }
        let answer = answerInnerHTML(for: turn, streaming: streaming)
        parts.append("<section class=\"answer\" id=\"\(id)-answer\">\(answer)</section>")
        return "<article class=\"turn \(turn.kind.rawValue)\" id=\"\(id)\">" + parts.joined() + "</article>"
    }

    /// A snapshot of each turn for diffing against what the page already shows.
    var snapshots: [TranscriptDiff.TurnSnapshot] {
        Self.ordered(turns).map { turn in
            let isStreaming = streaming.contains(turn.id)
            return TranscriptDiff.TurnSnapshot(
                id: turn.id,
                answerInnerHTML: Self.answerInnerHTML(for: turn, streaming: isStreaming),
                articleHTML: Self.html(for: turn, picture: picture(turn), streaming: isStreaming))
        }
    }
}