import Foundation
import NaturalLanguage

/// Something worth knowing in later conversations, learned from an earlier one.
struct MemoryItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var date: Date
    var conversationID: UUID
    var title: String
    var text: String
}

/// Facts carried from one conversation to the next. Kept as a JSON file in
/// Application Support/Companion; the user can see and delete every item.
@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()
    @Published private(set) var items: [MemoryItem] = []

    private let url = ContextStore.shared.baseDir.appendingPathComponent("memory.json")
    private static let limit = 400

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url),
           let saved = try? decoder.decode([MemoryItem].self, from: data) {
            items = saved
        }
    }

    /// Stores what a conversation taught, replacing what it taught before
    /// (a conversation is written up more than once as it grows).
    func replace(for conversation: UUID, title: String, facts: [String]) {
        items.removeAll { $0.conversationID == conversation }
        let now = Date()
        items.append(contentsOf: facts.map {
            MemoryItem(date: now, conversationID: conversation, title: title, text: $0)
        })
        if items.count > Self.limit {
            items.removeFirst(items.count - Self.limit)
        }
        save()
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(items) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Picks what to show the model from everything Companion knows about the
/// user: their details, the files attached to the conversation, and memories
/// from earlier conversations.
///
/// When all of it is small it is sent whole. When it is not, the material is
/// cut into passages and only the ones relevant to what is being asked are
/// sent, so a long resume or product document is never truncated blindly.
/// Relevance combines keyword match (BM25) with meaning (Apple's on-device
/// sentence embeddings); nothing leaves the Mac for this step.
@MainActor
final class KnowledgeIndex {
    static let shared = KnowledgeIndex()

    /// Called with the memories brought into a request.
    var onMemoriesUsed: (([MemoryItem]) -> Void)?

    private struct Chunk {
        let title: String
        let document: Int
        let order: Int
        let text: String
        let terms: [String: Int]
        let length: Int
    }

    /// The opening of the user's details, sent with every request.
    static let pinnedLength = 2500

    private var chunkCache: [Int: [Chunk]] = [:]
    private var vectorCache: [Int: [Double]] = [:]
    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "by", "from", "as",
        "is", "are", "was", "were", "be", "been", "it", "its", "this", "that", "these", "those", "i", "you",
        "he", "she", "we", "they", "me", "my", "your", "our", "their", "them", "do", "does", "did", "have",
        "has", "had", "so", "if", "then", "than", "about", "can", "could", "would", "will", "just", "not",
        "what", "how", "why", "when", "where", "who", "which", "tell", "there", "here", "okay", "yeah"
    ]

    private func details() -> (head: String, rest: String) {
        let all = ContextStore.shared.combinedDetails(cap: 400_000)
        guard all.count > Self.pinnedLength else { return (all, "") }
        // Cut at a line break so the head ends on a whole line.
        var cut = all.index(all.startIndex, offsetBy: Self.pinnedLength)
        if let lineBreak = all[..<cut].lastIndex(of: "\n"), all.distance(from: all.startIndex, to: lineBreak) > 1200 {
            cut = lineBreak
        }
        return (String(all[..<cut]), String(all[cut...]))
    }

    /// Who the user is: always sent, and the same from request to request, so
    /// engines that cache a stable prompt prefix can reuse it.
    func pinned() -> String {
        let head = details().head.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? "" : "## About Me (the user)\n\(head)"
    }

    /// The names and vocabulary at the top of the user's details, for passes
    /// that only need to recognize words.
    func hints(_ limit: Int) -> String {
        String(ContextStore.shared.combinedDetails().prefix(limit))
    }

    /// The reference material for one request, and which sources it came from.
    func context(for query: String,
                 attachments: [Attachment],
                 excluding conversation: UUID?,
                 useMemory: Bool,
                 budget: Int) -> (text: String, sources: [String]) {
        var documents: [(title: String, text: String)] = []
        let rest = details().rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty {
            documents.append(("My details", rest))
        }
        for file in attachments where !file.text.isEmpty {
            documents.append((file.name, file.text))
        }
        // Memories are background, not a standing part of the prompt: only
        // the few that bear on this request are added.
        if useMemory {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            let recalled = relevantMemories(for: query, excluding: conversation)
            for item in recalled {
                documents.append(("Earlier conversation, \(formatter.string(from: item.date)): \(item.title)", item.text))
            }
            // Which memories were actually brought into this request, so the
            // chat can show the ones it used and not everything on file.
            if !recalled.isEmpty {
                onMemoriesUsed?(recalled)
            }
        }
        guard !documents.isEmpty else { return ("", []) }

        var chunks: [Chunk] = []
        for (index, document) in documents.enumerated() {
            chunks.append(contentsOf: self.chunks(of: document.text, title: document.title, document: index))
        }
        let total = chunks.reduce(0) { $0 + $1.length }
        let chosen: [Chunk]
        let partial: Bool
        if total <= budget {
            chosen = chunks
            partial = false
        } else {
            chosen = select(from: chunks, query: query, budget: budget)
            partial = true
        }
        guard !chosen.isEmpty else { return ("", []) }

        // Back in reading order, grouped under the source they came from.
        let ordered = chosen.sorted { ($0.document, $0.order) < ($1.document, $1.order) }
        var parts: [String] = []
        var sources: [String] = []
        var current: Int?
        for chunk in ordered {
            if chunk.document != current {
                current = chunk.document
                parts.append("### \(chunk.title)")
                // All memories count as one source in the footnote.
                let source = chunk.title.hasPrefix("Earlier conversation") ? "Memory" : chunk.title
                if !sources.contains(source) {
                    sources.append(source)
                }
            }
            parts.append(chunk.text)
        }
        let note = partial
            ? "(Only the passages most relevant to what is being asked are shown; the full material is longer.)\n"
            : ""
        return (note + parts.joined(separator: "\n\n"), sources)
    }

    /// Up to three memories that are about what is being asked: they share
    /// at least two meaningful words with it, or mean nearly the same.
    private func relevantMemories(for query: String, excluding conversation: UUID?) -> [MemoryItem] {
        let wanted = Set(Self.terms(query).keys)
        guard !wanted.isEmpty else { return [] }
        let queryVector = embedding?.vector(for: String(query.suffix(600)))
        var scored: [(item: MemoryItem, score: Double)] = []
        // Newest first, and only a bounded number are looked at.
        for item in MemoryStore.shared.items.reversed().prefix(120) where item.conversationID != conversation {
            let shared = Double(wanted.intersection(Self.terms(item.text).keys).count)
            var closeness = 0.0
            if let queryVector {
                let key = item.text.hashValue
                let vector = vectorCache[key] ?? embedding?.vector(for: String(item.text.prefix(800)))
                if let vector {
                    vectorCache[key] = vector
                    closeness = max(0, Self.cosine(queryVector, vector))
                }
            }
            if shared >= 2 || closeness >= 0.5 {
                scored.append((item, shared + closeness))
            }
        }
        return scored.sorted { $0.score > $1.score }.prefix(3).map(\.item)
    }

    // MARK: - Ranking

    private func select(from chunks: [Chunk], query: String, budget: Int) -> [Chunk] {
        let queryTerms = Self.terms(query)
        guard !queryTerms.isEmpty else {
            return take(chunks.indices.map { $0 }, from: chunks, budget: budget)
        }
        // Keyword relevance (BM25).
        let count = Double(chunks.count)
        let average = Double(chunks.reduce(0) { $0 + $1.length }) / max(count, 1)
        var keyword = [Double](repeating: 0, count: chunks.count)
        for term in Set(queryTerms.keys) {
            let containing = Double(chunks.filter { $0.terms[term] != nil }.count)
            guard containing > 0 else { continue }
            let rarity = log(1 + (count - containing + 0.5) / (containing + 0.5))
            for (index, chunk) in chunks.enumerated() {
                guard let frequency = chunk.terms[term] else { continue }
                let f = Double(frequency)
                keyword[index] += rarity * (f * 2.2) / (f + 1.2 * (0.25 + 0.75 * Double(chunk.length) / average))
            }
        }
        let best = keyword.max() ?? 0
        // The strongest keyword candidates, re-ranked by meaning as well.
        var candidates = chunks.indices.sorted { keyword[$0] > keyword[$1] }
        candidates = Array(candidates.prefix(60))
        var score = [Int: Double]()
        let queryVector = embedding?.vector(for: String(query.suffix(600)))
        for index in candidates {
            var value = best > 0 ? 0.5 * keyword[index] / best : 0
            if let queryVector, let passageVector = vector(for: chunks[index]) {
                value += 0.5 * max(0, Self.cosine(queryVector, passageVector))
            }
            score[index] = value
        }
        let ranked = candidates.sorted { (score[$0] ?? 0) > (score[$1] ?? 0) }
        return take(ranked, from: chunks, budget: budget)
    }

    private func take(_ order: [Int], from chunks: [Chunk], budget: Int) -> [Chunk] {
        var left = budget
        var chosen: [Chunk] = []
        for index in order {
            let chunk = chunks[index]
            guard chunk.length <= left else { continue }
            chosen.append(chunk)
            left -= chunk.length
            if left < 200 { break }
        }
        return chosen
    }

    private func vector(for chunk: Chunk) -> [Double]? {
        let key = chunk.text.hashValue
        if let cached = vectorCache[key] { return cached }
        guard let vector = embedding?.vector(for: String(chunk.text.prefix(800))) else { return nil }
        if vectorCache.count > 4000 { vectorCache.removeAll() }
        vectorCache[key] = vector
        return vector
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, lengthA = 0.0, lengthB = 0.0
        for index in a.indices {
            dot += a[index] * b[index]
            lengthA += a[index] * a[index]
            lengthB += b[index] * b[index]
        }
        let scale = (lengthA * lengthB).squareRoot()
        return scale > 0 ? dot / scale : 0
    }

    // MARK: - Passages

    private func chunks(of text: String, title: String, document: Int) -> [Chunk] {
        var hasher = Hasher()
        hasher.combine(title)
        hasher.combine(text)
        let key = hasher.finalize()
        let pieces: [Chunk]
        if let cached = chunkCache[key] {
            pieces = cached
        } else {
            pieces = Self.split(text).enumerated().map { order, piece in
                Chunk(title: title, document: 0, order: order, text: piece,
                      terms: Self.terms(piece), length: piece.count)
            }
            if chunkCache.count > 300 { chunkCache.removeAll() }
            chunkCache[key] = pieces
        }
        return pieces.map {
            Chunk(title: $0.title, document: document, order: $0.order, text: $0.text,
                  terms: $0.terms, length: $0.length)
        }
    }

    /// Passages of roughly 700 characters, cut at paragraph breaks.
    private static func split(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(trimmed) }
            current = ""
        }
        for paragraph in text.components(separatedBy: "\n\n") {
            var rest = Substring(paragraph)
            // A paragraph too long for one passage is cut at line or sentence ends.
            while rest.count > 900 {
                let limit = rest.index(rest.startIndex, offsetBy: 900)
                let breakAt = rest[..<limit].lastIndex(where: { $0 == "\n" || $0 == "." }) ?? limit
                let end = rest.distance(from: rest.startIndex, to: breakAt) > 300 ? rest.index(after: breakAt) : limit
                flush()
                current = String(rest[..<end])
                flush()
                rest = rest[end...]
            }
            if current.count + rest.count > 700 { flush() }
            current += (current.isEmpty ? "" : "\n\n") + String(rest)
        }
        flush()
        return pieces
    }

    private static func terms(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for word in text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        where word.count > 1 && !stopWords.contains(word) {
            counts[word, default: 0] += 1
        }
        return counts
    }
}
