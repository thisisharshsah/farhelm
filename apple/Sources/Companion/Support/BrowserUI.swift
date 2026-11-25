import AppKit
import SwiftUI

/// What Companion's browser shows beyond its tabs, shared by both engines:
/// the command bar, whether the tab sidebar is out, which start page takes
/// the keys, and whether the agent is at work in the page.
@MainActor
final class BrowserUI: ObservableObject {
    static let shared = BrowserUI()

    /// The command bar floating over the page showing (⌘L, or a click on
    /// the address). A new place (⌘T) is asked for on a new tab's start
    /// page instead.
    @Published var commandBar = false
    /// The tab whose start page takes the keys when it shows: a tab just
    /// opened with ⌘T, or a blank one asked for with ⌘L.
    @Published var focusTab: UUID?
    /// The tab sidebar is out, in a browser wide enough for one.
    @Published var sidebar = true {
        didSet { UserDefaults.standard.set(sidebar, forKey: Self.sidebarKey) }
    }
    /// The agent took a step in the browser a moment ago.
    @Published private(set) var agentBrowsing = false
    /// Find in page is open over the page showing (⌘F).
    @Published var finding = false
    /// What was looked for last, kept for the next time it opens.
    var findQuery = ""
    /// Go up when the next or the previous match is asked for by key, or
    /// the keys are wanted back in the find bar.
    @Published var findForward = 0
    @Published var findBackward = 0
    @Published var findFocus = 0
    /// The tab whose page was taken off the chat box, so it does not go
    /// with messages. Another tab showing has its chip again.
    @Published var pageDismissed: UUID?
    /// Other tabs added to the next message, in the order they were added.
    @Published var chatTabs: [UUID] = []
    /// How wide the browser is, as last laid out (not published: it is
    /// read when a command runs, never drawn).
    var paneWidth: CGFloat = 0
    private var agentQuiet: Task<Void, Never>?

    private static let sidebarKey = "browserSidebar"

    private init() {
        sidebar = UserDefaults.standard.object(forKey: Self.sidebarKey) as? Bool ?? true
    }

    /// The agent took a step in the browser: the page shows it is being
    /// worked, until a few seconds after the last step.
    func agentStepped() {
        agentBrowsing = true
        agentQuiet?.cancel()
        agentQuiet = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.agentBrowsing = false
        }
    }
}

/// What the browser's commands do, on whichever engine the open chat's
/// browser runs. Every key and button goes through here, so both engines
/// behave the same.
@MainActor
enum BrowserActions {
    enum Action {
        case newTab, openLocation, closeTab, reopenTab, reload, back, forward, nextTab, previousTab
        case tab(Int), lastTab, togglePin, askAboutPage, toggleSplit, sleepOthers, copyLink, openOutside
        case toggleSidebar
        case find, findNext, findPrevious, toggleMute
    }

    private static var app: AppState { AppState.shared }

    /// The browser is open in the panel in use.
    static var showing: Bool { app.panelVisible && app.sidePanel == .browser }

    /// Runs an action on the open chat's browser.
    static func perform(_ action: Action) {
        let web = app.web
        if BrowserEngine.chromium {
            perform(action, on: web.chromium)
        } else {
            perform(action, on: web)
        }
    }

    static func perform<Model: BrowsingModel>(_ action: Action, on web: Model) {
        let ui = BrowserUI.shared
        let current = web.current
        switch action {
        case .find, .findNext, .findPrevious:
            guard let current, !current.isBlank else { return }
            ui.commandBar = false
            if !ui.finding {
                ui.finding = true
            } else if case .findNext = action {
                ui.findForward += 1
            } else if case .findPrevious = action {
                ui.findBackward += 1
            } else {
                ui.findFocus += 1
            }
        case .toggleMute:
            current?.toggleMute()
        case .newTab:
            web.openNewTab()
            ui.finding = false
            ui.commandBar = false
            ui.focusTab = web.current?.id
        case .openLocation:
            guard let current else { return }
            ui.finding = false
            if current.isBlank {
                ui.focusTab = current.id
            } else {
                ui.commandBar = true
            }
        case .closeTab:
            guard let current else { return }
            close(current, in: web)
        case .reopenTab:
            web.reopenClosed()
        case .reload:
            current?.reload()
        case .back:
            current?.goBack()
        case .forward:
            current?.goForward()
        case .nextTab:
            web.selectNext(1)
        case .previousTab:
            web.selectNext(-1)
        case .tab(let index):
            web.select(index: index)
        case .lastTab:
            web.select(index: web.tabs.count - 1)
        case .togglePin:
            guard let current, let url = current.url else { return }
            BrowserPins.shared.toggle(url, title: current.label, in: app.conversation.projectID)
        case .askAboutPage:
            ask(about: current)
        case .toggleSplit:
            toggleSplit(web)
        case .sleepOthers:
            web.sleepOthers()
        case .copyLink:
            guard let url = current?.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        case .openOutside:
            guard let url = current?.url else { return }
            NSWorkspace.shared.open(url)
        case .toggleSidebar:
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { ui.sidebar.toggle() }
        }
    }

    /// Closes a tab. Closing the last one leaves a fresh tab in its place;
    /// closing that one, with nothing in it, closes the browser.
    static func close<Model: BrowsingModel>(_ tab: Model.Tab, in web: Model) {
        if web.tabs.count == 1, tab.isBlank {
            app.showSide(nil)
        } else {
            web.close(tab.id)
        }
    }

    /// Ask about a page: it joins the pages going with the next message
    /// (read when the message is sent, so what is selected on it then goes
    /// too), and the chat comes back beside the browser with the keys in
    /// its box, for the question.
    static func ask<Tab: BrowsingTab>(about tab: Tab?) {
        guard let tab, !tab.isBlank else { return }
        let ui = BrowserUI.shared
        if ui.pageDismissed == tab.id { ui.pageDismissed = nil }
        if !ui.chatTabs.contains(tab.id) { ui.chatTabs.append(tab.id) }
        app.focusChat()
    }

    /// Ask about every page open: they all go with the next message.
    static func askAboutAll<Model: BrowsingModel>(in web: Model) {
        let ui = BrowserUI.shared
        ui.pageDismissed = nil
        ui.chatTabs = web.tabs.filter { !$0.isBlank }.map(\.id)
        app.focusChat()
    }

    // MARK: The chat's view of the browser

    /// A page open in the chat's browser, as the chat knows it.
    struct OpenPage: Identifiable {
        let id: UUID
        /// Its tab's number, from 1, as the agent's browser steps count tabs.
        let number: Int
        let title: String
        let url: URL
        let showing: Bool
    }

    /// The most pages one message takes along.
    static let pagesPerMessage = 6

    /// The pages open in the open chat's browser.
    static func openPages() -> [OpenPage] {
        let web = app.web
        return BrowserEngine.chromium ? pages(in: web.chromium) : pages(in: web)
    }

    static func pages<Model: BrowsingModel>(in web: Model) -> [OpenPage] {
        let current = web.current?.id
        return web.tabs.enumerated().compactMap { index, tab -> OpenPage? in
            guard !tab.isBlank, let url = tab.url else { return nil }
            return OpenPage(id: tab.id, number: index + 1, title: tab.label, url: url, showing: tab.id == current)
        }
    }

    /// Whether a page goes with the next message: the one showing, unless
    /// its chip was taken off, and the tabs added.
    static func goes(_ page: OpenPage) -> Bool {
        let ui = BrowserUI.shared
        return (page.showing && ui.pageDismissed != page.id) || ui.chatTabs.contains(page.id)
    }

    /// The pages that go with the next message, while the browser is open
    /// beside the chat.
    static func pagesForChat() -> [OpenPage] {
        guard app.sidePanel == .browser, !app.showSettings else { return [] }
        return Array(openPages().filter(goes).prefix(pagesPerMessage))
    }

    /// Reads pages as they are now. One that cannot be read in time (asleep,
    /// or not answering) goes as its title and address alone.
    static func snapshots(of pages: [OpenPage]) async -> [PageSnapshot] {
        let web = app.web
        var found: [PageSnapshot] = []
        for page in pages {
            let read: PageSnapshot?
            if BrowserEngine.chromium {
                read = await snapshot(page.id, in: web.chromium)
            } else {
                read = await snapshot(page.id, in: web)
            }
            found.append(read ?? PageSnapshot(title: page.title, url: page.url))
        }
        return found
    }

    private static func snapshot<Model: BrowsingModel>(_ id: UUID, in web: Model) async -> PageSnapshot? {
        guard let tab = web.tab(id) else { return nil }
        return await bounded(seconds: 1.5) { await tab.snapshot() }
    }

    /// What work gives, or nil when it has not answered in time, so a page
    /// that hangs never holds a message back.
    private static func bounded<Value: Sendable>(seconds: Double,
                                                 _ work: @escaping @MainActor () async -> Value?) async -> Value? {
        let once = Once()
        return await withCheckedContinuation { (reply: CheckedContinuation<Value?, Never>) in
            Task { @MainActor in
                let value = await work()
                guard !once.done else { return }
                once.done = true
                reply.resume(returning: value)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !once.done else { return }
                once.done = true
                reply.resume(returning: nil)
            }
        }
    }

    @MainActor
    private final class Once {
        var done = false
    }

    /// The tabs open beside the chat, in a few lines for the model: it
    /// always knows what is open and which one shows; a page's text it has
    /// only when the page went with a message.
    static func tabsNote() -> String {
        guard app.sidePanel == .browser else { return "" }
        let pages = openPages()
        guard !pages.isEmpty else { return "" }
        let lines = pages.map { page in
            "\(page.number). \(page.title), \(page.url.absoluteString)\(page.showing ? " (showing)" : "")"
        }
        return "Tabs open in the browser beside this chat, which the user sees:\n" + lines.joined(separator: "\n")
    }

    /// Split view: the current tab with the one after it (or the one
    /// before), or, alone, with a new tab to go somewhere from. Again, and
    /// the tab beside it goes back to being a tab.
    static func toggleSplit<Model: BrowsingModel>(_ web: Model) {
        if web.splitTab != nil {
            web.split = nil
            return
        }
        guard let current = web.current, let here = web.tabs.firstIndex(where: { $0.id == current.id }) else { return }
        let after = here + 1 < web.tabs.count ? web.tabs[here + 1] : nil
        let before = here > 0 ? web.tabs[here - 1] : nil
        if let partner = after ?? before {
            web.split = partner.id
        } else {
            web.openNewTab()
            web.split = current.id
            BrowserUI.shared.focusTab = web.current?.id
        }
        // Side by side wants the room: in a narrow column the chat steps aside.
        if !app.sideFull, BrowserUI.shared.paneWidth < BrowserMetrics.splitRoom {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { app.sideFull = true }
        }
    }

    // MARK: Commands

    /// The browser's commands, with their keys. They run while the browser
    /// is open; otherwise their keys pass on to whatever has the focus.
    static var commands: [Command] {
        let open: @MainActor () -> Bool = { BrowserActions.showing }
        // The number keys' codes, 1 to 8.
        let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28]
        var list: [Command] = [
            Command(id: "browser.newTab", title: "New Tab", category: "Browser", icon: "plus",
                    keys: .cmd(17, "T"), available: open) { perform(.newTab) },
            Command(id: "browser.openLocation", title: "Open Location or Search", category: "Browser",
                    icon: "magnifyingglass", keys: .cmd(37, "L"), available: open) { perform(.openLocation) },
            Command(id: "browser.closeTab", title: "Close Tab", category: "Browser", icon: "xmark",
                    keys: .cmd(13, "W"), available: open) { perform(.closeTab) },
            Command(id: "browser.reopenTab", title: "Reopen Closed Tab", category: "Browser",
                    icon: "arrow.uturn.backward", keys: .cmdShift(17, "T"), available: open) { perform(.reopenTab) },
            Command(id: "browser.reload", title: "Reload Page", category: "Browser", icon: "arrow.clockwise",
                    keys: .cmd(15, "R"), available: open) { perform(.reload) },
            Command(id: "browser.back", title: "Back", category: "Browser", icon: "chevron.left",
                    keys: .cmd(33, "["), available: open) { perform(.back) },
            Command(id: "browser.forward", title: "Forward", category: "Browser", icon: "chevron.right",
                    keys: .cmd(30, "]"), available: open) { perform(.forward) },
            Command(id: "browser.nextTab", title: "Next Tab", category: "Browser", icon: "arrow.right.square",
                    keys: KeyChord(keyCode: 48, modifiers: .control, display: "⌃⇥"), available: open) { perform(.nextTab) },
            Command(id: "browser.previousTab", title: "Previous Tab", category: "Browser", icon: "arrow.left.square",
                    keys: KeyChord(keyCode: 48, modifiers: [.control, .shift], display: "⌃⇧⇥"),
                    available: open) { perform(.previousTab) },
            Command(id: "browser.lastTab", title: "Show the Last Tab", category: "Browser", icon: "9.square",
                    keys: .cmd(25, "9"), available: open) { perform(.lastTab) },
            Command(id: "browser.pin", title: "Pin or Unpin This Page", category: "Browser", icon: "pin",
                    keys: .cmd(2, "D"), available: open) { perform(.togglePin) },
            Command(id: "browser.sidebar", title: "Show or Hide the Tab Sidebar", category: "Browser",
                    icon: "sidebar.left", keys: .cmdShift(37, "L"), available: open) { perform(.toggleSidebar) },
            Command(id: "browser.find", title: "Find in Page", category: "Browser", icon: "text.magnifyingglass",
                    keys: .cmd(3, "F"), available: open) { perform(.find) },
            Command(id: "browser.findNext", title: "Find Next", category: "Browser", icon: "chevron.down",
                    keys: .cmd(5, "G"), available: open) { perform(.findNext) },
            Command(id: "browser.findPrevious", title: "Find Previous", category: "Browser", icon: "chevron.up",
                    keys: .cmdShift(5, "G"), available: open) { perform(.findPrevious) },
            Command(id: "browser.mute", title: "Mute or Unmute This Tab", category: "Browser", icon: "speaker.slash",
                    available: { BrowserActions.showing && BrowserEngine.chromium }) { perform(.toggleMute) },
            Command(id: "browser.ask", title: "Ask About This Page", category: "Browser", icon: "sparkles",
                    available: open) { perform(.askAboutPage) },
            Command(id: "browser.split", title: "Split View", category: "Browser", icon: "square.split.2x1",
                    available: open) { perform(.toggleSplit) },
            Command(id: "browser.sleep", title: "Put Other Tabs to Sleep", category: "Browser", icon: "moon.zzz",
                    available: { BrowserActions.showing && BrowserEngine.chromium }) { perform(.sleepOthers) },
            Command(id: "browser.copyLink", title: "Copy Page Link", category: "Browser", icon: "link",
                    available: open) { perform(.copyLink) },
            Command(id: "browser.openOutside", title: "Open Page in Default Browser", category: "Browser",
                    icon: "safari", available: open) { perform(.openOutside) },
        ]
        for (place, code) in digits.enumerated() {
            list.append(Command(id: "browser.tab\(place + 1)", title: "Show Tab \(place + 1)", category: "Browser",
                                icon: "\(place + 1).square", keys: .cmd(code, "\(place + 1)"),
                                available: open) { perform(.tab(place)) })
        }
        return list
    }
}
