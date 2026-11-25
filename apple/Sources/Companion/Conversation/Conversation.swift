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
    /// Who gave the answer, when it was not the person: the project's
    /// supervisor in their place, with its reason.
    var answeredBy: String?

    /// The tools with a mark and a name of their own in the work list:
    /// earlier chats and the Mac's services, told apart by how their line
    /// starts.
    struct Mark {
        let prefix: String
        let icon: String
        let name: String
        /// How the line reads: "Calendar: events in the next 7 days".
        let verb: String
        /// In a summary: "checked Calendar".
        let phrase: String
    }

    static let marks: [Mark] = [
        Mark(prefix: "Searched chats for ", icon: "bubble.left.and.bubble.right", name: "Chats",
             verb: "Looked through your chats for", phrase: "looked through your chats"),
        Mark(prefix: "Read chat ", icon: "text.bubble", name: "Chat", verb: "Read the earlier chat", phrase: "looked through your chats"),
        Mark(prefix: "Spotlight ", icon: "magnifyingglass.circle", name: "Spotlight", verb: "Spotlight:", phrase: "searched your Mac"),
        Mark(prefix: "Clipboard ", icon: "doc.on.clipboard", name: "Clipboard", verb: "Clipboard:", phrase: "used the clipboard"),
        Mark(prefix: "Calendar ", icon: "calendar", name: "Calendar", verb: "Calendar:", phrase: "checked Calendar"),
        Mark(prefix: "Reminders ", icon: "checklist", name: "Reminders", verb: "Reminders:", phrase: "used Reminders"),
        Mark(prefix: "Mail ", icon: "envelope", name: "Mail", verb: "Mail:", phrase: "used Mail"),
        Mark(prefix: "Notes ", icon: "note.text", name: "Notes", verb: "Notes:", phrase: "used Notes"),
        Mark(prefix: "Check-in at ", icon: "alarm", name: "Check-in", verb: "Check-in at", phrase: "set a check-in"),
        Mark(prefix: "Delegated ", icon: "person.2", name: "Helper", verb: "A helper looked into", phrase: "asked a helper"),
    ]

    var mark: Mark? { Self.marks.first { title.hasPrefix($0.prefix) } }

    /// What a marked step worked on, without its tool's words.
    var markSubject: String {
        guard let mark else { return title }
        var text = String(title.dropFirst(mark.prefix.count))
        for tail in ["  (failed)", " (failed)"] where text.hasSuffix(tail) { text = String(text.dropLast(tail.count)) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// A step in the browser beside the chat or in Chrome, filed as web.
    var inBrowser: Bool {
        kind == .web && (title.hasPrefix("Browser: ") || title.hasPrefix("Chrome: "))
    }

    /// The picture a browser step took of the page ("look"), when it is
    /// still on this Mac.
    var picture: String? {
        guard inBrowser, let output, let range = output.range(of: "PICTURE: ", options: .backwards) else { return nil }
        let path = String(output[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// What a picture is of: the page's title, from the step's result.
    var pageName: String {
        guard let output, let range = output.range(of: "as it shows now: ") else { return "The page" }
        let line = output[range.upperBound...].prefix { $0 != "\n" }
        let title = line.components(separatedBy: " <").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return title.isEmpty ? "The page" : title
    }

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
        // Browser steps are filed with the web's, and chats and the Mac's
        // services with searches, but each is named apart.
        var order: [String] = []
        var counts: [String: Int] = [:]
        var kinds: [String: Kind] = [:]
        // What was said is not work, so it is not counted.
        for step in steps where step.kind != .note && step.kind != .think {
            let key = step.inBrowser ? "browser" : (step.mark.map { "mark:" + $0.phrase } ?? step.kind.rawValue)
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
            kinds[key] = step.kind
        }
        var parts = order.prefix(4).map { key -> String in
            let count = counts[key] ?? 0
            if key == "browser" { return "used the browser" + (count == 1 ? "" : " (\(count) steps)") }
            if key.hasPrefix("mark:") { return String(key.dropFirst(5)) }
            return phrase(kinds[key] ?? .other, count)
        }
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

    /// What a chat is to its project's board.
    enum Kind: String, Codable {
        /// The chat with the project's supervisor.
        case supervisor
        /// A task's chat, which every run of the task shares.
        case task
    }

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
    /// The agent's own notes on where this chat's work stands: the goal,
    /// where it lives (sites, hosts, folders, job numbers), what is done
    /// and what is next. They go with every task in the chat, so a short
    /// "go on" or a check-in after a restart picks up with the whole picture.
    var workNotes: String?
    /// The pages the agent worked on in this chat, newest last, to go back
    /// to after the browser was closed or Companion restarted.
    var workPages: [String]?
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
    /// The project this chat is in, or nil for a plain chat. Code (the
    /// agent's file and shell tools) is only on in a project chat, and
    /// works in the project's folder. Optional, so chats saved before
    /// projects existed load as plain chats.
    var projectID: UUID?
    /// What the chat is to its project's board; nil for one of the
    /// person's own. Chats saved before this load as the person's own
    /// until their board says otherwise (`Advanced.prepareChats`).
    var kind: Kind?
    /// The task whose chat this is, for a task's chat.
    var taskID: UUID?
    /// When the person archived it; nil while it is listed.
    var archivedAt: Date?
    /// Whether the model has given it a short name after its first answer
    /// (asked once, so a name the person chose is never replaced).
    var autoNamed: Bool?
    /// The chat this one was forked from, when it is a fork.
    var forkedFrom: UUID?

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

extension Conversation {
    /// Read field by field so every field added after the first version is
    /// optional (decodeIfPresent): a chat saved before projects existed has
    /// no projectID and loads as a plain chat.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        turns = try values.decode([ChatTurn].self, forKey: .turns)
        transcript = try values.decode([SavedLine].self, forKey: .transcript)
        attachments = try values.decodeIfPresent([Attachment].self, forKey: .attachments)
        workFolder = try values.decodeIfPresent(String.self, forKey: .workFolder)
        access = try values.decodeIfPresent(String.self, forKey: .access)
        summary = try values.decodeIfPresent(String.self, forKey: .summary)
        summarizedLines = try values.decodeIfPresent(Int.self, forKey: .summarizedLines)
        record = try values.decodeIfPresent(String.self, forKey: .record)
        usedMemories = try values.decodeIfPresent([String].self, forKey: .usedMemories)
        usedSources = try values.decodeIfPresent([String].self, forKey: .usedSources)
        draft = try values.decodeIfPresent(String.self, forKey: .draft)
        draftAttachments = try values.decodeIfPresent([UUID].self, forKey: .draftAttachments)
        draftScreen = try values.decodeIfPresent(Bool.self, forKey: .draftScreen)
        projectID = try values.decodeIfPresent(UUID.self, forKey: .projectID)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind)
        taskID = try values.decodeIfPresent(UUID.self, forKey: .taskID)
        archivedAt = try values.decodeIfPresent(Date.self, forKey: .archivedAt)
        autoNamed = try values.decodeIfPresent(Bool.self, forKey: .autoNamed)
        forkedFrom = try values.decodeIfPresent(UUID.self, forKey: .forkedFrom)
    }
}

/// A folder that chats are grouped under in the sidebar. A chat in a
/// project works in code, in `folder`; taking a project off the list
/// never touches the folder or anything in it.
struct Project: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    /// The project's folder, or nil when none is set (older entries).
    var folder: String?
    var createdAt = Date()

    init(id: UUID = UUID(), name: String, folder: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.folder = folder
        self.createdAt = createdAt
    }

    // Stored as "folderPath", the key projects.json already uses.
    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt
        case folder = "folderPath"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decode(String.self, forKey: .name)
        folder = try values.decodeIfPresent(String.self, forKey: .folder)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// The folder with the home folder shortened to ~, or nil.
    var abbreviatedFolder: String? {
        folder.map { ($0 as NSString).abbreviatingWithTildeInPath }
    }
}

struct ConversationSummary: Identifiable, Equatable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let turnCount: Int
    /// Roughly how many tokens the whole conversation holds.
    var tokens = 0
    /// The project the conversation is in, if any.
    var projectID: UUID? = nil
    /// What it is to its project's board, and its task (`Conversation.kind`).
    var kind: Conversation.Kind? = nil
    var taskID: UUID? = nil
    var archivedAt: Date? = nil
    /// A fork of another chat (older forks are known by their name).
    var isFork = false
    /// The first message's id: forks of one chat share it.
    var firstTurn: UUID? = nil
    /// The chat it was forked from, when that is recorded.
    var forkedFrom: UUID? = nil

    /// A saved conversation, as the lists show it.
    init(_ conversation: Conversation) {
        id = conversation.id
        title = conversation.title
        updatedAt = conversation.lastActivity
        turnCount = conversation.turns.count
        tokens = conversation.contextUse().total
        projectID = conversation.projectID
        kind = conversation.kind
        taskID = conversation.taskID
        archivedAt = conversation.archivedAt
        isFork = conversation.forkedFrom != nil || conversation.title.hasSuffix(" (fork)")
        firstTurn = conversation.turns.first?.id
        forkedFrom = conversation.forkedFrom
    }
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
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        summaryLock.lock()
        defer { summaryLock.unlock() }
        var seen = Set<String>()
        let summaries = files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != Self.projectsFile }
            .compactMap { url -> ConversationSummary? in
                // Each chat is read whole only when its file changed since
                // the last listing: opening a chat or saving one listed every
                // chat again, all of them decoded, on the main thread.
                let values = try? url.resourceValues(forKeys: Set(keys))
                let stamp = (values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
                seen.insert(url.lastPathComponent)
                if let cached = summaryCache[url.lastPathComponent], cached.modified == stamp.0, cached.size == stamp.1 {
                    return cached.summary
                }
                guard let data = try? Data(contentsOf: url),
                      let conversation = try? decoder.decode(Conversation.self, from: data) else { return nil }
                let summary = ConversationSummary(conversation)
                summaryCache[url.lastPathComponent] = (stamp.0, stamp.1, summary)
                return summary
            }
            .sorted { $0.updatedAt > $1.updatedAt }
        summaryCache = summaryCache.filter { seen.contains($0.key) }
        return summaries
    }

    /// Summaries of chats as last read, by file name, with the file's
    /// modification time and size when read.
    private var summaryCache: [String: (modified: Date, size: Int, summary: ConversationSummary)] = [:]
    private let summaryLock = NSLock()

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
                return ConversationSummary(conversation)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(_ id: UUID) -> Conversation? {
        // A save of this chat still under way is waited for, so what is
        // read is never older than what was saved.
        flush()
        guard let data = try? Data(contentsOf: fileURL(id)) else { return nil }
        return try? decoder.decode(Conversation.self, from: data)
    }

    func save(_ conversation: Conversation) {
        guard let data = try? encoder.encode(conversation) else { return }
        try? data.write(to: fileURL(conversation.id), options: .atomic)
    }

    /// Saves off the main thread, one save after another in order, then
    /// tells `done` on the main thread. A long chat took tens of
    /// milliseconds to encode and write, and saving happens on every
    /// switch, send and pause in typing.
    func saveInBackground(_ conversation: Conversation, done: @escaping @MainActor () -> Void = {}) {
        let url = fileURL(conversation.id)
        saveQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(conversation) {
                try? data.write(to: url, options: .atomic)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
        }
    }

    private let saveQueue = DispatchQueue(label: "companion.conversation-save", qos: .utility)

    /// Waits for the saves under way (before quitting, or before reading a
    /// chat's file straight after saving it).
    func flush() {
        saveQueue.sync {}
    }

    /// The projects, in one file beside the conversations.
    static let projectsFile = "projects.json"

    private var projectsURL: URL {
        directory.appendingPathComponent(Self.projectsFile)
    }

    func loadProjects() -> [Project] {
        guard let data = try? Data(contentsOf: projectsURL) else { return [] }
        return (try? decoder.decode([Project].self, from: data)) ?? []
    }

    /// Writes the list only. Taking a project off it never touches its folder.
    func saveProjects(_ projects: [Project]) {
        guard let data = try? encoder.encode(projects) else { return }
        try? data.write(to: projectsURL, options: .atomic)
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


/// Chats and their forks, as one family in the list: each fork under the
/// chat it came from. A fork records where it came from; older forks
/// (named "... (fork)") are matched by the first message they share.
enum ChatFamilies {
    /// The chat each fork belongs under, by the fork's id.
    static func parents(in chats: [ConversationSummary]) -> [UUID: UUID] {
        let ids = Set(chats.map(\.id))
        // For older forks: the original among the chats that share a first
        // message, the one that is not a fork, with the most messages.
        var originals: [UUID: ConversationSummary] = [:]
        for chat in chats where !chat.isFork {
            guard let first = chat.firstTurn else { continue }
            if let kept = originals[first], kept.turnCount >= chat.turnCount { continue }
            originals[first] = chat
        }
        var parent: [UUID: UUID] = [:]
        for chat in chats where chat.isFork {
            if let from = chat.forkedFrom, ids.contains(from), from != chat.id {
                parent[chat.id] = from
            } else if let first = chat.firstTurn, let original = originals[first], original.id != chat.id {
                parent[chat.id] = original.id
            }
        }
        // A fork of a fork goes under the first chat of the family.
        var root: [UUID: UUID] = [:]
        for (child, _) in parent {
            var top = child
            var steps = 0
            while let up = parent[top], steps < 20 { top = up; steps += 1 }
            root[child] = top
        }
        return root
    }
}
