import Foundation
import FluidAudio

/// Thin wrapper around FluidAudio's Parakeet (CoreML, Apple Neural Engine).
/// This is the only file that touches the FluidAudio ASR API (written against
/// 0.18.x); if a future release changes names, fix it here against their
/// README quickstart.
///
/// Parakeet v3 is multilingual (25 European languages); v2 is English-only
/// and more accurate for English. Each is downloaded once and cached.
actor Transcriber {
    private var manager: AsrManager?
    private var loadedEnglishOnly: Bool?
    private var wantsEnglishOnly = false
    private var loading: (englishOnly: Bool, task: Task<AsrManager, Error>)?
    private var upgrade: Task<Void, Never>?

    /// Whether a model is already on disk, so loading it needs no download.
    static func isCached(englishOnly: Bool) -> Bool {
        let version: AsrModelVersion = englishOnly ? .v2 : .v3
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    /// Makes a speech model ready and reports progress in plain words.
    ///
    /// Never waits on the English-only download when the multilingual model
    /// is already on disk: it uses that one right away, fetches the other in
    /// the background and switches when it is ready. Returns true in that
    /// case, so the caller can tell the user.
    @discardableResult
    func prepare(englishOnly: Bool, report: @escaping @Sendable (String) -> Void) async throws -> Bool {
        wantsEnglishOnly = englishOnly
        if manager != nil, loadedEnglishOnly == englishOnly { return false }

        if englishOnly, !Self.isCached(englishOnly: true), Self.isCached(englishOnly: false) {
            if manager == nil || loadedEnglishOnly != false {
                manager = try await load(englishOnly: false, report: report)
                loadedEnglishOnly = false
            }
            startUpgrade(report: report)
            return true
        }

        manager = try await load(englishOnly: englishOnly, report: report)
        loadedEnglishOnly = englishOnly
        return false
    }

    /// Loads one model, downloading it if needed. Concurrent requests for the
    /// same model share one load instead of starting a second download.
    private func load(englishOnly: Bool, report: @escaping @Sendable (String) -> Void) async throws -> AsrManager {
        if let loading, loading.englishOnly == englishOnly {
            return try await loading.task.value
        }
        let task = Task { () throws -> AsrManager in
            let models = try await AsrModels.downloadAndLoad(
                version: englishOnly ? .v2 : .v3,
                progressHandler: { progress in
                    switch progress.phase {
                    case .listing:
                        report("Checking speech model")
                    case .downloading(let completed, let total):
                        let percent = Int((progress.fractionCompleted * 100).rounded())
                        report("Downloading speech model \(percent)% (file \(min(completed + 1, total)) of \(total))")
                    case .compiling:
                        report("Preparing speech model")
                    }
                })
            let asrManager = AsrManager(config: .default)
            try await asrManager.loadModels(models)
            // Warm up CoreML with half a second of silence so the first real
            // utterance isn't paying kernel-compilation cost.
            if var warm = try? TdtDecoderState() {
                _ = try? await asrManager.transcribe(Array(repeating: 0, count: 8000), decoderState: &warm)
            }
            return asrManager
        }
        loading = (englishOnly, task)
        defer { loading = nil }
        return try await task.value
    }

    /// Fetches the English-only model in the background and adopts it once it
    /// is ready, provided the user still wants it.
    private func startUpgrade(report: @escaping @Sendable (String) -> Void) {
        guard upgrade == nil else { return }
        upgrade = Task {
            defer { upgrade = nil }
            guard let english = try? await load(englishOnly: true, report: { _ in }) else { return }
            guard wantsEnglishOnly else { return }
            manager = english
            loadedEnglishOnly = true
            report("English-only speech model is now in use")
        }
    }

    /// `samples` must be 16 kHz mono Float32. Each call is one independent
    /// utterance, so it gets a fresh decoder state; that also keeps the mic
    /// and system-audio streams from contaminating each other.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard samples.count >= 1600, let manager else { return "" }
        var state = try TdtDecoderState()
        return try await manager.transcribe(samples, decoderState: &state).text
    }
}
