import AppKit
import SwiftUI

/// The pages going with the next message, in the chat box while the browser
/// is open beside it: the page showing (as an editor's chat takes the open
/// file), and any tabs added. A chip's cross keeps its page out; the plus
/// adds other open tabs, or all of them. Pages are read when the message is
/// sent, so each goes as it is then, with what is selected on it.
struct BrowserPageChips: View {
    @EnvironmentObject var app: AppState
    /// Chromium or WebKit (Settings > Browser).
    @AppStorage(BrowserEngine.key) private var chromium = true

    var body: some View {
        if app.sidePanel == .browser, !app.showSettings {
            let web = app.web
            if chromium && BrowserEngine.chromium {
                Chips(web: web.chromium)
            } else {
                Chips(web: web)
            }
        }
    }
}

private struct Chips<Model: BrowsingModel>: View {
    @ObservedObject var web: Model

    var body: some View {
        if let tab = web.current {
            ChipRow(web: web, current: tab)
        }
    }
}

private struct ChipRow<Model: BrowsingModel>: View {
    @ObservedObject var web: Model
    /// The tab showing, watched so its chip follows it going somewhere.
    @ObservedObject var current: Model.Tab
    @ObservedObject private var ui = BrowserUI.shared

    var body: some View {
        let pages = BrowserActions.pages(in: web)
        let going = pages.filter(BrowserActions.goes).prefix(BrowserActions.pagesPerMessage)
        let others = pages.filter { !BrowserActions.goes($0) }
        if !pages.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(going) { page in
                        if let tab = web.tab(page.id) {
                            PageChip(tab: tab, history: web.history, showing: page.showing) { remove(page) }
                        }
                    }
                    if !others.isEmpty, going.count < BrowserActions.pagesPerMessage {
                        AddPagesChip(alone: going.isEmpty) { menu(others, room: BrowserActions.pagesPerMessage - going.count) }
                    }
                }
            }
        }
    }

    private func remove(_ page: BrowserActions.OpenPage) {
        ui.chatTabs.removeAll { $0 == page.id }
        if page.showing { ui.pageDismissed = page.id }
    }

    private func add(_ page: BrowserActions.OpenPage) {
        if page.showing, ui.pageDismissed == page.id {
            ui.pageDismissed = nil
        } else if !ui.chatTabs.contains(page.id) {
            ui.chatTabs.append(page.id)
        }
    }

    private func menu(_ others: [BrowserActions.OpenPage], room: Int) -> [BarMenu.Item] {
        var items = others.map { page in
            BarMenu.Item.action(String(page.title.prefix(60))) { add(page) }
        }
        if others.count > 1 {
            items.append(.separator)
            items.append(.action(others.count <= room ? "All Open Tabs" : "The First \(room) Open Tabs") {
                others.prefix(room).forEach(add)
            })
        }
        return items
    }
}

/// One page going with the message: its site's icon, its title, and the
/// cross that keeps it out.
private struct PageChip<Tab: BrowsingTab>: View {
    @ObservedObject var tab: Tab
    /// Watched for the site's icon arriving.
    @ObservedObject var history: BrowserHistory
    let showing: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            SiteIcon(icon: tab.url.flatMap { history.icon(for: $0.absoluteString) }, blank: false, bright: true)
            Text(tab.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 170, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Text(showing ? "page" : "tab")
                .font(.system(size: 10))
                .foregroundStyle(Theme.ink.opacity(0.45))
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.ink.opacity(0.55))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Don't send this page with the message")
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Theme.ink.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.12), lineWidth: 0.5))
        .help((tab.url?.absoluteString ?? tab.label) + " goes with the message, with what is selected on it")
    }
}

/// Adds other open tabs to the message.
private struct AddPagesChip: View {
    /// No page is going yet: it says what it is for.
    let alone: Bool
    let items: () -> [BarMenu.Item]
    @State private var hover = false
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button { anchor.popUp(items()) } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 8.5, weight: .bold))
                if alone {
                    Text("Add a page")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(Theme.ink.opacity(hover ? 0.9 : 0.6))
            .padding(.horizontal, alone ? 8 : 0)
            .frame(minWidth: 22)
            .frame(height: 22)
            .background(Capsule().fill(Theme.ink.opacity(hover ? 0.12 : 0.07)))
            .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.12), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(anchor: anchor))
        .onHover { hover = $0 }
        .help("Send other open tabs with the message")
    }
}
