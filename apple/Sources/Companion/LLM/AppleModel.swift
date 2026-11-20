import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model, the one behind Apple Intelligence: free,
/// private and offline, on a Mac with Apple Intelligence turned on
/// (macOS 26 and later). Nothing to install and no key.
///
/// It holds a few thousand tokens, prompt and answer together, so requests
/// are sized to what the system says it holds, and agent tasks, which need
/// far more, are left to a bigger engine.
enum AppleModel {
    /// Its one model, as shown beside the engine's name.
    static let modelName = "On device"

    /// What it is taken to hold when the system cannot say.
    static let fallbackContext = 4_096

    /// The least an agent task needs: its instructions, the task, and what
    /// each step shows.
    static let agentContext = 16_000

    /// Why it cannot answer on this Mac, in words for the screen; nil when
    /// it can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return "This Mac cannot run Apple's model. It needs Apple silicon and Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in System Settings to use Apple's model."
            case .unavailable(.modelNotReady):
                return "Apple's model is still downloading. Try again in a few minutes."
            case .unavailable:
                return "Apple's model is not available on this Mac right now."
            }
        }
        #endif
        return "Apple's model needs macOS 26 or later."
    }

    @MainActor private static var knownContext: Int?

    /// Tokens it holds, prompt and answer together, as the system says.
    @MainActor static var contextTokens: Int {
        if let knownContext { return knownContext }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            let size = SystemLanguageModel.default.contextSize
            knownContext = size
            return size
        }
        #endif
        return fallbackContext
    }

    /// An answer to a request, in pieces as it is written.
    static func stream(_ request: ChatRequest) throws -> AsyncThrowingStream<String, Error> {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if let reason = unavailableReason { throw LLMError.notConfigured(reason) }
            return OnDeviceModel.stream(request)
        }
        #endif
        throw LLMError.notConfigured(unavailableReason ?? "Apple's model is not available on this Mac.")
    }

    /// The conversation as one prompt. The model takes its instructions and
    /// one prompt, so earlier turns are written out above the newest.
    static func prompt(for messages: [ChatMessage]) -> String {
        guard let last = messages.last else { return "" }
        let earlier = messages.dropLast()
        guard !earlier.isEmpty else { return last.content }
        let turns = earlier.map { ($0.role == "assistant" ? "Assistant: " : "User: ") + $0.content }
        return "Earlier in this conversation:\n\n" + turns.joined(separator: "\n\n")
            + "\n\nThe newest message:\n\n" + last.content
    }

    /// An error from the model, in words for the screen. Errors are told
    /// apart by name, so the same code reads macOS 26's and macOS 27's,
    /// whose error types differ.
    static func explain(_ error: Error, holds tokens: Int) -> Error {
        if error is CancellationError { return error }
        let name = String(describing: error)
        let message: String
        if name.contains("exceededContextWindowSize") || name.contains("contextSizeExceeded") {
            message = "That is too long for Apple's model, which holds about \(tokens) tokens. Choose a bigger engine for it."
        } else if name.contains("guardrailViolation") || name.contains("refusal") {
            message = "Apple's model declined to answer this. Choose another engine for it."
        } else if name.contains("unsupportedLanguageOrLocale") {
            message = "Apple's model does not support this language yet."
        } else if name.contains("rateLimited") || name.contains("concurrentRequests") {
            message = "Apple's model is busy. Try again in a moment."
        } else if name.contains("assetsUnavailable") {
            message = "Apple's model is not ready yet. It may still be downloading."
        } else {
            message = "Apple's model could not answer: \(error.localizedDescription)"
        }
        return LLMError.engine(message)
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
private enum OnDeviceModel {
    static func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        let instructions = request.fullSystem
        let prompt = AppleModel.prompt(for: request.messages)
        let holds = SystemLanguageModel.default.contextSize
        // Prompt and answer share the context: the answer gets what the
        // prompt leaves, up to what the request asks for. Text is counted
        // at three characters a token, on the safe side.
        let used = (instructions.count + prompt.count) / 3
        let limit = max(128, min(request.maxOutput, holds - used - 64))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    var options = GenerationOptions()
                    options.maximumResponseTokens = limit
                    // Each snapshot holds the answer so far, so only what is
                    // new goes on. A piece that does not continue what was
                    // sent is new text in itself.
                    var sent = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        let text = snapshot.content
                        if text.hasPrefix(sent) {
                            let added = text.dropFirst(sent.count)
                            if !added.isEmpty { continuation.yield(String(added)) }
                            sent = text
                        } else {
                            continuation.yield(text)
                            sent += text
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AppleModel.explain(error, holds: holds))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
