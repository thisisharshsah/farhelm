import AppKit
import SwiftUI

// Renders every board mock-up at the design system's three sample widths,
// light and dark, to PNG files. It stands in for T-17's
// apple/scripts/snapshots.sh, which is not on companion/main and renders
// only the running app's own panel; render.sh beside this file builds and
// runs it. When a CompanionSnapshots target exists, the catalog moves there.

struct Mockup {
    let slug: String
    let view: () -> AnyView
}

@MainActor
enum MockupCatalog {
    static let all: [Mockup] = [
        Mockup(slug: "kanban") { AnyView(KanbanMockup()) },
        Mockup(slug: "table") { AnyView(TableMockup()) },
        Mockup(slug: "workload") { AnyView(WorkloadMockup()) },
        Mockup(slug: "card") { AnyView(CardMockup()) },
        Mockup(slug: "rules") { AnyView(RulesMockup()) },
        Mockup(slug: "side-panel") { AnyView(SidePanelMockup()) },
    ]
}

@MainActor
enum MockupRenderer {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: render OUTPUT-FOLDER\n".utf8))
            exit(2)
        }
        do {
            try render(to: URL(fileURLWithPath: arguments[1], isDirectory: true))
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static func render(to output: URL) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            // Shared views read the look from here, as the app sets it at launch.
            Design.palette = { dark ? .dark : .light }
            guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else {
                throw Failure(description: "no system appearance")
            }
            for mockup in MockupCatalog.all {
                for width in Design.WidthClass.allCases {
                    // A window that is never shown has no window server behind
                    // it, so Liquid Glass draws nothing and text on it loses
                    // its color. The pictures take the design system's own
                    // solid look (Reduce Transparency), and controls draw as
                    // in a focused window, so switches and the prominent
                    // button keep the accent.
                    let view = mockup.view()
                        .environment(\.designPreview, DesignAccessibility(reduceTransparency: true))
                        .environment(\.controlActiveState, .key)
                        .environment(\.widthClass, width)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .frame(width: width.sampleWidth)
                    let name = "\(mockup.slug)-\(width.name.lowercased())-\(dark ? "dark" : "light").png"
                    try write(view, appearance: appearance, to: output.appendingPathComponent(name))
                    print(name)
                }
            }
        }
    }

    /// Draws a view in a window that is never shown, so rendering needs no
    /// screen recording permission and nothing appears on the desktop.
    static func write(_ view: some View, appearance: NSAppearance, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        // Measured again once in the window: grids and wrapped text settle
        // only there, and a size taken before leaves empty bands above and
        // below the content.
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw Failure(description: "no bitmap for \(url.lastPathComponent)")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(description: "no PNG for \(url.lastPathComponent)")
        }
        try png.write(to: url)
    }
}