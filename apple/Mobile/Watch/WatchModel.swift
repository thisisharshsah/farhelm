import CompanionKit
import Foundation
import Observation
import WatchConnectivity

/// The Watch's view of the chat open on the Mac, asked of the iPhone every
/// few seconds while the app is on screen.
@MainActor
@Observable
final class WatchModel: NSObject, WCSessionDelegate {
    private(set) var summary: WatchRelay.Summary?
    private(set) var problem: String?
    private(set) var macs: [String] = []
    private(set) var sending = false
    private var polling: Task<Void, Never>?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Asks for the state now and every few seconds (faster while busy).
    func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.ask(.state)
                let busy = self?.summary?.busy ?? false
                try? await Task.sleep(nanoseconds: busy ? 2_000_000_000 : 6_000_000_000)
            }
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    func say(_ text: String) async {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        await ask(.say, text: words)
    }

    func stop() async { await ask(.stop) }

    private func ask(_ ask: WatchRelay.Ask, text: String? = nil) async {
        let session = WCSession.default
        guard session.activationState == .activated else {
            problem = "Starting…"
            return
        }
        guard session.isReachable else {
            problem = "Open Companion on your iPhone, or bring it closer."
            return
        }
        var message: [String: Any] = [WatchRelay.Key.ask: ask.rawValue]
        if let text { message[WatchRelay.Key.text] = text }
        if ask != .state { sending = true }
        defer { sending = false }
        let reply: [String: Any]? = await withCheckedContinuation { done in
            session.sendMessage(message, replyHandler: { reply in
                nonisolated(unsafe) let reply = reply
                done.resume(returning: reply)
            }, errorHandler: { _ in
                done.resume(returning: nil)
            })
        }
        guard let reply else {
            problem = "Your iPhone did not answer."
            return
        }
        if let error = reply[WatchRelay.Key.error] as? String {
            problem = error
        } else if let data = reply[WatchRelay.Key.summary] as? Data,
                  let summary = try? JSONDecoder().decode(WatchRelay.Summary.self, from: data) {
            self.summary = summary
            problem = nil
        }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let names = session.receivedApplicationContext[WatchRelay.Key.macs] as? [String] ?? []
        Task { @MainActor in
            self.macs = names
            await self.ask(.state)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let names = context[WatchRelay.Key.macs] as? [String] ?? []
        Task { @MainActor in self.macs = names }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in await self.ask(.state) }
    }
}
