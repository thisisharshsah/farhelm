import SwiftUI

/// The palette: one box that finds a command or a file by a few letters of
/// its name. Text that starts with ">" looks through the commands;
/// anything else looks through the files of the folder in use. Up and Down
/// move, Return runs or opens, Escape closes.
struct CommandPalette: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var commands = CommandRegistry.shared
    @ObservedObject private var index = FileIndex.shared
    @FocusState private var focused: Bool
    @State private var selection = 0

    private enum Row: Identifiable {
        case command(Command)
        case file(String)

        var id: String {
            switch self {
            case .command(let command): return "command:" + command.id
            case .file(let file): return "file:" + file
            }
        }
    }

    private static let rowHeight: CGFloat = 30

    private var commandMode: Bool { commands.paletteQuery.hasPrefix(">") }

    private var rows: [Row] {
        if commandMode {
            return commands.matches(String(commands.paletteQuery.dropFirst())).prefix(80).map(Row.command)
        }
        guard app.hasWorkFolder else { return [] }
        return index.matches(commands.paletteQuery).map(Row.file)
    }

    /// What to say when there is nothing to list.
    private var emptyNote: String {
        if commandMode { return "No command fits that." }
        if !app.hasWorkFolder { return "No folder is open. Type > to run a command." }
        if index.loading, index.files.isEmpty { return "Reading the folder..." }
        return "No file fits that. Type > to run a command."
    }

    private func move(_ step: Int, among count: Int) {
        guard count > 0 else { return }
        selection = (selection + step + count) % count
    }

    private func choose(_ row: Row) {
        commands.closePalette()
        switch row {
        case .command(let command):
            commands.run(command.id)
        case .file(let file):
            let root = app.workspaceRoot
            index.noteOpened(file)
            // Opening a file is work in code: the workspace comes up on it.
            if !app.codeMode {
                app.setCode(true)
            } else if app.sidePanel != .workspace {
                app.showSide(.workspace)
            }
            app.workspace.use(root: root)
            // Edits to the file being left are kept, not dropped.
            if app.workspace.dirty { app.workspace.save(conversation: app.conversation.id) }
            app.workspace.open((root as NSString).appendingPathComponent(file))
        }
    }

    @ViewBuilder
    private func label(_ row: Row, selected: Bool) -> some View {
        HStack(spacing: 8) {
            switch row {
            case .command(let command):
                Image(systemName: command.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.ink.opacity(0.6))
                    .frame(width: 18)
                Text(command.category + ":")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink.opacity(0.5))
                Text(command.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.95))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let keys = commands.keysLabel(command) {
                    Text(keys)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.ink.opacity(0.55))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous).fill(Theme.ink.opacity(0.08)))
                }
            case .file(let file):
                let name = (file as NSString).lastPathComponent
                let folder = (file as NSString).deletingLastPathComponent
                Image(systemName: "doc.text")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.ink.opacity(0.6))
                    .frame(width: 18)
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.95))
                    .lineLimit(1)
                Text(folder)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .fill(selected ? Theme.accent.opacity(0.16) : Color.clear))
        .contentShape(Rectangle())
    }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: commandMode ? "command" : "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .frame(width: 18)
                TextField(commandMode ? "Run a command" : "Go to a file, or type > for commands",
                          text: $commands.paletteQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink.opacity(0.95))
                    .focused($focused)
                    .onSubmit {
                        if selection < rows.count { choose(rows[selection]) }
                    }
                    .onKeyPress(.upArrow) {
                        move(-1, among: rows.count)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        move(1, among: rows.count)
                        return .handled
                    }
                if index.loading, !commandMode {
                    LoadingMark(state: .working, size: 14)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            Rectangle()
                .fill(Theme.ink.opacity(0.08))
                .frame(height: 1)
            if rows.isEmpty {
                Text(emptyNote)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { position, row in
                                label(row, selected: position == selection)
                                    .id(position)
                                    .onTapGesture { choose(row) }
                            }
                        }
                        .padding(5)
                    }
                    // As tall as what it lists, up to ten rows.
                    .frame(height: min(CGFloat(rows.count), 10) * (Self.rowHeight + 1) + 10)
                    .onChange(of: selection) { _, position in
                        proxy.scrollTo(position)
                    }
                }
            }
        }
        .frame(maxWidth: 480)
        // It sits over everything, so it needs a solid base under the glass.
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.shade.opacity(0.88)))
        .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: Color.black.opacity(0.28), radius: 18, y: 8)
        .onAppear {
            selection = 0
            index.use(root: app.hasWorkFolder ? app.workspaceRoot : "")
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: commands.paletteQuery) { _, _ in
            selection = 0
        }
        .onExitCommand { commands.closePalette() }
    }
}
