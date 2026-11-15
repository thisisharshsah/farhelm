import Foundation

/// OpenAI-style chat completions. Also the wire format Farhelm's front door
/// speaks (POST /p/<client>/v1/chat/completions), so both providers use this.
enum OpenAIClient {
    static func compatibleStream(_ req: ChatRequest,
                                 endpoint: URL,
                                 bearer: String,
                                 model: String?,
                                 unreachableMessage: String?,
                                 sendsImages: Bool = false,
                                 effort: String? = nil,
                                 sendsEffortField: Bool = true) async throws -> AsyncThrowingStream<String, Error> {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        // Only OpenAI itself gets the picture; Farhelm's front door refuses images.
        // Open-weight reasoning models (gpt-oss) read their effort from a
        // line in the instructions, whatever the server in front of them
        // does with the request field below.
        var instructions = req.fullSystem
        if let effort, model == nil || (model ?? "").lowercased().contains("gpt-oss") {
            instructions = "Reasoning: \(effort)\n\n" + instructions
        }
        var messages: [[String: Any]] = [["role": "system", "content": instructions]]
        if sendsImages, let image = req.image {
            messages += req.wireMessages(image: image, as: .openAI)
        } else {
            messages += req.wireMessages.map { $0 as [String: Any] }
        }
        var body: [String: Any] = [
            "stream": true,
            "messages": messages
        ]
        if let model, !model.isEmpty {
            body["model"] = model
        }
        // A gateway that checks its input strictly could refuse a field it
        // does not know, so the field goes only where it is documented.
        if let effort, sendsEffortField {
            body["reasoning_effort"] = effort
        }
        // Ask OpenAI to report what the request used at the end of the
        // stream. Other gateways are not asked, but are listened to.
        if sendsEffortField {
            body["stream_options"] = ["include_usage": true]
        }
        request.httpBody = try LLM.jsonBody(body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            if let unreachableMessage {
                throw LLMError.network(unreachableMessage)
            }
            throw error
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
