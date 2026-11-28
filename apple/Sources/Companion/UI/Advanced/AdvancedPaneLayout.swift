import Foundation
import SwiftUI

/// How the board, the task detail and the task chat share the width of
/// the Advanced side. Pure layout, no views.
///
/// Rules:
/// 1. Every shown pane gets at least its minimum readable width.
/// 2. Shown widths plus the gaps between them add up to the available width.
/// 3. When all open panes do not fit at their minimums, the board gives
///    way first: detail and chat keep their place.
/// 4. At compact width (detail and chat together do not fit), only one
///    of them shows, with a switcher between them.
struct AdvancedPaneLayout: Equatable {

    /// Which of detail and chat is in front at compact width.
    enum CompactFocus: Equatable { case detail, chat }

    static let boardMin = Design.PaneWidth.boardMin
    static let detailMin = Design.PaneWidth.detailMin
    static let chatMin = Design.PaneWidth.chatMin

    static let detailPreferred = Design.PaneWidth.detailPreferred
    static let chatPreferred = Design.PaneWidth.chatPreferred

    /// A pane's computed width, or nil when it is not shown.
    let board: CGFloat?
    let detail: CGFloat?
    let chat: CGFloat?

    /// Detail and chat share one slot with a switcher.
    let compact: Bool

    private let storedGap: CGFloat

    /// All shown widths plus gaps between them.
    var total: CGFloat {
        let panes = [board, detail, chat].compactMap { $0 }
        return panes.reduce(0, +) + max(0, CGFloat(panes.count - 1)) * storedGap
    }

    init(available: CGFloat,
         gap: CGFloat,
         boardOpen: Bool,
         detailOpen: Bool,
         chatOpen: Bool,
         focus: CompactFocus = .detail) {

        self.storedGap = gap

        struct Candidate {
            let id: String
            let min: CGFloat
            let preferred: CGFloat
            let fills: Bool
        }

        var open: [Candidate] = []
        if boardOpen { open.append(Candidate(id: "board", min: Self.boardMin, preferred: 0, fills: true)) }
        if detailOpen { open.append(Candidate(id: "detail", min: Self.detailMin, preferred: Self.detailPreferred, fills: false)) }
        if chatOpen { open.append(Candidate(id: "chat", min: Self.chatMin, preferred: Self.chatPreferred, fills: false)) }

        guard !open.isEmpty else {
            self.board = nil; self.detail = nil; self.chat = nil; self.compact = false
            return
        }

        func gaps(_ count: Int) -> CGFloat {
            max(0, CGFloat(count - 1)) * gap
        }

        func room(_ candidates: [Candidate]) -> CGFloat {
            max(0, available - gaps(candidates.count))
        }

        func fits(_ candidates: [Candidate]) -> Bool {
            candidates.reduce(CGFloat(0)) { $0 + $1.min } <= room(candidates)
        }

        if fits(open) {
            let r = room(open)
            var widths: [String: CGFloat] = [:]
            for c in open { widths[c.id] = c.min }
            var spare = r - open.reduce(CGFloat(0)) { $0 + $1.min }
            for c in open where !c.fills && c.preferred > c.min {
                let grow = min(c.preferred - c.min, spare)
                widths[c.id, default: 0] += grow
                spare -= grow
            }
            let filler = open.first(where: \.fills) ?? open[0]
            widths[filler.id, default: 0] += spare
            self.board = widths["board"]
            self.detail = widths["detail"]
            self.chat = widths["chat"]
            self.compact = false
            return
        }

        // Not all fit: the board gives way first.
        if boardOpen {
            let rest = open.filter { $0.id != "board" }
            if !rest.isEmpty, fits(rest) {
                let r = room(rest)
                var widths: [String: CGFloat] = [:]
                for c in rest { widths[c.id] = c.min }
                var spare = r - rest.reduce(CGFloat(0)) { $0 + $1.min }
                for c in rest where !c.fills && c.preferred > c.min {
                    let grow = min(c.preferred - c.min, spare)
                    widths[c.id, default: 0] += grow
                    spare -= grow
                }
                let filler = rest.first { $0.id == "detail" } ?? rest[0]
                widths[filler.id, default: 0] += spare
                self.board = nil
                self.detail = widths["detail"]
                self.chat = widths["chat"]
                self.compact = false
                return
            }
        }

        // Compact: only one of detail and chat.
        self.compact = detailOpen && chatOpen
        let pick: String
        if detailOpen && chatOpen {
            pick = focus == .detail ? "detail" : "chat"
        } else if detailOpen {
            pick = "detail"
        } else if chatOpen {
            pick = "chat"
        } else {
            pick = "board"
        }
        self.board = pick == "board" ? available : nil
        self.detail = pick == "detail" ? available : nil
        self.chat = pick == "chat" ? available : nil
    }
}

// MARK: - Environment

private struct BoardCompactKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when the board, detail and chat cannot all fit at their
    /// minimums in the full main span. Set by OverlayView; read by
    /// BoardPane to show the detail/chat switcher.
    var boardCompact: Bool {
        get { self[BoardCompactKey.self] }
        set { self[BoardCompactKey.self] = newValue }
    }
}