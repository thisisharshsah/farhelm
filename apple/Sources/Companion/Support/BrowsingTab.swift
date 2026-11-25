import AppKit
import Foundation
import WebKit

/// A tab as Companion's browser sees it, whichever engine shows the page, so
/// WebKit and Chromium share one design: the same bar, sidebar, command bar
/// and start page.
@MainActor
protocol BrowsingTab: ObservableObject, Identifiable where ID == UUID {
    var url: URL? { get }
    var label: String { get }
    var loading: Bool { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    /// Has not gone anywhere: the start page shows.
    var isBlank: Bool { get }
    /// The page's own color (its theme color, or what its top is painted
    /// in), which the browser's frame takes on. nil when it has none, or it
    /// is not known yet.
    var pageColor: NSColor? { get }
    /// Asleep to give back its memory: it holds no page until it is shown
    /// again.
    var asleep: Bool { get }
    /// Its page is making sound (known on Chromium only, for now).
    var audible: Bool { get }
    /// Its sound is turned off.
    var muted: Bool { get }
    func toggleMute()
    /// Runs a function body in the page and gives back what it returns, or
    /// nil when there is no page or it failed.
    func run(_ body: String) async -> Any?
    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    func stopLoading()
    /// The page as the chat can use it: its title, its address, what is
    /// selected on it and what it says. nil when there is no page, or it
    /// could not be read.
    func snapshot() async -> PageSnapshot?
}

/// A chat's tabs as the browser sees them.
@MainActor
protocol BrowsingModel: ObservableObject {
    associatedtype Tab: BrowsingTab
    var tabs: [Tab] { get }
    var selected: UUID? { get set }
    var current: Tab? { get }
    /// The tab shown beside the current one, in split view.
    var split: UUID? { get set }
    /// Visited pages: site icons, suggestions on the start page, and what
    /// the command bar finds.
    var history: BrowserHistory { get }
    /// Whether a closed tab can be opened again.
    var canReopen: Bool { get }
    func openNewTab()
    /// Shows a page: in a new tab, unless the tab showing is blank or
    /// `newTab` is false.
    func open(_ url: URL, newTab: Bool)
    func close(_ id: UUID)
    /// Opens the tab closed last again.
    func reopenClosed()
    /// Moves a tab to just before another one, or to the end.
    func move(_ id: UUID, before other: UUID?)
    /// Puts every tab out of sight to sleep now (those that play sound or
    /// video stay awake). Only Chromium's tabs sleep.
    func sleepOthers()
    /// Puts one tab out of sight to sleep now, unless it plays sound or
    /// video.
    func sleep(_ id: UUID)
}

extension BrowsingModel {
    func tab(_ id: UUID?) -> Tab? {
        guard let id else { return nil }
        return tabs.first { $0.id == id }
    }

    /// The tab shown beside the current one in split view, when there is one.
    var splitTab: Tab? {
        guard let split, split != current?.id else { return nil }
        return tab(split)
    }

    /// Shows a tab. In split view the tab beside the current one changes
    /// places with it; any other tab shows on its own.
    func show(_ id: UUID) {
        guard id != current?.id else { return }
        split = id == split ? current?.id : nil
        selected = id
    }

    /// Shows the tab `step` places on from the current one, round the ends.
    func selectNext(_ step: Int) {
        guard !tabs.isEmpty else { return }
        let here = tabs.firstIndex { $0.id == current?.id } ?? 0
        show(tabs[((here + step) % tabs.count + tabs.count) % tabs.count].id)
    }

    /// Shows the tab at a place in the order, from 0.
    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        show(tabs[index].id)
    }

    /// Goes to a page from a tab: in that tab, or in a new one when asked
    /// for (a blank tab is a new one already).
    func go(_ url: URL, from tab: Tab, newTab: Bool) {
        if newTab, !tab.isBlank {
            open(url, newTab: true)
        } else {
            tab.load(url)
        }
    }

    /// Shows another tab from where the person was. A start page left this
    /// way was only the way there, and closes.
    func leave(_ start: Tab, for other: Tab) {
        guard other.id != start.id else { return }
        show(other.id)
        if start.isBlank, tabs.count > 1 { close(start.id) }
    }

    /// A pinned page: the tab already on its site, else the page itself, in
    /// the tab it was asked from when that one is blank and in a new tab
    /// otherwise, so what was being read stays open.
    func openPin(_ pin: BrowserPin, from tab: Tab?) {
        guard let url = URL(string: pin.url) else { return }
        if let there = tabs.first(where: { $0.id != tab?.id && !$0.isBlank && $0.url?.host == url.host }) {
            if let tab {
                leave(tab, for: there)
            } else {
                show(there.id)
            }
        } else if let tab {
            go(url, from: tab, newTab: true)
        } else {
            open(url, newTab: true)
        }
    }
}

extension BrowserTab: BrowsingTab {
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stopLoading() { webView.stopLoading() }

    /// WebKit does not say which page makes sound, nor mute one alone.
    var audible: Bool { false }
    var muted: Bool { false }
    func toggleMute() {}

    func run(_ body: String) async -> Any? {
        guard url != nil else { return nil }
        return try? await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .defaultClient)
    }
}

extension BrowserModel: BrowsingModel {
    func openNewTab() { newTab() }
}

/// A page, as context for the chat.
struct PageSnapshot: Sendable {
    var title: String
    var url: URL
    /// What is selected on the page, if anything.
    var selection: String
    /// What the page says: the text of its article or main part, or else
    /// of the whole page.
    var text: String

    /// The attachment's name: the page's title, or its site.
    var name: String {
        let site = url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url.absoluteString
        let words = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((words.isEmpty ? site : words).prefix(60))
    }

    /// What the chat is given: where the page is, what was chosen on it,
    /// and what it says.
    var context: String {
        var lines = ["\(Self.heading)\(title.isEmpty ? url.absoluteString : title)", "Address: \(url.absoluteString)"]
        if !selection.isEmpty {
            lines += ["", "Selected on the page:", selection]
        }
        lines += ["", "What the page says:", text.isEmpty ? "(no readable text)" : text]
        return lines.joined(separator: "\n")
    }

    /// How a page's context starts, which tells it from other attachments.
    static let heading = "Web page: "

    /// The page script: a function body that returns the page as an object.
    static let script = #"""
    const pick = (selector) => document.querySelector(selector);
    const root = pick('article') || pick('main') || pick('[role="main"]') || document.body;
    const clean = (text) => String(text || '').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
    const chosen = window.getSelection ? String(window.getSelection()) : '';
    return {
      title: document.title || '',
      url: location.href,
      selection: clean(chosen).slice(0, 8000),
      text: clean(root ? root.innerText : '').slice(0, 60000)
    };
    """#

    /// A page that could not be read: its title and address alone.
    init(title: String, url: URL) {
        self.title = title
        self.url = url
        selection = ""
        text = ""
    }

    /// The page from what the script returned.
    init?(_ value: Any?) {
        guard let object = value as? [String: Any], let address = object["url"] as? String,
              let url = URL(string: address) else { return nil }
        title = object["title"] as? String ?? ""
        self.url = url
        selection = object["selection"] as? String ?? ""
        text = object["text"] as? String ?? ""
    }
}

/// A page's own color, as the browser's frame takes it on.
enum PageColor {
    /// The page script: a function body that returns the page's color, its
    /// theme color for the scheme in use or else the paint at its top, as
    /// a canvas writes colors ("#rrggbb", or "rgba(r, g, b, a)").
    static let script = #"""
    const metas = [...document.querySelectorAll('meta[name="theme-color"]')];
    const meta = metas.find((m) => !m.media || matchMedia(m.media).matches);
    const paint = (element) => {
      while (element) {
        const color = getComputedStyle(element).backgroundColor;
        if (color && color !== 'transparent' && !/rgba\(.*,\s*0\)$/.test(color)) return color;
        element = element.parentElement;
      }
      return '';
    };
    let color = meta && meta.content ? meta.content : paint(document.elementFromPoint(Math.max(1, innerWidth / 2), 3));
    if (!color) color = paint(document.body) || paint(document.documentElement);
    if (!color) return '';
    const canvas = document.createElement('canvas').getContext('2d');
    if (!canvas) return color;
    canvas.fillStyle = '#000';
    canvas.fillStyle = color;
    return canvas.fillStyle;
    """#

    /// A color as a canvas writes it, or nil for one that is not there or
    /// is mostly see-through.
    static func parse(_ text: String) -> NSColor? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") {
            let hex = String(value.dropFirst())
            guard hex.count == 6, let number = Int(hex, radix: 16) else { return nil }
            return NSColor(srgbRed: CGFloat((number >> 16) & 0xff) / 255, green: CGFloat((number >> 8) & 0xff) / 255,
                           blue: CGFloat(number & 0xff) / 255, alpha: 1)
        }
        guard value.hasPrefix("rgb"), let open = value.firstIndex(of: "("), let shut = value.lastIndex(of: ")"),
              open < shut else { return nil }
        let numbers = value[value.index(after: open)..<shut].split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count >= 3 else { return nil }
        if numbers.count > 3, numbers[3] < 0.5 { return nil }
        return NSColor(srgbRed: CGFloat(numbers[0] / 255), green: CGFloat(numbers[1] / 255),
                       blue: CGFloat(numbers[2] / 255), alpha: 1)
    }
}
