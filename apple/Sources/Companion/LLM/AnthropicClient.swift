import Foundation

enum AnthropicClient {
    static func stream(_ req: ChatRequest, config: LLMConfig) async throws -> AsyncThrowingStream<String, Error> {
        guard !config.apiKey.isEmpty else {
            throw LLMError.notConfigured("Add your Anthropic API key in Settings, or switch provider.")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(ModelCatalog.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        let messages: [[String: Any]]
        if let image = req.image {
            messages = req.wireMessages(image: image, as: .anthropic)
        } else {
            messages = req.wireMessages.map { $0 as [String: Any] }
        }
        // Prompt caching: the instructions and the pinned background are the
        // same on every request, so the API keeps them cached (5 minutes,
        // refreshed on each use) and only the changing part is processed
        // fresh. Prompts under the model's minimum are simply not cached.
        var system: [[String: Any]] = [["type": "text", "text": req.system]]
        if !req.pinned.isEmpty {
            system.append(["type": "text", "text": req.pinned])
        }
        system[system.count - 1]["cache_control"] = ["type": "ephemeral"]
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": req.maxOutput,
            "stream": true,
            "system": system,
            "messages": messages
        ]
        // Effort: how much work goes into the answer, thinking included.
        // The output limit covers thinking as well as the answer, so more
        // effort gets more room; otherwise the thinking could use it all
        // up and cut the answer short.
        if let effort = config.effort {
            body["output_config"] = ["effort": effort]
            let room = ["low": 1_000, "medium": 4_000, "high": 12_000][effort] ?? 0
            body["max_tokens"] = req.maxOutput + room
        }
        request.httpBody = try LLM.jsonBody(body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try await LLM.ensureOK(response, bytes: bytes)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let event = LLM.parse(payload[...]) else { continue }
                        // What the request used, as the API counts it: the
                        // input when the message starts, the output as it ends.
                        if let message = event["message"] as? [String: Any],
                           let used = message["usage"] as? [String: Any] {
                            req.usage?.input = used["input_tokens"] as? Int
                            req.usage?.cacheRead = used["cache_read_input_tokens"] as? Int ?? 0
                            req.usage?.cacheWrite = used["cache_creation_input_tokens"] as? Int ?? 0
                        }
                        if event["type"] as? String == "message_delta",
                           let used = event["usage"] as? [String: Any],
                           let produced = used["output_tokens"] as? Int {
                            req.usage?.output = produced
                        }
                        if event["type"] as? String == "content_block_delta",
                           let delta = event["delta"] as? [String: Any],
                           let text = delta["text"] as? String {
                            continuation.yield(text)
                        }
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
