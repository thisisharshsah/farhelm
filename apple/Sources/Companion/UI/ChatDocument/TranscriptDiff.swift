import Foundation

/// Compares the transcript last sent to the page with what it should show
/// now, and picks the smallest change. Pure value type so it can be tested
/// without a web view.
struct TranscriptDiff {
    struct TurnSnapshot: Equatable {
        var id: UUID
        /// The content inside `<section class="answer">`, without the tag.
        var answerInnerHTML: String
        /// The complete `<article>...</article>` for this turn.
        var articleHTML: String
    }

    enum Change: Equatable {
        case unchanged
        /// One element's content changed; update it by its stable id.
        case update(elementID: String, innerHTML: String)
        /// A new turn appeared at the end of the transcript.
        case append(html: String)
        /// A turn was removed from the transcript.
        case remove(elementID: String)
        /// More than one thing changed; replace everything.
        case reload(html: String)
    }

    static func diff(old: [TurnSnapshot], new: [TurnSnapshot]) -> Change {
        if old == new { return .unchanged }

        // One new turn appended at the end, rest unchanged.
        if new.count == old.count + 1,
           new.prefix(old.count).elementsEqual(old) {
            return .append(html: new[new.count - 1].articleHTML)
        }

        // One turn removed, rest unchanged in order.
        if old.count == new.count + 1 {
            let newIDs = Set(new.map(\.id))
            if let removedIndex = old.firstIndex(where: { !newIDs.contains($0.id) }) {
                var remaining = old
                remaining.remove(at: removedIndex)
                if remaining == new {
                    return .remove(elementID: ChatDocument.elementID(old[removedIndex].id))
                }
            }
        }

        // Same turns in the same order, exactly one changed.
        if old.count == new.count, old.map(\.id) == new.map(\.id) {
            var changed: Int?
            for i in old.indices where old[i] != new[i] {
                if changed != nil {
                    return .reload(html: fullHTML(new))
                }
                changed = i
            }
            if let i = changed {
                let id = ChatDocument.elementID(new[i].id)
                if old[i].answerInnerHTML != new[i].answerInnerHTML {
                    return .update(elementID: id + "-answer",
                                   innerHTML: new[i].answerInnerHTML)
                }
                return .reload(html: fullHTML(new))
            }
        }

        return .reload(html: fullHTML(new))
    }

    private static func fullHTML(_ turns: [TurnSnapshot]) -> String {
        turns.map(\.articleHTML).joined(separator: "\n")
    }
}