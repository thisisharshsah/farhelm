import CEFKit
import Foundation
import WebKit

/// The agent's browser steps in Companion's own browser, beside the chat:
/// the same commands as in Chrome (open, read, click, type, scroll, back,
/// key, tabs, focus) and the same results, so the agent works a page side
/// by side with the user, who sees every step. Sign-ins are the user's,
/// with iCloud Passwords in the bar over the page; password fields are
/// refused, as in Chrome.
@MainActor
enum InAppBrowser {
    static func run(_ command: String, _ args: [String: Any], app: AppState, chat: UUID? = nil) async -> [String: Any] {
        // On Chromium the page steps run in its tabs; the rest (history,
        // extensions, downloads) are shared.
        if BrowserEngine.chromium, let answer = await chromiumStep(command, args, app: app, chat: chat) {
            return answer
        }
        let web = app.web(for: chat ?? app.conversation.id)
        do {
            switch command {
            case "open":
                guard let text = args["url"] as? String, let url = BrowserModel.url(from: text) else {
                    return ["ok": false, "error": "That is not an address."]
                }
                app.showSide(.browser, for: chat)
                web.ensureTab()
                if (args["newTab"] as? Bool) == true {
                    web.newTab().load(url)
                } else {
                    web.open(url, newTab: false)
                }
                await loaded(web)
                return describe(web)
            case "tabs":
                let tabs = web.tabs.enumerated().map { index, tab -> [String: Any] in
                    ["tab": index + 1, "title": tab.label, "url": tab.url?.absoluteString ?? "", "active": tab.id == web.current?.id]
                }
                return ["ok": true, "tabs": tabs]
            case "focus":
                let index = (args["tab"] as? Int ?? 1) - 1
                guard web.tabs.indices.contains(index) else { return ["ok": false, "error": "There is no tab \(index + 1)."] }
                web.selected = web.tabs[index].id
                app.showSide(.browser, for: chat)
                return describe(web)
            case "read":
                guard let tab = web.current else { return ["ok": false, "error": "No page is open; open one first."] }
                let result = try await tab.webView.callAsyncJavaScript(script + "return snapshot();", arguments: [:],
                                                                         in: nil, contentWorld: .defaultClient)
                var answer = result as? [String: Any] ?? [:]
                answer["ok"] = true
                return answer
            case "click":
                guard let tab = web.current else { return ["ok": false, "error": "No page is open."] }
                let before = web.downloads.saved.count
                let label = try await tab.webView.callAsyncJavaScript(script + "return clickElement(id);",
                                                                        arguments: ["id": "\(args["target"] ?? "")"],
                                                                        in: nil, contentWorld: .defaultClient)
                try? await Task.sleep(nanoseconds: 700_000_000)
                await loaded(web, timeout: 8)
                var answer = describe(web)
                answer["clicked"] = label as? String ?? ""
                // A click that saves a file: where it went.
                let saved = await newDownloads(web, since: before)
                if !saved.isEmpty { answer["downloaded"] = saved }
                return answer
            case "upload":
                // Files from this Mac for one of the page's file fields: chosen
                // here, then the field is clicked and takes them.
                guard let tab = web.current else { return ["ok": false, "error": "No page is open."] }
                let paths = (args["paths"] as? [Any])?.compactMap { $0 as? String } ?? []
                let files = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                let missing = files.filter { !FileManager.default.fileExists(atPath: $0.path) }
                guard !files.isEmpty, missing.isEmpty else {
                    return ["ok": false, "error": missing.isEmpty ? "No files were named." : "Not found: \(missing.map(\.path).joined(separator: ", "))"]
                }
                web.prepareUploads(files)
                _ = try await tab.webView.callAsyncJavaScript(script + "return clickElement(id);",
                                                              arguments: ["id": "\(args["target"] ?? "")"],
                                                              in: nil, contentWorld: .defaultClient)
                try? await Task.sleep(nanoseconds: 600_000_000)
                var answer = describe(web)
                answer["uploaded"] = files.map(\.lastPathComponent)
                return answer
            case "downloads":
                let list = web.downloads.saved.prefix(20).map { item -> [String: Any] in
                    ["name": item.name, "path": item.path, "failed": item.failed,
                     "when": item.date.formatted(date: .omitted, time: .shortened)]
                }
                return ["ok": true, "downloads": Array(list)]
            case "extensions":
                // The Chrome extensions in Companion's browser.
                return ["ok": true, "supported": BrowserExtensions.supported,
                        "extensions": BrowserExtensions.shared.summary()]
            case "add_extension":
                // The user is shown what it may do and agrees, or not.
                let outcome = await BrowserExtensions.shared.installFromStore(args["url"] as? String ?? "")
                return ["ok": outcome.ok, outcome.ok ? "added" : "error": outcome.message]
            case "history":
                // Companion's own browser history: pages opened here before.
                let words = (args["query"] as? String ?? "").lowercased().split(separator: " ").map(String.init)
                let pages = web.history.pages.filter { page in
                    words.allSatisfy { page.url.lowercased().contains($0) || page.title.lowercased().contains($0) }
                }.prefix(15).map { ["title": $0.title, "url": $0.url, "visits": $0.visits] as [String: Any] }
                return ["ok": true, "pages": Array(pages)]
            case "type":
                guard let tab = web.current else { return ["ok": false, "error": "No page is open."] }
                let submit = (args["submit"] as? Bool) == true
                let outcome = try await tab.webView.callAsyncJavaScript(script + "return typeInto(id, text, submit);",
                                                                          arguments: ["id": "\(args["target"] ?? "")",
                                                                                      "text": args["text"] as? String ?? "",
                                                                                      "submit": submit],
                                                                          in: nil, contentWorld: .defaultClient) as? [String: Any]
                if let error = outcome?["error"] as? String { return ["ok": false, "error": error] }
                if submit {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    await loaded(web, timeout: 8)
                }
                var answer = describe(web)
                answer["typed"] = outcome?["field"] as? String ?? "the field"
                return answer
            case "scroll":
                guard let tab = web.current else { return ["ok": false, "error": "No page is open."] }
                _ = try await tab.webView.callAsyncJavaScript("window.scrollBy(0, (down ? 1 : -1) * window.innerHeight * 0.8);",
                                                              arguments: ["down": args["direction"] as? String != "up"],
                                                              in: nil, contentWorld: .defaultClient)
                return describe(web)
            case "back":
                guard let tab = web.current, tab.webView.canGoBack else { return ["ok": false, "error": "There is no page to go back to."] }
                tab.webView.goBack()
                await loaded(web, timeout: 8)
                return describe(web)
            case "key":
                guard let tab = web.current else { return ["ok": false, "error": "No page is open."] }
                _ = try await tab.webView.callAsyncJavaScript(script + "pressKey(key); return true;",
                                                              arguments: ["key": args["key"] as? String ?? "Enter"],
                                                              in: nil, contentWorld: .defaultClient)
                return describe(web)
            default:
                return ["ok": false, "error": "Unknown browser command \(command)."]
            }
        } catch {
            // A message thrown in the page ("Element 12 is not on the page any more").
            let text = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            return ["ok": false, "error": text]
        }
    }

    /// Downloads finished since a count, waiting a moment for one to start.
    private static func newDownloads(_ web: BrowserModel, since count: Int) async -> [String] {
        for _ in 0..<10 where web.downloads.saved.count == count {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return web.downloads.saved.prefix(max(0, web.downloads.saved.count - count)).map { $0.path }
    }

    private static func describe(_ web: BrowserModel) -> [String: Any] {
        ["ok": true, "title": web.current?.label ?? "", "url": web.current?.url?.absoluteString ?? ""]
    }

    /// Waits for the page showing to finish loading.
    private static func loaded(_ web: BrowserModel, timeout: Double = 20) async {
        let end = Date().addingTimeInterval(timeout)
        try? await Task.sleep(nanoseconds: 300_000_000)
        while Date() < end, web.current?.loading == true {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// The page side: numbered elements, clicking and typing by number.
    /// Password fields are never typed into.
    private static let script = #"""
    function snapshot() {
      document.querySelectorAll("[data-companion-id]").forEach((e) => e.removeAttribute("data-companion-id"));
      const selector = "a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[role=option],[contenteditable=true]";
      const elements = [];
      let n = 0;
      for (const el of document.querySelectorAll(selector)) {
        const box = el.getBoundingClientRect();
        if (box.width === 0 && box.height === 0) continue;
        const style = getComputedStyle(el);
        if (style.visibility === "hidden" || style.display === "none") continue;
        if (el.type === "hidden") continue;
        n += 1;
        el.setAttribute("data-companion-id", String(n));
        const secret = el.type === "password";
        const label = (el.getAttribute("aria-label") || el.innerText || (secret ? "" : el.value) || el.placeholder || el.title || el.name || "")
          .trim().replace(/\s+/g, " ").slice(0, 80);
        elements.push({ i: n, tag: el.tagName.toLowerCase(), type: el.type || el.getAttribute("role") || "", label,
                        href: el.href ? String(el.href).slice(0, 140) : "" });
        if (n >= 300) break;
      }
      const text = (document.body ? document.body.innerText : "").replace(/\n{3,}/g, "\n\n").slice(0, 15000);
      return { title: document.title, url: location.href, text, elements };
    }
    function clickElement(id) {
      const el = document.querySelector('[data-companion-id="' + id + '"]');
      if (!el) throw new Error("Element " + id + " is not on the page any more; read the page again.");
      el.scrollIntoView({ block: "center" });
      el.click();
      return (el.getAttribute("aria-label") || el.innerText || el.value || el.tagName).trim().slice(0, 80);
    }
    function typeInto(id, text, submit) {
      const el = document.querySelector('[data-companion-id="' + id + '"]');
      if (!el) return { error: "Element " + id + " is not on the page any more; read the page again." };
      if (el.type === "password" || /pass(word|code)|one-time-code/i.test(el.autocomplete || "")) {
        return { error: "That is a password field. Passwords are filled by the user with iCloud Passwords (the bar over the page), never typed by the agent: ask the user to sign in, then carry on." };
      }
      el.scrollIntoView({ block: "center" });
      el.focus();
      if (el.isContentEditable) {
        el.textContent = text;
      } else {
        const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype
          : (el.tagName === "SELECT" ? HTMLSelectElement.prototype : HTMLInputElement.prototype);
        Object.getOwnPropertyDescriptor(proto, "value").set.call(el, text);
      }
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
      if (submit) {
        if (el.form && el.form.requestSubmit) el.form.requestSubmit();
        else el.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
      }
      return { field: (el.getAttribute("aria-label") || el.placeholder || el.name || el.tagName).slice(0, 60) };
    }
    function pressKey(key) {
      const target = document.activeElement || document.body;
      for (const type of ["keydown", "keyup"]) target.dispatchEvent(new KeyboardEvent(type, { key, bubbles: true }));
      if (key === "Enter" && target.form && target.form.requestSubmit) target.form.requestSubmit();
    }

    """#
}

// MARK: - The same steps in Chromium

extension InAppBrowser {
    /// A page step in the chat's Chromium tabs, through DevTools' Runtime
    /// (the same page script as in WebKit). nil for steps that are not
    /// about the page, which run as before.
    static func chromiumStep(_ command: String, _ args: [String: Any], app: AppState, chat: UUID? = nil) async -> [String: Any]? {
        let tabs = app.web(for: chat ?? app.conversation.id).chromium
        func page() -> ChromiumTab? { tabs.current }
        do {
            switch command {
            case "open":
                guard let text = args["url"] as? String, let url = BrowserModel.url(from: text) else {
                    return ["ok": false, "error": "That is not an address."]
                }
                app.showSide(.browser, for: chat)
                guard await BrowserEngine.ready() else {
                    return ["ok": false, "error": Chromium.lastError]
                }
                if tabs.tabs.isEmpty || (args["newTab"] as? Bool) == true {
                    guard tabs.newTab(url.absoluteString) != nil else {
                        return ["ok": false, "error": tabs.problem ?? "Chromium did not start."]
                    }
                } else {
                    tabs.open(url, newTab: false)
                }
                await settle(tabs)
                return describe(tabs)
            case "tabs":
                let list = tabs.tabs.enumerated().map { index, tab -> [String: Any] in
                    ["tab": index + 1, "title": tab.label, "url": tab.address, "active": tab.id == tabs.current?.id]
                }
                return ["ok": true, "tabs": list]
            case "focus":
                let index = (args["tab"] as? Int ?? 1) - 1
                guard tabs.tabs.indices.contains(index) else { return ["ok": false, "error": "There is no tab \(index + 1)."] }
                tabs.selected = tabs.tabs[index].id
                app.showSide(.browser, for: chat)
                return describe(tabs)
            case "read":
                guard let tab = page() else { return ["ok": false, "error": "No page is open; open one first."] }
                var answer = try await evaluate(tab, call: "snapshot()") as? [String: Any] ?? [:]
                answer["ok"] = true
                return answer
            case "click":
                guard let tab = page() else { return ["ok": false, "error": "No page is open."] }
                let label = try await evaluate(tab, call: "clickElement(\(literal("\(args["target"] ?? "")")))")
                try? await Task.sleep(nanoseconds: 700_000_000)
                await settle(tabs, timeout: 8)
                var answer = describe(tabs)
                answer["clicked"] = label as? String ?? ""
                return answer
            case "type":
                guard let tab = page() else { return ["ok": false, "error": "No page is open."] }
                let submit = (args["submit"] as? Bool) == true
                let call = "typeInto(\(literal("\(args["target"] ?? "")")), \(literal(args["text"] as? String ?? "")), \(submit))"
                let outcome = try await evaluate(tab, call: call) as? [String: Any]
                if let error = outcome?["error"] as? String { return ["ok": false, "error": error] }
                if submit {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    await settle(tabs, timeout: 8)
                }
                var answer = describe(tabs)
                answer["typed"] = outcome?["field"] as? String ?? "the field"
                return answer
            case "scroll":
                guard let tab = page() else { return ["ok": false, "error": "No page is open."] }
                let down = args["direction"] as? String != "up"
                _ = try await evaluate(tab, expression: "window.scrollBy(0, \(down ? 1 : -1) * window.innerHeight * 0.8)")
                return describe(tabs)
            case "back":
                guard let tab = page(), tab.canGoBack else { return ["ok": false, "error": "There is no page to go back to."] }
                tab.browser.goBack()
                await settle(tabs, timeout: 8)
                return describe(tabs)
            case "key":
                guard let tab = page() else { return ["ok": false, "error": "No page is open."] }
                _ = try await evaluate(tab, call: "(pressKey(\(literal(args["key"] as? String ?? "Enter"))), true)")
                return describe(tabs)
            case "upload":
                return ["ok": false, "error": "Choosing files for a page is not in the Chromium browser yet: ask the user to choose them in the page's file field, or turn Chromium off in Settings > Browser."]
            default:
                return nil
            }
        } catch {
            return ["ok": false, "error": (error as? PageError)?.text ?? error.localizedDescription]
        }
    }

    struct PageError: Error { let text: String }

    private static func describe(_ tabs: ChromiumTabs) -> [String: Any] {
        ["ok": true, "title": tabs.current?.label ?? "", "url": tabs.current?.address ?? ""]
    }

    private static func settle(_ tabs: ChromiumTabs, timeout: Double = 20) async {
        let end = Date().addingTimeInterval(timeout)
        try? await Task.sleep(nanoseconds: 400_000_000)
        while Date() < end, tabs.current?.loading == true {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// A value written as JavaScript.
    private static func literal(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Calls one of the page script's functions and returns its value.
    private static func evaluate(_ tab: ChromiumTab, call: String) async throws -> Any? {
        try await evaluate(tab, expression: "(async () => {\n\(script)\nreturn \(call);\n})()")
    }

    private static func evaluate(_ tab: ChromiumTab, expression: String) async throws -> Any? {
        let json: String = try await withCheckedThrowingContinuation { done in
            tab.browser.evaluate(expression) { json, error in
                if let json { done.resume(returning: json) } else { done.resume(throwing: PageError(text: error ?? "The page did not run that.")) }
            }
        }
        guard let reply = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        if let details = reply["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            let text = (exception?["description"] as? String) ?? (details["text"] as? String) ?? "The page script failed."
            // "Error: Element 12 is not on the page any more…" without the stack.
            let line = text.components(separatedBy: "\n").first ?? text
            throw PageError(text: line.hasPrefix("Error: ") ? String(line.dropFirst(7)) : line)
        }
        return (reply["result"] as? [String: Any])?["value"]
    }
}
