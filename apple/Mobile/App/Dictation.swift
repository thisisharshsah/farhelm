import AVFoundation
import Observation
import Speech

/// Speaking into the chat box: the words are recognized on the phone as
/// they are said and land in the box, to send or change.
@MainActor
@Observable
final class Dictation {
    private(set) var listening = false
    private(set) var problem: String?
    /// What has been said so far, while listening.
    private(set) var heard = ""

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer()

    /// Starts listening, asking for the microphone and speech recognition
    /// the first time.
    func start() async {
        guard !listening else { return }
        problem = nil
        heard = ""
        let speech = await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
        }
        guard speech == .authorized else {
            problem = "Allow Speech Recognition for Companion in Settings to dictate."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            problem = "Allow the microphone for Companion in Settings to dictate."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            problem = "Dictation is not available right now."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            listening = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.heard = text }
                    if error != nil || final { self.stop() }
                }
            }
        } catch {
            problem = "Could not start dictation: \(error.localizedDescription)"
            stop()
        }
    }

    /// Stops listening; what was heard stays in `heard`.
    func stop() {
        guard listening || task != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
