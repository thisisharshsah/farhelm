import Foundation

/// A service that speaks OpenAI's chat completions.
///
/// What differs between them (where they are, whether they take a key and
/// pictures and tools, which optional fields they accept) is data here, so
/// one adapter serves them all: `OpenAIClient` for replies, `OpenAIAgent`
/// for the agent. Supporting another such service is a new entry below,
/// not new code.
///
/// OpenAI and Farhelm keep engines of their own in Settings; the others are
/// the "More services" engine, one chosen at a time.
struct CompatibleService: Identifiable, Equatable {
    let id: String
    let name: String
    /// Shown under the name: who runs it, or where.
    let place: String
    /// The address up to its version, as the service documents it
    /// ("https://api.openai.com/v1"). Empty when there is none to assume.
    let defaultAddress: String
    /// Added to the address before the routes: Farhelm's address names its
    /// client ("…/p/companion") and its OpenAI routes are under /v1 from there.
    var versionPath = ""
    /// What Settings says about the key, or nil when it takes none.
    let keyHint: String?
    /// Whether a request cannot go without a key.
    let keyRequired: Bool
    /// An environment variable that may hold the key.
    let keyVariable: String?
    /// Runs on this Mac, so nothing leaves it and a model may think quietly
    /// for a long time. "Other" decides by its address.
    let local: Bool
    /// Takes a picture with the last message.
    let images: Bool
    /// Takes tool calls, so the agent uses them rather than lines of text.
    let tools: Bool
    /// Takes `reasoning_effort`.
    let reasoningEffort: Bool
    /// Takes `stream_options.include_usage`. Usage is read from any service
    /// that reports it; only these are asked.
    let reportsUsage: Bool
    /// Names the output limit `max_completion_tokens` (OpenAI's newer name)
    /// rather than `max_tokens`.
    let completionTokens: Bool
    /// Takes `parallel_tool_calls`.
    var parallelToolCalls = false

    /// Where its key is kept in the Keychain. OpenAI's and Farhelm's keep
    /// the accounts they always had.
    var keyAccount: String {
        id == "openai" || id == "farhelm" ? id : "service." + id
    }

    // MARK: The services

    static let openAI = CompatibleService(
        id: "openai", name: "OpenAI", place: "OpenAI API",
        defaultAddress: "https://api.openai.com/v1",
        keyHint: "From platform.openai.com.", keyRequired: true, keyVariable: "OPENAI_API_KEY",
        local: false, images: true, tools: true, reasoningEffort: true, reportsUsage: true,
        completionTokens: true, parallelToolCalls: true)

    static let farhelm = CompatibleService(
        id: "farhelm", name: "Farhelm", place: "On this Mac",
        defaultAddress: "http://127.0.0.1:7842/p/companion", versionPath: "/v1",
        keyHint: "One-time setup on this Mac: farhelm clients add companion.", keyRequired: true,
        keyVariable: "FARHELM_API_KEY",
        local: true, images: false, tools: true, reasoningEffort: false, reportsUsage: false,
        completionTokens: false)

    static let gemini = CompatibleService(
        id: "gemini", name: "Gemini", place: "Google AI Studio",
        defaultAddress: "https://generativelanguage.googleapis.com/v1beta/openai",
        keyHint: "From aistudio.google.com.", keyRequired: true, keyVariable: "GEMINI_API_KEY",
        local: false, images: true, tools: true, reasoningEffort: true, reportsUsage: false,
        completionTokens: false)

    static let openRouter = CompatibleService(
        id: "openrouter", name: "OpenRouter", place: "Many providers' models",
        defaultAddress: "https://openrouter.ai/api/v1",
        keyHint: "From openrouter.ai/keys.", keyRequired: true, keyVariable: "OPENROUTER_API_KEY",
        // Pictures only to models that take them, which differs by model;
        // screen answers send the screen's text instead.
        local: false, images: false, tools: true, reasoningEffort: false, reportsUsage: false,
        completionTokens: false)

    static let lmStudio = CompatibleService(
        id: "lmstudio", name: "LM Studio", place: "On this Mac",
        defaultAddress: "http://127.0.0.1:1234/v1",
        keyHint: nil, keyRequired: false, keyVariable: nil,
        local: true, images: false, tools: true, reasoningEffort: false, reportsUsage: false,
        completionTokens: false)

    static let other = CompatibleService(
        id: "other", name: "Other", place: "Any OpenAI-compatible server",
        defaultAddress: "",
        keyHint: "Only if the server asks for one.", keyRequired: false, keyVariable: nil,
        local: false, images: false, tools: true, reasoningEffort: false, reportsUsage: false,
        completionTokens: false)

    /// The services of the "More services" engine, in the order offered.
    static let choices: [CompatibleService] = [gemini, openRouter, lmStudio, other]

    /// Every service, by id.
    static func named(_ id: String) -> CompatibleService? {
        ([openAI, farhelm] + choices).first { $0.id == id }
    }

    /// The service a request goes to, for the engines that speak OpenAI's
    /// chat completions; nil for the others.
    static func behind(_ config: LLMConfig) -> CompatibleService? {
        switch config.kind {
        case .openai: return openAI
        case .farhelm: return farhelm
        case .compatible: return named(config.service) ?? other
        default: return nil
        }
    }

    // MARK: Where requests go

    /// The address up to the routes: the configured one, or the service's own.
    func address(_ configured: String) -> String {
        var base = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = defaultAddress }
        while base.hasSuffix("/") { base.removeLast() }
        return base.isEmpty ? "" : base + versionPath
    }

    /// One route ("/chat/completions", "/models") at the configured address.
    func url(_ route: String, configured: String) throws -> URL {
        let base = address(configured)
        guard !base.isEmpty, let url = URL(string: base + route), url.host != nil else {
            throw LLMError.notConfigured("Set \(name)'s address in Settings (the gear > Engine).")
        }
        return url
    }

    /// Whether requests stay on this Mac or its network: the service's own
    /// answer, or, for Other, what its address says.
    func runsLocally(at configured: String) -> Bool {
        if local { return true }
        guard id == Self.other.id,
              let host = URL(string: address(configured))?.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// Why a request did not get through, when the connection itself failed.
    func unreachable(at configured: String) -> String {
        let base = address(configured)
        return runsLocally(at: configured)
            ? "\(name) is not reachable at \(base). Is it running?"
            : "\(name) is not reachable at \(base). Check the address and your connection."
    }

    /// The models it offers, from its /models route.
    func models(configured: String, key: String) async throws -> [String] {
        var request = URLRequest(url: try url("/models", configured: configured))
        request.timeoutInterval = 15
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return [] }
        // Gemini names its models "models/gemini-…" here, and takes them
        // without the prefix in requests.
        let ids = list.compactMap { $0["id"] as? String }.map { id in
            id.hasPrefix("models/") ? String(id.dropFirst("models/".count)) : id
        }
        return Array(Set(ids)).sorted()
    }
}
