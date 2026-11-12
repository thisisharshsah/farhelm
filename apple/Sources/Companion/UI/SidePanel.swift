import SwiftUI
import WebKit

/// What the column on the right of the chat shows.
enum SidePanelMode: Equatable {
    /// Progress, outputs and what the session has used.
    case details
    /// A web page.
    case browser
    /// Files and an editor, search, the history of changes, a terminal.
    case workspace

    var width: CGFloat {
        switch self {
        case .details: return 300
        case .browser: return 460
        case .workspace: return 520
        }
    }
}

/// The column on the right of the chat: the details of the session, or a
/// browser.
struct SidePanel: View {
    @EnvironmentObject var app: AppState
    let mode: SidePanelMode

    var body: some View {
        Group {
            switch mode {
            case .details: SessionDetails()
            case .browser: BrowserPane()
            case .workspace: WorkspacePane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Details

/// The session at a glance: where the task is, what it produced, and what
/// it drew on.
struct SessionDetails: View {
    @EnvironmentObject var app: AppState
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
                    // its answers. Click one to find it; the cross takes it
                    // out.
                    ForEach(attachments) { file in
                        HStack(spacing: 2) {
                            line(file.isFolder == true ? "folder" : "doc", file.name) {
                                if let path = file.path {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
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
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                    line("doc", name)
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
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
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
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(hover ? 0.09 : 0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.ink.opacity(0.12), lineWidth: 0.75))
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

    var body: some View {
        IconButton(app.sideFull ? "rectangle.split.2x1" : "arrow.up.left.and.arrow.down.right",
                   help: app.sideFull ? "Show the chat beside this again" : "Use the whole panel (the chat steps aside)",
                   tint: app.sideFull ? Theme.accent : nil) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { app.sideFull.toggle() }
        }
    }
}

/// A site's own icon for a tab, or a stand-in until there is one.
private struct SiteIcon: View {
    let icon: NSImage?
    let blank: Bool
    /// The tab that is showing; the others are a little quieter.
    let bright: Bool

    var body: some View {
        Group {
            if let icon, !blank {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .opacity(bright ? 1 : 0.8)
            } else {
                Image(systemName: blank ? "magnifyingglass" : "globe")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(bright ? Theme.accent : Theme.ink.opacity(0.5))
            }
        }
        .frame(width: 14, height: 14)
    }
}

// MARK: - Browser

/// A small browser beside the chat, with tabs. It is its own browser: no
/// sign-ins or history are shared with Safari or Chrome.
struct BrowserPane: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        // Each chat has a browser session of its own, so the pane is
        // rebuilt for the session of the chat that is showing.
        let web = app.web
        BrowserBody(web: web)
            .id(ObjectIdentifier(web))
            .onAppear { web.ensureTab() }
    }
}

private struct BrowserBody: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var web: BrowserModel

    var body: some View {
        // The bar sits above the page, not over it.
        VStack(spacing: 0) {
            bar
            if let tab = web.current {
                BrowserTabView(tab: tab, web: web)
                    .id(tab.id)
            }
        }
    }

    /// Room the tabs have, measured, so they can share it.
    @State private var stripWidth: CGFloat = 300
    /// The hairline between tabs.
    private static let tabGap: CGFloat = 1
    /// The narrowest the tab that is showing gets, and the others. When
    /// tabs are many the others drop their title and keep their icon, with
    /// the closing cross still in a place of its own beside it, so a click
    /// meant to pick a tab can never land on the cross. Past these the
    /// strip scrolls.
    private static let fieldLeast: CGFloat = 170
    /// The least the showing tab gets while it is not being typed in.
    private static let fieldShown: CGFloat = 120
    private static let chipLeast: CGFloat = 64
    /// From this width a tab that is not showing has room for its title.
    /// Narrower than this it is just its icon.
    private static let chipTitled: CGFloat = 104
    /// The widest a tab that is not showing gets.
    private static let chipMost: CGFloat = 220

    /// The tabs share the strip, as in a browser: each new tab makes them
    /// narrower, and the one that is showing takes a larger share since it
    /// holds the address. A tab that has not gone anywhere yet stays
    /// compact, so an empty browser is not one long empty bar.
    private var widths: (field: CGFloat, chip: CGFloat) {
        let count = CGFloat(max(1, web.tabs.count))
        let blank = web.current?.isBlank ?? true
        // A lone tab that has not gone anywhere stays compact.
        // In a narrow panel it gives way, so its end is never cut off by
        // the buttons beside it.
        if count == 1, blank { return (min(Self.fieldLeast, max(80, stripWidth)), Self.chipLeast) }
        // Every tab gets the same share, showing or not, so picking another
        // tab never makes the strip jump about.
        let share = (stripWidth - (count - 1) * Self.tabGap) / count
        // Only when tabs are crowded does the showing one keep a little
        // more, and room to type in while its address is being edited.
        // A tab on its own is exactly the strip, however narrow.
        if count == 1 { return (max(80, share), Self.chipLeast) }
        let least = editing ? Self.fieldLeast : Self.fieldShown
        return (max(least, share), max(Self.chipLeast, share))
    }

    /// Closing the last tab leaves a fresh one in its place; closing that
    /// one, with nothing in it, closes the browser.
    private func close(_ tab: BrowserTab) {
        if web.tabs.count == 1, tab.isBlank { app.showSide(nil) } else { web.close(tab.id) }
    }

    /// One tab that has not gone anywhere: nothing is open yet.
    private var hugging: Bool { web.tabs.count == 1 && (web.current?.isBlank ?? true) }
    private var fieldWidth: CGFloat { widths.field }
    private var chipWidth: CGFloat { widths.chip }

    /// The address field has the keyboard.
    @State private var editing = false

    /// Whether the hairline before this tab shows: only between two tabs
    /// that are not showing. The raised pill needs none beside it.
    private func hairline(before index: Int) -> Bool {
        guard index > 0 else { return false }
        let current: UUID? = web.current?.id
        return web.tabs[index].id != current && web.tabs[index - 1].id != current
    }

    /// One tab in the strip, with the hairline that sets it apart.
    @ViewBuilder
    private func tabItem(index: Int, tab: BrowserTab) -> some View {
        if index > 0 {
            Rectangle()
                .fill(Theme.ink.opacity(hairline(before: index) ? 0.14 : 0))
                .frame(width: 1, height: 14)
        }
        if tab.id == web.current?.id {
            AddressField(tab: tab, history: web.history,
                         close: { close(tab) },
                         editing: $editing)
                .frame(width: fieldWidth)
                .id(tab.id)
        } else {
            TabChip(tab: tab, history: web.history,
                    titled: chipWidth >= Self.chipTitled,
                    select: { web.selected = tab.id },
                    close: { close(tab) })
                .frame(width: chipWidth)
                .id(tab.id)
        }
    }

    /// One line for everything: back and forward, the tabs, a new tab and
    /// the way out. The tab that is showing is the address field itself;
    /// the others are small chips beside it.
    private var bar: some View {
        HStack(spacing: 5) {
            if let tab = web.current {
                BarGroup { NavButtons(tab: tab) }
            }
            // The tabs, in the order they were opened, all in one strip.
            // The one that is showing is a raised pill with its address;
            // the rest are just their icon and title, set apart by
            // hairlines. They scroll sideways when there are more than fit.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(web.tabs.enumerated()), id: \.element.id) { index, tab in
                            tabItem(index: index, tab: tab)
                        }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.86), value: web.tabs.count)
                    .animation(.spring(response: 0.3, dampingFraction: 0.86), value: web.selected)
                }
                .onChange(of: web.selected) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .frame(height: BarButton.size + 4)
            // Before anything is open the strip is only as long as the
            // search field; the rest of the bar is left empty.
            .frame(maxWidth: hugging ? Self.fieldLeast : .infinity)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { stripWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in stripWidth = width }
                }
            }
            // The strip is the same glass as the groups of buttons beside it.
            .clipShape(Capsule())
            .liquidGlass(in: Capsule())
            if hugging { Spacer(minLength: 0) }
            BarGroup {
                BarButton("plus", help: "New tab") { web.newTab() }
                BarButton(app.sideFull ? "rectangle.split.2x1" : "arrow.up.left.and.arrow.down.right",
                          help: app.sideFull ? "Show the chat beside this again" : "Use the whole panel (the chat steps aside)",
                          tint: app.sideFull ? Theme.accent : nil) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { app.sideFull.toggle() }
                }
                BarButton("xmark", help: "Close the browser") { app.showSide(nil) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// A round button for the browser's bar, the same size and weight as the
/// buttons in the panel's own top bar, so the two bars read as one family.
private struct BarButton: View {
    static let size: CGFloat = 26

    let symbol: String
    let help: String
    var tint: Color?
    let action: () -> Void
    @State private var hover = false

    init(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint ?? Theme.ink.opacity(hover ? 1 : 0.68))
                .frame(width: Self.size, height: Self.size)
                .background(Circle().fill((tint ?? Theme.ink).opacity(hover ? 0.18 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(help)
    }
}

/// Holds a few bar buttons together, on the same glass capsule as the
/// groups in the panel's top bar.
private struct BarGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 1) { content }
            .padding(2)
            .liquidGlass(in: Capsule())
    }
}

/// Back and forward for the tab that is showing.
private struct NavButtons: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        BarButton("chevron.left", help: "Back") { tab.webView.goBack() }
            .disabled(!tab.canGoBack)
            .opacity(tab.canGoBack ? 1 : 0.35)
        BarButton("chevron.right", help: "Forward") { tab.webView.goForward() }
            .disabled(!tab.canGoForward)
            .opacity(tab.canGoForward ? 1 : 0.35)
    }
}

/// The tab that is showing: its address, to read or to type over, with
/// reload at its end.
private struct AddressField: View {
    @ObservedObject var tab: BrowserTab
    /// Watched for the site's icon arriving.
    @ObservedObject var history: BrowserHistory
    /// Closes this tab.
    let close: () -> Void
    /// Tells the bar when the field is being typed in, so it can widen.
    @Binding var editing: Bool
    @State private var address = ""
    @State private var hover = false
    @FocusState private var focused: Bool

    /// What the field shows when it is not being typed in: just the site,
    /// as a title. Click it and the whole address is there to edit.
    private var site: String {
        guard let url = tab.url else { return "" }
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The field shows its own text: while typing, and on a blank tab.
    private var showsField: Bool { focused || tab.isBlank }

    var body: some View {
        HStack(spacing: 5) {
            // The cross that closes the tab sits at the very start of the
            // pill and reload at its very end, however wide the tab is; the
            // site's icon and name stay in the middle between them.
            Group {
                if hover, !focused {
                    fieldButton("xmark", help: "Close tab", action: close)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else if !showsField {
                    Color.clear
                } else {
                    SiteIcon(icon: tab.url.flatMap { history.icon(for: $0.absoluteString) }, blank: tab.isBlank, bright: true)
                }
            }
            .frame(width: 20, height: 20)
            ZStack {
                // The field is always there to click into. While it is not
                // being typed in, its own text is clear and the site's icon
                // and name sit over it, together, in the middle.
                TextField("Search", text: $address)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(showsField ? Theme.ink.opacity(0.95) : Color.clear)
                    .focused($focused)
                    .onSubmit {
                        guard let url = BrowserModel.url(from: address) else { return }
                        focused = false
                        tab.load(url)
                    }
                if !showsField {
                    HStack(spacing: 6) {
                        SiteIcon(icon: tab.url.flatMap { history.icon(for: $0.absoluteString) }, blank: false, bright: true)
                        Text(site)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ink.opacity(0.95))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                }
            }
            if tab.loading {
                // While a page loads, the way to stop it is always there.
                fieldButton("xmark", help: "Stop") { tab.webView.stopLoading() }
            } else {
                // Reload stays out of the way until the pointer is on the
                // tab. It keeps its place either way, so the site stays
                // centered.
                fieldButton("arrow.clockwise", help: "Reload") { tab.webView.reload() }
                    .opacity(hover && !tab.isBlank ? 1 : 0)
                    .allowsHitTesting(hover && !tab.isBlank)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: BarButton.size)
        .frame(maxWidth: .infinity)
        // The tab that is showing is told apart only by its edge and its
        // icon, both in the look's color. It has no fill of its own, so
        // the strip stays one piece of glass.
        .background(Capsule().fill(Theme.ink.opacity(hover && !focused ? 0.06 : 0)))
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(focused ? 0.95 : 0.7),
                                        lineWidth: focused ? 1.25 : 1))
        .padding(.horizontal, 2)
        // A thin line along the bottom while the page loads.
        .overlay(alignment: .bottom) {
            if tab.loading {
                Capsule()
                    .fill(Theme.accentGradient)
                    .frame(height: 1.5)
                    .padding(.horizontal, 10)
                    .transition(.opacity)
            }
        }
        .onHover { hover = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: hover)
        .animation(.easeOut(duration: 0.14), value: focused)
        .contextMenu {
            if let url = tab.url {
                Button("Open in default browser") { NSWorkspace.shared.open(url) }
                Button("Copy address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            Button("Close tab", action: close)
        }
        .onAppear {
            address = site
            if tab.isBlank { focused = true } else { editing = false }
        }
        .onChange(of: tab.url) { old, _ in
            // A blank tab has the field focused, ready to type in. Going
            // somewhere from it (a suggestion, say) must still show where.
            if old == nil {
                focused = false
                address = site
            } else if !focused {
                address = site
            }
        }
        .onChange(of: focused) { _, editing in
            // The whole address to edit; just the site once done.
            address = editing ? (tab.url?.absoluteString ?? "") : site
            self.editing = editing
        }
    }

    private func fieldButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Theme.ink.opacity(0.75))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.ink.opacity(0.10)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A tab that is not showing: its icon and, when there is room, the page's
/// title, centered in its share of the strip. Click to switch to it; with
/// the pointer on it the icon becomes the cross that closes it.
private struct TabChip: View {
    @ObservedObject var tab: BrowserTab
    /// Watched for the site's icon arriving.
    @ObservedObject var history: BrowserHistory
    /// Wide enough for the title as well as the icon.
    let titled: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hover = false

    var body: some View {
        // With room for a title, the cross sits at the very start of the
        // hover pill and the icon and title stay in the middle. A tab that
        // is only its icon has the cross slide in just ahead of it.
        HStack(spacing: 5) {
            if hover, !titled { cross }
            Group {
                if tab.loading {
                    LoadingMark(state: .working, size: 12)
                } else {
                    SiteIcon(icon: tab.url.flatMap { history.icon(for: $0.absoluteString) }, blank: tab.isBlank, bright: false)
                }
            }
            .frame(width: 16, height: 16)
            if titled {
                Text(tab.label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink.opacity(hover ? 0.9 : 0.66))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        // Room kept clear on both sides for the cross, so the title never
        // runs under it and stays centered.
        .padding(.horizontal, titled ? 18 : 0)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) {
            if hover, titled { cross }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The same rounded pill as the tab that is showing, only fainter.
        // It keeps the same gap from the strip's edge all the way round.
        .background(Capsule().fill(Theme.ink.opacity(hover ? 0.09 : 0))
            .frame(height: BarButton.size)
            .padding(.horizontal, 3))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: hover)
        .contextMenu {
            Button("Close tab", action: close)
        }
        .help(tab.label + (tab.url.map { "\n" + $0.absoluteString } ?? ""))
    }
}

/// A tab's content: the page or, before it has gone anywhere, the
/// suggestions.
private struct BrowserTabView: View {
    @EnvironmentObject var app: AppState
    /// Watched so pages follow the content zoom as it changes.
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var tab: BrowserTab
    @ObservedObject var web: BrowserModel
    /// The height of the bar floating over the top of the content.
    var topInset: CGFloat = 0

    var body: some View {
        if tab.isBlank {
            // No page yet: the panel's own background shows through, with
            // places to go on top of it.
            NewTabPage(history: web.history, chatPages: chatPages) { url in
                tab.load(url)
            }
            .padding(.top, topInset)
        } else if #available(macOS 26.0, *) {
            // The page fills the pane and knows its top is covered, so it
            // starts below the bar and scrolls up underneath it.
            WebView(webView: tab.webView, zoom: AppSettings.shared.contentZoom, topInset: topInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            WebView(webView: tab.webView, zoom: AppSettings.shared.contentZoom)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, topInset)
        }
    }

    /// Pages the agent used in this chat, offered first on a new tab.
    private var chatPages: [String] {
        app.sessionWeb.filter { URL(string: $0)?.scheme?.hasPrefix("http") == true }
    }
}

/// What a new tab shows: pages to go back to, as cards on the panel's own
/// background.
private struct NewTabPage: View {
    @ObservedObject var history: BrowserHistory
    let chatPages: [String]
    let open: (URL) -> Void

    private struct Card: Identifiable {
        let id: String
        let title: String
        let host: String
        let note: String
        let fromChat: Bool
        let page: VisitedPage?
    }

    private var cards: [Card] {
        var seen = Set<String>()
        var list: [Card] = []
        for address in chatPages where seen.insert(address).inserted {
            let host = Self.host(of: address)
            let known = history.pages.first { $0.url == address }
            list.append(Card(id: address, title: known?.title.isEmpty == false ? known!.title : host,
                             host: host, note: "From this chat", fromChat: true, page: nil))
            if list.count == 4 { break }
        }
        for page in history.suggestions(limit: 16) where seen.insert(page.url).inserted {
            list.append(Card(id: page.url, title: page.title.isEmpty ? page.host : page.title,
                             host: page.host, note: Self.when(page.last), fromChat: false, page: page))
            if list.count == 12 { break }
        }
        return list
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Suggestions")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.ink.opacity(0.96))
                let cards = cards
                if cards.isEmpty {
                    Text("Pages you visit show up here.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink.opacity(0.45))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 200), spacing: 8)],
                              alignment: .leading, spacing: 8) {
                        ForEach(cards) { card in
                            SuggestionCard(title: card.title, host: card.host, note: card.note,
                                           thumbnail: history.thumbnail(for: card.id),
                                           icon: history.icon(for: card.id),
                                           tint: card.fromChat ? Theme.accent : nil) {
                                if let url = URL(string: card.id) { open(url) }
                            }
                            .contextMenu {
                                if let page = card.page {
                                    Button("Remove from suggestions") { history.remove(page) }
                                }
                                Button("Clear all visited pages") { history.clear() }
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func host(of address: String) -> String {
        let host = URL(string: address)?.host ?? address
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// When a page was last open, in a word or two.
    private static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 { return "This week" }
        if days < 14 { return "Last week" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// One suggestion: the site's initial, the page's name, and where it is.
private struct SuggestionCard: View {
    let title: String
    let host: String
    let note: String
    /// The page as it last looked, when there is a picture of it.
    var thumbnail: NSImage?
    /// The site's own icon, when it has been fetched.
    var icon: NSImage?
    var tint: Color?
    let action: () -> Void
    @State private var hover = false

    /// The top of the card: the page itself when there is a picture of it,
    /// and otherwise the site's icon or its initial on a tile.
    @ViewBuilder
    private var top: some View {
        if let thumbnail {
            Color.clear
                .frame(height: 64)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                .clipped()
                .padding(.bottom, 9)
        } else {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                } else {
                    Text(String(host.prefix(1)).uppercased())
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.ink.opacity(0.92))
                }
            }
            .frame(width: 38, height: 38)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((tint ?? Theme.ink).opacity(tint == nil ? 0.12 : 0.30)))
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .padding(.bottom, 9)
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                top
                Group {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.95))
                    .lineLimit(1)
                Text(host)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.55))
                    .lineLimit(1)
                    .padding(.top, 1)
                Text(note)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle((tint ?? Theme.ink).opacity(tint == nil ? 0.45 : 0.95))
                    .lineLimit(1)
                    .padding(.top, 8)
                }
                .padding(.horizontal, 10)
            }
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Each place to go is a pane of glass over the panel's own
            // background, tinted with the look's color under the pointer.
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous),
                         tint: hover ? Theme.accent : nil, interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help("\(title)\n\(host)")
    }
}

private extension TabChip {
    /// The cross that closes the tab.
    var cross: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.ink.opacity(0.85))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Theme.ink.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Close tab")
        .transition(.scale(scale: 0.4).combined(with: .opacity))
    }
}

/// Hosts a tab's web view.
private struct WebView: NSViewRepresentable {
    let webView: WKWebView
    /// The content zoom, which pages follow.
    var zoom: Double = 1
    /// How much of the top of the page a floating bar covers.
    var topInset: CGFloat = 0

    func makeNSView(context: Context) -> WKWebView {
        webView.pageZoom = zoom
        cover(webView)
        return webView
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if abs(view.pageZoom - zoom) > 0.001 { view.pageZoom = zoom }
        cover(view)
    }

    private func cover(_ view: WKWebView) {
        if #available(macOS 26.0, *), abs(view.obscuredContentInsets.top - topInset) > 0.5 {
            view.obscuredContentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        }
    }
}
