/**
 * Everything a RelayForge client needs that is not a screen.
 *
 * Three clients import this package: the web PWA, the React Native phone app,
 * and (indirectly, by matching its wire format) the watchOS app. Nothing here
 * touches the DOM, `localStorage`, React, or React Native — that is enforced by
 * running this package's tests in a Node environment with no jsdom.
 */

export { CryptoError } from "./errors.ts";
export { fromBase64Url, toBase64Url } from "./base64.ts";
export {
  Identity,
  PAIRING_STORAGE_KEY,
  claimPairing,
  pairingStore,
  parseOffer,
  type DeviceKind,
  type Envelope,
  type Pairing,
  type PairingOffer,
  type PairingStore,
} from "./crypto.ts";
export * from "./api.ts";
export * from "./diff.ts";
export * from "./format.ts";
export { fetchFleetOnce, sendCommandOnce } from "./oneshot.ts";
export {
  applicationServerKey,
  httpFrom,
  registerPush,
  vapidPublicKey,
  type PushSubscription,
} from "./push.ts";
export {
  HttpTransport,
  RelayTransport,
  type Command,
  type ConnectionState,
  type EventStream,
  type Transport,
} from "./transport.ts";
