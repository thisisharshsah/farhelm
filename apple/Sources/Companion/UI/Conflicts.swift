import SwiftUI

/// One merge conflict in a file: the lines between `<<<<<<<` and `>>>>>>>`,
/// as git writes them. Lines are counted from 0.
struct MergeConflict: Identifiable, Equatable {
    let start: Int          // the <<<<<<< line
    let base: Int?          // the ||||||| line, when git wrote the common version (diff3)
    let middle: Int         // the ======= line
    let end: Int            // the >>>>>>> line
    let current: String     // what the <<<<<<< line names (HEAD, the branch)
    let incoming: String    // what the >>>>>>> line names
    var id: Int { start }

    /// The conflicts in a text, top to bottom.
    static func find(in text: String) -> [MergeConflict] {
        guard text.contains("<<<<<<< ") || text.contains("<<<<<<<\n") else { return [] }
        let lines = text.components(separatedBy: "\n")
        var found: [MergeConflict] = []
        var start: Int?, base: Int?, middle: Int?
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("<<<<<<<") {
                start = index
                base = nil
                middle = nil
            } else if line.hasPrefix("|||||||"), start != nil, middle == nil {
                base = index
            } else if line.hasPrefix("======="), start != nil, middle == nil {
                middle = index
            } else if line.hasPrefix(">>>>>>>"), let s = start, let m = middle {
                found.append(MergeConflict(start: s, base: base, middle: m, end: index,
                                           current: String(lines[s].dropFirst(7)).trimmingCharacters(in: .whitespaces),
                                           incoming: String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)))
                start = nil
            }
        }
        return found
    }

    enum Choice { case current, incoming, both }

    /// The text with this conflict settled one way.
    func resolve(_ choice: Choice, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard end < lines.count else { return text }
        let ours = Array(lines[(start + 1)..<(base ?? middle)])
        let theirs = Array(lines[(middle + 1)..<end])
        let kept: [String]
        switch choice {
        case .current: kept = ours
        case .incoming: kept = theirs
        case .both: kept = ours + theirs
        }
        lines.replaceSubrange(start...end, with: kept)
        return lines.joined(separator: "\n")
    }
}

/// The bar over the editor while the open file has merge conflicts, as an
/// editor's "Accept Current | Accept Incoming | Accept Both": one conflict
/// at a time, with a way through them, and the agent for the hard ones.
struct ConflictBar: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: WorkspaceModel
    @ObservedObject private var git = GitModel.shared
    @State private var index = 0
    @State private var conflicts: [MergeConflict] = []

    var body: some View {
        Group {
            if !conflicts.isEmpty {
                let current = conflicts[min(index, conflicts.count - 1)]
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.amber)
                    Text("Conflict \(min(index, conflicts.count - 1) + 1) of \(conflicts.count) · line \(current.start + 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ink.opacity(0.8))
                        .lineLimit(1)
                    IconButton("chevron.up", help: "Previous conflict") { go(-1) }
                    IconButton("chevron.down", help: "Next conflict") { go(1) }
                    Spacer(minLength: 4)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { choices(current, long: true) }
                        HStack(spacing: 10) { choices(current, long: false) }
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.amber.opacity(0.12))
            } else if let path = model.openPath, isConflicted(path), !model.dirty {
                // Every marker is gone: git still has to be told.
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.mint)
                    Text("No conflicts left in this file.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.ink.opacity(0.8))
                    Spacer(minLength: 4)
                    Button("Mark as Resolved") {
                        let rel = relative(path)
                        if let file = (git.unstaged + git.staged).first(where: { $0.path == rel }) { git.stage(file) }
                    }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .help("Stage the file (git add), which tells git the conflict is settled")
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.mint.opacity(0.1))
            }
        }
        .onAppear { conflicts = MergeConflict.find(in: model.text) }
        .onChange(of: model.text) { _, text in
            conflicts = MergeConflict.find(in: text)
            if index >= conflicts.count { index = max(0, conflicts.count - 1) }
        }
        .onChange(of: model.openPath) { _, _ in index = 0 }
    }

    @ViewBuilder
    private func choices(_ conflict: MergeConflict, long: Bool) -> some View {
        choice(long ? "Keep Current" + label(conflict.current) : "Current", help: "Keep the lines from \(name(conflict.current))") {
            settle(conflict, .current)
        }
        choice(long ? "Keep Incoming" + label(conflict.incoming) : "Incoming", help: "Keep the lines from \(name(conflict.incoming))") {
            settle(conflict, .incoming)
        }
        choice("Both", help: "Keep both, current first") { settle(conflict, .both) }
        Button {
            if let path = model.openPath { app.resolveConflicts(in: path) }
        } label: {
            Label(long ? "Ask Agent" : "Agent", systemImage: "sparkles")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.accent)
        .help("Have the agent settle every conflict in this file, keeping what each side meant")
    }

    private func choice(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.ink.opacity(0.85))
            .help(help)
    }

    private func label(_ name: String) -> String { name.isEmpty ? "" : " (\(name.prefix(18)))" }
    private func name(_ name: String) -> String { name.isEmpty ? "this side" : name }

    private func go(_ step: Int) {
        guard !conflicts.isEmpty else { return }
        index = (index + step + conflicts.count) % conflicts.count
        model.reveal = WorkspaceModel.Reveal(line: conflicts[index].start + 1)
    }

    /// Settles one conflict in the editor's text; saving is left to the user,
    /// and ⌘Z in the editor does not undo it, but Changes does once saved.
    private func settle(_ conflict: MergeConflict, _ choice: MergeConflict.Choice) {
        model.text = conflict.resolve(choice, in: model.text)
        let left = MergeConflict.find(in: model.text)
        if let next = left.first(where: { $0.start >= conflict.start }) ?? left.first {
            model.reveal = WorkspaceModel.Reveal(line: next.start + 1)
        }
    }

    private func relative(_ path: String) -> String {
        guard !git.root.isEmpty, path.hasPrefix(git.root + "/") else { return path }
        return String(path.dropFirst(git.root.count + 1))
    }

    private func isConflicted(_ path: String) -> Bool {
        let rel = relative(path)
        return (git.staged + git.unstaged).contains { $0.kind == .conflict && $0.path == rel }
    }
}
