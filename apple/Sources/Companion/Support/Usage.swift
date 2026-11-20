import Foundation
import Combine

/// What one request to an engine used.
struct UsageRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var conversation: UUID?
    /// "anthropic", "openai", "farhelm", "ollama", "apple", or for More services the
    /// service's id ("gemini", "lmstudio").
    var engine: String
    var model: String
    /// What the request was for: "Live reply", "Agent", "Transcript polish"…
    var purpose: String
    /// Input tokens billed at the full rate.
    var input: Int
    /// Input tokens read from the engine's prompt cache (billed far lower).
    var cacheRead = 0
    /// Input tokens written to the cache (billed a little higher).
    var cacheWrite = 0
    var output: Int
    /// Counted by the engine. Otherwise estimated from the text's length.
    var exact: Bool
    /// How long the request took.
    var seconds: Double
    /// The board task the request worked on and the project it is in, when
    /// it was made in Advanced mode or in a project's chat. Optional, so
    /// lines written before these existed still load.
    var workItem: UUID?
    var project: UUID?

    var tokens: Int { input + cacheRead + cacheWrite + output }
    var isLocal: Bool {
        LLMProviderKind(rawValue: engine)?.isLocal ?? (CompatibleService.named(engine)?.local ?? false)
    }
}

/// Dollars per million tokens.
struct Price: Codable, Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double

    static let zero = Price(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)

    func cost(of record: UsageRecord) -> Double {
        (Double(record.input) * input + Double(record.output) * output
            + Double(record.cacheRead) * cacheRead + Double(record.cacheWrite) * cacheWrite) / 1_000_000
    }
}

/// What each model costs. Published list prices are built in for Claude;
/// every price can be changed, and models with no known price (OpenAI,
/// local engines) start at zero until one is set. For a local engine the
/// price is the user's own cost of running it.
///
/// Prices change. The built-in ones are Anthropic's list prices as read on
/// 2026-11-11; check them before relying on a figure.
@MainActor
final class PriceBook: ObservableObject {
    static let shared = PriceBook()

    /// Longest matching prefix of the model's identifier wins.
    private static let listed: [(prefix: String, price: Price)] = [
        ("claude-fable-5-2", Price(input: 8, output: 40, cacheRead: 0.20, cacheWrite: 10)),
        ("claude-mythos-5-2", Price(input: 8, output: 40, cacheRead: 0.20, cacheWrite: 10)),
        ("claude-fable-5-1", Price(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5)),
        ("claude-mythos-5-1", Price(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5)),
        ("claude-fable-5", Price(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5)),
        ("claude-mythos-5", Price(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5)),
        ("claude-opus-5-5", Price(input: 4, output: 20, cacheRead: 0.20, cacheWrite: 5)),
        ("claude-opus-5", Price(input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25)),
        ("claude-opus-4-1", Price(input: 15, output: 75, cacheRead: 1.50, cacheWrite: 18.75)),
        ("claude-opus-4", Price(input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25)),
        ("claude-sonnet-5-5", Price(input: 2, output: 10, cacheRead: 0.10, cacheWrite: 2.5)),
        ("claude-sonnet-5", Price(input: 2, output: 10, cacheRead: 0.20, cacheWrite: 2.5)),
        ("claude-sonnet-4", Price(input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75)),
        // Haiku 5.5's rate for prompts up to 100,000 tokens.
        ("claude-haiku-5-5", Price(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125)),
        ("claude-haiku-4-5", Price(input: 1, output: 5, cacheRead: 0.10, cacheWrite: 1.25))
    ]

    /// Prices the user set, by model identifier.
    @Published private(set) var overrides: [String: Price] = [:]
    private let storeKey = "prices"

    private init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let saved = try? JSONDecoder().decode([String: Price].self, from: data) {
            overrides = saved
        }
    }

    /// The key a model's price is kept under. Farhelm's automatic choice has
    /// no model name, so it gets one of its own.
    static func key(engine: String, model: String) -> String {
        model.isEmpty ? "\(engine)-auto" : model.lowercased()
    }

    func price(engine: String, model: String) -> Price {
        let key = Self.key(engine: engine, model: model)
        if let own = overrides[key] { return own }
        let match = Self.listed
            .filter { key.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }
        return match?.price ?? .zero
    }

    /// Whether anything is known about what this model costs.
    func isPriced(engine: String, model: String) -> Bool {
        price(engine: engine, model: model) != .zero
    }

    func set(_ price: Price, engine: String, model: String) {
        overrides[Self.key(engine: engine, model: model)] = price
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    func cost(of record: UsageRecord) -> Double {
        price(engine: record.engine, model: record.model).cost(of: record)
    }
}

/// Every request's usage, kept on this Mac: one line of JSON per request in
/// `usage.jsonl`. It is the raw material for knowing what Companion costs
/// to run: per purpose, per model, per conversation, per day.
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    /// The last 90 days, oldest first.
    @Published private(set) var records: [UsageRecord] = []

    private let url = ContextStore.shared.baseDir.appendingPathComponent("usage.jsonl")
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        records = text.split(separator: "\n").compactMap { line -> UsageRecord? in
            guard let record = try? decoder.decode(UsageRecord.self, from: Data(line.utf8)),
                  record.date >= cutoff else { return nil }
            return record
        }
    }

    /// Files a request under the work it was made for: the scope it ran
    /// in, or, for a request made outside any, the chat that is open.
    func add(_ record: UsageRecord, scope: WorkScope?) {
        var filed = record
        filed.conversation = scope?.conversation ?? AppState.shared.conversation.id
        filed.workItem = scope?.workItem
        filed.project = scope?.project ?? (scope == nil ? AppState.shared.conversation.projectID : nil)
        add(filed)
    }

    func add(_ record: UsageRecord) {
        records.append(record)
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    func records(since date: Date?) -> [UsageRecord] {
        guard let date else { return records }
        return records.filter { $0.date >= date }
    }

    func records(for conversation: UUID) -> [UsageRecord] {
        records.filter { $0.conversation == conversation }
    }

    func cost(of list: [UsageRecord]) -> Double {
        list.reduce(0) { $0 + PriceBook.shared.cost(of: $1) }
    }

    /// Everything as a spreadsheet, one request per row, with its cost at
    /// today's prices.
    func csv() -> String {
        var rows = ["date,engine,model,purpose,input,cache_read,cache_write,output,exact,seconds,cost_usd,conversation,task,project"]
        let stamp = ISO8601DateFormatter()
        for record in records {
            rows.append([
                stamp.string(from: record.date), record.engine, record.model.isEmpty ? "auto" : record.model,
                record.purpose, "\(record.input)", "\(record.cacheRead)", "\(record.cacheWrite)", "\(record.output)",
                record.exact ? "yes" : "estimated", String(format: "%.2f", record.seconds),
                String(format: "%.6f", PriceBook.shared.cost(of: record)), record.conversation?.uuidString ?? "",
                record.workItem?.uuidString ?? "", record.project?.uuidString ?? ""
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }
}

/// Whom a piece of work is for and where it runs: the chat, and in a
/// project the board task and the project. It is set once around the work
/// (`WorkScope.$current.withValue`) and follows everything the work does,
/// however deep and through every task it starts, so each request to an
/// engine is filed where it belongs even when its chat is not the one on
/// screen. Work done outside any scope belongs to the open chat.
struct WorkScope: Sendable {
    var conversation: UUID?
    /// The board task a run is working on (Advanced mode).
    var workItem: UUID?
    var project: UUID?
    /// The folder the work is done in, for a tool that is started in one.
    var directory: String?

    @TaskLocal static var current: WorkScope?
}

/// Filled in by an engine's client while a request streams, when the engine
/// reports what it used.
final class UsageProbe: @unchecked Sendable {
    var input: Int?
    var cacheRead = 0
    var cacheWrite = 0
    var output: Int?
}

enum Money {
    /// Small amounts keep their detail: $0.0042, $0.38, $12.40.
    static func text(_ dollars: Double) -> String {
        if dollars == 0 { return "$0" }
        if dollars < 0.01 { return String(format: "$%.4f", dollars) }
        if dollars < 1 { return String(format: "$%.3f", dollars) }
        return String(format: "$%.2f", dollars)
    }
}
