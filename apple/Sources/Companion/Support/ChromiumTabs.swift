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

/// One Chromium tab. Its page lives in a browser of its own, made only when
/// the tab is sent somewhere: a blank tab (the start page) holds none, and
/// a tab out of sight for a while is put to sleep, its browser closed and
/// its place kept, to load again when it is shown.
@MainActor
final class ChromiumTab: NSObject, ObservableObject, Identifiable, ChromiumBrowserDelegate {
    let id = UUID()
    /// The page's browser: nil while the tab is blank or asleep.
    private(set) var browser: ChromiumBrowser?
    @Published private(set) var title = ""
    /// The address as Chromium reports it ("about:blank" before anything).
    @Published private(set) var address = ""
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// The page's own color, for the browser's frame to take on.
    @Published private(set) var pageColor: NSColor?
    /// Asleep: its browser was closed to give back its memory.
    @Published private(set) var asleep = false
    /// Its page is playing sound, as the page itself reports.
    @Published private(set) var audible = false
    /// Its sound is turned off.
    @Published private(set) var muted = false
    /// When it was last shown, for how long it has been out of sight.
    var lastShown = Date()
    fileprivate weak var tabs: ChromiumTabs?
    /// iCloud Passwords' page script and its way back are in place.
    private var prepared = false
    /// A page asked for before the browser was there to take it.
    private var queued: URL?
    /// Closed for good: nothing is made for it any more.
    private var gone = false
    /// A browser is to be made once Chromium is ready.
    private var waiting = false
    /// Browsers this tab let go (put to sleep): what they still report is
    /// not this tab's any more.
    private var retired = Set<ObjectIdentifier>()

    /// A tab that has not gone anywhere shows Companion's start page.
    var isBlank: Bool { address.isEmpty || address == ChromiumTabs.blank }

    var url: URL? { isBlank ? nil : URL(string: address) }

    var label: String {
        if !title.isEmpty, !isBlank { return title }
        if let host = url?.host { return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
        return "New tab"
    }

    fileprivate init(address: String, tabs: ChromiumTabs?) {
        self.tabs = tabs
        super.init()
        self.address = address
    }

    /// A window a page or extension opened, as a tab.
    fileprivate init(adopting browser: ChromiumBrowser, tabs: ChromiumTabs) {
        self.tabs = tabs
        self.browser = browser
        super.init()
        browser.delegate = self
        refusePasskeys()
    }

    /// Passkeys in Companion's browser: a page's request goes to Chromium's
    /// own passkey sheet, which signs in with a passkey on the phone (a QR
    /// code, then Bluetooth) or a security key. Without the Bluetooth usage
    /// line in Info.plist macOS ended Companion the moment that sheet
    /// looked for a phone. Passkeys kept on this Mac (iCloud Keychain, Touch
    /// ID) are only for browsers Apple has entitled, so pages are told this
    /// Mac has none: they then offer the phone, a key or a password, and
    /// never wait on a Mac passkey that cannot come.
    private static let passkeyGuard = """
    (() => { try {
      if (window.PublicKeyCredential) {
        PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = () => Promise.resolve(false);
        if (PublicKeyCredential.isConditionalMediationAvailable) PublicKeyCredential.isConditionalMediationAvailable = () => Promise.resolve(false);
      }
      const c = navigator.credentials;
      if (c && !c.__companionGuard) {
        const get = c.get.bind(c);
        // Passkey autofill in the sign-in field (conditional mediation)
        // only works with passkeys on this Mac: it is left out.
        c.get = (o) => (o && o.publicKey && o.mediation === "conditional")
          ? new Promise(() => {}) : get(o);
        c.__companionGuard = true;
      }
    } catch (e) {} })();
    """

    private func refusePasskeys() {
        Task { @MainActor in
            _ = await self.devTools("Page.addScriptToEvaluateOnNewDocument", ["source": Self.passkeyGuard])
            // The page already open gets it too.
            _ = await self.devTools("Runtime.evaluate", ["expression": Self.passkeyGuard])
        }
    }

    func load(_ url: URL) {
        guard !gone else { return }
        asleep = false
        address = url.absoluteString
        guard let browser else {
            make(url.absoluteString)
            return
        }
        guard browser.ready else {
            queued = url
            return
        }
        browser.load(url.absoluteString)
    }

    func goBack() { browser?.goBack() }
    func goForward() { browser?.goForward() }

    func reload() {
        if asleep { wake() } else { browser?.reload() }
    }

    func stopLoading() { browser?.stop() }

    func toggleMute() {
        muted.toggle()
        browser?.muted = muted
    }

    func run(_ body: String) async -> Any? {
        guard !isBlank, browser != nil else { return nil }
        return await value(of: "(() => {\n\(body)\n})()")
    }

    /// Makes the tab's browser for its page, now or once Chromium is ready.
    fileprivate func start() {
        make(address)
    }

    private func make(_ page: String) {
        guard !gone, browser == nil, page != ChromiumTabs.blank, !page.isEmpty else { return }
        guard Chromium.isReady else {
            guard !waiting else { return }
            waiting = true
            Chromium.whenReady { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.waiting = false
                    // Whatever it should show by now.
                    self.make(self.address)
                }
            }
            return
        }
        guard let made = ChromiumBrowser(url: page, delegate: self) else {
            tabs?.failed(self)
            return
        }
        objectWillChange.send()
        prepared = false
        browser = made
        refusePasskeys()
    }

    /// Wakes a sleeping tab: its page loads again. (Where it was in its
    /// back and forward history is not kept.)
    func wake() {
        guard asleep, !gone else { return }
        asleep = false
        make(address)
    }

    /// Puts the tab to sleep: its browser closes; its address, title and
    /// place stay.
    fileprivate func sleep() {
        guard let browser, !isBlank, !gone, let tabs, tabs.current?.id != id, tabs.split != id else { return }
        retired.insert(ObjectIdentifier(browser))
        objectWillChange.send()
        self.browser = nil
        prepared = false
        queued = nil
        loading = false
        audible = false
        asleep = true
        browser.close()
    }

    /// Sleeps, unless its page is playing sound or video.
    fileprivate func sleepIfQuiet() {
        guard browser != nil, !loading, !asleep else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let playing = await self.value(of: "[...document.querySelectorAll('audio,video')].some((m) => !m.paused && !m.ended && !m.muted && m.volume > 0)")
            if (playing as? Bool) != true { self.sleep() }
        }
    }

    /// Closes the tab for good.
    fileprivate func shut() {
        gone = true
        browser?.close()
    }

    /// Runs JavaScript in the page, handing back DevTools' answer as JSON,
    /// or why not.
    func evaluate(_ expression: String, completion: @escaping (String?, String?) -> Void) {
        guard let browser else {
            completion(nil, asleep ? "The tab is asleep. Show it to wake it." : "The tab has no page yet.")
            return
        }
        browser.evaluate(expression, completion: completion)
    }

    /// Runs a DevTools method on the page and gives back its result, or
    /// why not.
    func devTools(_ method: String, _ parameters: [String: Any] = [:]) async -> (result: [String: Any]?, error: String?) {
        guard let browser else { return (nil, asleep ? "The tab is asleep. Focus it first." : "The tab has no page yet.") }
        let data = (try? JSONSerialization.data(withJSONObject: parameters)) ?? Data("{}".utf8)
        let json = String(decoding: data, as: UTF8.self)
        let reply: (String?, String?) = await withCheckedContinuation { done in
            browser.devTools(method, parameters: json) { answer, error in done.resume(returning: (answer, error)) }
        }
        guard let text = reply.0 else { return (nil, reply.1 ?? "The page did not answer.") }
        let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        return (object ?? [:], nil)
    }

    /// The value an expression gives in the page, or nil when it gave none
    /// or failed.
    func value(of expression: String) async -> Any? {
        let json: String? = await withCheckedContinuation { done in
            evaluate(expression) { json, _ in done.resume(returning: json) }
        }
        guard let json, let reply = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              reply["exceptionDetails"] == nil else { return nil }
        return (reply["result"] as? [String: Any])?["value"]
    }

    func snapshot() async -> PageSnapshot? {
        guard !isBlank, browser != nil else { return nil }
        let found = await value(of: "(() => {\n\(PageSnapshot.script)\n})()")
        return PageSnapshot(found)
    }

    /// Reads the page's own color, once it has loaded.
    private func readColor() {
        guard !isBlank, browser != nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let found = await self.value(of: "(() => {\n\(PageColor.script)\n})()")
            let color = (found as? String).flatMap(PageColor.parse)
            if color != self.pageColor { self.pageColor = color }
        }
    }

    private func isMine(_ browser: ChromiumBrowser) -> Bool {
        !retired.contains(ObjectIdentifier(browser))
    }

    /// A dialog of the page's own (alert, confirm, prompt, or "leave this
    /// page?"), waiting for an answer: the page does nothing until then.
    struct PageDialog: Equatable {
        let kind: String
        let message: String
        let defaultText: String
    }

    @Published private(set) var dialog: PageDialog?

    /// Answers the page's dialog: OK or Cancel, with the text for a prompt.
    func answerDialog(accept: Bool, text: String? = nil) {
        browser?.answerDialog(accept: accept, text: text)
        dialog = nil
    }

    // MARK: ChromiumBrowserDelegate (called on the main thread)

    nonisolated func chromiumBrowser(_ browser: ChromiumBrowser, opensDialog kind: String, message: String,
                                     defaultText: String) {
        MainActor.assumeIsolated {
            guard isMine(browser) else { return }
            dialog = PageDialog(kind: kind, message: message, defaultText: defaultText)
            PageLabels.dialog = message
        }
    }

    nonisolated func chromiumBrowserDialogClosed(_ browser: ChromiumBrowser) {
        MainActor.assumeIsolated {
            guard isMine(browser) else { return }
            dialog = nil
        }
    }

    nonisolated func chromiumBrowser(_ browser: ChromiumBrowser, didChangeTitle title: String) {
        MainActor.assumeIsolated {
            guard isMine(browser) else { return }
            self.title = title
        }
    }

    nonisolated func chromiumBrowser(_ browser: ChromiumBrowser, didChangeURL url: String) {
        MainActor.assumeIsolated {
            guard isMine(browser) else { return }
            // Another site brings its own color.
            if URL(string: url)?.host != self.url?.host { pageColor = nil }
            self.address = url
        }
    }

    nonisolated func chromiumBrowser(_ browser: ChromiumBrowser, didChangeLoading loading: Bool,
                                     canGoBack: Bool, canGoForward: Bool) {
        MainActor.assumeIsolated {
            guard isMine(browser) else { return }
            // A new document starts silent, and says when it plays.
            if loading, !self.loading { audible = false }
            self.loading = loading
            self.canGoBack = canGoBack
            self.canGoForward = canGoForward
            prepare()
            if let page = queued, browser.ready {
                queued = nil
                browser.load(page.absoluteString)
            }
            if !loading {
                tabs?.finished(self)
                readColor()
            }
        }
    }

    nonisolated func chromiumBrowser(_ browser: ChromiumBrowser, didOpenPopup popup: ChromiumBrowser) {
        MainActor.assumeIsolated {
            if let tabs {
                tabs.adopt(popup, after: self)
                return
            }
            // A page of Companion's own (the code editor) opening a link:
            // it goes to the browser beside the chat, once it has an address.
            let address = popup.url
            popup.close()
            Task { @MainActor in
                if let url = URL(string: address), url.scheme?.hasPrefix("http") == true {
                    AppState.shared.browse(url)
                }
            }
        }
    }

    nonisolated func chromiumBrowserDidClose(_ browser: ChromiumBrowser) {
        MainActor.assumeIsolated {
            ICloudPasswords.shared.forget(page: self)
            // One put to sleep: the tab stays, asleep.
            guard isMine(browser) else {
                retired.remove(ObjectIdentifier(browser))
                return
            }
            self.browser = nil
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

    private static let soundBinding = "__companionSound"

    /// Tells the tab when the page starts or stops playing sound, from the
    /// media's own events, so nothing has to keep asking.
    private static let soundScript = #"""
    (() => {
      if (window.__companionSoundWatch) return;
      window.__companionSoundWatch = true;
      let last = null;
      const report = () => {
        const on = [...document.querySelectorAll('audio,video')]
          .some((m) => !m.paused && !m.ended && !m.muted && m.volume > 0);
        if (on === last) return;
        last = on;
        try { window.\#(soundBinding)(on ? '1' : '0'); } catch (error) {}
      };
      for (const type of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied']) {
        document.addEventListener(type, report, true);
      }
    })();
    """#

    private func prepare() {
        // The browser reports its first page while it is still being made,
        // before `browser` is set here; it is prepared on the next report.
        guard !prepared, let browser, browser.ready else { return }
        prepared = true
        browser.addBinding(Self.binding)
        browser.addScriptOnNewDocument(Self.passwordScript)
        browser.addBinding(Self.soundBinding)
        browser.addScriptOnNewDocument(Self.soundScript)
        if muted { browser.muted = true }
    }

    nonisolated func chromiumBrowser(_ browser: ChromiumBrowser, didCallBinding name: String, payload: String) {
        MainActor.assumeIsolated {
            if name == Self.soundBinding {
                if isMine(browser) { audible = payload == "1" }
                return
            }
            guard name == Self.binding,
                  let body = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return }
            ICloudPasswords.shared.handle(body, page: self)
        }
    }
}

extension ChromiumTab: PasswordPage {
    var passwordID: ObjectIdentifier { ObjectIdentifier(self) }
    var passwordHost: String? { url?.host }

    /// The arguments become constants, then the body runs in the page.
    func runPasswordScript(_ body: String, _ arguments: [String: Any]) async {
        let constants = arguments.compactMap { key, value -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
            return "const \(key) = \(String(decoding: data, as: UTF8.self));"
        }.joined(separator: "\n")
        let script = "(async () => {\n\(constants)\n\(body)\n})()"
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            evaluate(script) { _, _ in done.resume() }
        }
    }
}

/// A chat's Chromium tabs. Each tab with a page is a Chrome-style browser in
/// a window of its own that the pane keeps over itself; only those showing
/// are shown.
@MainActor
final class ChromiumTabs: ObservableObject {
    /// What a new tab loads: nothing, so Companion's start page shows.
    nonisolated static let blank = "about:blank"
    /// How long a tab stays out of sight before it sleeps.
    static let napAfter: TimeInterval = 20 * 60

    @Published private(set) var tabs: [ChromiumTab] = []
    @Published var selected: UUID? {
        didSet {
            guard selected != oldValue else { return }
            let now = Date()
            tabs.first { $0.id == oldValue }?.lastShown = now
            if let shown = tabs.first(where: { $0.id == selected }) {
                shown.lastShown = now
                shown.wake()
            }
        }
    }
    /// The tab shown beside the current one, in split view.
    @Published var split: UUID? {
        didSet {
            guard let side = tabs.first(where: { $0.id == split }) else { return }
            side.lastShown = Date()
            side.wake()
        }
    }
    /// Where visited pages are remembered, shared with the WebKit browser.
    let history: BrowserHistory
    /// The error from starting Chromium, when it did not start.
    @Published private(set) var problem: String?
    /// Addresses of closed tabs, the one closed last last.
    @Published private var closedPages: [String] = []
    private var napper: Timer?

    init(history: BrowserHistory) {
        self.history = history
        // Tabs long out of sight are looked at once a minute.
        napper = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.nap() }
        }
    }

    var current: ChromiumTab? { tabs.first { $0.id == selected } ?? tabs.last }

    /// A new tab, showing a page or the start page. A blank one holds no
    /// browser, so it costs nothing until it goes somewhere.
    @discardableResult
    func newTab(_ url: String = ChromiumTabs.blank) -> ChromiumTab? {
        guard BrowserEngine.start() else {
            problem = Chromium.lastError
            return nil
        }
        problem = nil
        let tab = ChromiumTab(address: url, tabs: self)
        insert(tab, after: current)
        tab.start()
        return tab
    }

    func ensureTab() {
        if tabs.isEmpty { newTab() }
    }

    /// Shows a page: in the current tab if asked, or when it is blank, else
    /// in a new one.
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
        if let url = tab.url { closedPages = Array((closedPages + [url.absoluteString]).suffix(20)) }
        tab.shut()
        remove(tab)
        if tabs.isEmpty { newTab() }
    }

    var canReopen: Bool { !closedPages.isEmpty }

    func reopenClosed() {
        guard let address = closedPages.popLast() else { return }
        newTab(address)
    }

    func move(_ id: UUID, before other: UUID?) {
        guard id != other, let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        if let other, let to = tabs.firstIndex(where: { $0.id == other }) {
            tabs.insert(tab, at: to)
        } else {
            tabs.append(tab)
        }
    }

    /// Every tab out of sight sleeps now.
    func sleepOthers() {
        for tab in tabs where tab.id != current?.id && tab.id != split {
            tab.sleepIfQuiet()
        }
    }

    func sleep(_ id: UUID) {
        guard id != current?.id, id != split, let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.sleepIfQuiet()
    }

    /// Tabs out of sight for longer than `napAfter` go to sleep.
    private func nap() {
        let now = Date()
        for tab in tabs where tab.id != current?.id && tab.id != split
            && now.timeIntervalSince(tab.lastShown) > Self.napAfter {
            tab.sleepIfQuiet()
        }
    }

    /// Every tab closes (the chat's session ends).
    func end() {
        ending = true
        defer { ending = false }
        napper?.invalidate()
        napper = nil
        for tab in tabs { tab.shut() }
        tabs = []
        selected = nil
        split = nil
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

    /// A tab's browser could not be made.
    fileprivate func failed(_ tab: ChromiumTab) {
        problem = Chromium.isRunning ? "Chromium could not open that page." : Chromium.lastError
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
        // A new tab shows on its own; split view, if any, ends.
        split = nil
        selected = tab.id
    }

    private func remove(_ tab: ChromiumTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if split == tab.id { split = nil }
        if selected == tab.id {
            // In split view the page beside it takes its place.
            if let side = split, tabs.contains(where: { $0.id == side }) {
                split = nil
                selected = side
            } else {
                selected = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
            }
        }
        if split != nil, split == selected { split = nil }
    }
}

extension ChromiumTab {
    /// A page of Companion's own, outside any chat's tabs (the code
    /// editor): it keeps its browser, never sleeps, and records no history.
    static func standalone(_ address: String) -> ChromiumTab? {
        guard BrowserEngine.start() else { return nil }
        let tab = ChromiumTab(address: address, tabs: nil)
        tab.start()
        return tab
    }
}

// MARK: - One design for both engines

extension ChromiumTab: BrowsingTab {}

extension ChromiumTabs: BrowsingModel {
    func openNewTab() { newTab() }
}
