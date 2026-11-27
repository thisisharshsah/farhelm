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
    func chatDocument(top: CGFloat, bottom: CGFloat) -> some View {
        let conversation = app.conversation.id
        let store = app.store
        let document = ChatDocument(turns: app.conversation.turns,
                                    streaming: app.streamingTurns,
                                    picture: { turn in turn.imageFile.map { store.imageURL(conversation: conversation, file: $0) } })
        return ChatDocumentPane(document: document, style: .current(top: top, bottom: bottom))
    }
}

/// The chat drawn in WebKit as one document. A view inside the panel, never
/// a window of its own, so it is hidden from screen sharing with the panel.
struct ChatDocumentPane: NSViewRepresentable {
    var document: ChatDocument
    var style: ChatPageStyle

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.start(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(document: document, style: style)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private weak var view: WKWebView?
        private var folder: URL?
        var loaded = false
        private var wanted: (document: ChatDocument, style: ChatPageStyle)?
        private(set) var shownSnapshots: [TranscriptDiff.TurnSnapshot] = []
        private var shownStyle: ChatPageStyle?
        /// Every JS expression evaluated, so tests can verify one call per piece.
        private(set) var jsCalls: [String] = []

        func start(_ view: WKWebView) {
            self.view = view
            guard let folder = ChatDocumentPage.folder,
                  let store = WKContentRuleListStore.default() else { return }
            self.folder = folder
            store.compileContentRuleList(forIdentifier: "CompanionChatDocument",
                                         encodedContentRuleList: ChatPageRequest.ruleList(pageFolder: folder)) { [weak self] list, _ in
                Task { @MainActor in
                    guard let self, let view = self.view, let list else { return }
                    view.configuration.userContentController.add(list)
                    view.loadFileURL(folder.appendingPathComponent("index.html"),
                                     allowingReadAccessTo: URL(fileURLWithPath: "/"))
                }
            }
        }

        func update(document: ChatDocument, style: ChatPageStyle) {
            wanted = (document, style)
            guard loaded, let view else { return }
            if style != shownStyle {
                shownStyle = style
                let call = "ChatPage.style(\(style.json))"
                jsCalls.append(call)
                view.evaluateJavaScript(call)
            }
            let newSnapshots = document.snapshots
            let change = TranscriptDiff.diff(old: shownSnapshots, new: newSnapshots)
            func js(_ text: String) -> String {
                Coordinator.jsString(text) ?? "\"\""
            }
            switch change {
            case .unchanged:
                break
            case .update(let elementID, let innerHTML):
                let idArg = js(elementID)
                let htmlArg = js(innerHTML)
                let call = "ChatPage.updateElement(" + idArg + ", " + htmlArg + ")"
                jsCalls.append(call)
                view.evaluateJavaScript(call)
                shownSnapshots = newSnapshots
            case .append(let html):
                let call = "ChatPage.append(" + js(html) + ")"
                jsCalls.append(call)
                view.evaluateJavaScript(call)
                shownSnapshots = newSnapshots
            case .remove(let elementID):
                let call = "ChatPage.removeElement(" + js(elementID) + ")"
                jsCalls.append(call)
                view.evaluateJavaScript(call)
                shownSnapshots = newSnapshots
            case .reload(let html):
                let call = "ChatPage.render(" + js(html) + ")"
                jsCalls.append(call)
                view.evaluateJavaScript(call)
                shownSnapshots = newSnapshots
            }
        }

        static func jsString(_ text: String) -> String? {
            guard let data = try? JSONSerialization.data(withJSONObject: [text]),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            let start = json.index(after: json.startIndex)
            let end = json.index(before: json.endIndex)
            return String(json[start..<end])
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let wanted { update(document: wanted.document, style: wanted.style) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, let folder else {
                decisionHandler(.cancel)
                return
            }
            let clicked = navigationAction.navigationType == .linkActivated || loaded
            switch ChatPageRequest.verdict(for: url, pageFolder: folder, clicked: clicked) {
            case .load: decisionHandler(.allow)
            case .openOutside:
                if navigationAction.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            case .refuse: decisionHandler(.cancel)
            }
        }

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