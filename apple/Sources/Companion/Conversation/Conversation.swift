import Foundation
import AppKit

enum TurnKind: String, Codable, Hashable {
    case reply   // speech / typed conversation thread
    case screen  // screen capture thread
}

enum TurnOrigin: String, Codable {
    case auto    // triggered by the other side finishing, or by the screen watcher
    case manual  // hotkey or button
    case typed   // the user wrote the prompt
}

/// One exchange in a thread: what was asked (or heard, or captured) and the answer.
struct ChatTurn: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: TurnKind
    var origin: TurnOrigin
    var prompt: String
    /// Screenshot thumbnail, a file name inside the conversation's image folder.
    var imageFile: String?
    /// OCR text of the capture, kept so the turn can be regenerated.
    var context: String?
    var answer: String = ""
    var error: String?
    /// Engine that produced the answer, e.g. "Farhelm · auto".
    var model: String
    var date = Date()
    /// Where the turn sits in the conversation: the time of the last line it
    /// answers. nil means it sits at `date`.
    var anchor: Date?
    /// How many words of the answer the user went on to say aloud.
    var spoken: Int?
    /// Which of the user's material the answer drew on (details, files,
    /// earlier conversations).
    var sources: [String]?
    /// Next steps offered after the answer; choosing one sends it as a message.
    var suggestions: [String]?
    /// Result of the last recheck: whether this reply answers something that
    /// was actually asked in the conversation. nil when not checked yet.
    var matched: Bool?
}

/// Whether a suggested reply was actually said.
enum TurnUsage {
    case used, partly, unused
}

struct SavedLine: Codable, Equatable {
    var isMe: Bool
    var tag: String?
    var text: String
    /// What was heard, when the line was polished afterwards.
    var original: String?
    /// Heard on the system-audio channel, so certainly not the user.
    var systemAudio: Bool?
    /// When it was said, so replies can be shown where they happened.
    var date: Date?
}

struct Conversation: Identifiable, Codable, Equatable {
    static let defaultTitle = "New conversation"

    var id = UUID()
    var title = Conversation.defaultTitle
    var createdAt = Date()
    var updatedAt = Date()
    var turns: [ChatTurn] = []
    var transcript: [SavedLine] = []
    /// Files attached as context. Optional so older saved conversations still decode.
    var attachments: [Attachment]?
    /// Running notes on the part of the conversation that has scrolled out of
    /// the recent window, so long conversations keep their beginning.
    var summary: String?
    /// How many saved transcript lines are already folded into `summary`.
    var summarizedLines: Int?
    /// The conversation written up as structured notes (Markdown) for later use.
    var record: String?
}

struct ConversationSummary: Identifiable, Equatable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let turnCount: Int
}

/// Conversations live as JSON files in Application Support/Companion/conversations,
/// with each conversation's screenshots in a sibling folder named after its id.
final class ConversationStore {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        directory = ContextStore.shared.baseDir.appendingPathComponent("conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func imageDirectory(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func imageURL(conversation: UUID, file: String) -> URL {
        imageDirectory(conversation).appendingPathComponent(file)
    }

    func list() -> [ConversationSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ConversationSummary? in
                guard let data = try? Data(contentsOf: url),
                      let conversation = try? decoder.decode(Conversation.self, from: data) else { return nil }
                return ConversationSummary(id: conversation.id,
                                           title: conversation.title,
                                           updatedAt: conversation.updatedAt,
                                           turnCount: conversation.turns.count)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Conversations whose title, transcript, answers or notes contain every
    /// word of the query, newest first.
    func search(_ query: String) -> [ConversationSummary] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return list() }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ConversationSummary? in
                guard let data = try? Data(contentsOf: url),
                      let conversation = try? decoder.decode(Conversation.self, from: data) else { return nil }
                var parts = [conversation.title, conversation.summary ?? "", conversation.record ?? ""]
                parts += conversation.transcript.map(\.text)
                parts += conversation.turns.flatMap { [$0.prompt, $0.answer] }
                let haystack = parts.joined(separator: "\n").lowercased()
                guard words.allSatisfy({ haystack.contains($0) }) else { return nil }
                return ConversationSummary(id: conversation.id,
                                           title: conversation.title,
                                           updatedAt: conversation.updatedAt,
                                           turnCount: conversation.turns.count)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(_ id: UUID) -> Conversation? {
        guard let data = try? Data(contentsOf: fileURL(id)) else { return nil }
        return try? decoder.decode(Conversation.self, from: data)
    }

    func save(_ conversation: Conversation) {
        guard let data = try? encoder.encode(conversation) else { return }
        try? data.write(to: fileURL(conversation.id), options: .atomic)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(id))
        try? FileManager.default.removeItem(at: imageDirectory(id))
    }

    func deleteImage(conversation: UUID, file: String) {
        try? FileManager.default.removeItem(at: imageURL(conversation: conversation, file: file))
    }

    /// Saves a downscaled JPEG of a capture and returns its file name.
    func saveThumbnail(_ image: CGImage, conversation: UUID) -> String? {
        let scale = min(1, 900 / CGFloat(image.width))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else { return nil }
        let folder = imageDirectory(conversation)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).jpg"
        do {
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }
}
