import AppKit
import SwiftUI

/// What a new tab shows, on the panel's own background: the command bar to
/// go anywhere, the project's pinned pages, and pages to go back to. While
/// words are in the bar, what it finds takes the room.
struct NewTabPage<Model: BrowsingModel>: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var web: Model
    @ObservedObject var tab: Model.Tab
    /// Pages the agent used in this chat, offered first.
    let chatPages: [String]
    @ObservedObject private var history: BrowserHistory
    @ObservedObject private var pins = BrowserPins.shared
    @State private var searching = false

    init(web: Model, tab: Model.Tab, chatPages: [String]) {
        self.web = web
        self.tab = tab
        self.chatPages = chatPages
        self.history = web.history
    }

    private struct Card: Identifiable {
        let id: String
        let title: String
        let host: String
        let note: String
        let fromChat: Bool
        let page: VisitedPage?
    }

    private var cards: [Card] {
        var seen = Set<String>()
        var list: [Card] = []
        for address in chatPages where seen.insert(address).inserted {
            let host = Self.host(of: address)
            let known = history.pages.first { $0.url == address }
            let title = known.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? host
            list.append(Card(id: address, title: title, host: host, note: "From this chat", fromChat: true, page: nil))
            if list.count == 4 { break }
        }
        // The same page under two addresses (a search with other tracking
        // bits, a session link) shows once: title and host together.
        var titles = Set(list.map { $0.title + "|" + $0.host })
        for page in history.suggestions(limit: 24) where seen.insert(page.url).inserted {
            let title = page.title.isEmpty ? page.host : page.title
            guard titles.insert(title + "|" + page.host).inserted else { continue }
            list.append(Card(id: page.url, title: page.title.isEmpty ? page.host : page.title,
                             host: page.host, note: Self.when(page.last), fromChat: false, page: page))
            if list.count == 12 { break }
        }
        return list
    }

    var body: some View {
        let pinned = pins.pins(for: app.conversation.projectID)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                BrowserCommandBar(web: web, tab: tab, style: .startPage, searching: $searching, close: {})
                    .frame(maxWidth: .infinity)
                if !searching {
                    if !pinned.isEmpty {
                        pinShelf(pinned)
                            .transition(.opacity)
                    }
                    suggestions
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.16), value: searching)
            .padding(.horizontal, 14)
            .padding(.top, 22)
            .padding(.bottom, 14)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The project's pinned pages, as a row of tiles.
    private func pinShelf(_ pinned: [BrowserPin]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64, maximum: 78), spacing: 6)], alignment: .center,
                  spacing: 10) {
            ForEach(pinned) { pin in
                PinTile(pin: pin, icon: history.icon(for: pin.url), size: 42) {
                    web.openPin(pin, from: tab)
                } unpin: {
                    BrowserPins.shared.unpin(pin.id, in: app.conversation.projectID)
                }
            }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            let cards = cards
            if cards.isEmpty {
                Text("Pages you visit show up here.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                    .frame(maxWidth: .infinity)
            } else {
                Text("Suggestions")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.6))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 200), spacing: 8)],
                          alignment: .leading, spacing: 8) {
                    ForEach(cards) { card in
                        SuggestionCard(title: card.title, host: card.host, note: card.note,
                                       thumbnail: history.thumbnail(for: card.id),
                                       icon: history.icon(for: card.id),
                                       tint: card.fromChat ? Theme.accent : nil) {
                            if let url = URL(string: card.id) { tab.load(url) }
                        }
                        .contextMenu {
                            if let url = URL(string: card.id) {
                                Button("Pin to This Project") {
                                    BrowserPins.shared.toggle(url, title: card.title, in: app.conversation.projectID)
                                }
                                .disabled(pins.pin(for: url, in: app.conversation.projectID) != nil)
                            }
                            if let page = card.page {
                                Button("Remove from Suggestions") { history.remove(page) }
                            }
                            Button("Clear All Visited Pages") { history.clear() }
                        }
                    }
                }
            }
        }
    }

    private static func host(of address: String) -> String {
        let host = URL(string: address)?.host ?? address
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// When a page was last open, in a word or two.
    private static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 { return "This week" }
        if days < 14 { return "Last week" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// A pinned page as a tile: the site's icon (or its initial) on glass, and
/// its name under it. Used on the start page and in the tab sidebar.
struct PinTile: View {
    let pin: BrowserPin
    let icon: NSImage?
    /// The tile's side.
    var size: CGFloat = 36
    /// Its name shows under it.
    var named = true
    /// A tab is open on its site.
    var open = false
    let action: () -> Void
    let unpin: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Group {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: size * 0.44, height: size * 0.44)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    } else {
                        SiteMonogram(host: pin.host, size: size * 0.6)
                    }
                }
                .frame(width: size, height: size)
                .frame(maxWidth: named ? nil : .infinity)
                .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous),
                             tint: hover ? Theme.accent : nil, interactive: true)
                .overlay(alignment: .bottom) {
                    // A dot under a pinned page that is open in a tab.
                    if open {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 4, height: 4)
                            .offset(y: named ? 7 : -3)
                    }
                }
                if named {
                    Text(pin.name)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink.opacity(hover ? 0.95 : 0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: size + 30)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .contextMenu {
            if let url = URL(string: pin.url) {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                Button("Open in Default Browser") { NSWorkspace.shared.open(url) }
                Divider()
            }
            Button("Unpin", action: unpin)
        }
        .help("\(pin.name)\n\(pin.url)")
    }
}

/// One suggestion: the page as it last looked (or the site's icon), its
/// name, and where it is.
private struct SuggestionCard: View {
    let title: String
    let host: String
    let note: String
    /// The page as it last looked, when there is a picture of it.
    var thumbnail: NSImage?
    /// The site's own icon, when it has been fetched.
    var icon: NSImage?
    var tint: Color?
    let action: () -> Void
    @State private var hover = false

    /// The top of the card: the page itself when there is a picture of it,
    /// and otherwise the site's icon or its initial on a tile.
    @ViewBuilder
    private var top: some View {
        if let thumbnail {
            Color.clear
                .frame(height: 64)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                .clipped()
                .padding(.bottom, 9)
        } else {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                } else {
                    SiteMonogram(host: host, size: 38)
                }
            }
            .frame(width: 38, height: 38)
            .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                .fill((tint ?? Theme.ink).opacity(icon == nil ? 0 : (tint == nil ? 0.12 : 0.30))))
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .padding(.bottom, 9)
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                top
                Group {
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.ink.opacity(0.95))
                        .lineLimit(1)
                    Text(host)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink.opacity(0.55))
                        .lineLimit(1)
                        .padding(.top, 1)
                    Text(note)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle((tint ?? Theme.ink).opacity(tint == nil ? 0.45 : 0.95))
                        .lineLimit(1)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 10)
            }
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Each place to go is a pane of glass over the panel's own
            // background, tinted with the look's color under the pointer.
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous),
                         tint: hover ? Theme.accent : nil, interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help("\(title)\n\(host)")
    }
}
