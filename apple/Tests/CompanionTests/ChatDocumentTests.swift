import XCTest
@testable import Companion

final class ChatDocumentTests: XCTestCase {
    private func turn(prompt: String = "", answer: String, origin: TurnOrigin = .typed) -> ChatTurn {
        ChatTurn(kind: .reply, origin: origin, prompt: prompt, answer: answer, model: "Local")
    }

    private var pageFolder: URL {
        URL(fileURLWithPath: "/Applications/Companion.app/Contents/Resources/Companion_ChatDocumentPage.bundle/page")
    }

    func testUserTurnHasStableIDsAndItsWords() {
        let sent = turn(prompt: "How do I list files?", answer: "Use `ls`.")
        let html = ChatDocument.html(for: sent)
        let id = ChatDocument.elementID(sent.id)
        XCTAssertTrue(html.hasPrefix("<article class=\"turn reply\" id=\"\(id)\">"))
        XCTAssertTrue(html.contains("id=\"\(id)-prompt\""))
        XCTAssertTrue(html.contains("id=\"\(id)-answer\""))
        XCTAssertTrue(html.contains("<div class=\"bubble\">How do I list files?</div>"))
        XCTAssertTrue(html.contains("<code>ls</code>"))
        // The same turn always gets the same id.
        XCTAssertEqual(ChatDocument.html(for: sent), html)
    }

    func testAnswerWithTable() {
        let html = ChatMarkdown.html("""
        | Name | Size |
        | :--- | ---: |
        | a.txt | 12 |
        | b.txt | 3 |
        """)
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<th class=\"align-left\">Name</th><th class=\"align-right\">Size</th>"))
        XCTAssertTrue(html.contains("<tr><td class=\"align-left\">a.txt</td><td class=\"align-right\">12</td></tr>"))
        XCTAssertTrue(html.contains("<td class=\"align-left\">b.txt</td>"))
    }

    func testFencedCodeBlockIsKeptAndEscaped() {
        let html = ChatMarkdown.html("""
        Run this:

        ```swift
        if a < b && c > d { print("*not emphasis*") }
        ```
        """)
        XCTAssertTrue(html.contains("<p>Run this:</p>"))
        XCTAssertTrue(html.contains("<pre class=\"code\" data-lang=\"swift\"><code>"))
        XCTAssertTrue(html.contains("if a &lt; b &amp;&amp; c &gt; d { print(&quot;*not emphasis*&quot;) }"))
        XCTAssertFalse(html.contains("<em>"))
    }

    func testListsAndLinks() {
        let html = ChatMarkdown.html("- one\n- [site](https://example.com)\n  1. nested")
        XCTAssertTrue(html.contains("<ul><li>one</li><li><a href=\"https://example.com\">site</a><ol><li>nested</li></ol></li></ul>"))
        // A script address is never a link.
        XCTAssertFalse(ChatMarkdown.html("[x](javascript:alert(1))").contains("href"))
    }

    func testLocalPictureAndFilm() {
        let picture = ChatMarkdown.html("![Chart](/Users/me/Desktop/chart.png)")
        XCTAssertTrue(picture.contains("<img src=\"file:///Users/me/Desktop/chart.png\" alt=\"Chart\">"))
        let film = ChatMarkdown.html("![Demo](/tmp/demo.mov)")
        XCTAssertTrue(film.contains("<video src=\"file:///tmp/demo.mov\""))
        // A picture on the web is not loaded: it stays a link.
        let remote = ChatMarkdown.html("![Logo](https://example.com/logo.png)")
        XCTAssertFalse(remote.contains("<img"))
        XCTAssertTrue(remote.contains("<a href=\"https://example.com/logo.png\">Logo</a>"))
    }

    func testScreenCaptureIsShownFromItsFile() {
        var capture = ChatTurn(kind: .screen, origin: .manual, prompt: "", answer: "A dialog.", model: "Local")
        capture.imageFile = "shot.png"
        let html = ChatDocument.html(for: capture, picture: URL(fileURLWithPath: "/tmp/conv/shot.png"))
        XCTAssertTrue(html.contains("<img src=\"file:///tmp/conv/shot.png\" alt=\"Screen capture\">"))
    }

    func testRawScriptInATurnComesOutEscaped() {
        let hostile = "<script>alert('x')</script> <img src=x onerror=alert(1)>"
        let html = ChatDocument.html(for: turn(prompt: hostile, answer: hostile))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("<img src=x"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
    }

    func testChatAsDocumentIsOffAndScreenSharingHiddenByDefault() throws {
        let name = "ChatDocumentTests-\(UUID().uuidString)"
        let empty = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { empty.removePersistentDomain(forName: name) }
        XCTAssertFalse(AppSettings.flag("chatAsDocument", in: empty))
        XCTAssertTrue(AppSettings.flag("hideFromScreenShare", in: empty))
        empty.set(true, forKey: "chatAsDocument")
        XCTAssertTrue(AppSettings.flag("chatAsDocument", in: empty))
    }

    func testRequestRuleAllowsOnlyThePageAndLocalMedia() {
        let folder = pageFolder
        XCTAssertTrue(ChatPageRequest.allows(folder.appendingPathComponent("index.html"), pageFolder: folder))
        XCTAssertTrue(ChatPageRequest.allows(folder.appendingPathComponent("chat.css"), pageFolder: folder))
        XCTAssertTrue(ChatPageRequest.allows(URL(fileURLWithPath: "/Users/me/shot.png"), pageFolder: folder))
        XCTAssertTrue(ChatPageRequest.allows(URL(fileURLWithPath: "/tmp/demo.mp4"), pageFolder: folder))
        XCTAssertTrue(ChatPageRequest.allows(URL(string: "about:blank")!, pageFolder: folder))

        for address in ["http://example.com/a.png", "https://example.com/", "ws://127.0.0.1:7842/", "wss://example.com/",
                        "ftp://example.com/x", "data:text/html,hi", "javascript:alert(1)", "blob:x"] {
            let url = URL(string: address)!
            XCTAssertFalse(ChatPageRequest.allows(url, pageFolder: folder), address)
            XCTAssertNotEqual(ChatPageRequest.verdict(for: url, pageFolder: folder, clicked: false), .load, address)
        }
        // Other local files, or a path climbing out of the page's folder.
        XCTAssertFalse(ChatPageRequest.allows(URL(fileURLWithPath: "/etc/passwd"), pageFolder: folder))
        XCTAssertFalse(ChatPageRequest.allows(folder.appendingPathComponent("../../../../evil.html"), pageFolder: folder))
    }

    func testClickedLinksOpenOutsideThePage() {
        let folder = pageFolder
        XCTAssertEqual(ChatPageRequest.verdict(for: URL(string: "https://example.com")!, pageFolder: folder, clicked: true), .openOutside)
        XCTAssertEqual(ChatPageRequest.verdict(for: URL(fileURLWithPath: "/tmp/a.png"), pageFolder: folder, clicked: true), .openOutside)
        XCTAssertEqual(ChatPageRequest.verdict(for: URL(fileURLWithPath: "/tmp/run.command"), pageFolder: folder, clicked: true), .refuse)
        XCTAssertEqual(ChatPageRequest.verdict(for: URL(string: "javascript:alert(1)")!, pageFolder: folder, clicked: true), .refuse)
    }

    func testRuleListIsValidJSONThatBlocksFirst() throws {
        let text = ChatPageRequest.ruleList(pageFolder: pageFolder)
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        let first = try XCTUnwrap(rules.first?["action"] as? [String: String])
        XCTAssertEqual(first["type"], "block")
    }

    func testBundledCSSHasNoShadows() throws {
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let css = try String(contentsOf: apple.appendingPathComponent("Resources/ChatDocument/page/chat.css"), encoding: .utf8)
        for shadow in ["box-shadow", "drop-shadow", "text-shadow"] {
            XCTAssertFalse(css.lowercased().contains(shadow), shadow)
        }
    }
}