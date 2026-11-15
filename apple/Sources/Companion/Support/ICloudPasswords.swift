import AppKit
import Foundation
import WebKit

/// iCloud Passwords in Companion's browser: logins saved in iCloud Keychain
/// offered on sign-in pages, and new ones saved there on sign-up.
///
/// macOS lets only approved browsers talk to its iCloud Passwords helper,
/// so this works the way apwlib (MIT, github.com/michel-tricot/apwcli)
/// does: a hidden Chrome hosts Apple's own iCloud Passwords extension, and
/// a small bridge talks to it on this Mac. Pairing takes the 6-digit code
/// macOS shows, once each time the hidden Chrome starts. This is not an
/// API Apple publishes, so an update to macOS or the extension can break it.
///
/// Passwords go from the bridge straight into the page. They are never
/// shown in the chat, given to the model, written to a log or kept on disk
/// by Companion.
@MainActor
final class ICloudPasswords: ObservableObject {
    static let shared = ICloudPasswords()

    enum State: Equatable {
        case notInstalled, installing, starting, needsPairing, awaitingCode, ready
        case failed(String)
    }

    struct Login: Identifiable, Hashable {
        let username: String
        let domain: String
        var id: String { domain + "\u{1}" + username }
    }

    /// What the page script reported: a sign-in form, a sign-up form.
    enum FormKind: String { case login, new }

    @Published private(set) var state = State.notInstalled
    @Published private(set) var detail = ""
    /// The kind of password form showing, by web view.
    @Published private(set) var forms: [ObjectIdentifier: (host: String, kind: FormKind)] = [:]
    /// Logins found for a site, by host.
    @Published private(set) var logins: [String: [Login]] = [:]
    /// A login typed into a page, waiting for "Save" or "Not now". The
    /// password is held only until then.
    @Published private(set) var offer: (webView: ObjectIdentifier, host: String, username: String, update: Bool)?
    private var offeredPassword = ""
    /// No browser macOS lets talk to iCloud Passwords is installed.
    @Published private(set) var missingBrowser = false

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<[String: Any]?, Never>] = [:]

    // MARK: Where the bridge lives

    private var home: URL {
        ContextStore.shared.baseDir.appendingPathComponent("icloud-passwords", isDirectory: true)
    }
    /// The Python the app carries, with apwlib in it (build.sh puts it in
    /// Contents/Resources/Python), so nothing is installed on this Mac.
    /// A build without it falls back to one installed into Companion's folder.
    private var bundledPython: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Python/bin/python3"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }
    private var python: URL { bundledPython ?? home.appendingPathComponent(".venv/bin/python") }
    private var script: URL { home.appendingPathComponent("bridge.py") }

    var installed: Bool { FileManager.default.isExecutableFile(atPath: python.path) }

    init() {
        state = installed ? .needsPairing : .notInstalled
    }

    /// Installs the bridge: a private Python with apwlib, pinned to the
    /// version this was written against. uv is used when it is there (it
    /// fetches a Python of its own); otherwise a Python 3.12 or later.
    func install() {
        guard state != .installing else { return }
        state = .installing
        detail = "Installing apwlib 0.1.2 into Companion's own folder…"
        let folder = home
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let venv = Shell.quote(folder.appendingPathComponent(".venv").path)
            let command = """
            if command -v uv >/dev/null 2>&1; then
              uv venv --python 3.12 \(venv) && uv pip install --python \(venv)/bin/python 'apwlib==0.1.2'
            else
              for p in python3.13 python3.12 python3; do
                if command -v $p >/dev/null 2>&1 && $p -c 'import sys; sys.exit(0 if sys.version_info >= (3,12) else 1)'; then
                  $p -m venv \(venv) && \(venv)/bin/pip install --quiet 'apwlib==0.1.2'; exit $?
                fi
              done
              echo "Needs Python 3.12 or later. Install uv (brew install uv) or Python 3.12, then try again."; exit 1
            fi
            """
            let result = await Shell.run(command, in: folder.path, timeout: 900)
            OutputLog.shared.append("iCloud Passwords", command: "install apwlib", ok: result.ok, result.output)
            guard result.ok, installed else {
                state = .failed(result.output.contains("Needs Python")
                                ? "Needs Python 3.12 or later. Install uv (brew install uv), then try again."
                                : "Could not install apwlib. The Output tab has what happened.")
                return
            }
            state = .needsPairing
            detail = ""
            await connect()
        }
    }

    // MARK: The bridge process

    private static let bridgeSource = #"""
    # Companion's bridge to iCloud Passwords, through apwlib. One JSON request
    # per line on stdin, one JSON answer per line on stdout. Nothing is logged.
    import json, sys
    from apwlib import ApplePasswords, Daemon
    from apwlib import ApwError, SessionError, NotPairedError

    daemon = Daemon()
    client = None

    def out(message):
        sys.stdout.write(json.dumps(message, default=str) + "\n")
        sys.stdout.flush()

    def passwords():
        global client
        if client is None:
            client = ApplePasswords()
        return client

    for line in sys.stdin:
        request = {}
        try:
            request = json.loads(line)
            command = request.get("cmd")
            if command == "status":
                daemon.start()
                result = daemon.status()
            elif command == "challenge":
                daemon.start()
                daemon.request_challenge()
                result = True
            elif command == "verify":
                result = bool(daemon.verify_challenge(str(request["pin"])))
            elif command == "list":
                result = [{"username": e.username, "domain": e.domain}
                          for e in passwords().get_password(request["domain"])]
            elif command == "get":
                result = [{"username": e.username, "domain": e.domain, "password": e.password}
                          for e in passwords().get_password(request["domain"], request.get("username") or None)]
            elif command == "save":
                passwords().save_password(request["domain"], request["username"], request["password"])
                result = True
            elif command == "otp":
                result = [{"username": c.username, "domain": c.domain, "code": c.code}
                          for c in passwords().get_otp(request["domain"])]
            else:
                raise ValueError("unknown command")
            out({"id": request.get("id"), "ok": True, "result": result})
        except NotPairedError as error:
            out({"id": request.get("id"), "ok": False, "error": "not_paired", "message": str(error)})
        except SessionError as error:
            client = None
            out({"id": request.get("id"), "ok": False, "error": "session", "message": str(error)})
        except Exception as error:
            out({"id": request.get("id"), "ok": False, "error": type(error).__name__, "message": str(error)})
    """#

    /// Starts the bridge (and through it the hidden Chrome) and finds out
    /// whether it is paired.
    func connect() async {
        guard installed else { state = .notInstalled; return }
        guard Self.hasApprovedBrowser else {
            missingBrowser = true
            state = .failed(Self.browserNote)
            return
        }
        missingBrowser = false
        addArc()
        if process?.isRunning != true {
            guard startProcess() else { state = .failed("The bridge could not be started."); return }
        }
        state = .starting
        detail = "Starting iCloud Passwords…"
        guard let answer = await request("status", timeout: 90) else {
            if Self.onlyArc {
                missingBrowser = true
                state = .failed(Self.arcNote)
            } else {
                state = .failed("iCloud Passwords did not answer. It needs Chrome, Brave or Edge installed.")
            }
            return
        }
        guard answer["ok"] as? Bool == true else {
            let text = message(answer)
            if Self.onlyArc {
                missingBrowser = true
                state = .failed(Self.arcNote)
            } else if text.contains("supported browser") {
                missingBrowser = true
                state = .failed(Self.browserNote)
            } else {
                state = .failed(text)
            }
            return
        }
        let status = answer["result"] as? [String: Any] ?? [:]
        state = (status["paired"] as? Bool == true) ? .ready : .needsPairing
        detail = ""
    }

    private func startProcess() -> Bool {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? Self.bridgeSource.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = python
        process.arguments = ["-u", script.path]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.received(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                for (_, waiter) in self.waiting { waiter.resume(returning: nil) }
                self.waiting = [:]
                if self.state == .ready { self.state = .needsPairing }
            }
        }
        signal(SIGPIPE, SIG_IGN)
        do { try process.run() } catch { return false }
        self.process = process
        input = stdin.fileHandleForWriting
        return true
    }

    func stop() {
        process?.terminate()
        process = nil
        if installed { state = .needsPairing }
    }

    private func request(_ command: String, _ arguments: [String: Any] = [:], timeout: Double = 30) async -> [String: Any]? {
        guard let input else { return nil }
        let id = nextID
        nextID += 1
        var message = arguments
        message["id"] = id
        message["cmd"] = command
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        data.append(0x0A)
        return await withCheckedContinuation { (done: CheckedContinuation<[String: Any]?, Never>) in
            waiting[id] = done
            do { try input.write(contentsOf: data) } catch {
                waiting.removeValue(forKey: id)?.resume(returning: nil)
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let late = self.waiting.removeValue(forKey: id) { late.resume(returning: nil) }
            }
        }
    }

    private func received(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = message["id"] as? Int else { continue }
            waiting.removeValue(forKey: id)?.resume(returning: message)
        }
    }

    private func message(_ answer: [String: Any]) -> String {
        let text = answer["message"] as? String ?? ""
        return text.isEmpty ? "iCloud Passwords could not do that." : String(text.prefix(300))
    }

    /// An answer that says the pairing is gone sends it back to pairing.
    private func checkPaired(_ answer: [String: Any]?) -> Bool {
        guard let answer else { return false }
        if answer["ok"] as? Bool == true { return true }
        if ["not_paired", "session"].contains(answer["error"] as? String ?? "") {
            state = .needsPairing
            detail = "iCloud Passwords needs pairing again."
        } else {
            detail = message(answer)
        }
        return false
    }

    // MARK: The browser it needs

    /// macOS's iCloud Passwords helper answers only Apple's list of
    /// browsers, and apwlib looks for them in /Applications.
    static let approvedBrowsers = [
        "/Applications/Google Chrome.app",
        "/Applications/Chromium.app",
        "/Applications/Brave Browser.app",
        "/Applications/Microsoft Edge.app",
        // Arc is Chromium and runs Apple's extension too (as Arc's own
        // help says); apwlib does not list it, so Companion adds it.
        "/Applications/Arc.app",
    ]

    /// Arc is the only one there: if it cannot host the extension
    /// hidden, Chrome is the way.
    static var onlyArc: Bool {
        approvedBrowsers.filter { FileManager.default.fileExists(atPath: $0) } == ["/Applications/Arc.app"]
    }

    static let arcNote = "Arc could not run iCloud Passwords hidden for Companion. Install Chrome for this; it stays hidden and you keep browsing in Companion and Arc."

    /// Teaches apwlib about Arc: a small module in Companion's own Python
    /// that adds Arc to the browsers it may use (after Chrome, Chromium,
    /// Brave and Edge). The daemon's Python loads it too.
    private func addArc() {
        // The bundled Python has it already.
        guard bundledPython == nil,
              let source = Bundle.main.url(forResource: "companion_arc", withExtension: "py") else { return }
        let fm = FileManager.default
        let lib = home.appendingPathComponent(".venv/lib")
        guard let python = (try? fm.contentsOfDirectory(atPath: lib.path))?.first(where: { $0.hasPrefix("python") }) else { return }
        let site = lib.appendingPathComponent(python).appendingPathComponent("site-packages")
        guard fm.fileExists(atPath: site.path) else { return }
        try? fm.removeItem(at: site.appendingPathComponent("companion_arc.py"))
        try? fm.copyItem(at: source, to: site.appendingPathComponent("companion_arc.py"))
        try? "import companion_arc\n".write(to: site.appendingPathComponent("companion_arc.pth"), atomically: true, encoding: .utf8)
    }

    static var hasApprovedBrowser: Bool {
        approvedBrowsers.contains { FileManager.default.fileExists(atPath: $0) }
    }

    static let browserNote = "iCloud Passwords needs Chrome, Arc, Brave or Edge in Applications: macOS lets only those talk to it (Safari's is built in). Companion can install Chrome for you; it stays hidden and is used only for this."

    /// Installs Google Chrome (with Homebrew when it is there, else
    /// Google's own disk image), then starts iCloud Passwords.
    func installBrowser() {
        guard state != .installing else { return }
        state = .installing
        detail = "Installing Google Chrome…"
        Task { @MainActor in
            let command = """
            set -e
            BREW=$(command -v brew || ls /opt/homebrew/bin/brew /usr/local/bin/brew 2>/dev/null | head -1 || true)
            if [ -n "$BREW" ]; then
              "$BREW" install --cask google-chrome
            else
              T=$(mktemp -d)
              curl -fsSL -o "$T/chrome.dmg" https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg
              hdiutil attach -nobrowse -quiet -mountpoint "$T/mnt" "$T/chrome.dmg"
              ditto "$T/mnt/Google Chrome.app" "/Applications/Google Chrome.app"
              hdiutil detach -quiet "$T/mnt"
              rm -rf "$T"
            fi
            """
            let result = await Shell.run(command, in: NSHomeDirectory(), timeout: 1500)
            OutputLog.shared.append("iCloud Passwords", command: "install Google Chrome", ok: result.ok, result.output)
            guard Self.hasApprovedBrowser else {
                state = .failed("Chrome could not be installed. The Output tab has what happened; installing Chrome from google.com/chrome works too.")
                return
            }
            missingBrowser = false
            detail = ""
            state = installed ? .needsPairing : .notInstalled
            if installed { await connect() } else { install() }
        }
    }

    // MARK: Pairing

    /// Asks macOS for a code; it shows a 6-digit code to type in here.
    func startPairing() {
        Task { @MainActor in
            if process?.isRunning != true { await connect() }
            guard state == .needsPairing || state == .ready || state == .awaitingCode else { return }
            detail = "Asking macOS for a code…"
            let answer = await request("challenge", timeout: 60)
            guard answer?["ok"] as? Bool == true else {
                state = .failed(answer.map(message) ?? "macOS did not show a code.")
                return
            }
            state = .awaitingCode
            detail = "Type the 6-digit code macOS shows."
        }
    }

    func submit(code: String) {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { detail = "The code has 6 digits."; return }
        Task { @MainActor in
            detail = "Pairing…"
            let answer = await request("verify", ["pin": digits], timeout: 60)
            if answer?["ok"] as? Bool == true, answer?["result"] as? Bool == true {
                state = .ready
                detail = ""
                logins = [:]
            } else {
                state = .needsPairing
                detail = "That code did not work. Ask for a new one."
            }
        }
    }

    // MARK: Logins

    /// The logins saved for a site (names only).
    func loadLogins(for host: String) {
        guard state == .ready, !host.isEmpty else { return }
        Task { @MainActor in
            let answer = await request("list", ["domain": host])
            guard checkPaired(answer) else { return }
            let list = (answer?["result"] as? [[String: Any]] ?? []).map {
                Login(username: $0["username"] as? String ?? "", domain: $0["domain"] as? String ?? host)
            }
            logins[host] = list
        }
    }

    /// Fills a saved login into the page: the password goes from iCloud
    /// Passwords into the page's field and nowhere else.
    func fill(_ login: Login, host: String, in webView: WKWebView) {
        fill(login, host: host, page: webView)
    }

    func fill(_ login: Login, host: String, page: PasswordPage) {
        Task { @MainActor in
            let answer = await request("get", ["domain": host, "username": login.username])
            guard checkPaired(answer),
                  let entry = (answer?["result"] as? [[String: Any]])?.first,
                  let password = entry["password"] as? String else {
                if state == .ready { detail = "iCloud Passwords did not give the password for \(login.username)." }
                return
            }
            await page.runPasswordScript("return window.__companionFill && window.__companionFill(u, p)",
                                         ["u": login.username, "p": password])
        }
    }

    /// Fills a new strong password into a sign-up form.
    func suggestPassword(in webView: WKWebView) {
        suggestPassword(page: webView)
    }

    func suggestPassword(page: PasswordPage) {
        let password = Self.strongPassword()
        Task { @MainActor in
            await page.runPasswordScript("return window.__companionFill && window.__companionFill('', p, true)", ["p": password])
        }
    }

    /// Apple's style: three groups of six letters and digits, with hyphens.
    static func strongPassword() -> String {
        let letters = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        func group() -> String {
            var bytes = [UInt8](repeating: 0, count: 6)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return String(bytes.map { letters[Int($0) % letters.count] })
        }
        return [group(), group(), group()].joined(separator: "-")
    }

    // MARK: From the page

    /// What the page script reports.
    func handle(_ body: [String: Any], from webView: WKWebView) {
        handle(body, page: webView)
    }

    func handle(_ body: [String: Any], page: PasswordPage) {
        let id = page.passwordID
        let host = body["host"] as? String ?? ""
        switch body["type"] as? String {
        case "form":
            if let kind = FormKind(rawValue: body["kind"] as? String ?? "") {
                forms[id] = (host, kind)
                if logins[host] == nil { loadLogins(for: host) }
            } else {
                forms[id] = nil
            }
        case "submit":
            let username = body["username"] as? String ?? ""
            let password = body["password"] as? String ?? ""
            guard state == .ready, !host.isEmpty, !password.isEmpty else { return }
            Task { @MainActor in
                // Already saved as it is: nothing to ask.
                let answer = await request("get", ["domain": host, "username": username])
                let saved = (answer?["result"] as? [[String: Any]])?.first
                if let same = saved?["password"] as? String, same == password { return }
                offeredPassword = password
                offer = (id, host, username, saved != nil)
            }
        default:
            break
        }
    }

    func saveOffer() {
        guard let offer else { return }
        let password = offeredPassword
        offeredPassword = ""
        self.offer = nil
        Task { @MainActor in
            let answer = await request("save", ["domain": offer.host, "username": offer.username, "password": password])
            if checkPaired(answer) {
                detail = "Saved to iCloud Passwords."
                logins[offer.host] = nil
                loadLogins(for: offer.host)
            }
        }
    }

    func dismissOffer() {
        offeredPassword = ""
        offer = nil
    }

    func forget(_ webView: WKWebView) {
        forms[ObjectIdentifier(webView)] = nil
    }

    func forget(page: PasswordPage) {
        forms[page.passwordID] = nil
    }

    // MARK: The page script

    /// Finds password forms, fills them, and reports a login as it is sent.
    static let pageScript = #"""
    (() => {
      if (window.__companionPasswords) return;
      window.__companionPasswords = true;
      const post = (m) => { try { window.webkit.messageHandlers.companionPasswords.postMessage(m); } catch (e) {} };
      const visible = (el) => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
      const passwords = () => Array.from(document.querySelectorAll('input[type=password]')).filter(visible);
      const userish = 'input[type=email],input[type=text],input[type=tel],input:not([type])';
      const userField = (pw) => {
        const scope = pw.form || document;
        const all = Array.from(scope.querySelectorAll(userish)).filter(visible);
        let best = null;
        for (const el of all) {
          if (el.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING) best = el;
        }
        return best || all[0] || null;
      };
      // A username typed on one page and the password on the next.
      document.addEventListener('change', (e) => {
        const el = e.target;
        if (el && el.matches && el.matches(userish) && el.value && /mail|user|login|id/i.test((el.name || '') + (el.id || '') + (el.autocomplete || '') + (el.type || ''))) {
          try { sessionStorage.setItem('__companionUser', el.value); } catch (x) {}
        }
      }, true);
      let reported = null;
      const report = () => {
        const list = passwords();
        let kind = '';
        if (list.length) {
          const isNew = list.length > 1 || list.some((x) => (x.autocomplete || '').includes('new-password'));
          kind = isNew ? 'new' : 'login';
        }
        if (kind !== reported) { reported = kind; post({ type: 'form', kind, host: location.hostname }); }
      };
      let sent = '';
      const capture = () => {
        const list = passwords().filter((x) => x.value);
        if (!list.length) return;
        const pw = list[list.length > 1 ? 1 : 0];
        const user = userField(pw);
        let name = user && user.value ? user.value : '';
        if (!name) { try { name = sessionStorage.getItem('__companionUser') || ''; } catch (x) {} }
        const key = name + '\u0001' + pw.value;
        if (key === sent) return;
        sent = key;
        post({ type: 'submit', host: location.hostname, username: name, password: pw.value });
      };
      document.addEventListener('submit', capture, true);
      document.addEventListener('click', (e) => {
        const target = e.target && e.target.closest ? e.target.closest('button,input[type=submit],[role=button]') : null;
        if (target) setTimeout(capture, 0);
      }, true);
      document.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && e.target && e.target.type === 'password') capture();
      }, true);
      window.__companionFill = (user, pass, allNew) => {
        const list = passwords();
        if (!list.length) return false;
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        const put = (el, value) => {
          el.focus();
          setter.call(el, value);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        };
        const userEl = userField(list[0]);
        if (user && userEl && !userEl.value) put(userEl, user);
        if (allNew) { list.forEach((el) => put(el, pass)); } else { put(list[0], pass); }
        return true;
      };
      new MutationObserver(report).observe(document.documentElement, { childList: true, subtree: true });
      report();
    })();
    """#

    /// Adds the script and its message channel to a browser configuration.
    static func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: pageScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.add(PasswordMessages.shared, name: "companionPasswords")
    }
}

/// The page script's messages, handed to iCloud Passwords.
final class PasswordMessages: NSObject, WKScriptMessageHandler {
    static let shared = PasswordMessages()

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let webView = message.webView else { return }
        MainActor.assumeIsolated {
            ICloudPasswords.shared.handle(body, from: webView)
        }
    }
}


/// A page iCloud Passwords works on: a WebKit tab, or a Chromium tab.
/// The page script reports its forms (by `passwordID`) and fills them.
@MainActor
protocol PasswordPage: AnyObject {
    var passwordID: ObjectIdentifier { get }
    /// Runs a function body in the page with these arguments (JSON values).
    func runPasswordScript(_ body: String, _ arguments: [String: Any]) async
}

extension WKWebView: PasswordPage {
    var passwordID: ObjectIdentifier { ObjectIdentifier(self) }

    func runPasswordScript(_ body: String, _ arguments: [String: Any]) async {
        _ = try? await callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
    }
}
