import Foundation

/// One labeled voiceprint: this voice was the user, or was not.
struct VoiceExample: Codable {
    let vector: [Float]
    let isMe: Bool
}

/// A small per-person adapter on top of the frozen voice model: a logistic
/// classifier over voiceprints that answers "is this that person?".
///
/// It starts as the plain rule "close enough to the person's voiceprint",
/// so it works with no examples at all. Every labeled example (a corrected
/// speaker badge, a recheck verdict) then bends it toward what actually
/// separates this person from the people around them. Training is a few
/// hundred steps over a few hundred numbers and takes milliseconds, so it is
/// simply refitted whenever an example arrives. More people means one more
/// head per person; the voice model itself never changes.
struct VoiceHead {
    private(set) var weights: [Float]
    private(set) var bias: Float

    /// One training example and how much it counts.
    private struct Weighted {
        let vector: [Float]
        let isMe: Bool
        let weight: Float
    }

    /// How sharply the starting rule turns from "no" to "yes" around the
    /// threshold.
    private static let sharpness: Float = 12

    /// The starting rule: similarity to `center` at or above `threshold`.
    init(center: [Float], threshold: Float) {
        weights = center.map { $0 * Self.sharpness }
        bias = -Self.sharpness * threshold
    }

    /// How likely the voice is this person's, 0 to 1.
    func probability(_ voice: [Float]) -> Float {
        guard voice.count == weights.count else { return 0 }
        var sum = bias
        for index in voice.indices { sum += weights[index] * voice[index] }
        return 1 / (1 + exp(-sum))
    }

    /// The starting rule, fitted to the examples. The fit is held near the
    /// starting rule, so a handful of examples adjusts it and cannot wreck
    /// it, and both kinds of example count equally however many there are of
    /// each.
    ///
    /// `reference` is voiceprints of people who are certainly not this
    /// person (a public set of voices). They show the head what other people
    /// sound like in general, but the user's own "not me" examples, the
    /// voices actually around them, carry more weight than the whole set.
    static func fitted(center: [Float], threshold: Float, examples: [VoiceExample],
                       reference: [[Float]] = []) -> VoiceHead {
        var head = VoiceHead(center: center, threshold: threshold)
        let learned = examples.filter { $0.vector.count == center.count }
        let general = reference.filter { $0.count == center.count }
        let positives = Float(learned.filter(\.isMe).count)
        let negatives = Float(learned.count) - positives
        guard positives > 0, negatives > 0 || !general.isEmpty else { return head }

        // Half the say goes to "me", half to "not me"; within "not me" the
        // learned examples get the larger part when both kinds are present.
        let learnedShare: Float = general.isEmpty ? 0.5 : (negatives > 0 ? 0.3 : 0)
        let generalShare: Float = 0.5 - learnedShare
        var usable: [Weighted] = learned.map {
            Weighted(vector: $0.vector, isMe: $0.isMe,
                     weight: $0.isMe ? 0.5 / positives : learnedShare / max(negatives, 1))
        }
        for vector in general {
            usable.append(Weighted(vector: vector, isMe: false, weight: generalShare / Float(general.count)))
        }

        let prior = head
        let rate: Float = 0.5
        let hold: Float = 0.02
        for _ in 0..<300 {
            var gradient = [Float](repeating: 0, count: center.count)
            var biasGradient: Float = 0
            for example in usable {
                let target: Float = example.isMe ? 1 : 0
                let error = (head.probability(example.vector) - target) * example.weight
                for index in gradient.indices { gradient[index] += error * example.vector[index] }
                biasGradient += error
            }
            for index in gradient.indices {
                gradient[index] += hold * (head.weights[index] - prior.weights[index])
                head.weights[index] -= rate * gradient[index]
            }
            head.bias -= rate * (biasGradient + hold * (head.bias - prior.bias))
        }
        return head
    }
}

/// The labeled voiceprints the head is fitted to, kept on disk between
/// sessions. The newest examples of each kind are kept.
struct VoiceExampleStore {
    private static let perKind = 150
    let url: URL

    func load() -> [VoiceExample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? PropertyListDecoder().decode([VoiceExample].self, from: data)) ?? []
    }

    func save(_ examples: [VoiceExample]) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(examples) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    // Reference voices: plain voiceprints of people who are not the user.

    static func loadVectors(_ url: URL) -> [[Float]] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? PropertyListDecoder().decode([[Float]].self, from: data)) ?? []
    }

    static func saveVectors(_ vectors: [[Float]], to url: URL) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(vectors) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Drops the oldest examples beyond the cap, per kind.
    static func trimmed(_ examples: [VoiceExample]) -> [VoiceExample] {
        var kept: [VoiceExample] = []
        var counts: [Bool: Int] = [:]
        for example in examples.reversed() where counts[example.isMe, default: 0] < perKind {
            counts[example.isMe, default: 0] += 1
            kept.append(example)
        }
        return kept.reversed()
    }
}
