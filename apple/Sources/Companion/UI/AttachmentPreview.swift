import AppKit
import Quartz
import SwiftUI

/// Opening what was attached or pasted: a preview over the chat, with
/// every attachment of the same message a step away, and one button to
/// fill the screen with it.
///
/// Where a file opens depends on what it is and where you are:
/// - text and code in code mode: the workspace editor, to be read and changed;
/// - pictures: zoomable, in the preview;
/// - everything else (PDF, Word, Excel, Keynote, video, code in chat): Quick
///   Look, the Mac's own previewer, so any type macOS can show works.
@MainActor
final class Previewer: ObservableObject {
    static let shared = Previewer()

    /// The files of the message being looked at, and which one is showing.
    @Published private(set) var items: [Attachment] = []
    @Published var index = 0
    /// Shown with the list of every file beside it (from Details), rather
    /// than the one file alone.
    @Published private(set) var listMode = false
    /// The enlarged window, when the preview fills the screen.
    private var enlarged: NSWindow?

    var current: Attachment? { items.indices.contains(index) ? items[index] : nil }
    var isOpen: Bool { !items.isEmpty }

    static let pictures: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "tif", "bmp", "webp"]
    /// What opens in the editor in code mode.
    static let editable: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "json", "md", "txt", "yaml", "yml",
                                        "toml", "sh", "zsh", "rb", "go", "rs", "c", "h", "cpp", "hpp", "m",
                                        "java", "kt", "css", "scss", "html", "xml", "csv", "sql", "log", "env"]

    static func isPicture(_ file: Attachment) -> Bool {
        guard let path = file.path else { return false }
        return pictures.contains((path as NSString).pathExtension.lowercased())
    }

    /// Opens one attachment, with the others of its message beside it.
    /// Every file of the chat: the list on the left, the one picked on the right.
    func openList(_ files: [Attachment], selecting file: Attachment? = nil) {
        let list = files.filter { $0.isFolder != true }
        guard !list.isEmpty else { return }
        items = list
        index = file.flatMap { picked in list.firstIndex { $0.id == picked.id } } ?? 0
        listMode = true
    }

    func open(_ file: Attachment, among others: [Attachment] = []) {
        listMode = false
        let app = AppState.shared
        // Code mode: text goes to the editor, where it can be worked on.
        if app.codeMode, file.isFolder != true, let path = file.path,
           FileManager.default.fileExists(atPath: path),
           Self.editable.contains((path as NSString).pathExtension.lowercased()) {
            close()
            app.openInWorkspace(path)
            return
        }
        let list = others.contains(where: { $0.id == file.id }) ? others : [file]
        items = list
        index = list.firstIndex(where: { $0.id == file.id }) ?? 0
    }

    func step(_ by: Int) {
        guard !items.isEmpty else { return }
        index = (index + by + items.count) % items.count
    }

    func close() {
        closeEnlarged()
        items = []
        index = 0
        listMode = false
    }

    // MARK: Actions

    func openInDefaultApp() {
        guard let path = current?.path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func showInFinder() {
        guard let path = current?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// A picture is copied as a picture, a file as the file, else its text.
    func copy() {
        guard let file = current else { return }
        let board = NSPasteboard.general
        board.clearContents()
        if let path = file.path, Self.isPicture(file), let image = NSImage(contentsOfFile: path) {
            board.writeObjects([image])
        } else if let path = file.path, FileManager.default.fileExists(atPath: path) {
            board.writeObjects([URL(fileURLWithPath: path) as NSURL])
        } else {
            board.setString(file.text, forType: .string)
        }
    }

    /// A copy in Downloads (a new name if one is there already), shown in Finder.
    func download() {
        guard let path = current?.path else { return }
        let fm = FileManager.default
        let folder = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let name = (path as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var target = folder.appendingPathComponent(name)
        var number = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(stem) \(number)" + (ext.isEmpty ? "" : ".\(ext)"))
            number += 1
        }
        do {
            try fm.copyItem(at: URL(fileURLWithPath: path), to: target)
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch {
            AppState.shared.lastError = "Could not save \(name) to Downloads: \(error.localizedDescription)"
        }
    }

    /// Takes it off the chat (the file itself is left where it is).
    func remove() {
        guard let file = current else { return }
        AppState.shared.removeAttachment(file.id)
        items.removeAll { $0.id == file.id }
        if items.isEmpty { close() } else { index = min(index, items.count - 1) }
    }

    // MARK: Filling the screen

    var isEnlarged: Bool { enlarged != nil }

    /// The preview in a window of its own over the whole screen the panel is
    /// on. Esc, or the button, brings it back.
    func toggleEnlarged() {
        if enlarged != nil { closeEnlarged(); return }
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let window = EnlargedWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .modalPanel
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: PreviewContent(enlarged: true))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        enlarged = window
        objectWillChange.send()
    }

    private func closeEnlarged() {
        enlarged?.orderOut(nil)
        enlarged = nil
        objectWillChange.send()
    }
}

/// A borderless window that can take the keyboard (Esc, arrows).
private final class EnlargedWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: Previewer.shared.toggleEnlarged()   // Esc: back to the panel
        case 123: Previewer.shared.step(-1)          // Left
        case 124: Previewer.shared.step(1)           // Right
        default: super.keyDown(with: event)
        }
    }
}

/// The preview over the chat, as a chat app shows a picture: the room
/// dimmed, the file large in the middle with its name under it, and close,
/// download and more beside it. A click on the dimmed room closes it.
struct AttachmentPreviewOverlay: View {
    @ObservedObject private var previewer = Previewer.shared
    @FocusState private var focused: Bool

    var body: some View {
        if previewer.isOpen, !previewer.isEnlarged, previewer.listMode {
            UploadsBrowser()
                .transition(.opacity)
        } else if previewer.isOpen, !previewer.isEnlarged, let file = previewer.current {
            ZStack {
                Color.black.opacity(0.78)
                    .ignoresSafeArea()
                    .onTapGesture { previewer.close() }
                HStack(alignment: .top, spacing: 12) {
                    side(-1, "chevron.left", help: "Previous (←)")
                    VStack(spacing: 12) {
                        shown(file)
                            .id(file.id)
                        HStack(spacing: 8) {
                            Text(file.name)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if previewer.items.count > 1 {
                                Text("\(previewer.index + 1) of \(previewer.items.count)")
                                    .font(.system(size: 11.5))
                                    .monospacedDigit()
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                    VStack(spacing: 10) {
                        RoundAction("xmark", help: "Close (Esc)") { previewer.close() }
                        if file.path != nil {
                            RoundAction("arrow.down.to.line", help: "Save to Downloads") { previewer.download() }
                        }
                        Menu {
                            if file.path != nil {
                                Button("Open in Its App") { previewer.openInDefaultApp() }
                                Button("Show in Finder") { previewer.showInFinder() }
                            }
                            Button("Copy") { previewer.copy() }
                            Button("Fill the Screen") { previewer.toggleEnlarged() }
                            Divider()
                            Button("Remove from This Chat") { previewer.remove() }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 30, height: 30)
                                .contentShape(Circle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("More")
                    }
                    side(1, "chevron.right", help: "Next (→)")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 36)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onAppear { focused = true }
            .onKeyPress(.escape) { previewer.close(); return .handled }
            .onKeyPress(.leftArrow) { previewer.step(-1); return .handled }
            .onKeyPress(.rightArrow) { previewer.step(1); return .handled }
            .transition(.opacity)
        }
    }

    /// The arrows to the next file, when the message has more than one.
    @ViewBuilder
    private func side(_ step: Int, _ icon: String, help: String) -> some View {
        if previewer.items.count > 1 {
            RoundAction(icon, help: help) { previewer.step(step) }
                .frame(maxHeight: .infinity)
        }
    }

    /// A picture as itself, fitted to the room; anything else in Quick Look.
    @ViewBuilder
    private func shown(_ file: Attachment) -> some View {
        if let path = file.path, FileManager.default.fileExists(atPath: path) {
            if Previewer.isPicture(file), let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    // Never larger than it is.
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                    .onTapGesture(count: 2) { previewer.toggleEnlarged() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                QuickLookView(url: URL(fileURLWithPath: path))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView(.vertical) {
                Text(file.text.isEmpty ? "This file is no longer where it was, and no text was kept from it." : file.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.ink.opacity(0.88))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).fill(Theme.shade.opacity(0.95)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A round button beside a preview.
private struct RoundAction: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    init(_ icon: String, help: String, action: @escaping () -> Void) {
        self.icon = icon
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(hover ? 1 : 0.85))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(hover ? 0.18 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// The preview itself: a bar of actions above the file, the same whether
/// over the chat or filling the screen.
struct PreviewContent: View {
    let enlarged: Bool
    @ObservedObject private var previewer = Previewer.shared
    @FocusState private var focused: Bool

    var body: some View {
        if let file = previewer.current {
            VStack(spacing: 0) {
                bar(file)
                Rectangle().fill(Theme.ink.opacity(0.08)).frame(height: 1)
                content(of: file)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(file.id)
            }
            .background(RoundedRectangle(cornerRadius: enlarged ? 0 : Theme.cardRadius, style: .continuous)
                .fill(Theme.shade.opacity(enlarged ? 0.97 : 0.94)))
            .clipShape(RoundedRectangle(cornerRadius: enlarged ? 0 : Theme.cardRadius, style: .continuous))
            .shadow(color: .black.opacity(enlarged ? 0 : 0.3), radius: 18, y: 8)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onAppear { focused = true }
            .onKeyPress(.escape) {
                if enlarged { previewer.toggleEnlarged() } else { previewer.close() }
                return .handled
            }
            .onKeyPress(.leftArrow) { previewer.step(-1); return .handled }
            .onKeyPress(.rightArrow) { previewer.step(1); return .handled }
        }
    }

    private func bar(_ file: Attachment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: Previewer.isPicture(file) ? "photo" : (file.isFolder == true ? "folder" : "doc"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(file.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
            if previewer.items.count > 1 {
                Text("\(previewer.index + 1) of \(previewer.items.count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink.opacity(0.5))
                IconButton("chevron.left", help: "Previous (←)") { previewer.step(-1) }
                IconButton("chevron.right", help: "Next (→)") { previewer.step(1) }
            }
            Spacer(minLength: 6)
            if file.path != nil {
                IconButton("arrow.up.forward.app", help: "Open in its own app") { previewer.openInDefaultApp() }
                IconButton("folder", help: "Show in Finder") { previewer.showInFinder() }
            }
            IconButton("doc.on.doc", help: "Copy") { previewer.copy() }
            IconButton("trash", help: "Remove from this chat (the file itself is kept)") { previewer.remove() }
            IconButton(enlarged ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       help: enlarged ? "Back to the panel (Esc)" : "Fill the screen",
                       tint: Theme.accent) { previewer.toggleEnlarged() }
            IconButton("xmark", help: "Close (Esc)") { previewer.close() }
        }
        .padding(.horizontal, 10)
        .padding(.top, enlarged ? 10 + (NSScreen.main?.safeAreaInsets.top ?? 0) : 8)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func content(of file: Attachment) -> some View {
        if let path = file.path, FileManager.default.fileExists(atPath: path) {
            if Previewer.isPicture(file), let image = NSImage(contentsOfFile: path) {
                ZoomableImage(image: image)
            } else {
                QuickLookView(url: URL(fileURLWithPath: path))
            }
        } else {
            // Attached before files were kept by path, or moved since: what
            // was read from it is still here.
            ScrollView(.vertical) {
                Text(file.text.isEmpty ? "This file is no longer where it was, and no text was kept from it." : file.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.ink.opacity(0.88))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
    }
}

/// A picture that can be pinched or scrolled to zoom (double-click fits it
/// again), on AppKit's own magnifying scroll view.
private struct ZoomableImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 8
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let view = FitImageView()
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.frame = NSRect(origin: .zero, size: image.size)
        scroll.documentView = view
        context.coordinator.scroll = scroll
        DispatchQueue.main.async { context.coordinator.fit() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        weak var scroll: NSScrollView?

        /// The whole picture in view, never blown up past its own size.
        func fit() {
            guard let scroll, let view = scroll.documentView else { return }
            let room = scroll.contentSize
            let size = view.frame.size
            guard size.width > 0, size.height > 0 else { return }
            let scale = min(1, min(room.width / size.width, room.height / size.height))
            scroll.magnification = scale
            view.scroll(NSPoint(x: 0, y: 0))
        }
    }

    /// Double-click goes back to the whole picture, or to its real size.
    private final class FitImageView: NSImageView {
        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 2, let scroll = enclosingScrollView, let size = image?.size else {
                super.mouseDown(with: event)
                return
            }
            let room = scroll.contentSize
            let fit = min(1, min(room.width / size.width, room.height / size.height))
            let target: CGFloat = abs(scroll.magnification - fit) < 0.01 ? 1 : fit
            let point = convert(event.locationInWindow, from: nil)
            scroll.setMagnification(target, centeredAt: point)
        }
    }
}

/// The Mac's Quick Look previewer: PDFs, Office and iWork files, video,
/// code, and anything else macOS knows how to show.
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}


/// Every file of the chat, as a chat app's Uploads: the list on the left,
/// the one picked large on the right with its name, type, download and close.
private struct UploadsBrowser: View {
    @ObservedObject private var previewer = Previewer.shared
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { previewer.close() }
            GeometryReader { geometry in
                let wide = geometry.size.width > 620
                HStack(spacing: 0) {
                    if wide {
                        list
                            .frame(width: min(300, geometry.size.width * 0.36))
                        Rectangle().fill(Theme.ink.opacity(0.08)).frame(width: 1)
                    }
                    preview(wide: wide)
                }
                .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.shade.opacity(0.97)))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.ink.opacity(0.12), lineWidth: 0.75))
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                .padding(18)
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.escape) { previewer.close(); return .handled }
        .onKeyPress(.upArrow) { previewer.step(-1); return .handled }
        .onKeyPress(.downArrow) { previewer.step(1); return .handled }
        .onKeyPress(.leftArrow) { previewer.step(-1); return .handled }
        .onKeyPress(.rightArrow) { previewer.step(1); return .handled }
    }

    private static func kind(_ file: Attachment) -> String {
        let ext = ((file.path ?? file.name) as NSString).pathExtension
        return ext.isEmpty ? "FILE" : ext.uppercased()
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Uploads")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.92))
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 10)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(previewer.items.enumerated()), id: \.element.id) { index, file in
                            UploadRow(file: file, kind: Self.kind(file), selected: index == previewer.index) {
                                previewer.index = index
                            }
                            .id(file.id)
                            if index < previewer.items.count - 1 {
                                Rectangle().fill(Theme.ink.opacity(0.06)).frame(height: 1).padding(.horizontal, 14)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 10)
                }
                .onChange(of: previewer.index) { _, _ in
                    if let id = previewer.current?.id { withAnimation { proxy.scrollTo(id) } }
                }
            }
        }
    }

    @ViewBuilder
    private func preview(wide: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if !wide, previewer.items.count > 1 {
                    IconButton("chevron.left", help: "Previous") { previewer.step(-1) }
                    IconButton("chevron.right", help: "Next") { previewer.step(1) }
                }
                if let file = previewer.current {
                    Text(((file.name) as NSString).deletingPathExtension)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Self.kind(file))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.ink.opacity(0.45))
                }
                Spacer(minLength: 6)
                if previewer.current?.path != nil {
                    IconButton("arrow.down.to.line", help: "Save to Downloads") { previewer.download() }
                    IconButton("arrow.up.forward.app", help: "Open in its own app") { previewer.openInDefaultApp() }
                }
                IconButton("xmark", help: "Close (Esc)") { previewer.close() }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            if let file = previewer.current {
                PreviewBody(file: file)
                    .id(file.id)
                    .padding(wide ? 22 : 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct UploadRow: View {
    let file: Attachment
    let kind: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Previewer.isPicture(file) ? "photo" : "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink.opacity(0.6))
                .frame(width: 18)
            Text((file.name as NSString).deletingPathExtension)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(kind)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.42))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .fill(Theme.ink.opacity(selected ? 0.1 : (hover ? 0.05 : 0))))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
        .help(file.path ?? file.name)
    }
}

/// A file as itself: a picture fitted to the room, else Quick Look, else
/// the text kept from it.
private struct PreviewBody: View {
    let file: Attachment

    var body: some View {
        if let path = file.path, FileManager.default.fileExists(atPath: path) {
            if Previewer.isPicture(file), let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                QuickLookView(url: URL(fileURLWithPath: path))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            }
        } else {
            ScrollView(.vertical) {
                Text(file.text.isEmpty ? "This file is no longer where it was, and no text was kept from it." : file.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.ink.opacity(0.88))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
