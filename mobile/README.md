# The phone app

React Native, via Expo. iOS and Android. The wrist companion is in
[`watch/`](watch/) and is native SwiftUI — see that README for why.

## Running it

```sh
pnpm install                      # from the repo root
cd mobile
npx expo prebuild                 # generates ios/ and android/
pnpm ios                          # or: pnpm android
```

`prebuild` output is generated, not checked in. The Expo config in
`app.config.ts` is the source of truth for both platforms.

## What it shares with the web app

Everything that is not a screen. `@relayforge/client-core` holds the crypto, the
wire types, the HTTP client, and both transports; this package adds the parts a
phone does differently:

| | Web | React Native |
|---|---|---|
| Pairing storage | `localStorage`, in the clear | Keychain / EncryptedSharedPreferences via `expo-secure-store` |
| Live updates on the local network | `EventSource` (SSE) | polling, every 3s — RN has no SSE |
| Live updates over the relay | WebSocket | WebSocket (same code) |
| Randomness | `crypto.getRandomValues` | same, once `react-native-get-random-values` has loaded |
| Cost dashboard | yes | no — a reading surface, not a fifteen-second one |

The keystore is the one place this client is meaningfully safer than the PWA:
there is no origin for an injected script to run on and steal the device key.

### The import order in `index.js` is load-bearing

Hermes has no `crypto.getRandomValues`. TweetNaCl looks for it at *module load*
and throws "no PRNG" if it is missing, so `react-native-get-random-values` must
be imported before anything reaches `@relayforge/client-core`. Throwing is the
good outcome — the alternative is a key generated from a predictable source,
which is indistinguishable from a working app right up until it isn't.

## Pairing the watch

The watch generates its own keypair and asks this app to redeem a code for it,
because claiming a code needs an HTTP request to the runner on its own network
and a watch usually is not on one. Only the **public** half crosses.

The phone must be able to reach the runner directly while that happens — set the
address under **Pair**. `src/watch/bridge.ts` has the full reasoning, and
`bridge.test.ts` asserts the two properties that matter: the device is claimed as
`kind: "watch"` (claiming it as `phone` would silently disable the
destructive-command rule for the wrist), and nothing secret is ever sent.

## Testing

```sh
pnpm test          # the watch bridge, under Node
pnpm typecheck
```

The screens are not unit-tested: rendering them needs a React Native renderer,
which is a device or a simulator. What is tested is what can be wrong silently —
the pairing courier logic and the shared core it sits on.

## Not verified here

**No screen of this app has been rendered.** It typechecks and its logic is
tested, but this machine has no simulator, so layout, dark mode, and tap targets
are unverified by eye.
