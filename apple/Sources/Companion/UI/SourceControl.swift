import AppKit
import SwiftUI

/// The repository's tab in the workspace, laid out the way an editor's
/// source control is: the branch on top, the message and Commit, then what
/// is staged and what has changed. A click on a file shows what changed in
/// it.
struct SourceTab: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var git: GitModel

    /// Naming a new branch, in place of the branch bar.
    @State private var naming = false
    @State private var newBranch = ""
    @FocusState private var namingFocused: Bool
    /// The file whose changes are about to be dropped, asked about once more.
    @State private var discarding: GitFile?
    /// Drafting a commit message from the changes.
    @State private var drafting = false

    var body: some View {
        Group {
            if !git.loaded {
                workspaceNote("Reading the repository...")
            } else if !git.isRepository {
                notRepository
            } else if let file = git.shown {
                detail(file)
            } else {
                list
            }
        }
        .onAppear { git.use(folder: model.root) }
        // Back from a terminal or another app: the state may have moved.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            git.refresh()
        }
    }

    // MARK: Not a repository

    private var notRepository: some View {
        VStack(alignment: .leading, spacing: 8) {
            workspaceNote("This folder is not a git repository. Starting one here lets you commit your work, use branches and undo with confidence.")
            Button {
                git.initialize()
            } label: {
                Text("Start a repository here")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.82))
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Capsule().fill(Theme.accentGradient))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            noteLine
        }
    }

    // MARK: The list

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            branchBar
            commitBox
            noteLine
            Rectangle()
                .fill(Theme.ink.opacity(0.07))
                .frame(height: 1)
            if git.count == 0 {
                workspaceNote("Nothing has changed since the last commit.")
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !git.staged.isEmpty {
                        sectionTitle("Staged Changes", count: git.staged.count,
                                     icon: "minus", help: "Unstage all") { git.unstageAll() }
                        ForEach(git.staged) { file in row(file) }
                    }
                    if !git.unstaged.isEmpty {
                        sectionTitle("Changes", count: git.unstaged.count,
                                     icon: "plus", help: "Stage all") { git.stageAll() }
                        ForEach(git.unstaged) { file in row(file) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
        }
    }

    /// The branch, how far it is from its remote, and pull, push, refresh.
    @ViewBuilder
    private var branchBar: some View {
        if naming {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                TextField("", text: $newBranch, prompt: Text("Name of the new branch").foregroundStyle(Theme.ink.opacity(0.42)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink.opacity(0.95))
                    .focused($namingFocused)
                    .onSubmit {
                        git.createBranch(newBranch)
                        naming = false
                    }
                    .onExitCommand { naming = false }
                IconButton("xmark", help: "Cancel") { naming = false }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .onAppear {
                newBranch = ""
                namingFocused = true
            }
        } else {
            HStack(spacing: 6) {
                Menu {
                    ForEach(git.branches, id: \.self) { name in
                        Button {
                            git.switchTo(name)
                        } label: {
                            if name == git.branch {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(name)
                            }
                        }
                    }
                    Divider()
                    Button("New branch...") { naming = true }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Text(git.branch.isEmpty ? "No branch" : git.branch)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.ink.opacity(0.92))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            // A long branch name is cut short, so the
                            // buttons beside it always have their room.
                            .frame(maxWidth: 150)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Theme.ink.opacity(0.5))
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Capsule().fill(Theme.ink.opacity(0.08)))
                    .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Switch branch, or start a new one")
                if git.ahead > 0 || git.behind > 0 {
                    Text((git.behind > 0 ? "↓\(git.behind) " : "") + (git.ahead > 0 ? "↑\(git.ahead)" : ""))
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink.opacity(0.6))
                        .help("\(git.ahead) to push, \(git.behind) to pull, against \(git.upstream)")
                }
                Spacer(minLength: 4)
                if git.busy {
                    LoadingMark(state: .working, size: 14)
                }
                IconButton("arrow.down", help: "Pull: bring in what the remote has") { git.pull() }
                IconButton("arrow.up", help: git.upstream.isEmpty
                           ? "Push: publish this branch to the remote"
                           : "Push: send your commits to \(git.upstream)") { git.push() }
                IconButton("arrow.clockwise", help: "Refresh") { git.refresh() }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
        }
    }

    /// A message drafted from what is staged, or every change when
    /// nothing is; it is only written into the box, to read before committing.
    private func draftMessage() {
        drafting = true
        let root = git.root
        let stagedOnly = !git.staged.isEmpty
        Task { @MainActor in
            defer { drafting = false }
            if let message = await app.draftCommitMessage(root: root, stagedOnly: stagedOnly) {
                git.message = message
            } else {
                app.lastError = "Could not write a commit message. Check the model in Settings."
            }
        }
    }

    private var commitBox: some View {
        let ready = !git.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && git.count > 0 && !git.busy
        return HStack(alignment: .bottom, spacing: 6) {
            TextField("", text: $git.message, prompt: Text("Message").foregroundStyle(Theme.ink.opacity(0.42)), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink.opacity(0.95))
                .lineLimit(1...5)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.ink.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(Theme.ink.opacity(0.1), lineWidth: 0.75))
            if drafting {
                LoadingMark(state: .working, size: 14)
                    .frame(width: 27, height: 27)
            } else {
                IconButton("sparkles", help: "Write a message from the changes", tint: Theme.accent) {
                    draftMessage()
                }
                .frame(height: 27)
                .disabled(git.count == 0 || git.busy)
            }
            Button {
                git.commit()
            } label: {
                Text(git.staged.isEmpty ? "Commit All" : "Commit")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(ready ? Color.black.opacity(0.82) : Theme.ink.opacity(0.4))
                    .padding(.horizontal, 11)
                    .frame(height: 27)
                    .background(Capsule().fill(ready ? AnyShapeStyle(Theme.accentGradient)
                                               : AnyShapeStyle(Theme.ink.opacity(0.07))))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!ready)
            .keyboardShortcut(.return, modifiers: .command)
            .help(git.staged.isEmpty
                  ? "Nothing is staged, so this commits every change (Cmd+Return)"
                  : "Commit what is staged (Cmd+Return)")
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    /// What the last action said.
    @ViewBuilder
    private var noteLine: some View {
        if !git.note.isEmpty {
            Text(git.note)
                .font(.system(size: 10.5, design: git.noteFailed ? .monospaced : .default))
                .foregroundStyle(git.noteFailed ? Theme.rose : Theme.mint)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    private func sectionTitle(_ title: String, count: Int, icon: String, help: String,
                              action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Theme.ink.opacity(0.5))
            Text("\(count)")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.ink.opacity(0.6))
                .padding(.horizontal, 5)
                .frame(minHeight: 15)
                .background(Capsule().fill(Theme.ink.opacity(0.08)))
            Spacer(minLength: 4)
            IconButton(icon, help: help, action: action)
        }
        .padding(.leading, 6)
        .padding(.top, 8)
        .frame(height: 30)
    }

    private func row(_ file: GitFile) -> some View {
        GitRow(file: file,
               confirming: discarding == file,
               open: { git.show(file) },
               stage: { file.staged ? git.unstage(file) : git.stage(file) },
               askDiscard: { discarding = file },
               discard: { sure in
                   discarding = nil
                   if sure { git.discard(file) }
               })
    }

    // MARK: One file's changes

    private func detail(_ file: GitFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                IconButton("chevron.left", help: "Back to the list") { git.show(nil) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(file.path)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.ink.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text(file.staged ? "Staged, against the last commit" : "In the folder, against what is staged")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ink.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                IconButton(file.staged ? "minus" : "plus", help: file.staged ? "Unstage" : "Stage") {
                    file.staged ? git.unstage(file) : git.stage(file)
                }
                if file.kind != .deleted {
                    IconButton("doc.text", help: "Open the file") {
                        model.open((git.root as NSString).appendingPathComponent(file.path))
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            Rectangle()
                .fill(Theme.ink.opacity(0.07))
                .frame(height: 1)
            if !git.shownNote.isEmpty {
                workspaceNote(git.shownNote)
            }
            ScrollView([.vertical, .horizontal], showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(git.shownRows) { row in
                        DiffLine(row: row)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

/// One changed file: what happened to it, its name and folder, and on
/// hover the actions on it.
private struct GitRow: View {
    let file: GitFile
    /// Asked whether its changes should really be dropped.
    let confirming: Bool
    let open: () -> Void
    let stage: () -> Void
    let askDiscard: () -> Void
    let discard: (Bool) -> Void
    @State private var hover = false

    private var tint: Color {
        switch file.kind {
        case .modified, .renamed: return Theme.amber
        case .added, .untracked: return Theme.mint
        case .deleted, .conflict: return Theme.rose
        }
    }

    private var meaning: String {
        switch file.kind {
        case .modified: return "Modified"
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .untracked: return "New, not yet in git"
        case .conflict: return "In conflict: settle it, then stage"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(file.name)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink.opacity(0.9))
                .strikethrough(file.kind == .deleted, color: Theme.ink.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(file.folder)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink.opacity(0.42))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if confirming {
                Text(file.kind == .untracked ? "Move to Trash?" : "Discard changes?")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.rose)
                choice("Yes", tint: Theme.rose) { discard(true) }
                choice("No", tint: Theme.ink.opacity(0.7)) { discard(false) }
            } else {
                if hover {
                    if !file.staged {
                        IconButton("arrow.uturn.backward",
                                   help: file.kind == .untracked
                                       ? "Move this new file to the Trash"
                                       : "Discard the changes to this file",
                                   action: askDiscard)
                    }
                    IconButton(file.staged ? "minus" : "plus", help: file.staged ? "Unstage" : "Stage", action: stage)
                }
                Text(file.kind.rawValue)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                    .frame(width: 14)
                    .help(meaning)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous).fill(Theme.ink.opacity(hover ? 0.09 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
        .help("\(file.path)\n\(meaning). Click to see what changed.")
    }

    private func choice(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(tint.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
