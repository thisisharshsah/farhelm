import CryptoKit
import Foundation

/// One end of a pairing's link through the relay: the Mac's, or a device's.
///
/// It keeps one WebSocket open to the relay, reconnecting after a drop with
/// backoff, and speaks the protocol on it:
///
/// - A device sends requests and gets responses, shaped as over HTTP.
/// - The Mac answers them through its request handler, and sends the open
///   chat's changes to the devices that subscribe (they say so every half
///   minute, and are forgotten when they stop).
/// - A message longer than one frame goes in parts. Past `window` parts the
///   sender waits for the receiver's acks, so the relay, which skips ahead
///   for a reader that falls too far behind, never has to.
///
/// Every frame is sealed for its direction (`LinkWire`), and repeats and
/// stale frames are refused (`LinkAssembler`), so the relay can delay or
/// drop what passes through it, but not read it, change it or replay it.
public actor LinkEndpoint {
    public enum Role: Sendable, Equatable {
        case mac
        /// A device, by its lasting id on this install.
        case device(String)
    }

    public enum State: Sendable, Equatable {
        case off
        case connecting
        case connected
        case failed(String)
    }

    public let role: Role
    public let key: LinkKey
    private let me: String
    private let channel: String
    private let url: URL
    private let sealKey: SymmetricKey
    private let openKey: SymmetricKey

    /// Parts a long message may be ahead of the receiver's last ack.
    static let window = 48
    /// A receiver acks every this many parts, and at the end.
    static let ackEvery = 16
    /// The longest text the relay forwards, with room to spare.
    static let largestFrame = 300_000
    /// A subscription lapses this long after a device last renewed it.
    static let subscriptionLife: TimeInterval = 70

    private var state: State = .off
    private var lastFailure: Error?
    private var socket: RelaySocket?
    private var runner: Task<Void, Never>?
    /// Bumped by every start and stop, so a loop left over from before
    /// cannot touch what a newer one set up.
    private var generation = 0
    private var assembler: LinkAssembler
    private var stateHandler: (@Sendable (State) -> Void)?

    // A device's side.
    private var waiting: [String: CheckedContinuation<LinkResponse, Error>] = [:]
    private var streams: [UUID: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    private var heartbeat: Task<Void, Never>?

    // The Mac's side.
    private var requestHandler: (@Sendable (LinkRequest, String) async -> LinkResponse)?
    private var subscriberHandler: (@Sendable (String) async -> Void)?
    private var listeningHandler: (@Sendable (Bool) -> Void)?
    private var subscribers: [String: Date] = [:]

    // Long messages on their way out: whose acks pace them, and how far.
    private var ackedBy: [String: String] = [:]
    private var acked: [String: Int] = [:]

    /// `relay` is the relay's address (`RelayAddress.url(from:)`).
    public init(relay: URL, key: LinkKey, role: Role) {
        self.role = role
        self.key = key
        let me: String
        switch role {
        case .mac:
            me = "mac"
            sealKey = key.sealing(.macToDevice)
            openKey = key.sealing(.deviceToMac)
        case .device(let id):
            me = id
            sealKey = key.sealing(.deviceToMac)
            openKey = key.sealing(.macToDevice)
        }
        self.me = me
        channel = key.channel
        url = RelayAddress.channel(key.channel, at: relay)
        assembler = LinkAssembler(me: me)
    }

    // MARK: On and off

    public var currentState: State { state }

    /// Called with the state now and on every change.
    public func setStateHandler(_ handler: @escaping @Sendable (State) -> Void) {
        stateHandler = handler
        handler(state)
    }

    /// Connects, and stays connected until `stop`. Called again while it
    /// waits out a failure, it tries again at once.
    public func start() {
        if runner != nil {
            guard case .failed = state else { return }
            runner?.cancel()
            runner = nil
            socket?.close()
            socket = nil
        }
        // Connecting from now, so a wait that starts right after this one
        // does not find it still off.
        set(.connecting)
        generation += 1
        let mine = generation
        runner = Task { await self.run(mine) }
    }

    public func stop() {
        generation += 1
        runner?.cancel()
        runner = nil
        socket?.close()
        socket = nil
        fail(LinkError.closed)
        set(.off)
    }

    /// Returns once connected; throws why it is not, or on the deadline.
    public func waitUntilConnected(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch state {
            case .connected:
                return
            case .off:
                throw LinkError.notConnected
            case .failed:
                throw lastFailure ?? LinkError.notConnected
            case .connecting:
                break
            }
            guard Date() < deadline else { throw LinkError.timedOut }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func run(_ mine: Int) async {
        var wait: UInt64 = 1
        while generation == mine, !Task.isCancelled {
            set(.connecting)
            let socket = RelaySocket(url: url, seat: key.seat)
            self.socket = socket
            let began = Date()
            var reached = false
            do {
                try await socket.open(timeout: 15)
                guard generation == mine, !Task.isCancelled else {
                    socket.close()
                    return
                }
                reached = true
                lastFailure = nil
                set(.connected)
                try await pump(socket)
            } catch {
                if generation == mine, !Task.isCancelled, !reached {
                    lastFailure = error
                    set(.failed(Self.words(for: error)))
                }
            }
            socket.close()
            guard generation == mine, !Task.isCancelled else { return }
            if self.socket === socket { self.socket = nil }
            fail(LinkError.closed)
            if reached {
                set(.connecting)
                if Date().timeIntervalSince(began) > 60 { wait = 1 }
            }
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            wait = min(wait * 2, 30)
        }
    }

    /// Reads the socket until it ends, pinging it so a dead one is noticed
    /// (and so neither the relay nor a proxy closes it for being quiet).
    private func pump(_ socket: RelaySocket) async throws {
        let keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if Task.isCancelled { return }
                do {
                    try await socket.ping(timeout: 15)
                } catch {
                    socket.close()
                    return
                }
                await self?.sweepSubscribers()
            }
        }
        defer { keepAlive.cancel() }
        while true {
            let text = try await socket.receive()
            await receive(text)
        }
    }

    private func set(_ new: State) {
        guard state != new else { return }
        state = new
        stateHandler?(new)
    }

    /// Everything waiting on this connection learns it is gone.
    private func fail(_ error: Error) {
        let pending = waiting
        waiting = [:]
        for continuation in pending.values { continuation.resume(throwing: error) }
        let open = streams
        streams = [:]
        for stream in open.values { stream.finish(throwing: error) }
        heartbeat?.cancel()
        heartbeat = nil
        ackedBy = [:]
        acked = [:]
        if !subscribers.isEmpty {
            subscribers = [:]
            listeningHandler?(false)
        }
    }

    private static func words(for error: Error) -> String {
        if let described = (error as? LocalizedError)?.errorDescription { return described }
        return error.localizedDescription
    }

    // MARK: A device's side

    /// Asks the Mac, and waits for its answer.
    public func request(_ request: LinkRequest, timeout: TimeInterval = 20) async throws -> LinkResponse {
        guard case .device = role, state == .connected, socket != nil else { throw LinkError.notConnected }
        let id = UUID().uuidString
        let deadline = Date().addingTimeInterval(timeout)
        return try await withCheckedThrowingContinuation { continuation in
            // Waiting before sending: the answer can come back before the
            // last part has finished going out.
            waiting[id] = continuation
            Task { await self.deliver(request, id: id, deadline: deadline) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 1) * 1_000_000_000))
                await self.expire(id)
            }
        }
    }

    private func deliver(_ request: LinkRequest, id: String, deadline: Date) async {
        do {
            try await transmit(.request, id: id, to: "mac", body: request.body, ackedBy: "mac", deadline: deadline) { header in
                header.method = request.method
                header.path = request.path
                header.query = request.query.isEmpty ? nil : request.query
            }
        } catch {
            waiting.removeValue(forKey: id)?.resume(throwing: error)
        }
    }

    private func expire(_ id: String) {
        waiting.removeValue(forKey: id)?.resume(throwing: LinkError.timedOut)
    }

    /// The Mac's events (the open chat as it changes), from a full snapshot
    /// on. Ends, with an error, when the connection does.
    public func events() -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        guard case .device = role, state == .connected else {
            continuation.finish(throwing: LinkError.notConnected)
            return stream
        }
        let id = UUID()
        streams[id] = continuation
        continuation.onTermination = { _ in
            Task { await self.endStream(id) }
        }
        if heartbeat == nil {
            heartbeat = Task {
                while !Task.isCancelled {
                    await self.subscribe(true)
                    try? await Task.sleep(nanoseconds: 25_000_000_000)
                }
            }
        }
        return stream
    }

    private func endStream(_ id: UUID) async {
        guard streams.removeValue(forKey: id) != nil, streams.isEmpty else { return }
        heartbeat?.cancel()
        heartbeat = nil
        await subscribe(false)
    }

    private func subscribe(_ on: Bool) async {
        guard state == .connected else { return }
        try? await transmit(.subscribe, id: UUID().uuidString, to: "mac", body: Data(), ackedBy: nil,
                            deadline: Date().addingTimeInterval(10)) { header in
            header.on = on
        }
    }

    // MARK: The Mac's side

    /// Answers a device's request; the second argument is the device's id.
    public func setRequestHandler(_ handler: @escaping @Sendable (LinkRequest, String) async -> LinkResponse) {
        requestHandler = handler
    }

    /// Called when a device subscribes anew, to send it a full snapshot.
    public func setSubscriberHandler(_ handler: @escaping @Sendable (String) async -> Void) {
        subscriberHandler = handler
    }

    /// Called when the first device subscribes and when the last one goes.
    public func setListeningHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
        listeningHandler = handler
    }

    /// Sends an event to every subscribed device, or to one.
    public func publish(_ event: Data, to device: String? = nil) async {
        guard case .mac = role, state == .connected, device != nil || !subscribers.isEmpty else { return }
        try? await transmit(.event, id: UUID().uuidString, to: device, body: event, ackedBy: nil,
                            deadline: Date().addingTimeInterval(30))
    }

    private func answer(_ response: LinkResponse, to device: String, request id: String) async {
        try? await transmit(.response, id: UUID().uuidString, to: device, body: response.body, ackedBy: device,
                            deadline: Date().addingTimeInterval(120)) { header in
            header.re = id
            header.status = response.status
            header.type = response.type
        }
    }

    private func subscription(from device: String, on: Bool) {
        let wasListening = !subscribers.isEmpty
        if on {
            let isNew = subscribers[device].map { Date().timeIntervalSince($0) > Self.subscriptionLife } ?? true
            subscribers[device] = Date()
            if isNew, let handler = subscriberHandler {
                Task { await handler(device) }
            }
        } else {
            subscribers[device] = nil
        }
        if wasListening != !subscribers.isEmpty { listeningHandler?(!subscribers.isEmpty) }
    }

    private func sweepSubscribers() {
        guard case .mac = role, !subscribers.isEmpty else { return }
        let now = Date()
        subscribers = subscribers.filter { now.timeIntervalSince($0.value) <= Self.subscriptionLife }
        if subscribers.isEmpty { listeningHandler?(false) }
    }

    // MARK: Frames in and out

    private func receive(_ text: String) async {
        guard text.utf8.count <= Self.largestFrame,
              let envelope = try? LinkWire.envelope(text),
              envelope.channel == channel, envelope.sender != me,
              let plaintext = try? LinkWire.open(envelope, with: openKey),
              let frame = try? LinkWire.unframe(plaintext),
              let taken = assembler.take(frame, from: envelope.sender) else { return }
        let header = frame.header
        let paced = header.k == .request || header.k == .response
        if paced, header.n > 1, taken.received % Self.ackEvery == 0 || taken.received == header.n {
            await sendAck(of: header.m, got: taken.received, to: envelope.sender)
        }
        if let message = taken.message { handle(message) }
    }

    private func handle(_ message: LinkAssembler.Message) {
        let header = message.header
        switch (header.k, role) {
        case (.ack, _):
            if let of = header.of, let got = header.got, ackedBy[of] == message.from {
                acked[of] = max(acked[of] ?? 0, got)
            }
        case (.request, .mac):
            guard let handler = requestHandler else { return }
            let request = LinkRequest(method: header.method ?? "GET", path: header.path ?? "/",
                                      query: header.query ?? [:], body: message.body)
            let from = message.from
            let id = header.m
            Task {
                let response = await handler(request, from)
                await self.answer(response, to: from, request: id)
            }
        case (.subscribe, .mac):
            subscription(from: message.from, on: header.on ?? true)
        case (.response, .device):
            if let re = header.re, let waiter = waiting.removeValue(forKey: re) {
                waiter.resume(returning: LinkResponse(status: header.status ?? 200, type: header.type ?? "",
                                                      body: message.body))
            }
        case (.event, .device):
            for stream in streams.values { stream.yield(message.body) }
        default:
            break
        }
    }

    private func sendAck(of message: String, got: Int, to peer: String) async {
        try? await transmit(.ack, id: UUID().uuidString, to: peer, body: Data(), ackedBy: nil,
                            deadline: Date().addingTimeInterval(10)) { header in
            header.of = message
            header.got = got
        }
    }

    /// Sends one message in as many frames as it takes. With `acker`, a
    /// message longer than `window` parts waits for that end's acks.
    private func transmit(_ kind: LinkKind, id: String, to peer: String?, body: Data, ackedBy acker: String?,
                          deadline: Date, fill: (inout FrameHeader) -> Void = { _ in }) async throws {
        guard let socket, state == .connected else { throw LinkError.notConnected }
        let pieces = LinkWire.parts(of: body)
        let count = pieces.count
        guard count <= LinkAssembler.maxParts, acker != nil || count <= Self.window * 2 else {
            throw LinkError.tooLarge
        }
        let paced = acker != nil && count > Self.window
        if paced {
            ackedBy[id] = acker
            acked[id] = 0
        }
        defer {
            if paced {
                ackedBy[id] = nil
                acked[id] = nil
            }
        }
        var first = FrameHeader(message: id, part: 0, parts: count, kind: kind)
        first.to = peer
        fill(&first)
        for (index, piece) in pieces.enumerated() {
            if paced {
                while index - (acked[id] ?? 0) >= Self.window {
                    guard Date() < deadline else { throw LinkError.timedOut }
                    guard self.socket === socket else { throw LinkError.closed }
                    try await Task.sleep(nanoseconds: 40_000_000)
                }
            }
            var header = first
            if index > 0 {
                header = FrameHeader(message: id, part: index, parts: count, kind: kind)
                header.to = peer
            }
            header.ts = LinkClock.now()
            let plaintext = try LinkWire.frame(header, piece)
            let sealed = try LinkWire.seal(plaintext, with: sealKey, channel: channel, sender: me)
            try await socket.send(LinkWire.text(sealed))
            guard Date() < deadline else { throw LinkError.timedOut }
        }
    }
}
