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
    /// Background that is the same from request to request (who the user
    /// is). Engines that cache a stable prompt prefix cache up to here.
    var pinned = ""
    /// The longest answer wanted, in tokens.
    var maxOutput = 700

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
    static func stream(_ request: ChatRequest, config: LLMConfig) async throws -> AsyncThrowingStream<String, Error> {
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
                sendsImages: true)
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
                unreachableMessage: "Farhelm runner not reachable at \(base). Is it running on this Mac?")
        case .ollama:
            return try await OllamaClient.stream(request, config: config)
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
