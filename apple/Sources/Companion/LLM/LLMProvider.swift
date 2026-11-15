import AppKit
import Foundation

struct ChatMessage {
    let role: String // "user" or "assistant"
    let content: String
}

struct ChatRequest {
    let system: String
    let messages: [ChatMessage]
    /// A JPEG that goes with the last user message, for engines that can
    /// look at pictures (Claude, OpenAI). Others ignore it.
    var image: Data?
    /// Pictures the user attached, as files on this Mac. An API engine is
    /// sent the first as a picture; a subscription tool (Claude Code,
    /// Codex) is given the files to look at itself.
    var pictures: [String] = []
    /// Background that is the same from request to request (who the user
    /// is). Engines that cache a stable prompt prefix cache up to here.
    var pinned = ""
    /// The longest answer wanted, in tokens.
    var maxOutput = 700
    /// What the request is for, so its cost can be put under a heading.
    var purpose = "Other"
    /// Where the engine's own token counts are left, when it reports them.
    var usage: UsageProbe?

    func tagged(_ purpose: String) -> ChatRequest {
        var copy = self
        copy.purpose = purpose
        return copy
    }

    /// The instructions with the pinned background, for engines that take
    /// one system text.
    var fullSystem: String {
        pinned.isEmpty ? system : "\(system)\n\n\(pinned)"
    }

    init(system: String, messages: [ChatMessage]) {
        self.system = system
        self.messages = messages
    }

    init(system: String, user: String) {
        self.init(system: system, messages: [ChatMessage(role: "user", content: user)])
    }

    var wireMessages: [[String: String]] {
        messages.map { ["role": $0.role, "content": $0.content] }
    }

    enum ImageWire {
        case anthropic, openAI
    }

    /// The messages with the image attached to the last user message, in
    /// the engine's own format.
    func wireMessages(image: Data, as wire: ImageWire) -> [[String: Any]] {
        let base64 = image.base64EncodedString()
        let lastUser = messages.lastIndex { $0.role == "user" }
        return messages.enumerated().map { index, message -> [String: Any] in
            guard index == lastUser else {
                return ["role": message.role, "content": message.content]
            }
            let picture: [String: Any]
            switch wire {
            case .anthropic:
                picture = ["type": "image",
                           "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]]
            case .openAI:
                picture = ["type": "image_url",
                           "image_url": ["url": "data:image/jpeg;base64,\(base64)"]]
            }
            let text: [String: Any] = ["type": "text", "text": message.content]
            return ["role": message.role, "content": [picture, text]]
        }
    }
}

struct LLMConfig {
    var kind: LLMProviderKind
    var apiKey: String
    var model: String
    var baseURL: String
    /// "low", "medium" or "high", or nil to leave it to the engine.
    var effort: String? = nil
}

enum LLMError: LocalizedError {
    case notConfigured(String)
    case http(Int, String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let message): return message
        case .http(let code, let body): return "Provider error \(code): \(String(body.prefix(300)))"
        case .network(let message): return message
        }
    }
}

/// Lists models from an OpenAI-style /v1/models endpoint (Farhelm's front door).
enum ModelCatalog {
    /// Shown before the live list has loaded (or when it cannot be fetched).
    /// Haiku is the fastest, which matters most for live replies.
    static let anthropicSuggestions = ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"]

    /// The Anthropic API version every request is sent with. 2026-10-21
    /// rejects temperature, top_p and top_k, so requests must not set them.
    static let anthropicVersion = "2026-10-21"

    /// The models this Anthropic key can use, newest first, from the API.
    static func anthropicModels(key: String) async throws -> [String] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else {
            return []
        }
        return list.compactMap { $0["id"] as? String }
    }

    static func openAIStyleModels(base: String, bearer: String) async throws -> [String] {
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: trimmed + "/v1/models") else {
            throw LLMError.notConfigured("Invalid gateway URL.")
        }
        var request = URLRequest(url: url)
        if !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else {
            return []
        }
        return list.compactMap { $0["id"] as? String }.sorted()
    }
}

enum LLM {
    /// Every request to an engine goes through here, so every request is
    /// metered here: what it was for, which model, how many tokens in and
    /// out, how long it took. The engine's own counts are used when it
    /// gives them; otherwise the counts are estimated from the text.
    static func stream(_ request: ChatRequest, config: LLMConfig) async throws -> AsyncThrowingStream<String, Error> {
        var request = request
        // An attached picture is shown to an engine that can look at one.
        if request.image == nil, config.kind == .anthropic || config.kind == .openai,
           let first = request.pictures.first {
            request.image = Self.jpeg(ofPictureAt: first)
        }
        let probe = UsageProbe()
        request.usage = probe
        let started = Date()
        let inner = try await send(request, config: config)
        let sentBytes = request.fullSystem.utf8.count + request.messages.reduce(0) { $0 + $1.content.utf8.count }
        // A picture is charged as tokens too; this is a middling estimate.
        let pictureTokens = request.image == nil ? 0 : 1_200
        let purpose = request.purpose
        let engine = config.kind.rawValue
        let model = config.model
        return AsyncThrowingStream { continuation in
            let task = Task {
                var receivedBytes = 0
                do {
                    for try await piece in inner {
                        receivedBytes += piece.utf8.count
                        continuation.yield(piece)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                // Recorded however the request ended: what was sent was used.
                let record = UsageRecord(engine: engine,
                                         model: model,
                                         purpose: purpose,
                                         input: probe.input ?? (ContextUse.tokens(sentBytes) + pictureTokens),
                                         cacheRead: probe.cacheRead,
                                         cacheWrite: probe.cacheWrite,
                                         output: probe.output ?? ContextUse.tokens(receivedBytes),
                                         exact: probe.input != nil && probe.output != nil,
                                         seconds: Date().timeIntervalSince(started))
                await MainActor.run {
                    var filed = record
                    filed.conversation = AppState.shared.conversation.id
                    UsageStore.shared.add(filed)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A picture file as a JPEG of a size the engines take (longest side
    /// 1600 points at most).
    static func jpeg(ofPictureAt path: String) -> Data? {
        guard let image = NSImage(contentsOfFile: path),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let longest = CGFloat(max(cgImage.width, cgImage.height))
        let scale = min(1, 1600 / max(longest, 1))
        let width = Int(CGFloat(cgImage.width) * scale), height = Int(CGFloat(cgImage.height) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private static func send(_ request: ChatRequest, config: LLMConfig) async throws -> AsyncThrowingStream<String, Error> {
        switch config.kind {
        case .anthropic:
            return try await AnthropicClient.stream(request, config: config)
        case .openai:
            return try await OpenAIClient.compatibleStream(
                request,
                endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
                bearer: config.apiKey,
                model: config.model,
                unreachableMessage: nil,
                sendsImages: true,
                effort: config.effort)
        case .farhelm:
            let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
            guard let endpoint = URL(string: base + "/v1/chat/completions") else {
                throw LLMError.notConfigured("Invalid Farhelm gateway URL in Settings.")
            }
            return try await OpenAIClient.compatibleStream(
                request,
                endpoint: endpoint,
                bearer: config.apiKey,
                model: config.model.isEmpty ? nil : config.model,
                unreachableMessage: "Farhelm runner not reachable at \(base). Is it running on this Mac?",
                effort: config.effort,
                sendsEffortField: false)
        case .ollama:
            return try await OllamaClient.stream(request, config: config)
        case .subscription:
            return try await CLIAgentClient.stream(request, config: config)
        }
    }

    /// Throws a readable error for non-200 responses, draining a bit of the body.
    static func ensureOK(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > 2048 { break }
        }
        throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
    }

    static func jsonBody(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    static func parse(_ payload: Substring) -> [String: Any]? {
        guard let data = String(payload).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
