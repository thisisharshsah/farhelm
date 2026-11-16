import CryptoKit
import Foundation

/// The secret a pairing shares: 32 random bytes, made by the Mac, carried
/// once in its pairing QR code, and kept in the Keychain on both ends.
///
/// Everything the relay sees is derived from it, and nothing it sees gives
/// the key back: the seat that opens the channel and the two sealing keys
/// come out of HKDF-SHA256 under different labels, so holding the seat (as
/// the relay does) reads nothing.
public struct LinkKey: Sendable, Hashable {
    /// The 32 bytes.
    public let bytes: Data

    /// A new key.
    public init() {
        bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// The key from its text form (base64url, as in the pairing link), or
    /// nil when the text is not one.
    public init?(text: String) {
        guard let data = Base64URL.decode(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              data.count == 32 else { return nil }
        bytes = data
    }

    /// Its text form: base64url, no padding.
    public var text: String { Base64URL.encode(bytes) }

    /// What opens this pairing's channel on the relay, sent in a header.
    public var seat: String { Base64URL.encode(Self.bytes(of: derive("relay seat"))) }

    /// The relay channel this pairing meets on: `c1-` and the start of the
    /// seat's hash, so the name (which ends up in logs) opens nothing.
    /// The relay computes the same to check a seat (`seat_channel` in
    /// farhelm-relay), against the same fixture.
    public var channel: String {
        let digest = Base64URL.encode(Data(SHA256.hash(data: Data(seat.utf8))))
        return "c1-" + String(digest.prefix(22))
    }

    /// The key that seals what goes one way. Each way has its own, so a
    /// message cannot be sent back to where it came from as if new.
    func sealing(_ direction: LinkDirection) -> SymmetricKey {
        derive(direction.label)
    }

    private static let salt = Data("companion-link-v1".utf8)

    private func derive(_ label: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes), salt: Self.salt,
                               info: Data(label.utf8), outputByteCount: 32)
    }

    static func bytes(of key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}

/// Which way a message goes.
enum LinkDirection: Sendable {
    case deviceToMac
    case macToDevice

    var label: String {
        switch self {
        case .deviceToMac: return "device to mac"
        case .macToDevice: return "mac to device"
        }
    }
}

/// Base64url without padding, as the pairing link and the relay carry it.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        switch base64.count % 4 {
        case 0: break
        case 1: return nil
        case let remainder: base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}

/// Where the relay is: an address as typed in Settings or carried in a
/// pairing link ("wss://…", "https://…", or a bare host name).
public enum RelayAddress {
    /// The relay's WebSocket address, or nil when the text is not one.
    public static func url(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "wss://" + trimmed }
        guard var parts = URLComponents(string: trimmed), let host = parts.host, !host.isEmpty else { return nil }
        switch parts.scheme?.lowercased() {
        case "wss", "https": parts.scheme = "wss"
        // Plain WebSocket only for a relay on your own network: the seat
        // would cross the network readable (what it opens stays sealed).
        case "ws", "http": parts.scheme = "ws"
        default: return nil
        }
        parts.query = nil
        parts.fragment = nil
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.url
    }

    /// The WebSocket for one channel on the relay at `base`.
    static func channel(_ channel: String, at base: URL) -> URL {
        base.appendingPathComponent("v1").appendingPathComponent("channel").appendingPathComponent(channel)
    }
}
