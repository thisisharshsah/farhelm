import AppKit
import SwiftUI

/// The browser beside the chat, with tabs. It is its own browser: no
/// sign-ins or history are shared with Safari or Chrome.
struct BrowserPane: View {
    @EnvironmentObject var app: AppState
    /// Chromium or WebKit (Settings > Browser).
    @AppStorage(BrowserEngine.key) private var chromium = true

    var body: some View {
        // Each chat has a browser session of its own, so the pane is
        // rebuilt for the session of the chat that is showing.
        let web = app.web
        if chromium && BrowserEngine.chromium {
            ChromiumBody(tabs: web.chromium)
                .id(ObjectIdentifier(web))
        } else {
            BrowserBody(web: web) { tab in
                PasswordBar(page: tab.webView)
                StoreBar(tab: tab)
                BrowserTabView(tab: tab, web: web)
                    .id(tab.id)
            }
            .id(ObjectIdentifier(web))
            .onAppear { web.ensureTab() }
        }
    }
}

/// The sizes the browser lays itself out by. (Kept out of the generic
/// views: a generic type cannot hold static stored properties.)
enum BrowserMetrics {
    /// From this width the browser has room for its tab sidebar.
    static let wideFrom: CGFloat = 760
    /// The tab sidebar's width.
    static let sidebarWidth: CGFloat = 232
    /// From this width split view sets its pages side by side; narrower,
    /// one over the other.
    static let sideBySideFrom: CGFloat = 600
    /// Narrower than this, the compact bar keeps Ask and close and puts the
    /// rest in one menu, so the tabs keep room to be read.
    static let narrowBelow: CGFloat = 460
    /// A browser narrower than this takes the whole panel for split view.
    static let splitRoom: CGFloat = 720
    /// The hairline between two tabs in the compact bar.
    static let tabGap: CGFloat = 1
    /// The narrowest the tab showing gets in the compact bar while others
    /// share the strip. Past this and `chipLeast` the strip scrolls.
    static let pillLeast: CGFloat = 120
    /// A lone tab that has not gone anywhere: the strip hugs it.
    static let pillLone: CGFloat = 190
    /// The narrowest a tab that is not showing gets: just its icon.
    static let chipLeast: CGFloat = 64
    /// From this width a tab that is not showing has room for its title.
    static let chipTitled: CGFloat = 104
}

/// The browser, the same for either engine. Beside the chat it is a compact
/// bar over the page; given the room (the column dragged wide, or the whole
/// panel) the tabs move to a sidebar beside the page, as in Arc and Zen,
/// which tucks away for the page to have it all. The frame takes on the
/// page's own color. `content` is what shows for a tab: its page, or the
/// start page.
struct BrowserBody<Model: BrowsingModel, Content: View>: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var web: Model
    @ObservedObject private var ui = BrowserUI.shared
    let content: (Model.Tab) -> Content

    /// The pane's width, measured.
    @State private var width: CGFloat = 460

    init(web: Model, @ViewBuilder content: @escaping (Model.Tab) -> Content) {
        self.web = web
        self.content = content
    }

    private var wide: Bool { width >= BrowserMetrics.wideFrom }
    private var sidebar: Bool { wide && ui.sidebar }

    var body: some View {
        HStack(spacing: 0) {
            if sidebar {
                BrowserSidebar(web: web)
                    .frame(width: BrowserMetrics.sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: 0) {
                if !sidebar {
                    CompactBar(web: web, wide: wide, narrow: width < BrowserMetrics.narrowBelow)
                }
                pages
                    .padding(.top, sidebar ? Theme.panelGap : 0)
                    .padding(.leading, sidebar ? 0 : Theme.panelGap)
                    .padding(.trailing, Theme.panelGap)
                    .padding(.bottom, Theme.panelGap)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if let tab = web.current {
                PageWash(tab: tab)
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        width = geometry.size.width
                        ui.paneWidth = geometry.size.width
                    }
                    .onChange(of: geometry.size.width) { _, value in
                        width = value
                        ui.paneWidth = value
                    }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: sidebar)
        // The command bar is about the tab it was opened over.
        .onChange(of: web.current?.id) { _, _ in
            ui.commandBar = false
            ui.finding = false
        }
        .onDisappear {
            ui.commandBar = false
            ui.finding = false
        }
    }

    /// The page showing, or two in split view, with the agent's ring round
    /// them while it works in them and the command bar over them when it
    /// is open.
    @ViewBuilder
    private var pages: some View {
        if let tab = web.current {
            Group {
                if let other = web.splitTab {
                    split(tab, other)
                } else {
                    page(tab)
                }
            }
            .overlay {
                if ui.agentBrowsing {
                    AgentRing()
                        .transition(.opacity)
                }
            }
            .overlay { PageOverlay(web: web, tab: tab) }
            // Find in page keeps to a corner, so the page stays in reach.
            .overlay(alignment: .topTrailing) {
                FindOverlay(tab: tab)
                    .frame(width: 330, height: 40)
                    .padding(8)
            }
            // A question the page asks ("Are you sure?"), over its top,
            // until it is answered.
            .overlay(alignment: .top) {
                if let chromium = tab as? ChromiumTab {
                    PageDialogOverlay(tab: chromium)
                        .frame(width: 380, height: 168)
                        .padding(.top, 36)
                }
            }
            .animation(.easeOut(duration: 0.25), value: ui.agentBrowsing)
        }
    }

    /// One page, set into the panel with rounded corners, as a browser's
    /// page sits in its window.
    private func page(_ tab: Model.Tab) -> some View {
        VStack(spacing: 0) { content(tab) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
    }

    /// Two pages side by side, in their order among the tabs, so neither
    /// jumps when the other is brought in; one over the other when the
    /// pane is narrow.
    private func split(_ tab: Model.Tab, _ other: Model.Tab) -> some View {
        let here = web.tabs.firstIndex { $0.id == tab.id } ?? 0
        let there = web.tabs.firstIndex { $0.id == other.id } ?? 0
        let sides = here <= there ? [tab, other] : [other, tab]
        let room = sidebar ? width - BrowserMetrics.sidebarWidth : width
        let layout = room >= BrowserMetrics.sideBySideFrom
            ? AnyLayout(HStackLayout(spacing: Theme.panelGap))
            : AnyLayout(VStackLayout(spacing: Theme.panelGap))
        return layout {
            ForEach(sides, id: \.id) { side in
                VStack(spacing: 4) {
                    SplitHeader(tab: side, history: web.history, focused: side.id == tab.id,
                                focus: { web.show(side.id) },
                                close: { unsplit(keeping: side.id == tab.id ? other : tab) })
                    page(side)
                }
            }
        }
    }

    /// Takes a page out of split view; the other one shows on its own.
    private func unsplit(keeping other: Model.Tab) {
        web.split = nil
        web.show(other.id)
    }
}

// MARK: - Compact bar

/// The bar beside the chat: back and forward, the tabs in one strip (the one
/// showing is its address), and the browser's buttons, all on one line so
/// the page keeps the room.
private struct CompactBar<Model: BrowsingModel>: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var web: Model
    /// The browser has room for the tab sidebar, put away for now.
    let wide: Bool
    /// Too narrow for every button: the rest go in a menu.
    let narrow: Bool

    /// Three pieces of glass, always the same three: the way back and
    /// forward, the tabs, and what the browser can do.
    var body: some View {
        HStack(spacing: 5) {
            if let tab = web.current {
                BarGroup {
                    if wide {
                        BarButton("sidebar.left", help: "Show the tab sidebar (⇧⌘L)") {
                            BrowserActions.perform(.toggleSidebar, on: web)
                        }
                    }
                    NavButtons(tab: tab)
                }
                TabStrip(web: web, current: tab)
            } else {
                Spacer(minLength: 0)
            }
            BarGroup {
                if narrow {
                    if let tab = web.current {
                        AskButton(tab: tab)
                    }
                    BarMenu("ellipsis", help: "More") { more }
                } else {
                    ExtensionsButton(web: web)
                    if let tab = web.current {
                        AskButton(tab: tab)
                    }
                    BarButton("plus", help: "New tab (⌘T)") { BrowserActions.perform(.newTab, on: web) }
                    FullButton()
                }
                BarButton("xmark", help: "Close the browser") { app.showSide(nil) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// The tabs in the compact bar, in their order, all in one strip. The one
/// showing is a pill with its site; the others are their icon and, with
/// room, their title, set apart by hairlines. They share the strip as a
/// browser's tabs do, and scroll sideways when there are more than fit.
private struct TabStrip<Model: BrowsingModel>: View {
    @ObservedObject var web: Model
    /// The tab showing, watched so the strip follows it going somewhere.
    @ObservedObject var current: Model.Tab
    @ObservedObject private var ui = BrowserUI.shared
    /// Room the tabs have, measured, so they can share it.
    @State private var stripWidth: CGFloat = 300

    /// One tab that has not gone anywhere: the strip is only as long as it.
    private var hugging: Bool { web.tabs.count == 1 && current.isBlank }

    /// Every tab gets the same share, showing or not, so picking another
    /// never makes the strip jump about; only when they are crowded does
    /// the one showing keep a little more, for its site.
    private var widths: (pill: CGFloat, chip: CGFloat) {
        let count = CGFloat(max(1, web.tabs.count))
        if hugging { return (min(BrowserMetrics.pillLone, max(80, stripWidth)), BrowserMetrics.chipLeast) }
        let share = (stripWidth - (count - 1) * BrowserMetrics.tabGap) / count
        if count == 1 { return (max(80, share), BrowserMetrics.chipLeast) }
        return (max(BrowserMetrics.pillLeast, share), max(BrowserMetrics.chipLeast, share))
    }

    var body: some View {
        HStack(spacing: 5) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(web.tabs.enumerated()), id: \.element.id) { index, tab in
                            item(index: index, tab: tab)
                        }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.86), value: web.tabs.count)
                    .animation(.spring(response: 0.3, dampingFraction: 0.86), value: web.selected)
                }
                .onChange(of: web.selected) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .frame(height: BarButton.size + 4)
            .frame(maxWidth: hugging ? BrowserMetrics.pillLone : .infinity)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { stripWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in stripWidth = width }
                }
            }
            // The strip is the same glass as the groups of buttons beside it.
            .clipShape(Capsule())
            .liquidGlass(in: Capsule())
            if hugging { Spacer(minLength: 0) }
        }
    }

    /// Whether the hairline before this tab shows: only between two tabs
    /// that are not showing. The pill needs none beside it.
    private func hairline(before index: Int) -> Bool {
        guard index > 0 else { return false }
        return web.tabs[index].id != current.id && web.tabs[index - 1].id != current.id
    }

    @ViewBuilder
    private func item(index: Int, tab: Model.Tab) -> some View {
        if index > 0 {
            Rectangle()
                .fill(Theme.ink.opacity(hairline(before: index) ? 0.14 : 0))
                .frame(width: 1, height: 14)
        }
        if tab.id == current.id {
            AddressPill(tab: tab, history: web.history, active: ui.commandBar,
                        open: { BrowserActions.perform(.openLocation, on: web) },
                        close: { BrowserActions.close(tab, in: web) })
                .frame(width: widths.pill)
                .id(tab.id)
        } else {
            TabChip(tab: tab, history: web.history, titled: widths.chip >= BrowserMetrics.chipTitled,
                    select: { web.show(tab.id) },
                    close: { BrowserActions.close(tab, in: web) })
                .frame(width: widths.chip)
                .id(tab.id)
        }
    }
}

extension CompactBar {
    /// What a narrow bar keeps in its menu.
    var more: [BarMenu.Item] {
        var items: [BarMenu.Item] = [
            .action("New Tab") { BrowserActions.perform(.newTab, on: web) },
            .action(app.sideFull ? "Show the Chat Beside This" : "Use the Whole Panel") {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { app.sideFull.toggle() }
            },
            .action(web.splitTab == nil ? "Split View" : "Close Split View") { BrowserActions.perform(.toggleSplit, on: web) },
            .action("Find in Page") { BrowserActions.perform(.find, on: web) },
        ]
        if let chromium = web as? ChromiumTabs {
            items += [
                .separator,
                .action("Chrome Web Store") { chromium.newTab("https://chromewebstore.google.com") },
                .action("Manage Extensions") { chromium.newTab("chrome://extensions/") },
            ]
        }
        return items
    }
}

// MARK: - Buttons shared with the sidebar

/// Ask about the page showing: it goes to the chat beside the browser, with
/// what is selected on it. While the agent works in the page, the same place
/// shows it at work.
struct AskButton<Tab: BrowsingTab>: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var ui = BrowserUI.shared

    var body: some View {
        Group {
            if ui.agentBrowsing {
                LoadingMark(state: .working, size: 14)
                    .frame(width: BrowserChrome.button, height: BrowserChrome.button)
                    .help("The agent is working in this page")
            } else {
                // "Chat" in words, as in Dia: the page goes to the chat
                // beside the browser, with what is selected on it.
                Button { BrowserActions.ask(about: tab) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left")
                            .font(BrowserChrome.glyph)
                        Text("Chat")
                            .font(BrowserChrome.title)
                    }
                    .foregroundStyle(Theme.ink.opacity(tab.isBlank ? 0.35 : 0.85))
                    .padding(.horizontal, 8)
                    .frame(height: BrowserChrome.button)
                    .background(Capsule().fill(Theme.accent.opacity(0.14)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Ask about this page")
                .disabled(tab.isBlank)
            }
        }
        .animation(.easeOut(duration: 0.2), value: ui.agentBrowsing)
    }
}

/// Reload the page showing, or stop it while it loads.
struct ReloadButton<Tab: BrowsingTab>: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if tab.loading {
            BarButton("xmark", help: "Stop") { tab.stopLoading() }
        } else {
            BarButton("arrow.clockwise", help: "Reload (⌘R)") { tab.reload() }
                .disabled(tab.isBlank)
        }
    }
}

/// Gives the browser the whole panel, or hands the room back to the chat:
/// the same pair of arrows as everywhere else in the panel.
struct FullButton: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        BarButton(FullToggle.symbol(full: app.sideFull), help: FullToggle.help(full: app.sideFull),
                  on: app.sideFull) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { app.sideFull.toggle() }
        }
    }
}

/// Chrome's or WebKit's extensions, as a bar button like the others: the
/// pinned ones' own buttons first on WebKit, then one menu for the rest.
struct ExtensionsButton<Model: BrowsingModel>: View {
    @ObservedObject var web: Model

    var body: some View {
        if let model = web as? BrowserModel {
            if BrowserExtensions.supported {
                ExtensionStrip(web: model)
            }
        } else if let chromium = web as? ChromiumTabs {
            ChromiumExtensionsMenu(tabs: chromium)
        }
    }
}

// MARK: - Over and around the page

/// The top of a page in split view: its site, quieter on the side not in
/// use (a click there brings that side in), and a cross that takes the page
/// out of split view.
private struct SplitHeader<Tab: BrowsingTab>: View {
    @ObservedObject var tab: Tab
    /// Watched for the site's icon arriving.
    @ObservedObject var history: BrowserHistory
    let focused: Bool
    let focus: () -> Void
    let close: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            SiteIcon(icon: tab.url.flatMap { history.icon(for: $0.absoluteString) }, blank: tab.isBlank,
                     bright: focused)
            Text(tab.isBlank ? "New Tab" : tab.label)
                .font(focused ? BrowserChrome.titleChosen : BrowserChrome.title)
                .foregroundStyle(focused ? BrowserChrome.titleChosenColor : BrowserChrome.titleColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if hover {
                InlineButton("xmark", help: "Take this page out of split view", action: close)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(height: 24)
        .background(Capsule().fill(focused ? BrowserChrome.chosen : (hover ? BrowserChrome.pillHover : .clear)))
        .contentShape(Capsule())
        .onTapGesture(perform: focus)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(focused ? tab.label : "Use this side")
    }
}

/// The command bar over the page while it is open, about the tab showing.
private struct PageOverlay<Model: BrowsingModel>: View {
    @ObservedObject var web: Model
    @ObservedObject var tab: Model.Tab
    @ObservedObject private var ui = BrowserUI.shared

    var body: some View {
        OverPage(shown: ui.commandBar && !tab.isBlank, dismiss: { ui.commandBar = false }) {
            CommandOverlay(web: web, tab: tab) { ui.commandBar = false }
        }
    }
}

/// Find in page over the page's corner while it is open, about the tab
/// showing.
private struct FindOverlay<Tab: BrowsingTab>: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var ui = BrowserUI.shared

    var body: some View {
        OverPage(shown: ui.finding && !tab.isBlank, dismiss: { ui.finding = false }) {
            FindBar(tab: tab) { ui.finding = false }
        }
    }
}

/// The command bar on a veil over the page, near its top. A click on the
/// veil lets it go.
private struct CommandOverlay<Model: BrowsingModel>: View {
    @ObservedObject var web: Model
    @ObservedObject var tab: Model.Tab
    let close: () -> Void
    @State private var shown = false

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
                .fill(Color.black.opacity(Theme.isLight ? 0.12 : 0.3))
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .opacity(shown ? 1 : 0)
            BrowserCommandBar(web: web, tab: tab, style: .floating, close: close)
                .padding(.horizontal, 12)
                .padding(.top, 26)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : -8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) { shown = true }
        }
    }
}

/// While the agent works in the page: a ring in the look's colors round it,
/// breathing. It sits in the gap round the page, since a Chromium page
/// covers anything drawn over it.
private struct AgentRing: View {
    @State private var lit = false

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.innerRadius + 3, style: .continuous)
            .strokeBorder(Theme.accentGradient, lineWidth: 2)
            .padding(-3)
            .opacity(lit ? 1 : 0.3)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { lit = true }
            }
    }
}

/// The page's own color over the browser's frame, as Safari and Arc tint
/// their bars by the page.
private struct PageWash<Tab: BrowsingTab>: View {
    @ObservedObject var tab: Tab

    var body: some View {
        let color = tab.isBlank || tab.asleep ? nil : tab.pageColor
        Rectangle()
            .fill(Color(nsColor: color ?? .clear))
            .opacity(color.map(PageTint.strength) ?? 0)
            .animation(.easeOut(duration: 0.35), value: color)
            .allowsHitTesting(false)
    }
}

/// How strongly a page's color washes the browser's frame: enough to read
/// as the page's, little enough that the glass stays glass.
enum PageTint {
    /// A page in the frame's own light or dark washes it most, so frame
    /// and page read as one; a colored page a little less; and one that
    /// would only fight the glass (a white page on dark glass, a black one
    /// on light) hardly at all.
    static func strength(_ color: NSColor) -> Double {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        let red = Double(rgb.redComponent), green = Double(rgb.greenComponent), blue = Double(rgb.blueComponent)
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let chroma = max(red, green, blue) - min(red, green, blue)
        if chroma < 0.12 {
            let along = Theme.isLight ? luminance : 1 - luminance
            return along > 0.6 ? 0.3 : 0.05
        }
        return 0.2
    }
}


/// The page's own dialog (alert, confirm, prompt, "leave this page?"),
/// shown over the page as a card: what it asks, a field for a prompt, and
/// its buttons. The page waits until it is answered, by the person here
/// or by the agent with their OK.
private struct PageDialogOverlay: View {
    @ObservedObject var tab: ChromiumTab
    @State private var text = ""

    var body: some View {
        OverPage(shown: tab.dialog != nil, dismiss: {}) {
            if let dialog = tab.dialog { card(dialog) }
        }
        .onChange(of: tab.dialog) { _, dialog in text = dialog?.defaultText ?? "" }
    }

    private func card(_ dialog: ChromiumTab.PageDialog) -> some View {
        let host = URL(string: tab.address)?.host ?? "This page"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: dialog.kind == "alert" ? "exclamationmark.bubble" : "questionmark.bubble")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                Text("\(host) asks")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .lineLimit(1)
            }
            Text(dialog.message.isEmpty ? (dialog.kind == "leave" ? "Leave this page? Changes you made may not be saved." : "The page needs an answer.") : dialog.message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink.opacity(0.95))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            if dialog.kind == "prompt" {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.ink.opacity(0.08)))
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Spacer()
                if dialog.kind != "alert" {
                    Button(dialog.kind == "leave" ? "Stay" : "Cancel") { tab.answerDialog(accept: false) }
                        .keyboardShortcut(.cancelAction)
                }
                Button(dialog.kind == "leave" ? "Leave" : "OK") {
                    tab.answerDialog(accept: true, text: dialog.kind == "prompt" ? text : nil)
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.amber.opacity(0.35), lineWidth: 0.75))
    }
}
