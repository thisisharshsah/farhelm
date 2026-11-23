import SwiftUI

// What the selection controls share: the items they list, the badges on a
// row, text matching for search, and a layout that wraps chips onto lines.
// The controls themselves are in this folder; apple/Design/README.md has the
// rules for using them.

/// A small label on a row or chip: where a model runs, what it costs, how
/// much it can read. Its tone gives it a tint; the words carry the meaning.
struct SelectionBadge: Hashable {
    var text: String
    var symbol: String?
    var tone: Design.Tone

    init(_ text: String, symbol: String? = nil, tone: Design.Tone = .neutral) {
        self.text = text
        self.symbol = symbol
        self.tone = tone
    }
}

/// One choice in a searchable picker.
struct SelectionItem<ID: Hashable>: Identifiable {
    let id: ID
    var title: String
    var subtitle: String?
    var symbol: String?
    var badges: [SelectionBadge]
    /// Words that find the item in a search without being shown.
    var keywords: [String]
    var isDisabled: Bool

    init(id: ID, title: String, subtitle: String? = nil, symbol: String? = nil,
         badges: [SelectionBadge] = [], keywords: [String] = [], isDisabled: Bool = false) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.badges = badges
        self.keywords = keywords
        self.isDisabled = isDisabled
    }

    /// Everything a search looks through.
    var searchText: String {
        ([title, subtitle ?? ""] + badges.map(\.text) + keywords).joined(separator: " ")
    }

    /// What VoiceOver says after the title.
    var spokenDetail: String {
        ([subtitle] + badges.map(\.text)).compactMap { $0 }.joined(separator: ", ")
    }
}

/// A titled group of items, such as the models that run on this Mac.
struct SelectionSection<ID: Hashable>: Identifiable {
    let id: String
    var title: String
    var symbol: String?
    var items: [SelectionItem<ID>]

    init(id: String, title: String, symbol: String? = nil, items: [SelectionItem<ID>]) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.items = items
    }
}

/// A row after the list of items, such as "Add or change engines".
struct SelectionFooter {
    var title: String
    var symbol: String?
    var action: () -> Void

    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }
}

enum SelectionSearch {
    /// Whether every word of the query is found in the text, ignoring case
    /// and accents. An empty query matches everything.
    static func matches(_ text: String, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        return words.allSatisfy {
            text.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

/// The choices a person made lately, newest first, kept in the user defaults.
struct RecentChoices {
    let key: String
    var limit = 3

    func ids() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func record(_ id: String) {
        var list = ids().filter { $0 != id }
        list.insert(id, at: 0)
        UserDefaults.standard.set(Array(list.prefix(limit)), forKey: key)
    }
}

// MARK: - Badge

struct SelectionBadgeView: View {
    let badge: SelectionBadge

    var body: some View {
        HStack(spacing: Design.Space.xxs) {
            if let symbol = badge.symbol {
                Image(systemName: symbol).foregroundStyle(badge.tone.color)
            }
            Text(badge.text).lineLimit(1)
        }
        .textRole(.caption, .secondary)
        .padding(.horizontal, Design.Space.xs)
        .padding(.vertical, Design.Space.xxs / 2)
        .background(badge.tone.color.opacity(0.16), in: Design.Radius.shape(Design.Radius.chip))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Wrapping layout

/// Puts its views in lines, starting a new line when one does not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = Design.Space.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in placed.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                                  proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        var origins: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + lineHeight), origins)
    }
}