import Foundation
import WebKit

/// A tab as Companion's browser bar sees it, whichever engine shows the
/// page, so WebKit and Chromium share one design: the same tab strip,
/// address field, buttons and new tab page.
@MainActor
protocol BrowsingTab: ObservableObject, Identifiable where ID == UUID {
    var url: URL? { get }
    var label: String { get }
    var loading: Bool { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    /// Has not gone anywhere: the new tab page shows.
    var isBlank: Bool { get }
    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    func stopLoading()
}

/// A chat's tabs as the bar sees them.
@MainActor
protocol BrowsingModel: ObservableObject {
    associatedtype Tab: BrowsingTab
    var tabs: [Tab] { get }
    var selected: UUID? { get set }
    var current: Tab? { get }
    /// Visited pages: site icons in the bar, suggestions on a new tab.
    var history: BrowserHistory { get }
    func openNewTab()
    func close(_ id: UUID)
}

extension BrowserTab: BrowsingTab {
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stopLoading() { webView.stopLoading() }
}

extension BrowserModel: BrowsingModel {
    func openNewTab() { newTab() }
}
