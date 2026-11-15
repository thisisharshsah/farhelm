import AppKit
import CryptoKit
import Foundation
import WebKit

/// Chrome extensions in Companion's browser. They are the same extensions
/// Chrome uses (manifest v3, from the Chrome Web Store, a folder, or the
/// ones already installed in Chrome, Arc, Brave or Edge), run by WebKit's
/// own extension support (macOS 15.4 or later). One set serves every
/// chat's browser and the agent's steps in it, so a blocker, a reader or a
/// password manager added once works everywhere the browser does.
///
/// An extension is asked about before it is added, with what it may do;
/// what it later asks for is asked about again. Its files live in
/// Companion's own folder. Extensions that talk to an app on this Mac
/// (native messaging) reach it the way Chrome does, through the app's own
/// host file, and only when that file names the extension.
@MainActor
final class BrowserExtensions: ObservableObject {
    static let shared = BrowserExtensions()

    /// Apple's iCloud Passwords extension. Its helper on this Mac answers
    /// only Apple's list of browsers, so it cannot run here as it is: its
    /// button opens Companion's own iCloud Passwords instead (the same
    /// keychain, paired the same way with a code from macOS).
    static let iCloudPasswordsID = "pejdijmoenmkgeppbflobdenhhabjlaj"

    struct Item: Identifiable, Codable, Hashable {
        var id: String
        var name: String
        var version: String
        var summary: String
        /// "Chrome Web Store", "Folder", "Arc", "Google Chrome", ...
        var source: String
        var enabled = true
        /// Shown as a button in the browser bar.
        var pinned = true
        /// What went wrong loading it, if anything.
        var problem: String?
    }

    /// An extension found in another browser, ready to bring over.
    struct Found: Identifiable, Hashable {
        let id: String
        let name: String
        let version: String
        let folder: URL
        let browser: String
    }

    /// One button in the browser bar.
    struct ToolbarAction: Identifiable {
        let id: String
        let label: String
        let icon: NSImage?
        let badge: String
        let enabled: Bool
        let pinned: Bool
        let hasOptions: Bool
    }

    @Published private(set) var items: [Item] = []
    /// What is being added right now, for a line with a spinner.
    @Published private(set) var busy: String?
    /// The last thing worth telling (an error, or what was added).
    @Published var notice: String?
    /// Goes up when an extension changes its button (icon, badge, title).
    @Published private(set) var tick = 0

    nonisolated static var supported: Bool {
        if #available(macOS 15.4, *) { return true }
        return false
    }

    let root: URL
    private let listFile: URL
    private var runtimeBox: AnyObject?
    private var icons: [String: NSImage] = [:]

    @available(macOS 15.4, *)
    fileprivate var runtime: ExtensionRuntime? { runtimeBox as? ExtensionRuntime }

    private init() {
        root = ContextStore.shared.baseDir.appendingPathComponent("extensions", isDirectory: true)
        listFile = root.appendingPathComponent("extensions.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: listFile),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
        if #available(macOS 15.4, *) {
            let runtime = ExtensionRuntime(owner: self)
            runtimeBox = runtime
            Task { @MainActor in
                for item in self.items where item.enabled { await self.start(item.id) }
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: listFile, options: .atomic)
    }

    func folder(of id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    fileprivate func bump() { tick &+= 1 }

    // MARK: The browser tells it what happens

    func attach(_ configuration: WKWebViewConfiguration) {
        if #available(macOS 15.4, *), let runtime {
            configuration.webExtensionController = runtime.controller
            // The Chrome Web Store's own button adds to Companion.
            let content = configuration.userContentController
            content.addUserScript(WKUserScript(source: Self.storeScript, injectionTime: .atDocumentEnd,
                                               forMainFrameOnly: true, in: .defaultClient))
            content.add(StoreMessages.shared, contentWorld: .defaultClient, name: "companionStore")
        }
    }

    // MARK: The Chrome Web Store's own button

    /// Store pages whose button now adds to Companion. Where it could not
    /// be found, the bar over the page offers the same.
    @Published private(set) var storeHooked = Set<ObjectIdentifier>()

    fileprivate func storeMessage(_ body: [String: Any], from webView: WKWebView) {
        if body["hooked"] != nil { storeHooked.insert(ObjectIdentifier(webView)) }
        if body["hello"] != nil { mark(webView) }
        if let id = body["add"] as? String, Self.storeID(in: id) != nil {
            Task { @MainActor in
                mark(webView, working: true)
                _ = await installFromStore(id)
                mark(webView)
            }
        }
    }

    /// Tells a store page which extensions are here, so its button reads
    /// right (Add, Adding, In Companion).
    private func mark(_ webView: WKWebView, working: Bool = false) {
        let ids = items.map(\.id)
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript("if (window.__companionMark) window.__companionMark(ids, working);",
                                                       arguments: ["ids": ids, "working": working],
                                                       in: nil, contentWorld: .defaultClient)
        }
    }

    /// On chromewebstore.google.com: the store's "Add to Chrome" button
    /// becomes "Add to Companion" and the "Switch to Chrome" notice goes.
    /// The page cannot see or call this (it runs in a world of its own).
    private static let storeScript = #"""
    (() => {
      if (location.host !== "chromewebstore.google.com") return;
      let installed = [], busy = false, told = "";
      const post = (m) => { try { webkit.messageHandlers.companionStore.postMessage(m); } catch (e) {} };
      const idNow = () => (location.pathname.match(/\/detail\/(?:[^\/]+\/)?([a-p]{32})/) || [])[1];
      window.__companionMark = (ids, working) => { installed = ids || []; busy = !!working; apply(); };

      function hideNotices() {
        for (const el of document.querySelectorAll("div, section, aside, p, span")) {
          if (el.dataset.companionHidden) continue;
          const text = el.textContent || "";
          if (text.length > 160 || !/switch to chrome/i.test(text)) continue;
          let box = el;
          while (box.parentElement && box.parentElement !== document.body &&
                 (box.parentElement.textContent || "").length < 220) box = box.parentElement;
          box.style.display = "none";
          box.dataset.companionHidden = "1";
        }
      }

      function storeButton() {
        return [...document.querySelectorAll("button")].find((b) =>
          !b.dataset.companionStore && /^(add to chrome|remove from chrome|get)$/i.test((b.textContent || "").trim()));
      }

      function label(button) {
        const have = installed.includes(idNow());
        const text = busy ? "Adding…" : (have ? "In Companion (update)" : "Add to Companion");
        const walker = document.createTreeWalker(button, NodeFilter.SHOW_TEXT);
        let node, last = null;
        while ((node = walker.nextNode())) if (node.textContent.trim()) last = node;
        if (last) { if (last.textContent !== text) last.textContent = text; } else button.textContent = text;
        button.style.opacity = busy ? "0.6" : "";
        button.style.cursor = busy ? "progress" : "pointer";
      }

      function apply() {
        const id = idNow();
        if (!id) return;
        if (told !== id) { told = id; post({ hello: id }); }
        hideNotices();
        let mine = document.querySelector("button[data-companion-store]");
        if (!mine) {
          const original = storeButton();
          if (!original) return;
          mine = original.cloneNode(true);
          mine.dataset.companionStore = "1";
          mine.removeAttribute("disabled");
          mine.removeAttribute("aria-disabled");
          mine.addEventListener("click", (event) => {
            event.preventDefault();
            event.stopPropagation();
            const current = idNow();
            if (!current || busy) return;
            busy = true;
            label(mine);
            post({ add: current });
          }, true);
          original.replaceWith(mine);
          post({ hooked: id });
        }
        label(mine);
      }

      let timer = null;
      new MutationObserver(() => {
        if (!timer) timer = setTimeout(() => { timer = null; apply(); }, 250);
      }).observe(document.documentElement, { childList: true, subtree: true });
      apply();
    })();
    """#

    func opened(window model: BrowserModel) {
        if #available(macOS 15.4, *) { runtime?.opened(window: model) }
    }

    func closed(window model: BrowserModel) {
        if #available(macOS 15.4, *) { runtime?.closed(window: model) }
    }

    func opened(_ tab: BrowserTab, in model: BrowserModel) {
        if #available(macOS 15.4, *) { runtime?.opened(tab, in: model) }
    }

    func closed(_ tab: BrowserTab, in model: BrowserModel) {
        if #available(macOS 15.4, *) { runtime?.closed(tab, in: model, windowClosing: false) }
    }

    func activated(_ tab: BrowserTab?, previous: BrowserTab?, in model: BrowserModel) {
        if #available(macOS 15.4, *) { runtime?.activated(tab, previous: previous, in: model) }
    }

    enum TabChange { case url, title, loading }

    func changed(_ tab: BrowserTab, _ what: TabChange) {
        if #available(macOS 15.4, *) { runtime?.changed(tab, what) }
    }

    // MARK: The browser bar

    func toolbar(tab: BrowserTab?, in model: BrowserModel) -> [ToolbarAction] {
        guard #available(macOS 15.4, *), let runtime else { return [] }
        return items.filter(\.enabled).compactMap { item -> ToolbarAction? in
            if item.id == Self.iCloudPasswordsID {
                return ToolbarAction(id: item.id, label: "iCloud Passwords", icon: icon(for: item.id),
                                     badge: ICloudPasswords.shared.state == .ready ? "" : "!",
                                     enabled: true, pinned: item.pinned, hasOptions: false)
            }
            guard let context = runtime.contexts[item.id] else { return nil }
            let action = runtime.action(item.id, tab: tab, in: model)
            let size = CGSize(width: 18, height: 18)
            return ToolbarAction(id: item.id,
                                 label: action?.label ?? item.name,
                                 icon: action?.icon(for: size) ?? context.webExtension.icon(for: size) ?? icon(for: item.id),
                                 badge: action?.badgeText ?? "",
                                 enabled: action?.isEnabled ?? true,
                                 pinned: item.pinned,
                                 hasOptions: context.optionsPageURL != nil)
        }
    }

    func perform(_ id: String, tab: BrowserTab?, in model: BrowserModel) {
        if id == Self.iCloudPasswordsID {
            if let anchor = anchor(for: id) { PasswordsPopover.toggle(webView: tab?.webView, from: anchor) }
            return
        }
        if #available(macOS 15.4, *) { runtime?.perform(id, tab: tab, in: model) }
    }

    func openOptions(_ id: String, in model: BrowserModel) {
        if #available(macOS 15.4, *) { runtime?.openOptions(id, in: model) }
    }

    /// Where an extension's popup hangs from: its button in the bar.
    private let anchors = NSMapTable<NSString, NSView>.strongToWeakObjects()

    func setAnchor(_ view: NSView, for id: String) { anchors.setObject(view, forKey: id as NSString) }

    fileprivate func anchor(for id: String) -> NSView? {
        anchors.object(forKey: id as NSString) ?? anchors.object(forKey: "menu")
            ?? NSApp.keyWindow?.contentView
    }

    // MARK: Managing them

    func setEnabled(_ id: String, _ on: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].enabled = on
        save()
        if #available(macOS 15.4, *) {
            if on { Task { await start(id) } } else { runtime?.unload(id) }
        }
        bump()
    }

    func setPinned(_ id: String, _ on: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned = on
        save()
        bump()
    }

    func remove(_ id: String) {
        if #available(macOS 15.4, *) { runtime?.unload(id) }
        items.removeAll { $0.id == id }
        icons[id] = nil
        try? FileManager.default.removeItem(at: folder(of: id))
        save()
        bump()
    }

    func isInstalled(_ id: String) -> Bool { items.contains { $0.id == id } }

    /// What the agent sees: the extensions in the browser.
    func summary() -> [[String: Any]] {
        items.map { ["id": $0.id, "name": $0.name, "version": $0.version, "on": $0.enabled,
                     "from": $0.source, "problem": $0.problem ?? ""] }
    }

    @available(macOS 15.4, *)
    private func start(_ id: String) async {
        guard let runtime, items.contains(where: { $0.id == id }) else { return }
        // Apple's extension is not run; its button is Companion's own.
        if id == Self.iCloudPasswordsID { runtime.unload(id); bump(); return }
        let problem = await runtime.load(id, from: folder(of: id))
        guard let now = items.firstIndex(where: { $0.id == id }) else { return }
        items[now].problem = problem
        save()
        bump()
    }

    // MARK: Adding

    /// A Chrome Web Store page or an extension ID.
    static func storeID(in text: String) -> String? {
        let pattern = "[a-p]{32}"
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    /// From the Chrome Web Store, the way Chrome fetches it.
    func addFromStore(_ text: String) {
        Task { @MainActor in _ = await installFromStore(text) }
    }

    /// The same, waited for (the agent's step): says what happened.
    func installFromStore(_ text: String) async -> (ok: Bool, message: String) {
        guard Self.supported else { return fail("Extensions need macOS 15.4 or later.") }
        guard let id = Self.storeID(in: text) else {
            return fail("That is not a Chrome Web Store link or extension ID.")
        }
        guard busy == nil else { return fail("Another extension is being added; try again in a moment.") }
        busy = "Downloading from the Chrome Web Store…"
        defer { busy = nil }
        var parts = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        parts.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: "140.0.0.0"),
            URLQueryItem(name: "acceptformat", value: "crx2,crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&installsource=ondemand&uc"),
        ]
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let zip = Self.zipInside(crx: data) else {
            return fail("Could not download that extension from the Chrome Web Store (no answer in 30 seconds, or it is not available).")
        }
        busy = "Unpacking (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))…"
        guard let unpacked = await unzip(zip) else {
            return fail("The download was not an extension Companion can open.")
        }
        defer { try? FileManager.default.removeItem(at: unpacked.work) }
        let added = await add(from: unpacked.folder, id: id, source: "Chrome Web Store")
        return (added, notice ?? "")
    }

    private func fail(_ text: String) -> (ok: Bool, message: String) {
        notice = text
        return (false, text)
    }

    /// A folder with a manifest.json, or a .crx or .zip file.
    func addFromDisk() {
        guard Self.supported else { notice = "Extensions need macOS 15.4 or later."; return }
        let panel = NSOpenPanel()
        panel.message = "Choose an unpacked extension folder (with manifest.json), or a .crx or .zip file."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.level = WindowStacking.above
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        Task { @MainActor in
            busy = "Adding \(picked.lastPathComponent)…"
            defer { busy = nil }
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: picked.path, isDirectory: &isFolder)
            if isFolder.boolValue {
                await add(from: picked, id: nil, source: "Folder")
                return
            }
            guard let data = try? Data(contentsOf: picked) else { notice = "Could not read that file."; return }
            let zip = picked.pathExtension.lowercased() == "crx" ? Self.zipInside(crx: data) : data
            guard let zip, let unpacked = await unzip(zip) else {
                notice = "That file is not an extension Companion can open."
                return
            }
            defer { try? FileManager.default.removeItem(at: unpacked.work) }
            await add(from: unpacked.folder, id: nil, source: "File")
        }
    }

    /// Brings over extensions found in another browser (their files only:
    /// no sign-ins, history or settings come with them).
    func importFound(_ found: [Found]) {
        guard Self.supported, !found.isEmpty else { return }
        Task { @MainActor in
            for item in found {
                busy = "Adding \(item.name)…"
                await add(from: item.folder, id: item.id, source: item.browser, confirmed: found.count > 1)
            }
            busy = nil
        }
    }

    /// Copies an unpacked extension into Companion's folder and starts it,
    /// once the user has agreed to what it may do.
    @discardableResult
    private func add(from source: URL, id given: String?, source origin: String, confirmed: Bool = false) async -> Bool {
        guard let manifest = Self.manifest(in: source) else {
            notice = "No manifest.json there, so it is not an extension."
            return false
        }
        if manifest["theme"] != nil {
            notice = "That is a Chrome theme, not an extension."
            return false
        }
        let name = Self.text(manifest["name"], in: source, manifest: manifest) ?? "Extension"
        let id = given ?? (manifest["key"] as? String).flatMap(Self.chromeID(fromKey:)) ?? Self.chromeID(of: source.path)
        let waiting = busy
        let ask = !confirmed && id != Self.iCloudPasswordsID
        if ask { busy = "Waiting for your OK to add \(name)…" }
        if ask, !Self.confirm(name: name, manifest: manifest, update: isInstalled(id)) {
            notice = "Not added: \(name) was declined."
            return false
        }

        busy = waiting == nil ? nil : "Starting \(name)…"
        let target = folder(of: id)
        let fm = FileManager.default
        if #available(macOS 15.4, *) { runtime?.unload(id) }
        try? fm.removeItem(at: target)
        do {
            try fm.copyItem(at: source, to: target)
        } catch {
            notice = "Could not copy \(name): \(error.localizedDescription)"
            return false
        }
        icons[id] = nil
        let item = Item(id: id, name: name,
                        version: manifest["version"] as? String ?? "",
                        summary: Self.text(manifest["description"], in: source, manifest: manifest) ?? "",
                        source: origin)
        if let index = items.firstIndex(where: { $0.id == id }) {
            var kept = item
            kept.pinned = items[index].pinned
            items[index] = kept
        } else {
            items.append(item)
        }
        save()
        if #available(macOS 15.4, *) { await start(id) }
        notice = items.first { $0.id == id }?.problem.map { "\(name) was added, but: \($0)" } ?? "Added \(name)."
        if id == Self.iCloudPasswordsID {
            notice = "iCloud Passwords is in the browser bar. Click it to connect with the code macOS shows."
        }
        return true
    }

    // MARK: Other browsers

    /// Chromium browsers on this Mac whose extensions can be brought over,
    /// with where each keeps its profiles.
    private static let browsers: [(name: String, path: String)] = [
        ("Google Chrome", "Google/Chrome"),
        ("Arc", "Arc/User Data"),
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Microsoft Edge", "Microsoft Edge"),
        ("Chromium", "Chromium"),
        ("Vivaldi", "Vivaldi"),
    ]

    /// The extensions installed in another browser that Companion does not
    /// have yet. Only read when the user asks to import.
    func importable() -> [Found] {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var found: [Found] = []
        var seen = Set(items.map(\.id))
        for browser in Self.browsers {
            let base = support.appendingPathComponent(browser.path, isDirectory: true)
            guard let profiles = try? fm.contentsOfDirectory(atPath: base.path) else { continue }
            for profile in profiles.sorted() where profile == "Default" || profile.hasPrefix("Profile ") {
                let extensions = base.appendingPathComponent(profile).appendingPathComponent("Extensions")
                guard let ids = try? fm.contentsOfDirectory(atPath: extensions.path) else { continue }
                for id in ids.sorted() where id.range(of: "^[a-p]{32}$", options: .regularExpression) != nil {
                    guard !seen.contains(id) else { continue }
                    let versions = (try? fm.contentsOfDirectory(at: extensions.appendingPathComponent(id),
                                                                 includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                    let newest = versions.max { a, b in
                        let one = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        let two = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        return one < two
                    }
                    guard let folder = newest, let manifest = Self.manifest(in: folder), manifest["theme"] == nil,
                          let name = Self.text(manifest["name"], in: folder, manifest: manifest) else { continue }
                    seen.insert(id)
                    found.append(Found(id: id, name: name, version: manifest["version"] as? String ?? "",
                                       folder: folder, browser: browser.name))
                }
            }
        }
        return found
    }

    // MARK: Helpers

    func icon(for id: String) -> NSImage? {
        if let image = icons[id] { return image }
        let base = folder(of: id)
        guard let manifest = Self.manifest(in: base) else { return nil }
        var candidates: [String: Any] = manifest["icons"] as? [String: Any] ?? [:]
        if candidates.isEmpty, let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any] {
            candidates = action["default_icon"] as? [String: Any] ?? [:]
        }
        let best = candidates.compactMap { key, value -> (Int, String)? in
            guard let size = Int(key), let path = value as? String else { return nil }
            return (size, path)
        }.max { $0.0 < $1.0 }
        guard let path = best?.1,
              let image = NSImage(contentsOf: base.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)) else { return nil }
        icons[id] = image
        return image
    }

    static func manifest(in folder: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else { return nil }
        // Some manifests start with a byte-order mark.
        let clean = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
        return (try? JSONSerialization.jsonObject(with: Data(clean))) as? [String: Any]
    }

    /// A manifest string, with "__MSG_name__" looked up in its locales.
    static func text(_ value: Any?, in folder: URL, manifest: [String: Any]) -> String? {
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__") else { return raw }
        let key = String(raw.dropFirst(6).dropLast(2)).lowercased()
        var locales = [Locale.current.identifier, Locale.current.language.languageCode?.identifier ?? "en"]
        if let fallback = manifest["default_locale"] as? String { locales.append(fallback) }
        locales.append("en")
        for locale in locales {
            let file = folder.appendingPathComponent("_locales").appendingPathComponent(locale).appendingPathComponent("messages.json")
            guard let data = try? Data(contentsOf: file),
                  let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for (name, entry) in messages where name.lowercased() == key {
                if let message = (entry as? [String: Any])?["message"] as? String { return message }
            }
        }
        return nil
    }

    /// Chrome's ID for an extension with a "key": the first half of the
    /// key's SHA-256, written with the letters a to p.
    static func chromeID(fromKey key: String) -> String? {
        guard let data = Data(base64Encoded: key, options: .ignoreUnknownCharacters) else { return nil }
        return letters(SHA256.hash(data: data))
    }

    /// Chrome's ID for an unpacked extension: from its folder's path.
    static func chromeID(of path: String) -> String {
        letters(SHA256.hash(data: Data(path.utf8)))
    }

    private static func letters(_ digest: SHA256.Digest) -> String {
        let alphabet = Array("abcdefghijklmnop")
        return digest.prefix(16).map { String([alphabet[Int($0 >> 4)], alphabet[Int($0 & 0x0F)]]) }.joined()
    }

    /// The zip inside a .crx (version 2 or 3).
    static func zipInside(crx data: Data) -> Data? {
        let bytes = [UInt8](data)
        func word(_ at: Int) -> Int? {
            guard bytes.count >= at + 4 else { return nil }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        guard bytes.count > 16 else { return nil }
        // Already a zip.
        if bytes[0] == 0x50, bytes[1] == 0x4B { return data }
        guard bytes[0] == 0x43, bytes[1] == 0x72, bytes[2] == 0x32, bytes[3] == 0x34, let version = word(4) else { return nil }
        let start: Int
        if version == 3, let header = word(8) {
            start = 12 + header
        } else if version == 2, let key = word(8), let signature = word(12) {
            start = 16 + key + signature
        } else {
            return nil
        }
        guard start < bytes.count else { return nil }
        return Data(bytes[start...])
    }

    /// Unzips into a new folder of its own; returns the folder holding the
    /// manifest.
    private func unzip(_ zip: Data) async -> (folder: URL, work: URL)? {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("companion-extension-" + UUID().uuidString, isDirectory: true)
        let file = work.appendingPathComponent("extension.zip")
        let out = work.appendingPathComponent("unpacked", isDirectory: true)
        do {
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            try zip.write(to: file)
        } catch { return nil }
        let result = await Shell.run("/usr/bin/ditto -x -k \(Shell.quote(file.path)) \(Shell.quote(out.path))",
                                     in: work.path, timeout: 120)
        guard result.ok else { try? fm.removeItem(at: work); return nil }
        if Self.manifest(in: out) != nil { return (out, work) }
        // A zip with one folder at its top.
        if let inner = try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil),
           inner.count == 1, Self.manifest(in: inner[0]) != nil {
            return (inner[0], work)
        }
        try? fm.removeItem(at: work)
        return nil
    }

    /// What the extension may do, in words, before it is added.
    static func abilities(_ manifest: [String: Any]) -> [String] {
        var permissions = manifest["permissions"] as? [String] ?? []
        var hosts = manifest["host_permissions"] as? [String] ?? []
        // Manifest v2 puts sites among the permissions.
        hosts += permissions.filter { $0.contains("://") || $0 == "<all_urls>" }
        permissions.removeAll { $0.contains("://") || $0 == "<all_urls>" }
        for script in manifest["content_scripts"] as? [[String: Any]] ?? [] {
            hosts += script["matches"] as? [String] ?? []
        }
        var lines: [String] = []
        let everywhere = hosts.contains { $0 == "<all_urls>" || $0.hasPrefix("*://*/") || $0.hasPrefix("http://*/") || $0.hasPrefix("https://*/") }
        if everywhere {
            lines.append("Read and change what you see on every website")
        } else if !hosts.isEmpty {
            let sites = Array(Set(hosts.compactMap { pattern -> String? in
                let host = pattern.components(separatedBy: "://").last?.components(separatedBy: "/").first ?? ""
                return host.isEmpty ? nil : host.replacingOccurrences(of: "*.", with: "")
            })).sorted()
            lines.append("Read and change what you see on " + sites.prefix(5).joined(separator: ", ")
                         + (sites.count > 5 ? " and \(sites.count - 5) more sites" : ""))
        }
        let words: [String: String] = [
            "tabs": "See your open tabs and their addresses",
            "history": "Read your browsing history",
            "bookmarks": "Read and change your bookmarks",
            "cookies": "Read and change cookies on the sites it can reach",
            "downloads": "Manage your downloads",
            "nativeMessaging": "Talk to apps on this Mac that have agreed to it",
            "clipboardRead": "Read what you copy",
            "clipboardWrite": "Change what is on the clipboard",
            "declarativeNetRequest": "Block or change content on pages",
            "declarativeNetRequestWithHostAccess": "Block or change content on pages",
            "webRequest": "See the requests pages make",
            "scripting": "Run scripts on the pages it can reach",
            "notifications": "Show notifications",
            "contextMenus": "Add items to menus",
            "webNavigation": "See where your tabs go",
            "management": "See your other extensions",
        ]
        for permission in permissions {
            if let line = words[permission], !lines.contains(line) { lines.append(line) }
        }
        return lines
    }

    private static func confirm(name: String, manifest: [String: Any], update: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = update ? "Update “\(name)”?" : "Add “\(name)” to Companion's browser?"
        let lines = abilities(manifest)
        var info = lines.isEmpty ? "It asks for no special access." : "It will be able to:\n" + lines.map { "• " + $0 }.joined(separator: "\n")
        info += "\n\nIt works in every chat's browser, including the agent's steps there. Turn it off or remove it any time in Settings > Browser."
        alert.informativeText = info
        alert.addButton(withTitle: update ? "Update" : "Add Extension")
        alert.addButton(withTitle: "Cancel")
        return run(alert)
    }

    /// Above Companion's panel while it floats (WindowStacking).
    static func run(_ alert: NSAlert) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        alert.layout()
        alert.window.level = WindowStacking.above
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Asks about access an extension wants once it is running.
    fileprivate static func allow(_ name: String, _ what: [String]) -> Bool {
        guard !what.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "“\(name)” is asking for more access"
        alert.informativeText = what.prefix(8).map { "• " + $0 }.joined(separator: "\n")
            + (what.count > 8 ? "\n• and \(what.count - 8) more" : "")
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return run(alert)
    }
}

// MARK: - WebKit's side

@available(macOS 15.4, *)
@MainActor
fileprivate final class ExtensionRuntime: NSObject, WKWebExtensionControllerDelegate {
    let controller: WKWebExtensionController
    private(set) var contexts: [String: WKWebExtensionContext] = [:]
    private var windows: [ObjectIdentifier: ExtensionWindow] = [:]
    private var tabs: [ObjectIdentifier: ExtensionTab] = [:]
    private var connections: [ObjectIdentifier: NativeHost] = [:]
    private weak var owner: BrowserExtensions?

    init(owner: BrowserExtensions) {
        self.owner = owner
        controller = WKWebExtensionController()
        super.init()
        controller.delegate = self
    }

    /// Loads one extension; returns what went wrong, if anything.
    func load(_ id: String, from folder: URL) async -> String? {
        unload(id)
        do {
            let webExtension = try await WKWebExtension(resourceBaseURL: folder)
            let context = WKWebExtensionContext(for: webExtension)
            // Its own ID, kept across launches, so its storage stays and
            // apps that name it (native messaging) recognise it.
            context.uniqueIdentifier = id
            // The user agreed to these when adding it.
            for permission in webExtension.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            for pattern in webExtension.allRequestedMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            try controller.load(context)
            contexts[id] = context
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func unload(_ id: String) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(context)
    }

    // MARK: Windows and tabs

    func window(for model: BrowserModel) -> ExtensionWindow {
        let key = ObjectIdentifier(model)
        if let window = windows[key] { return window }
        let window = ExtensionWindow(model: model, runtime: self)
        windows[key] = window
        return window
    }

    func tab(for tab: BrowserTab, in model: BrowserModel) -> ExtensionTab {
        let key = ObjectIdentifier(tab)
        if let known = tabs[key] { return known }
        let made = ExtensionTab(tab: tab, model: model, runtime: self)
        tabs[key] = made
        return made
    }

    /// The window of the chat that is showing comes first.
    var ordered: [ExtensionWindow] {
        let front = ObjectIdentifier(AppState.shared.web)
        let live = windows.filter { $0.value.model != nil }
        return live.sorted { a, _ in a.key == front }.map(\.value)
    }

    var focused: ExtensionWindow? { window(for: AppState.shared.web) }

    func opened(window model: BrowserModel) {
        guard windows[ObjectIdentifier(model)] == nil else { return }
        controller.didOpenWindow(window(for: model))
    }

    func closed(window model: BrowserModel) {
        let key = ObjectIdentifier(model)
        guard let window = windows[key] else { return }
        for tab in model.tabs { closed(tab, in: model, windowClosing: true) }
        controller.didCloseWindow(window)
        windows[key] = nil
    }

    func opened(_ tab: BrowserTab, in model: BrowserModel) {
        opened(window: model)
        controller.didOpenTab(self.tab(for: tab, in: model))
    }

    func closed(_ tab: BrowserTab, in model: BrowserModel, windowClosing: Bool) {
        guard let known = tabs.removeValue(forKey: ObjectIdentifier(tab)) else { return }
        controller.didCloseTab(known, windowIsClosing: windowClosing)
    }

    func activated(_ tab: BrowserTab?, previous: BrowserTab?, in model: BrowserModel) {
        guard let tab else { return }
        let now = self.tab(for: tab, in: model)
        let before = previous.map { self.tab(for: $0, in: model) }
        controller.didActivateTab(now, previousActiveTab: before)
        if let before { controller.didDeselectTabs([before]) }
        controller.didSelectTabs([now])
        controller.didFocusWindow(window(for: model))
    }

    func changed(_ tab: BrowserTab, _ what: BrowserExtensions.TabChange) {
        guard let known = tabs[ObjectIdentifier(tab)] else { return }
        let properties: WKWebExtension.TabChangedProperties
        switch what {
        case .url: properties = .URL
        case .title: properties = .title
        case .loading: properties = .loading
        }
        controller.didChangeTabProperties(properties, for: known)
    }

    /// A new tab in a chat's browser. An extension's own page (options, a
    /// welcome page) needs the extension's web view set-up to load.
    @discardableResult
    func newTab(in model: BrowserModel, url: URL?, context: WKWebExtensionContext) -> BrowserTab {
        if let url, url.scheme == context.baseURL.scheme, let configuration = context.webViewConfiguration {
            let tab = model.addTab(configuration: configuration)
            tab.load(url)
            return tab
        }
        let tab = model.newTab()
        if let url { tab.load(url) }
        return tab
    }

    // MARK: The bar

    func action(_ id: String, tab: BrowserTab?, in model: BrowserModel) -> WKWebExtension.Action? {
        guard let context = contexts[id] else { return nil }
        return context.action(for: tab.map { self.tab(for: $0, in: model) })
    }

    func perform(_ id: String, tab: BrowserTab?, in model: BrowserModel) {
        guard let context = contexts[id] else { return }
        let known = tab.map { self.tab(for: $0, in: model) }
        // A click is a user gesture: "activeTab" access for this page.
        if let known { context.userGesturePerformed(in: known) }
        context.performAction(for: known)
    }

    func openOptions(_ id: String, in model: BrowserModel) {
        guard let context = contexts[id], let url = context.optionsPageURL else { return }
        AppState.shared.showSide(.browser)
        newTab(in: model, url: url, context: context)
    }

    private func name(_ context: WKWebExtensionContext) -> String {
        context.webExtension.displayName ?? "An extension"
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        ordered
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        focused
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        guard let model = (configuration.window as? ExtensionWindow)?.model ?? focused?.model else {
            completionHandler(nil, nil)
            return
        }
        let previous = model.selected
        let tab = newTab(in: model, url: configuration.url, context: extensionContext)
        if !configuration.shouldBeActive, let previous { model.selected = previous }
        if configuration.shouldBeActive, model === AppState.shared.web { AppState.shared.showSide(.browser) }
        completionHandler(self.tab(for: tab, in: model), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        // Companion has one browser per chat: a "window" opens as tabs in it.
        guard let window = focused, let model = window.model else { completionHandler(nil, nil); return }
        for url in configuration.tabURLs { newTab(in: model, url: url, context: extensionContext) }
        if configuration.tabURLs.isEmpty { model.newTab() }
        if model === AppState.shared.web { AppState.shared.showSide(.browser) }
        completionHandler(window, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        if let model = focused?.model, let url = extensionContext.optionsPageURL {
            AppState.shared.showSide(.browser)
            newTab(in: model, url: url, context: extensionContext)
        }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popover = action.popupPopover, let anchor = owner?.anchor(for: context.uniqueIdentifier) else {
            completionHandler(nil)
            return
        }
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        owner?.bump()
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let ok = BrowserExtensions.allow(name(extensionContext), permissions.map { "Use “\($0.rawValue)”" }.sorted())
        completionHandler(ok ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let sites = Array(Set(urls.compactMap(\.host))).sorted()
        let ok = BrowserExtensions.allow(name(extensionContext), sites.map { "Read and change what you see on \($0)" })
        completionHandler(ok ? urls : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let ok = BrowserExtensions.allow(name(extensionContext),
                                         matchPatterns.map { "Read and change what you see on \($0.string)" }.sorted())
        completionHandler(ok ? matchPatterns : [], nil)
    }

    /// chrome.runtime.sendNativeMessage: one message to an app's host.
    func webExtensionController(_ controller: WKWebExtensionController,
                                sendMessage message: Any,
                                toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext,
                                replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        guard let name = applicationIdentifier,
              let host = NativeHost.launch(name, extensionID: extensionContext.uniqueIdentifier) else {
            replyHandler(nil, NativeHost.failure("No app on this Mac is set up to talk to this extension."))
            return
        }
        // The closures hold the host until it answers or ends, then let go.
        host.onMessage = { reply in
            host.onMessage = nil
            host.onExit = nil
            replyHandler(reply, nil)
            host.stop()
        }
        host.onExit = {
            host.onMessage = nil
            host.onExit = nil
            replyHandler(nil, NativeHost.failure("The app closed without answering."))
        }
        host.send(message)
    }

    /// chrome.runtime.connectNative: a lasting line to an app's host.
    func webExtensionController(_ controller: WKWebExtensionController,
                                connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let name = port.applicationIdentifier,
              let host = NativeHost.launch(name, extensionID: extensionContext.uniqueIdentifier) else {
            completionHandler(NativeHost.failure("No app on this Mac is set up to talk to this extension."))
            return
        }
        let key = ObjectIdentifier(port)
        connections[key] = host
        port.messageHandler = { message, _ in host.send(message) }
        port.disconnectHandler = { [weak self] _ in
            host.stop()
            MainActor.assumeIsolated { self?.connections[key] = nil }
        }
        host.onMessage = { [weak port] reply in
            MainActor.assumeIsolated { port?.sendMessage(reply, completionHandler: nil) }
        }
        host.onExit = { [weak self, weak port] in
            MainActor.assumeIsolated {
                port?.disconnect()
                self?.connections[key] = nil
            }
        }
        completionHandler(nil)
    }
}

@available(macOS 15.4, *)
@MainActor
fileprivate final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var model: BrowserModel?
    private weak var runtime: ExtensionRuntime?

    init(model: BrowserModel, runtime: ExtensionRuntime) {
        self.model = model
        self.runtime = runtime
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let model, let runtime else { return [] }
        return model.tabs.map { runtime.tab(for: $0, in: model) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let model, let runtime, let tab = model.current else { return nil }
        return runtime.tab(for: tab, in: model)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        NSApp.keyWindow?.frame ?? NSApp.windows.first?.frame ?? .zero
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        NSScreen.main?.frame ?? .zero
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if model === AppState.shared.web { AppState.shared.showSide(.browser) }
        completionHandler(nil)
    }
}

@available(macOS 15.4, *)
@MainActor
fileprivate final class ExtensionTab: NSObject, WKWebExtensionTab {
    private weak var tab: BrowserTab?
    private weak var model: BrowserModel?
    private weak var runtime: ExtensionRuntime?

    init(tab: BrowserTab, model: BrowserModel, runtime: ExtensionRuntime) {
        self.tab = tab
        self.model = model
        self.runtime = runtime
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let model else { return nil }
        return runtime?.window(for: model)
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        model?.tabs.firstIndex { $0.id == tab?.id } ?? 0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { tab?.webView }
    func title(for context: WKWebExtensionContext) -> String? { tab?.title }
    func url(for context: WKWebExtensionContext) -> URL? { tab?.webView.url }
    func isSelected(for context: WKWebExtensionContext) -> Bool { tab != nil && model?.current?.id == tab?.id }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(tab?.webView.isLoading ?? false) }

    func size(for context: WKWebExtensionContext) -> CGSize { tab?.webView.bounds.size ?? .zero }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.load(url)
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let tab, let model {
            model.selected = tab.id
            if model === AppState.shared.web { AppState.shared.showSide(.browser) }
        }
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let tab, let model { model.close(tab.id) }
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { tab?.webView.reloadFromOrigin() } else { tab?.webView.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.webView.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.webView.goForward()
        completionHandler(nil)
    }
}

// MARK: - Native messaging, the way Chrome does it

/// An app's native messaging host: found from the host file the app put
/// in Chrome's (or another Chromium browser's) folder, started only when
/// that file names this extension, and spoken to over stdin and stdout
/// with Chrome's framing (a 4-byte length, then JSON).
final class NativeHost: @unchecked Sendable {
    private let process = Process()
    private let input: FileHandle
    private var buffer = Data()
    /// Called on the main thread.
    var onMessage: ((Any) -> Void)?
    var onExit: (() -> Void)?

    static func failure(_ text: String) -> NSError {
        NSError(domain: "Companion.NativeMessaging", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    /// Where apps put their host files, in Chrome's order of lookup.
    private static var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let user = [
            "Library/Application Support/Google/Chrome/NativeMessagingHosts",
            "Library/Application Support/Chromium/NativeMessagingHosts",
            "Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts",
            "Library/Application Support/Microsoft Edge/NativeMessagingHosts",
            "Library/Application Support/Arc/User Data/NativeMessagingHosts",
        ].map { home.appendingPathComponent($0, isDirectory: true) }
        let system = [
            "/Library/Google/Chrome/NativeMessagingHosts",
            "/Library/Application Support/Chromium/NativeMessagingHosts",
            "/Library/Microsoft/Edge/NativeMessagingHosts",
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
        return user + system
    }

    static func launch(_ name: String, extensionID: String) -> NativeHost? {
        guard name.range(of: "^[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)*$", options: .regularExpression) != nil else { return nil }
        let origin = "chrome-extension://\(extensionID)/"
        for folder in folders {
            let file = folder.appendingPathComponent(name + ".json")
            guard let data = try? Data(contentsOf: file),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (manifest["type"] as? String ?? "stdio") == "stdio",
                  let path = manifest["path"] as? String,
                  (manifest["allowed_origins"] as? [String] ?? []).contains(origin) else { continue }
            let executable = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
            return try? NativeHost(executable: executable, origin: origin)
        }
        return nil
    }

    private init(executable: URL, origin: String) throws {
        let stdin = Pipe(), stdout = Pipe()
        process.executableURL = executable
        process.arguments = [origin]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.received(data)
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.onExit?() }
        }
        signal(SIGPIPE, SIG_IGN)
        try process.run()
    }

    private func received(_ data: Data) {
        buffer.append(data)
        while buffer.count >= 4 {
            let size = buffer.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            guard buffer.count >= 4 + size else { break }
            let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + size)
            buffer = Data(buffer.dropFirst(4 + size))
            guard let message = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else { continue }
            DispatchQueue.main.async { [weak self] in self?.onMessage?(message) }
        }
    }

    func send(_ message: Any?) {
        guard process.isRunning,
              let body = try? JSONSerialization.data(withJSONObject: message ?? NSNull(), options: [.fragmentsAllowed]) else { return }
        var size = UInt32(body.count).littleEndian
        var frame = Data(bytes: &size, count: 4)
        frame.append(body)
        try? input.write(contentsOf: frame)
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }
}

/// Messages from the Chrome Web Store script.
final class StoreMessages: NSObject, WKScriptMessageHandler {
    static let shared = StoreMessages()

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let webView = message.webView else { return }
        MainActor.assumeIsolated {
            BrowserExtensions.shared.storeMessage(body, from: webView)
        }
    }
}
