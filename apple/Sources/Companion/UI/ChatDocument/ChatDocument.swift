import Foundation

/// The conversation as one HTML document, for the chat drawn as one page
/// (`ChatDocumentPane`), so a selection can run across messages, code and
/// pictures. Every turn is one `<article>` whose id comes from the turn's
/// own id, with its request and answer as `-prompt` and `-answer` inside,
/// the folded work timeline as `-work` and the tools row as `-tools`:
/// later work replaces a single element by its id instead of the whole
/// page.
struct ChatDocument {
    var turns: [ChatTurn]
    /// Turns whose answer is still being written.
    var streaming: Set<UUID> = []
    /// Where a turn's screen capture is on this Mac.
    var picture: (ChatTurn) -> URL? = { _ in nil }
    /// Turns whose work timeline is folded open. The chat page tells the
    /// coordinator when the person opens or closes one, and the next
    /// render keeps that state so a re-render does not fold it shut.
    var workOpen: Set<UUID> = []

    static func elementID(_ turn: UUID) -> String { "turn-\(turn.uuidString)" }

    var html: String {
        Self.ordered(turns)
            .map { Self.html(for: $0, picture: picture($0), streaming: streaming.contains($0.id),
                             workOpen: workOpen.contains($0.id)) }
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

    static func html(for turn: ChatTurn, picture: URL? = nil, streaming: Bool = false,
                     workOpen: Bool = false) -> String {
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
        if let steps = turn.steps, !steps.isEmpty {
            parts.append(workSectionHTML(for: turn, steps: steps, open: workOpen))
        }
        let answer = answerInnerHTML(for: turn, streaming: streaming)
        parts.append("<section class=\"answer\" id=\"\(id)-answer\">\(answer)</section>")
        parts.append(toolsRowHTML(for: turn, streaming: streaming))
        return "<article class=\"turn \(turn.kind.rawValue)\" id=\"\(id)\">" + parts.joined() + "</article>"
    }

    /// The row of message tools under an answer: copy, read aloud, thumbs
    /// up and thumbs down for finished answers, then regenerate, edit
    /// (when the turn was typed or captured from the screen) and delete.
    /// Each button posts its name back to the app through the one script
    /// handler the chat page uses.
    static func toolsRowHTML(for turn: ChatTurn, streaming: Bool) -> String {
        let id = turn.id.uuidString
        let answerReady = !turn.answer.isEmpty && !streaming
        var buttons: [(action: String, label: String)] = []
        if answerReady {
            buttons.append(("copy", "Copy"))
            buttons.append(("readAloud", "Read aloud"))
            buttons.append(("thumbsUp", "Thumbs up"))
            buttons.append(("thumbsDown", "Thumbs down"))
        }
        buttons.append(("regenerate", "Regenerate"))
        if turn.origin == .typed || turn.kind == .screen {
            buttons.append(("edit", "Edit and send again"))
        }
        buttons.append(("delete", "Delete this turn"))
        let items = buttons.map { toolButtonHTML(action: $0.action, label: $0.label, turnID: id) }.joined()
        return "<nav class=\"tools\" id=\"\(elementID(turn.id))-tools\" aria-label=\"Message tools\">\(items)</nav>"
    }

    private static func toolButtonHTML(action: String, label: String, turnID: String) -> String {
        let escaped = ChatMarkdown.escape(label)
        return "<button type=\"button\" class=\"tool tool-\(action)\" data-action=\"\(action)\" data-turn=\"\(turnID)\" aria-label=\"\(escaped)\" title=\"\(escaped)\">\(iconSVG(action))</button>"
    }

    /// The work timeline for a turn, folded. Closed shows the one-line
    /// summary of what the agent did; opening reveals the step titles.
    /// The toggle button posts `openWork` or `closeWork` through the one
    /// script handler, so the coordinator keeps the state across renders.
    static func workSectionHTML(for turn: ChatTurn, steps: [WorkStep], open: Bool) -> String {
        let id = elementID(turn.id)
        let turnID = turn.id.uuidString
        let summary = ChatMarkdown.escape(WorkStep.summary(of: steps))
        let action = open ? "closeWork" : "openWork"
        let expanded = open ? "true" : "false"
        let openFlag = open ? "true" : "false"
        var items = ""
        for step in steps {
            let title = ChatMarkdown.escape(step.title)
            items += "<li class=\"step step-\(step.kind.rawValue)\(step.failed ? " failed" : "")\">\(title)</li>"
        }
        return "<section class=\"work\" id=\"\(id)-work\" data-open=\"\(openFlag)\">"
            + "<button type=\"button\" class=\"work-toggle\" data-action=\"\(action)\" data-turn=\"\(turnID)\" aria-expanded=\"\(expanded)\" aria-controls=\"\(id)-work-steps\">"
            + "<span class=\"work-caret\" aria-hidden=\"true\">\(caretSVG())</span>"
            + "<span class=\"work-summary\">\(summary)</span>"
            + "</button>"
            + "<ol class=\"work-steps\" id=\"\(id)-work-steps\">\(items)</ol>"
            + "</section>"
    }

    private static func caretSVG() -> String {
        "<svg viewBox=\"0 0 16 16\" width=\"10\" height=\"10\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.4\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M5.5 3.5 10.5 8 5.5 12.5\"/></svg>"
    }

    private static func iconSVG(_ action: String) -> String {
        let attributes = "viewBox=\"0 0 16 16\" width=\"13\" height=\"13\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.3\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\""
        let path: String
        switch action {
        case "copy":
            path = "<rect x=\"4.5\" y=\"4.5\" width=\"8\" height=\"9\" rx=\"1.5\"/><path d=\"M3 2.5h6a1 1 0 0 1 1 1V4\"/>"
        case "readAloud":
            path = "<path d=\"M3 6.5h2.5l3-2.5v8l-3-2.5H3z\"/><path d=\"M10.5 5.5c1.3 1.3 1.3 3.7 0 5\"/>"
        case "thumbsUp":
            path = "<path d=\"M6 6.5V4a1.5 1.5 0 0 1 3 0v3h3.3a1 1 0 0 1 1 1.2l-1 4.3a1 1 0 0 1-1 .8H6z\"/><path d=\"M2.5 6.5h3.5v7H2.5z\"/>"
        case "thumbsDown":
            path = "<path d=\"M6 9.5V12a1.5 1.5 0 0 0 3 0V9h3.3a1 1 0 0 0 1-1.2l-1-4.3a1 1 0 0 0-1-.8H6z\"/><path d=\"M2.5 2.5h3.5v7H2.5z\"/>"
        case "regenerate":
            path = "<path d=\"M12.5 8a4.5 4.5 0 1 1-1.3-3.2\"/><path d=\"M12.5 2.5V5h-2.5\"/>"
        case "edit":
            path = "<path d=\"M10.5 2.5 13 5l-7 7H3.5V9.5z\"/>"
        case "delete":
            path = "<path d=\"M3.5 4.5h9M6 4.5V3.5a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1v1M5 4.5l.6 8.1a1 1 0 0 0 1 .9h2.8a1 1 0 0 0 1-.9l.6-8.1\"/>"
        default:
            path = ""
        }
        return "<svg \(attributes)>\(path)</svg>"
    }

    /// A snapshot of each turn for diffing against what the page already shows.
    var snapshots: [TranscriptDiff.TurnSnapshot] {
        Self.ordered(turns).map { turn in
            let isStreaming = streaming.contains(turn.id)
            let isWorkOpen = workOpen.contains(turn.id)
            return TranscriptDiff.TurnSnapshot(
                id: turn.id,
                answerInnerHTML: Self.answerInnerHTML(for: turn, streaming: isStreaming),
                articleHTML: Self.html(for: turn, picture: picture(turn), streaming: isStreaming,
                                       workOpen: isWorkOpen))
        }
    }
}