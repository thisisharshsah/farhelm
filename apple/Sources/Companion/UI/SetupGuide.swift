import SwiftUI
import AppKit
import Combine
import AVFoundation
import CoreGraphics

/// A checklist of what Companion needs before it can help, each with the one
/// button that fixes it. Shown in the panel until the essentials are done.
struct SetupGuide: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var screenAllowed = CGPreflightScreenCaptureAccess()
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Whether the essentials (microphone and an AI model) are in place.
    @MainActor
    static var essentialsDone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && modelConfigured
    }

    @MainActor
    static var modelConfigured: Bool {
        let env = ProcessInfo.processInfo.environment
        func has(_ account: String, _ variable: String) -> Bool {
            !(Keychain.read(account) ?? env[variable] ?? "").isEmpty
        }
        switch AppSettings.shared.provider {
        case .farhelm: return has("farhelm", "FARHELM_API_KEY")
        case .anthropic: return has("anthropic", "ANTHROPIC_API_KEY")
        case .openai: return has("openai", "OPENAI_API_KEY")
        case .ollama: return true
        // The tool holds its own sign-in; choosing it is all there is to do here.
        case .subscription: return true
        }
    }

    private var doneCount: Int {
        [micStatus == .authorized, screenAllowed, Self.modelConfigured,
         !settings.userDetails.isEmpty, app.voiceEnrolled].filter { $0 }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Label("Get set up", systemImage: "checklist")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.95))
                Text("\(doneCount) of 5 done")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.ink.opacity(0.5))
                Spacer(minLength: 4)
                Button("Hide") { settings.setupDismissed = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.6))
            }

            row(done: micStatus == .authorized,
                title: "Microphone",
                detail: "So Companion can hear the conversation.") {
                if micStatus == .notDetermined {
                    action("Allow") {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in
                            Task { @MainActor in micStatus = AVCaptureDevice.authorizationStatus(for: .audio) }
                        }
                    }
                } else {
                    action("Open Settings") { openPrivacy("Privacy_Microphone") }
                }
            }
            row(done: Self.modelConfigured,
                title: "AI model",
                detail: "Pick an engine and add its key. This writes the replies.") {
                settingsLink("Engine")
            }
            row(done: !settings.userDetails.isEmpty,
                title: "Your details",
                detail: "Your background, resume or product notes, so replies sound like you.") {
                settingsLink("You")
            }
            row(done: screenAllowed,
                title: "Screen Recording",
                detail: "Optional. Needed to hear call audio from the Mac and to answer what is on screen. Relaunch after allowing.") {
                action("Allow") {
                    _ = CGRequestScreenCaptureAccess()
                    openPrivacy("Privacy_ScreenCapture")
                }
            }
            row(done: app.voiceEnrolled,
                title: "Your voice",
                detail: "Optional. Lets Companion tell you apart from other people on the microphone.") {
                settingsLink("Listening")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .fill(Theme.shade.opacity(0.28)))
        .glassBorder(radius: Theme.cardRadius, tint: Theme.accent)
        .onReceive(refresh) { _ in
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            screenAllowed = CGPreflightScreenCaptureAccess()
        }
    }

    private func row<Action: View>(done: Bool,
                                   title: String,
                                   detail: String,
                                   @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(done ? Theme.mint : Theme.ink.opacity(0.35))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(done ? 0.6 : 0.95))
                if !done {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            if !done {
                action()
            }
        }
    }

    private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Chip(title, tint: Theme.accent)
        }
        .buttonStyle(.plain)
    }

    private func settingsLink(_ tab: String) -> some View {
        Button {
            AppState.shared.openSettings(tab: tab)
        } label: {
            Chip("Open Settings", tint: Theme.accent)
        }
        .buttonStyle(.plain)
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Close, minimize and enlarge, drawn to match the macOS window buttons:
/// the system's colors, size and spacing, a tone-on-tone rim, glyphs that
/// appear for all three when the pointer is over the group, and a darker
/// face while pressed. (The panel is a borderless floating window, so the
/// system does not supply its own.) Close hides the panel (the circle brings
/// it back), minimize shrinks it to a strip with just the newest answer,
/// enlarge fills most of the screen and toggles back.
struct WindowControls: View {
    @EnvironmentObject var app: AppState
    @State private var hover = false

    private enum Light {
        case close, minimize, zoom

        var face: Color {
            switch self {
            case .close: return Color(red: 1.0, green: 0.373, blue: 0.341)
            case .minimize: return Color(red: 0.996, green: 0.737, blue: 0.180)
            case .zoom: return Color(red: 0.157, green: 0.784, blue: 0.251)
            }
        }

        var rim: Color {
            switch self {
            case .close: return Color(red: 0.878, green: 0.267, blue: 0.243)
            case .minimize: return Color(red: 0.871, green: 0.631, blue: 0.137)
            case .zoom: return Color(red: 0.102, green: 0.671, blue: 0.161)
            }
        }

        var glyph: Color {
            switch self {
            case .close: return Color(red: 0.30, green: 0.0, blue: 0.0)
            case .minimize: return Color(red: 0.36, green: 0.23, blue: 0.0)
            case .zoom: return Color(red: 0.04, green: 0.36, blue: 0.06)
            }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            light(.close, help: "Close the panel (\(Shortcuts.shared.label(.panel)) brings it back)") {
                app.overlay?.hidePanel()
            }
            light(.minimize,
                  help: app.compact ? "Back to the full panel" : "Minimize to a small strip with the newest answer") {
                app.overlay?.setCompact(!app.compact)
            }
            light(.zoom, help: app.zoomed ? "Back to the normal size" : "Enlarge") {
                app.overlay?.toggleZoom()
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    private func light(_ kind: Light, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            glyph(kind)
                .opacity(hover ? 0.78 : 0)
                .frame(width: 12, height: 12)
        }
        .buttonStyle(LightStyle(face: kind.face, rim: kind.rim))
        .help(help)
    }

    @ViewBuilder
    private func glyph(_ kind: Light) -> some View {
        switch kind {
        case .close:
            Image(systemName: "xmark")
                .font(.system(size: 6.5, weight: .heavy))
                .foregroundStyle(kind.glyph)
        case .minimize:
            Capsule()
                .fill(kind.glyph)
                .frame(width: 7.5, height: 1.6)
        case .zoom:
            // The system's enlarge glyph: two triangles pointing at
            // opposite corners.
            Path { path in
                path.move(to: CGPoint(x: 3.4, y: 3.4))
                path.addLine(to: CGPoint(x: 7.4, y: 3.4))
                path.addLine(to: CGPoint(x: 3.4, y: 7.4))
                path.closeSubpath()
                path.move(to: CGPoint(x: 8.6, y: 8.6))
                path.addLine(to: CGPoint(x: 4.6, y: 8.6))
                path.addLine(to: CGPoint(x: 8.6, y: 4.6))
                path.closeSubpath()
            }
            .fill(kind.glyph)
        }
    }

    private struct LightStyle: ButtonStyle {
        let face: Color
        let rim: Color

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(Circle().fill(face))
                .overlay(Circle().strokeBorder(rim, lineWidth: 0.5))
                .overlay(Circle().fill(Color.black.opacity(configuration.isPressed ? 0.22 : 0)))
                .contentShape(Circle())
        }
    }
}
