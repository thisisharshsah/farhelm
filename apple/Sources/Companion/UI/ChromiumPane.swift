import AppKit
import CEFKit
import SwiftUI

/// The browser beside the chat on Chromium, in Companion's own design: the
/// same bar, tabs and new tab page as the WebKit browser, with Chromium
/// drawing the pages (and running Chrome's extensions) underneath.
struct ChromiumBody: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tabs: ChromiumTabs

    var body: some View {
        ZStack(alignment: .top) {
            BrowserBody(web: tabs) { tab in
                PasswordBar(page: tab)
                ChromiumTabView(tab: tab, history: tabs.history)
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

/// A tab's content: Companion's new tab page until it goes somewhere,
/// then the page itself.
private struct ChromiumTabView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: ChromiumTab
    let history: BrowserHistory

    var body: some View {
        if tab.isBlank {
            NewTabPage(history: history, chatPages: chatPages) { url in tab.load(url) }
        } else {
            ChromiumHost(tab: tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
    let size: CGFloat

    var body: some View {
        Menu {
            Button("Chrome Web Store") { tabs.newTab("https://chromewebstore.google.com") }
            Button("Manage Extensions") { tabs.newTab("chrome://extensions/") }
            Button("Extension Shortcuts") { tabs.newTab("chrome://extensions/shortcuts") }
        } label: {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.68))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Extensions")
    }
}

/// Holds the place of the tab in the pane: the tab's own window is kept
/// exactly over it, moving and resizing with it, and hidden when the pane
/// goes.
private struct ChromiumHost: NSViewRepresentable {
    let tab: ChromiumTab

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.tab = tab
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.tab = tab
    }

    static func dismantleNSView(_ view: HostView, coordinator: ()) {
        view.tab?.browser.hide()
        view.tab = nil
    }

    final class HostView: NSView {
        var tab: ChromiumTab? {
            didSet {
                guard oldValue !== tab else { return }
                oldValue?.browser.hide()
                place()
            }
        }

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            place()
            // SwiftUI settles the pane's place over the next moments
            // (animations, the bar measuring itself); follow it there.
            for delay in [0.05, 0.2, 0.45] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.place() }
            }
        }

        override func layout() {
            super.layout()
            place()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            place()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            place()
        }

        override func viewDidHide() {
            super.viewDidHide()
            tab?.browser.hide()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            place()
        }

        private func place() {
            guard let tab else { return }
            guard let window, !isHiddenWithOrAncestor, bounds.width > 20, bounds.height > 20 else {
                tab.browser.hide()
                return
            }
            let frame = window.convertToScreen(convert(bounds, to: nil))
            // Its corners follow the rounded place the page has in its panel.
            tab.browser.cornerRadius = Theme.innerRadius
            tab.browser.show(above: window, frame: frame)
        }

        private var isHiddenWithOrAncestor: Bool { isHiddenOrHasHiddenAncestor }
    }
}
