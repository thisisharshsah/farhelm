import CompanionLink
import Foundation

/// Reaching this Mac away from its network: Companion keeps a connection
/// out to a relay, and the iPhone, iPad and Watch apps meet it there when
/// they cannot reach it directly.
///
/// Nothing on this Mac listens to the internet: the connection goes out.
/// Everything on it is sealed with the pairing's key, which only travels in
/// the pairing QR code, so the relay (and Cloudflare in front of it) passes
/// along what it cannot read, and cannot change or replay it either. A
/// request that comes this way is answered by the same code as on the local
/// network (`RemoteServer.answerRelayed`), so the relay is never a way in
/// with rules of its own: approving what the agent does stays on this Mac.
@MainActor
final class RemoteRelay: ObservableObject {
    static let shared = RemoteRelay()

    enum Status: Equatable {
        case off
        /// On, but no relay address is set.
        case noAddress
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    /// Some device is following the open chat through the relay.
    @Published private(set) var listening = false

    private var endpoint: LinkEndpoint?
    /// Events go out one at a time, in the order they were made.
    private var outbox: AsyncStream<(Data, String?)>.Continuation?
    private var sender: Task<Void, Never>?

    private init() {}

    // MARK: Settings

    /// Whether the apps may reach this Mac through the relay. On unless
    /// turned off; it only runs while the app connection is on.
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "remoteRelayEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "remoteRelayEnabled")
            objectWillChange.send()
            restart()
        }
    }

    /// The relay's address: as set in Settings, else the one this build
    /// names (Info.plist's CompanionRelayURL).
    var address: String {
        get { UserDefaults.standard.string(forKey: "remoteRelayAddress") ?? Self.builtInAddress }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == Self.builtInAddress {
                UserDefaults.standard.removeObject(forKey: "remoteRelayAddress")
            } else {
                UserDefaults.standard.set(trimmed, forKey: "remoteRelayAddress")
            }
            objectWillChange.send()
            restart()
        }
    }

    static var builtInAddress: String {
        (Bundle.main.object(forInfoDictionaryKey: "CompanionRelayURL") as? String) ?? ""
    }

    /// The relay as a WebSocket address, when one is set and well formed.
    var relayURL: URL? { RelayAddress.url(from: address) }

    /// What the pairing link carries for the relay, while it is on.
    var pairing: (relay: String, key: String)? {
        guard enabled, let url = relayURL else { return nil }
        return (url.absoluteString, key.text)
    }

    /// What `/info` tells a paired app: the relay now, or "" when it is off.
    var advertised: String { pairing?.relay ?? "" }

    // MARK: The key

    private static let keyAccount = "remoteLinkKey"

    /// The pairing's key, made the first time it is needed and kept in the
    /// Keychain beside the pairing code.
    var key: LinkKey {
        if let text = Keychain.read(Self.keyAccount), let kept = LinkKey(text: text) { return kept }
        let made = LinkKey()
        Keychain.write(made.text, account: Self.keyAccount)
        return made
    }

    /// A new key, made with a new pairing code: every app paired before has
    /// to pair again, and the old channel on the relay goes quiet.
    func newKey() {
        Keychain.write(LinkKey().text, account: Self.keyAccount)
        objectWillChange.send()
        restart()
    }

    // MARK: On and off

    /// Connects when the app connection and the relay are both on.
    func start() {
        guard endpoint == nil else { return }
        guard enabled, RemoteServer.shared.enabled else {
            status = .off
            return
        }
        guard let url = relayURL else {
            status = .noAddress
            return
        }
        let endpoint = LinkEndpoint(relay: url, key: key, role: .mac)
        self.endpoint = endpoint
        status = .connecting
        let (events, outbox) = AsyncStream<(Data, String?)>.makeStream()
        self.outbox = outbox
        sender = Task {
            for await (event, device) in events {
                await endpoint.publish(event, to: device)
            }
        }
        Task {
            await endpoint.setStateHandler { state in
                Task { @MainActor in RemoteRelay.shared.update(state, from: endpoint) }
            }
            await endpoint.setListeningHandler { listening in
                Task { @MainActor in RemoteRelay.shared.listeningChanged(listening, from: endpoint) }
            }
            await endpoint.setSubscriberHandler { device in
                await MainActor.run { RemoteRelay.shared.sendSnapshot(to: device, from: endpoint) }
            }
            await endpoint.setRequestHandler { request, _ in
                let reply = await RemoteServer.shared.answerRelayed(method: request.method, path: request.path,
                                                                    query: request.query, body: request.body)
                return LinkResponse(status: reply.status, type: reply.type, body: reply.body)
            }
            await endpoint.start()
        }
    }

    func stop() {
        outbox?.finish()
        outbox = nil
        sender?.cancel()
        sender = nil
        if let endpoint {
            Task { await endpoint.stop() }
        }
        endpoint = nil
        listening = false
        status = .off
    }

    func restart() {
        stop()
        start()
    }

    // MARK: The open chat, for devices following it

    /// An event (what the local feed streams) for every device following
    /// through the relay.
    func publish(_ event: String) {
        guard listening else { return }
        outbox?.yield((Data(event.utf8), nil))
    }

    /// A device just subscribed: the whole chat for it, then what changes.
    private func sendSnapshot(to device: String, from source: LinkEndpoint) {
        guard source === endpoint else { return }
        outbox?.yield((Data(RemoteServer.shared.snapshotEvent().utf8), device))
    }

    private func update(_ state: LinkEndpoint.State, from source: LinkEndpoint) {
        guard source === endpoint else { return }
        switch state {
        // Only `stop` turns it off, and it says so itself.
        case .off: break
        case .connecting: status = .connecting
        case .connected: status = .connected
        case .failed(let why): status = .failed(why)
        }
    }

    private func listeningChanged(_ value: Bool, from source: LinkEndpoint) {
        guard source === endpoint else { return }
        listening = value
    }
}
