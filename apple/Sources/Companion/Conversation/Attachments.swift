import Foundation
import AppKit
import PDFKit

/// A file attached to a conversation. Only its extracted text is kept, so the
/// conversation stays self-contained even if the original file moves.
struct Attachment: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var text: String
    /// Where it lives on this Mac, so the agent can open or change it.
    var path: String? = nil
    /// A whole folder: `text` is its listing plus the readable files in it.
    var isFolder: Bool? = nil
}

/// Pulls readable text out of common file types.
enum FileTextExtractor {
    /// Whole documents are kept: only the relevant passages are sent to the model.
    static let perFileLimit = 300_000

    @MainActor
    static func extract(_ url: URL) async -> String? {
        var text: String?
        switch url.pathExtension.lowercased() {
        case "pdf":
            text = PDFDocument(url: url)?.string
        case "png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp", "webp":
            if let image = NSImage(contentsOf: url),
               let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                text = try? await ScreenReader.recognizeText(in: cgImage)
            }
        case "rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive":
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        default:
            // Plain text, markdown, code, CSV, JSON, ... Anything with NUL
            // bytes near the start is treated as binary and refused.
            if let data = try? Data(contentsOf: url), !data.prefix(4096).contains(0) {
                text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            }
        }
        guard let cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else {
            return nil
        }
        return String(cleaned.prefix(perFileLimit))
    }

    private static let skippedFolders: Set<String> = [
        "node_modules", "build", "dist", "DerivedData", "Pods", "venv", "__pycache__", "target"
    ]
    private static let textKinds: Set<String> = [
        "md", "txt", "swift", "py", "js", "ts", "tsx", "jsx", "json", "yaml", "yml", "toml", "csv", "html",
        "css", "sh", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "m", "sql", "xml", "plist", "tex", "ini", "cfg"
    ]

    /// A folder as context: what is in it (up to 500 entries, hidden and
    /// build folders left out), followed by the contents of its smaller
    /// text files until the per-attachment limit is reached. The model gets
    /// the shape of the folder and the passages that matter; the agent can
    /// open anything else by path.
    static func extractFolder(_ url: URL) -> String {
        var listing: [String] = []
        var bodies: [String] = []
        var used = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return "Folder at \(url.path)"
        }
        var visited = 0
        while let item = walker.nextObject() as? URL {
            // A very large folder is sampled, not walked to the end.
            visited += 1
            if visited > 5000 { break }
            let values = try? item.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory ?? false
            if isFolder, skippedFolders.contains(item.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            let relative = String(item.path.dropFirst(url.path.count + 1))
            if listing.count < 500 {
                listing.append(isFolder ? relative + "/" : relative)
            }
            guard !isFolder, textKinds.contains(item.pathExtension.lowercased()),
                  (values?.fileSize ?? .max) <= 40_000, used < perFileLimit - 60_000,
                  let data = try? Data(contentsOf: item), !data.prefix(4096).contains(0),
                  let text = String(data: data, encoding: .utf8) else { continue }
            bodies.append("### \(relative)\n\(text)")
            used += text.count
        }
        let more = listing.count >= 500 || visited > 5000 ? "\n(more files not listed)" : ""
        return """
        Folder at \(url.path). The agent can read and change files here.

        ## Contents
        \(listing.joined(separator: "\n"))\(more)

        \(bodies.joined(separator: "\n\n"))
        """
    }
}
