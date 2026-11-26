import AppKit
import ChatDocumentPage
import SwiftUI
import WebKit

/// The look the page is drawn in, from the app's own settings.
struct ChatPageStyle: Equatable {
    var accent: String
    var ink: String
    var light: Bool
    var scale: Double
    var serif: Bool
    var top: CGFloat
    var bottom: CGFloat

    @MainActor
    static func current(top: CGFloat, bottom: CGFloat) -> ChatPageStyle {
        let settings = AppSettings.shared
        return ChatPageStyle(accent: css(Theme.accent), ink: css(Theme.ink), light: Theme.ink != .white,
                             scale: settings.chatTextScale, serif: settings.replySerif, top: top, bottom: bottom)
    }

    static func css(_ color: Color) -> String {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return "rgb(\(channel(c.redComponent)), \(channel(c.greenComponent)), \(channel(c.blueComponent)))"
    }

    var json: String {
        let values: [String: Any] = ["accent": accent, "ink": ink, "light": light, "scale": scale,
                                     "serif": serif, "top": Double(top), "bottom": Double(bottom)]
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

extension ChatThread {
    /// The conversation as one page, shown in place of the message list when
    /// Chat as one document is on. Speech heard is not in it yet: it shows
    /// typed and screen turns with their answers.
    func chatDocument(top: CGFloat, bottom: CGFloat) -> some View {
        let conversation = app.conversation.id
        let store = app.store
        let document = ChatDocument(turns: app.conversation.turns,
                                    streaming: app.streamingTurns,
                                    picture: { turn in turn.imageFile.map { store.imageURL(conversation: conversation, file: $0) } })
        return ChatDocumentPane(html: document.html, style: .current(top: top, bottom: bottom))
    }
}

/// The chat drawn in WebKit as one document. A view inside the panel, never
/// a window of its own, so it is hidden from screen sharing with the panel.
struct ChatDocumentPane: NSViewRepresentable {
    var html: String
    var style: ChatPageStyle

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing the page does is kept: no cookies, storage or cache.
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        // The page sits on the panel's glass, as the message list does.
        view.setValue(false, forKey: "drawsBackground")
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.start(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.show(html: html, style: style)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private weak var view: WKWebView?
        private var folder: URL?
        private var loaded = false
        private var wanted: (html: String, style: ChatPageStyle)?
        private var shownHTML: String?
        private var shownStyle: ChatPageStyle?

        func start(_ view: WKWebView) {
            self.view = view
            // A build without the page shows nothing rather than anything else.
            guard let folder = ChatDocumentPage.folder,
                  let store = WKContentRuleListStore.default() else { return }
            self.folder = folder
            store.compileContentRuleList(forIdentifier: "CompanionChatDocument",
                                         encodedContentRuleList: ChatPageRequest.ruleList(pageFolder: folder)) { [weak self] list, _ in
                Task { @MainActor in
                    // Without its rule list the page is not loaded at all:
                    // the navigation delegate never sees what a page asks
                    // for itself (pictures, styles, scripts).
                    guard let self, let view = self.view, let list else { return }
                    view.configuration.userContentController.add(list)
                    // Read access to the whole disk so pictures and films
                    // in the conversation show; the rule list and the page's
                    // own policy let only those and the page's files load.
                    view.loadFileURL(folder.appendingPathComponent("index.html"),
                                     allowingReadAccessTo: URL(fileURLWithPath: "/"))
                }
            }
        }

        func show(html: String, style: ChatPageStyle) {
            wanted = (html, style)
            guard loaded, let view else { return }
            if style != shownStyle {
                shownStyle = style
                view.evaluateJavaScript("ChatPage.style(\(style.json))")
            }
            if html != shownHTML, let argument = Self.jsString(html) {
                shownHTML = html
                view.evaluateJavaScript("ChatPage.render(\(argument))")
            }
        }

        /// A string as a JavaScript literal (JSON is one).
        static func jsString(_ text: String) -> String? {
            guard let data = try? JSONSerialization.data(withJSONObject: [text]),
                  let array = String(data: data, encoding: .utf8) else { return nil }
            return array + "[0]"
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let wanted { show(html: wanted.html, style: wanted.style) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, let folder else {
                decisionHandler(.cancel)
                return
            }
            // Once the page is up, anything that tries to take the frame
            // over counts as a click: it never loads inside the page.
            let clicked = navigationAction.navigationType == .linkActivated || loaded
            switch ChatPageRequest.verdict(for: url, pageFolder: folder, clicked: clicked) {
            case .load: decisionHandler(.allow)
            case .openOutside:
                // Only a person's click opens anything outside.
                if navigationAction.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            case .refuse: decisionHandler(.cancel)
            }
        }

        /// A link meant for a new window opens outside; the page never gets one.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, let folder,
               navigationAction.navigationType == .linkActivated,
               ChatPageRequest.verdict(for: url, pageFolder: folder, clicked: true) == .openOutside {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }
}