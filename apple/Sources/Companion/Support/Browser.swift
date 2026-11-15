import AppKit
import Combine
import CryptoKit
import Foundation
import WebKit

/// A page the browser has shown, remembered so a new tab can offer it again.
struct VisitedPage: Codable, Identifiable, Equatable {
    var url: String
    var title: String
    var last: Date
    var visits: Int

    var id: String { url }
    var host: String {
        let host = URL(string: url)?.host ?? url
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// The pages visited in Companion's browser, newest first, kept on disk.
/// It is Companion's own list: nothing is read from Safari or Chrome.
@MainActor
final class BrowserHistory: ObservableObject {
    @Published private(set) var pages: [VisitedPage] = []

    /// Goes up when a picture is saved, so cards showing it redraw.
    @Published private(set) var pictureTick = 0

    private let file: URL
    private let pictures: URL
    private let cache = NSCache<NSString, NSImage>()
    private var iconsAsked = Set<String>()
    private static let limit = 300

    init(directory: URL) {
        file = directory.appendingPathComponent("browser-history.json")
        pictures = directory.appendingPathComponent("browser-pictures", isDirectory: true)
        try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([VisitedPage].self, from: data) {
            pages = saved
        }
    }

    func record(_ url: URL, title: String?) {
        guard url.scheme?.hasPrefix("http") == true else { return }
        let key = url.absoluteString
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var page = VisitedPage(url: key, title: name, last: Date(), visits: 1)
        if let index = pages.firstIndex(where: { $0.url == key }) {
            let old = pages.remove(at: index)
            page.visits = old.visits + 1
            if name.isEmpty { page.title = old.title }
        }
        pages.insert(page, at: 0)
        while pages.count > Self.limit {
            forgetThumbnail(of: pages.removeLast().url)
        }
        save()
        fetchIcon(for: url)
    }

    func remove(_ page: VisitedPage) {
        pages.removeAll { $0.url == page.url }
        forgetThumbnail(of: page.url)
        save()
    }

    func clear() {
        pages = []
        cache.removeAllObjects()
        try? FileManager.default.removeItem(at: pictures)
        try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        iconsAsked = []
        pictureTick += 1
        save()
    }

    // MARK: Pictures: a small shot of each page, and each site's icon

    private func name(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func thumbnailFile(_ address: String) -> URL {
        pictures.appendingPathComponent("page-" + name(address) + ".jpg")
    }

    private func iconFile(_ host: String) -> URL {
        pictures.appendingPathComponent("icon-" + name(host))
    }

    private func picture(at url: URL) -> NSImage? {
        let key = url.lastPathComponent as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// The page as it looked when it was last open.
    func thumbnail(for address: String) -> NSImage? {
        picture(at: thumbnailFile(address))
    }

    /// The site's own icon.
    func icon(for address: String) -> NSImage? {
        guard let host = URL(string: address)?.host else { return nil }
        return picture(at: iconFile(host))
    }

    func saveThumbnail(_ image: NSImage, for url: URL) {
        guard url.scheme?.hasPrefix("http") == true,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return }
        let file = thumbnailFile(url.absoluteString)
        try? data.write(to: file, options: .atomic)
        cache.setObject(image, forKey: file.lastPathComponent as NSString)
        pictureTick += 1
    }

    private func forgetThumbnail(of address: String) {
        let file = thumbnailFile(address)
        cache.removeObject(forKey: file.lastPathComponent as NSString)
        try? FileManager.default.removeItem(at: file)
    }

    /// Fetches a site's icon once and keeps it.
    private func fetchIcon(for url: URL) {
        guard let host = url.host, iconsAsked.insert(host).inserted else { return }
        let file = iconFile(host)
        guard !FileManager.default.fileExists(atPath: file.path),
              let source = URL(string: "https://\(host)/favicon.ico") else { return }
        Task { [weak self] in
            var request = URLRequest(url: source)
            request.timeoutInterval = 8
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count < 400_000,
                  NSImage(data: data)?.isValid == true else { return }
            try? data.write(to: file, options: .atomic)
            self?.pictureTick += 1
        }
    }

    /// What a new tab offers: recent pages, at most two from any one site so
    /// a single site cannot fill the grid.
    func suggestions(limit: Int = 12) -> [VisitedPage] {
        var perHost: [String: Int] = [:]
        var picked: [VisitedPage] = []
        for page in pages {
            let count = perHost[page.host, default: 0]
            guard count < 2 else { continue }
            perHost[page.host] = count + 1
            picked.append(page)
            if picked.count == limit { break }
        }
        return picked
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(pages) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

/// One tab: a web view and what the tab strip needs to know about it.
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    let webView: WKWebView

    @Published var title = ""
    @Published var url: URL?
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false

    /// A tab that has not been sent anywhere shows the suggestions.
    var isBlank: Bool { url == nil && !loading }

    var label: String {
        if !title.isEmpty { return title }
        if let host = url?.host { return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
        return "New tab"
    }

    fileprivate weak var model: BrowserModel?
    private var bag = Set<AnyCancellable>()

    fileprivate init(configuration: WKWebViewConfiguration, model: BrowserModel) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.model = model
        super.init()
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self

        webView.publisher(for: \.title)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.title = $0 ?? ""
                BrowserExtensions.shared.changed(self, .title)
            }
            .store(in: &bag)
        webView.publisher(for: \.url)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.url = $0
                self.model?.noteActivity()
                BrowserExtensions.shared.changed(self, .url)
            }
            .store(in: &bag)
        webView.publisher(for: \.isLoading)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.loading = $0
                BrowserExtensions.shared.changed(self, .loading)
            }
            .store(in: &bag)
        webView.publisher(for: \.canGoBack)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canGoBack = $0 }
            .store(in: &bag)
        webView.publisher(for: \.canGoForward)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canGoForward = $0 }
            .store(in: &bag)
    }

    func load(_ url: URL) {
        self.url = url
        webView.load(URLRequest(url: url))
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        model?.history.record(url, title: webView.title)
        // A moment for the page to draw, then a small picture of it for the
        // suggestions on a new tab.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.webView.url == url, self.webView.window != nil,
                  self.webView.bounds.width > 50 else { return }
            let shot = WKSnapshotConfiguration()
            // The top of the page, in the shape of a card.
            let width = self.webView.bounds.width
            shot.rect = CGRect(x: 0, y: 0, width: width, height: min(self.webView.bounds.height, width * 0.6))
            shot.snapshotWidth = 360
            self.webView.takeSnapshot(with: shot) { [weak self] image, _ in
                guard let image else { return }
                MainActor.assumeIsolated { self?.model?.history.saveThumbnail(image, for: url) }
            }
        }
    }

    // MARK: WKUIDelegate

    /// A link that asks for a new window opens in a new tab.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        model?.addTab(configuration: configuration).webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        model?.close(id)
    }

    /// A page's file field: the files the agent chose for it (approved),
    /// or the usual Open panel for the user.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        if let chosen = model?.takeUploads(), !chosen.isEmpty {
            completionHandler(parameters.allowsMultipleSelection ? chosen : [chosen[0]])
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { answer in completionHandler(answer == .OK ? panel.urls : nil) }
    }

    // MARK: Downloads

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    /// What the browser cannot show, or the page sends as an attachment, is saved.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        let attachment = disposition.hasPrefix("attachment")
        decisionHandler(navigationResponse.isForMainFrame && (!navigationResponse.canShowMIMEType || attachment)
                        ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = model?.downloads
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = model?.downloads
    }
}

/// Files the browser saves: into Downloads, under a name not taken yet,
/// remembered so the agent and the user know where each one went.
@MainActor
final class BrowserDownloads: NSObject, ObservableObject, WKDownloadDelegate {
    struct Saved: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let path: String
        let date: Date
        var failed = false
    }

    @Published private(set) var saved: [Saved] = []
    private var places: [ObjectIdentifier: URL] = [:]

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let fm = FileManager.default
        let folder = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var target = folder.appendingPathComponent(name)
        var number = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(stem) \(number)" + (ext.isEmpty ? "" : ".\(ext)"))
            number += 1
        }
        places[ObjectIdentifier(download)] = target
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let place = places.removeValue(forKey: ObjectIdentifier(download)) else { return }
        saved.insert(Saved(name: place.lastPathComponent, path: place.path, date: Date()), at: 0)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let place = places.removeValue(forKey: ObjectIdentifier(download)) else { return }
        saved.insert(Saved(name: place.lastPathComponent, path: place.path, date: Date(), failed: true), at: 0)
    }
}

/// The browser beside the chat: its tabs, which one is showing, and the
/// pages it has visited. It is its own browser; no sign-ins or history are
/// shared with Safari or Chrome.
@MainActor
final class BrowserModel: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var selected: UUID? {
        didSet {
            guard selected != oldValue else { return }
            // Extensions follow which tab is showing (chrome.tabs.onActivated).
            BrowserExtensions.shared.activated(tabs.first { $0.id == selected },
                                               previous: tabs.first { $0.id == oldValue }, in: self)
        }
    }
    let history: BrowserHistory

    /// One configuration for every tab of this session, so a sign-in in
    /// one holds in all. Its sign-ins, cookies and site data live in
    /// memory only: nothing is shared with another chat's session, and
    /// nothing is left once the session ends or the app quits.
    private let configuration: WKWebViewConfiguration = {
        let configuration = WKWebViewConfiguration()
        // By default sign-ins last only as long as the session; with "Keep
        // browser sign-ins" on (Settings > Passwords) they are kept on this
        // Mac, so a portal signed in to once stays signed in.
        configuration.websiteDataStore = UserDefaults.standard.bool(forKey: "browserKeepsSignIns")
            ? .default() : .nonPersistent()
        return configuration
    }()

    /// The same browser on Chromium (Settings > Browser), with its own tabs.
    let chromium: ChromiumTabs

    /// Files saved from pages, and files chosen for a page's file field.
    let downloads = BrowserDownloads()
    private var uploads: [URL] = []

    /// Files for the next file field a page opens (the agent's upload).
    func prepareUploads(_ files: [URL]) { uploads = files }

    fileprivate func takeUploads() -> [URL] {
        defer { uploads = [] }
        return uploads
    }

    init(history: BrowserHistory) {
        self.history = history
        chromium = ChromiumTabs(history: history)
        // Sign-in and sign-up forms get iCloud Passwords.
        ICloudPasswords.install(in: configuration)
        // The same Chrome extensions in every chat's browser.
        BrowserExtensions.shared.attach(configuration)
        BrowserExtensions.shared.opened(window: self)
    }

    /// Whether the session has a page open in any tab: something is
    /// running in it, whether or not its pane is showing.
    @Published private(set) var running = false
    /// Told when `running` changes, so the chat it belongs to can show it.
    var onRunning: ((Bool) -> Void)?

    fileprivate func noteActivity() {
        let now = tabs.contains { $0.url != nil }
        guard now != running else { return }
        running = now
        onRunning?(now)
    }

    /// Ends the session: every page stops and its tabs go.
    func end() {
        tabs.forEach { $0.webView.stopLoading() }
        BrowserExtensions.shared.closed(window: self)
        chromium.end()
        tabs = []
        selected = nil
        noteActivity()
    }

    var current: BrowserTab? {
        tabs.first { $0.id == selected } ?? tabs.last
    }

    /// The browser always has a tab to show.
    func ensureTab() {
        if tabs.isEmpty { newTab() }
    }

    @discardableResult
    func newTab() -> BrowserTab {
        addTab(configuration: configuration)
    }

    /// A tab on a configuration of its own: a page's popup, or an
    /// extension's own page, which needs the extension's set-up.
    @discardableResult
    func addTab(configuration: WKWebViewConfiguration) -> BrowserTab {
        let tab = BrowserTab(configuration: configuration, model: self)
        // A tab opened from a page sits right after it.
        if let index = tabs.firstIndex(where: { $0.id == selected }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        BrowserExtensions.shared.opened(tab, in: self)
        selected = tab.id
        return tab
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        tab.webView.stopLoading()
        BrowserExtensions.shared.closed(tab, in: self)
        noteActivity()
        if tabs.isEmpty {
            newTab()
        } else if selected == id {
            selected = tabs[min(index, tabs.count - 1)].id
        }
    }

    /// Shows a page: in the tab that is open if it is still blank, and in a
    /// new one otherwise, so what was being read is not replaced.
    func open(_ url: URL, newTab wantNew: Bool = true) {
        if let tab = current, tab.isBlank || !wantNew {
            tab.load(url)
        } else {
            newTab().load(url)
        }
    }

    /// An address as typed: a full one, a bare domain, or words to search for.
    static func url(from text: String) -> URL? {
        let entry = text.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty else { return nil }
        if let url = URL(string: entry), url.scheme?.hasPrefix("http") == true {
            return url
        }
        if !entry.contains(" "), entry.contains("."), let url = URL(string: "https://" + entry) {
            return url
        }
        var search = URLComponents(string: "https://duckduckgo.com/")
        search?.queryItems = [URLQueryItem(name: "q", value: entry)]
        return search?.url
    }
}
