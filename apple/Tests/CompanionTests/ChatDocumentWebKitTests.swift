import AppKit
import ChatDocumentPage
import WebKit
import XCTest
@testable import Companion

final class ChatDocumentWebKitTests: XCTestCase {
    @MainActor
    func testBundledTranscriptRendersInWebKit() async throws {
        _ = NSApplication.shared
        let folder = try XCTUnwrap(ChatDocumentPage.folder, "The bundled transcript page could not be found.")
        let ruleStore = try XCTUnwrap(WKContentRuleListStore.default())
        let ruleError: String? = await withCheckedContinuation { continuation in
            ruleStore.compileContentRuleList(
                forIdentifier: "CompanionChatDocument",
                encodedContentRuleList: ChatPageRequest.ruleList(pageFolder: folder)
            ) { list, error in
                continuation.resume(returning: list == nil
                    ? error.map { String(describing: $0) } ?? "WebKit returned no rule list."
                    : nil)
            }
        }
        if let ruleError {
            XCTFail("WebKit could not compile the transcript request rules. \(ruleError)")
            return
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480),
            configuration: configuration
        )
        let coordinator = ChatDocumentPane.Coordinator()
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator

        let turn = ChatTurn(kind: .reply, origin: .typed, prompt: "Show an example", answer: """
        | Name | Size |
        | :--- | ---: |
        | a.txt | 12 |

        ```swift
        print("hello")
        ```

        <script>window.transcriptProbe = true</script>
        """, model: "Local")
        coordinator.start(view)
        coordinator.show(
            html: ChatDocument.html(for: turn),
            style: ChatPageStyle(accent: "purple", ink: "black", light: true,
                                 scale: 1, serif: false, top: 0, bottom: 0)
        )

        let probe = """
        (() => {
            const turn = document.getElementById('\(ChatDocument.elementID(turn.id))');
            return window.location.protocol === 'file:'
                && document.querySelector('link[rel="stylesheet"]')?.sheet != null
                && turn?.querySelector('.bubble')?.textContent === 'Show an example'
                && turn?.querySelector('table td')?.textContent === 'a.txt'
                && turn?.querySelector('pre code')?.textContent.includes('print("hello")')
                && turn.textContent.includes('<script>window.transcriptProbe = true</script>')
                && !turn.querySelector('script')
                && window.transcriptProbe === undefined;
        })()
        """

        // WebKit compiles the content rules and loads the page asynchronously.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var lastProbe = "No result"
        while ContinuousClock.now < deadline {
            let result: (rendered: Bool, detail: String) = await withCheckedContinuation { continuation in
                view.evaluateJavaScript(probe) { result, error in
                    continuation.resume(returning: (
                        result as? Bool == true,
                        error.map { String(describing: $0) } ?? String(describing: result)
                    ))
                }
            }
            if result.rendered { return }
            lastProbe = result.detail
            try await Task.sleep(for: .milliseconds(100))
        }

        let pageState: String = await withCheckedContinuation { continuation in
            view.evaluateJavaScript("""
            JSON.stringify({
                url: document.URL,
                script: typeof window.ChatPage,
                stylesheets: document.styleSheets.length,
                transcript: document.getElementById('chat')?.innerHTML
            })
            """) { result, error in
                continuation.resume(returning: result as? String ?? error?.localizedDescription ?? "No page state")
            }
        }
        XCTFail("Transcript did not render. Probe: \(lastProbe). Page: \(pageState)")
    }
}