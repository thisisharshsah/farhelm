import Foundation

struct SpeechChunk {
    let samples: [Float]
    let utteranceID: UUID
    let seq: Int
    let isFinal: Bool
    /// Position of this utterance in the stream, in samples since the chunker
    /// was last reset. Lets the speaker diarizer look up who was talking.
    let startSample: Int
    let endSample: Int
}

/// Energy-based voice activity detection over 16 kHz mono samples.
/// Groups speech into utterances, emits rolling partials while someone is
/// talking and a final chunk after ~500 ms of silence. All state is confined
/// to the single audio queue that feeds it.
final class SpeechChunker {
    var onChunk: ((SpeechChunk) -> Void)?
    var onLevel: ((Float) -> Void)?
    /// Minimum RMS a frame needs to count as speech. Lower = more sensitive,
    /// needed when the other voice reaches the mic quietly (phone on speaker,
    /// someone across the room).
    var vadFloor: Float = 0.006

    private let frameSize = 1600                  // 100 ms at 16 kHz
    private let silenceFramesToEnd = 5            // 500 ms
    private let softCapFrames = 100               // after 10 s, end at the next short pause
    private let maxUtteranceFrames = 140          // 14 s hard cap (model window is ~15 s)
    private let preRollFrames = 3                 // 300 ms kept before speech starts
    private let minSpeechFrames = 2               // ignore blips under 200 ms
    private let partialEveryFrames = 8            // live partial every 0.8 s

    private var pending: [Float] = []
    private var preRoll: [Float] = []
    private var utterance: [Float] = []
    private var utteranceID = UUID()
    private var seq = 0
    private var speaking = false
    private var silenceRun = 0
    private var speechFrames = 0
    private var framesSincePartial = 0
    private var noiseFloor: Float = 0.004
    private var position = 0                      // samples processed since reset
    private var utteranceStart = 0

    func feed(_ samples: [Float]) {
        pending.append(contentsOf: samples)
        while pending.count >= frameSize {
            let frame = Array(pending.prefix(frameSize))
            pending.removeFirst(frameSize)
            process(frame)
        }
    }

    func reset() {
        pending = []
        preRoll = []
        utterance = []
        speaking = false
        silenceRun = 0
        speechFrames = 0
        noiseFloor = 0.004
        position = 0
        utteranceStart = 0
        onLevel?(0)
    }

    private func process(_ frame: [Float]) {
        position += frame.count
        var sum: Float = 0
        for sample in frame { sum += sample * sample }
        let rms = sqrt(sum / Float(frame.count))
        onLevel?(min(1, rms * 18))

        let threshold = max(noiseFloor * 2.5, vadFloor)
        let isSpeech = rms >= threshold
        if !isSpeech {
            // The adaptive floor is capped. Uncapped, steady quiet speech (a
            // phone on speaker) kept raising it until nothing counted as
            // speech any more and listening appeared to stop.
            noiseFloor = min(noiseFloor * 0.97 + rms * 0.03, vadFloor * 1.2)
        }

        if speaking {
            utterance.append(contentsOf: frame)
            if isSpeech {
                silenceRun = 0
                speechFrames += 1
            } else {
                silenceRun += 1
            }
            framesSincePartial += 1
            let frames = utterance.count / frameSize
            // Long speech is cut at a breath (200 ms pause) rather than
            // mid-word, so sentences aren't split in awkward places.
            let atSoftBreak = frames >= softCapFrames && silenceRun >= 2
            if silenceRun >= silenceFramesToEnd || atSoftBreak || frames >= maxUtteranceFrames {
                finishUtterance()
            } else if framesSincePartial >= partialEveryFrames, speechFrames >= minSpeechFrames {
                framesSincePartial = 0
                seq += 1
                onChunk?(SpeechChunk(samples: utterance,
                                     utteranceID: utteranceID,
                                     seq: seq,
                                     isFinal: false,
                                     startSample: utteranceStart,
                                     endSample: position))
            }
        } else {
            preRoll.append(contentsOf: frame)
            let maxPre = preRollFrames * frameSize
            if preRoll.count > maxPre {
                preRoll.removeFirst(preRoll.count - maxPre)
            }
            if isSpeech {
                speaking = true
                utteranceID = UUID()
                seq = 0
                speechFrames = 1
                silenceRun = 0
                framesSincePartial = 0
                utterance = preRoll
                utteranceStart = position - preRoll.count
                preRoll = []
            }
        }
    }

    private func finishUtterance() {
        defer {
            speaking = false
            utterance = []
            speechFrames = 0
            silenceRun = 0
        }
        guard speechFrames >= minSpeechFrames else {
            // Too short to transcribe; tell the pipeline to drop any partial it showed.
            onChunk?(SpeechChunk(samples: [],
                                 utteranceID: utteranceID,
                                 seq: Int.max,
                                 isFinal: true,
                                 startSample: utteranceStart,
                                 endSample: position))
            return
        }
        var samples = utterance
        var end = position
        let keepTail = 2 * frameSize
        let trailingSilence = silenceRun * frameSize
        if trailingSilence > keepTail {
            samples.removeLast(trailingSilence - keepTail)
            end -= trailingSilence - keepTail
        }
        onChunk?(SpeechChunk(samples: samples,
                             utteranceID: utteranceID,
                             seq: Int.max,
                             isFinal: true,
                             startSample: utteranceStart,
                             endSample: end))
    }
}
