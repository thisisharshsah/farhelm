import SwiftUI

// The pieces of an editor's frame that sit outside the workspace: in the
// top bar, back and forward with a search box, and the layout buttons; in
// the chat box, the open file going with the message. Each watches the
// workspace itself, so it follows the file that is open.

/// Back and forward between files, and a search box named for the folder
/// that opens Go to File and the commands.
struct WorkspaceNavBar: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject private var commands = CommandRegistry.shared

    var body: some View {
        HStack(spacing: 8) {
            ToolbarGroup {
                IconButton("chevron.left", help: "Back to the file before") { model.goBack() }
                    .disabled(model.backStack.isEmpty)
                    .opacity(model.backStack.isEmpty ? 0.4 : 1)
                IconButton("chevron.right", help: "Forward") { model.goForward() }
                    .disabled(model.forwardStack.isEmpty)
                    .opacity(model.forwardStack.isEmpty ? 0.4 : 1)
            }
            Button { commands.openPalette(commands: false) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                    Text((model.root as NSString).lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("⌘P")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .opacity(0.6)
                }
                .foregroundStyle(Theme.ink.opacity(0.7))
                .padding(.horizontal, 10)
                .frame(width: 220, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.ink.opacity(0.12), lineWidth: 0.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go to a file (⌘P), or type > to run a command (⇧⌘P)")
        }
    }
}

/// The file tree and the bottom panel, shown or put away.
struct WorkspaceLayoutButtons: View {
    @ObservedObject var model: WorkspaceModel
    /// The file tree's button too (off when it has a place of its own).
    var showsFiles = true

    var body: some View {
        ToolbarGroup {
            if showsFiles {
                FilesToggle.button(model)
            }
            IconButton("inset.filled.bottomthird.rectangle",
                       help: model.panelOpen ? "Put the panel away (⌘J)" : "Show the panel (⌘J)",
                       tint: model.panelOpen ? Theme.accent : nil) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { model.panelOpen.toggle() }
            }
        }
    }
}

/// Shows or puts away the file tree, the way an editor's left sidebar
/// button does.
struct FilesToggle: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        ToolbarGroup { Self.button(model) }
    }

    static func button(_ model: WorkspaceModel) -> some View {
        IconButton("sidebar.left",
                   help: model.filesHidden ? "Show the file tree" : "Put the file tree away",
                   tint: model.filesHidden ? nil : Theme.accent) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { model.filesHidden.toggle() }
        }
    }
}

/// The file open in the editor, going with the next message; the cross
/// keeps it out until another file is opened.
struct OpenFileChip: View {
    @ObservedObject var model: WorkspaceModel
    @EnvironmentObject var app: AppState

    var body: some View {
        if let path = app.openFileForChat {
            HStack(spacing: 5) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("open file")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                Button { app.openFileDismissed = path } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.ink.opacity(0.55))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Don't send this file with the message")
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Theme.ink.opacity(0.07)))
            .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.12), lineWidth: 0.5))
            .help("\(path) goes with the message")
        }
    }
}
