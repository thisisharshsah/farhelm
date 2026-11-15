import AppKit
import CEFKit
import Combine
import Foundation

/// Which engine Companion's browser runs: Chromium (the way Arc is built:
/// Chrome's own extensions, Web Store and profile, inside Companion's own
/// bar and pages) when it is built in and not turned off in Settings >
/// Browser; otherwise WebKit.
enum BrowserEngine {
    static let key = "browserChromium"

    static var chromium: Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool ?? true) && Chromium.isAvailable
    }

    /// One Chromium profile for all chats, kept like a browser's: sign-ins,
    /// extensions, history and settings.
    @MainActor
    static func start() -> Bool {
        if Chromium.isRunning { return true }
        // A window Chromium opens on its own becomes a tab in this chat's
        // browser instead, so nothing opens outside Companion.
        Chromium.strayPageHandler = { address in
            MainActor.assumeIsolated {
                guard let url = URL(string: address) else { return }
                let app = AppState.shared
                if app.sidePanel != .browser { app.showSide(.browser) }
                app.web.chromium.open(url)
            }
        }
        let profile = ContextStore.shared.baseDir.appendingPathComponent("chromium", isDirectory: true)
        return Chromium.start(withProfileDirectory: profile.path)
    }

    /// Started and ready for tabs (it finishes starting a moment later).
    @MainActor
    static func ready() async -> Bool {
        guard start() else { return false }
        if Chromium.isReady { return true }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Chromium.whenReady { done.resume() }
        }
        return true
    }
}

/// One Chromium tab.
@MainActor
final class ChromiumTab: NSObject, ObservableObject, Identifiable, ChromiumBrowserDelegate {
    let id = UUID()
    private(set) var browser: ChromiumBrowser!
    @Published private(set) var title = ""
    /// The address as Chromium reports it ("about:blank" before anything).
    @Published private(set) var address = ""
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    fileprivate weak var tabs: ChromiumTabs?
    /// iCloud Passwords' page script and its way back are in place.
    private var prepared = false
    /// A page asked for before the browser was there to take it.
    private var queued: URL?

    /// A tab that has not gone anywhere shows Companion's suggestions.
    var isBlank: Bool { address.isEmpty || address == ChromiumTabs.blank }

    var url: URL? { isBlank ? nil : URL(string: address) }

    var label: String {
        if !title.isEmpty, !isBlank { return title }
        if let host = url?.host { return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
        return "New tab"
    }

    fileprivate init?(url: String, tabs: ChromiumTabs) {
        self.tabs = tabs
        super.init()
        guard let browser = ChromiumBrowser(url: url, delegate: self) else { return nil }
        self.browser = browser
        address = url
    }

    func load(_ url: URL) {
        guard browser.ready else {
            queued = url
            address = url.absoluteString
            return
        }
        browser.load(url.absoluteString)
    }

    func goBack() { browser.goBack() }
    func goForward() { browser.goForward() }
    func reload() { browser.reload() }
    func stopLoading() { browser.stop() }

    /// A window a page or extension opened, as a tab.
    fileprivate init(adopting browser: ChromiumBrowser, tabs: ChromiumTabs) {
        self.tabs = tabs
        self.browser = browser
        super.init()
        browser.delegate = self
    }

    // MARK: ChromiumBrowserDelegate (called on the main thread)

    nonisolated func chromiumBrowser(_ browser: ChromiumBrowser, didChangeTitle title: String) {
        MainActor.assumeIsolated { self.title = title }
    }

    nonisolated func chromiumBrowser(_ browser: ChromiumBrowser, didChangeURL url: String) {
        MainActor.assumeIsolated { self.address = url }
    }

    nonisolated func chromiumBrowser(_ browser: ChromiumBrowser, didChangeLoading loading: Bool,
                                     canGoBack: Bool, canGoForward: Bool) {
        MainActor.assumeIsolated {
            self.loading = loading
            self.canGoBack = canGoBack
            self.canGoForward = canGoForward
            prepare()
            if let page = queued, browser.ready {
                queued = nil
                browser.load(page.absoluteString)
            }
            if !loading { tabs?.finished(self) }
        }
    }

    nonisolated func chromiumBrowser(_ browser: ChromiumBrowser, didOpenPopup popup: ChromiumBrowser) {
        MainActor.assumeIsolated { tabs?.adopt(popup, after: self) }
    }

    nonisolated func chromiumBrowserDidClose(_ browser: ChromiumBrowser) {
        MainActor.assumeIsolated {
            ICloudPasswords.shared.forget(page: self)
            tabs?.closed(self)
        }
    }

    // MARK: iCloud Passwords, as in the WebKit browser

    private static let binding = "__companionPasswordsPost"

    /// The same page script, reporting through a DevTools binding instead
    /// of WebKit's message handler.
    private static let passwordScript = ICloudPasswords.pageScript.replacingOccurrences(
        of: "window.webkit.messageHandlers.companionPasswords.postMessage(m)",
        with: "window.\(binding)(JSON.stringify(m))")

    private func prepare() {
        // The browser reports its first page while it is still being made,
        // before `browser` is set here; it is prepared on the next report.
        guard !prepared, let browser, browser.ready else { return }
        prepared = true
        browser.addBinding(Self.binding)
        browser.addScriptOnNewDocument(Self.passwordScript)
    }

    nonisolated func chromiumBrowser(_ browser: ChromiumBrowser, didCallBinding name: String, payload: String) {
        MainActor.assumeIsolated {
            guard name == Self.binding,
                  let body = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return }
            ICloudPasswords.shared.handle(body, page: self)
        }
    }
}

extension ChromiumTab: PasswordPage {
    var passwordID: ObjectIdentifier { ObjectIdentifier(self) }

    /// The arguments become constants, then the body runs in the page.
    func runPasswordScript(_ body: String, _ arguments: [String: Any]) async {
        let constants = arguments.compactMap { key, value -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
            return "const \(key) = \(String(decoding: data, as: UTF8.self));"
        }.joined(separator: "\n")
        let script = "(async () => {\n\(constants)\n\(body)\n})()"
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            browser.evaluate(script) { _, _ in done.resume() }
        }
    }
}

/// A chat's Chromium tabs. Each tab is a Chrome-style browser in a window
/// of its own that the pane keeps over itself; only the one showing is
/// shown.
@MainActor
final class ChromiumTabs: ObservableObject {
    /// What a new tab loads: nothing, so Companion's suggestions show.
    nonisolated static let blank = "about:blank"

    @Published private(set) var tabs: [ChromiumTab] = []
    @Published var selected: UUID?
    /// Where visited pages are remembered, shared with the WebKit browser.
    let history: BrowserHistory

    init(history: BrowserHistory) {
        self.history = history
    }
    /// The error from starting Chromium, when it did not start.
    @Published private(set) var problem: String?

    var current: ChromiumTab? { tabs.first { $0.id == selected } ?? tabs.last }

    @discardableResult
    func newTab(_ url: String = ChromiumTabs.blank) -> ChromiumTab? {
        guard BrowserEngine.start() else {
            problem = Chromium.lastError
            return nil
        }
        problem = nil
        // Chromium finishes starting a moment later; the tab opens then.
        guard Chromium.isReady else {
            pending.append(url)
            if pending.count == 1 {
                Chromium.whenReady { [weak self] in
                    MainActor.assumeIsolated { self?.openPending() }
                }
            }
            return nil
        }
        guard let tab = ChromiumTab(url: url, tabs: self) else {
            problem = "Chromium could not open a tab."
            return nil
        }
        insert(tab, after: current)
        return tab
    }

    func ensureTab() {
        if tabs.isEmpty, pending.isEmpty { newTab() }
    }

    /// Tabs asked for before Chromium was ready.
    private var pending: [String] = []

    private func openPending() {
        let urls = pending
        pending = []
        for url in urls { newTab(url) }
    }

    /// Shows a page: in the current tab if asked, or when it is a new tab
    /// page, else in a new one.
    func open(_ url: URL, newTab wantNew: Bool = true) {
        if let tab = current, !wantNew || tab.isBlank {
            tab.load(url)
        } else {
            newTab(url.absoluteString)
        }
    }

    /// Closing the last tab leaves a fresh one in its place, as in the
    /// WebKit browser (closing that one, blank, closes the browser: the bar
    /// does that).
    func close(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.browser.close()
        remove(tab)
        if tabs.isEmpty { newTab() }
    }

    /// Every tab closes (the chat's session ends).
    func end() {
        ending = true
        defer { ending = false }
        for tab in tabs { tab.browser.close() }
        tabs = []
        selected = nil
    }

    /// The session is ending: no fresh tab replaces the closed ones.
    private var ending = false

    fileprivate func adopt(_ browser: ChromiumBrowser, after opener: ChromiumTab) {
        insert(ChromiumTab(adopting: browser, tabs: self), after: opener)
    }

    /// A page closed itself (window.close()).
    fileprivate func closed(_ tab: ChromiumTab) {
        let wasOpen = tabs.contains { $0.id == tab.id }
        remove(tab)
        if wasOpen, tabs.isEmpty, !ending { newTab() }
    }

    fileprivate func finished(_ tab: ChromiumTab) {
        guard let url = tab.url, url.scheme?.hasPrefix("http") == true else { return }
        history.record(url, title: tab.title)
    }

    private func insert(_ tab: ChromiumTab, after other: ChromiumTab?) {
        if let other, let index = tabs.firstIndex(where: { $0.id == other.id }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        selected = tab.id
    }

    private func remove(_ tab: ChromiumTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if selected == tab.id {
            selected = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }
}

// MARK: - One design for both engines

extension ChromiumTab: BrowsingTab {}

extension ChromiumTabs: BrowsingModel {
    func openNewTab() { newTab() }
}
