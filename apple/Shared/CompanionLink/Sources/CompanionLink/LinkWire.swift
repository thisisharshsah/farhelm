import CryptoKit
import Foundation

/// A request a device makes of the Mac, shaped as it would be over HTTP, so
/// the Mac answers it with the very code that answers on its own network.
public struct LinkRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
    }
}

/// The Mac's answer to one request.
public struct LinkResponse: Sendable {
    public var status: Int
    public var type: String
    public var body: Data

    public init(status: Int, type: String, body: Data) {
        self.status = status
        self.type = type
        self.body = body
    }
}

/// What went wrong on the link, in words for the screen.
public enum LinkError: LocalizedError, Sendable, Equatable {
    case notConnected
    case timedOut
    case closed
    case tooLarge
    /// Something came through that is not a frame of this protocol.
    case malformed
    /// The relay answered the connection with this HTTP status.
    case refused(Int)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the relay."
        case .timedOut: return "No answer through the relay in time."
        case .closed: return "The connection through the relay closed."
        case .tooLarge: return "That is too large to send through the relay."
        case .malformed: return "Something unreadable came through the relay."
        case .refused(401), .refused(403):
            return "The relay did not let this pairing in. Check that the relay is up to date, then pair again."
        case .refused(404): return "There is no relay at that address."
        case .refused(let status): return "The relay refused the connection (\(status))."
        }
    }
}

/// What a frame is part of.
enum LinkKind: String, Codable, Sendable {
    /// A device asks the Mac something.
    case request = "req"
    /// The Mac's answer to one request.
    case response = "res"
    /// The open chat as it changes: what the local feed streams.
    case event = "evt"
    /// A device wants the events (said again every half minute), or no longer does.
    case subscribe = "sub"
    /// How many parts of a long message have arrived, so its sender goes on.
    case ack = "ack"
}

/// The readable start of every frame, inside the seal. Every part of a
/// message carries one; the first part's also says what the message is.
struct FrameHeader: Codable, Sendable, Equatable {
    var v: Int
    /// The message this part belongs to.
    var m: String
    /// This part's place, from 0, and how many parts there are.
    var i: Int
    var n: Int
    /// When it was sealed, in milliseconds since 1970 by the sender's clock:
    /// frames much older (or newer) than the receiver's clock are refused.
    var ts: Int64
    var k: LinkKind
    /// The one end it is meant for (an answer, an ack, a first snapshot);
    /// every other end on the channel drops it unread.
    var to: String?

    // A request.
    var method: String?
    var path: String?
    var query: [String: String]?
    // A response: the request it answers.
    var re: String?
    var status: Int?
    var type: String?
    // A subscription.
    var on: Bool?
    // An ack: how many parts of message `of` have arrived.
    var of: String?
    var got: Int?

    init(message: String, part: Int, parts: Int, kind: LinkKind, time: Int64 = LinkClock.now()) {
        v = LinkWire.version
        m = message
        i = part
        n = parts
        ts = time
        k = kind
    }
}

/// What the relay carries: the shape farhelm-relay routes on. It reads the
/// channel to route and nothing else; the rest is base64url it cannot open.
struct RelayEnvelope: Codable, Sendable {
    var channel: String
    var sender: String
    var nonce: String
    var ciphertext: String

    enum CodingKeys: String, CodingKey {
        case channel
        case sender = "sender_id"
        case nonce
        case ciphertext
    }
}

/// One frame, opened.
struct Frame {
    var header: FrameHeader
    var payload: Data
}

enum LinkClock {
    static func now(_ date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

/// How messages are cut into frames and sealed.
///
/// A frame is its header as JSON, a newline, then its slice of the message;
/// sealed with ChaCha20-Poly1305 under the key for its direction, with the
/// channel and the sender bound in as associated data, so the relay can
/// neither read a frame nor pass it off as another end's or another
/// channel's.
enum LinkWire {
    static let version = 1

    /// Bytes of a message in one frame. Sealed and in base64url, a frame
    /// stays well under the 256 KiB the relay accepts.
    static let partSize = 160 * 1024

    static let seatHeader = "X-Relay-Seat"

    /// A fresh encoder per use: one shared across threads is not promised
    /// to be safe.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func frame(_ header: FrameHeader, _ payload: Data) throws -> Data {
        var data = try encoder().encode(header)
        data.append(0x0A)
        data.append(payload)
        return data
    }

    static func unframe(_ data: Data) throws -> Frame {
        guard let newline = data.firstIndex(of: 0x0A) else { throw LinkError.malformed }
        let header = try JSONDecoder().decode(FrameHeader.self, from: Data(data[data.startIndex..<newline]))
        return Frame(header: header, payload: Data(data[data.index(after: newline)...]))
    }

    /// A message's body in frame-sized slices: at least one, even when empty.
    static func parts(of body: Data) -> [Data] {
        let body = Data(body)
        guard !body.isEmpty else { return [Data()] }
        return stride(from: 0, to: body.count, by: partSize).map { start in
            body.subdata(in: start..<min(start + partSize, body.count))
        }
    }

    static func associatedData(channel: String, sender: String) -> Data {
        Data("companion-link-v1|\(channel)|\(sender)".utf8)
    }

    static func seal(_ plaintext: Data, with key: SymmetricKey, channel: String, sender: String) throws -> RelayEnvelope {
        let nonce = ChaChaPoly.Nonce()
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce,
                                      authenticating: associatedData(channel: channel, sender: sender))
        return RelayEnvelope(channel: channel, sender: sender,
                             nonce: Base64URL.encode(nonce.withUnsafeBytes { Data($0) }),
                             ciphertext: Base64URL.encode(box.ciphertext + box.tag))
    }

    static func open(_ envelope: RelayEnvelope, with key: SymmetricKey) throws -> Data {
        guard let nonce = Base64URL.decode(envelope.nonce), nonce.count == 12,
              let sealed = Base64URL.decode(envelope.ciphertext), sealed.count >= 16 else {
            throw LinkError.malformed
        }
        let box = try ChaChaPoly.SealedBox(combined: nonce + sealed)
        return try ChaChaPoly.open(box, using: key,
                                   authenticating: associatedData(channel: envelope.channel, sender: envelope.sender))
    }

    static func text(_ envelope: RelayEnvelope) throws -> String {
        let data = try encoder().encode(envelope)
        return String(decoding: data, as: UTF8.self)
    }

    static func envelope(_ text: String) throws -> RelayEnvelope {
        try JSONDecoder().decode(RelayEnvelope.self, from: Data(text.utf8))
    }
}
