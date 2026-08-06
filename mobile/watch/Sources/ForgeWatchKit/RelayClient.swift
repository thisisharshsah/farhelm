import Foundation
import ForgeCrypto

/// The watch's own connection to the relay.
///
/// Not a proxy through the phone. The runner records `decided_via` from the
/// registered kind of the device whose key sealed the envelope, and the D3 rule —
/// destructive commands cannot be cleared from a wrist — is enforced against
/// that. A watch that spoke through the phone would arrive as `phone` and the
/// rule would quietly stop applying. See `mobile/src/watch/bridge.ts`.
///
/// ## Snapshots
///
/// The relay is fan-out with no request/response, so a snapshot request is
/// answered by another envelope arriving. Replies are matched to waiting calls
/// by shape — the same approach the TypeScript client takes, for the same
/// reason: giving the relay correlation state would give it metadata it exists
/// not to have.
public actor RelayClient {
    public enum ConnectionState: Sendable, Equatable {
        case connecting, open, closed
    }

    private let pairing: Pairing
    private let identity: Identity
    private let session: URLSession

    private var task: URLSessionWebSocketTask?
    private var closedDeliberately = false
    private var backoff: Duration = .seconds(1)

    /// A snapshot request waiting for its answer.
    private var pendingFleet: [CheckedContinuation<FleetView, Error>] = []

    private var eventHandler: (@Sendable (ServerEvent) -> Void)?
    private var stateHandler: (@Sendable (ConnectionState) -> Void)?

    private static let maxBackoff: Duration = .seconds(30)
    private static let requestTimeout: Duration = .seconds(10)

    public init(pairing: Pairing, session: URLSession = .shared) throws {
        self.pairing = pairing
        self.identity = try Identity.fromSecret(pairing.secret)
        self.session = session
    }

    public func onEvent(_ handler: @escaping @Sendable (ServerEvent) -> Void) {
        eventHandler = handler
    }

    public func onStateChange(_ handler: @escaping @Sendable (ConnectionState) -> Void) {
        stateHandler = handler
    }

    // ------------------------------------------------------------ lifecycle

    public func connect() {
        guard !closedDeliberately else { return }
        guard let url = URL(string: "\(pairing.relayURL)/v1/channel/\(pairing.channel)") else {
            stateHandler?(.closed)
            return
        }

        stateHandler?(.connecting)
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        stateHandler?(.open)
        backoff = .seconds(1)

        Task { await receiveLoop(task) }
    }

    public func close() {
        closedDeliberately = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        // Anything still waiting will never be answered; say so rather than
        // leaving a spinner up forever.
        failPending(RelayError.notConnected)
        stateHandler?(.closed)
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !closedDeliberately {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handle(text)
                case .data(let data):
                    handle(String(decoding: data, as: UTF8.self))
                @unknown default:
                    break
                }
            } catch {
                guard !closedDeliberately else { return }
                stateHandler?(.closed)
                failPending(RelayError.notConnected)
                await reconnect()
                return
            }
        }
    }

    private func reconnect() async {
        let delay = backoff
        backoff = min(backoff * 2, Self.maxBackoff)
        try? await Task.sleep(for: delay)
        connect()
    }

    // -------------------------------------------------------------- receive

    private func handle(_ raw: String) {
        guard
            let data = raw.data(using: .utf8),
            let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return }

        // Envelopes for *other* paired devices ride the same channel and simply
        // do not open. That is the isolation working, not an error.
        guard
            let plaintext = try? identity.open(
                senderPublicKey: pairing.runnerPublicKey, envelope: envelope)
        else { return }

        let payload = Data(plaintext)

        // A waiting snapshot claims it first; anything else is a live event.
        if !pendingFleet.isEmpty,
            let fleet = try? JSONDecoder().decode(FleetView.self, from: payload)
        {
            pendingFleet.removeFirst().resume(returning: fleet)
            return
        }

        if let event = try? JSONDecoder().decode(ServerEvent.self, from: payload) {
            eventHandler?(event)
        }
    }

    private func failPending(_ error: Error) {
        let waiting = pendingFleet
        pendingFleet = []
        for continuation in waiting { continuation.resume(throwing: error) }
    }

    // ----------------------------------------------------------------- send

    public enum RelayError: Error, LocalizedError, Equatable {
        case notConnected
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected"
            case .timedOut: return "The runner did not answer"
            }
        }
    }

    private func send(_ command: Command) async throws {
        guard let task else { throw RelayError.notConnected }
        let envelope = try identity.sealJSON(
            channel: pairing.channel,
            senderID: pairing.deviceID,
            recipientPublicKey: pairing.runnerPublicKey,
            value: command
        )
        let data = try JSONEncoder().encode(envelope)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    /// Ask for the fleet and wait for the answer.
    public func fleet() async throws -> FleetView {
        try await send(.snapshot)

        return try await withThrowingTaskGroup(of: FleetView.self) { group in
            group.addTask { [self] in
                try await withCheckedThrowingContinuation { continuation in
                    Task { await self.enqueue(continuation) }
                }
            }
            group.addTask {
                try await Task.sleep(for: Self.requestTimeout)
                throw RelayError.timedOut
            }

            // Whichever finishes first wins; the loser is cancelled.
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func enqueue(_ continuation: CheckedContinuation<FleetView, Error>) {
        pendingFleet.append(continuation)
    }

    /// Approve or deny.
    ///
    /// Fire-and-forget: the relay has no acknowledgement, and the change arrives
    /// as the event it produced. A *refusal* does come back — as a
    /// `command_error` event, which is why the D3 case shows a reason on the
    /// wrist instead of a tap that appears to do nothing.
    public func decide(approvalID: String, decision: Decision) async throws {
        try await send(.decide(approvalID: approvalID, decision: decision))
    }

    public func instruct(sessionID: String, text: String) async throws {
        try await send(.instruct(sessionID: sessionID, text: text))
    }
}
