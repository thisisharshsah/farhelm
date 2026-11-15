import Foundation
import AVFoundation
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
/// 2. Live verdict on "is this the user?": each finished utterance gets a
///    voiceprint (a WeSpeaker embedding), and a small per-user adapter
///    (`VoiceHead`) fitted to the setup recording and to every correction
///    decides whether it is the user. The diarizer only numbers the others,
///    and the voiceprint folds a voice it split across slots back into one.
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
    /// How close a voice must be to the user's voiceprint to count as the
    /// user. It starts from how consistent the setup recording is with
    /// itself, then moves with every correction and recheck, and is kept
    /// between sessions.
    private var meThreshold: Float = {
        let saved = UserDefaults.standard.float(forKey: "voiceThreshold")
        return saved > 0 ? saved : 0.45
    }()
    /// The adapter that decides "is this the user?": a small classifier over
    /// voiceprints, fitted to the setup recording and to every labeled
    /// example since. See `VoiceHead`.
    private var head: VoiceHead?
    /// Voiceprints of the parts of the setup recording: the first examples.
    private var enrollVectors: [[Float]] = []
    /// Labeled voiceprints from corrections and rechecks, kept on disk.
    private var examples: [VoiceExample] = []
    private var examplesLoaded = false
    private var exampleStore: VoiceExampleStore {
        VoiceExampleStore(url: ContextStore.shared.baseDir.appendingPathComponent("voice-examples.plist"))
    }
    /// Voiceprints of a public set of voices, one per person: what "other
    /// people" sound like before the user has corrected anything. Imported
    /// once from a folder of recordings and kept on disk.
    private var reference: [[Float]] = []
    private var referenceLoaded = false
    private static let maxReference = 600
    private var referenceURL: URL {
        ContextStore.shared.baseDir.appendingPathComponent("voice-reference.plist")
    }
    /// Similarities to the user's voiceprint for lines known to be the user
    /// and known not to be, from corrections and rechecks.
    private var knownMe: [Float] = []
    private var knownOther: [Float] = []
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
        knownMe = []
        knownOther = []
        head = nil
        enrollVectors = []
        examples = []
        examplesLoaded = true
        exampleStore.clear()
        meThreshold = 0.45
        UserDefaults.standard.removeObject(forKey: "voiceThreshold")
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
            let unit = vectors.map(Self.normalized)
            var sum: [Float] = []
            for vector in unit {
                sum = Self.add(sum, vector)
            }
            meVoice = Self.normalized(sum)
            // First estimate of the line between "me" and "not me": how well
            // each part of the setup recording matches the rest of it, less
            // a margin. Skipped once real examples have set it.
            if UserDefaults.standard.float(forKey: "voiceThreshold") <= 0, unit.count >= 3 {
                var lowest: Float = 1
                for (index, vector) in unit.enumerated() {
                    var rest: [Float] = []
                    for (other, value) in unit.enumerated() where other != index {
                        rest = Self.add(rest, value)
                    }
                    lowest = min(lowest, Self.similarity(vector, Self.normalized(rest)))
                }
                meThreshold = min(max(lowest - 0.12, 0.30), 0.60)
            }
            enrollVectors = unit
            loadReferenceIfNeeded()
            if !examplesLoaded {
                examplesLoaded = true
                examples = exampleStore.load()
            }
            refit()
            log.info("voiceprint ready from \(vectors.count) spans, \(self.examples.count) learned examples, threshold \(Double(self.meThreshold), format: .fixed(precision: 2))")
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

    /// Refits the adapter to the setup recording plus everything learned.
    private func refit() {
        guard let meVoice else { head = nil; return }
        let own = enrollVectors.map { VoiceExample(vector: $0, isMe: true) }
        head = VoiceHead.fitted(center: meVoice, threshold: meThreshold, examples: own + examples,
                                reference: reference)
    }

    // MARK: - Reference voices

    private func loadReferenceIfNeeded() {
        guard !referenceLoaded else { return }
        referenceLoaded = true
        reference = VoiceExampleStore.loadVectors(referenceURL)
    }

    func referenceVoiceCount() -> Int {
        loadReferenceIfNeeded()
        return reference.count
    }

    /// Takes one voiceprint per person from a folder of recordings (any
    /// layout: LibriSpeech, or one folder per person) and keeps them as
    /// examples of "not the user". Returns how many people were added.
    func importReferenceVoices(from folder: URL,
                               progress: @Sendable (Int, Int) -> Void) async throws -> Int {
        loadReferenceIfNeeded()
        let manager = try await offlineManager()

        // Group the audio files by speaker. LibriSpeech names files
        // speaker-chapter-utterance; otherwise the containing folder is the
        // speaker.
        var files: [String: [URL]] = [:]
        let kinds: Set<String> = ["flac", "wav", "mp3", "m4a", "aiff", "caf"]
        if let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) {
            while let url = walker.nextObject() as? URL {
                guard kinds.contains(url.pathExtension.lowercased()) else { continue }
                let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
                let libri = parts.count == 3 && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
                let speaker = libri ? String(parts[0]) : url.deletingLastPathComponent().lastPathComponent
                files[speaker, default: []].append(url)
            }
        }
        let speakers = files.keys.sorted()
        guard !speakers.isEmpty else {
            throw NSError(domain: "Companion", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "No audio files found in that folder."])
        }

        var added: [[Float]] = []
        for (index, speaker) in speakers.enumerated() {
            if Task.isCancelled { break }
            progress(index, speakers.count)
            // About ten seconds of this person, from their first recordings.
            var clip: [Float] = []
            for url in (files[speaker] ?? []).sorted(by: { $0.path < $1.path }) {
                guard clip.count < 10 * 16000 else { break }
                clip += Self.samples16k(url) ?? []
            }
            clip = Array(Self.voicedOnly(clip).prefix(15 * 16000))
            guard clip.count >= 3 * 16000, !offlineBusy else { continue }
            let seconds = Double(clip.count) / 16000
            if let vector = try? await manager.embedSpans(audioSource: ArrayAudioSampleSource(samples: clip),
                                                          spans: [0..<seconds]).first {
                added.append(Self.normalized(vector))
            }
        }
        progress(speakers.count, speakers.count)
        reference = Array((reference + added).suffix(Self.maxReference))
        VoiceExampleStore.saveVectors(reference, to: referenceURL)
        refit()
        log.info("reference voices: added \(added.count), now \(self.reference.count)")
        return added.count
    }

    /// A sound file as 16 kHz mono samples.
    private static func samples16k(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do { try file.read(into: buffer) } catch { return nil }
        let format = file.processingFormat
        if format.sampleRate == 16000, format.channelCount == 1, let data = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / format.sampleRate) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var failure: NSError?
        converter.convert(to: output, error: &failure) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard failure == nil, let data = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
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
        func nextNumber() -> Int {
            (otherNumbers.values.max() ?? 0) + 1
        }
        // Without a voiceprint (a very short line, or the models are not
        // loaded yet) the diarizer's slot is all there is.
        guard let voice, let meVoice else {
            guard let slot else { return nil }
            if slot == meIndex { return .me }
            if let number = otherNumbers[slot] { return .other(number) }
            let number = nextNumber()
            otherNumbers[slot] = number
            return .other(number)
        }

        // With one, the question "is this the user?" is answered by the
        // voice itself, measured against the user's own recording. That is
        // steadier than the diarizer, which has to keep track of who is who
        // as it goes and can swap or split voices.
        let toMe = Self.similarity(voice, meVoice)
        let toOthers = otherVoices.mapValues { Self.similarity(voice, Self.normalized($0)) }
        let closest = toOthers.max(by: { $0.value < $1.value })
        let label: SpeakerLabel
        // The adapter gives the verdict. Until it has seen a few voices that
        // are not the user, a voice that sits closer to someone already
        // heard is not taken for the user either.
        let chance = head?.probability(voice) ?? (toMe >= meThreshold ? 1 : 0)
        let taught = reference.count + examples.filter { !$0.isMe }.count >= 3
        if chance >= 0.5, taught || toMe + 0.03 >= (closest?.value ?? 0) {
            label = .me
        } else {
            // Someone else. Which one: the diarizer's slot if it has a
            // settled number, unless the voice clearly belongs to another
            // person already heard; a fresh slot joins a voice it matches,
            // or becomes a new person.
            var number: Int?
            if let slot, slot != meIndex, let known = otherNumbers[slot] {
                number = known
                if let closest, closest.key != known, closest.value >= 0.5,
                   closest.value > (toOthers[known] ?? 0) + 0.1 {
                    number = closest.key
                }
            } else if let closest, closest.value >= 0.45 || otherVoices.count >= 4 {
                number = closest.key
                if let slot, slot != meIndex { otherNumbers[slot] = closest.key }
            }
            let chosen = number ?? max(nextNumber(), (otherVoices.keys.max() ?? 0) + 1)
            if number == nil, let slot, slot != meIndex {
                otherNumbers[slot] = chosen
            }
            otherVoices[chosen] = Self.add(otherVoices[chosen] ?? [], voice)
            label = .other(chosen)
        }
        log.info("slot \(slot ?? -1), me chance \(Double(chance), format: .fixed(precision: 2)), voice to me \(Double(toMe), format: .fixed(precision: 2)) vs \(Double(self.meThreshold), format: .fixed(precision: 2)), closest other \(Double(closest?.value ?? 0), format: .fixed(precision: 2)) -> \(String(describing: label))")
        return label
    }

    /// A labeled example from the user (a corrected line) or from the
    /// offline recheck: this stretch of audio was the user, or was not.
    /// It moves the line between the two so the same mistake is less likely
    /// again, and adds the voice to the right person's voiceprint.
    func learn(startSample: Int, endSample: Int, isMe: Bool, other: Int?) async {
        guard let meVoice, let voice = await voiceprint(startSample: startSample, endSample: endSample) else { return }
        let toMe = Self.similarity(voice, meVoice)
        if isMe {
            knownMe.append(toMe)
        } else {
            knownOther.append(toMe)
            if let other {
                otherVoices[other] = Self.add(otherVoices[other] ?? [], voice)
            }
        }
        knownMe = Array(knownMe.suffix(40))
        knownOther = Array(knownOther.suffix(40))

        var threshold = meThreshold
        if let lowestMe = knownMe.min(), let highestOther = knownOther.max(), lowestMe > highestOther {
            // The two groups separate cleanly: draw the line between them.
            threshold = (lowestMe + highestOther) / 2
        } else if isMe, toMe < threshold {
            // The user was taken for someone else: let this voice through.
            threshold = toMe - 0.02
        } else if !isMe, toMe >= threshold {
            // Someone else was taken for the user: shut this voice out.
            threshold = toMe + 0.02
        }
        meThreshold = min(max(threshold, 0.20), 0.80)
        UserDefaults.standard.set(meThreshold, forKey: "voiceThreshold")

        // The example itself goes to the adapter, unless the same stretch of
        // audio is already there (a recheck run twice teaches nothing new).
        let seen = examples.contains { $0.isMe == isMe && Self.similarity($0.vector, voice) > 0.995 }
        if !seen {
            examples = VoiceExampleStore.trimmed(examples + [VoiceExample(vector: voice, isMe: isMe)])
            exampleStore.save(examples)
        }
        refit()
        log.info("learned \(isMe ? "me" : "other") at \(Double(toMe), format: .fixed(precision: 2)); threshold now \(Double(self.meThreshold), format: .fixed(precision: 2))")
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
