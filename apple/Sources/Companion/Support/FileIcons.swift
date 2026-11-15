import AppKit
import SwiftUI

/// File and folder icons as VS Code's Material Icon Theme draws them: a
/// coloured icon per language and file type, and folders by what they
/// usually hold (src, tests, docs, config...). The icons and the theme's
/// name-to-icon map ship with the app (Resources/FileIcons.tar.gz, unpacked
/// into the app by build.sh; MIT licensed, see its LICENSE).
///
/// Lookup follows the theme's rules: an exact file name first, then the
/// longest extension ("d.ts" before "ts"), then the plain file icon.
@MainActor
enum FileIcons {
    private struct IconTheme {
        var folder = "folder", folderOpen = "folder-open", rootFolder = "folder", rootFolderOpen = "folder-open"
        var file = "file"
        var folderNames: [String: String] = [:], folderNamesOpen: [String: String] = [:]
        var rootNames: [String: String] = [:], rootNamesOpen: [String: String] = [:]
        var extensions: [String: String] = [:], fileNames: [String: String] = [:]
    }

    private static var dark = IconTheme()
    private static var light = IconTheme()
    private static var files: [String: String] = [:]
    private static var loaded = false
    private static let images = NSCache<NSString, NSImage>()

    private static var folder: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("FileIcons", isDirectory: true)
    }

    private static func load() {
        guard !loaded else { return }
        loaded = true
        guard let url = folder?.appendingPathComponent("material-icons.json"),
              let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        files = json["files"] as? [String: String] ?? [:]
        func theme(_ object: [String: Any], base: IconTheme) -> IconTheme {
            var theme = base
            func map(_ key: String) -> [String: String]? { object[key] as? [String: String] }
            theme.folder = object["folder"] as? String ?? theme.folder
            theme.folderOpen = object["folderExpanded"] as? String ?? theme.folderOpen
            theme.rootFolder = object["rootFolder"] as? String ?? theme.rootFolder
            theme.rootFolderOpen = object["rootFolderExpanded"] as? String ?? theme.rootFolderOpen
            theme.file = object["file"] as? String ?? theme.file
            // The light theme only names what differs; the rest is the dark one's.
            if let names = map("folderNames") { theme.folderNames.merge(names) { $1 } }
            if let names = map("folderNamesExpanded") { theme.folderNamesOpen.merge(names) { $1 } }
            if let names = map("rootFolderNames") { theme.rootNames.merge(names) { $1 } }
            if let names = map("rootFolderNamesExpanded") { theme.rootNamesOpen.merge(names) { $1 } }
            if let names = map("fileExtensions") { theme.extensions.merge(names) { $1 } }
            if let names = map("fileNames") { theme.fileNames.merge(names) { $1 } }
            return theme
        }
        dark = theme(json, base: IconTheme())
        light = theme(json["light"] as? [String: Any] ?? [:], base: dark)
    }

    /// The icon id for a file or folder.
    private static func id(for name: String, isFolder: Bool, open: Bool, root: Bool, light useLight: Bool) -> String {
        load()
        let theme = useLight ? light : dark
        let key = name.lowercased()
        if isFolder {
            if root {
                return (open ? theme.rootNamesOpen[key] : theme.rootNames[key]) ?? (open ? theme.rootFolderOpen : theme.rootFolder)
            }
            return (open ? theme.folderNamesOpen[key] : theme.folderNames[key]) ?? (open ? theme.folderOpen : theme.folder)
        }
        if let exact = theme.fileNames[key] { return exact }
        // ".env.local" tries "env.local" then "local"; "a.d.ts" tries "d.ts" then "ts".
        var rest = Substring(key)
        while let dot = rest.firstIndex(of: ".") {
            rest = rest[rest.index(after: dot)...]
            if !rest.isEmpty, let found = theme.extensions[String(rest)] { return found }
        }
        return theme.file
    }

    static func image(for name: String, isFolder: Bool, open: Bool = false, root: Bool = false, light: Bool = false) -> NSImage? {
        let id = id(for: name, isFolder: isFolder, open: open, root: root, light: light)
        if let cached = images.object(forKey: id as NSString) { return cached }
        guard let file = files[id], let url = folder?.appendingPathComponent(file),
              let image = NSImage(contentsOf: url) else { return nil }
        images.setObject(image, forKey: id as NSString)
        return image
    }
}

/// A file's or folder's icon from the theme, with a plain symbol when the
/// icons are not in the app (a build without them).
struct FileIcon: View {
    let name: String
    var isFolder = false
    var open = false
    var root = false
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let image = FileIcons.image(for: name, isFolder: isFolder, open: open, root: root, light: scheme == .light) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: isFolder ? "folder" : "doc")
                .font(.system(size: size * 0.66))
                .foregroundStyle(isFolder ? Theme.accent.opacity(0.9) : Theme.ink.opacity(0.55))
                .frame(width: size, height: size)
        }
    }
}
