import Foundation
import AppKit
import PDFKit

/// A file attached to a conversation. Only its extracted text is kept, so the
/// conversation stays self-contained even if the original file moves.
struct Attachment: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var text: String
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
}
