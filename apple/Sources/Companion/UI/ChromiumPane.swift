import AppKit
import CEFKit
import SwiftUI

/// The browser on Chromium, in Companion's own design: the same frame, tabs,
/// command bar and start page as the WebKit browser, with Chromium drawing
/// the pages (and running Chrome's extensions) underneath.
struct ChromiumBody: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tabs: ChromiumTabs

    var body: some View {
        ZStack(alignment: .top) {
            BrowserBody(web: tabs) { tab in
                PasswordBar(page: tab)
                ChromiumTabView(tab: tab, tabs: tabs)
                    .id(tab.id)
            }
            if tabs.tabs.isEmpty {
                starting
                    .padding(.top, 44)
            }
        }
        .onAppear { tabs.ensureTab() }
    }

    /// Before the first tab: Chromium is starting, or could not.
    private var starting: some View {
        VStack(spacing: 10) {
            if tabs.problem == nil {
                LoadingMark(state: .working, size: 16)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Theme.ink.opacity(0.45))
            }
            Text(tabs.problem ?? "Starting Chromium…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink.opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if tabs.problem != nil {
                Button("Use the WebKit browser instead") {
                    UserDefaults.standard.set(false, forKey: BrowserEngine.key)
                }
                .buttonStyle(.link)
                .font(.system(size: 11.5))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A tab's content: Companion's start page until it goes somewhere, then
/// the page itself. Under the page sits a quiet stand-in (its site and a
/// mark while it loads), seen only while there is no page over it yet: a
/// tab waking from sleep, or making its first page.
private struct ChromiumTabView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: ChromiumTab
    @ObservedObject var tabs: ChromiumTabs

    var body: some View {
        if tab.isBlank {
            NewTabPage(web: tabs, tab: tab, chatPages: chatPages)
        } else {
            ZStack {
                standIn
                ChromiumHost(tab: tab, browser: tab.browser)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var standIn: some View {
        VStack(spacing: 10) {
            LoadingMark(state: tab.asleep ? .idle : .working, size: 16)
            Text(tab.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.6))
                .lineLimit(1)
            if tab.asleep {
                Text("Asleep to save memory")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.4))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Pages the agent used in this chat, offered first on a new tab.
    private var chatPages: [String] {
        app.sessionWeb.filter { URL(string: $0)?.scheme?.hasPrefix("http") == true }
    }
}

/// Chrome's extensions, reached from Companion's bar: add them from the
/// Web Store and manage them (pin, options, shortcuts) on Chrome's own
/// Extensions page, each in a tab.
struct ChromiumExtensionsMenu: View {
    @ObservedObject var tabs: ChromiumTabs

    var body: some View {
        BarMenu("puzzlepiece", help: "Extensions") {
            [
                .action("Chrome Web Store") { tabs.newTab("https://chromewebstore.google.com") },
                .action("Manage Extensions") { tabs.newTab("chrome://extensions/") },
                .action("Extension Shortcuts") { tabs.newTab("chrome://extensions/shortcuts") },
            ]
        }
    }
}

/// Holds the place of a tab's page in the pane: the tab's own window is
/// kept exactly over it, moving and resizing with it, and hidden when the
/// pane goes. A tab with no browser yet (asleep, or about to make its first
/// page) is woken, and its browser placed as soon as there is one.
struct ChromiumHost: NSViewRepresentable {
    let tab: ChromiumTab
    /// The tab's browser now, so a new one (the tab woken, or making its
    /// first page) brings an update that places it.
    let browser: ChromiumBrowser?

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.tab = tab
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.tab = tab
        view.refresh()
        // The layout around it may have changed (a sidebar, a divider).
        view.settle()
    }

    static func dismantleNSView(_ view: HostView, coordinator: ()) {
        view.tab?.browser?.hide()
        view.tab = nil
    }

    final class HostView: NSView {
        var tab: ChromiumTab? {
            didSet {
                guard oldValue !== tab else { return }
                oldValue?.browser?.hide()
                placed = nil
                place()
            }
        }

        /// The browser placed last, so a new one (a tab woken, or sent
        /// somewhere for the first time) is placed in its turn.
        private weak var placed: ChromiumBrowser?

        override var isFlipped: Bool { true }

        /// Places the tab's browser if it is not the one placed last.
        func refresh() {
            if tab?.browser !== placed { place() }
        }

        /// The panel's resizes, watched: SwiftUI can move this view inside
        /// the panel (a sidebar opening beside the chat) without changing
        /// its size, and then nothing here would hear of it.
        private var watching: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watching.forEach(NotificationCenter.default.removeObserver)
            watching = []
            if let window {
                // Moved too: the page is a window of its own over the pane,
                // and a panel moved without resizing (dragged, or put back
                // where it was) left the page behind at its old place.
                for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                             NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
                    watching.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.settle() }
                    })
                }
                // And every view it sits in: SwiftUI moves a container (the
                // sidebar opening pushes the pane along) and leaves this
                // view's own frame as it was, so only the container hears
                // of it. The page would stay behind, half outside the pane.
                var ancestor = superview
                while let view = ancestor {
                    view.postsFrameChangedNotifications = true
                    watching.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.placeSoon() }
                    })
                    ancestor = view.superview
                }
            }
            settle()
        }

        /// Places the page now and again as SwiftUI settles the pane's place
        /// over the next moments (animations, the bar measuring itself).
        func settle() {
            place()
            for delay in [0.05, 0.2, 0.45, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.place() }
            }
        }

        override func layout() {
            super.layout()
            placeSoon()
        }

        // Its own frame changing (a divider dragged) places the page at
        // once, in the same frame, so the page never trails the pane; the
        // many moves of the views around it are gathered (`placeSoon`).
        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            place()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            place()
        }

        /// One placing for all the moves of one layout pass. A resize moves
        /// this view and every container around it many times a frame, and
        /// each placing moves another process's window: placed each time,
        /// resizing the panel stuttered.
        private var placeQueued = false
        private func placeSoon() {
            guard !placeQueued else { return }
            placeQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.placeQueued = false
                self.place()
            }
        }

        override func viewDidHide() {
            super.viewDidHide()
            tab?.browser?.hide()
            placed = nil
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            place()
        }

        private func place() {
            guard let tab else { return }
            // Shown, it wakes: out of the way of the layout under way.
            if tab.asleep {
                DispatchQueue.main.async { tab.wake() }
                return
            }
            guard let browser = tab.browser else { return }
            guard let window, !isHiddenOrHasHiddenAncestor, bounds.width > 20, bounds.height > 20 else {
                browser.hide()
                placed = nil
                return
            }
            let frame = window.convertToScreen(convert(bounds, to: nil))
            // Its corners follow the rounded place the page has in its panel.
            browser.cornerRadius = Theme.innerRadius
            browser.show(above: window, frame: frame)
            placed = browser
        }
    }
}
