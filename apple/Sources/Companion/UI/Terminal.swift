import AppKit
import SwiftTerm
import SwiftUI

/// A real terminal in the workspace: the user's own shell running in a
/// pseudo-terminal, drawn by SwiftTerm. Anything that runs in Terminal runs
/// here the same way: programs that ask for input, editors, progress bars,
/// colors, Ctrl+C.
///
/// One session belongs to one folder. It keeps running while the panel is
/// closed or another tab is showing, so nothing is lost by looking away.
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    /// The folder the shell started in.
    let folder: String
    let view: LocalProcessTerminalView
    /// What the shell calls itself now (the program running, the folder).
    @Published private(set) var title = ""
    /// The shell has exited; it can be started again.
    @Published private(set) var ended = false
    /// Told when what the shell did may have changed the folder.
    var changed: () -> Void = {}

    init(folder: String) {
        self.folder = folder
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        super.init()
        view.processDelegate = self
        start()
    }

    /// Starts the user's shell as a login shell, so it reads the same
    /// profile Terminal does and finds the same programs.
    func start() {
        ended = false
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let name = "-" + (shell as NSString).lastPathComponent
        let start = FileManager.default.fileExists(atPath: folder) ? folder : NSHomeDirectory()
        view.startProcess(executable: shell, args: [], environment: nil, execName: name, currentDirectory: start)
    }

    func end() {
        view.terminate()
    }

    /// The look follows the panel's: light or dark, and the content zoom.
    /// The terminal's own background is see-through, so it sits on the same
    /// glass as the rest of the app instead of on a solid block of its own.
    /// Text takes the app's ink color.
    func restyle(light: Bool, zoom: Double) {
        view.font = NSFont.monospacedSystemFont(ofSize: 11.5 * zoom, weight: .regular)
        view.nativeBackgroundColor = light ? NSColor.white : NSColor.black
        view.backgroundOpacity = 0
        view.nativeForegroundColor = light
            ? NSColor(calibratedRed: 0.11, green: 0.10, blue: 0.17, alpha: 1)
            : NSColor(calibratedWhite: 1, alpha: 0.92)
    }

    /// Puts the cursor in the terminal.
    func focus() {
        view.window?.makeFirstResponder(view)
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { self.title = title }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            self.ended = true
            self.changed()
        }
    }
}

/// The terminal's own view, placed in the panel as it is.
private struct TerminalSurface: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}
}

/// The Terminal tab of the workspace's bottom panel.
struct TerminalPane: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        // The session is made the first time the tab shows, and kept.
        TerminalHost(session: model.terminalSession())
    }
}

private struct TerminalHost: View {
    @ObservedObject var session: TerminalSession
    /// Watched so the terminal follows the look and the content zoom.
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ZStack {
            TerminalSurface(session: session)
                .id(ObjectIdentifier(session))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            if session.ended {
                VStack(spacing: 8) {
                    Text("The shell has ended.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink.opacity(0.7))
                    Button {
                        session.start()
                        session.focus()
                    } label: {
                        Text("Start it again")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(SwiftUI.Color.black.opacity(0.82))
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(Capsule().fill(Theme.accentGradient))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.shade.opacity(0.8)))
            }
        }
        .onAppear {
            session.restyle(light: Theme.isLight, zoom: settings.contentZoom)
            DispatchQueue.main.async { session.focus() }
        }
        .onDisappear { session.changed() }
        .onChange(of: settings.contentZoom) { _, zoom in
            session.restyle(light: Theme.isLight, zoom: zoom)
        }
        .onChange(of: settings.themeTick) { _, _ in
            session.restyle(light: Theme.isLight, zoom: settings.contentZoom)
        }
    }
}
