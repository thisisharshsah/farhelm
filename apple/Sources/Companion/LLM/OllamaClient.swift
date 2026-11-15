import Foundation

enum OllamaClient {
    static func stream(_ req: ChatRequest, config: LLMConfig) async throws -> AsyncThrowingStream<String, Error> {
        guard let url = URL(string: config.baseURL)?.appendingPathComponent("api/chat") else {
            throw LLMError.notConfigured("Invalid Ollama URL in Settings.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Ollama loads models with a small window unless told otherwise, and
        // silently drops the start of a prompt that does not fit.
        let window = await MainActor.run { AppSettings.shared.localContextTokens }
        var body: [String: Any] = [
            "model": config.model,
            "stream": true,
            "options": ["num_ctx": window, "num_predict": req.maxOutput],
            "messages": [["role": "system", "content": req.fullSystem]] + req.wireMessages
        ]
        // Ollama takes a thinking level only for gpt-oss; other models
        // reject it, so it is sent to those alone.
        if let effort = config.effort, config.model.lowercased().contains("gpt-oss") {
            body["think"] = effort
        }
        request.httpBody = try LLM.jsonBody(body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw LLMError.network("Cannot reach Ollama at \(config.baseURL). Start it with `ollama serve` and pull the model (`ollama pull \(config.model)`).")
        }
        try await LLM.ensureOK(response, bytes: bytes)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        guard let event = LLM.parse(line[...]) else { continue }
                        if let message = event["message"] as? [String: Any],
                           let text = message["content"] as? String, !text.isEmpty {
                            continuation.yield(text)
                        }
                        if event["done"] as? Bool == true {
                            req.usage?.input = event["prompt_eval_count"] as? Int
                            req.usage?.output = event["eval_count"] as? Int
                            break
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
