import AppKit
import SwiftUI

// The Design Gallery: every token and glass component of the design system,
// in light and dark at the three widths, with Reduce Transparency, Increase
// Contrast and Reduce Motion to preview. Debug > Design Gallery opens it
// beside the panel; launching with `--design-gallery` opens it alone.

// MARK: - Opening it

@MainActor
enum DesignGallery {
    static let launchArgument = "--design-gallery"
    static var launchesAlone: Bool { ProcessInfo.processInfo.arguments.contains(launchArgument) }

    static var window: NSWindow?

    static func open() {
        if window == nil {
            let made = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
            made.title = "Design Gallery"
            made.isReleasedWhenClosed = false
            made.contentView = NSHostingView(rootView: DesignGalleryView())
            made.center()
            // Opens on the Space in use, even beside a full-screen app.
            made.collectionBehavior.insert(.moveToActiveSpace)
            window = made
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // macOS may not let the app come forward (a launch from the shell,
        // another app in use); the window is shown all the same.
        window?.orderFrontRegardless()
    }

    // MARK: Debug menu

    static let menuTitle = "Debug"
    static let menuTarget = DesignGalleryMenuTarget()
    static var activation: NSObjectProtocol?

    /// Puts Debug > Design Gallery into the app's menus. They only show
    /// with "Show in menu bar" on, and are put back when the app comes
    /// forward, so the item is added again then if it is missing.
    static func installMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { addMenu() }
        guard activation == nil else { return }
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            // After the app delegate has put its menus back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated { addMenu() }
            }
        }
    }

    static func addMenu() {
        guard let main = NSApp.mainMenu, !main.items.isEmpty,
              !main.items.contains(where: { $0.title == menuTitle }) else { return }
        let item = NSMenuItem(title: "Design Gallery",
                              action: #selector(DesignGalleryMenuTarget.openGallery(_:)),
                              keyEquivalent: "")
        item.target = menuTarget
        let menu = NSMenu(title: menuTitle)
        menu.addItem(item)
        let top = NSMenuItem(title: menuTitle, action: nil, keyEquivalent: "")
        top.submenu = menu
        // Before Window and Help, where Xcode and Safari keep theirs.
        let before = main.items.firstIndex { entry in
            guard let submenu = entry.submenu else { return false }
            return submenu === NSApp.windowsMenu || submenu === NSApp.helpMenu
        }
        main.insertItem(top, at: before ?? main.items.count)
    }
}

@MainActor
final class DesignGalleryMenuTarget: NSObject {
    @objc func openGallery(_ sender: Any?) {
        DesignGallery.open()
    }
}

/// The gallery on its own, for `--design-gallery`: no panel, no shortcuts,
/// nothing else Companion starts.
struct DesignGalleryApp: App {
    @NSApplicationDelegateAdaptor(DesignGalleryAppDelegate.self) var delegate

    var body: some Scene {
        // The window is opened by the delegate (`DesignGallery.open`), the
        // same one Debug > Design Gallery opens.
        Settings { EmptyView() }
    }
}

@MainActor
final class DesignGalleryAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DesignGallery.open()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - The gallery

struct DesignGalleryView: View {
    enum Widths: Hashable { case compact, regular, wide, all }
    enum Schemes: Hashable { case light, dark, both }

    @State var widths: Widths = .all
    @State var schemes: Schemes = .both
    @State var density: Design.Density = .regular
    @State var preview = DesignAccessibility()

    var shownWidths: [Design.WidthClass] {
        switch widths {
        case .compact: [.compact]
        case .regular: [.regular]
        case .wide: [.wide]
        case .all: Design.WidthClass.allCases
        }
    }

    var shownSchemes: [ColorScheme] {
        switch schemes {
        case .light: [.light]
        case .dark: [.dark]
        case .both: [.light, .dark]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, Design.Space.l)
                .padding(.vertical, Design.Space.s)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: Design.Space.xxl) {
                    ForEach(shownWidths, id: \.self) { width in
                        VStack(alignment: .leading, spacing: Design.Space.s) {
                            Text("\(width.name), \(Int(width.sampleWidth)) points")
                                .textRole(.title)
                            HStack(alignment: .top, spacing: Design.Space.xl) {
                                ForEach(shownSchemes, id: \.self) { scheme in
                                    GallerySpecimen(width: width, scheme: scheme)
                                }
                            }
                        }
                    }
                }
                .padding(Design.Space.xl)
            }
        }
        .environment(\.designPreview, preview)
        .environment(\.density, density)
        .frame(minWidth: 560, minHeight: 420)
    }

    var controls: some View {
        AdaptiveStack(columnsAt: nil) {
            HStack(spacing: Design.Space.s) {
                Picker("Width", selection: $widths) {
                    Text("Compact").tag(Widths.compact)
                    Text("Regular").tag(Widths.regular)
                    Text("Wide").tag(Widths.wide)
                    Text("All").tag(Widths.all)
                }
                Picker("Appearance", selection: $schemes) {
                    Text("Light").tag(Schemes.light)
                    Text("Dark").tag(Schemes.dark)
                    Text("Both").tag(Schemes.both)
                }
                Picker("Density", selection: $density) {
                    ForEach(Design.Density.allCases, id: \.self) { density in
                        Text(density.name).tag(density)
                    }
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            HStack(spacing: Design.Space.s) {
                Toggle("Reduce Transparency", isOn: $preview.reduceTransparency)
                Toggle("Increase Contrast", isOn: $preview.increaseContrast)
                Toggle("Reduce Motion", isOn: $preview.reduceMotion)
            }
            .help("Previews the setting here. The system's own setting applies as well.")
            .fixedSize()
        }
        .controlSize(.small)
    }
}

/// One width in one appearance.
struct GallerySpecimen: View {
    let width: Design.WidthClass
    let scheme: ColorScheme

    var body: some View {
        SpecimenContent(scheme: scheme)
            .padding(Design.Space.l)
            .readsWidthClass()
            .frame(width: width.sampleWidth, alignment: .topLeading)
            .background(Design.Fill.content.style)
            .clipShape(Design.Radius.shape(Design.Radius.card))
            .overlay(Design.Radius.shape(Design.Radius.card).strokeBorder(.quaternary))
            .environment(\.colorScheme, scheme)
    }
}

struct SpecimenContent: View {
    let scheme: ColorScheme
    @Environment(\.widthClass) var widthClass
    @Environment(\.density) var density

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xl) {
            HStack {
                Text(scheme == .dark ? "Dark" : "Light").textRole(.heading)
                Spacer(minLength: Design.Space.s)
                Text("Width class: \(widthClass.name), density: \(density.name)")
                    .textRole(.label, .secondary)
            }
            GallerySection(title: "Colors") { ColorTokens() }
            GallerySection(title: "Spacing") { SpacingTokens() }
            GallerySection(title: "Corners") { RadiusTokens() }
            GallerySection(title: "Type") { TypeTokens() }
            GallerySection(title: "Controls") { ControlTokens() }
            GallerySection(title: "Icons and digits") { IconRows() }
            GallerySection(title: "Motion") { MotionTokens() }
            GallerySection(title: "Glass") { GlassComponents() }
            GallerySection(title: "Size rules") { SizeRulesDemo() }
            GallerySection(title: "Morph") { MorphDemo() }
        }
    }
}

struct GallerySection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            Text(title).textRole(.heading, .secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Tokens

struct ColorTokens: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: Design.Space.xs)],
                      alignment: .leading, spacing: Design.Space.xs) {
                ForEach(Design.Tone.allCases, id: \.self) { tone in
                    HStack(spacing: Design.Space.xs) {
                        Circle()
                            .fill(tone.color)
                            .frame(width: Design.Icon.small.width, height: Design.Icon.small.width)
                        Text(tone.rawValue).textRole(.label)
                    }
                }
            }
            HStack(spacing: Design.Space.m) {
                ForEach(Design.TextLevel.allCases, id: \.self) { level in
                    Text(level.rawValue).textRole(.body, level)
                }
            }
            HStack(spacing: Design.Space.xs) {
                ForEach(Design.Fill.allCases, id: \.self) { fill in
                    Text(fill.rawValue)
                        .textRole(.caption, .secondary)
                        .padding(Design.Space.xs)
                        .frame(maxWidth: .infinity)
                        .background(fill.style, in: Design.Radius.shape(Design.Radius.control))
                        .overlay(Design.Radius.shape(Design.Radius.control).strokeBorder(.quaternary))
                }
            }
        }
    }
}

struct SpacingTokens: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Design.Space.s, verticalSpacing: Design.Space.xxs) {
            ForEach(Design.Space.all, id: \.self) { step in
                GridRow {
                    Text(step.name).textRole(.code, .secondary)
                    Text("\(Int(step.value))").textRole(.number).gridColumnAlignment(.trailing)
                    Rectangle()
                        .fill(Design.Tone.accent.color)
                        .frame(width: step.value, height: Design.Space.xs)
                }
            }
        }
    }
}

struct RadiusTokens: View {
    var body: some View {
        let outer = Design.Radius.card
        let inset = Design.Space.xs
        let inner = Design.Radius.concentric(outer, inset: inset)
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(alignment: .bottom, spacing: Design.Space.s) {
                ForEach(Design.Radius.all, id: \.self) { step in
                    VStack(spacing: Design.Space.xxs) {
                        Design.Radius.shape(step.value)
                            .fill(.background.secondary)
                            .overlay(Design.Radius.shape(step.value).strokeBorder(.tertiary))
                            .frame(width: Design.Space.xxl * 2, height: Design.Control.large.height)
                        Text("\(step.name) \(Int(step.value))").textRole(.caption, .secondary)
                    }
                }
            }
            HStack(spacing: Design.Space.s) {
                Design.Radius.shape(outer)
                    .fill(.background.secondary)
                    .overlay(
                        Design.Radius.shape(inner)
                            .fill(Design.Tone.accent.color.opacity(0.3))
                            .padding(inset)
                    )
                    .frame(width: Design.Space.xxl * 4, height: Design.Space.xxl * 2)
                Text("Concentric: card \(Int(outer)), inset \(Int(inset)), inner \(Int(inner))")
                    .textRole(.caption, .secondary)
            }
        }
    }
}

struct TypeTokens: View {
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Design.Space.s,
             verticalSpacing: Design.Space.xs) {
            ForEach(Design.TextRole.allCases, id: \.self) { role in
                GridRow {
                    Text(role.rawValue).textRole(.caption, .secondary)
                    Text(role.sample).textRole(role)
                }
            }
        }
    }
}

struct ControlTokens: View {
    @State var on = true
    @State var mode = "Agent"

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Design.Space.s, verticalSpacing: Design.Space.s) {
            ForEach(Design.Control.allCases, id: \.self) { size in
                GridRow {
                    Text("\(size.rawValue) \(Int(size.height))").textRole(.caption, .secondary)
                    Button("Glass") {}.glassButton(size: size)
                    Button("Prominent") {}.glassButton(.prominent, size: size)
                    Toggle("On", isOn: $on)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(size.system)
                    Picker("Mode", selection: $mode) {
                        ForEach(["Ask", "Plan", "Agent", "Review"], id: \.self) { Text($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(size.system)
                }
            }
        }
    }
}

struct IconRows: View {
    struct Row: Hashable {
        let symbol: String
        let label: String
        let value: Int
    }

    let rows = [
        Row(symbol: "folder", label: "Files", value: 1204),
        Row(symbol: "doc.text", label: "Lines changed", value: 38),
        Row(symbol: "clock", label: "Minutes", value: 7),
        Row(symbol: "checkmark.circle", label: "Tasks done", value: 112),
    ]
    @Environment(\.density) var density

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: Design.Space.xs) {
                    Image(systemName: row.symbol)
                        .iconWidth(density.icon)
                        .foregroundStyle(.secondary)
                    Text(row.label).textRole(density.textRole)
                    Spacer(minLength: Design.Space.s)
                    Text(row.value, format: .number).textRole(.number)
                }
                .frame(height: density.rowHeight)
            }
        }
        .frame(maxWidth: Design.readableWidth / 2)
    }
}

struct MotionTokens: View {
    @State var moved = false
    var access = DesignAccess()

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            Button(moved ? "Back" : "Play") { moved.toggle() }
                .glassButton(size: .small)
            ForEach(Design.Motion.allCases, id: \.self) { motion in
                HStack(spacing: Design.Space.s) {
                    Text(motion.rawValue).textRole(.caption, .secondary)
                        .frame(width: Design.Space.xxl * 2, alignment: .leading)
                    track(motion)
                }
            }
            Text(access.reduceMotion ? "Reduce Motion: each dot fades across." : "Each dot moves on its spring.")
                .textRole(.caption, .secondary)
        }
        .frame(maxWidth: Design.readableWidth / 2, alignment: .leading)
    }

    @ViewBuilder
    func track(_ motion: Design.Motion) -> some View {
        let dot = Circle()
            .fill(Design.Tone.accent.color)
            .frame(width: Design.Space.s, height: Design.Space.s)
        ZStack(alignment: moved ? .trailing : .leading) {
            Capsule().fill(.quaternary).frame(height: Design.Space.xxs)
            if access.reduceMotion {
                dot.id(moved).transition(.opacity)
            } else {
                dot
            }
        }
        .designAnimation(motion, value: moved)
    }
}

// MARK: - Glass

/// Something for glass to sit over: a wash of the look's colors and lines of
/// content, as the conversation would be behind a panel.
struct GlassBackdrop: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Design.Tone.accent.color, Design.Tone.info.color, Design.Tone.positive.color],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(0.55)
            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                ForEach(0..<16) { _ in
                    Text("Content behind the glass: messages, code and documents sit here, never on glass.")
                        .textRole(.caption, .secondary)
                        .lineLimit(1)
                }
            }
            .padding(Design.Space.s)
        }
    }
}

struct GalleryToolbarIcon: View {
    let title: String
    let symbol: String

    var body: some View {
        Button {} label: {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .iconWidth(.regular)
                .frame(height: Design.Control.regular.height)
                .padding(.horizontal, Design.Space.xxs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
    }
}

struct GlassComponents: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            GlassSectionHeader("Section header", symbol: "square.stack")
            AdaptiveStack(rowAlignment: .top) {
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    Text("Floating panel").textRole(.heading)
                    Text("Text on glass is primary or secondary.").textRole(.label, .secondary)
                    HStack(spacing: Design.Space.xs) {
                        Button("Cancel") {}.glassButton(size: .small)
                        Button("Run") {}.glassButton(.prominent, size: .small)
                    }
                }
                .padding(Design.Space.m)
                .glassPanel()
                GlassGroup(spacing: Design.Space.xs) {
                    HStack(spacing: Design.Space.xxs) {
                        GalleryToolbarIcon(title: "Sidebar", symbol: "sidebar.left")
                        GalleryToolbarIcon(title: "Search", symbol: "magnifyingglass")
                        GalleryToolbarIcon(title: "Share", symbol: "square.and.arrow.up")
                    }
                    .glassToolbarGroup()
                }
            }
            HStack(spacing: Design.Space.xs) {
                Button("Glass button") {}.glassButton()
                Button("Prominent button") {}.glassButton(.prominent)
            }
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                Text("No glass on glass: the group inside this panel draws flat.")
                    .textRole(.label, .secondary)
                HStack(spacing: Design.Space.xxs) {
                    GalleryToolbarIcon(title: "Bold", symbol: "bold")
                    GalleryToolbarIcon(title: "Italic", symbol: "italic")
                }
                .glassToolbarGroup()
            }
            .padding(Design.Space.m)
            .glassPanel(radius: Design.Radius.card)
        }
        .padding(Design.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { GlassBackdrop() }
        .clipShape(Design.Radius.shape(Design.Radius.card))
    }
}

// MARK: - Size rules

struct SizeRulesDemo: View {
    @Environment(\.widthClass) var widthClass
    @Environment(\.density) var density

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Text("Compact under \(Int(Design.WidthClass.regularFrom)) points, regular to \(Int(Design.WidthClass.wideFrom)), wide above. This one is \(widthClass.name.lowercased()).")
                .textRole(.label, .secondary)
            AdaptiveStack(rowAlignment: .top) {
                ForEach(["Plan", "Build", "Review"], id: \.self) { step in
                    VStack(alignment: .leading, spacing: Design.Space.xxs) {
                        Text(step).textRole(.heading)
                        Text("A row of cards becomes a column when space runs out.")
                            .textRole(.caption, .secondary)
                    }
                    .padding(density.inset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Design.Fill.raised.style, in: Design.Radius.shape(Design.Radius.tile))
                }
            }
            AdaptiveStack(rowAlignment: .top) {
                ForEach(Design.Density.allCases, id: \.self) { kind in
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(kind.name) density").textRole(.caption, .secondary)
                        ForEach(["Inbox", "Tasks", "Runs"], id: \.self) { name in
                            HStack(spacing: Design.Space.xs) {
                                Image(systemName: "tray").iconWidth(kind.icon).foregroundStyle(.secondary)
                                Text(name).textRole(kind.textRole)
                                Spacer(minLength: kind.gap)
                            }
                            .padding(.horizontal, kind.inset)
                            .frame(height: kind.rowHeight)
                            .background(Design.Fill.raised.style, in: Design.Radius.shape(Design.Radius.control))
                            .padding(.vertical, Design.Space.xxs / 2)
                        }
                    }
                }
            }
            ReadableColumn {
                Text("A readable column keeps running text near seventy characters a line, however wide the window grows. At compact and regular widths it simply fills the space; at wide it stays at \(Int(Design.readableWidth)) points and centres.")
                    .textRole(.body)
                    .padding(density.inset)
                    .background(Design.Fill.raised.style, in: Design.Radius.shape(Design.Radius.tile))
            }
        }
    }
}

// MARK: - Morph

struct MorphDemo: View {
    @Namespace var glass
    @State var expanded = false
    var access = DesignAccess()

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Button(expanded ? "Collapse" : "Expand") {
                withAnimation(Design.Motion.morph.animation(reduceMotion: access.reduceMotion)) {
                    expanded.toggle()
                }
            }
            .glassButton(size: .small)
            GlassGroup(spacing: Design.Space.m) {
                if expanded {
                    VStack(alignment: .leading, spacing: Design.Space.xs) {
                        Label("Three tasks running", systemImage: "bolt.horizontal.circle")
                            .textRole(.heading)
                        ForEach(["Tokens", "Glass surfaces", "Gallery"], id: \.self) { name in
                            Label(name, systemImage: "circle.dotted").textRole(.label, .secondary)
                        }
                    }
                    .padding(Design.Space.m)
                    .frame(maxWidth: Design.readableWidth / 2, alignment: .leading)
                    .glassPanel(radius: Design.Radius.card)
                    .glassMorph("activity", in: glass)
                } else {
                    Label("3 running", systemImage: "bolt.horizontal.circle")
                        .textRole(.label)
                        .padding(.horizontal, Design.Space.s)
                        .frame(height: Design.Control.regular.height)
                        .glassSurface(Capsule())
                        .glassMorph("activity", in: glass)
                }
            }
            .padding(Design.Space.m)
            .frame(maxWidth: .infinity, minHeight: Design.Space.xxl * 5, alignment: .topLeading)
            .background { GlassBackdrop() }
            .clipShape(Design.Radius.shape(Design.Radius.card))
            Text(access.reduceMotion
                 ? "Reduce Motion: the pill and the panel fade into each other."
                 : "The pill morphs into the panel and back.")
                .textRole(.caption, .secondary)
        }
    }
}