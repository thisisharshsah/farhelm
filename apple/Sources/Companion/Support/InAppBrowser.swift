import AppKit
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
        // The page shows that the agent is at work in it, while the chat it
        // works for is the one open.
        if chat == nil || chat == app.conversation.id { BrowserUI.shared.agentStepped() }
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
                web.show(web.tabs[index].id)
                app.showSide(.browser, for: chat)
                return describe(web)
            case "read":
                guard let tab = target(args, in: web) else { return ["ok": false, "error": "No such page is open; list the tabs, or open one first."] }
                let result = try await tab.webView.callAsyncJavaScript(script + "return snapshot();", arguments: [:],
                                                                         in: nil, contentWorld: .defaultClient)
                var answer = result as? [String: Any] ?? [:]
                PageLabels.remember(answer)
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
            case "look":
                guard let tab = target(args, in: web) else { return ["ok": false, "error": "No page is open."] }
                let image: NSImage? = await withCheckedContinuation { done in
                    tab.webView.takeSnapshot(with: nil) { image, _ in done.resume(returning: image) }
                }
                guard let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6]),
                      let file = savePicture(data) else {
                    return ["ok": false, "error": "The page could not be pictured."]
                }
                var answer = describe(web)
                answer["picture"] = file
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
      // Terminals and code editors on a page (JupyterLab, code-server,
      // CodeMirror) are listed as one element each, to click and type in.
      const selector = "a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[role=option],[contenteditable=true],.xterm,.monaco-editor,.cm-editor";
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
        const kind = el.matches(".xterm") ? "terminal" : (el.matches(".monaco-editor,.cm-editor") ? "code editor" : "");
        elements.push({ i: n, tag: el.tagName.toLowerCase(), type: kind || el.type || el.getAttribute("role") || "", label: kind ? (kind + " " + label.slice(0, 40)).trim() : label,
                        href: el.href ? String(el.href).slice(0, 140) : "" });
        if (n >= 300) break;
      }
      const text = (document.body ? document.body.innerText : "").replace(/\n{3,}/g, "\n\n").slice(0, 15000);
      return { title: document.title, url: location.href, text, elements };
    }
    // An element by its number from the last read, checked by its name: a
    // page that refreshed itself (or moved things) renumbers what it shows,
    // so a number alone could press the wrong thing. If the name no longer
    // matches, the one element that has it is used; if none or several
    // do, the page has to be read again.
    function labelOf(e) {
      return (e.getAttribute("aria-label") || e.innerText || (e.type === "password" ? "" : e.value) || e.placeholder || e.title || e.name || "")
        .trim().replace(/\s+/g, " ").slice(0, 80);
    }
    function findElement(id, expected) {
      let el = document.querySelector('[data-companion-id="' + id + '"]');
      if (expected && (!el || labelOf(el) !== expected)) {
        const selector = "a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[role=option],[contenteditable=true]";
        const same = Array.from(document.querySelectorAll(selector)).filter((e) => {
          const box = e.getBoundingClientRect();
          return (box.width > 0 || box.height > 0) && labelOf(e) === expected;
        });
        if (same.length === 1) {
          el = same[0];
          el.setAttribute("data-companion-id", String(id));
        } else if (same.length === 0) {
          throw new Error("The page changed since it was read: nothing called \"" + expected + "\" is on it now. Read the page again.");
        } else {
          throw new Error("The page changed since it was read, and " + same.length + " elements are called \"" + expected + "\" now. Read the page again and use the new number.");
        }
      }
      if (!el) throw new Error("Element " + id + " is not on the page any more; read the page again.");
      // What the agent clicks opens here, in the same tab, never in a new
      // window that could be lost: a link or a form meant for a new tab
      // ("Connect to Jupyter") is pointed at this one. Pages that redraw
      // (OnDemand refreshes its session cards every few seconds) replace
      // the element before the click lands, so the page itself also turns
      // the next few seconds of new-tab links, forms and window.open into
      // this tab.
      try {
        window.__companionClickAt = Date.now();
        if (!window.__companionSameTab) {
          window.__companionSameTab = true;
          const fresh = () => Date.now() - (window.__companionClickAt || 0) < 4000;
          document.addEventListener("submit", (e) => {
            try { const f = e.target; if (fresh() && f && f.target && f.target !== "_self") f.target = "_self"; } catch (x) {}
          }, true);
          document.addEventListener("click", (e) => {
            try {
              const a = e.target && e.target.closest && e.target.closest("a[target]");
              if (fresh() && a && a.target !== "_self") a.target = "_self";
              const b = e.target && e.target.closest && e.target.closest("button, input[type=submit]");
              const f = b && (b.form || b.closest("form"));
              if (fresh() && f && f.target && f.target !== "_self") f.target = "_self";
              if (fresh() && b && b.formTarget && b.formTarget !== "_self") b.formTarget = "_self";
            } catch (x) {}
          }, true);
          const open = window.open;
          window.open = function (u, n, o) {
            if (fresh() && u) { location.href = new URL(u, location.href).href; return window; }
            return open.apply(this, arguments);
          };
        }
      } catch (e) {}
      try {
        const link = el.closest("a[target]");
        if (link && link.target && link.target !== "_self") link.target = "_self";
        const form = el.form || el.closest("form");
        if (form && form.target && form.target !== "_self") form.target = "_self";
        if (el.formTarget && el.formTarget !== "_self") el.formTarget = "_self";
      } catch (e) {}
      return el;
    }
    function elementCenter(id, expected) {
      const el = findElement(id, expected);
      el.scrollIntoView({ block: "center", inline: "center" });
      const box = el.getBoundingClientRect();
      const x = box.left + box.width / 2, y = box.top + box.height / 2;
      // Something else on top of it (a cookie banner, a dialog) would take
      // a real click: then the element is clicked directly instead.
      const top = document.elementFromPoint(x, y);
      const reachable = box.width > 0 && box.height > 0 && top && (top === el || el.contains(top) || top.contains(el));
      const label = (el.getAttribute("aria-label") || el.innerText || (el.type === "password" ? "" : el.value) || el.tagName).trim().slice(0, 80);
      return { x, y, reachable: !!reachable, label };
    }
    function fileField(id) {
      const el = document.querySelector('[data-companion-id="' + id + '"]');
      if (el) {
        if (el.matches('input[type="file"]')) return el;
        const near = el.querySelector('input[type="file"]')
          || (el.closest("form, label, [role=dialog]") || document).querySelector('input[type="file"]');
        if (near) return near;
      }
      // Hidden fields inside web components (shadow roots), as on Colab
      // and JupyterLab: the last one on the page is the one in use.
      const found = [];
      const walk = (root) => {
        root.querySelectorAll('input[type="file"]').forEach((input) => found.push(input));
        root.querySelectorAll("*").forEach((node) => { if (node.shadowRoot) walk(node.shadowRoot); });
      };
      walk(document);
      return found.length ? found[found.length - 1] : (window.__companionFileInput || null);
    }
    // A page that makes its file field on the fly and clicks it from code
    // (Colab, JupyterLab, Google Drive) never shows one to find: the click
    // is caught instead, and the field kept for the files.
    function catchFilePicker() {
      if (window.__companionFileHook) return true;
      window.__companionFileHook = true;
      const click = HTMLInputElement.prototype.click;
      HTMLInputElement.prototype.click = function () {
        if (this.type === "file") { window.__companionFileInput = this; return; }
        return click.call(this);
      };
      const picker = HTMLInputElement.prototype.showPicker;
      if (picker) HTMLInputElement.prototype.showPicker = function () {
        if (this.type === "file") { window.__companionFileInput = this; return; }
        return picker.call(this);
      };
      return true;
    }
    function clickElement(id, expected) {
      const el = findElement(id, expected);
      el.scrollIntoView({ block: "center" });
      el.click();
      return (el.getAttribute("aria-label") || el.innerText || (el.type === "password" ? "" : el.value) || el.tagName).trim().slice(0, 80);
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
    // A menu (a <select>) is chosen from, not typed into: keys typed into
    // one go nowhere, and Enter there sends the whole form. The option is
    // the one whose text or value matches what was to be typed.
    function isMenu(id) {
      const el = document.querySelector('[data-companion-id="' + id + '"]');
      return !!(el && el.tagName === "SELECT");
    }
    function chooseOption(id, text) {
      const el = document.querySelector('[data-companion-id="' + id + '"]');
      if (!el || el.tagName !== "SELECT") return { error: "Element " + id + " is not a menu any more; read the page again." };
      const want = String(text).trim().toLowerCase();
      const options = Array.from(el.options);
      const named = (o) => (o.textContent || "").trim().toLowerCase();
      const pick = options.find((o) => named(o) === want || o.value.toLowerCase() === want)
        || options.find((o) => named(o).includes(want) || o.value.toLowerCase().includes(want));
      if (!pick) {
        return { error: "The menu has no option like \"" + text + "\". Its options: " + options.map((o) => (o.textContent || o.value).trim()).slice(0, 30).join(", ") };
      }
      el.scrollIntoView({ block: "center" });
      cursorOn(el, "type");
      el.focus();
      Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value").set.call(el, pick.value);
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
      return { field: (el.getAttribute("aria-label") || el.name || "the menu").slice(0, 60), chose: (pick.textContent || pick.value).trim() };
    }
    // The agent's own pointer, drawn over the page so the person can follow
    // what it does: it glides to what it clicks or types into, pulses on a
    // click, takes no clicks itself, and fades once the agent is still.
    function agentCursor(x, y, mode) {
      try {
        let host = document.getElementById("companion-agent-cursor");
        let root = host && host.shadowRoot;
        if (!root) {
          host = document.createElement("div");
          host.id = "companion-agent-cursor";
          host.style.cssText = "position:fixed;left:0;top:0;width:0;height:0;z-index:2147483647;pointer-events:none;";
          root = host.attachShadow({ mode: "open" });
          const style = document.createElement("style");
          style.textContent = ".c{position:fixed;left:0;top:0;width:24px;height:24px;pointer-events:none;transition:transform .38s cubic-bezier(.2,.8,.2,1),opacity .3s}"
            + ".r{position:fixed;left:0;top:0;width:30px;height:30px;margin:-15px 0 0 -15px;border-radius:50%;border:2px solid rgb(139,108,255);opacity:0;pointer-events:none}"
            + ".r.go{animation:p .55s ease-out}@keyframes p{0%{transform:scale(.3);opacity:.95}100%{transform:scale(1.7);opacity:0}}"
            + ".t{position:fixed;left:0;top:0;padding:2px 7px;border-radius:8px;background:rgb(139,108,255);color:#fff;font:600 11px -apple-system,system-ui,sans-serif;pointer-events:none;transition:transform .38s cubic-bezier(.2,.8,.2,1),opacity .3s;white-space:nowrap}";
          const ns = "http://www.w3.org/2000/svg";
          const svg = document.createElementNS(ns, "svg");
          svg.setAttribute("class", "c");
          svg.setAttribute("viewBox", "0 0 24 24");
          const path = document.createElementNS(ns, "path");
          path.setAttribute("d", "M4 2.5 20 11.7l-7.2 1.7-3.5 6.9z");
          path.setAttribute("fill", "rgb(139,108,255)");
          path.setAttribute("stroke", "white");
          path.setAttribute("stroke-width", "1.6");
          path.setAttribute("stroke-linejoin", "round");
          svg.appendChild(path);
          const ring = document.createElement("div");
          ring.className = "r";
          const tag = document.createElement("div");
          tag.className = "t";
          tag.textContent = "Companion";
          root.append(style, svg, ring, tag);
          (document.body || document.documentElement).appendChild(host);
          const startX = window.innerWidth / 2, startY = window.innerHeight / 2;
          svg.style.transform = "translate(" + startX + "px," + startY + "px)";
          tag.style.transform = "translate(" + (startX + 16) + "px," + (startY + 20) + "px)";
          svg.getBoundingClientRect();
        }
        const svg = root.querySelector(".c"), ring = root.querySelector(".r"), tag = root.querySelector(".t");
        svg.style.opacity = "1";
        tag.style.opacity = "1";
        tag.textContent = mode === "type" ? "Typing" : (mode === "click" ? "Clicking" : "Companion");
        svg.style.transform = "translate(" + (x - 4) + "px," + (y - 2) + "px)";
        tag.style.transform = "translate(" + (x + 14) + "px," + (y + 18) + "px)";
        if (mode === "click") {
          setTimeout(() => {
            ring.style.left = x + "px";
            ring.style.top = y + "px";
            ring.classList.remove("go");
            void ring.offsetWidth;
            ring.classList.add("go");
          }, 380);
        }
        clearTimeout(window.__companionCursorFade);
        window.__companionCursorFade = setTimeout(() => { svg.style.opacity = "0"; tag.style.opacity = "0"; }, 6000);
      } catch (e) {}
      return true;
    }
    function cursorOn(el, mode) {
      try {
        const box = el.getBoundingClientRect();
        agentCursor(box.left + Math.min(box.width / 2, 40), box.top + box.height / 2, mode);
      } catch (e) {}
    }
    function focusForTyping(id) {
      let el = document.querySelector('[data-companion-id="' + id + '"]');
      // A terminal or an editor takes keys through a box inside it.
      if (el && el.matches(".xterm,.monaco-editor,.cm-editor")) {
        el.scrollIntoView({ block: "center" });
        const box = el.querySelector("textarea, [contenteditable=true]");
        cursorOn(el, "type");
        if (box) { box.focus(); return { field: el.matches(".xterm") ? "the terminal" : "the editor" }; }
      }
      if (!el) return { error: "Element " + id + " is not on the page any more; read the page again." };
      if (el.type === "password" || /pass(word|code)|one-time-code/i.test(el.autocomplete || "")) {
        return { error: "That is a password field. Passwords are filled by the user with iCloud Passwords (the bar over the page), never typed by the agent: ask the user to sign in, then carry on." };
      }
      el.scrollIntoView({ block: "center" });
      el.focus();
      cursorOn(el, "type");
      // A field's old text is chosen, so what is typed replaces it; a
      // terminal's or an editor's hidden box is typed into as it is.
      const plain = (el.tagName === "INPUT" || el.tagName === "TEXTAREA") && !/xterm|inputarea|monaco/i.test(el.className || "");
      if (plain && el.select) el.select();
      else if (el.isContentEditable && !/cm-content|ProseMirror/i.test(el.className || "")) {
        const range = document.createRange(); range.selectNodeContents(el);
        const chosen = window.getSelection(); chosen.removeAllRanges(); chosen.addRange(range);
      }
      return { field: (el.getAttribute("aria-label") || el.placeholder || el.name || el.tagName).slice(0, 60) };
    }
    function focusedField() {
      const el = document.activeElement;
      if (!el || el === document.body) return { error: "Nothing on the page has the cursor. Click the field, terminal or editor first, then type." };
      if (el.type === "password") return { error: "That is a password field: ask the user to sign in." };
      cursorOn(el.closest(".xterm,.monaco-editor,.cm-editor") || el, "type");
      return { field: (el.getAttribute("aria-label") || el.placeholder || el.className || el.tagName).toString().slice(0, 60) };
    }
    function pressKey(key) {
      const target = document.activeElement || document.body;
      for (const type of ["keydown", "keyup"]) target.dispatchEvent(new KeyboardEvent(type, { key, bubbles: true }));
      if (key === "Enter" && target.form && target.form.requestSubmit) target.form.requestSubmit();
    }

    """#
}

/// The numbered elements of the page the agent read last, so an approval
/// can say "click [31] the COLLAPSE button" and not only "click [31]".
enum PageLabels {
    private static let lock = NSLock()
    private static var labels: [Int: String] = [:]
    /// The names as the page gave them, to find an element again by name.
    private static var raws: [Int: String] = [:]
    /// The message of the dialog a page showed last, for the approval card.
    nonisolated(unsafe) static var dialog = ""

    static func remember(_ snapshot: [String: Any]) {
        guard let elements = snapshot["elements"] as? [[String: Any]] else { return }
        var found: [Int: String] = [:]
        var names: [Int: String] = [:]
        for element in elements {
            guard let number = (element["i"] as? NSNumber)?.intValue else { continue }
            let label = (element["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Terminals and editors are named by their kind, not their text.
            let type = element["type"] as? String ?? ""
            if type != "terminal", type != "code editor", !label.isEmpty { names[number] = label }
            let tag = element["tag"] as? String ?? ""
            let kind = ["a": "link", "button": "button", "input": "field", "textarea": "field", "select": "menu"][tag] ?? ""
            let text = label.count > 48 ? String(label.prefix(47)) + "…" : label
            found[number] = text.isEmpty ? kind : (kind.isEmpty ? "\u{201C}\(text)\u{201D}" : "the \u{201C}\(text)\u{201D} \(kind)")
        }
        lock.lock(); labels = found; raws = names; lock.unlock()
    }

    /// An element's name as the page gave it in the last read.
    static func raw(_ target: Any?) -> String? {
        let number = (target as? NSNumber)?.intValue ?? Int("\(target ?? "")")
        lock.lock(); defer { lock.unlock() }
        return number.flatMap { raws[$0] }
    }

    /// "[31] the “COLLAPSE” button", or "[31]" when the label is unknown.
    static func named(_ target: Any?) -> String {
        let number = (target as? NSNumber)?.intValue ?? Int("\(target ?? "")")
        lock.lock(); defer { lock.unlock() }
        guard let number else { return "[\(target ?? "?")]" }
        guard let label = labels[number], !label.isEmpty else { return "[\(number)]" }
        return "[\(number)] \(label)"
    }
}

// MARK: - The same steps in Chromium

extension InAppBrowser {
    /// A page step in the chat's Chromium tabs, through DevTools' Runtime
    /// (the same page script as in WebKit). nil for steps that are not
    /// about the page, which run as before.
    static func chromiumStep(_ command: String, _ args: [String: Any], app: AppState, chat: UUID? = nil) async -> [String: Any]? {
        let tabs = app.web(for: chat ?? app.conversation.id).chromium
        func page() -> ChromiumTab? { tabs.current }
        // A dialog of the page's own blocks the page: nothing else on it
        // runs until it is answered, so it is answered first.
        if command == "dialog" {
            guard let tab = page(), let open = tab.dialog else { return ["ok": false, "error": "The page has no dialog open."] }
            let accept = (args["accept"] as? Bool) ?? ((args["accept"] as? String) == "true")
            tab.answerDialog(accept: accept, text: args["text"] as? String)
            try? await Task.sleep(nanoseconds: 800_000_000)
            await settle(tabs, timeout: 6)
            var answer = describe(tabs)
            answer["answered"] = (accept ? "OK" : "Cancel") + " to \u{201C}\(open.message)\u{201D}"
            return answer
        }
        if let open = page()?.dialog, !["tabs", "focus", "open"].contains(command) {
            return ["ok": false, "error": "The page is showing a \(open.kind) dialog: \u{201C}\(open.message)\u{201D}. Nothing on the page works until it is answered: use dialog with accept true (OK) or false (Cancel)."]
        }
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
                tabs.show(tabs.tabs[index].id)
                app.showSide(.browser, for: chat)
                return describe(tabs)
            case "read":
                guard let tab = target(args, in: tabs) else { return ["ok": false, "error": "No such page is open; list the tabs, or open one first."] }
                // A tab asleep has no page to read until it is shown.
                if tab.asleep { return ["ok": false, "error": "That tab is asleep. Focus it first, then read."] }
                var answer = try await evaluate(tab, call: "snapshot()") as? [String: Any] ?? [:]
                PageLabels.remember(answer)
                answer["ok"] = true
                return answer
            case "click":
                guard let tab = page() else { return ["ok": false, "error": "No page is open."] }
                let target = literal("\(args["target"] ?? "")")
                // A real click, as a person's: the mouse pressed and let go
                // at the element's middle. Pages that ignore a script's
                // click (menus, custom buttons) take this one.
                var label: Any? = nil
                // The name it had when the page was read, to be sure it is
                // still the same element.
                let expected = literal(PageLabels.raw(args["target"]) ?? "")
                await keepFocused(tab)
                if let spot = try await evaluate(tab, call: "elementCenter(\(target), \(expected))") as? [String: Any],
                   spot["reachable"] as? Bool == true,
                   let x = (spot["x"] as? NSNumber)?.doubleValue, let y = (spot["y"] as? NSNumber)?.doubleValue {
                    // The agent's pointer glides there first, so the person
                    // sees what is about to be clicked.
                    await briefly(1) { _ = try? await evaluate(tab, call: "agentCursor(\(x), \(y), 'click')") }
                    try? await Task.sleep(nanoseconds: 420_000_000)
                    for type in ["mouseMoved", "mousePressed", "mouseReleased"] {
                        // A click that opens a dialog leaves the page waiting
                        // on it: the press is not waited on for long.
                        await briefly(2) {
                            _ = await tab.devTools("Input.dispatchMouseEvent",
                                                   ["type": type, "x": x, "y": y, "button": type == "mouseMoved" ? "none" : "left",
                                                    "clickCount": type == "mouseMoved" ? 0 : 1])
                        }
                        if tab.dialog != nil { break }
                    }
                    label = spot["label"]
                } else {
                    // A script's click that opens a dialog would hold the
                    // script until it is answered: not waited on for long.
                    final class Box: @unchecked Sendable { var value: Any? }
                    let box = Box()
                    await briefly(2) { box.value = try? await evaluate(tab, call: "clickElement(\(target), \(expected))") }
                    label = box.value
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                var answer: [String: Any]
                if let open = tab.dialog {
                    // The click asked something: it waits for an answer.
                    answer = describe(tabs)
                    answer["dialog"] = "\(open.kind): \(open.message)"
                } else {
                    await settle(tabs, timeout: 8)
                    answer = describe(tabs)
                }
                answer["clicked"] = label as? String ?? ""
                return answer
            case "type":
                // Real typing, as from the keyboard: the field gets the
                // keys, so terminals (JupyterLab, VS Code) and editors that
                // ignore a script setting the value take it too. With no
                // target it types where the cursor already is.
                guard let tab = page() else { return ["ok": false, "error": "No page is open."] }
                let submit = (args["submit"] as? Bool) == true
                let target = "\(args["target"] ?? "")".trimmingCharacters(in: .whitespaces)
                let call = target.isEmpty ? "focusedField()" : "focusForTyping(\(literal(target)))"
                await keepFocused(tab)
                if !target.isEmpty, try await evaluate(tab, call: "isMenu(\(literal(target)))") as? Bool == true {
                    // A menu: its option is chosen, and nothing is pressed.
                    let chosen = try await evaluate(tab, call: "chooseOption(\(literal(target)), \(literal(args["text"] as? String ?? "")))") as? [String: Any]
                    if let error = chosen?["error"] as? String { return ["ok": false, "error": error] }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    var answer = describe(tabs)
                    answer["typed"] = "\(chosen?["field"] as? String ?? "the menu"): chose \(chosen?["chose"] as? String ?? "")"
                    return answer
                }
                let outcome = try await evaluate(tab, call: call) as? [String: Any]
                if let error = outcome?["error"] as? String { return ["ok": false, "error": error] }
                // The pointer has gone to the field: a moment to see it there.
                try? await Task.sleep(nanoseconds: 350_000_000)
                let typed = await tab.devTools("Input.insertText", ["text": args["text"] as? String ?? ""])
                if let error = typed.error { return ["ok": false, "error": "The page did not take the typing: \(error)"] }
                if submit {
                    await pressReal("Enter", in: tab)
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
                tab.goBack()
                await settle(tabs, timeout: 8)
                return describe(tabs)
            case "key":
                // A real key press, which terminals and editors take.
                guard let tab = page() else { return ["ok": false, "error": "No page is open."] }
                await keepFocused(tab)
                await pressReal(args["key"] as? String ?? "Enter", in: tab)
                try? await Task.sleep(nanoseconds: 300_000_000)
                return describe(tabs)
            case "look":
                // The page as the person sees it, for the model to look at:
                // what a page's text leaves out (a layout, a chart, a
                // captcha, which button is highlighted).
                guard let tab = page() else { return ["ok": false, "error": "No page is open."] }
                let shot = await tab.devTools("Page.captureScreenshot", ["format": "jpeg", "quality": 60])
                guard let data = (shot.result?["data"] as? String).flatMap({ Data(base64Encoded: $0) }),
                      let file = savePicture(data) else {
                    return ["ok": false, "error": shot.error ?? "The page could not be pictured."]
                }
                var answer = describe(tabs)
                answer["picture"] = file
                return answer
            case "upload":
                // Files from this Mac straight into the page's file field
                // (DevTools DOM.setFileInputFiles), as if chosen in the Open
                // panel; the page sees them change as usual.
                guard let tab = page() else { return ["ok": false, "error": "No page is open."] }
                let paths = (args["paths"] as? [Any])?.compactMap { $0 as? String } ?? []
                let files = paths.map { ($0 as NSString).expandingTildeInPath }
                let missing = files.filter { !FileManager.default.fileExists(atPath: $0) }
                guard !files.isEmpty, missing.isEmpty else {
                    return ["ok": false, "error": missing.isEmpty ? "No files were named." : "Not found: \(missing.joined(separator: ", "))"]
                }
                let target = literal("\(args["target"] ?? "")")
                var found = await tab.devTools("Runtime.evaluate", [
                    "expression": "(() => {\n\(script)\nreturn fileField(\(target));\n})()",
                    "returnByValue": false,
                ])
                if (found.result?["result"] as? [String: Any])?["objectId"] == nil {
                    // No field yet: the button (target) is pressed with the
                    // picker caught, and the field it made is used.
                    _ = try? await evaluate(tab, call: "catchFilePicker()")
                    final class Box: @unchecked Sendable { var value: Any? }
                    let box = Box()
                    await briefly(2) { box.value = try? await evaluate(tab, call: "clickElement(\(target), '')") }
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    found = await tab.devTools("Runtime.evaluate", [
                        "expression": "(() => {\n\(script)\nreturn fileField(\(target));\n})()",
                        "returnByValue": false,
                    ])
                }
                guard let object = (found.result?["result"] as? [String: Any])?["objectId"] as? String else {
                    return ["ok": false, "error": found.error ?? "No file field at \(args["target"] ?? "that element") or near it. Read the page and name the file field, or the button beside it."]
                }
                let set = await tab.devTools("DOM.setFileInputFiles", ["files": files, "objectId": object])
                if let error = set.error { return ["ok": false, "error": "The page did not take the files: \(error)"] }
                try? await Task.sleep(nanoseconds: 600_000_000)
                var answer = describe(tabs)
                answer["uploaded"] = files.map { ($0 as NSString).lastPathComponent }
                return answer
            default:
                return nil
            }
        } catch {
            return ["ok": false, "error": (error as? PageError)?.text ?? error.localizedDescription]
        }
    }

    struct PageError: Error { let text: String }

    /// Work waited on for at most `seconds`; past that it is left to
    /// finish on its own and the caller goes on.
    fileprivate static func briefly(_ seconds: Double, _ work: @escaping @MainActor () async -> Void) async {
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                await work()
                if !once.done { once.done = true; continuation.resume() }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if !once.done { once.done = true; continuation.resume() }
            }
        }
    }

    /// A key pressed and let go through DevTools, as the keyboard sends it:
    /// "Enter", "Tab", "Escape", "ArrowUp", or a shortcut such as "ctrl+c".
    /// A page in a window that is not in front (the person working in
    /// another app) loses its focus, and keys typed into it go nowhere:
    /// a terminal shows nothing and the agent reads the old screen as new.
    /// The page is told to act focused, as it does with the window in front.
    fileprivate static func keepFocused(_ tab: ChromiumTab) async {
        await briefly(2) { _ = await tab.devTools("Emulation.setFocusEmulationEnabled", ["enabled": true]) }
    }

    fileprivate static func pressReal(_ chord: String, in tab: ChromiumTab) async {
        let parts = chord.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let name = parts.last, !name.isEmpty else { return }
        var modifiers = 0
        for part in parts.dropLast() {
            switch part.lowercased() {
            case "alt", "option": modifiers |= 1
            case "ctrl", "control": modifiers |= 2
            case "cmd", "command", "meta": modifiers |= 4
            case "shift": modifiers |= 8
            default: break
            }
        }
        let named: [String: (key: String, code: String, number: Int, text: String)] = [
            "enter": ("Enter", "Enter", 13, "\r"), "return": ("Enter", "Enter", 13, "\r"),
            "tab": ("Tab", "Tab", 9, "\t"), "escape": ("Escape", "Escape", 27, ""), "esc": ("Escape", "Escape", 27, ""),
            "backspace": ("Backspace", "Backspace", 8, ""), "delete": ("Delete", "Delete", 46, ""),
            "space": (" ", "Space", 32, " "),
            "arrowup": ("ArrowUp", "ArrowUp", 38, ""), "up": ("ArrowUp", "ArrowUp", 38, ""),
            "arrowdown": ("ArrowDown", "ArrowDown", 40, ""), "down": ("ArrowDown", "ArrowDown", 40, ""),
            "arrowleft": ("ArrowLeft", "ArrowLeft", 37, ""), "left": ("ArrowLeft", "ArrowLeft", 37, ""),
            "arrowright": ("ArrowRight", "ArrowRight", 39, ""), "right": ("ArrowRight", "ArrowRight", 39, ""),
            "home": ("Home", "Home", 36, ""), "end": ("End", "End", 35, ""),
            "pageup": ("PageUp", "PageUp", 33, ""), "pagedown": ("PageDown", "PageDown", 34, ""),
        ]
        var key = name, code = "", number = 0, text = ""
        if let known = named[name.lowercased()] {
            key = known.key; code = known.code; number = known.number; text = known.text
        } else if name.count == 1, let scalar = name.uppercased().unicodeScalars.first {
            key = name
            code = name.first!.isLetter ? "Key" + name.uppercased() : (name.first!.isNumber ? "Digit" + name : "")
            number = Int(scalar.value)
            text = modifiers & (2 | 4) == 0 ? name : ""
        }
        var down: [String: Any] = ["type": text.isEmpty ? "rawKeyDown" : "keyDown", "key": key, "code": code,
                                   "windowsVirtualKeyCode": number, "nativeVirtualKeyCode": number, "modifiers": modifiers]
        if !text.isEmpty { down["text"] = text; down["unmodifiedText"] = text }
        _ = await tab.devTools("Input.dispatchKeyEvent", down)
        _ = await tab.devTools("Input.dispatchKeyEvent", ["type": "keyUp", "key": key, "code": code,
                                                         "windowsVirtualKeyCode": number, "nativeVirtualKeyCode": number,
                                                         "modifiers": modifiers])
    }

    /// Keeps a picture of a page for the model, in a folder of Companion's
    /// own that is emptied of pictures older than a day.
    fileprivate static func savePicture(_ data: Data) -> String? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("companion-page-pictures", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-86_400)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let path = folder.appendingPathComponent(name).path
            if let made = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date, made < old {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        let file = folder.appendingPathComponent(UUID().uuidString + ".jpg")
        return (try? data.write(to: file)) == nil ? nil : file.path
    }

    /// The tab a step is about: the one numbered (from 1, as "tabs" lists
    /// them), else the one showing. Reading a tab does not switch to it.
    fileprivate static func target<Model: BrowsingModel>(_ args: [String: Any], in web: Model) -> Model.Tab? {
        guard let number = args["tab"] as? Int else { return web.current }
        return web.tabs.indices.contains(number - 1) ? web.tabs[number - 1] : nil
    }

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
            tab.evaluate(expression) { json, error in
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
