import SwiftUI

// The searchable picker: a glass panel with a search field, grouped
// sections, rows with an icon, a title, a one-line description and badges,
// a check mark on the current choice, and recent choices on top. Typing
// filters, the arrow keys move, Return chooses and Escape closes, all
// without the mouse. Rows are read by VoiceOver as buttons with the title,
// then the description and badges, and the current one as selected.

struct SearchablePicker<ID: Hashable>: View {
    let title: String
    let sections: [SelectionSection<ID>]
    var selection: ID?
    var recents: [ID]
    var prompt: String
    var maxHeight: CGFloat
    /// Draws its own glass panel. Off inside a popover, which has its own.
    var framed: Bool
    /// Puts the cursor in the search field when it appears.
    var autoFocus: Bool
    var footer: SelectionFooter?
    let onSelect: (ID) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var highlighted: String?
    @State private var scrollTarget: String?
    @State private var contentHeight: CGFloat = 0
    @FocusState private var focused: Bool
    @Environment(\.density) private var density
    private var access = DesignAccess()

    init(title: String, sections: [SelectionSection<ID>], selection: ID? = nil, recents: [ID] = [],
         prompt: String = "Search", maxHeight: CGFloat = 340, framed: Bool = true, autoFocus: Bool = true,
         footer: SelectionFooter? = nil, onSelect: @escaping (ID) -> Void, onClose: @escaping () -> Void = {}) {
        self.title = title
        self.sections = sections
        self.selection = selection
        self.recents = recents
        self.prompt = prompt
        self.maxHeight = maxHeight
        self.framed = framed
        self.autoFocus = autoFocus
        self.footer = footer
        self.onSelect = onSelect
        self.onClose = onClose
    }

    // MARK: What is listed

    struct Row: Identifiable {
        let id: String
        let item: SelectionItem<ID>
    }

    struct Block: Identifiable {
        let id: String
        let title: String
        let symbol: String?
        let rows: [Row]
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// The sections that match the search, with the recent choices first
    /// while nothing is typed.
    private var blocks: [Block] {
        var result: [Block] = []
        if trimmedQuery.isEmpty, !recents.isEmpty {
            let all = sections.flatMap(\.items)
            let items = recents.compactMap { id in all.first { $0.id == id } }.filter { !$0.isDisabled }
            if !items.isEmpty {
                result.append(Block(id: "recent", title: "Recent", symbol: "clock",
                                    rows: items.enumerated().map { Row(id: "recent/\($0.offset)", item: $0.element) }))
            }
        }
        for section in sections {
            let items = section.items.filter {
                SelectionSearch.matches($0.searchText + " " + section.title, query: trimmedQuery)
            }
            guard !items.isEmpty else { continue }
            result.append(Block(id: section.id, title: section.title, symbol: section.symbol,
                                rows: items.enumerated().map { Row(id: "\(section.id)/\($0.offset)", item: $0.element) }))
        }
        return result
    }

    /// The rows the arrow keys can reach.
    private var navigable: [Row] {
        blocks.flatMap(\.rows).filter { !$0.item.isDisabled }
    }

    // MARK: Actions

    private func move(_ step: Int) {
        let rows = navigable
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == highlighted }
        let next = index.map { min(max($0 + step, 0), rows.count - 1) } ?? (step > 0 ? 0 : rows.count - 1)
        highlighted = rows[next].id
        scrollTarget = rows[next].id
    }

    private func commit() {
        let rows = navigable
        guard let row = rows.first(where: { $0.id == highlighted }) ?? rows.first else { return }
        choose(row.item)
    }

    private func choose(_ item: SelectionItem<ID>) {
        guard !item.isDisabled else { return }
        onSelect(item.id)
    }

    private func resetHighlight() {
        let rows = navigable
        highlighted = rows.first { selection != nil && $0.item.id == selection }?.id ?? rows.first?.id
        scrollTarget = highlighted
    }

    private func announceResults() {
        let count = navigable.count
        let text = count == 0 ? "No matches" : (count == 1 ? "1 match" : "\(count) matches")
        AccessibilityNotification.Announcement(text).post()
    }

    // MARK: Body

    var body: some View {
        panel
            .frame(minWidth: 240)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
            .onExitCommand(perform: onClose)
            .onKeyPress(.escape) { onClose(); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onAppear { resetHighlight() }
            .task { if autoFocus { focused = true } }
            .onChange(of: query) {
                highlighted = navigable.first?.id
                scrollTarget = nil
                announceResults()
            }
    }

    @ViewBuilder
    private var panel: some View {
        if framed {
            content.glassPanel(radius: Design.Radius.card)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if blocks.isEmpty {
                emptyState
            } else {
                list
            }
            if let footer {
                Divider()
                footerButton(footer)
            }
        }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: Design.Space.xs) {
            Image(systemName: "magnifyingglass")
                .iconWidth(density.icon)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $query)
                .textFieldStyle(.plain)
                .textRole(density.textRole)
                .focused($focused)
                .onSubmit(commit)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .accessibilityLabel("Search \(title)")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").iconWidth(density.icon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, density.inset)
        .frame(minHeight: density.rowHeight + Design.Space.xs)
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.xxs) {
                    ForEach(blocks) { block in
                        header(block)
                        ForEach(block.rows) { row in rowView(row) }
                    }
                }
                .padding(Design.Space.xxs)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: contentHeight > 0 ? min(contentHeight, maxHeight) : Design.Space.xxl * 3)
            .onChange(of: scrollTarget) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func header(_ block: Block) -> some View {
        HStack(spacing: Design.Space.xs) {
            if let symbol = block.symbol {
                Image(systemName: symbol).iconWidth(.small)
            }
            Text(block.title)
            Spacer(minLength: 0)
        }
        .textRole(.caption, .secondary)
        .padding(.horizontal, density.gap)
        .padding(.top, Design.Space.xs)
        .padding(.bottom, Design.Space.xxs / 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func rowView(_ row: Row) -> some View {
        let item = row.item
        let current = selection == item.id
        let traits: AccessibilityTraits = current ? [.isButton, .isSelected] : [.isButton]
        let shape = Design.Radius.shape(Design.Radius.concentric(Design.Radius.card, inset: Design.Space.xxs))
        let tint = Design.Tone.accent.color.opacity(access.highContrast ? 0.3 : 0.16)
        return Button { choose(item) } label: {
            SelectionRowContent(title: item.title, subtitle: item.subtitle, symbol: item.symbol,
                                badges: item.badges, current: current, disabled: item.isDisabled)
        }
        .buttonStyle(.plain)
        .disabled(item.isDisabled)
        .background(highlighted == row.id ? tint : Color.clear, in: shape)
        .id(row.id)
        .onHover { inside in
            if inside, !item.isDisabled { highlighted = row.id }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.spokenDetail)
        .accessibilityAddTraits(traits)
    }

    // MARK: Empty state and footer

    private var emptyState: some View {
        let nothingToChoose = sections.allSatisfy { $0.items.isEmpty }
        return VStack(spacing: Design.Space.xs) {
            Image(systemName: nothingToChoose ? "tray" : "magnifyingglass")
                .font(Design.Icon.large.font)
                .foregroundStyle(.secondary)
            Text(nothingToChoose ? "Nothing to choose yet" : "No matches").textRole(.heading)
            Text(nothingToChoose ? "Nothing is available for \(title.lowercased()) right now."
                 : "Nothing matches \u{201C}\(trimmedQuery)\u{201D}. Try another word.")
                .textRole(.label, .secondary)
                .multilineTextAlignment(.center)
            if !nothingToChoose {
                Button("Clear search") { query = "" }
                    .glassButton(size: density.control)
            }
        }
        .padding(Design.Space.l)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func footerButton(_ footer: SelectionFooter) -> some View {
        Button(action: footer.action) {
            HStack(spacing: density.gap) {
                if let symbol = footer.symbol {
                    Image(systemName: symbol).iconWidth(density.icon)
                }
                Text(footer.title)
                Spacer(minLength: 0)
            }
            .textRole(density.textRole, .secondary)
            .padding(.horizontal, density.inset)
            .frame(minHeight: density.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - A row

struct SelectionRowContent: View {
    let title: String
    let subtitle: String?
    let symbol: String?
    let badges: [SelectionBadge]
    let current: Bool
    let disabled: Bool
    @Environment(\.density) private var density

    var body: some View {
        HStack(alignment: .center, spacing: density.gap) {
            if let symbol {
                Image(systemName: symbol)
                    .iconWidth(density.icon)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Design.Space.xxs / 2) {
                Text(title)
                    .textRole(density.textRole)
                    .fontWeight(current ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .textRole(.caption, .secondary)
                        .lineLimit(1)
                }
                if !badges.isEmpty {
                    FlowLayout(spacing: Design.Space.xxs) {
                        ForEach(badges, id: \.self) { SelectionBadgeView(badge: $0) }
                    }
                    .padding(.top, Design.Space.xxs / 2)
                }
            }
            Spacer(minLength: 0)
            // Always there, so titles line up whether or not it is shown.
            Image(systemName: "checkmark")
                .iconWidth(density.icon)
                .foregroundStyle(Design.Tone.accent.color)
                .opacity(current ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, density.gap)
        .padding(.vertical, density == .compact ? Design.Space.xxs : Design.Space.xs)
        .frame(minHeight: density.rowHeight)
        .contentShape(Rectangle())
        .opacity(disabled ? 0.5 : 1)
    }
}

// MARK: - A button that opens it

/// A button showing the current choice that opens the picker in a popover.
struct SearchablePickerButton<ID: Hashable>: View {
    let title: String
    let sections: [SelectionSection<ID>]
    @Binding var selection: ID
    @State private var open = false
    @State private var lately: [ID] = []
    @Environment(\.density) private var density

    init(title: String, sections: [SelectionSection<ID>], selection: Binding<ID>) {
        self.title = title
        self.sections = sections
        self._selection = selection
    }

    private var current: SelectionItem<ID>? {
        sections.flatMap(\.items).first { $0.id == selection }
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: Design.Space.xs) {
                if let symbol = current?.symbol { Image(systemName: symbol) }
                Text(current?.title ?? "Choose")
                Image(systemName: "chevron.up.chevron.down")
                    .font(Design.Icon.small.font)
                    .foregroundStyle(.secondary)
            }
        }
        .glassButton(size: density.control)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SearchablePicker(title: title, sections: sections, selection: selection, recents: lately,
                             framed: false, onSelect: { id in
                                 selection = id
                                 lately = Array(([id] + lately.filter { $0 != id }).prefix(3))
                                 open = false
                             }, onClose: { open = false })
                .frame(width: 340)
        }
        .accessibilityLabel(title)
        .accessibilityValue(current?.title ?? "None")
        .accessibilityHint("Opens a list you can search")
    }
}