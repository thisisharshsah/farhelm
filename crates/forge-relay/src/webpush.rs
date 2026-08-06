//! WebPush delivery: VAPID signing (RFC 8292) and `aes128gcm` payload
//! encryption (RFC 8291 over RFC 8188).
//!
//! This is what turns "the relay knows something happened" into a phone buzzing
//! in a pocket. Without it the whole product only works while you are already
//! looking at it, which is the problem it exists to solve.
//!
//! # Why hand-rolled rather than the `web-push` crate
//!
//! The same reason `forge-crypto` uses `crypto_box` directly: the pieces here
//! are RustCrypto primitives the workspace already depends on, and the composed
//! crates in this space carry their own HTTP client, their own async runtime
//! opinion, and their own key-file handling. What is actually needed is about
//! 120 lines of well-specified glue.
//!
//! **That is only defensible because it is checked against the specification's
//! own worked example.** RFC 8291 §5 publishes a complete known-answer test —
//! fixed keys, fixed salt, fixed expected ciphertext — and [`tests`] runs it. An
//! encryption routine verified only by its own decryption routine is verified
//! against nothing; that lesson cost a day in `mobile/watch`.
//!
//! # The payload is empty, on purpose
//!
//! The relay cannot read the envelope that triggered the wake-up, so it has
//! nothing truthful to put in a notification body. It sends an encrypted but
//! *contentless* push; the device wakes, connects, decrypts locally, and renders
//! the real card. Putting the approval text in the payload would mean decrypting
//! it on the relay, which is the one property §6 promises not to break.
//!
//! The payload is still encrypted even though it is empty. That is not
//! ceremony: an unencrypted push is a push whose *existence and shape* the push
//! service sees plainly, and browsers increasingly require encryption anyway.

use std::time::Duration;

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes128Gcm, Nonce};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use hkdf::Hkdf;
use p256::ecdsa::{Signature, SigningKey, signature::Signer as _};
use p256::elliptic_curve::sec1::ToEncodedPoint as _;
use p256::{PublicKey, SecretKey};
use sha2::Sha256;

use crate::push::Subscription;

/// How long a VAPID token is good for. RFC 8292 caps this at 24 hours; 12 keeps
/// a comfortable margin against clock skew on either side.
const VAPID_LIFETIME: Duration = Duration::from_secs(12 * 60 * 60);

/// The `rs` field of the aes128gcm header. One record is enough for a payload
/// this small, and multi-record framing is complexity with no use here.
const RECORD_SIZE: u32 = 4096;

/// How long the push service should hold the message for an offline device.
///
/// Fifteen minutes, matching the approval timeout: a wake-up that arrives after
/// the request it refers to has already timed out is worse than none, because it
/// sends someone to look at something that is gone.
const TTL_SECONDS: u32 = 900;

#[derive(Debug)]
pub enum PushError {
    BadKey(String),
    BadSubscription(String),
    Encrypt,
    Endpoint(String),
    /// The push service says this subscription is gone (404/410).
    Expired,
    Http(String),
}

impl std::fmt::Display for PushError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PushError::BadKey(detail) => write!(f, "vapid key: {detail}"),
            PushError::BadSubscription(detail) => write!(f, "subscription: {detail}"),
            PushError::Encrypt => write!(f, "could not encrypt the push payload"),
            PushError::Endpoint(url) => write!(f, "not a usable push endpoint: {url}"),
            PushError::Expired => write!(f, "the subscription has expired"),
            PushError::Http(detail) => write!(f, "push delivery: {detail}"),
        }
    }
}

impl std::error::Error for PushError {}

/* -------------------------------------------------------------------- vapid */

/// The relay's application-server identity, as push services know it.
///
/// Long-lived and persisted: every subscription a browser creates is bound to
/// the public half it saw at subscribe time, so a regenerated key silently
/// orphans every device that ever paired. The relay stores it beside its own
/// state with the same `0600`-from-creation handling as the runner's key.
pub struct VapidKey {
    signing: SigningKey,
}

impl VapidKey {
    pub fn generate() -> Self {
        Self {
            signing: SigningKey::random(&mut rand_core::OsRng),
        }
    }

    pub fn from_secret_base64url(encoded: &str) -> Result<Self, PushError> {
        let bytes = B64
            .decode(encoded.trim())
            .map_err(|_| PushError::BadKey("not valid base64url".into()))?;
        let signing = SigningKey::from_slice(&bytes)
            .map_err(|_| PushError::BadKey("not a P-256 scalar".into()))?;
        Ok(Self { signing })
    }

    pub fn to_secret_base64url(&self) -> String {
        B64.encode(self.signing.to_bytes())
    }

    /// The `applicationServerKey` a browser passes to `pushManager.subscribe`.
    ///
    /// Uncompressed SEC1 (65 bytes, `0x04` prefix) — the only form the Push API
    /// accepts.
    pub fn public_key_base64url(&self) -> String {
        B64.encode(
            self.signing
                .verifying_key()
                .as_affine()
                .to_encoded_point(false)
                .as_bytes(),
        )
    }

    /// Build the `Authorization` header for one endpoint.
    ///
    /// `subject` is a `mailto:` or `https:` URL identifying whoever operates
    /// this relay; push services use it to reach a human when something is
    /// wrong, and some reject tokens without one.
    pub fn authorization(
        &self,
        endpoint: &str,
        subject: &str,
        now_secs: u64,
    ) -> Result<String, PushError> {
        let audience = audience_of(endpoint)?;
        let expiry = now_secs + VAPID_LIFETIME.as_secs();

        // The header is fixed, so it is written out rather than serialised.
        let header = B64.encode(br#"{"typ":"JWT","alg":"ES256"}"#);
        let claims = B64.encode(
            serde_json::json!({ "aud": audience, "exp": expiry, "sub": subject }).to_string(),
        );
        let signing_input = format!("{header}.{claims}");

        // ES256 is raw r‖s, 64 bytes — *not* the ASN.1 DER encoding `to_der`
        // would give. A DER signature is accepted by nothing here and rejected
        // with an opaque 401.
        let signature: Signature = self.signing.sign(signing_input.as_bytes());
        let token = format!("{signing_input}.{}", B64.encode(signature.to_bytes()));

        Ok(format!(
            "vapid t={token}, k={}",
            self.public_key_base64url()
        ))
    }
}

/// The `aud` claim: scheme and host of the endpoint, nothing more.
///
/// Including the path would bind the token to one subscription and leak which
/// device it is for into a header the push service logs.
fn audience_of(endpoint: &str) -> Result<String, PushError> {
    let (scheme, rest) = endpoint
        .split_once("://")
        .ok_or_else(|| PushError::Endpoint(endpoint.to_owned()))?;
    if scheme != "https" && scheme != "http" {
        return Err(PushError::Endpoint(endpoint.to_owned()));
    }
    let host = rest.split(['/', '?', '#']).next().unwrap_or_default();
    if host.is_empty() {
        return Err(PushError::Endpoint(endpoint.to_owned()));
    }
    Ok(format!("{scheme}://{host}"))
}

/* --------------------------------------------------------------- encryption */

/// Encrypt a payload for one subscription (RFC 8291).
///
/// The ephemeral sender keypair and the salt are fresh per message, which is
/// what makes reuse of the subscription's long-lived key safe.
pub fn encrypt(
    plaintext: &[u8],
    ua_public_base64url: &str,
    auth_secret_base64url: &str,
) -> Result<Vec<u8>, PushError> {
    let ephemeral = SecretKey::random(&mut rand_core::OsRng);
    let mut salt = [0u8; 16];
    rand_core::RngCore::fill_bytes(&mut rand_core::OsRng, &mut salt);
    encrypt_with(
        plaintext,
        ua_public_base64url,
        auth_secret_base64url,
        &ephemeral,
        &salt,
        RECORD_SIZE,
    )
}

/// [`encrypt`] with the randomness supplied, so the RFC's worked example can be
/// reproduced exactly. Never call this with a reused salt or key in anger.
fn encrypt_with(
    plaintext: &[u8],
    ua_public_base64url: &str,
    auth_secret_base64url: &str,
    ephemeral: &SecretKey,
    salt: &[u8; 16],
    record_size: u32,
) -> Result<Vec<u8>, PushError> {
    let ua_public_bytes = B64
        .decode(ua_public_base64url.trim())
        .map_err(|_| PushError::BadSubscription("p256dh is not base64url".into()))?;
    let ua_public = PublicKey::from_sec1_bytes(&ua_public_bytes)
        .map_err(|_| PushError::BadSubscription("p256dh is not a P-256 point".into()))?;
    let auth_secret = B64
        .decode(auth_secret_base64url.trim())
        .map_err(|_| PushError::BadSubscription("auth is not base64url".into()))?;

    let as_public_bytes = ephemeral.public_key().to_encoded_point(false);
    let as_public_bytes = as_public_bytes.as_bytes();

    // Step 1 (RFC 8291 §3.3): ECDH, then a first HKDF keyed by the auth secret
    // and bound to *both* public keys. Binding the keys is what stops a push
    // service from replaying one subscriber's message at another.
    let shared = p256::ecdh::diffie_hellman(ephemeral.to_nonzero_scalar(), ua_public.as_affine());

    let mut key_info = Vec::with_capacity(14 + 65 + 65);
    key_info.extend_from_slice(b"WebPush: info\0");
    key_info.extend_from_slice(&ua_public_bytes);
    key_info.extend_from_slice(as_public_bytes);

    let mut ikm = [0u8; 32];
    Hkdf::<Sha256>::new(Some(&auth_secret), shared.raw_secret_bytes())
        .expand(&key_info, &mut ikm)
        .map_err(|_| PushError::Encrypt)?;

    // Step 2 (RFC 8188 §2.2): the content encryption key and nonce, from the
    // per-message salt.
    let hkdf = Hkdf::<Sha256>::new(Some(salt), &ikm);
    let mut cek = [0u8; 16];
    let mut nonce = [0u8; 12];
    hkdf.expand(b"Content-Encoding: aes128gcm\0", &mut cek)
        .map_err(|_| PushError::Encrypt)?;
    hkdf.expand(b"Content-Encoding: nonce\0", &mut nonce)
        .map_err(|_| PushError::Encrypt)?;

    // A single record, so the delimiter is 0x02 ("last record"). Using 0x01
    // here produces something that decrypts and is then rejected as truncated.
    let mut record = Vec::with_capacity(plaintext.len() + 1);
    record.extend_from_slice(plaintext);
    record.push(0x02);

    let ciphertext = Aes128Gcm::new_from_slice(&cek)
        .map_err(|_| PushError::Encrypt)?
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: &record,
                aad: &[],
            },
        )
        .map_err(|_| PushError::Encrypt)?;

    // RFC 8188 §2.1 header: salt ‖ rs ‖ idlen ‖ keyid, where the key id is the
    // sender's ephemeral public key.
    let mut body = Vec::with_capacity(16 + 4 + 1 + as_public_bytes.len() + ciphertext.len());
    body.extend_from_slice(salt);
    body.extend_from_slice(&record_size.to_be_bytes());
    body.push(u8::try_from(as_public_bytes.len()).map_err(|_| PushError::Encrypt)?);
    body.extend_from_slice(as_public_bytes);
    body.extend_from_slice(&ciphertext);
    Ok(body)
}

/* ----------------------------------------------------------------- delivery */

/// POST one wake-up.
///
/// `Urgency: high` because every push this relay sends is a person waiting on an
/// agent; there is no low-priority category here. A 404 or 410 means the browser
/// dropped the subscription, which is normal and is reported as
/// [`PushError::Expired`] so the caller can forget it.
pub async fn deliver(
    client: &reqwest::Client,
    subscription: &Subscription,
    vapid: &VapidKey,
    subject: &str,
    payload: &[u8],
    now_secs: u64,
) -> Result<(), PushError> {
    let authorization = vapid.authorization(&subscription.endpoint, subject, now_secs)?;
    let body = encrypt(payload, &subscription.p256dh, &subscription.auth)?;

    let response = client
        .post(&subscription.endpoint)
        .header("Authorization", authorization)
        .header("Content-Encoding", "aes128gcm")
        .header("Content-Type", "application/octet-stream")
        .header("TTL", TTL_SECONDS.to_string())
        .header("Urgency", "high")
        .body(body)
        .send()
        .await
        .map_err(|err| PushError::Http(err.to_string()))?;

    let status = response.status();
    if status == reqwest::StatusCode::NOT_FOUND || status == reqwest::StatusCode::GONE {
        return Err(PushError::Expired);
    }
    if !status.is_success() {
        let detail = response.text().await.unwrap_or_default();
        return Err(PushError::Http(format!("{status}: {}", detail.trim())));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// RFC 8291 §5, "Push Message Encryption Example".
    ///
    /// This is the test that makes the module defensible. Every value is fixed
    /// by the specification, so passing it means the implementation agrees with
    /// something written by somebody else — which a round-trip against my own
    /// decryptor would not have shown.
    mod rfc8291 {
        pub const PLAINTEXT: &str = "When I grow up, I want to be a watermelon";
        pub const UA_PUBLIC: &str = "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4";
        pub const AUTH_SECRET: &str = "BTBZMqHH6r4Tts7J_aSIgg";
        pub const AS_SECRET: &str = "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw";
        pub const AS_PUBLIC: &str = "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8";
        pub const SALT: &str = "DGv6ra1nlYgDCS1FRnbzlw";
        pub const EXPECTED: &str = "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN";
    }

    fn rfc_ephemeral() -> SecretKey {
        SecretKey::from_slice(&B64.decode(rfc8291::AS_SECRET).unwrap()).unwrap()
    }

    fn rfc_salt() -> [u8; 16] {
        B64.decode(rfc8291::SALT).unwrap().try_into().unwrap()
    }

    #[test]
    fn the_rfc_worked_example_reproduces_byte_for_byte() {
        let expected = B64.decode(rfc8291::EXPECTED).unwrap();
        // The record size is part of the expected body; read it from there
        // rather than assuming, so the assertion cannot be made to pass by
        // tuning a constant.
        let record_size = u32::from_be_bytes(expected[16..20].try_into().unwrap());

        let body = encrypt_with(
            rfc8291::PLAINTEXT.as_bytes(),
            rfc8291::UA_PUBLIC,
            rfc8291::AUTH_SECRET,
            &rfc_ephemeral(),
            &rfc_salt(),
            record_size,
        )
        .unwrap();

        assert_eq!(B64.encode(&body), rfc8291::EXPECTED);
    }

    #[test]
    fn the_rfc_example_uses_the_record_size_this_module_defaults_to() {
        // If the RFC's example used something else, the assertion above would
        // still pass while production traffic used an untested path.
        let expected = B64.decode(rfc8291::EXPECTED).unwrap();
        assert_eq!(
            u32::from_be_bytes(expected[16..20].try_into().unwrap()),
            RECORD_SIZE
        );
    }

    #[test]
    fn the_header_carries_the_senders_ephemeral_key() {
        let body = encrypt_with(
            b"",
            rfc8291::UA_PUBLIC,
            rfc8291::AUTH_SECRET,
            &rfc_ephemeral(),
            &rfc_salt(),
            RECORD_SIZE,
        )
        .unwrap();

        assert_eq!(&body[0..16], &rfc_salt(), "salt");
        assert_eq!(body[20], 65, "key id length");
        assert_eq!(
            B64.encode(&body[21..86]),
            rfc8291::AS_PUBLIC,
            "the receiver cannot derive the key without this"
        );
    }

    #[test]
    fn an_empty_payload_still_produces_a_tag() {
        // The wake-up carries no content, but it is still authenticated: 1 byte
        // of delimiter plus a 16-byte GCM tag.
        let body = encrypt(b"", rfc8291::UA_PUBLIC, rfc8291::AUTH_SECRET).unwrap();
        assert_eq!(body.len(), 16 + 4 + 1 + 65 + 1 + 16);
    }

    #[test]
    fn every_message_gets_a_fresh_salt_and_key() {
        // Reusing either against the same subscription would repeat a nonce
        // under the same key, which is total loss for AES-GCM.
        let first = encrypt(b"", rfc8291::UA_PUBLIC, rfc8291::AUTH_SECRET).unwrap();
        let second = encrypt(b"", rfc8291::UA_PUBLIC, rfc8291::AUTH_SECRET).unwrap();
        assert_ne!(first[0..16], second[0..16], "salt");
        assert_ne!(first[21..86], second[21..86], "ephemeral public key");
    }

    #[test]
    fn a_malformed_client_key_is_an_error_not_a_panic() {
        assert!(matches!(
            encrypt(b"", "not base64!", rfc8291::AUTH_SECRET),
            Err(PushError::BadSubscription(_))
        ));
        assert!(matches!(
            encrypt(b"", &B64.encode([0u8; 65]), rfc8291::AUTH_SECRET),
            Err(PushError::BadSubscription(_))
        ));
    }

    /* ------------------------------------------------------------- vapid */

    #[test]
    fn the_audience_is_the_origin_and_nothing_else() {
        // The path identifies the device. Putting it in a signed claim the push
        // service logs would leak exactly what the relay is built not to hold.
        assert_eq!(
            audience_of("https://fcm.googleapis.com/fcm/send/abc123?x=1").unwrap(),
            "https://fcm.googleapis.com"
        );
        assert_eq!(
            audience_of("https://web.push.apple.com/QRSTUV").unwrap(),
            "https://web.push.apple.com"
        );
    }

    #[test]
    fn a_nonsense_endpoint_is_refused_before_anything_is_signed() {
        assert!(audience_of("not-a-url").is_err());
        assert!(audience_of("https://").is_err());
        assert!(audience_of("ftp://push.example/x").is_err());
    }

    #[test]
    fn the_token_verifies_under_the_key_it_advertises() {
        use p256::ecdsa::{VerifyingKey, signature::Verifier as _};

        let key = VapidKey::generate();
        let header = key
            .authorization(
                "https://push.example/x",
                "mailto:ops@example.com",
                1_785_369_600,
            )
            .unwrap();

        let token = header
            .strip_prefix("vapid t=")
            .and_then(|rest| rest.split_once(", k="))
            .unwrap();
        let (jwt, advertised) = token;

        let mut parts = jwt.rsplitn(2, '.');
        let signature = B64.decode(parts.next().unwrap()).unwrap();
        let signed = parts.next().unwrap();

        // `k=` is what the push service verifies with, so it has to be the key
        // that actually signed — not merely *a* key we happen to own.
        let verifying = VerifyingKey::from_sec1_bytes(&B64.decode(advertised).unwrap()).unwrap();
        let signature = Signature::from_slice(&signature).unwrap();
        assert!(verifying.verify(signed.as_bytes(), &signature).is_ok());
    }

    #[test]
    fn the_signature_is_raw_r_s_not_der() {
        let key = VapidKey::generate();
        let header = key
            .authorization("https://push.example/x", "mailto:ops@example.com", 0)
            .unwrap();
        let jwt = header
            .strip_prefix("vapid t=")
            .and_then(|rest| rest.split_once(", k="))
            .unwrap()
            .0;
        let signature = B64.decode(jwt.rsplit('.').next().unwrap()).unwrap();
        // A DER signature is 70-72 bytes and starts 0x30. Sending one gets an
        // opaque 401 from every push service.
        assert_eq!(signature.len(), 64);
    }

    #[test]
    fn the_claims_say_who_to_shout_at_and_when_to_stop_trusting_this() {
        let key = VapidKey::generate();
        let now = 1_785_369_600;
        let header = key
            .authorization("https://push.example/x", "mailto:ops@example.com", now)
            .unwrap();
        let claims_b64 = header
            .strip_prefix("vapid t=")
            .unwrap()
            .split('.')
            .nth(1)
            .unwrap();
        let claims: serde_json::Value =
            serde_json::from_slice(&B64.decode(claims_b64).unwrap()).unwrap();

        assert_eq!(claims["aud"], "https://push.example");
        assert_eq!(claims["sub"], "mailto:ops@example.com");
        let expiry = claims["exp"].as_u64().unwrap();
        assert!(expiry > now);
        // RFC 8292 caps this at 24 hours; a token past that is rejected.
        assert!(expiry - now <= 24 * 60 * 60);
    }

    #[test]
    fn a_key_survives_a_save_and_reload() {
        // Every subscription a browser makes is bound to the public key it saw,
        // so a key that did not round-trip would orphan every paired device on
        // the next relay restart.
        let original = VapidKey::generate();
        let restored = VapidKey::from_secret_base64url(&original.to_secret_base64url()).unwrap();
        assert_eq!(
            restored.public_key_base64url(),
            original.public_key_base64url()
        );
    }

    #[test]
    fn the_advertised_key_is_the_uncompressed_form_browsers_require() {
        let bytes = B64
            .decode(VapidKey::generate().public_key_base64url())
            .unwrap();
        assert_eq!(bytes.len(), 65);
        assert_eq!(bytes[0], 0x04);
    }

    #[test]
    fn a_corrupt_key_file_is_an_error_not_a_fresh_identity() {
        assert!(VapidKey::from_secret_base64url("not base64!").is_err());
        assert!(VapidKey::from_secret_base64url(&B64.encode([0u8; 8])).is_err());
    }
}
