import AppKit
import SwiftUI

/// The command bar: one place to go anywhere. Words search the web, an
/// address goes there, and as it is typed it finds open tabs, the project's
/// pinned pages and pages from history; about a page, it also offers what
/// to do with it (ask the chat about it, pin it, copy its link, split view).
/// It floats over the page (⌘L, or a click on the address) and it is the
/// search on a new tab's start page (⌘T). Arrows choose, Return goes, ⌘Return
/// opens in a new tab, Escape lets it go.
struct BrowserCommandBar<Model: BrowsingModel>: View {
    enum Style {
        /// Over the page it is about.
        case floating
        /// Set into a new tab's start page.
        case startPage
    }

    /// One thing it offers.
    struct Row: Identifiable {
        let id: String
        let title: String
        var detail = ""
        var symbol = "globe"
        /// The site's own icon, when it has one.
        var icon: NSImage? = nil
        /// What Return does with it, said while it is chosen.
        var hint = ""
        let run: (_ newTab: Bool) -> Void
    }

    @EnvironmentObject var app: AppState
    @ObservedObject var web: Model
    /// The tab it is about: the page showing, or the new tab it starts from.
    @ObservedObject var tab: Model.Tab
    @ObservedObject private var history: BrowserHistory
    @ObservedObject private var pins = BrowserPins.shared
    @ObservedObject private var ui = BrowserUI.shared
    let style: Style
    /// Words are in it: the start page makes room for what it finds.
    @Binding var searching: Bool
    /// Lets it go (floating): a choice was made, or Escape.
    let close: () -> Void

    @State private var query = ""
    /// What it was opened with (the page's address), so only what the
    /// person types counts as a search.
    @State private var prefill = ""
    @State private var selection = 0
    /// Bumped to put the keys in its field.
    @State private var focus = 0

    init(web: Model, tab: Model.Tab, style: Style, searching: Binding<Bool> = .constant(false),
         close: @escaping () -> Void) {
        self.web = web
        self.tab = tab
        self.history = web.history
        self.style = style
        self._searching = searching
        self.close = close
    }

    private static var rowHeight: CGFloat { 40 }
    private static var radius: CGFloat { 16 }

    /// What was typed, trimmed. Nothing while a floating bar still holds
    /// the address it opened with.
    private var words: String {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return style == .floating && query == prefill ? "" : text
    }

    /// Whether the list shows: always over a page; on the start page, once
    /// there are words.
    private var listing: Bool { style == .floating || !words.isEmpty }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            field(rows)
            if listing, !rows.isEmpty {
                Rectangle()
                    .fill(Theme.ink.opacity(0.08))
                    .frame(height: 1)
                list(rows)
            }
        }
        .frame(maxWidth: 580)
        // It sits over a page, so it needs a solid base under its glass.
        .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .fill(Theme.shade.opacity(style == .floating ? (Theme.isLight ? 0.94 : 0.88) : (Theme.isLight ? 0.6 : 0.2))))
        .liquidGlass(in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .glassBorder(radius: Self.radius, tint: style == .floating ? Theme.accent : nil)
        .onAppear {
            if style == .floating {
                prefill = tab.url?.absoluteString ?? ""
                query = prefill
                focus += 1
            } else if ui.focusTab == tab.id {
                ui.focusTab = nil
                focus += 1
            }
        }
        .onChange(of: ui.focusTab) { _, id in
            guard style == .startPage, id == tab.id else { return }
            ui.focusTab = nil
            focus += 1
        }
        .onChange(of: query) { _, _ in
            selection = 0
            if style == .startPage { searching = !words.isEmpty }
        }
    }

    // MARK: The field

    private func field(_ rows: [Row]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 18)
            CommandField(text: $query, placeholder: "Search or enter an address", focus: focus,
                         selectAll: style == .floating,
                         onMove: { step in move(step, among: rows.count) },
                         onSubmit: { newTab in
                             guard listing, rows.indices.contains(selection) else { return }
                             choose(rows[selection], newTab: newTab)
                         },
                         onCancel: cancel)
                .frame(height: 22)
            if style == .floating {
                Text("esc")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.ink.opacity(0.5))
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(Capsule().fill(Theme.ink.opacity(0.08)))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    // MARK: The list

    private func list(_ rows: [Row]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { position, row in
                        // Known by the row's own id only: a second id (its
                        // place in the list) made SwiftUI keep showing the
                        // row that was there before.
                        rowView(row, chosen: position == selection)
                            .onTapGesture { choose(row, newTab: NSEvent.modifierFlags.contains(.command)) }
                            .onHover { inside in
                                if inside { selection = position }
                            }
                    }
                }
                .padding(6)
            }
            // As tall as what it lists, up to eight rows.
            .frame(height: min(CGFloat(rows.count), 8) * (Self.rowHeight + 1) + 12)
            .onChange(of: selection) { _, position in
                if rows.indices.contains(position) { proxy.scrollTo(rows[position].id) }
            }
        }
    }

    private func rowView(_ row: Row, chosen: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon = row.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                } else {
                    Image(systemName: row.symbol)
                        .font(BrowserChrome.symbol)
                        .foregroundStyle(chosen ? Theme.accent : BrowserChrome.icon)
                }
            }
            .frame(width: BrowserChrome.button, height: BrowserChrome.button)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(Theme.ink.opacity(0.07)))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            if chosen, !row.hint.isEmpty {
                HStack(spacing: 4) {
                    Text(row.hint)
                    Image(systemName: "return")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.5))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: BrowserChrome.rowRadius, style: .continuous)
            .fill(chosen ? BrowserChrome.chosen : Color.clear))
        .contentShape(Rectangle())
    }

    // MARK: What it offers

    private var rows: [Row] {
        let words = self.words
        var list: [Row] = []
        if !words.isEmpty, let url = BrowserModel.url(from: words) {
            if Self.isAddress(words) {
                list.append(Row(id: "go", title: url.absoluteString, detail: "Go to this address",
                                symbol: "arrow.up.forward.circle", hint: "Go") { newTab in web.go(url, from: tab, newTab: newTab) })
            } else {
                list.append(Row(id: "search", title: words, detail: "Search the web",
                                symbol: "magnifyingglass", hint: "Search") { newTab in web.go(url, from: tab, newTab: newTab) })
            }
        }
        let actions = self.actions.filter { words.isEmpty || $0.title.localizedCaseInsensitiveContains(words) }
        // Over a page, before anything is typed: what to do with it first.
        if words.isEmpty { list += actions }
        list += tabRows(words)
        list += pinRows(words)
        if !words.isEmpty {
            list += historyRows(words)
            list += actions
        }
        return list
    }

    /// Open tabs: the others, or those that match.
    private func tabRows(_ words: String) -> [Row] {
        let found = web.tabs.filter { other in
            other.id != tab.id && !other.isBlank
                && (words.isEmpty || Self.matches(words, other.label, other.url?.absoluteString))
        }
        return found.prefix(words.isEmpty ? 6 : 5).map { other in
            Row(id: "tab-\(other.id)", title: other.label, detail: Self.site(other.url), symbol: "square.on.square",
                icon: other.url.flatMap { history.icon(for: $0.absoluteString) }, hint: "Switch to Tab") { _ in
                web.leave(tab, for: other)
            }
        }
    }

    /// The project's pinned pages.
    private func pinRows(_ words: String) -> [Row] {
        let pinned = pins.pins(for: app.conversation.projectID)
            .filter { words.isEmpty || Self.matches(words, $0.name, $0.url) }
        return pinned.prefix(4).map { pin in
            Row(id: "pin-\(pin.id)", title: pin.name, detail: pin.host, symbol: "pin",
                icon: history.icon(for: pin.url), hint: "Open") { _ in
                web.openPin(pin, from: tab)
            }
        }
    }

    /// Pages from history that match, not already open.
    private func historyRows(_ words: String) -> [Row] {
        let open = Set(web.tabs.compactMap { $0.url?.absoluteString })
        let found = history.pages.filter { !open.contains($0.url) && Self.matches(words, $0.title, $0.url) }
        return found.prefix(6).map { page in
            Row(id: "page-\(page.url)", title: page.title.isEmpty ? page.host : page.title, detail: page.host,
                symbol: "clock", icon: history.icon(for: page.url), hint: "Open") { newTab in
                if let url = URL(string: page.url) { web.go(url, from: tab, newTab: newTab) }
            }
        }
    }

    /// What can be done with the page it is about, and with the tabs.
    private var actions: [Row] {
        var list: [Row] = []
        let project = app.conversation.projectID
        if style == .floating, !tab.isBlank, let url = tab.url {
            let about = tab
            list.append(Row(id: "ask", title: "Ask about this page",
                            detail: "It goes with your next message, with what you selected on it",
                            symbol: "sparkles", hint: "Ask") { _ in BrowserActions.ask(about: about) })
            if web.tabs.filter({ !$0.isBlank }).count > 1 {
                list.append(Row(id: "askAll", title: "Ask about all open tabs",
                                detail: "Every open page goes with your next message",
                                symbol: "sparkles.rectangle.stack", hint: "Ask") { _ in
                    BrowserActions.askAboutAll(in: web)
                })
            }
            let pinned = pins.pin(for: url, in: project) != nil
            list.append(Row(id: "pin", title: pinned ? "Unpin this page" : "Pin this page",
                            detail: pinned ? "Take it off this project's pinned pages"
                                : "Keep it at hand in every chat of this project",
                            symbol: pinned ? "pin.slash" : "pin", hint: pinned ? "Unpin" : "Pin") { _ in
                BrowserPins.shared.toggle(url, title: about.label, in: project)
            })
            list.append(Row(id: "copy", title: "Copy link", detail: url.absoluteString, symbol: "link",
                            hint: "Copy") { _ in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            })
            list.append(Row(id: "split", title: web.split == nil ? "Split view" : "Close split view",
                            detail: web.split == nil ? "This page beside the next tab" : "Back to one page",
                            symbol: "square.split.2x1") { _ in BrowserActions.toggleSplit(web) })
            list.append(Row(id: "outside", title: "Open in default browser", detail: url.host ?? "",
                            symbol: "safari") { _ in NSWorkspace.shared.open(url) })
        }
        if web.canReopen {
            list.append(Row(id: "reopen", title: "Reopen closed tab", detail: "⇧⌘T",
                            symbol: "arrow.uturn.backward") { _ in web.reopenClosed() })
        }
        let current = tab.id
        if BrowserEngine.chromium, web.tabs.contains(where: { $0.id != current && !$0.isBlank && !$0.asleep }) {
            list.append(Row(id: "sleep", title: "Put other tabs to sleep",
                            detail: "They give back their memory, and wake when shown",
                            symbol: "moon.zzz") { _ in web.sleepOthers() })
        }
        return list
    }

    // MARK: Doing it

    private func choose(_ row: Row, newTab: Bool) {
        row.run(newTab)
        query = ""
        prefill = ""
        if style == .startPage { searching = false }
        close()
    }

    private func move(_ step: Int, among count: Int) {
        guard count > 0 else { return }
        selection = ((selection + step) % count + count) % count
    }

    private func cancel() {
        if style == .floating {
            close()
        } else {
            query = ""
        }
    }

    // MARK: Matching

    /// Words that are an address rather than a search, as
    /// `BrowserModel.url(from:)` reads them.
    private static func isAddress(_ text: String) -> Bool {
        if let url = URL(string: text), url.scheme?.hasPrefix("http") == true { return true }
        return !text.contains(" ") && text.contains(".")
    }

    private static func matches(_ words: String, _ texts: String?...) -> Bool {
        texts.contains { $0?.localizedCaseInsensitiveContains(words) == true }
    }

    private static func site(_ url: URL?) -> String {
        guard let host = url?.host else { return url?.absoluteString ?? "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// The command bar's field: AppKit's own text field, so the arrow keys,
/// Return and Escape reach the bar the way the field editor takes them, and
/// an address can be chosen whole to type over.
struct CommandField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// Bumped to put the keys here.
    var focus: Int
    /// The whole text is chosen when the keys arrive, to type over.
    var selectAll = false
    let onMove: (Int) -> Void
    let onSubmit: (_ newTab: Bool) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13.5)
        field.placeholderString = placeholder
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.stringValue = text
        context.coordinator.ticket = focus
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.textColor = NSColor(Theme.ink)
        // The system's placeholder gray follows the window's appearance,
        // which a glass panel does not always carry; this one follows the
        // theme, so it shows on dark and light alike.
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor(Theme.ink).withAlphaComponent(0.42),
            .font: field.font ?? NSFont.systemFont(ofSize: 13.5),
        ])
        field.selectsAll = selectAll
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.ticket != focus {
            context.coordinator.ticket = focus
            field.wantsKeys = true
            field.takeKeys()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandField
        /// The focus asked for last.
        var ticket = 0

        init(_ parent: CommandField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
                parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(NSEvent.modifierFlags.contains(.command))
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            default:
                return false
            }
            return true
        }
    }

    final class Field: NSTextField {
        var selectsAll = false
        /// The keys are wanted here as soon as it is in a window.
        var wantsKeys = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if wantsKeys { takeKeys() }
        }

        func takeKeys() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.wantsKeys = false
                // A page (a Chromium window of its own) may have the keys.
                if !window.isKeyWindow, window.canBecomeKey { window.makeKey() }
                window.makeFirstResponder(self)
                if self.selectsAll {
                    self.currentEditor()?.selectAll(nil)
                } else {
                    self.currentEditor()?.moveToEndOfDocument(nil)
                }
            }
        }
    }
}
