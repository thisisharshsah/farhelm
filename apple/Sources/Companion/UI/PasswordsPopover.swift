import AppKit
import SwiftUI
import WebKit

/// iCloud Passwords under its button in the browser bar, laid out like
/// Apple's own popup: connect with the code macOS shows, then the logins
/// saved for the site that is open, to fill with one click.
struct PasswordsPopover: View {
    @ObservedObject private var passwords = ICloudPasswords.shared
    let webView: WKWebView?
    @State private var code = ""

    private var host: String {
        guard let host = webView?.url?.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var form: (host: String, kind: ICloudPasswords.FormKind)? {
        webView.flatMap { passwords.forms[ObjectIdentifier($0)] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            content
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .onAppear { if passwords.state == .ready { passwords.loadLogins(for: form?.host ?? host) } }
        .onChange(of: passwords.state) { _, state in
            if state == .ready { passwords.loadLogins(for: form?.host ?? host) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Color.accentColor.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text("iCloud Passwords")
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        switch passwords.state {
        case .ready: return host.isEmpty ? "Connected" : host
        case .awaitingCode: return "Enter the code from macOS"
        case .needsPairing: return "Not connected"
        case .installing, .starting: return "Getting ready"
        case .notInstalled: return "Not set up"
        case .failed: return "Not working"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch passwords.state {
        case .notInstalled:
            note("Use the passwords saved in your iCloud Keychain on sign-in pages here, and save new ones.")
            action("Set Up") { passwords.install() }
        case .installing, .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                note(passwords.detail.isEmpty ? "One moment…" : passwords.detail)
            }
        case .failed(let why):
            note(why)
            if passwords.missingBrowser {
                action("Install Chrome") { passwords.installBrowser() }
            } else {
                action("Try Again") { passwords.installed ? passwords.startPairing() : passwords.install() }
            }
        case .needsPairing:
            note(passwords.detail.isEmpty
                 ? "Connect once each time Companion starts: macOS shows a 6-digit code, and you type it here."
                 : passwords.detail)
            action("Get Code") { passwords.startPairing() }
        case .awaitingCode:
            VStack(alignment: .center, spacing: 12) {
                CodeBoxes(code: $code) { digits in passwords.submit(code: digits); code = "" }
                if !passwords.detail.isEmpty {
                    note(passwords.detail)
                }
                Button("Get a New Code") { code = ""; passwords.startPairing() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            .frame(maxWidth: .infinity)
        case .ready:
            logins
        }
    }

    @ViewBuilder
    private var logins: some View {
        let site = form?.host ?? host
        let found = passwords.logins[site] ?? []
        if site.isEmpty {
            note("Open a site's sign-in page to see its logins.")
        } else if found.isEmpty {
            note(form?.kind == .new ? "No login saved for \(site) yet. After you sign up, iCloud Passwords offers to save it."
                                    : "No logins saved for \(site).")
        } else {
            VStack(spacing: 2) {
                ForEach(found) { login in
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(login.username.isEmpty ? "(no username)" : login.username)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                            Text(login.domain)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let webView, form != nil {
                            Button("Fill") { passwords.fill(login, host: site, in: webView) }
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
            if form == nil {
                note("Open the sign-in form to fill one.")
            }
        }
        if let webView, form?.kind == .new {
            action("Use a Strong Password") { passwords.suggestPassword(in: webView) }
        }
        HStack {
            Spacer()
            Button("Disconnect") { passwords.stop() }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    // MARK: Showing it

    private static var shown: NSPopover?

    /// Opens under the button, or closes if it is open.
    @MainActor
    static func toggle(webView: WKWebView?, from anchor: NSView) {
        if let open = shown, open.isShown {
            open.performClose(nil)
            shown = nil
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(rootView: PasswordsPopover(webView: webView))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        // The code is typed here, so Companion takes the keyboard.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        shown = popover
    }
}

/// Six boxes for the code, evenly spaced, typed into as one field.
private struct CodeBoxes: View {
    @Binding var code: String
    let done: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            // The field takes the typing; the boxes show it.
            TextField("", text: $code)
                .textFieldStyle(.plain)
                .foregroundStyle(.clear)
                .tint(.clear)
                .focused($focused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .onChange(of: code) { _, value in
                    let digits = String(value.filter(\.isNumber).prefix(6))
                    if digits != value { code = digits }
                    if digits.count == 6 { done(digits) }
                }
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    let characters = Array(code)
                    let filled = index < characters.count
                    let current = focused && index == min(characters.count, 5)
                    Text(filled ? String(characters[index]) : "")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .frame(width: 38, height: 46)
                        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                            .fill(Color.primary.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                            .strokeBorder(current ? Color.accentColor : Color.primary.opacity(0.18),
                                          lineWidth: current ? 2 : 1))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
        }
        .onAppear { focused = true }
    }
}
