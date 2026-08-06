# The watch

An Apple Watch app for the one thing a wrist is genuinely good at: clearing an
approval in under five seconds without taking your phone out.

## Why this is Swift and not React Native

There is no React Native renderer for watchOS, and there is not going to be one —
watchOS has no `UIView` hierarchy to bridge to. Every "React Native watch app"
is a native watchOS target talking to the phone over WatchConnectivity. So this
is native SwiftUI, and the phone app in `mobile/` is React Native. They share the
wire format, not the code.

## Why the watch is a device, not a remote control

The tempting design is to have the watch tap a button and let the phone act on
it. That is wrong here, for a specific reason.

The runner records `decided_via` on every approval, and rule **D3** — destructive
commands cannot be cleared from a wrist — is enforced against the *registered
kind of the device whose key sealed the envelope*. A watch acting through the
phone would arrive as `phone`. The rule would quietly stop applying, and the
audit trail would say something untrue.

So the watch has its own keypair, its own row in the runner's `device` table with
`kind = 'watch'`, and its own WebSocket to the relay. The phone's entire role is
carrying the *public* key to the runner during pairing, because claiming a code
needs an HTTP request on the runner's own network and a watch usually is not on
it. The secret half never leaves the wrist — not over WatchConnectivity, not
into a backup (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).

## Layout

| Path | What it is |
|---|---|
| `Sources/ForgeCrypto` | NaCl `crypto_box` — Salsa20, HSalsa20, Poly1305, XSalsa20-Poly1305, X25519 via CryptoKit |
| `Sources/ForgeWatchKit` | The relay client, the wire types, Keychain storage, the pairing handshake |
| `Sources/ForgeWatchUI` | The SwiftUI screens and the observable store |
| `App/` | The `@main` shell — three lines, added to the Xcode target |
| `Tests/` | 37 tests, all runnable on a Mac |

The split is deliberate: everything except the `@main` shell is a package target,
so `swift test` covers it without a watch, a simulator, or a provisioning
profile. An app target that carried logic would be logic nothing could test.

## Why the crypto is hand-written

Apple ships no Salsa20 and no raw Poly1305 — CryptoKit has ChaChaPoly and
AES-GCM, neither of which is what `crypto_box` is built from. The alternative was
changing RelayForge's wire format so the watch could use CryptoKit, which would
mean a third dialect for the sake of one client.

**Hand-written crypto that only talks to itself is indistinguishable from
correct.** It round-trips beautifully and interoperates with nothing. This
happened here: the first `Poly1305` read its top limb from byte 13 instead of
byte 12. Every Swift-only test passed — round-trips, tamper detection, a sweep
across every block boundary — because seal and open shared the same wrong
arithmetic. It was wrong only when talking to somebody else, and only for
messages of 13 bytes or more.

Two things caught it and now keep it caught:

- `InteropTests` opens envelopes that **RustCrypto's audited `crypto_box`** and
  **TweetNaCl** sealed, from the fixture in
  `crates/forge-crypto/tests/fixtures/interop.json` — read at its canonical path,
  not copied, so it cannot go stale.
- `VectorTests` checks `seal` and `open` byte-for-byte against TweetNaCl output
  at every length where the padding rules change: 12/13 (the limb boundary),
  15/16/17 (the Poly1305 block), 63/64/65 (the Salsa20 block), and 127–129.

## Running the tests

```sh
cd mobile/watch && swift test
```

No watch required. If the interop tests complain the fixture is missing:

```sh
cargo test -p forge-crypto --test interop -- --ignored
node packages/client-core/scripts/seal-fixture.mjs
```

## Adding the target in Xcode

The package builds and tests on its own; turning it into an installable watch app
needs an Xcode project, which is generated rather than checked in.

1. `cd mobile && npx expo prebuild -p ios` — generates `mobile/ios/`.
2. Open `mobile/ios/RelayForge.xcworkspace`.
3. **File → New → Target → watchOS → App**. Name it `RelayForgeWatch`, embed it
   in the `RelayForge` app target.
4. Delete the generated `ContentView.swift` and `…App.swift`; add
   `mobile/watch/App/RelayForgeWatchApp.swift` instead.
5. **File → Add Package Dependencies → Add Local…** → `mobile/watch`. Add
   `ForgeWatchUI` to the watch target.
6. On the **iOS** target, confirm `react-native-watch-connectivity` linked during
   prebuild — it supplies the phone's half of the handshake.

Both targets need the same App Group only if you later want shared storage; the
current design does not, because the watch holds its own key.

## Not verified here

**No line of the watchOS UI has run on a watch.** The logic is tested — 37 tests
including the cross-language crypto — and the SwiftUI typechecks, but this
machine has the watchOS *SDK* without the watchOS *platform* installed, so
`xcodebuild -destination 'generic/platform=watchOS'` cannot run. The
`WatchConnectivity` code in `WatchStore.swift` is behind `#if canImport`, which
means it is the one part that was never compiled at all.

Treat first install on a real watch as the real test. The parts most likely to
need adjusting are layout on the smaller cases and `WCSession` reachability
behaviour when the phone app is backgrounded.
