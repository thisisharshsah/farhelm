/// Salsa20, HSalsa20, and the XSalsa20 keystream.
///
/// Written out rather than imported because Apple ships no Salsa20: CryptoKit
/// has ChaChaPoly and AES-GCM, neither of which is what NaCl `crypto_box` is
/// built from. The alternative would be changing RelayForge's wire format so the
/// watch could use CryptoKit — but the format is already spoken by Rust
/// (`crates/forge-crypto`) and TweetNaCl (`packages/client-core`), and a third
/// dialect for the sake of one client is how "the phone can't approve anything"
/// bugs get made.
///
/// Correctness here is not a matter of reading the code. `InteropTests` opens
/// envelopes sealed by RustCrypto's audited implementation and seals ones it
/// opens back — byte-for-byte, in both directions.
///
/// Reference: Bernstein, *The Salsa20 family of stream ciphers* (2007), and
/// *Extending the Salsa20 nonce* (2011) for HSalsa20.
enum Salsa20 {
    /// `"expand 32-byte k"`, the constant NaCl calls sigma.
    private static let sigma: [UInt32] = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]

    private static func rotate(_ value: UInt32, _ bits: UInt32) -> UInt32 {
        (value << bits) | (value >> (32 - bits))
    }

    /// The 20-round core, operating on a 16-word state.
    ///
    /// `hashed == false` gives the HSalsa20 variant: it returns the state after
    /// the rounds *without* adding the input back in, which is what makes it a
    /// PRF suitable for deriving a subkey rather than a stream cipher.
    private static func core(_ input: [UInt32], feedForward: Bool) -> [UInt32] {
        var x = input

        for _ in 0..<10 {
            // Column round.
            x[4] ^= rotate(x[0] &+ x[12], 7)
            x[8] ^= rotate(x[4] &+ x[0], 9)
            x[12] ^= rotate(x[8] &+ x[4], 13)
            x[0] ^= rotate(x[12] &+ x[8], 18)

            x[9] ^= rotate(x[5] &+ x[1], 7)
            x[13] ^= rotate(x[9] &+ x[5], 9)
            x[1] ^= rotate(x[13] &+ x[9], 13)
            x[5] ^= rotate(x[1] &+ x[13], 18)

            x[14] ^= rotate(x[10] &+ x[6], 7)
            x[2] ^= rotate(x[14] &+ x[10], 9)
            x[6] ^= rotate(x[2] &+ x[14], 13)
            x[10] ^= rotate(x[6] &+ x[2], 18)

            x[3] ^= rotate(x[15] &+ x[11], 7)
            x[7] ^= rotate(x[3] &+ x[15], 9)
            x[11] ^= rotate(x[7] &+ x[3], 13)
            x[15] ^= rotate(x[11] &+ x[7], 18)

            // Row round.
            x[1] ^= rotate(x[0] &+ x[3], 7)
            x[2] ^= rotate(x[1] &+ x[0], 9)
            x[3] ^= rotate(x[2] &+ x[1], 13)
            x[0] ^= rotate(x[3] &+ x[2], 18)

            x[6] ^= rotate(x[5] &+ x[4], 7)
            x[7] ^= rotate(x[6] &+ x[5], 9)
            x[4] ^= rotate(x[7] &+ x[6], 13)
            x[5] ^= rotate(x[4] &+ x[7], 18)

            x[11] ^= rotate(x[10] &+ x[9], 7)
            x[8] ^= rotate(x[11] &+ x[10], 9)
            x[9] ^= rotate(x[8] &+ x[11], 13)
            x[10] ^= rotate(x[9] &+ x[8], 18)

            x[12] ^= rotate(x[15] &+ x[14], 7)
            x[13] ^= rotate(x[12] &+ x[15], 9)
            x[14] ^= rotate(x[13] &+ x[12], 13)
            x[15] ^= rotate(x[14] &+ x[13], 18)
        }

        if feedForward {
            for index in 0..<16 { x[index] = x[index] &+ input[index] }
        }
        return x
    }

    private static func word(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        let base = bytes.startIndex
        return UInt32(bytes[base])
            | (UInt32(bytes[base + 1]) << 8)
            | (UInt32(bytes[base + 2]) << 16)
            | (UInt32(bytes[base + 3]) << 24)
    }

    private static func append(_ value: UInt32, to out: inout [UInt8]) {
        out.append(UInt8(value & 0xff))
        out.append(UInt8((value >> 8) & 0xff))
        out.append(UInt8((value >> 16) & 0xff))
        out.append(UInt8((value >> 24) & 0xff))
    }

    /// HSalsa20: 32-byte key + 16-byte input → 32-byte subkey.
    ///
    /// This is the trick that turns Salsa20's 8-byte nonce into XSalsa20's
    /// 24-byte one: hash the first 16 bytes of the long nonce into a fresh key,
    /// then run ordinary Salsa20 with the remaining 8.
    static func hsalsa20(key: [UInt8], input: [UInt8]) -> [UInt8] {
        precondition(key.count == 32 && input.count == 16)

        var state = [UInt32](repeating: 0, count: 16)
        state[0] = sigma[0]
        state[5] = sigma[1]
        state[10] = sigma[2]
        state[15] = sigma[3]
        for i in 0..<4 { state[1 + i] = word(key[(4 * i)..<(4 * i + 4)]) }
        for i in 0..<4 { state[11 + i] = word(key[(16 + 4 * i)..<(16 + 4 * i + 4)]) }
        for i in 0..<4 { state[6 + i] = word(input[(4 * i)..<(4 * i + 4)]) }

        let z = core(state, feedForward: false)

        // The output words are the ones a plain Salsa20 block would *not* have
        // fed forward — positions 0, 5, 10, 15 and 6, 7, 8, 9.
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for index in [0, 5, 10, 15, 6, 7, 8, 9] { append(z[index], to: &out) }
        return out
    }

    /// The XSalsa20 keystream: 32-byte key, 24-byte nonce, `count` bytes out.
    static func keystream(key: [UInt8], nonce: [UInt8], count: Int) -> [UInt8] {
        precondition(key.count == 32 && nonce.count == 24)

        let subkey = hsalsa20(key: key, input: Array(nonce[0..<16]))
        let salsaNonce = Array(nonce[16..<24])

        var state = [UInt32](repeating: 0, count: 16)
        state[0] = sigma[0]
        state[5] = sigma[1]
        state[10] = sigma[2]
        state[15] = sigma[3]
        for i in 0..<4 { state[1 + i] = word(subkey[(4 * i)..<(4 * i + 4)]) }
        for i in 0..<4 { state[11 + i] = word(subkey[(16 + 4 * i)..<(16 + 4 * i + 4)]) }
        state[6] = word(salsaNonce[0..<4])
        state[7] = word(salsaNonce[4..<8])

        var out: [UInt8] = []
        out.reserveCapacity(count)
        var counter: UInt64 = 0

        while out.count < count {
            state[8] = UInt32(truncatingIfNeeded: counter)
            state[9] = UInt32(truncatingIfNeeded: counter >> 32)
            let block = core(state, feedForward: true)
            for word in block { append(word, to: &out) }
            counter &+= 1
        }

        out.removeLast(out.count - count)
        return out
    }
}
