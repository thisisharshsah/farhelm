import Foundation
import Testing

@testable import ForgeCrypto

/// Reference vectors from TweetNaCl, checked at every block boundary.
///
/// These exist because of a specific bug. The first version of `Poly1305` read
/// the top 26-bit limb from byte 13 instead of byte 12 — off by one byte. Every
/// Swift-only test still passed: sealing and opening shared the same wrong
/// arithmetic, so round-trips were perfect, tampering was still detected, and
/// the block-boundary sweep was green. It was only wrong when talking to
/// somebody else, and only for messages of 13 bytes or more, because below that
/// the dropped byte is zero padding.
///
/// The interop fixture caught it. These vectors make sure it stays caught, at
/// every length where the padding rules change, with a failure that names the
/// length rather than saying "could not decrypt".
///
/// Generated with:
/// ```
/// nacl.secretbox(message, nonce, key)
/// ```
/// where `key[i] = i`, `nonce[i] = i + 100`, `message[i] = (i * 37 + 11) & 0xff`.
@Suite("NaCl reference vectors")
struct VectorTests {
    static let key = (0..<32).map { UInt8($0) }
    static let nonce = (0..<24).map { UInt8($0 + 100) }

    static func message(_ length: Int) -> [UInt8] {
        (0..<length).map { UInt8(($0 * 37 + 11) & 0xff) }
    }

    /// `(message length, base64url of tag || ciphertext)`.
    static let vectors: [(Int, String)] = [
        (0, "9JVy1hlCgePIf7tOIQaTLA"),
        (1, "nGbr54M12800hw6TZzGkHwk"),
        // 12 and 13 straddle the limb-4 boundary — the exact pair that separates
        // a correct Poly1305 from the off-by-one one.
        (12, "JEYqr4wy_SxdUR8XZ28dvAmJzLOlcifng6VeNg"),
        (13, "VyZk2Kbf4CXS-CH6hesgmQmJzLOlcifng6VeNvA"),
        (15, "QwE8-0UZUW5vR2z0tM7r_gmJzLOlcifng6VeNvBosg"),
        // 16 is the first full Poly1305 block, where the high bit moves outside
        // the buffer and has to be OR'd in rather than written.
        (16, "VMErSK_o6YPxAAA6N9wbSwmJzLOlcifng6VeNvBosi4"),
        (17, "DpjwaIi3czTGEMzs1ejNMQmJzLOlcifng6VeNvBosi5l"),
        (31, "Uqxb8BUWlMPu84RxkZ03zwmJzLOlcifng6VeNvBosi5lKp1tC7JyRSWkj2Ydt6g"),
        (32, "zID7_GjmxXYF84tVJbL1GgmJzLOlcifng6VeNvBosi5lKp1tC7JyRSWkj2Ydt6gO"),
        (33, "iS_tgn2OQr4UJOZyJrEDvgmJzLOlcifng6VeNvBosi5lKp1tC7JyRSWkj2Ydt6gOAw"),
        (47, "1llWJYpcbPtBMdD70Skb1gmJzLOlcifng6VeNvBosi5lKp1tC7JyRSWkj2Ydt6gOA78BAnBTEkom7gogZ59s"),
        (48, "FEWS7SdAAWKS0dQG8-kkLAmJzLOlcifng6VeNvBosi5lKp1tC7JyRSWkj2Ydt6gOA78BAnBTEkom7gogZ59ssw"),
        // 64 is the Salsa20 block boundary; 63 and 65 bracket it, because the
        // keystream is offset by 32 and an error there lands mid-block.
        (63, "CyNmlLyCGKYQSmj3KU3E5gmJzLOlcifng6VeNvBosi5lKp1tC7JyRSWkj2Ydt6gOA78BAnBTEkom7gogZ59sszqw63KdMuChIKk-lmxunw"),
        (64, "W9aHyZOxMdkV-PM5QZY7UwmJzLOlcifng6VeNvBosi5lKp1tC7JyRSWkj2Ydt6gOA78BAnBTEkom7gogZ59sszqw63KdMuChIKk-lmxun0I"),
        (65, "wnGai9MGpqzLPZkQEP1QjwmJzLOlcifng6VeNvBosi5lKp1tC7JyRSWkj2Ydt6gOA78BAnBTEkom7gogZ59sszqw63KdMuChIKk-lmxun0II"),
        (127, "OVKbteymmzQNmHd9MDZmpAmJzLOlcifng6VeNvBosi5lKp1tC7JyRSWkj2Ydt6gOA78BAnBTEkom7gogZ59sszqw63KdMuChIKk-lmxun0II-9nXFzhhxMoXohBH77zlz1doDYirApxRc4QVL5pEABHZ3CGQffMpEEMiCRuQZC5DTxPgGN9ZNyMEo3ETDZc"),
        (128, "Pvb4mhQVgvHi0SyJ-vky0QmJzLOlcifng6VeNvBosi5lKp1tC7JyRSWkj2Ydt6gOA78BAnBTEkom7gogZ59sszqw63KdMuChIKk-lmxun0II-9nXFzhhxMoXohBH77zlz1doDYirApxRc4QVL5pEABHZ3CGQffMpEEMiCRuQZC5DTxPgGN9ZNyMEo3ETDZda"),
        (129, "L5nZWd_g1vnGNGVaZkvW-AmJzLOlcifng6VeNvBosi5lKp1tC7JyRSWkj2Ydt6gOA78BAnBTEkom7gogZ59sszqw63KdMuChIKk-lmxun0II-9nXFzhhxMoXohBH77zlz1doDYirApxRc4QVL5pEABHZ3CGQffMpEEMiCRuQZC5DTxPgGN9ZNyMEo3ETDZdaNQ"),
    ]

    @Test("seals byte-for-byte what NaCl seals", arguments: vectors)
    func matchesNaCl(length: Int, expected: String) throws {
        let boxed = try SecretBox.seal(
            Self.message(length), nonce: Self.nonce, key: Self.key)
        #expect(Base64URL.encode(boxed) == expected, "message length \(length)")
    }

    @Test("opens what NaCl sealed", arguments: vectors)
    func opensNaCl(length: Int, expected: String) throws {
        let opened = try SecretBox.open(
            Base64URL.decode(expected), nonce: Self.nonce, key: Self.key)
        #expect(opened == Self.message(length), "message length \(length)")
    }

    @Test("rejects a NaCl box with one bit flipped in its tag")
    func rejectsFlippedTag() throws {
        var boxed = try Base64URL.decode(Self.vectors[10].1)
        boxed[3] ^= 0x08
        #expect(throws: CryptoError.decryptionFailed) {
            try SecretBox.open(boxed, nonce: Self.nonce, key: Self.key)
        }
    }

    @Test("rejects a box shorter than its own tag")
    func rejectsRunt() {
        #expect(throws: CryptoError.decryptionFailed) {
            try SecretBox.open([1, 2, 3], nonce: Self.nonce, key: Self.key)
        }
    }

    @Test("rejects a key of the wrong length instead of padding it")
    func rejectsShortKey() {
        #expect(throws: CryptoError.badKeyLength(expected: 32, got: 16)) {
            try SecretBox.seal([1], nonce: Self.nonce, key: [UInt8](repeating: 0, count: 16))
        }
    }

    @Test("rejects a nonce of the wrong length")
    func rejectsShortNonce() {
        #expect(throws: CryptoError.badNonceLength) {
            try SecretBox.seal([1], nonce: [1, 2, 3], key: Self.key)
        }
    }
}
