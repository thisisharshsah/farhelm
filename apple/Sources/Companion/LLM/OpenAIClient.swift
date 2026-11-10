import Foundation

/// OpenAI-style chat completions. Also the wire format Farhelm's front door
/// speaks (POST /p/<client>/v1/chat/completions), so both providers use this.
enum OpenAIClient {
    static func compatibleStream(_ req: ChatRequest,
                                 endpoint: URL,
                                 bearer: String,
                                 model: String?,
                                 unreachableMessage: String?,
                                 sendsImages: Bool = false) async throws -> AsyncThrowingStream<String, Error> {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        // Only OpenAI itself gets the picture; Farhelm's front door refuses images.
        var messages: [[String: Any]] = [["role": "system", "content": req.fullSystem]]
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
                        guard let event = LLM.parse(payload[...]),
                              let choices = event["choices"] as? [[String: Any]],
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
