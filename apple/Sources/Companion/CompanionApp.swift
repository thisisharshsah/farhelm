import SwiftUI
import AppKit

@main
struct CompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(AppState.shared)
                .environmentObject(AppSettings.shared)
        } label: {
            MenuBarIcon()
        }

        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let overlay = OverlayController(app: AppState.shared, settings: AppSettings.shared)
        AppState.shared.overlay = overlay
        overlay.showPanel()
        HotKeys.registerAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.persist()
    }
}

struct MenuBarIcon: View {
    @ObservedObject var app = AppState.shared

    var body: some View {
        Image(systemName: app.isListening ? "waveform.circle.fill" : "waveform.circle")
    }
}

struct MenuContent: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Button(app.isListening ? "Stop Listening" : "Start Listening") {
            app.toggleListening()
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])

        Button(app.panelVisible ? "Hide Panel" : "Show Panel") {
            app.overlay?.togglePanel()
        }
        Toggle("Click-Through Panel", isOn: $app.clickThrough)
            .keyboardShortcut("t", modifiers: [.command, .shift])
        Button("Reset Overlay Position") {
            app.overlay?.resetPositions()
        }

        Divider()

        Button("Suggest Reply Now") { app.suggestNow() }
        Button("Answer Screen Question") { app.answerScreenNow() }
        Button("New Conversation") { app.newConversation() }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        Button("Recheck Transcript") { app.rescanTranscript() }
            .disabled(app.isRescanning)
        Button("Clear Transcript") { app.clearTranscript() }

        Divider()

        Picker("Reply Engine", selection: $settings.provider) {
            ForEach(LLMProviderKind.allCases) { kind in
                Text(kind.label).tag(kind)
            }
        }
        Toggle("Auto-Suggest Replies", isOn: $settings.autoSuggest)
        Toggle("Watch Screen for Questions", isOn: $settings.autoScreenWatch)
        Picker("Monitor to Read", selection: $settings.screenDisplayID) {
            Text("Automatic (where the pointer is)").tag(0)
            ForEach(ScreenReader.screens()) { screen in
                Text(screen.name).tag(screen.id)
            }
            // A saved monitor that is not connected right now.
            if settings.screenDisplayID != 0,
               !ScreenReader.screens().contains(where: { $0.id == settings.screenDisplayID }) {
                Text("Disconnected monitor").tag(settings.screenDisplayID)
            }
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Button("Quit Companion") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
