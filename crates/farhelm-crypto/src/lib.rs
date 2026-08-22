//! End-to-end encryption between devices and the runner (D2).
//!
//! The security claim in §6 is precise, and this module is what has to make it
//! true: *a compromised relay learns session existence, not content*. Everything
//! that crosses the relay is an [`Envelope`], and an envelope is opaque to
//! anyone who does not hold one of the two long-term secret keys.
//!
//! # One deviation from the design document, on purpose
//!
//! §6 specifies libsodium **sealed boxes**. A sealed box is *anonymous*: it
//! encrypts to a recipient's public key using a throwaway keypair, so the
//! recipient learns nothing about who sent it. That is the wrong primitive for
//! this system in one direction and dangerous in the other:
//!
//! - The runner's public key travels in a pairing QR code. Anyone who
//!   photographs that QR — over a shoulder, out of a screenshot, from a chat
//!   backlog — could seal a valid `approval_decision` to the runner. Sealed
//!   boxes have no sender to check, so the runner would have no way to tell that
//!   message from the paired phone's.
//! - The whole point of the approval flow is knowing *who* approved. The
//!   `approval.decided_via` column is meaningless if the transport cannot
//!   attest to the sender.
//!
//! So both directions use **authenticated** boxes (X25519 + XSalsa20-Poly1305,
//! NaCl `crypto_box`): the sender signs with its own secret key and the receiver
//! verifies with the sender's known public key. Confidentiality is identical to
//! a sealed box; authenticity is added. The cost is that a device must be paired
//! before it can talk, which is the intended behaviour anyway.
//!
//! # What the relay can still see
//!
//! [`Envelope`] deliberately exposes the routing metadata a dumb relay needs and
//! nothing else: which channel, which sender, a nonce, and a byte string. Those
//! leak that *a* device is talking to *a* runner and roughly how much — which is
//! the documented, accepted residual.

pub mod keystore;
pub mod token;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use crypto_box::aead::{Aead, AeadCore, OsRng};
use crypto_box::{PublicKey as BoxPublicKey, SalsaBox, SecretKey as BoxSecretKey};
use serde::{Deserialize, Serialize};

/// How long a pairing code stays usable. Long enough to walk to the other
/// device, short enough that a photographed QR is not a standing invitation.
pub const PAIRING_TTL_MS: i64 = 10 * 60 * 1_000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CryptoError {
    /// The ciphertext did not authenticate: wrong key, wrong sender, or
    /// tampered bytes. Deliberately does not say which — a decrypt oracle that
    /// distinguishes those is a real attack surface.
    Undecryptable,
    MalformedKey(String),
    MalformedEnvelope(String),
    /// The pairing code was wrong, already used, or expired.
    PairingRejected(&'static str),
}

impl std::fmt::Display for CryptoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CryptoError::Undecryptable => {
                f.write_str("could not decrypt: wrong key or tampered payload")
            }
            CryptoError::MalformedKey(what) => write!(f, "malformed key: {what}"),
            CryptoError::MalformedEnvelope(what) => write!(f, "malformed envelope: {what}"),
            CryptoError::PairingRejected(why) => write!(f, "pairing rejected: {why}"),
        }
    }
}

impl std::error::Error for CryptoError {}

/// A public key, in the base64url form that travels in QR codes and the
/// `device.pubkey` column.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct PublicKey(String);

impl PublicKey {
    fn from_box(key: &BoxPublicKey) -> Self {
        Self(B64.encode(key.as_bytes()))
    }

    fn to_box(&self) -> Result<BoxPublicKey, CryptoError> {
        let bytes = B64
            .decode(&self.0)
            .map_err(|err| CryptoError::MalformedKey(err.to_string()))?;
        let bytes: [u8; 32] = bytes
            .try_into()
            .map_err(|_| CryptoError::MalformedKey("expected 32 bytes".into()))?;
        Ok(BoxPublicKey::from(bytes))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn parse(encoded: &str) -> Result<Self, CryptoError> {
        let key = Self(encoded.to_owned());
        // Round-trip now so a bad key fails at the boundary rather than at the
        // first message.
        key.to_box()?;
        Ok(key)
    }
}

impl std::fmt::Display for PublicKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// A long-term keypair: one per runner, one per paired device.
///
/// The secret half is never serialised by any `Serialize` impl — writing it out
/// is [`Identity::to_secret_base64`], which is deliberately awkward to call by
/// accident and used in exactly one place.
pub struct Identity {
    secret: BoxSecretKey,
    public: PublicKey,
}

impl std::fmt::Debug for Identity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never print the secret, not even in a panic message.
        f.debug_struct("Identity")
            .field("public", &self.public)
            .field("secret", &"<redacted>")
            .finish()
    }
}

impl Identity {
    pub fn generate() -> Self {
        let secret = BoxSecretKey::generate(&mut OsRng);
        let public = PublicKey::from_box(&secret.public_key());
        Self { secret, public }
    }

    pub fn public_key(&self) -> &PublicKey {
        &self.public
    }

    /// The secret key, base64url. Only for writing the keystore.
    pub fn to_secret_base64(&self) -> String {
        B64.encode(self.secret.to_bytes())
    }

    pub fn from_secret_base64(encoded: &str) -> Result<Self, CryptoError> {
        let bytes = B64
            .decode(encoded.trim())
            .map_err(|err| CryptoError::MalformedKey(err.to_string()))?;
        let bytes: [u8; 32] = bytes
            .try_into()
            .map_err(|_| CryptoError::MalformedKey("expected 32 bytes".into()))?;
        let secret = BoxSecretKey::from(bytes);
        let public = PublicKey::from_box(&secret.public_key());
        Ok(Self { secret, public })
    }

    /// Encrypt `plaintext` for `recipient`, authenticated as this identity.
    pub fn seal(
        &self,
        channel: &str,
        sender_id: &str,
        recipient: &PublicKey,
        plaintext: &[u8],
    ) -> Result<Envelope, CryptoError> {
        let boxed = SalsaBox::new(&recipient.to_box()?, &self.secret);
        let nonce = SalsaBox::generate_nonce(&mut OsRng);
        let ciphertext = boxed
            .encrypt(&nonce, plaintext)
            .map_err(|_| CryptoError::Undecryptable)?;

        Ok(Envelope {
            channel: channel.to_owned(),
            sender_id: sender_id.to_owned(),
            nonce: B64.encode(nonce),
            ciphertext: B64.encode(ciphertext),
        })
    }

    /// Decrypt an envelope that `sender` sealed for this identity.
    ///
    /// Requiring the sender's public key is the authentication: an envelope from
    /// anyone else fails, even though it was addressed to us.
    pub fn open(&self, sender: &PublicKey, envelope: &Envelope) -> Result<Vec<u8>, CryptoError> {
        let nonce_bytes = B64
            .decode(&envelope.nonce)
            .map_err(|err| CryptoError::MalformedEnvelope(err.to_string()))?;
        let nonce: [u8; 24] = nonce_bytes
            .try_into()
            .map_err(|_| CryptoError::MalformedEnvelope("nonce must be 24 bytes".into()))?;
        let ciphertext = B64
            .decode(&envelope.ciphertext)
            .map_err(|err| CryptoError::MalformedEnvelope(err.to_string()))?;

        SalsaBox::new(&sender.to_box()?, &self.secret)
            .decrypt(&nonce.into(), ciphertext.as_slice())
            .map_err(|_| CryptoError::Undecryptable)
    }

    /// Convenience: seal a serialisable value as JSON.
    pub fn seal_json<T: Serialize>(
        &self,
        channel: &str,
        sender_id: &str,
        recipient: &PublicKey,
        value: &T,
    ) -> Result<Envelope, CryptoError> {
        let json = serde_json::to_vec(value)
            .map_err(|err| CryptoError::MalformedEnvelope(err.to_string()))?;
        self.seal(channel, sender_id, recipient, &json)
    }

    pub fn open_json<T: for<'de> Deserialize<'de>>(
        &self,
        sender: &PublicKey,
        envelope: &Envelope,
    ) -> Result<T, CryptoError> {
        let bytes = self.open(sender, envelope)?;
        serde_json::from_slice(&bytes)
            .map_err(|err| CryptoError::MalformedEnvelope(err.to_string()))
    }
}

/// Exactly what crosses the relay.
///
/// Every field here is metadata the relay needs to route, or opaque bytes. If a
/// future field would let the relay infer content, it does not belong here.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Envelope {
    /// Which runner's fan-out group this belongs to. A public identifier, not a
    /// secret — knowing it lets you connect, not read.
    pub channel: String,
    /// Who sealed it, so the receiver knows whose public key to verify against.
    pub sender_id: String,
    /// base64url, 24 bytes.
    pub nonce: String,
    /// base64url ciphertext, including the Poly1305 tag.
    pub ciphertext: String,
}

impl Envelope {
    /// Bytes on the wire, for the relay's size accounting.
    pub fn size_hint(&self) -> usize {
        self.ciphertext.len()
    }
}

/* ------------------------------------------------------------------ pairing */

/// What a pairing QR code encodes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PairingOffer {
    /// Where to reach the relay.
    pub relay_url: String,
    /// The runner's fan-out channel.
    pub channel: String,
    /// The runner's long-term public key — what the device will encrypt to.
    pub runner_public_key: PublicKey,
    /// Single-use code proving the device saw this QR.
    pub code: String,
    /// Unix ms after which the code is refused.
    pub expires_at: i64,
}

impl PairingOffer {
    pub fn to_qr_payload(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }

    pub fn parse(payload: &str) -> Result<Self, CryptoError> {
        serde_json::from_str(payload).map_err(|err| CryptoError::MalformedEnvelope(err.to_string()))
    }
}

/// Issues and redeems pairing codes.
///
/// A code is good for one device, once, before it expires. That is what stops a
/// photographed QR from being a standing invitation — the second use fails even
/// with the correct code.
#[derive(Debug, Default)]
pub struct PairingBroker {
    outstanding: std::collections::HashMap<String, i64>,
}

impl PairingBroker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Mint an offer. `now_ms` is passed in so tests and replays are not at the
    /// mercy of the wall clock.
    pub fn offer(
        &mut self,
        relay_url: &str,
        channel: &str,
        runner_public_key: &PublicKey,
        now_ms: i64,
    ) -> PairingOffer {
        let code = random_code();
        let expires_at = now_ms + PAIRING_TTL_MS;
        self.outstanding.insert(code.clone(), expires_at);

        PairingOffer {
            relay_url: relay_url.to_owned(),
            channel: channel.to_owned(),
            runner_public_key: runner_public_key.clone(),
            code,
            expires_at,
        }
    }

    /// Redeem a code. Succeeds at most once per code.
    pub fn redeem(&mut self, code: &str, now_ms: i64) -> Result<(), CryptoError> {
        // Removed first: a redeem that fails on expiry still consumes the code,
        // so a stale code cannot be retried until the clock cooperates.
        let Some(expires_at) = self.outstanding.remove(code) else {
            return Err(CryptoError::PairingRejected("unknown or already used"));
        };
        if now_ms >= expires_at {
            return Err(CryptoError::PairingRejected("expired"));
        }
        Ok(())
    }

    /// Drop codes nobody redeemed.
    pub fn purge_expired(&mut self, now_ms: i64) -> usize {
        let before = self.outstanding.len();
        self.outstanding.retain(|_, expires| *expires > now_ms);
        before - self.outstanding.len()
    }

    pub fn outstanding(&self) -> usize {
        self.outstanding.len()
    }
}

/// 160 bits from the OS CSPRNG, base64url. Long enough that guessing is not a
/// strategy even without rate limiting.
fn random_code() -> String {
    use rand_core::RngCore as _;
    let mut bytes = [0u8; 20];
    OsRng.fill_bytes(&mut bytes);
    B64.encode(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_785_369_600_000;

    fn pair() -> (Identity, Identity) {
        (Identity::generate(), Identity::generate())
    }

    #[test]
    fn a_message_round_trips_between_two_identities() {
        let (runner, phone) = pair();
        let envelope = runner
            .seal("chan", "runner", phone.public_key(), b"approve the push")
            .unwrap();

        let opened = phone.open(runner.public_key(), &envelope).unwrap();
        assert_eq!(opened, b"approve the push");
    }

    #[test]
    fn json_payloads_round_trip() {
        #[derive(Debug, PartialEq, Serialize, Deserialize)]
        struct Decision {
            approval_id: String,
            decision: String,
        }

        let (runner, phone) = pair();
        let sent = Decision {
            approval_id: "a1".into(),
            decision: "approved".into(),
        };
        let envelope = phone
            .seal_json("chan", "phone", runner.public_key(), &sent)
            .unwrap();

        let received: Decision = runner.open_json(phone.public_key(), &envelope).unwrap();
        assert_eq!(received, sent);
    }

    #[test]
    fn the_relay_sees_no_plaintext() {
        let (runner, phone) = pair();
        let secret_text = "rm -rf /very/secret/path";
        let envelope = runner
            .seal("chan", "runner", phone.public_key(), secret_text.as_bytes())
            .unwrap();

        // Everything a relay could serialise and store.
        let as_relay_sees_it = serde_json::to_string(&envelope).unwrap();
        assert!(
            !as_relay_sees_it.contains("secret"),
            "plaintext leaked into the envelope: {as_relay_sees_it}"
        );
        assert!(!as_relay_sees_it.contains("rm -rf"));
    }

    #[test]
    fn a_third_party_holding_both_public_keys_cannot_read_it() {
        let (runner, phone) = pair();
        let eavesdropper = Identity::generate();
        let envelope = runner
            .seal("chan", "runner", phone.public_key(), b"private")
            .unwrap();

        // The relay knows both public keys — they are in the QR and the device
        // table — and its own secret. That is not enough.
        assert_eq!(
            eavesdropper.open(runner.public_key(), &envelope),
            Err(CryptoError::Undecryptable)
        );
        assert_eq!(
            eavesdropper.open(phone.public_key(), &envelope),
            Err(CryptoError::Undecryptable)
        );
    }

    #[test]
    fn an_envelope_from_an_unpaired_sender_is_refused() {
        // The attack sealed boxes would allow: anyone with the runner's public
        // key from a photographed QR sealing a valid-looking approval.
        let (runner, _phone) = pair();
        let attacker = Identity::generate();

        let forged = attacker
            .seal("chan", "phone", runner.public_key(), b"approve everything")
            .unwrap();

        // The runner verifies against the *paired phone's* key, so the forgery
        // fails even though it was correctly addressed.
        let phone = Identity::generate();
        assert_eq!(
            runner.open(phone.public_key(), &forged),
            Err(CryptoError::Undecryptable)
        );
    }

    #[test]
    fn tampering_with_the_ciphertext_is_detected() {
        let (runner, phone) = pair();
        let mut envelope = runner
            .seal("chan", "runner", phone.public_key(), b"deny")
            .unwrap();

        // Flip one base64 character. AEAD must reject it.
        let mut bytes = B64.decode(&envelope.ciphertext).unwrap();
        bytes[0] ^= 0x01;
        envelope.ciphertext = B64.encode(&bytes);

        assert_eq!(
            phone.open(runner.public_key(), &envelope),
            Err(CryptoError::Undecryptable)
        );
    }

    #[test]
    fn tampering_with_the_nonce_is_detected() {
        let (runner, phone) = pair();
        let mut envelope = runner
            .seal("chan", "runner", phone.public_key(), b"deny")
            .unwrap();

        let mut bytes = B64.decode(&envelope.nonce).unwrap();
        bytes[0] ^= 0x01;
        envelope.nonce = B64.encode(&bytes);

        assert_eq!(
            phone.open(runner.public_key(), &envelope),
            Err(CryptoError::Undecryptable)
        );
    }

    #[test]
    fn rewriting_the_routing_metadata_does_not_help_an_attacker_read_it() {
        // The relay can freely rewrite channel and sender_id — they are outside
        // the AEAD. That must not affect confidentiality, only routing.
        let (runner, phone) = pair();
        let mut envelope = runner
            .seal("chan", "runner", phone.public_key(), b"payload")
            .unwrap();
        envelope.channel = "attacker-channel".into();
        envelope.sender_id = "someone-else".into();

        assert_eq!(
            phone.open(runner.public_key(), &envelope).unwrap(),
            b"payload"
        );
    }

    #[test]
    fn every_message_gets_a_fresh_nonce() {
        let (runner, phone) = pair();
        let first = runner
            .seal("chan", "runner", phone.public_key(), b"same text")
            .unwrap();
        let second = runner
            .seal("chan", "runner", phone.public_key(), b"same text")
            .unwrap();

        assert_ne!(first.nonce, second.nonce);
        // ...so identical plaintexts do not produce identical ciphertexts.
        assert_ne!(first.ciphertext, second.ciphertext);
    }

    #[test]
    fn a_malformed_envelope_is_rejected_rather_than_panicking() {
        let (runner, phone) = pair();
        let bad = Envelope {
            channel: "c".into(),
            sender_id: "s".into(),
            nonce: "not-base64!!".into(),
            ciphertext: "also not base64!!".into(),
        };
        assert!(matches!(
            phone.open(runner.public_key(), &bad),
            Err(CryptoError::MalformedEnvelope(_))
        ));

        let short_nonce = Envelope {
            nonce: B64.encode([0u8; 8]),
            ciphertext: B64.encode([0u8; 32]),
            ..bad
        };
        assert!(matches!(
            phone.open(runner.public_key(), &short_nonce),
            Err(CryptoError::MalformedEnvelope(_))
        ));
    }

    #[test]
    fn an_identity_survives_a_save_and_load() {
        let original = Identity::generate();
        let encoded = original.to_secret_base64();
        let restored = Identity::from_secret_base64(&encoded).unwrap();

        assert_eq!(original.public_key(), restored.public_key());

        // ...and can still read messages sent to the original.
        let peer = Identity::generate();
        let envelope = peer
            .seal("c", "peer", original.public_key(), b"still works")
            .unwrap();
        assert_eq!(
            restored.open(peer.public_key(), &envelope).unwrap(),
            b"still works"
        );
    }

    #[test]
    fn a_corrupt_stored_key_is_an_error_not_a_panic() {
        assert!(Identity::from_secret_base64("nonsense!!!").is_err());
        assert!(Identity::from_secret_base64(&B64.encode([0u8; 8])).is_err());
    }

    #[test]
    fn debug_output_never_contains_the_secret() {
        let identity = Identity::generate();
        let rendered = format!("{identity:?}");
        assert!(rendered.contains("redacted"));
        assert!(!rendered.contains(&identity.to_secret_base64()));
    }

    #[test]
    fn a_public_key_round_trips_through_its_text_form() {
        let identity = Identity::generate();
        let parsed = PublicKey::parse(identity.public_key().as_str()).unwrap();
        assert_eq!(&parsed, identity.public_key());
    }

    #[test]
    fn a_malformed_public_key_fails_at_the_boundary() {
        assert!(PublicKey::parse("not-a-key").is_err());
        assert!(PublicKey::parse(&B64.encode([0u8; 16])).is_err());
    }

    /* ------------------------------------------------------------ pairing */

    #[test]
    fn a_pairing_offer_round_trips_through_a_qr_payload() {
        let runner = Identity::generate();
        let mut broker = PairingBroker::new();
        let offer = broker.offer("wss://relay.example", "chan", runner.public_key(), NOW);

        let parsed = PairingOffer::parse(&offer.to_qr_payload()).unwrap();
        assert_eq!(parsed, offer);
        assert_eq!(&parsed.runner_public_key, runner.public_key());
    }

    #[test]
    fn a_pairing_code_works_once() {
        let runner = Identity::generate();
        let mut broker = PairingBroker::new();
        let offer = broker.offer("wss://r", "chan", runner.public_key(), NOW);

        broker.redeem(&offer.code, NOW + 1_000).unwrap();
        // A photographed QR must not pair a second device.
        assert_eq!(
            broker.redeem(&offer.code, NOW + 2_000),
            Err(CryptoError::PairingRejected("unknown or already used"))
        );
    }

    #[test]
    fn a_pairing_code_expires() {
        let runner = Identity::generate();
        let mut broker = PairingBroker::new();
        let offer = broker.offer("wss://r", "chan", runner.public_key(), NOW);

        assert_eq!(
            broker.redeem(&offer.code, NOW + PAIRING_TTL_MS),
            Err(CryptoError::PairingRejected("expired"))
        );
    }

    #[test]
    fn an_expired_code_cannot_be_retried() {
        let runner = Identity::generate();
        let mut broker = PairingBroker::new();
        let offer = broker.offer("wss://r", "chan", runner.public_key(), NOW);

        // Fails on expiry...
        assert!(broker.redeem(&offer.code, NOW + PAIRING_TTL_MS).is_err());
        // ...and is gone, so a wound-back clock does not resurrect it.
        assert_eq!(
            broker.redeem(&offer.code, NOW + 1),
            Err(CryptoError::PairingRejected("unknown or already used"))
        );
    }

    #[test]
    fn an_unknown_code_is_refused() {
        let mut broker = PairingBroker::new();
        assert!(broker.redeem("never-issued", NOW).is_err());
    }

    #[test]
    fn codes_are_unpredictable_and_long() {
        let runner = Identity::generate();
        let mut broker = PairingBroker::new();
        let codes: std::collections::HashSet<String> = (0..64)
            .map(|_| broker.offer("wss://r", "c", runner.public_key(), NOW).code)
            .collect();

        assert_eq!(codes.len(), 64, "pairing codes collided");
        // 20 bytes → 27 base64url characters.
        assert!(codes.iter().all(|code| code.len() >= 27));
    }

    #[test]
    fn unredeemed_codes_are_purged() {
        let runner = Identity::generate();
        let mut broker = PairingBroker::new();
        broker.offer("wss://r", "c", runner.public_key(), NOW);
        broker.offer("wss://r", "c", runner.public_key(), NOW);
        assert_eq!(broker.outstanding(), 2);

        assert_eq!(broker.purge_expired(NOW + PAIRING_TTL_MS + 1), 2);
        assert_eq!(broker.outstanding(), 0);
    }
}
