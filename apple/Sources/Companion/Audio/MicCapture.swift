import AVFoundation

/// Microphone capture ("You" side of the conversation).
final class MicCapture {
    private let engine = AVAudioEngine()
    private let resampler = AudioResampler()
    private var routeObserver: NSObjectProtocol?
    private var recentRestarts: [Date] = []
    private(set) var running = false

    /// Called on an audio thread with 16 kHz mono samples.
    var onSamples: (([Float]) -> Void)?
    /// Called on the main queue when the mic cannot be kept running.
    var onFailure: ((String) -> Void)?

    func start() throws {
        guard !running else { return }
        try startEngine()
        running = true
        recentRestarts = []
        // When the audio hardware changes (AirPods connect, a call starts, the
        // input device switches) the engine stops itself and posts this.
        routeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    func stop() {
        guard running else { return }
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
        routeObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.resampler.resample(buffer)
            if !samples.isEmpty { self.onSamples?(samples) }
        }
        engine.prepare()
        try engine.start()
    }

    private func handleConfigurationChange() {
        guard running else { return }
        // The notification also arrives for changes that leave the engine
        // running. Restarting then would tear down a working mic, and on some
        // devices that restart triggers the next notification: an endless
        // loop with no audio. Only act when the engine really stopped.
        guard !engine.isRunning else { return }

        let now = Date()
        recentRestarts = recentRestarts.filter { now.timeIntervalSince($0) < 10 }
        guard recentRestarts.count < 4 else {
            onFailure?("The microphone keeps being interrupted by an audio device change. Stop and start listening once the device has settled.")
            return
        }
        recentRestarts.append(now)
        restart(attempt: 1)
    }

    private func restart(attempt: Int) {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try startEngine()
        } catch {
            // The new device may not be ready yet; try a few more times.
            guard attempt < 4 else {
                onFailure?("The microphone stopped after an audio device change and could not restart: \(error.localizedDescription)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.restart(attempt: attempt + 1)
            }
        }
    }
}
