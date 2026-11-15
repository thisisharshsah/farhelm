import CompanionKit
import Foundation
import WatchConnectivity

/// The phone's side of the Watch app: it hands the Watch the paired Macs,
/// and carries the Watch's requests to the Mac (the phone wakes for them
/// even in the background).
@MainActor
final class WatchBridge: NSObject, WCSessionDelegate {
    private let store: MacStore
    private let session: LiveSession

    init(store: MacStore, session: LiveSession) {
        self.store = store
        self.session = session
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// The Watch keeps the Mac's name to show; it reaches it through here.
    func sendMacs() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return }
        let names = store.macs.map(\.name)
        try? WCSession.default.updateApplicationContext([WatchRelay.Key.macs: names])
    }

    /// A request from the Watch, answered with the chat's summary.
    private func handle(_ message: [String: Any]) async -> [String: Any] {
        guard let raw = message[WatchRelay.Key.ask] as? String, let ask = WatchRelay.Ask(rawValue: raw) else {
            return [WatchRelay.Key.error: "Unknown request."]
        }
        do {
            let client = try await reachable()
            switch ask {
            case .state:
                break
            case .say:
                if let text = message[WatchRelay.Key.text] as? String { try await client.say(text) }
            case .stop:
                try await client.stop()
            }
            let state = try await client.state()
            let summary = WatchRelay.Summary(meta: state.meta, turns: state.changed)
            let data = try JSONEncoder().encode(summary)
            return [WatchRelay.Key.summary: data]
        } catch {
            return [WatchRelay.Key.error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription]
        }
    }

    /// The live client when the app is open; otherwise one made now.
    private func reachable() async throws -> CompanionClient {
        if let client = session.client { return client }
        guard let mac = store.selected else { throw CompanionError.unpaired }
        let (client, info) = try await CompanionClient.connect(to: mac)
        store.update(mac.id, info: info, workingHost: client.host)
        return client
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.sendMacs() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        // The dictionary is plain property-list values, safe to carry over.
        nonisolated(unsafe) let message = message
        Task { @MainActor in
            let reply = await self.handle(message)
            replyHandler(reply)
        }
    }
}
