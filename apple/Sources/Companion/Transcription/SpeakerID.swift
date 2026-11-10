import Foundation
import os
import FluidAudio

enum SpeakerLabel: Equatable {
    case me
    case other(Int) // 1-based: P1, P2, ...
}

/// Tells voices apart on the microphone, with three FluidAudio models:
///
/// 1. Live: the streaming Sortformer diarizer listens to the continuous mic
///    stream and keeps each voice in a slot (up to four). The user's recorded
///    voice primes it at the start of a session, so the "Me" slot is known.
/// 2. Live second opinion: each finished utterance gets a voiceprint (a
///    WeSpeaker embedding) that is compared with the user's own voiceprint
///    and with the voices heard so far. It overrules the diarizer when the
///    voice clearly says otherwise, and folds a voice that the diarizer split
///    across two slots back into one person.
/// 3. Recheck: the offline pyannote pipeline (segmentation, embeddings, VBx
///    clustering) re-labels the whole recorded session at once, which is the
///    most accurate of the three because it hears everything before deciding.
actor SpeakerID {
    private let log = Logger(subsystem: "com.harshsah.companion", category: "speaker")
    private var diarizer: SortformerDiarizer?
    private var enrollment: [Float]?
    private var profileLoaded = false
    private var sessionReady = false
    private var startGeneration = 0
    private var meIndex: Int?
    private var otherNumbers: [Int: Int] = [:]
    private var feedTask: Task<Void, Never>?
    private let feed = FeedBox()

    /// The session's mic audio, on the same sample clock as the chunker, kept
    /// for voiceprints and for the by-voice recheck. Capped; `audioOffset` is
    /// how many samples have been dropped from the front.
    private var sessionAudio: [Float] = []
    private var audioOffset = 0
    private static let maxSessionSamples = 30 * 60 * 16000
    /// Identifies the session the kept audio belongs to.
    private var activeSession = 0

    private var offline: OfflineDiarizerManager?
    private var offlineLoading = false
    /// The offline pipeline is running; voiceprints must not use the models.
    private var offlineBusy = false
    private var meVoice: [Float]?
    /// Running voiceprint of each other person, keyed by P number.
    private var otherVoices: [Int: [Float]] = [:]

    /// Hands mic audio from the audio thread to the diarizer, in order.
    private final class FeedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<[Float]>.Continuation?

        func set(_ new: AsyncStream<[Float]>.Continuation?) {
            lock.lock()
            continuation?.finish()
            continuation = new
            lock.unlock()
        }

        func yield(_ samples: [Float]) {
            lock.lock()
            let current = continuation
            lock.unlock()
            current?.yield(samples)
        }
    }

    private var profileURL: URL {
        ContextStore.shared.baseDir.appendingPathComponent("voice-profile.pcm")
    }

    /// Downloads (first use) and loads the diarization model.
    func prepare() async throws {
        if diarizer == nil {
            let config = SortformerConfig.default
            let models = try await SortformerModels.loadFromHuggingFace(config: config)
            let loaded = SortformerDiarizer(config: config)
            loaded.initialize(models: models)
            diarizer = loaded
        }
        loadProfileIfNeeded()
    }

    func enrolled() -> Bool {
        loadProfileIfNeeded()
        return enrollment != nil
    }

    /// Stores the user's voice: the voiced part of ~10 s of their speech,
    /// replayed to the diarizer at the start of every session.
    func enroll(samples: [Float]) async throws {
        let voiced = Self.voicedOnly(samples)
        guard voiced.count >= 3 * 16000 else {
            throw NSError(domain: "Companion", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Too little speech in the recording. Speak continuously for the whole 10 seconds and try again."])
        }
        let kept = Array(voiced.prefix(15 * 16000))
        let data = kept.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: profileURL, options: .atomic)
        enrollment = kept
        meVoice = nil
        profileLoaded = true
        log.info("voice enrolled from \(kept.count) voiced samples")
        try await prepare()
    }

    /// Starts a fresh diarization session primed with the user's voice. Call
    /// before the mic starts, so the stream clock matches the chunker's.
    ///
    /// Returns whether the session is ready. If the caller gave up waiting
    /// (see `abandonStart`), a late finish does not activate the session,
    /// because its clock would no longer match the mic stream.
    func startSession() async -> Bool {
        endSession()
        startGeneration += 1
        let generation = startGeneration
        do {
            try await prepare()
        } catch {
            log.error("diarizer unavailable: \(error.localizedDescription)")
            return false
        }
        guard generation == startGeneration, let diarizer, let enrollment else { return false }
        diarizer.reset()
        otherNumbers = [:]
        otherVoices = [:]
        sessionAudio = []
        audioOffset = 0
        meIndex = nil
        do {
            guard let me = try diarizer.enrollSpeaker(withAudio: enrollment, named: "Me") else {
                log.error("enrollment audio did not map to a speaker slot")
                return false
            }
            meIndex = me.index
        } catch {
            log.error("priming failed: \(error.localizedDescription)")
            return false
        }
        guard generation == startGeneration else { return false }
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        feed.set(continuation)
        feedTask = Task { [weak self] in
            for await chunk in stream {
                await self?.consume(chunk)
            }
        }
        sessionReady = true
        activeSession = generation
        log.info("diarization session started, me = slot \(self.meIndex ?? -1)")
        // The voiceprint models load in the background; until they are ready
        // the live labels come from the diarizer alone.
        Task { await self.prepareVoiceprints() }
        return true
    }

    /// The session whose audio is currently kept. Lines remember it, so a
    /// recheck never matches them against another session's audio.
    func sessionID() -> Int {
        activeSession
    }

    /// The caller stopped waiting for `startSession`; make its eventual
    /// completion a no-op. The model keeps loading, so the next start is fast.
    func abandonStart() {
        startGeneration += 1
        endSession()
    }

    func endSession() {
        feedTask?.cancel()
        feedTask = nil
        feed.set(nil)
        sessionReady = false
    }

    /// Mic audio, in capture order. Safe to call from the audio thread.
    nonisolated func ingest(_ samples: [Float]) {
        feed.yield(samples)
    }

    private func consume(_ chunk: [Float]) {
        guard let diarizer else { return }
        sessionAudio.append(contentsOf: chunk)
        if sessionAudio.count > Self.maxSessionSamples {
            let drop = sessionAudio.count - Self.maxSessionSamples
            sessionAudio.removeFirst(drop)
            audioOffset += drop
        }
        diarizer.addAudio(chunk)
        _ = try? diarizer.process()
    }

    // MARK: - Voiceprints (live second opinion)

    private func offlineManager() async throws -> OfflineDiarizerManager {
        // One load at a time: a second caller waits for the first.
        while offlineLoading {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if let offline { return offline }
        offlineLoading = true
        defer { offlineLoading = false }
        let manager = OfflineDiarizerManager()
        try await manager.prepareModels()
        offline = manager
        return manager
    }

    /// Loads the embedding models and takes the user's voiceprint from their
    /// voice setup recording.
    private func prepareVoiceprints() async {
        guard meVoice == nil, let enrollment else { return }
        do {
            let manager = try await offlineManager()
            let seconds = Double(enrollment.count) / 16000
            var spans: [Range<TimeInterval>] = []
            var start = 0.0
            while start + 2 <= seconds {
                spans.append(start..<min(start + 5, seconds))
                start += 5
            }
            guard !spans.isEmpty else { return }
            let vectors = try await manager.embedSpans(audioSource: ArrayAudioSampleSource(samples: enrollment),
                                                       spans: spans)
            var sum: [Float] = []
            for vector in vectors {
                sum = Self.add(sum, Self.normalized(vector))
            }
            meVoice = Self.normalized(sum)
            log.info("voiceprint ready from \(vectors.count) spans")
        } catch {
            log.error("voiceprints unavailable: \(error.localizedDescription)")
        }
    }

    /// The voiceprint of one utterance, or nil when it is too short, its
    /// audio is not available, or the models are not ready or are busy.
    private func voiceprint(startSample: Int, endSample: Int) async -> [Float]? {
        guard meVoice != nil, !offlineBusy, let offline else { return nil }
        let from = max(startSample - audioOffset, 0)
        let to = min(endSample - audioOffset, sessionAudio.count)
        guard to - from >= Int(1.2 * 16000) else { return nil }
        let clip = Array(sessionAudio[from..<to])
        let seconds = Double(clip.count) / 16000
        guard let vector = try? await offline.embedSpans(audioSource: ArrayAudioSampleSource(samples: clip),
                                                         spans: [0..<seconds]).first else { return nil }
        return Self.normalized(vector)
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        var sum: Float = 0
        for value in vector { sum += value * value }
        let length = sqrt(sum)
        guard length > 0 else { return vector }
        return vector.map { $0 / length }
    }

    private static func add(_ a: [Float], _ b: [Float]) -> [Float] {
        guard a.count == b.count else { return a.isEmpty ? b : a }
        return zip(a, b).map { $0 + $1 }
    }

    /// Cosine similarity of two voiceprints (both already unit length).
    private static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var sum: Float = 0
        for index in a.indices { sum += a[index] * b[index] }
        return sum
    }

    // MARK: - Recheck by voice (offline pipeline)

    /// Re-labels stretches of the session by voice with the offline pipeline,
    /// which hears the whole recording before deciding. Each range is in mic
    /// samples on the session clock; the result has one label per range, nil
    /// where the pipeline has no confident coverage.
    ///
    /// The user's voice setup recording is placed in front of the session
    /// audio, so whichever voice the pipeline finds there is "Me".
    func relabel(session: Int, ranges: [Range<Int>]) async throws -> [SpeakerLabel?] {
        guard session == activeSession, let enrollment, sessionAudio.count >= 16000 else {
            throw NSError(domain: "Companion", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "The audio of this conversation is not available for a recheck by voice."])
        }
        let manager = try await offlineManager()
        let gap = 16000
        let offset = audioOffset
        var audio = enrollment
        audio.append(contentsOf: [Float](repeating: 0, count: gap))
        audio.append(contentsOf: sessionAudio)
        let shift = enrollment.count + gap - offset
        let enrollEnd = Float(enrollment.count) / 16000

        offlineBusy = true
        defer { offlineBusy = false }
        let result = try await manager.process(audio: audio)

        var timeInEnrollment: [String: Float] = [:]
        for segment in result.segments {
            let shared = min(segment.endTimeSeconds, enrollEnd) - max(segment.startTimeSeconds, 0)
            if shared > 0 {
                timeInEnrollment[segment.speakerId, default: 0] += shared
            }
        }
        guard let me = timeInEnrollment.max(by: { $0.value < $1.value })?.key else {
            throw NSError(domain: "Companion", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "The recheck by voice could not find your voice. Redo voice setup and try again."])
        }
        // Everyone else is numbered in the order they first speak.
        var numbers: [String: Int] = [:]
        for segment in result.segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds })
        where segment.speakerId != me && segment.endTimeSeconds > enrollEnd {
            if numbers[segment.speakerId] == nil {
                numbers[segment.speakerId] = numbers.count + 1
            }
        }
        log.info("offline diarization: \(result.segments.count) segments, \(numbers.count) other speakers")

        return ranges.map { range -> SpeakerLabel? in
            guard range.lowerBound >= offset else { return nil }
            let start = Float(range.lowerBound + shift) / 16000
            let end = Float(range.upperBound + shift) / 16000
            guard end - start >= 0.3 else { return nil }
            var overlap: [String: Float] = [:]
            for segment in result.segments {
                let shared = min(segment.endTimeSeconds, end) - max(segment.startTimeSeconds, start)
                if shared > 0 {
                    overlap[segment.speakerId, default: 0] += shared
                }
            }
            guard let best = overlap.max(by: { $0.value < $1.value }),
                  best.value >= max(0.2, (end - start) * 0.3) else { return nil }
            if best.key == me { return .me }
            return numbers[best.key].map { SpeakerLabel.other($0) }
        }
    }

    /// Who spoke during the given stretch of the mic stream. nil when there is
    /// no session or neither model has a confident answer for that stretch.
    func classify(startSample: Int, endSample: Int) async -> SpeakerLabel? {
        guard sessionReady, meIndex != nil else { return nil }
        let slot = await diarizerSlot(startSample: startSample, endSample: endSample)
        let voice = await voiceprint(startSample: startSample, endSample: endSample)
        return decide(slot: slot, voice: voice)
    }

    /// The diarizer's slot for the stretch, if it has confident coverage.
    private func diarizerSlot(startSample: Int, endSample: Int) async -> Int? {
        guard let diarizer else { return nil }
        let start = Float(startSample) / 16000
        let end = Float(endSample) / 16000
        guard end - start >= 0.3 else { return nil }

        // The model trails live audio by about a second; give it a few
        // moments to cover the utterance before giving up.
        for attempt in 0..<4 {
            var overlap: [Int: Float] = [:]
            for (index, speaker) in diarizer.timeline.speakers {
                for segment in speaker.finalizedSegments + speaker.tentativeSegments {
                    let shared = min(segment.endTime, end) - max(segment.startTime, start)
                    if shared > 0 {
                        overlap[index, default: 0] += shared
                    }
                }
            }
            if let best = overlap.max(by: { $0.value < $1.value }),
               best.value >= max(0.2, (end - start) * 0.3) {
                return best.key
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
        return nil
    }

    /// Combines the diarizer's slot with the utterance's voiceprint.
    ///
    /// The diarizer is trusted by default. The voiceprint overrules it only
    /// when the voice is clearly someone else's, and it decides what a slot
    /// the diarizer has not used before really is: the user, a person already
    /// heard (the same voice split across slots), or somebody new.
    private func decide(slot: Int?, voice: [Float]?) -> SpeakerLabel? {
        var label: SpeakerLabel?
        var newSlot: Int?
        if let slot {
            if slot == meIndex {
                label = .me
            } else if let number = otherNumbers[slot] {
                label = .other(number)
            } else {
                newSlot = slot
            }
        }
        func nextNumber() -> Int {
            (otherNumbers.values.max() ?? 0) + 1
        }
        guard let voice, let meVoice else {
            if let newSlot {
                let number = nextNumber()
                otherNumbers[newSlot] = number
                label = .other(number)
            }
            return label
        }

        let toMe = Self.similarity(voice, meVoice)
        let toOthers = otherVoices.mapValues { Self.similarity(voice, Self.normalized($0)) }
        let closest = toOthers.max(by: { $0.value < $1.value })

        if let newSlot {
            if toMe >= 0.5, toMe >= (closest?.value ?? 0) {
                // A fresh slot that sounds like the user: the diarizer split
                // the user's voice.
                label = .me
            } else if let closest, closest.value >= 0.5 {
                // A fresh slot that sounds like someone already heard.
                otherNumbers[newSlot] = closest.key
                label = .other(closest.key)
            } else {
                let number = nextNumber()
                otherNumbers[newSlot] = number
                label = .other(number)
            }
        } else if label == .me {
            if toMe < 0.2, let closest, closest.value >= 0.45 {
                label = .other(closest.key)
            }
        } else if case .other(let number)? = label {
            let own = toOthers[number] ?? 0
            if toMe >= 0.45, toMe > own + 0.1 {
                label = .me
            } else if let closest, closest.key != number, closest.value >= 0.5, closest.value > own + 0.1 {
                label = .other(closest.key)
            }
        } else {
            // The diarizer had no answer; the voice may.
            if toMe >= 0.5, toMe >= (closest?.value ?? 0) {
                label = .me
            } else if let closest, closest.value >= 0.5 {
                label = .other(closest.key)
            }
        }

        if case .other(let number)? = label {
            otherVoices[number] = Self.add(otherVoices[number] ?? [], voice)
        }
        log.info("slot \(slot ?? -1), voice to me \(Double(toMe), format: .fixed(precision: 2)), closest other \(Double(closest?.value ?? 0), format: .fixed(precision: 2)) -> \(String(describing: label))")
        return label
    }

    private func loadProfileIfNeeded() {
        guard !profileLoaded else { return }
        profileLoaded = true
        guard let data = try? Data(contentsOf: profileURL), data.count >= 3 * 16000 * MemoryLayout<Float>.size else {
            return
        }
        enrollment = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Keeps only 100 ms frames with speech energy, so silence doesn't dilute
    /// the enrollment.
    private static func voicedOnly(_ samples: [Float], frame: Int = 1600, floor: Float = 0.004) -> [Float] {
        var kept: [Float] = []
        kept.reserveCapacity(samples.count)
        var start = 0
        while start + frame <= samples.count {
            var sum: Float = 0
            for index in start..<(start + frame) {
                sum += samples[index] * samples[index]
            }
            if sqrt(sum / Float(frame)) >= floor {
                kept.append(contentsOf: samples[start..<(start + frame)])
            }
            start += frame
        }
        return kept
    }
}
