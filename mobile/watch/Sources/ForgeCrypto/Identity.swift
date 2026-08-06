import CryptoKit
import Foundation

/// base64url, unpadded — the form every RelayForge component speaks.
public enum Base64URL {
    public static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ encoded: String) throws -> [UInt8] {
        var standard = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Foundation's decoder insists on padding; the wire format omits it.
        let remainder = standard.count % 4
        if remainder == 1 { throw CryptoError.notBase64URL }
        if remainder > 0 { standard += String(repeating: "=", count: 4 - remainder) }

        guard let data = Data(base64Encoded: standard) else {
            throw CryptoError.notBase64URL
        }
        return [UInt8](data)
    }
}

/// Exactly what crosses the relay. Mirrors `forge_crypto::Envelope` and the
/// TypeScript `Envelope`, field name for field name — this struct is the wire
/// format, so its `CodingKeys` are not cosmetic.
public struct Envelope: Codable, Equatable, Sendable {
    public let channel: String
    public let senderID: String
    public let nonce: String
    public let ciphertext: String

    enum CodingKeys: String, CodingKey {
        case channel
        case senderID = "sender_id"
        case nonce
        case ciphertext
    }

    public init(channel: String, senderID: String, nonce: String, ciphertext: String) {
        self.channel = channel
        self.senderID = senderID
        self.nonce = nonce
        self.ciphertext = ciphertext
    }
}

/// This device's keypair.
///
/// Generated on the watch and never sent anywhere. When the phone claims a
/// pairing code on the watch's behalf, it carries `publicKey` and nothing else —
/// see `mobile/src/watch/bridge.ts`.
public struct Identity: Sendable {
    private let secret: [UInt8]
    public let publicKey: String

    private init(secret: [UInt8], publicKey: String) {
        self.secret = secret
        self.publicKey = publicKey
    }

    public static func generate() -> Identity {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return Identity(
            secret: [UInt8](key.rawRepresentation),
            publicKey: Base64URL.encode([UInt8](key.publicKey.rawRepresentation))
        )
    }

    public static func fromSecret(_ secretBase64URL: String) throws -> Identity {
        let secret = try Base64URL.decode(secretBase64URL)
        guard secret.count == 32 else {
            throw CryptoError.badKeyLength(expected: 32, got: secret.count)
        }
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secret)
        return Identity(
            secret: secret,
            publicKey: Base64URL.encode([UInt8](key.publicKey.rawRepresentation))
        )
    }

    /// For the keychain, and nowhere else.
    public func toSecret() -> String { Base64URL.encode(secret) }

    public func seal(
        channel: String,
        senderID: String,
        recipientPublicKey: String,
        plaintext: [UInt8]
    ) throws -> Envelope {
        // CryptoKit's key generator is the system CSPRNG, stated as such. A
        // repeated nonce under the same key is total loss for XSalsa20, so this
        // must never be anything cheaper — not a counter, not `Int.random`.
        let nonce = SymmetricKey(size: .init(bitCount: SecretBox.nonceLength * 8))
            .withUnsafeBytes { Array($0) }

        let boxed = try CryptoBox.seal(
            plaintext,
            nonce: nonce,
            recipientPublicKey: Base64URL.decode(recipientPublicKey),
            senderSecretKey: secret
        )
        return Envelope(
            channel: channel,
            senderID: senderID,
            nonce: Base64URL.encode(nonce),
            ciphertext: Base64URL.encode(boxed)
        )
    }

    /// Decrypt an envelope `senderPublicKey` sealed for this device.
    ///
    /// Requiring the sender's key is the authentication: an envelope from anyone
    /// else fails even though it was correctly addressed. This is what makes
    /// `decided_via` meaningful — the runner knows which device spoke.
    public func open(senderPublicKey: String, envelope: Envelope) throws -> [UInt8] {
        let nonce = try Base64URL.decode(envelope.nonce)
        guard nonce.count == SecretBox.nonceLength else { throw CryptoError.badNonceLength }

        return try CryptoBox.open(
            Base64URL.decode(envelope.ciphertext),
            nonce: nonce,
            senderPublicKey: Base64URL.decode(senderPublicKey),
            recipientSecretKey: secret
        )
    }

    public func sealJSON<T: Encodable>(
        channel: String,
        senderID: String,
        recipientPublicKey: String,
        value: T
    ) throws -> Envelope {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        return try seal(
            channel: channel,
            senderID: senderID,
            recipientPublicKey: recipientPublicKey,
            plaintext: [UInt8](data)
        )
    }

    public func openJSON<T: Decodable>(
        _ type: T.Type,
        senderPublicKey: String,
        envelope: Envelope
    ) throws -> T {
        let bytes = try open(senderPublicKey: senderPublicKey, envelope: envelope)
        return try JSONDecoder().decode(type, from: Data(bytes))
    }
}
