import SwiftUI
import AppKit
import Combine

@main
struct CompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var menuBar = MenuBarPresence.shared

    var body: some Scene {
        // Out of the box Companion is only its floating panel: nothing in
        // the menu bar, nothing in the Dock. Settings > Look can show
        // either. The menu bar item is the app's one scene, inserted only
        // when asked for.
        MenuBarExtra(isInserted: Binding(get: { menuBar.shown }, set: { menuBar.set($0) })) {
            Button("Show or Hide Panel") { AppState.shared.overlay?.togglePanel() }
            Button("New Conversation") {
                AppState.shared.overlay?.showPanel()
                AppState.shared.newConversation()
            }
            Divider()
            Button("Settings") {
                AppState.shared.overlay?.showPanel()
                AppState.shared.openSettings()
            }
            Divider()
            Button("Quit Companion") { AppState.shared.requestQuit() }
        } label: {
            Image(systemName: "atom")
        }
    }
}

/// Whether the menu bar item is in. It is kept apart from the rest of the
/// settings on purpose. A menu bar item writes its state back every time
/// the app's scene is refreshed; wired straight to the settings, each write
/// announced a change, the change refreshed the scene, and the scene wrote
/// again without end, which froze the app. Here a write that changes
/// nothing is dropped, and the scene only refreshes when this one value
/// really changes.
@MainActor
final class MenuBarPresence: ObservableObject {
    static let shared = MenuBarPresence()

    @Published private(set) var shown: Bool
    private var watch: AnyCancellable?

    private init() {
        shown = AppSettings.shared.showInMenuBar
        watch = AppSettings.shared.$showInMenuBar
            .removeDuplicates()
            .sink { [weak self] value in
                Task { @MainActor in
                    guard let self, self.shown != value else { return }
                    self.shown = value
                }
            }
    }

    /// The menu bar item reporting its own state (the user can drag it out).
    func set(_ value: Bool) {
        guard value != shown else { return }
        shown = value
        if AppSettings.shared.showInMenuBar != value {
            AppSettings.shared.showInMenuBar = value
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockPresence(AppSettings.shared.showInDock)
        let overlay = OverlayController(app: AppState.shared, settings: AppSettings.shared)
        AppState.shared.overlay = overlay
        overlay.showPanel()
        Shortcuts.shared.registerAll()
        CommandRegistry.shared.registerBuiltIns()
        watchForQuit()
        dockWatch = AppSettings.shared.$showInDock
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] show in
                Task { @MainActor in self?.applyDockPresence(show) }
            }
    }

    private var dockWatch: AnyCancellable?

    /// In the Dock like an ordinary app, or out of it. Clicking the Dock
    /// icon brings the panel back (see `applicationShouldHandleReopen`).
    private func applyDockPresence(_ show: Bool) {
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        // Leaving the Dock can drop the app's windows back; keep the panel
        // where it was.
        if AppState.shared.panelVisible {
            AppState.shared.overlay?.showPanel()
        }
    }

    /// Cmd+Q quits Companion completely, but only while its panel is the
    /// window in use: it is not a global shortcut, so Cmd+Q in any other
    /// app still quits that app and never this one. It asks once when
    /// Companion is busy (see `AppState.requestQuit`).
    private func watchForQuit() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // A command's own keys come first: the palette, the sidebar,
            // a new conversation and the rest.
            if CommandRegistry.shared.handle(event) { return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Cmd+Plus, Cmd+Minus and Cmd+0 make the content larger,
            // smaller, and the usual size again, as in a browser. (Plus is
            // on the = key, so Shift may or may not be held.)
            if flags == .command || flags == [.command, .shift] {
                switch event.keyCode {
                case 24, 69:
                    AppSettings.shared.zoom(1)
                    return nil
                case 27, 78:
                    AppSettings.shared.zoom(-1)
                    return nil
                case 29 where flags == .command:
                    AppSettings.shared.zoom(0)
                    return nil
                default:
                    break
                }
            }
            // Companion has no main menu, so the usual Edit menu shortcuts
            // (Cut, Copy, Paste, Select All, Undo, Redo) are never routed
            // to the text field on their own. Send them to the focused
            // field here, as the Edit menu would.
            if flags == .command || flags == [.command, .shift] {
                var action: Selector?
                switch (event.charactersIgnoringModifiers?.lowercased(), flags == .command) {
                case ("x", true): action = #selector(NSText.cut(_:))
                case ("c", true): action = #selector(NSText.copy(_:))
                case ("v", true): action = #selector(NSText.paste(_:))
                case ("a", true): action = #selector(NSResponder.selectAll(_:))
                case ("z", true): action = Selector(("undo:"))
                case ("z", false): action = Selector(("redo:"))
                default: break
                }
                // A picture or files on the clipboard are attached rather
                // than pasted as text.
                if action == #selector(NSText.paste(_:)), AppState.shared.pasteAttachments() {
                    return nil
                }
                if let action, NSApp.sendAction(action, to: nil, from: nil) {
                    return nil
                }
            }
            guard event.keyCode == 12, flags == .command else { return event }
            AppState.shared.requestQuit()
            return nil
        }
    }

    /// Opening Companion again while it is running (from Spotlight, Finder
    /// or Launchpad) brings the panel back. With no menu bar icon, this and
    /// the shortcut are the ways to find a hidden panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppState.shared.overlay?.showPanel()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.persist()
    }
}
