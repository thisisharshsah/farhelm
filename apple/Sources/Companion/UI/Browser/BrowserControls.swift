import AppKit
import SwiftUI

// The browser's parts and its look, shared by the compact bar beside the
// chat, the tab sidebar of a wide browser, split view's headers and the
// menus. Every part takes its sizes, weights and colors from
// `BrowserChrome`, so none reads heavier, brighter or rounder than the one
// beside it.

/// The browser's look in one place. Its round buttons are the panel's own
/// top bar buttons (`IconButton`): the same side, symbol and highlight.
/// Color means one thing throughout: the look's color marks what is chosen
/// or on, never decoration.
enum BrowserChrome {
    /// A round button's side, and the height of what sits in a bar.
    static let button: CGFloat = 26
    /// Every bar button's symbol.
    static let symbol = Font.system(size: 11.5, weight: .semibold)
    /// The small round button inside a tab, a line or a header (close,
    /// stop, reload), and its symbol.
    static let inline: CGFloat = 18
    static let inlineSymbol = Font.system(size: 8.5, weight: .bold)
    /// A symbol that marks a line: a page with no icon of its own, a new
    /// tab, the lock of a secure address.
    static let glyph = Font.system(size: 10, weight: .semibold)
    /// A line in the sidebar.
    static let row: CGFloat = 30
    /// A tab's title and the address: one size wherever they show, heavier
    /// for the tab showing.
    static let title = Font.system(size: 12)
    static let titleChosen = Font.system(size: 12, weight: .semibold)
    static var titleColor: Color { Theme.ink.opacity(0.7) }
    static var titleChosenColor: Color { Theme.ink.opacity(0.95) }
    /// A shortcut or a note beside a line.
    static let note = Font.system(size: 10.5, weight: .medium)
    /// The corner of a line: a tab in the sidebar, a row of the command bar.
    static var rowRadius: CGFloat { Theme.controlRadius + 1 }

    /// A symbol at rest, under the pointer, and when it cannot be used.
    static var icon: Color { Theme.ink.opacity(0.68) }
    static var iconHover: Color { Theme.ink }
    static var iconOff: Color { Theme.ink.opacity(0.28) }
    /// Under the pointer: a round button (as in the top bar), a tab in the
    /// strip, a line in a list.
    static var buttonHover: Color { Theme.ink.opacity(0.18) }
    static var pillHover: Color { Theme.ink.opacity(0.09) }
    static var rowHover: Color { Theme.ink.opacity(0.07) }
    /// What is chosen: the tab showing, the row picked in the command bar,
    /// the side in use in split view, a button whose thing is on. Stronger
    /// while it is being acted on.
    static var chosen: Color { Theme.accent.opacity(0.16) }
    static var chosenStrong: Color { Theme.accent.opacity(0.24) }
}

/// A site's own icon for a tab, or a quiet stand-in until there is one.
struct SiteIcon: View {
    let icon: NSImage?
    let blank: Bool
    /// The tab that is showing; the others are a little quieter.
    let bright: Bool

    var body: some View {
        Group {
            if let icon, !blank {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .opacity(bright ? 1 : 0.8)
            } else {
                Image(systemName: blank ? "magnifyingglass" : "globe")
                    .font(BrowserChrome.glyph)
                    .foregroundStyle(Theme.ink.opacity(bright ? 0.75 : 0.5))
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// A site with no icon to show (an intranet behind a sign-in): the first
/// letter of the site's own name ("N" for ood.burst.hpc.nyu.edu), in a
/// color of its own that stays the same for that site everywhere.
struct SiteMonogram: View {
    let host: String
    let size: CGFloat

    /// The site's own name: "nyu" in ood.burst.hpc.nyu.edu, "bbc" in bbc.co.uk.
    static func name(of host: String) -> String {
        let parts = host.lowercased().split(separator: ".").filter { $0 != "www" }
        let short: Set<String> = ["co", "com", "ac", "org", "gov", "edu", "net"]
        var name = parts.count >= 2 ? parts[parts.count - 2] : (parts.first ?? "")
        if parts.count >= 3, short.contains(String(name)) { name = parts[parts.count - 3] }
        return String(name)
    }

    static func letter(of host: String) -> String {
        String(name(of: host).prefix(1)).uppercased()
    }

    /// One color per site name, so every page of one place matches.
    static func hue(of host: String) -> Color {
        let hues: [Double] = [0.72, 0.58, 0.47, 0.36, 0.08, 0.95, 0.83, 0.52]
        let seed = name(of: host).unicodeScalars.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ $1.value }
        return Color(hue: hues[Int(seed % UInt32(hues.count))], saturation: 0.55, brightness: 0.95)
    }

    var body: some View {
        let color = Self.hue(of: host)
        Text(Self.letter(of: host))
            .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(color.opacity(0.18)))
    }
}

/// A round button for the browser's bars: the panel's top bar button
/// (`IconButton`), so the two bars read as one family. `on` marks a thing
/// it turns on that is on (the whole panel, split view), in the look's
/// color as in the top bar; `.disabled` dims it.
struct BarButton: View {
    static var size: CGFloat { BrowserChrome.button }

    let symbol: String
    let help: String
    var on = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    init(_ symbol: String, help: String, on: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.on = on
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            BarFace(symbol: symbol, on: on, hover: hover, enabled: enabled)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(help)
    }
}

/// What a bar button looks like, for `BarButton` and `BarMenu` alike.
private struct BarFace: View {
    let symbol: String
    let on: Bool
    let hover: Bool
    let enabled: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(BrowserChrome.symbol)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(color)
            .frame(width: BrowserChrome.button, height: BrowserChrome.button)
            .background(Circle().fill(fill))
            .contentShape(Circle())
    }

    private var color: Color {
        if !enabled { return BrowserChrome.iconOff }
        if on { return Theme.accent }
        return hover ? BrowserChrome.iconHover : BrowserChrome.icon
    }

    /// As the top bar's: a circle under the pointer only, in the look's
    /// color when the button's thing is on.
    private var fill: Color {
        guard enabled, hover else { return .clear }
        return on ? Theme.accent.opacity(0.18) : BrowserChrome.buttonHover
    }
}

/// A bar button that opens a menu under it. It looks exactly like
/// `BarButton` (SwiftUI's own menu button draws its label its own way,
/// heavier and brighter than the buttons beside it); the menu is AppKit's.
struct BarMenu: View {
    /// One line of the menu.
    enum Item {
        case action(String, enabled: Bool = true, run: () -> Void)
        /// A line that only says something.
        case note(String)
        case separator
    }

    let symbol: String
    let help: String
    let items: () -> [Item]
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    @State private var anchor = MenuAnchor()

    init(_ symbol: String, help: String, items: @escaping () -> [Item]) {
        self.symbol = symbol
        self.help = help
        self.items = items
    }

    var body: some View {
        Button(action: open) {
            BarFace(symbol: symbol, on: false, hover: hover, enabled: enabled)
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(anchor: anchor))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(help)
    }

    private func open() { anchor.popUp(items()) }
}

/// Where a bar menu hangs from: its button's place, and what its lines call.
@MainActor
final class MenuAnchor {
    weak var view: NSView?
    fileprivate var target: MenuTarget?

    /// Opens a menu of these lines under the place held.
    func popUp(_ items: [BarMenu.Item]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let target = MenuTarget()
        for item in items {
            switch item {
            case .action(let title, let enabled, let run):
                let line = NSMenuItem(title: title, action: #selector(MenuTarget.choose(_:)), keyEquivalent: "")
                line.target = target
                line.isEnabled = enabled
                line.representedObject = MenuTarget.Choice(run)
                menu.addItem(line)
            case .note(let title):
                let line = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                line.isEnabled = false
                menu.addItem(line)
            case .separator:
                menu.addItem(.separator())
            }
        }
        // Kept with the button, so it is there whenever AppKit sends the
        // choice.
        self.target = target
        if let view = view {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

/// Runs the line chosen in a bar menu.
@MainActor
final class MenuTarget: NSObject {
    final class Choice {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    @objc func choose(_ sender: NSMenuItem) {
        (sender.representedObject as? Choice)?.run()
    }
}

/// Holds a bar menu's place, for the menu to open under it.
struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = FlippedView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }

    /// Counts down from its top, so "under the button" is its height.
    final class FlippedView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The small round button inside a tab, a line or a header: close, stop,
/// reload. One size and weight wherever it is.
struct InlineButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(BrowserChrome.inlineSymbol)
                .foregroundStyle(Theme.ink.opacity(hover ? 0.95 : 0.75))
                .frame(width: BrowserChrome.inline, height: BrowserChrome.inline)
                .background(Circle().fill(Theme.ink.opacity(hover ? 0.18 : 0.10)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(help)
    }
}

/// The speaker on a tab that is playing sound, or whose sound is off: a
/// click turns its sound off or back on. Nothing on a quiet tab.
struct SoundButton<Tab: BrowsingTab>: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if tab.audible || tab.muted {
            InlineButton(tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                         help: tab.muted ? "Turn this tab's sound back on" : "Turn this tab's sound off") {
                tab.toggleMute()
            }
        }
    }
}

/// Holds a few bar buttons together, on the same glass capsule as the
/// groups in the panel's top bar.
struct BarGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 1) { content }
            .padding(2)
            .liquidGlass(in: Capsule())
    }
}

/// Back and forward for the tab that is showing.
struct NavButtons<Tab: BrowsingTab>: View {
    @ObservedObject var tab: Tab

    var body: some View {
        BarButton("chevron.left", help: "Back (⌘[)") { tab.goBack() }
            .disabled(!tab.canGoBack)
        BarButton("chevron.right", help: "Forward (⌘])") { tab.goForward() }
            .disabled(!tab.canGoForward)
    }
}

/// A tab that is not showing: its icon and, when there is room, the page's
/// title, centered in its share of the strip. Click to switch to it; with
/// the pointer on it the cross that closes it slides in.
struct TabChip<Tab: BrowsingTab>: View {
    @ObservedObject var tab: Tab
    /// Watched for the site's icon arriving.
    @ObservedObject var history: BrowserHistory
    /// Wide enough for the title as well as the icon.
    let titled: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hover = false

    var body: some View {
        // With room for a title, the cross sits at the very start of the
        // pill and the icon and title stay in the middle. A tab that is
        // only its icon has the cross slide in just ahead of it.
        HStack(spacing: 5) {
            if hover, !titled { cross }
            Group {
                if tab.loading {
                    LoadingMark(state: .working, size: 12)
                } else {
                    SiteIcon(icon: tab.url.flatMap { history.icon(for: $0.absoluteString) }, blank: tab.isBlank,
                             bright: false)
                }
            }
            .frame(width: 16, height: 16)
            SoundButton(tab: tab)
            if titled {
                Text(tab.label)
                    .font(BrowserChrome.title)
                    .foregroundStyle(hover ? BrowserChrome.titleChosenColor : BrowserChrome.titleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        // Room kept clear on both sides for the cross, so the title never
        // runs under it and stays centered.
        .padding(.horizontal, titled ? 20 : 0)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) {
            if hover, titled { cross }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The same pill as the tab that is showing, without its color.
        .background(Capsule().fill(hover ? BrowserChrome.pillHover : .clear)
            .frame(height: BrowserChrome.button)
            .padding(.horizontal, 2))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: hover)
        .contextMenu {
            Button("Close Tab", action: close)
        }
        .help(tab.label + (tab.url.map { "\n" + $0.absoluteString } ?? ""))
    }

    private var cross: some View {
        InlineButton("xmark", help: "Close tab", action: close)
            .transition(.scale(scale: 0.4).combined(with: .opacity))
    }
}

/// The tab that is showing, in the compact bar: a pill in the look's color
/// with its site, the cross that closes it at its start and reload at its
/// end while the pointer is on it. A click opens the command bar over the
/// page to go somewhere else, or, on a new tab, puts the keys in its start
/// page.
struct AddressPill<Tab: BrowsingTab>: View {
    @ObservedObject var tab: Tab
    /// Watched for the site's icon arriving.
    @ObservedObject var history: BrowserHistory
    /// The command bar is open about this tab.
    let active: Bool
    let open: () -> Void
    let close: () -> Void
    @State private var hover = false

    private var site: String {
        guard let url = tab.url else { return "" }
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var body: some View {
        HStack(spacing: 5) {
            // The cross at the very start of the pill and reload at its very
            // end, however wide the tab is; the site stays in the middle.
            Group {
                if hover {
                    InlineButton("xmark", help: "Close tab (⌘W)", action: close)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    Color.clear
                }
            }
            .frame(width: BrowserChrome.inline, height: BrowserChrome.inline)
            HStack(spacing: 6) {
                if tab.isBlank {
                    SiteIcon(icon: nil, blank: true, bright: true)
                    // The longer words only where they fit; never "…".
                    ViewThatFits(in: .horizontal) {
                        Text("Search or enter address")
                        Text("Search")
                        Color.clear.frame(width: 0)
                    }
                    .font(BrowserChrome.title)
                    .foregroundStyle(Theme.ink.opacity(0.5))
                    .lineLimit(1)
                } else {
                    if tab.asleep {
                        Image(systemName: "moon.zzz")
                            .font(BrowserChrome.glyph)
                            .foregroundStyle(Theme.ink.opacity(0.55))
                            .frame(width: 14, height: 14)
                    } else {
                        SiteIcon(icon: tab.url.flatMap { history.icon(for: $0.absoluteString) }, blank: false,
                                 bright: true)
                    }
                    // The address reads as plain text at the start, as in
                    // Dia: the page, not the bar, has the attention.
                    Text(site)
                        .font(BrowserChrome.title)
                        .foregroundStyle(BrowserChrome.titleChosenColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SoundButton(tab: tab)
            Group {
                if tab.loading {
                    // While a page loads, the way to stop it is always there.
                    InlineButton("xmark", help: "Stop") { tab.stopLoading() }
                } else if !tab.isBlank {
                    // Reload is always there, not only under the pointer.
                    InlineButton("arrow.clockwise", help: "Reload (⌘R)") { tab.reload() }
                } else {
                    Color.clear
                }
            }
            .frame(width: BrowserChrome.inline, height: BrowserChrome.inline)
        }
        .padding(.horizontal, 4)
        .frame(height: BrowserChrome.button)
        .frame(maxWidth: .infinity)
        // The tab showing is chosen, as a picked row is anywhere else in
        // the browser: the look's color, no outline.
        .background(Capsule().fill(active || hover ? BrowserChrome.chosen : Color.clear))
        .padding(.horizontal, 2)
        // A thin line along the bottom while the page loads.
        .overlay(alignment: .bottom) {
            if tab.loading {
                Capsule()
                    .fill(Theme.accentGradient)
                    .frame(height: 1.5)
                    .padding(.horizontal, 12)
                    .transition(.opacity)
            }
        }
        .contentShape(Capsule())
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: hover)
        .contextMenu {
            if let url = tab.url {
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                Button("Open in Default Browser") { NSWorkspace.shared.open(url) }
                Button("Pin or Unpin This Page") { BrowserActions.perform(.togglePin) }
                Button("Ask About This Page") { BrowserActions.ask(about: tab) }
                Divider()
            }
            Button("Close Tab", action: close)
        }
        .help(tab.url?.absoluteString ?? "Search or enter an address (⌘L)")
    }
}

/// The address of the tab that is showing, at the top of the tab sidebar:
/// its site in full weight and the rest of the address quieter, with a lock
/// for a secure page. A click opens the command bar over the page.
struct AddressCapsule<Tab: BrowsingTab>: View {
    @ObservedObject var tab: Tab
    /// The command bar is open about this tab.
    let active: Bool
    let open: () -> Void
    @State private var hover = false

    private var symbol: String {
        if tab.isBlank { return "magnifyingglass" }
        return tab.url?.scheme == "https" ? "lock.fill" : "globe"
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(BrowserChrome.glyph)
                .foregroundStyle(Theme.ink.opacity(0.5))
                .frame(width: 14)
            address
            Spacer(minLength: 0)
            if tab.loading {
                LoadingMark(state: .working, size: 12)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: BrowserChrome.row)
        .background(Capsule().fill(active ? BrowserChrome.chosen
            : Theme.ink.opacity(hover ? 0.10 : 0.06)))
        .contentShape(Capsule())
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help((tab.url?.absoluteString ?? "Search or enter an address") + " (⌘L)")
    }

    @ViewBuilder
    private var address: some View {
        if let url = tab.url, let host = url.host {
            let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let rest = url.path == "/" ? "" : url.path
            (Text(site).font(BrowserChrome.titleChosen).foregroundStyle(BrowserChrome.titleChosenColor)
                + Text(rest).font(BrowserChrome.title).foregroundStyle(Theme.ink.opacity(0.42)))
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text(tab.isBlank ? "Search or enter address" : tab.label)
                .font(BrowserChrome.title)
                .foregroundStyle(tab.isBlank ? Theme.ink.opacity(0.5) : BrowserChrome.titleChosenColor)
                .lineLimit(1)
        }
    }
}
