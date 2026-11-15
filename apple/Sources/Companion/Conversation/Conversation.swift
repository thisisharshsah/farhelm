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
/// One thing the agent did on the way to its answer: a command it ran, an
/// app it opened, a click. Kept with the turn so the work can be looked at
/// afterwards, folded away behind a one-line summary.
struct WorkStep: Codable, Equatable {
    enum Kind: String, Codable {
        case run, open, click, type, key, other
        case read, search, edit, web
        /// Something the agent said to the user along the way.
        case note
        /// A round where the agent worked out what to do next.
        case think
        /// A question the agent asked, with its choices and the answer.
        case ask
        /// A skill the agent read and followed.
        case skill
    }

    var kind: Kind
    /// The command, or what was opened, clicked, typed or pressed.
    var title: String
    /// The end of a command's output.
    var output: String?
    var failed = false
    // All optional, so replies saved before them still load.
    /// What the step was for, in the agent's words.
    var why: String?
    /// The file a read, write or edit was about.
    var path: String?
    /// Lines a write or edit added and took out, and the file's length after.
    var added: Int?
    var removed: Int?
    var lines: Int?
    /// A question's choices, and the answer given.
    var options: [String]?
    var answer: String?

    private static func phrase(_ kind: Kind, _ count: Int) -> String {
        let plural = count == 1 ? "" : "s"
        switch kind {
        case .run: return "ran \(count) command\(plural)"
        case .open: return "opened \(count) app\(plural)"
        case .click: return "clicked \(count) time\(plural)"
        case .type: return "typed \(count) time\(plural)"
        case .key: return "pressed \(count) key\(plural)"
        case .other: return "took \(count) more step\(plural)"
        case .read: return "read \(count) file\(plural)"
        case .search: return "searched \(count) time\(plural)"
        case .edit: return "changed \(count) file\(plural)"
        case .web: return "used the web \(count) time\(plural)"
        case .note, .think: return ""
        case .ask: return "asked \(count) question\(plural)"
        case .skill: return "used \(count) skill\(plural)"
        }
    }

    /// Steps counted the way a person would say it: "Ran 5 commands, read
    /// 3 files and changed 2 files". Up to four kinds are named, in the
    /// order they were first done; anything past that is counted.
    static func summary(of steps: [WorkStep]) -> String {
        var order: [Kind] = []
        var counts: [Kind: Int] = [:]
        // What was said is not work, so it is not counted.
        for step in steps where step.kind != .note && step.kind != .think {
            if counts[step.kind] == nil { order.append(step.kind) }
            counts[step.kind, default: 0] += 1
        }
        var parts = order.prefix(4).map { phrase($0, counts[$0] ?? 0) }
        let rest = order.dropFirst(4).reduce(0) { $0 + (counts[$1] ?? 0) }
        if rest > 0 {
            parts.append("\(rest) more step\(rest == 1 ? "" : "s")")
        }
        let text: String
        switch parts.count {
        case 0: text = ""
        case 1: text = parts[0]
        default: text = parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// One line of the checklist the agent keeps for a longer task.
struct PlanItem: Codable, Equatable {
    enum State: String, Codable {
        case todo, doing, done
    }

    var text: String
    var state: State

    /// "[x] Read the config | [>] Fix the port | Run the tests".
    static func parse(_ value: String) -> [PlanItem] {
        value.split(separator: "|").compactMap { part -> PlanItem? in
            var text = part.trimmingCharacters(in: .whitespaces)
            var state = State.todo
            for (mark, meaning) in [("[x]", State.done), ("[X]", State.done), ("[>]", State.doing), ("[ ]", State.todo)]
            where text.hasPrefix(mark) {
                state = meaning
                text = String(text.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
            }
            return text.isEmpty ? nil : PlanItem(text: text, state: state)
        }
    }
}

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
    /// What the agent did to get to this answer, when it did any work.
    var steps: [WorkStep]?
    /// The agent's checklist for the task, when it kept one.
    var plan: [PlanItem]?
    /// Names of the files that were attached with this message.
    var attached: [String]?
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
    /// The folder this chat's code side works in. Optional so older saved
    /// conversations still decode.
    var workFolder: String?
    /// How much the agent does in this chat without asking (an
    /// `AgentAccess`). Unset follows the setting for new chats.
    var access: String?
    /// Running notes on the part of the conversation that has scrolled out of
    /// the recent window, so long conversations keep their beginning.
    var summary: String?
    /// How many saved transcript lines are already folded into `summary`.
    var summarizedLines: Int?
    /// The conversation written up as structured notes (Markdown) for later use.
    var record: String?
    /// Facts from earlier conversations that were brought into this one.
    var usedMemories: [String]?
    /// What the answers in this conversation drew on besides the
    /// conversation itself: "My details", attached files by name, "Memory".
    var usedSources: [String]?
    /// What was being written in the chat box and not sent yet, with the
    /// files picked to go with it and whether the screen goes too. Each
    /// chat keeps its own, across switching and relaunching.
    var draft: String?
    var draftAttachments: [UUID]?
    var draftScreen: Bool?

    /// How much this conversation holds. `spoken` is the size of the
    /// transcript when the live one is fuller than the saved one.
    func contextUse(spoken: Int? = nil) -> ContextUse {
        var use = ContextUse()
        use.transcript = ContextUse.tokens(spoken ?? transcript.reduce(0) { $0 + $1.text.utf8.count })
        use.answers = ContextUse.tokens(turns.reduce(0) {
            $0 + $1.prompt.utf8.count + $1.answer.utf8.count + ($1.context?.utf8.count ?? 0)
        })
        use.attachments = ContextUse.tokens((attachments ?? []).reduce(0) { $0 + $1.text.utf8.count })
        use.notes = ContextUse.tokens((summary?.utf8.count ?? 0) + (record?.utf8.count ?? 0))
        return use
    }

    /// When something was last said, typed or answered here. Opening a
    /// conversation to read it does not count, so lists ordered by this
    /// keep the order in which the conversations actually happened.
    var lastActivity: Date {
        let lastTurn = turns.map(\.date).max()
        let lastLine = transcript.compactMap(\.date).max()
        return [lastTurn, lastLine].compactMap { $0 }.max() ?? updatedAt
    }
}

struct ConversationSummary: Identifiable, Equatable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let turnCount: Int
    /// Roughly how many tokens the whole conversation holds.
    var tokens = 0
}

/// How much a conversation holds, in tokens (estimated from its length),
/// split by where it comes from. This is the size of everything the engine
/// could be given about the conversation; when it is more than one request
/// can carry, the older part is summarised and the relevant passages are
/// picked out, so a full conversation still works.
struct ContextUse: Equatable {
    var transcript = 0
    var answers = 0
    var attachments = 0
    var notes = 0

    var total: Int { transcript + answers + attachments + notes }

    /// Characters per token, the same estimate the request budgets use.
    static func tokens(_ bytes: Int) -> Int { Int(Double(bytes) / 3.5) }

    /// 3200 as "3.2k", 148000 as "148k".
    static func short(_ tokens: Int) -> String {
        if tokens < 1_000 { return "\(tokens)" }
        if tokens < 10_000 { return String(format: "%.1fk", Double(tokens) / 1_000) }
        return "\(tokens / 1_000)k"
    }
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
                                           updatedAt: conversation.lastActivity,
                                           turnCount: conversation.turns.count,
                                       tokens: conversation.contextUse().total)
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
                                           updatedAt: conversation.lastActivity,
                                           turnCount: conversation.turns.count,
                                       tokens: conversation.contextUse().total)
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
