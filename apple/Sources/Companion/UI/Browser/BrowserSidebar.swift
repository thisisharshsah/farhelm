import AppKit
import SwiftUI

/// The tabs beside the page in a wide browser, as in Arc and Zen: the way
/// back and forward and the address at the top, the project's pinned pages
/// as tiles, then the tabs one per line, in an order to drag them into. It
/// tucks away (⇧⌘L) for the page to have the room, and the compact bar
/// takes its place.
struct BrowserSidebar<Model: BrowsingModel>: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var web: Model
    /// Watched for sites' icons arriving.
    @ObservedObject private var history: BrowserHistory
    @ObservedObject private var ui = BrowserUI.shared
    @ObservedObject private var pins = BrowserPins.shared

    /// The tab being dragged to a new place, and how far it has gone.
    @State private var dragging: UUID?
    @State private var dragOffset: CGFloat = 0

    init(web: Model) {
        self.web = web
        self.history = web.history
    }

    private static var rowHeight: CGFloat { BrowserChrome.row }
    private static var rowSpacing: CGFloat { 2 }
    /// From one tab's line to the next.
    private static var pitch: CGFloat { rowHeight + rowSpacing }

    var body: some View {
        let pinned = pins.pins(for: app.conversation.projectID)
        VStack(alignment: .leading, spacing: 8) {
            top
            if let tab = web.current {
                AddressCapsule(tab: tab, active: ui.commandBar) {
                    BrowserActions.perform(.openLocation, on: web)
                }
            }
            if !pinned.isEmpty {
                pinGrid(pinned)
            }
            Rectangle()
                .fill(Theme.ink.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 4)
            NewTabRow { BrowserActions.perform(.newTab, on: web) }
            tabList
            footer
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
    }

    // MARK: Parts

    private var top: some View {
        HStack(spacing: 1) {
            BarButton("sidebar.left", help: "Hide the tab sidebar (⇧⌘L)") {
                BrowserActions.perform(.toggleSidebar, on: web)
            }
            Spacer(minLength: 0)
            if let tab = web.current {
                NavButtons(tab: tab)
                ReloadButton(tab: tab)
                AskButton(tab: tab)
            }
        }
    }

    /// The project's pinned pages, four to a line. A dot marks one open in
    /// a tab; a click goes to that tab, or opens the page.
    private func pinGrid(_ pinned: [BrowserPin]) -> some View {
        let open = Set(web.tabs.compactMap { $0.url?.host })
        let project = app.conversation.projectID
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(pinned) { pin in
                PinTile(pin: pin, icon: history.icon(for: pin.url), size: 34, named: false,
                        open: URL(string: pin.url)?.host.map(open.contains) ?? false) {
                    web.openPin(pin, from: web.current)
                } unpin: {
                    BrowserPins.shared.unpin(pin.id, in: project)
                }
            }
        }
    }

    private var tabList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: Self.rowSpacing) {
                ForEach(Array(web.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabRow(tab: tab, history: history, selected: tab.id == web.current?.id,
                           paired: web.splitTab?.id == tab.id,
                           select: { web.show(tab.id) },
                           close: { BrowserActions.close(tab, in: web) })
                        .contextMenu { menu(for: tab) }
                        .offset(y: offset(of: tab, at: index))
                        .zIndex(dragging == tab.id ? 1 : 0)
                        .animation(dragging == tab.id ? nil : .spring(response: 0.26, dampingFraction: 0.86),
                                   value: dropIndex)
                        .gesture(drag(tab))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: web.tabs.map(\.id))
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var footer: some View {
        HStack(spacing: 1) {
            BarButton("square.split.2x1", help: web.splitTab == nil ? "Split view" : "Close split view",
                      on: web.splitTab != nil) {
                BrowserActions.perform(.toggleSplit, on: web)
            }
            ExtensionsButton(web: web)
            Spacer(minLength: 0)
            FullButton()
            BarButton("xmark", help: "Close the browser") { app.showSide(nil) }
        }
    }

    // MARK: A tab's menu

    @ViewBuilder
    private func menu(for tab: Model.Tab) -> some View {
        let project = app.conversation.projectID
        if let url = tab.url, !tab.isBlank {
            Button(pins.pin(for: url, in: project) == nil ? "Pin to This Project" : "Unpin") {
                BrowserPins.shared.toggle(url, title: tab.label, in: project)
            }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            Button("Open in Default Browser") { NSWorkspace.shared.open(url) }
            Button("Ask About This Page") { BrowserActions.ask(about: tab) }
            Divider()
        }
        if tab.id == web.current?.id || tab.id == web.splitTab?.id {
            if web.splitTab != nil {
                Button("Close Split View") { web.split = nil }
            }
        } else {
            Button("Open in Split View") { web.split = tab.id }
        }
        if tab.audible || tab.muted {
            Button(tab.muted ? "Unmute Tab" : "Mute Tab") { tab.toggleMute() }
        }
        if web is ChromiumTabs, tab.id != web.current?.id, tab.id != web.splitTab?.id, !tab.isBlank, !tab.asleep {
            Button("Put to Sleep") { web.sleep(tab.id) }
        }
        Divider()
        Button("Close Tab") { BrowserActions.close(tab, in: web) }
        if web.tabs.count > 1 {
            Button("Close Other Tabs") {
                web.show(tab.id)
                for other in web.tabs where other.id != tab.id {
                    web.close(other.id)
                }
            }
        }
    }

    // MARK: Dragging a tab to a new place

    /// Where the tab being dragged would land, by place among the tabs.
    private var dropIndex: Int? {
        guard let dragging, let from = web.tabs.firstIndex(where: { $0.id == dragging }) else { return nil }
        let steps = Int((dragOffset / Self.pitch).rounded())
        return min(max(from + steps, 0), web.tabs.count - 1)
    }

    /// The tab being dragged follows the pointer; those it passes make way.
    private func offset(of tab: Model.Tab, at index: Int) -> CGFloat {
        guard let dragging, let from = web.tabs.firstIndex(where: { $0.id == dragging }),
              let to = dropIndex else { return 0 }
        if tab.id == dragging { return dragOffset }
        if from < to, index > from, index <= to { return -Self.pitch }
        if from > to, index >= to, index < from { return Self.pitch }
        return 0
    }

    private func drag(_ tab: Model.Tab) -> some Gesture {
        // Measured on the screen, not on the line being moved, so the
        // line's own movement does not feed back into how far it went.
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                if dragging != tab.id { dragging = tab.id }
                dragOffset = value.translation.height
            }
            .onEnded { _ in
                let ids = web.tabs.map(\.id)
                let from = ids.firstIndex(of: tab.id)
                let to = dropIndex
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    if let from, let to, from != to {
                        web.move(tab.id, before: to > from ? (to + 1 < ids.count ? ids[to + 1] : nil) : ids[to])
                    }
                    dragging = nil
                    dragOffset = 0
                }
            }
    }
}

/// The line that opens a new tab, above the tabs.
private struct NewTabRow: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(BrowserChrome.glyph)
                    .frame(width: 16, height: 16)
                Text("New Tab")
                    .font(BrowserChrome.title)
                Spacer(minLength: 0)
                Text("⌘T")
                    .font(BrowserChrome.note)
                    .opacity(hover ? 0.6 : 0)
            }
            .foregroundStyle(Theme.ink.opacity(hover ? 0.85 : 0.6))
            .padding(.horizontal, 8)
            .frame(height: BrowserChrome.row)
            .background(RoundedRectangle(cornerRadius: BrowserChrome.rowRadius, style: .continuous)
                .fill(hover ? BrowserChrome.rowHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// One tab in the sidebar: its site's icon (a mark while it loads, a moon
/// while it sleeps), its title, and the cross that closes it under the
/// pointer. The tab showing is lifted in the look's color.
private struct TabRow<Tab: BrowsingTab>: View {
    @ObservedObject var tab: Tab
    /// Watched for the site's icon arriving.
    @ObservedObject var history: BrowserHistory
    let selected: Bool
    /// Shown beside the tab showing, in split view.
    let paired: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if tab.loading {
                    LoadingMark(state: .working, size: 12)
                } else if tab.asleep {
                    Image(systemName: "moon.zzz")
                        .font(BrowserChrome.glyph)
                        .foregroundStyle(Theme.ink.opacity(0.45))
                } else {
                    SiteIcon(icon: tab.url.flatMap { history.icon(for: $0.absoluteString) }, blank: tab.isBlank,
                             bright: selected)
                }
            }
            .frame(width: 16, height: 16)
            Text(tab.isBlank ? "New Tab" : tab.label)
                .font(selected ? BrowserChrome.titleChosen : BrowserChrome.title)
                .foregroundStyle(selected ? BrowserChrome.titleChosenColor
                    : (tab.asleep ? Theme.ink.opacity(0.45) : BrowserChrome.titleColor))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            SoundButton(tab: tab)
            if paired {
                Image(systemName: "square.split.2x1")
                    .font(BrowserChrome.glyph)
                    .foregroundStyle(Theme.accent)
                    .help("Beside the tab showing, in split view")
            }
            if hover {
                InlineButton("xmark", help: "Close tab (⌘W)", action: close)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, hover ? 6 : 8)
        .frame(height: BrowserChrome.row)
        .background(RoundedRectangle(cornerRadius: BrowserChrome.rowRadius, style: .continuous)
            .fill(selected ? BrowserChrome.chosen : (hover ? BrowserChrome.rowHover : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(tab.label + (tab.url.map { "\n" + $0.absoluteString } ?? ""))
    }
}
