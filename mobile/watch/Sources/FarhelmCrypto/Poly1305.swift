/// Poly1305, the one-time authenticator NaCl's `secretbox` uses.
///
/// CryptoKit exposes Poly1305 only welded to ChaCha20 inside `ChaChaPoly`, so
/// the raw primitive has to be here. This follows the 32-bit limb structure of
/// poly1305-donna, which is the reference everyone implements from: the message
/// is read as 130-bit numbers, accumulated mod 2^130 − 5, and the result added
/// to the second half of the key.
///
/// Reference: Bernstein, *The Poly1305-AES message-authentication code* (2005),
/// and RFC 8439 §2.5 for the same arithmetic in modern notation.
enum Poly1305 {
    static let tagLength = 16
    static let keyLength = 32

    /// Authenticate `message` under a **one-time** key.
    ///
    /// Reusing a key across two messages leaks the key — which is why callers
    /// here always derive it fresh from the stream cipher, per nonce.
    static func authenticate(message: [UInt8], key: [UInt8]) -> [UInt8] {
        precondition(key.count == keyLength)

        // r is clamped: the top four bits of certain bytes are cleared so that
        // the multiplications below cannot overflow the limb arithmetic.
        var r = [UInt32](repeating: 0, count: 5)
        r[0] = (le32(key, 0)) & 0x3ff_ffff
        r[1] = ((le32(key, 3)) >> 2) & 0x3ff_ff03
        r[2] = ((le32(key, 6)) >> 4) & 0x3ff_c0ff
        r[3] = ((le32(key, 9)) >> 6) & 0x3f0_3fff
        r[4] = ((le32(key, 12)) >> 8) & 0x00f_ffff

        var h = [UInt32](repeating: 0, count: 5)
        let s = [
            r[1] &* 5, r[2] &* 5, r[3] &* 5, r[4] &* 5,
        ]

        var offset = 0
        var remaining = message.count

        while remaining > 0 {
            let take = min(16, remaining)

            // Every block is read as a 130-bit number: 128 bits of message with
            // a 1 bit above them. For a full block that bit sits at position
            // 128, past the 16 bytes, so it is OR'd in. For a short final block
            // it lands *inside* the buffer, right after the last message byte.
            //
            // The five limbs are 26 bits each, so limb 4 covers bits 104–129 —
            // which is the 32-bit word at byte 12, shifted down by 8. Reading it
            // at byte 13 instead is off by one byte and produces a tag that is
            // self-consistent but wrong; short messages hide it, because the
            // dropped byte is zero padding.
            let highBit: UInt32 = take == 16 ? (1 << 24) : 0
            var block = [UInt8](repeating: 0, count: 16)
            for index in 0..<take { block[index] = message[offset + index] }
            if take < 16 { block[take] = 1 }

            h[0] &+= (le32(block, 0)) & 0x3ff_ffff
            h[1] &+= ((le32(block, 3)) >> 2) & 0x3ff_ffff
            h[2] &+= ((le32(block, 6)) >> 4) & 0x3ff_ffff
            h[3] &+= ((le32(block, 9)) >> 6) & 0x3ff_ffff
            h[4] &+= ((le32(block, 12)) >> 8) | highBit

            // h = (h * r) mod 2^130 - 5, in five 26-bit limbs.
            var d = [UInt64](repeating: 0, count: 5)
            d[0] = mul(h[0], r[0]) &+ mul(h[1], s[3]) &+ mul(h[2], s[2]) &+ mul(h[3], s[1]) &+ mul(h[4], s[0])
            d[1] = mul(h[0], r[1]) &+ mul(h[1], r[0]) &+ mul(h[2], s[3]) &+ mul(h[3], s[2]) &+ mul(h[4], s[1])
            d[2] = mul(h[0], r[2]) &+ mul(h[1], r[1]) &+ mul(h[2], r[0]) &+ mul(h[3], s[3]) &+ mul(h[4], s[2])
            d[3] = mul(h[0], r[3]) &+ mul(h[1], r[2]) &+ mul(h[2], r[1]) &+ mul(h[3], r[0]) &+ mul(h[4], s[3])
            d[4] = mul(h[0], r[4]) &+ mul(h[1], r[3]) &+ mul(h[2], r[2]) &+ mul(h[3], r[1]) &+ mul(h[4], r[0])

            var carry: UInt64 = 0
            for index in 0..<5 {
                d[index] &+= carry
                h[index] = UInt32(d[index] & 0x3ff_ffff)
                carry = d[index] >> 26
            }
            // The 2^130 wrap: 2^130 ≡ 5, so the overflow folds back times five.
            h[0] &+= UInt32(carry &* 5)
            h[1] &+= h[0] >> 26
            h[0] &= 0x3ff_ffff

            offset += take
            remaining -= take
        }

        // Final carry propagation.
        var carry = h[1] >> 26
        h[1] &= 0x3ff_ffff
        for index in 2..<5 {
            h[index] &+= carry
            carry = h[index] >> 26
            h[index] &= 0x3ff_ffff
        }
        h[0] &+= carry &* 5
        carry = h[0] >> 26
        h[0] &= 0x3ff_ffff
        h[1] &+= carry

        // Compute h + -p and pick it if there was no borrow — i.e. reduce once
        // more if h ≥ p. Done without a branch on the value.
        var g = [UInt32](repeating: 0, count: 5)
        g[0] = h[0] &+ 5
        carry = g[0] >> 26
        g[0] &= 0x3ff_ffff
        for index in 1..<4 {
            g[index] = h[index] &+ carry
            carry = g[index] >> 26
            g[index] &= 0x3ff_ffff
        }
        g[4] = h[4] &+ carry &- (1 << 26)

        var mask = (g[4] >> 31) &- 1  // all ones when g did not borrow
        for index in 0..<5 { g[index] &= mask }
        mask = ~mask
        for index in 0..<5 { h[index] = (h[index] & mask) | g[index] }

        // Repack the 26-bit limbs into 32-bit words.
        var f = [UInt64](repeating: 0, count: 4)
        f[0] = UInt64((h[0] | (h[1] << 26)) & 0xffff_ffff)
        f[1] = UInt64(((h[1] >> 6) | (h[2] << 20)) & 0xffff_ffff)
        f[2] = UInt64(((h[2] >> 12) | (h[3] << 14)) & 0xffff_ffff)
        f[3] = UInt64(((h[3] >> 18) | (h[4] << 8)) & 0xffff_ffff)

        // tag = (h + pad) mod 2^128, where pad is the key's second half.
        var tag = [UInt8](repeating: 0, count: tagLength)
        var accumulator: UInt64 = 0
        for index in 0..<4 {
            accumulator &+= f[index] &+ UInt64(le32(key, 16 + index * 4))
            tag[index * 4] = UInt8(accumulator & 0xff)
            tag[index * 4 + 1] = UInt8((accumulator >> 8) & 0xff)
            tag[index * 4 + 2] = UInt8((accumulator >> 16) & 0xff)
            tag[index * 4 + 3] = UInt8((accumulator >> 24) & 0xff)
            accumulator >>= 32
        }
        return tag
    }

    /// Constant-time tag comparison.
    ///
    /// An early return on the first differing byte turns forgery into a timing
    /// puzzle solvable one byte at a time. This looks at every byte, always.
    static func verify(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }

    private static func mul(_ lhs: UInt32, _ rhs: UInt32) -> UInt64 {
        UInt64(lhs) &* UInt64(rhs)
    }

    /// Little-endian 32-bit read, tolerating a short tail.
    private static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 where offset + index < bytes.count {
            value |= UInt32(bytes[offset + index]) << (8 * UInt32(index))
        }
        return value
    }
}
