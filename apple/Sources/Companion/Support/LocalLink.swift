import CompanionLink
import Foundation
import Network

/// The apps' sealed way in on this Mac's own network.
///
/// Away from the network the iPhone, iPad and Watch apps reach Companion
/// through the relay, sealed end to end (`RemoteRelay`). On the network they
/// used plain HTTP with the pairing code in every request, which anyone who
/// could see the network's traffic could read (security review, H1). This
/// serves the relay's own protocol here: a small WebSocket hub that the apps
/// and this Mac's own `LinkEndpoint` both join, so what crosses the local
/// network is sealed with the pairing's key just as through the relay. The
/// pages for a browser and the glasses keep the plain way for now.
///
/// The hub passes frames between whoever holds the pairing's seat and reads
/// none of them: each is sealed for its direction, and repeats are refused
/// at either end (`LinkAssembler`), as on the relay.
@MainActor
final class LocalLink {
    static let shared = LocalLink()

    /// The hub's port, or 0 while it is not up. Apps learn it from `/link`.
    private(set) var port: UInt16 = 0
    /// Some app is following the open chat this way.
    private(set) var listening = false

    private let preferredPort: UInt16 = 7346
    private var listener: NWListener?
    private var members: [ObjectIdentifier: NWConnection] = [:]
    private var endpoint: LinkEndpoint?
    /// Events go out one at a time, in the order they were made.
    private var outbox: AsyncStream<(Data, String?)>.Continuation?
    private var sender: Task<Void, Never>?

    /// The most parties at once: this Mac, and the apps on its network.
    private static let memberLimit = 16
    /// The longest frame passed on; the link's own stay under 300 KB.
    private static let frameLimit = 1 << 20

    private init() {}

    // MARK: On and off

    func start() {
        open(on: NWEndpoint.Port(rawValue: preferredPort))
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
        for member in members.values { member.cancel() }
        members = [:]
        listener?.cancel()
        listener = nil
        port = 0
    }

    /// After New code: the old seat no longer gets in.
    func restart() {
        stop()
        start()
    }

    private func open(on chosen: NWEndpoint.Port?) {
        guard listener == nil else { return }
        let key = RemoteRelay.shared.key
        let preferred = chosen != nil
        do {
            let listener = try NWListener(using: Self.parameters(seat: key.seat), on: chosen ?? .any)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state, key: key, preferred: preferred) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.admit(connection) }
            }
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            // The preferred port is taken: any will do, since apps ask.
            if preferred { open(on: nil) }
        }
    }

    /// TCP with WebSocket on top, letting in only a party that presents this
    /// pairing's seat, in the header the relay checks (`LinkWire.seatHeader`).
    private static func parameters(seat: String) -> NWParameters {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = frameLimit
        options.setClientRequestHandler(DispatchQueue.global(qos: .userInitiated)) { _, headers in
            let given = headers.first { $0.name.caseInsensitiveCompare("X-Relay-Seat") == .orderedSame }?.value
            return NWProtocolWebSocket.Response(status: sameSeat(given ?? "", seat) ? .accept : .reject,
                                                subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        return parameters
    }

    private func listenerChanged(_ state: NWListener.State, key: LinkKey, preferred: Bool) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue ?? 0
            startEndpoint(key: key)
        case .failed:
            listener?.cancel()
            listener = nil
            port = 0
            if preferred { open(on: nil) }
        default:
            break
        }
    }

    // MARK: The hub

    private func admit(_ connection: NWConnection) {
        // This Mac and its own network only, and a bounded number at once.
        guard RemoteServer.isNearby(connection.endpoint), members.count < Self.memberLimit else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        members[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.members[id] = nil }
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receive(on: connection, id: id)
    }

    private func receive(on connection: NWConnection, id: ObjectIdentifier) {
        connection.receiveMessage { [weak self] content, context, _, error in
            Task { @MainActor in
                guard let self, self.members[id] != nil else { return }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                if error != nil || metadata?.opcode == .close || (content == nil && context?.isFinal == true) {
                    connection.cancel()
                    self.members[id] = nil
                    return
                }
                if let content, metadata?.opcode == .text {
                    self.pass(content, from: id)
                }
                self.receive(on: connection, id: id)
            }
        }
    }

    /// A frame from one party to every other. The hub reads none of them.
    private func pass(_ frame: Data, from origin: ObjectIdentifier) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        for (id, member) in members where id != origin {
            member.send(content: frame, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
        }
    }

    // MARK: This Mac's own end

    /// This Mac joins its own hub as the relay's Mac end does the relay, and
    /// answers through the same code (`RemoteServer.answerRelayed`).
    private func startEndpoint(key: LinkKey) {
        guard endpoint == nil, port != 0, let url = URL(string: "ws://127.0.0.1:\(port)") else { return }
        let endpoint = LinkEndpoint(relay: url, key: key, role: .mac)
        self.endpoint = endpoint
        let (events, outbox) = AsyncStream<(Data, String?)>.makeStream()
        self.outbox = outbox
        sender = Task {
            for await (event, device) in events {
                await endpoint.publish(event, to: device)
            }
        }
        Task {
            await endpoint.setListeningHandler { listening in
                Task { @MainActor in LocalLink.shared.listeningChanged(listening, from: endpoint) }
            }
            await endpoint.setSubscriberHandler { device in
                await MainActor.run { LocalLink.shared.sendSnapshot(to: device, from: endpoint) }
            }
            await endpoint.setRequestHandler { request, _ in
                let reply = await RemoteServer.shared.answerRelayed(method: request.method, path: request.path,
                                                                    query: request.query, body: request.body)
                return LinkResponse(status: reply.status, type: reply.type, body: reply.body)
            }
            await endpoint.start()
        }
    }

    /// An event (what the local feed streams) for every app following here.
    func publish(_ event: String) {
        guard listening else { return }
        outbox?.yield((Data(event.utf8), nil))
    }

    /// An app just subscribed: the whole chat for it, then what changes.
    private func sendSnapshot(to device: String, from source: LinkEndpoint) {
        guard source === endpoint else { return }
        outbox?.yield((Data(RemoteServer.shared.snapshotEvent().utf8), device))
    }

    private func listeningChanged(_ value: Bool, from source: LinkEndpoint) {
        guard source === endpoint else { return }
        listening = value
    }
}

/// Two seats compared in the same time whatever they hold.
private func sameSeat(_ given: String, _ expected: String) -> Bool {
    let given = Array(given.utf8), expected = Array(expected.utf8)
    guard !expected.isEmpty, given.count == expected.count else { return false }
    return zip(given, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
}
