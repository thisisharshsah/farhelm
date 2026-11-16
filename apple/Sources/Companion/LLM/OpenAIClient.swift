import Foundation

/// OpenAI-style chat completions, for every service that speaks them: OpenAI,
/// Farhelm's front door (POST /p/<client>/v1/chat/completions), and the
/// "More services" engine. What differs between them is in `CompatibleService`.
enum OpenAIClient {
    static func stream(_ req: ChatRequest, config: LLMConfig,
                       service: CompatibleService) async throws -> AsyncThrowingStream<String, Error> {
        var request = URLRequest(url: try service.url("/chat/completions", configured: config.baseURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let model: String? = config.model.isEmpty ? nil : config.model
        // Open-weight reasoning models (gpt-oss) read their effort from a
        // line in the instructions, whatever the server in front of them
        // does with the request field below.
        var instructions = req.fullSystem
        if let effort = config.effort, model == nil || (model ?? "").lowercased().contains("gpt-oss") {
            instructions = "Reasoning: \(effort)\n\n" + instructions
        }
        var messages: [[String: Any]] = [["role": "system", "content": instructions]]
        if service.images, let image = req.image {
            messages += req.wireMessages(image: image, as: .openAI)
        } else {
            messages += req.wireMessages.map { $0 as [String: Any] }
        }
        var body: [String: Any] = [
            "stream": true,
            "messages": messages
        ]
        if let model { body["model"] = model }
        // A server that checks its input strictly could refuse a field it
        // does not know, so optional fields go only where they are documented.
        if let effort = config.effort, service.reasoningEffort {
            body["reasoning_effort"] = effort
        }
        if service.reportsUsage {
            body["stream_options"] = ["include_usage": true]
        }
        request.httpBody = try LLM.jsonBody(body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let error as URLError where error.code != .cancelled {
            throw LLMError.network(service.unreachable(at: config.baseURL))
        }
        try await LLM.ensureOK(response, bytes: bytes)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let event = LLM.parse(payload[...]) else { continue }
                        if let used = event["usage"] as? [String: Any] {
                            let cached = (used["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
                            if let prompt = used["prompt_tokens"] as? Int {
                                req.usage?.input = max(prompt - cached, 0)
                                req.usage?.cacheRead = cached
                            }
                            req.usage?.output = used["completion_tokens"] as? Int
                        }
                        guard let choices = event["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let text = delta["content"] as? String else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
