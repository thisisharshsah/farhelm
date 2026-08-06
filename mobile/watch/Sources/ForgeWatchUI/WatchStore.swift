import Foundation
import ForgeCrypto
import ForgeWatchKit
import SwiftUI

#if canImport(WatchConnectivity)
    import WatchConnectivity
#endif

/// Everything the watch screens read, in one observable place.
///
/// The connection lives here rather than in a view because a watch app is
/// suspended and resumed constantly; a socket owned by a view would be torn down
/// and rebuilt on every glance.
@MainActor
@Observable
public final class WatchStore {
    public enum Phase: Equatable {
        case loading
        case unpaired
        case pairing
        case ready
    }

    public private(set) var phase: Phase = .loading
    public private(set) var fleet: FleetView?
    public private(set) var connection: RelayClient.ConnectionState = .connecting
    /// The last refusal the runner sent back. The D3 case lands here.
    public private(set) var refusal: String?
    public private(set) var pairingError: String?
    /// Approvals this watch has acted on, so a tapped card stops offering itself
    /// again before the next snapshot lands.
    public private(set) var acted: Set<String> = []

    private let store: PairingStore
    private var client: RelayClient?
    private var phone: PhoneLink?
    private var pendingIdentity: Identity?

    public init(store: PairingStore = PairingStore()) {
        self.store = store
    }

    public func start() {
        guard phase == .loading else { return }
        if let pairing = store.load() {
            connect(pairing)
        } else {
            phase = .unpaired
        }
    }

    // ---------------------------------------------------------------- relay

    private func connect(_ pairing: Pairing) {
        guard let client = try? RelayClient(pairing: pairing) else {
            phase = .unpaired
            pairingError = "The stored key is unreadable. Pair again."
            store.forget()
            return
        }

        self.client = client
        phase = .ready

        Task {
            await client.onStateChange { [weak self] state in
                Task { @MainActor in self?.connection = state }
            }
            await client.onEvent { [weak self] event in
                Task { @MainActor in self?.apply(event) }
            }
            await client.connect()
            await refresh()
        }
    }

    private func apply(_ event: ServerEvent) {
        switch event {
        case .commandError(let message):
            // Without this the wrist would show a tap that did nothing at all —
            // the worst failure a remote control surface can have.
            refusal = message
            acted.removeAll()
            Task { await refresh() }
        case .unknown:
            break
        default:
            Task { await refresh() }
        }
    }

    public func refresh() async {
        guard let client else { return }
        if let next = try? await client.fleet() {
            fleet = next
            acted = acted.intersection(Set(next.pendingApprovals.map(\.id)))
        }
    }

    public func decide(_ approval: ApprovalView, _ decision: Decision) async {
        guard let client else { return }
        refusal = nil
        acted.insert(approval.id)
        do {
            try await client.decide(approvalID: approval.id, decision: decision)
        } catch {
            acted.remove(approval.id)
            refusal = error.localizedDescription
        }
    }

    public func dismissRefusal() { refusal = nil }

    // -------------------------------------------------------------- pairing

    /// Ask the phone to claim a pairing code for this watch.
    ///
    /// The keypair is generated here; only its public half crosses to the phone.
    public func beginPairing() {
        pairingError = nil
        phase = .pairing

        let (message, identity) = WatchPairing.request()
        pendingIdentity = identity

        let link = phone ?? PhoneLink()
        phone = link
        link.onReply = { [weak self] reply in
            Task { @MainActor in self?.finishPairing(reply) }
        }
        link.send(message) { [weak self] error in
            Task { @MainActor in
                self?.phase = .unpaired
                self?.pairingError = error
            }
        }
    }

    private func finishPairing(_ reply: [String: Any]) {
        guard let identity = pendingIdentity else { return }
        do {
            let pairing = try WatchPairing.complete(reply: reply, identity: identity)
            guard store.save(pairing) else {
                phase = .unpaired
                pairingError = "Could not save the key to the keychain."
                return
            }
            pendingIdentity = nil
            connect(pairing)
        } catch {
            phase = .unpaired
            pairingError = error.localizedDescription
        }
    }

    public func unpair() {
        store.forget()
        Task { [client] in await client?.close() }
        client = nil
        fleet = nil
        phase = .unpaired
    }
}

/// The link to the phone, used for one thing only: pairing.
///
/// Everything else the watch does goes straight to the relay — see
/// `RelayClient` for why routing decisions through the phone would break the
/// destructive-command rule.
@MainActor
final class PhoneLink: NSObject {
    var onReply: (([String: Any]) -> Void)?

    #if canImport(WatchConnectivity)
        private let session: WCSession? = WCSession.isSupported() ? .default : nil

        override init() {
            super.init()
            session?.delegate = self
            session?.activate()
        }

        func send(_ message: [String: Any], onError: @escaping (String) -> Void) {
            guard let session, session.isReachable else {
                onError("Open RelayForge on your iPhone, then try again.")
                return
            }
            session.sendMessage(
                message,
                replyHandler: { [weak self] reply in
                    Task { @MainActor in self?.onReply?(reply) }
                },
                errorHandler: { error in
                    Task { @MainActor in onError(error.localizedDescription) }
                }
            )
        }
    #else
        // macOS has no WatchConnectivity. The package still builds there so the
        // rest of this code can be typechecked and tested without a device.
        func send(_ message: [String: Any], onError: @escaping (String) -> Void) {
            onError("There is no phone to talk to on this platform.")
        }
    #endif
}

#if canImport(WatchConnectivity)
    extension PhoneLink: WCSessionDelegate {
        nonisolated func session(
            _ session: WCSession,
            activationDidCompleteWith state: WCSessionActivationState,
            error: Error?
        ) {}

        nonisolated func session(
            _ session: WCSession,
            didReceiveMessage message: [String: Any]
        ) {
            Task { @MainActor [weak self] in self?.onReply?(message) }
        }
    }
#endif
