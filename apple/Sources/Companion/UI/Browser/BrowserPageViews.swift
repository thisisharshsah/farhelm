import AppKit
import SwiftUI
import WebKit

// What sits in the browser's page area beside the page itself: the WebKit
// tab's page, iCloud Passwords' bar over a sign-in, and the extensions'
// buttons and the Web Store's bar.

/// A WebKit tab's content: the page or, before it has gone anywhere, the
/// start page.
struct BrowserTabView: View {
    @EnvironmentObject var app: AppState
    /// Watched so pages follow the content zoom as it changes.
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var tab: BrowserTab
    @ObservedObject var web: BrowserModel
    /// The height of the bar floating over the top of the content.
    var topInset: CGFloat = 0

    var body: some View {
        if tab.isBlank {
            // No page yet: the panel's own background shows through, with
            // places to go on top of it.
            NewTabPage(web: web, tab: tab, chatPages: chatPages)
                .padding(.top, topInset)
        } else if #available(macOS 26.0, *) {
            // The page fills the pane and knows its top is covered, so it
            // starts below the bar and scrolls up underneath it.
            WebView(webView: tab.webView, zoom: AppSettings.shared.contentZoom, topInset: topInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            WebView(webView: tab.webView, zoom: AppSettings.shared.contentZoom)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, topInset)
        }
    }

    /// Pages the agent used in this chat, offered first on a new tab.
    private var chatPages: [String] {
        app.sessionWeb.filter { URL(string: $0)?.scheme?.hasPrefix("http") == true }
    }
}

/// Hosts a tab's web view.
private struct WebView: NSViewRepresentable {
    let webView: WKWebView
    /// The content zoom, which pages follow.
    var zoom: Double = 1
    /// How much of the top of the page a floating bar covers.
    var topInset: CGFloat = 0

    func makeNSView(context: Context) -> WKWebView {
        webView.pageZoom = zoom
        cover(webView)
        return webView
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if abs(view.pageZoom - zoom) > 0.001 { view.pageZoom = zoom }
        cover(view)
    }

    private func cover(_ view: WKWebView) {
        if #available(macOS 26.0, *), abs(view.obscuredContentInsets.top - topInset) > 0.5 {
            view.obscuredContentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        }
    }
}

/// iCloud Passwords over a page with a password form: saved logins to fill,
/// a strong password for a sign-up, and "Save" after signing in or up.
struct PasswordBar: View {
    /// The page it works on: a WebKit tab's web view, or a Chromium tab.
    let page: any PasswordPage
    @ObservedObject private var passwords = ICloudPasswords.shared
    @State private var code = ""

    private var form: (host: String, kind: ICloudPasswords.FormKind)? {
        passwords.forms[page.passwordID]
    }

    var body: some View {
        Group {
            if let offer = passwords.offer, offer.webView == page.passwordID {
                row(icon: "key.fill", tint: Theme.mint) {
                    Text(offer.update ? "Update the password for \(offer.username) in iCloud Passwords?"
                                      : "Save \(offer.username.isEmpty ? "this login" : offer.username) to iCloud Passwords?")
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    button(offer.update ? "Update" : "Save", prominent: true) { passwords.saveOffer() }
                    button("Not now") { passwords.dismissOffer() }
                }
            } else if let form {
                row(icon: "key.fill", tint: Theme.accent) { content(form) }
            }
        }
        .animation(.easeOut(duration: 0.15), value: form?.host)
    }

    @ViewBuilder
    private func content(_ form: (host: String, kind: ICloudPasswords.FormKind)) -> some View {
        switch passwords.state {
        case .ready:
            let found = passwords.logins[form.host] ?? []
            if found.isEmpty {
                Text(form.kind == .new ? "iCloud Passwords will offer to save this sign-up." : "No saved login for \(form.host).")
                    .lineLimit(1)
            } else {
                Text("iCloud Passwords")
                Menu {
                    ForEach(found) { login in
                        Button(login.username.isEmpty ? "(no username)" : login.username) {
                            passwords.fill(login, host: form.host, page: page)
                        }
                    }
                } label: {
                    Text(found.count == 1 ? "Fill \(found[0].username)" : "Fill a login (\(found.count))")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Spacer(minLength: 6)
            if form.kind == .new {
                button("Strong password") { passwords.suggestPassword(page: page) }
            }
        case .awaitingCode:
            Text("Code from macOS")
            TextField("", text: $code, prompt: Text("123456").foregroundStyle(Theme.ink.opacity(0.42)))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 70)
                .onSubmit { passwords.submit(code: code); code = "" }
            button("Pair", prominent: true) { passwords.submit(code: code); code = "" }
            Spacer(minLength: 6)
        case .notInstalled:
            Text("Use your iCloud Passwords here?")
            Spacer(minLength: 6)
            button("Set up", prominent: true) { passwords.install() }
        case .installing, .starting:
            LoadingMark(state: .working, size: 13)
            Text(passwords.detail).lineLimit(1)
            Spacer(minLength: 6)
        case .needsPairing:
            Text(passwords.detail.isEmpty ? "Pair with iCloud Passwords to fill logins." : passwords.detail)
                .lineLimit(1)
            Spacer(minLength: 6)
            button("Pair", prominent: true) { passwords.startPairing() }
        case .failed(let why):
            Text(why).lineLimit(2)
            Spacer(minLength: 6)
            if passwords.missingBrowser {
                button("Install Chrome", prominent: true) { passwords.installBrowser() }
            } else {
                button("Try again") { passwords.installed ? passwords.startPairing() : passwords.install() }
            }
        }
    }

    private func row<Content: View>(icon: String, tint: Color, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            content()
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.ink.opacity(0.85))
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .background(tint.opacity(0.1))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func button(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? Theme.accent : Theme.ink.opacity(0.7))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill((prominent ? Theme.accent : Theme.ink).opacity(prominent ? 0.16 : 0.07)))
    }
}

// MARK: - Extensions

/// The extensions' buttons, as in Chrome: the pinned ones side by side, and
/// the rest behind the puzzle piece. Bare buttons, for whatever group of
/// the bar or sidebar holds them.
struct ExtensionStrip: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var web: BrowserModel
    @ObservedObject private var extensions = BrowserExtensions.shared

    var body: some View {
        let actions = extensions.toolbar(tab: web.current, in: web)
        ForEach(actions.filter(\.pinned)) { action in
            ExtensionButton(action: action) {
                extensions.perform(action.id, tab: web.current, in: web)
            }
        }
        BarMenu("puzzlepiece", help: "Extensions") { menu(actions) }
            .background(ExtensionAnchor(id: "menu"))
    }

    private func menu(_ actions: [BrowserExtensions.ToolbarAction]) -> [BarMenu.Item] {
        var items: [BarMenu.Item] = []
        if actions.isEmpty {
            items.append(.note("No extensions yet"))
        }
        for action in actions {
            items.append(.action(action.label, enabled: action.enabled) {
                extensions.perform(action.id, tab: web.current, in: web)
            })
        }
        let configurable = actions.filter(\.hasOptions)
        if !configurable.isEmpty {
            items.append(.separator)
            for action in configurable {
                items.append(.action("Options for \(action.label)") { extensions.openOptions(action.id, in: web) })
            }
        }
        items.append(.separator)
        items.append(.action("Chrome Web Store") {
            if let url = URL(string: "https://chromewebstore.google.com") { web.open(url) }
        })
        items.append(.action("Manage Extensions…") { app.openSettings(tab: "Browser") })
        return items
    }
}

/// One extension's button: its icon, with its badge.
private struct ExtensionButton: View {
    let action: BrowserExtensions.ToolbarAction
    let run: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: run) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let icon = action.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "puzzlepiece")
                            .font(BrowserChrome.symbol)
                            .foregroundStyle(hover ? BrowserChrome.iconHover : BrowserChrome.icon)
                    }
                }
                .frame(width: BrowserChrome.button, height: BrowserChrome.button)
                .background(Circle().fill(hover ? BrowserChrome.buttonHover : .clear))
                if !action.badge.isEmpty {
                    Text(action.badge.prefix(4))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 12, minHeight: 11)
                        .background(Capsule().fill(Theme.rose))
                        .offset(x: 1, y: 1)
                }
            }
            .contentShape(Circle())
            .opacity(action.enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .background(ExtensionAnchor(id: action.id))
        .help(action.label)
    }
}

/// Lets an extension's popup hang from its button.
private struct ExtensionAnchor: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Task { @MainActor in BrowserExtensions.shared.setAnchor(view, for: id) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        BrowserExtensions.shared.setAnchor(view, for: id)
    }
}

/// On a Chrome Web Store page: add the extension to Companion's browser,
/// since the store's own button only works in Chrome.
struct StoreBar: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject private var extensions = BrowserExtensions.shared

    private var storeID: String? {
        guard BrowserExtensions.supported, let url = tab.url, url.host == "chromewebstore.google.com",
              url.path.contains("/detail/") else { return nil }
        return BrowserExtensions.storeID(in: url.lastPathComponent)
    }

    /// The store's own button adds to Companion on this page; the bar
    /// only shows progress then.
    private var hooked: Bool { extensions.storeHooked.contains(ObjectIdentifier(tab.webView)) }

    var body: some View {
        if let id = storeID, extensions.busy != nil || !hooked {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                if let busy = extensions.busy {
                    LoadingMark(state: .working, size: 13)
                    Text(busy).lineLimit(1)
                } else if extensions.isInstalled(id) {
                    Text("This extension is in Companion's browser.").lineLimit(1)
                } else {
                    Text("Add this extension to Companion's browser?").lineLimit(1)
                }
                Spacer(minLength: 6)
                if extensions.busy == nil {
                    Button(extensions.isInstalled(id) ? "Update" : "Add to Companion") { extensions.addFromStore(id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(Theme.accent.opacity(0.16)))
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.ink.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(Theme.accent.opacity(0.1))
        }
    }
}
