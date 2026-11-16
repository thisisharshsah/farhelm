import Foundation

/// Puts long messages back together, and turns away frames that are stale,
/// repeated, or meant for another end.
///
/// Repeats matter because the relay could replay what it saw: a device's
/// "send this message" sent twice would send it twice. Every message has a
/// random id; one seen in the last ten minutes is dropped, and anything
/// sealed more than five minutes from now (by this end's clock) is dropped
/// too, so nothing older can come back once its id is forgotten.
struct LinkAssembler {
    /// A whole message, and who sent it.
    struct Message {
        let header: FrameHeader
        let body: Data
        let from: String
    }

    /// What one frame came to: a whole message when it completed one, and
    /// how many parts of its message have arrived (for acks).
    struct Taken {
        var message: Message?
        var received: Int
    }

    static let maxParts = 512
    static let maxBytes = 64 * 1024 * 1024
    static let freshness: Int64 = 5 * 60 * 1000
    static let remember: TimeInterval = 10 * 60
    static let partialLife: TimeInterval = 120
    static let maxPartials = 32

    private struct Partial {
        var first: FrameHeader?
        var count: Int
        var parts: [Int: Data] = [:]
        var bytes = 0
        var touched: Date
    }

    /// This end, to drop what is addressed to another.
    let me: String
    private var partials: [String: Partial] = [:]
    private var seen: [String: Date] = [:]
    private var lastSweep = Date.distantPast

    init(me: String) {
        self.me = me
    }

    /// Takes one opened frame from `sender`; nil when it is dropped.
    mutating func take(_ frame: Frame, from sender: String, now: Date = Date()) -> Taken? {
        let header = frame.header
        sweep(now)
        guard header.v == LinkWire.version else { return nil }
        if let to = header.to, to != me { return nil }
        let (age, overflow) = LinkClock.now(now).subtractingReportingOverflow(header.ts)
        guard !overflow, age.magnitude <= UInt64(Self.freshness) else { return nil }
        guard (1...Self.maxParts).contains(header.n), (0..<header.n).contains(header.i) else { return nil }
        let id = sender + "|" + header.m
        guard seen[id] == nil else { return nil }

        if header.n == 1 {
            seen[id] = now
            return Taken(message: Message(header: header, body: frame.payload, from: sender), received: 1)
        }

        var partial = partials[id] ?? Partial(count: header.n, touched: now)
        guard partial.count == header.n, partial.parts[header.i] == nil else { return nil }
        guard partial.bytes + frame.payload.count <= Self.maxBytes else {
            partials[id] = nil
            return nil
        }
        if header.i == 0 { partial.first = header }
        partial.parts[header.i] = frame.payload
        partial.bytes += frame.payload.count
        partial.touched = now

        if partial.parts.count == partial.count, let first = partial.first {
            partials[id] = nil
            seen[id] = now
            var body = Data(capacity: partial.bytes)
            for index in 0..<partial.count {
                body.append(partial.parts[index] ?? Data())
            }
            return Taken(message: Message(header: first, body: body, from: sender), received: partial.count)
        }

        partials[id] = partial
        if partials.count > Self.maxPartials,
           let oldest = partials.min(by: { $0.value.touched < $1.value.touched })?.key {
            partials[oldest] = nil
        }
        return Taken(message: nil, received: partial.parts.count)
    }

    /// Forgets messages that will not complete and ids old enough that
    /// their frames would be refused as stale anyway.
    private mutating func sweep(_ now: Date) {
        guard now.timeIntervalSince(lastSweep) > 5 else { return }
        lastSweep = now
        partials = partials.filter { now.timeIntervalSince($0.value.touched) < Self.partialLife }
        seen = seen.filter { now.timeIntervalSince($0.value) < Self.remember }
    }
}
