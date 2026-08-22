import CryptoKit
import Foundation

public enum CryptoError: Error, LocalizedError, Equatable {
    case badKeyLength(expected: Int, got: Int)
    case badNonceLength
    case notBase64URL
    case decryptionFailed
    case malformedOffer(String)

    public var errorDescription: String? {
        switch self {
        case .badKeyLength(let expected, let got):
            return "key must be \(expected) bytes, got \(got)"
        case .badNonceLength:
            return "nonce must be 24 bytes"
        case .notBase64URL:
            return "not valid base64url"
        case .decryptionFailed:
            // Deliberately does not distinguish "wrong key" from "tampered
            // bytes": a decrypt oracle that tells them apart is a real attack
            // surface. The same wording is used in Rust and TypeScript.
            return "could not decrypt: wrong key or tampered payload"
        case .malformedOffer(let detail):
            return detail
        }
    }
}

/// XSalsa20-Poly1305, in NaCl's *combined* form: `tag || ciphertext`.
///
/// NaCl's own C API takes zero-padded buffers and returns zero-padded ones. Rust
/// and TweetNaCl both expose the combined form instead, and that is what crosses
/// the relay, so that is what this produces.
public enum SecretBox {
    public static let keyLength = 32
    public static let nonceLength = 24
    public static let tagLength = Poly1305.tagLength

    public static func seal(_ plaintext: [UInt8], nonce: [UInt8], key: [UInt8]) throws -> [UInt8] {
        guard key.count == keyLength else {
            throw CryptoError.badKeyLength(expected: keyLength, got: key.count)
        }
        guard nonce.count == nonceLength else { throw CryptoError.badNonceLength }

        // The first 32 bytes of the keystream are the one-time Poly1305 key and
        // are never used to encrypt anything; the message starts at offset 32.
        let stream = Salsa20.keystream(key: key, nonce: nonce, count: 32 + plaintext.count)
        let polyKey = Array(stream[0..<32])

        var ciphertext = [UInt8](repeating: 0, count: plaintext.count)
        for index in 0..<plaintext.count {
            ciphertext[index] = plaintext[index] ^ stream[32 + index]
        }

        // Authenticate the ciphertext, not the plaintext — encrypt-then-MAC.
        let tag = Poly1305.authenticate(message: ciphertext, key: polyKey)
        return tag + ciphertext
    }

    public static func open(_ boxed: [UInt8], nonce: [UInt8], key: [UInt8]) throws -> [UInt8] {
        guard key.count == keyLength else {
            throw CryptoError.badKeyLength(expected: keyLength, got: key.count)
        }
        guard nonce.count == nonceLength else { throw CryptoError.badNonceLength }
        guard boxed.count >= tagLength else { throw CryptoError.decryptionFailed }

        let tag = Array(boxed[0..<tagLength])
        let ciphertext = Array(boxed[tagLength...])

        let stream = Salsa20.keystream(key: key, nonce: nonce, count: 32 + ciphertext.count)
        let polyKey = Array(stream[0..<32])

        // Verify before decrypting. Releasing plaintext from an unauthenticated
        // ciphertext is the classic way to turn a cipher into an oracle.
        guard Poly1305.verify(Poly1305.authenticate(message: ciphertext, key: polyKey), tag) else {
            throw CryptoError.decryptionFailed
        }

        var plaintext = [UInt8](repeating: 0, count: ciphertext.count)
        for index in 0..<ciphertext.count {
            plaintext[index] = ciphertext[index] ^ stream[32 + index]
        }
        return plaintext
    }
}

/// NaCl `crypto_box`: X25519 key agreement feeding [`SecretBox`].
///
/// The shared secret is *not* the raw X25519 output — NaCl runs it through
/// HSalsa20 with a zero nonce first. Skipping that step produces a cipher that
/// works perfectly against itself and interoperates with nothing, which is
/// exactly the failure `InteropTests` exists to catch.
public enum CryptoBox {
    public static func sharedKey(
        secretKey: [UInt8],
        publicKey: [UInt8]
    ) throws -> [UInt8] {
        guard secretKey.count == 32 else {
            throw CryptoError.badKeyLength(expected: 32, got: secretKey.count)
        }
        guard publicKey.count == 32 else {
            throw CryptoError.badKeyLength(expected: 32, got: publicKey.count)
        }

        let secret = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secretKey)
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        let agreed = try secret.sharedSecretFromKeyAgreement(with: peer)

        let raw = agreed.withUnsafeBytes { Array($0) }
        return Salsa20.hsalsa20(key: raw, input: [UInt8](repeating: 0, count: 16))
    }

    public static func seal(
        _ plaintext: [UInt8],
        nonce: [UInt8],
        recipientPublicKey: [UInt8],
        senderSecretKey: [UInt8]
    ) throws -> [UInt8] {
        let key = try sharedKey(secretKey: senderSecretKey, publicKey: recipientPublicKey)
        return try SecretBox.seal(plaintext, nonce: nonce, key: key)
    }

    public static func open(
        _ boxed: [UInt8],
        nonce: [UInt8],
        senderPublicKey: [UInt8],
        recipientSecretKey: [UInt8]
    ) throws -> [UInt8] {
        let key = try sharedKey(secretKey: recipientSecretKey, publicKey: senderPublicKey)
        return try SecretBox.open(boxed, nonce: nonce, key: key)
    }
}
