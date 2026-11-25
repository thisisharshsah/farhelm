import AppKit
import SwiftUI

/// Find in page (⌘F): the words, where among the matches the page is, and
/// the way to the next and the one before (Return and ⇧Return, the arrows,
/// ⌘G and ⇧⌘G). It runs the page's own find, so it is the same on both
/// engines. Escape, or a click anywhere else, lets it go; what it found
/// stays chosen on the page.
struct FindBar<Tab: BrowsingTab>: View {
    @ObservedObject var tab: Tab
    let close: () -> Void
    @ObservedObject private var ui = BrowserUI.shared
    @State private var query = ""
    /// How many times the words are on the page, and which one is chosen.
    @State private var count = 0
    @State private var place = 0
    /// Bumped to put the keys in its field.
    @State private var focus = 0
    /// The search under way, so a later one is not overtaken by it.
    @State private var search = 0

    private static var radius: CGFloat { 12 }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(BrowserChrome.symbol)
                .foregroundStyle(Theme.accent)
                .frame(width: 18)
            CommandField(text: $query, placeholder: "Find in page", focus: focus, selectAll: true,
                         onMove: { step in find(back: step < 0) },
                         onSubmit: { _ in find(back: NSEvent.modifierFlags.contains(.shift)) },
                         onCancel: close)
                .frame(height: 22)
            if !query.isEmpty {
                Text(count == 0 ? "No matches" : "\(place) of \(count)")
                    .font(BrowserChrome.note)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink.opacity(0.55))
                    .fixedSize()
            }
            InlineButton("chevron.up", help: "Previous (⇧⌘G)") { find(back: true) }
                .disabled(count == 0)
            InlineButton("chevron.down", help: "Next (⌘G)") { find(back: false) }
                .disabled(count == 0)
            InlineButton("xmark", help: "Done (esc)", action: close)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // It sits over a page, so it needs a solid base under its glass.
        .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .fill(Theme.shade.opacity(Theme.isLight ? 0.94 : 0.88)))
        .liquidGlass(in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .glassBorder(radius: Self.radius, tint: Theme.accent)
        .onAppear {
            query = ui.findQuery
            focus += 1
            if !query.isEmpty { find(back: false, fresh: true) }
        }
        .onChange(of: query) { _, words in
            ui.findQuery = words
            find(back: false, fresh: true)
        }
        .onChange(of: ui.findForward) { _, _ in find(back: false) }
        .onChange(of: ui.findBackward) { _, _ in find(back: true) }
        .onChange(of: ui.findFocus) { _, _ in focus += 1 }
    }

    /// Goes to the next match (or the one before). A fresh search starts
    /// from the top of the page.
    private func find(back: Bool, fresh: Bool = false) {
        let words = query
        guard !words.isEmpty else {
            count = 0
            place = 0
            return
        }
        search += 1
        let ticket = search
        Task { @MainActor in
            let found = await tab.run(Self.script(words, back: back, fresh: fresh)) as? [String: Any]
            guard ticket == search else { return }
            let total = (found?["count"] as? NSNumber)?.intValue ?? 0
            let moved = (found?["found"] as? NSNumber)?.boolValue ?? false
            count = total
            if total == 0 || !moved {
                place = 0
                if !moved { count = 0 }
            } else if fresh || place == 0 {
                place = back ? total : 1
            } else {
                place = back ? (place - 2 + total) % total + 1 : place % total + 1
            }
        }
    }

    /// The page's side: counts the matches in what the page shows, and
    /// moves the page's own selection to the next one, round the ends.
    private static func script(_ words: String, back: Bool, fresh: Bool) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: words, options: [.fragmentsAllowed])) ?? Data("\"\"".utf8)
        let literal = String(decoding: data, as: UTF8.self)
        return """
        const words = \(literal);
        const text = (document.body ? document.body.innerText : '').toLowerCase();
        const needle = words.toLowerCase();
        let count = 0;
        for (let at = text.indexOf(needle); at !== -1; at = text.indexOf(needle, at + needle.length)) count++;
        if (\(fresh) && window.getSelection) window.getSelection().removeAllRanges();
        const found = window.find(words, false, \(back), true, false, false, false);
        return { count: count, found: !!found };
        """
    }
}
