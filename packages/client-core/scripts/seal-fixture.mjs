/**
 * Fills in the TweetNaCl-sealed half of the cross-language interop fixture.
 *
 * The Rust side mints the keys and seals runner→device; this seals device→runner
 * with the *JavaScript* implementation, so the checked-in fixture proves both
 * directions rather than only Rust talking to itself.
 *
 * Run after `cargo test -p forge-crypto --test interop -- --ignored`.
 */
import { readFileSync, writeFileSync } from "node:fs";
import nacl from "tweetnacl";

const PATH = new URL(
  "../../../crates/forge-crypto/tests/fixtures/interop.json",
  import.meta.url,
);

const b64 = {
  encode: (bytes) =>
    Buffer.from(bytes).toString("base64url"),
  decode: (text) => new Uint8Array(Buffer.from(text, "base64url")),
};

const fixture = JSON.parse(readFileSync(PATH, "utf8"));

const nonce = nacl.randomBytes(nacl.box.nonceLength);
const plaintext = new TextEncoder().encode(fixture.device_to_runner_plaintext);
const ciphertext = nacl.box(
  plaintext,
  nonce,
  b64.decode(fixture.runner_public),
  b64.decode(fixture.device_secret),
);

fixture.device_to_runner = {
  channel: fixture.channel,
  sender_id: "device-phone",
  nonce: b64.encode(nonce),
  ciphertext: b64.encode(ciphertext),
};

writeFileSync(PATH, `${JSON.stringify(fixture, null, 2)}\n`);
console.log("sealed device→runner with TweetNaCl");
