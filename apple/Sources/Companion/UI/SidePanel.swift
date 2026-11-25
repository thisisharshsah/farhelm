import SwiftUI

/// What the column on the right of the chat shows.
enum SidePanelMode: Equatable {
    /// Progress, outputs and what the session has used.
    case details
    /// A web page.
    case browser
    /// Files and an editor, search, the history of changes, a terminal.
    case workspace
    /// Advanced mode's board: a project's tasks, their runs and their cost.
    case board

    var width: CGFloat {
        switch self {
        case .details: return 300
        case .browser: return 460
        case .workspace: return 520
        case .board: return 620
        }
    }
}

/// The column on the right of the chat: the details of the session, or a
/// browser.
struct SidePanel: View {
    @EnvironmentObject var app: AppState
    let mode: SidePanelMode

    var body: some View {
        // Details and the browser are one panel each; the workspace is
        // several (files, editor, terminal) and draws its own, and so
        // does the board (its header, its views, a task's details).
        switch mode {
        case .details: filled(SessionDetails()).panelCard()
        case .browser: filled(BrowserPane()).panelCard()
        case .workspace: filled(WorkspacePane())
        case .board: filled(BoardPane())
        }
    }

    private func filled<Content: View>(_ content: Content) -> some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Details

/// The session at a glance: where the task is, what it produced, and what
/// it drew on.
struct SessionDetails: View {
    @EnvironmentObject var app: AppState
    /// Watched so the skills this chat used show as they are used.
    @ObservedObject private var skillLibrary = SkillLibrary.shared
    /// Which lines under "Used in this session" are open.
    @State private var opened = Set<String>()
    /// The sections that are folded to their heading, by name. Kept
    /// between launches.
    @AppStorage("detailsFolded") private var foldedNames = ""

    private func isFolded(_ key: String) -> Bool {
        foldedNames.split(separator: ",").contains(Substring(key))
    }

    private func toggleFold(_ key: String) {
        var names = foldedNames.split(separator: ",").map(String.init)
        if let index = names.firstIndex(of: key) {
            names.remove(at: index)
        } else {
            names.append(key)
        }
        foldedNames = names.joined(separator: ",")
    }

    /// The checklist in a few words, for its heading when it is folded.
    private var progressSummary: String {
        guard let plan = app.sessionPlan, !plan.isEmpty else { return "" }
        return "\(plan.filter { $0.state == .done }.count) of \(plan.count) done"
    }

    var body: some View {
        // No title of its own: the first section's heading is the top
        // line, and the close button sits on it.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                section("Progress", key: "progress", summary: progressSummary, closes: true) { progress }
                section("Outputs", key: "outputs",
                        summary: app.sessionOutputs.isEmpty ? "" : "\(app.sessionOutputs.count)") { outputs }
                section("Used in this session", key: "used",
                        summary: app.sessionTasks.isEmpty ? "" : "\(app.sessionTasks.count)") { used }
            }
            .padding(.bottom, 10)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// A section under its heading. A click on the heading folds it to
    /// that one line, which then says in a word or two what is inside.
    private func section<Content: View>(_ title: String, key: String, summary: String = "", closes: Bool = false,
                                        @ViewBuilder content: () -> Content) -> some View {
        let folded = isFolded(key)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Theme.ink.opacity(0.4))
                        .rotationEffect(.degrees(folded ? 0 : 90))
                        .frame(width: 9)
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.ink.opacity(0.9))
                    if folded, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 10.5))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink.opacity(0.5))
                    }
                    Spacer(minLength: 4)
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) { toggleFold(key) }
                }
                .help(folded ? "Show \(title.lowercased())" : "Fold to this line")
                if closes {
                    IconButton("xmark", help: "Close") { app.closeDetails() }
                }
            }
            if !folded {
                content()
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.ink.opacity(0.42))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func line(_ icon: String, _ title: String, _ detail: String = "", tint: Color? = nil,
                      action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tint ?? Theme.ink.opacity(0.55))
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink.opacity(0.86))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }

    /// The checklist of the task in hand, or of the last one.
    @ViewBuilder
    private var progress: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let plan = app.sessionPlan, !plan.isEmpty {
                // A line down the side with a mark on each step: the one
                // in hand stands out, the rest are quieter.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(plan.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 10) {
                            ZStack(alignment: .top) {
                                Rectangle()
                                    .fill(Theme.ink.opacity(0.14))
                                    .frame(width: 1.5)
                                Circle()
                                    .fill(item.state == .doing ? Theme.accent
                                          : (item.state == .done ? Theme.mint.opacity(0.8) : Theme.ink.opacity(0.28)))
                                    .frame(width: item.state == .doing ? 8 : 6, height: item.state == .doing ? 8 : 6)
                                    .padding(.top, item.state == .doing ? 6 : 7)
                            }
                            .frame(width: 9)
                            Text(item.text)
                                .font(.system(size: 11.5, weight: item.state == .doing ? .medium : .regular))
                                .foregroundStyle(Theme.ink.opacity(item.state == .doing ? 0.95 : (item.state == .done ? 0.55 : 0.7)))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 4)
                            Spacer(minLength: 0)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .help(item.state == .done ? "Done" : (item.state == .doing ? "In hand now" : "To do"))
                    }
                }
                .padding(.leading, 3)
            } else if app.agentRunning {
                line("circle.dotted.circle", app.agentStatus ?? "Working", tint: Theme.accent)
            } else {
                empty("A longer task shows its steps here as it goes.")
            }
        }
    }

    /// Files the agent wrote or changed in this conversation.
    @ViewBuilder
    private var outputs: some View {
        VStack(alignment: .leading, spacing: 2) {
            let files = app.sessionOutputs
            if files.isEmpty {
                empty("Files the agent creates or changes are listed here.")
            } else {
                // The newest is shown as it looks; the rest are listed.
                if let newest = files.last {
                    OutputPreview(path: newest)
                        .padding(.bottom, 4)
                }
                ForEach(files.dropLast().reversed(), id: \.self) { path in
                    line("doc.text", (path as NSString).lastPathComponent,
                         (path as NSString).pathExtension.uppercased()) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .help("\(path)\nClick to show it in Finder.")
                }
            }
        }
    }

    /// What the session has drawn on: attachments, the web, files, memory.
    /// One line for each kind, saying what and how many; click a line to
    /// see all of it.
    @ViewBuilder
    private var used: some View {
        VStack(alignment: .leading, spacing: 2) {
            let attachments = app.attachments
            let tasks = app.sessionTasks
            // Only what this chat actually drew on, not everything on file.
            let memories = app.conversation.usedMemories ?? []
            if attachments.isEmpty, tasks.isEmpty, memories.isEmpty {
                empty("Attachments, web pages, files and memory used along the way.")
            }

            if !attachments.isEmpty {
                group("uploads", icon: "paperclip", title: "Uploads",
                      summary: attachments[0].name, more: attachments.count - 1) {
                    // Attached files stay with the chat and keep informing
                    // its answers. Click one to open it (a folder shows in
                    // Finder); the cross takes it out.
                    ForEach(attachments) { file in
                        HStack(spacing: 2) {
                            line(file.isFolder == true ? "folder" : (Previewer.isPicture(file) ? "photo" : "doc"), file.name) {
                                if file.isFolder == true, let path = file.path {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                } else {
                                    // The chat's files as Uploads: the list, and this one open.
                                    Previewer.shared.openList(attachments, selecting: file)
                                }
                            }
                            IconButton("xmark", help: "Remove from this chat") {
                                app.removeAttachment(file.id)
                            }
                        }
                        .help((file.path ?? file.name) + "\nUsed as context for every answer in this chat.")
                    }
                }
            }
            // Request by request, oldest first: what was asked and when,
            // then what it drew on and changed.
            // Newest first. Each request is two lines: what was asked and when, then
            // the model and a count of each kind of thing it used. Click
            // one to open it into the full rows.
            ForEach(tasks.reversed()) { task in
                let open = opened.contains(task.id.uuidString)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(task.title.isEmpty ? "Request" : task.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.ink.opacity(0.86))
                            .lineLimit(open ? 4 : 1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        // The day too, once it is not today.
                        Text(Calendar.current.isDateInToday(task.date)
                             ? task.date.formatted(date: .omitted, time: .shortened)
                             : task.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                            .font(.system(size: 9.5))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink.opacity(0.42))
                            .fixedSize()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(Theme.ink.opacity(0.35))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    if !open {
                        summary(of: task)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(Theme.ink.opacity(open ? 0.07 : 0.045)))
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if open {
                            opened.remove(task.id.uuidString)
                        } else {
                            opened.insert(task.id.uuidString)
                        }
                    }
                }
                .help(open ? "Click to fold" : "\(task.title)\nClick to see everything this request used.")
                .padding(.top, 3)
                if open {
                    VStack(alignment: .leading, spacing: 0) {
                        usage(of: task)
                    }
                    .padding(.leading, 8)
                }
            }
            if (app.conversation.usedSources ?? []).contains("Live lookup") {
                line("antenna.radiowaves.left.and.right", "Live lookup", "Weather, web")
                    .help("Weather or a quick web search was looked up for an answer in this chat.")
            }
            // The skills the agent read and followed in this chat.
            let skills = skillLibrary.skills(in: app.conversation.id)
            if !skills.isEmpty {
                group("skills", icon: "book.closed", title: "Skills",
                      summary: skills[0], more: skills.count - 1) {
                    ForEach(skills, id: \.self) { name in
                        line("book.closed", name)
                            .help("The agent read and followed the \(name) skill in this chat. Settings > Skills lists every chat that used it.")
                    }
                }
            }
            if !memories.isEmpty {
                group("memory", icon: "brain", title: "Earlier chats",
                      summary: "Read · \(memories.count) remembered", more: 0) {
                    ForEach(memories, id: \.self) { fact in
                        line("clock.arrow.circlepath", fact)
                            .help(fact)
                    }
                }
            }
        }
    }

    /// One request at a glance: the model that did the work, then a mark
    /// and a count for each kind of thing it used.
    private func summary(of task: AppState.TaskUse) -> some View {
        let engine = EngineLogo.mark(of: task.model)
        let name = engine == nil
            ? task.model
            : task.model.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
        let counts: [(icon: String, count: Int, what: String)] = [
            ("paperclip", task.uploads.count, "uploaded"),
            ("globe", task.web.count, "web pages and searches"),
            ("doc.text.magnifyingglass", task.reads.count, "files read"),
            ("pencil", task.edits.count, "files edited"),
            ("terminal", task.commands.count, "commands run"),
            ("brain", task.sources.count, "from memory")
        ]
        return HStack(spacing: 8) {
            if !task.model.isEmpty {
                HStack(spacing: 4) {
                    if let engine {
                        EngineLogo(kind: engine.kind, tool: engine.tool, size: 10)
                            .foregroundStyle(Theme.accent)
                    }
                    Text(name.isEmpty ? task.model : name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.ink.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            ForEach(counts.filter { $0.count > 0 }, id: \.icon) { item in
                HStack(spacing: 2) {
                    Image(systemName: item.icon)
                        .font(.system(size: 9, weight: .medium))
                    Text("\(item.count)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(Theme.ink.opacity(0.55))
                .fixedSize()
                .help("\(item.count) \(item.what)")
            }
        }
    }

    /// What one request drew on: a line for each kind, which opens.
    @ViewBuilder
    private func usage(of task: AppState.TaskUse) -> some View {
        let key = task.id.uuidString
        // Which model did this request's work, by its engine's own logo.
        if !task.model.isEmpty {
            let engine = EngineLogo.mark(of: task.model)
            let name = engine == nil
                ? task.model
                : task.model.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
            HStack(spacing: 8) {
                Group {
                    if let engine {
                        EngineLogo(kind: engine.kind, tool: engine.tool, size: 11)
                    } else {
                        Image(systemName: "cpu")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                }
                .foregroundStyle(Theme.accent)
                .frame(width: 16)
                Text("Model")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink.opacity(0.86))
                Spacer(minLength: 6)
                Text(name.isEmpty ? task.model : name)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.vertical, 4)
        }
        if !task.uploads.isEmpty {
            group(key + "-uploads", icon: "paperclip", title: "Uploads",
                  summary: task.uploads[0], more: task.uploads.count - 1) {
                ForEach(task.uploads, id: \.self) { name in
                    if let file = app.attachments.first(where: { $0.name == name }) {
                        line(Previewer.isPicture(file) ? "photo" : "doc", name) {
                            Previewer.shared.open(file, among: app.attachments.filter { task.uploads.contains($0.name) })
                        }
                    } else {
                        line("doc", name)
                    }
                }
            }
        }
        if !task.web.isEmpty {
            // Pages show by their site's own mark, three of them and a count.
            group(key + "-web", icon: "globe", title: "Web", summary: "",
                  more: max(0, task.web.count - 3), sites: Array(task.web.prefix(3))) {
                ForEach(task.web, id: \.self) { page in
                    if let url = URL(string: page), url.scheme?.hasPrefix("http") == true {
                        line("link", Self.short(page), "Open") { app.browse(url) }
                            .help("\(page)\nClick to open it in the browser on the right.")
                    } else {
                        line("magnifyingglass", page, "Search")
                    }
                }
            }
        }
        if !task.reads.isEmpty {
            group(key + "-files", icon: "doc.text.magnifyingglass", title: "Files",
                  summary: (task.reads[0] as NSString).lastPathComponent, more: task.reads.count - 1) {
                ForEach(task.reads, id: \.self) { path in
                    line("doc.text", (path as NSString).lastPathComponent, "Open") { app.openInWorkspace(path) }
                        .help("\(path)\nClick to open it in the workspace.")
                }
            }
        }
        if !task.edits.isEmpty {
            group(key + "-edits", icon: "pencil", title: "Edited",
                  summary: (task.edits[0] as NSString).lastPathComponent, more: task.edits.count - 1) {
                ForEach(task.edits, id: \.self) { path in
                    line("doc.badge.ellipsis", (path as NSString).lastPathComponent, "Compare") {
                        app.showEdit(path, of: task)
                    }
                    .help("\(path)\nClick to see it before and after this request, side by side in the workspace.")
                }
            }
        }
        if !task.commands.isEmpty {
            // The commands themselves, in the order they ran.
            group(key + "-shell", icon: "terminal", title: "Shell",
                  summary: task.commands[0], more: task.commands.count - 1) {
                ForEach(Array(task.commands.enumerated()), id: \.offset) { _, command in
                    Text(command)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.ink.opacity(0.8))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                        .help(command)
                }
            }
        }
        if !task.sources.isEmpty {
            group(key + "-memory", icon: "brain", title: "Memory",
                  summary: "Read · " + task.sources.prefix(2).joined(separator: ", "),
                  more: max(0, task.sources.count - 2)) {
                ForEach(task.sources, id: \.self) { source in
                    if source == "My details" {
                        line("person.text.rectangle", source, "Open") { app.openSettings() }
                            .help("What you told Companion about yourself.")
                    } else {
                        line("doc.text", source)
                            .help(source)
                    }
                }
            }
        }
    }

    /// A site's own icon, or its first letter on a dot when there is none.
    @ViewBuilder
    private func siteMark(_ address: String) -> some View {
        if let icon = app.siteIcon(for: address) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 13, height: 13)
                .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous))
        } else {
            let name = Self.short(address)
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .frame(width: 13, height: 13)
                .background(Circle().fill(Theme.accent.opacity(0.18)))
        }
    }

    /// A web address without its clutter.
    private static func short(_ address: String) -> String {
        guard let url = URL(string: address), let host = url.host else { return address }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// One kind of thing the session used: a line with what and how many,
    /// which opens to show each one.
    @ViewBuilder
    private func group<Rows: View>(_ key: String, icon: String, title: String, summary: String, more: Int,
                                   sites: [String] = [],
                                   @ViewBuilder rows: () -> Rows) -> some View {
        let open = opened.contains(key)
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.55))
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink.opacity(0.86))
                .fixedSize()
            Spacer(minLength: 6)
            if sites.isEmpty {
                Text(summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                HStack(spacing: 4) {
                    ForEach(sites, id: \.self) { site in
                        siteMark(site)
                    }
                }
            }
            if more > 0 {
                Text("+\(more)")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink.opacity(0.5))
                    .fixedSize()
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(Theme.ink.opacity(0.35))
                .rotationEffect(.degrees(open ? 90 : 0))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) {
                if open { opened.remove(key) } else { opened.insert(key) }
            }
        }
        if open {
            VStack(alignment: .leading, spacing: 0, content: rows)
                .padding(.leading, 14)
        }
    }
}

/// A file the agent produced, shown as it looks: a picture as itself, text
/// by its first lines. Click to find it in Finder.
private struct OutputPreview: View {
    let path: String
    @State private var image: NSImage?
    @State private var text = ""
    @State private var hover = false

    private static let pictures: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "bmp", "webp", "pdf", "icns"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 104, alignment: .top)
                        .clipped()
                } else {
                    Text(text.isEmpty ? " " : text)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Theme.ink.opacity(0.62))
                        .lineLimit(8)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .frame(height: 104, alignment: .topLeading)
                        .padding(.horizontal, 9)
                        .padding(.top, 8)
                        .clipped()
                }
            }
            Rectangle()
                .fill(Theme.ink.opacity(0.08))
                .frame(height: 1)
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.55))
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text((path as NSString).pathExtension.uppercased())
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ink.opacity(0.45))
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
        }
        .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).fill(Theme.ink.opacity(hover ? 0.09 : 0.05)))
        .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).strokeBorder(Theme.ink.opacity(0.12), lineWidth: 0.75))
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        .onHover { hover = $0 }
        .help("\(path)\nClick to show it in Finder.")
        .task(id: path) {
            image = nil
            text = ""
            let kind = (path as NSString).pathExtension.lowercased()
            if Self.pictures.contains(kind) {
                image = NSImage(contentsOfFile: path)
            } else if let data = FileManager.default.contents(atPath: path) {
                // The start of the file is enough for a look.
                text = String(decoding: data.prefix(1_600), as: UTF8.self)
            }
        }
    }
}

/// Gives the right column the whole panel, or hands the room back to the
/// chat. The chat is only out of the way: it also comes back from the
/// button in the top bar, or when the column is closed.
struct FullToggle: View {
    @EnvironmentObject var app: AppState

    /// One pair of arrows wherever a column can take the whole panel: out
    /// to take it, in to give it back.
    static func symbol(full: Bool) -> String {
        full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
    }

    static func help(full: Bool) -> String {
        full ? "Show the chat beside this again" : "Use the whole panel (the chat steps aside)"
    }

    var body: some View {
        IconButton(Self.symbol(full: app.sideFull), help: Self.help(full: app.sideFull),
                   tint: app.sideFull ? Theme.accent : nil) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { app.sideFull.toggle() }
        }
    }
}
