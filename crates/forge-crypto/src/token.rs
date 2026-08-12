//! Signed capability tokens — the one thing three processes have to agree on.
//!
//! The control plane ([`forge-cloud`]) is the only party that can *mint* a
//! token. The relay and the runner only ever *verify* one, which is why this is
//! ES256 (P-256 ECDSA) rather than an HMAC: a shared secret would mean every
//! relay operator holds a key that forges account tokens, and the relay is
//! explicitly the component we assume can be compromised.
//!
//! # Why a hand-rolled JWT
//!
//! It is a hundred lines against a dependency that pulls in a second base64, a
//! second time crate and a general-purpose JOSE parser we would immediately have
//! to restrict. The restriction *is* the security property here: [`verify`]
//! accepts exactly one algorithm, refuses `none` structurally (there is no
//! branch that skips the signature check), and requires `exp` — the three ways
//! JWT libraries are usually misused.
//!
//! # What a token is *not*
//!
//! It is not a way to read anything. A relay token gets you a seat on a channel;
//! everything said there is still sealed to a device key the control plane has
//! never seen. Multi-tenancy is an access-control layer *on top of* the
//! end-to-end encryption in this crate, not a replacement for it.

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use p256::ecdsa::signature::{Signer as _, Verifier as _};
use p256::ecdsa::{Signature, SigningKey, VerifyingKey};
use serde::{Deserialize, Serialize};

/// Tokens live minutes, not days: a device re-asks the control plane whenever it
/// reconnects, which is also how revocation takes effect without the relay
/// holding any state.
pub const CHANNEL_TOKEN_TTL_MS: i64 = 15 * 60 * 1_000;

/// A runner is a daemon, not a phone. It reconnects rarely and must survive the
/// control plane being down for a while, so its token is longer-lived.
pub const RUNNER_TOKEN_TTL_MS: i64 = 24 * 60 * 60 * 1_000;

/// Small, deliberately: every extra minute is a minute a revoked device keeps
/// working. Chosen to cover NTP drift on a home server, not clock neglect.
const CLOCK_SKEW_MS: i64 = 60 * 1_000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TokenError {
    Malformed(&'static str),
    /// The signature did not verify under the offered key.
    BadSignature,
    /// `exp` has passed, allowing for [`CLOCK_SKEW_MS`].
    Expired,
    /// Structurally valid and correctly signed, but not for this use.
    WrongAudience {
        expected: Audience,
        found: Audience,
    },
}

impl std::fmt::Display for TokenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TokenError::Malformed(what) => write!(f, "malformed token: {what}"),
            TokenError::BadSignature => f.write_str("token signature did not verify"),
            TokenError::Expired => f.write_str("token has expired"),
            TokenError::WrongAudience { expected, found } => write!(
                f,
                "token is for {}, not {}",
                found.as_str(),
                expected.as_str()
            ),
        }
    }
}

impl std::error::Error for TokenError {}

/// What a token may be presented to.
///
/// Separate audiences so that a token good enough to read the billing API is not
/// also good enough to join a channel. A token minted for one and replayed at
/// the other fails structurally rather than by policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Audience {
    /// The control plane's own HTTP API.
    #[serde(rename = "api")]
    Api,
    /// A seat on a relay channel.
    #[serde(rename = "relay")]
    Relay,
    /// A runner's local HTTP API.
    #[serde(rename = "runner")]
    Runner,
    /// A remote MCP server — the "custom connector" surface.
    ///
    /// Its own audience because the bearer is a *third party*: Claude holds
    /// this token, and it must reach the tool surface it was granted and
    /// nothing else. Replaying it against the control plane's own API fails
    /// structurally rather than by policy.
    #[serde(rename = "mcp")]
    Mcp,
}

impl Audience {
    pub const fn as_str(self) -> &'static str {
        match self {
            Audience::Api => "api",
            Audience::Relay => "relay",
            Audience::Runner => "runner",
            Audience::Mcp => "mcp",
        }
    }
}

/// What the bearer is, inside its organisation.
///
/// Ordered by capability so a check is a comparison rather than a match with a
/// hole in it: `role >= Role::Admin` is one expression that stays correct when a
/// role is added between existing ones.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum Role {
    /// Reads the fleet and the cost dashboard. Cannot decide an approval.
    #[serde(rename = "viewer")]
    Viewer,
    /// A daemon acting for the organisation, not a person. Publishes on its own
    /// channel and nothing else — deliberately below `Member`, because a runner
    /// must never be able to approve its own request.
    #[serde(rename = "runner")]
    Runner,
    /// Decides approvals and reviews diffs. The everyday role.
    #[serde(rename = "member")]
    Member,
    /// Adds and removes members and runners.
    #[serde(rename = "admin")]
    Admin,
    /// Everything, plus billing.
    #[serde(rename = "owner")]
    Owner,
}

impl Role {
    pub const fn as_str(self) -> &'static str {
        match self {
            Role::Viewer => "viewer",
            Role::Runner => "runner",
            Role::Member => "member",
            Role::Admin => "admin",
            Role::Owner => "owner",
        }
    }

    /// Whether this role may act on an approval or a diff.
    ///
    /// A runner is excluded on purpose: it is the thing being supervised.
    pub const fn can_decide(self) -> bool {
        matches!(self, Role::Member | Role::Admin | Role::Owner)
    }

    pub const fn can_administer(self) -> bool {
        matches!(self, Role::Admin | Role::Owner)
    }

    pub const fn can_bill(self) -> bool {
        matches!(self, Role::Owner)
    }
}

impl std::str::FromStr for Role {
    type Err = TokenError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "viewer" => Ok(Role::Viewer),
            "runner" => Ok(Role::Runner),
            "member" => Ok(Role::Member),
            "admin" => Ok(Role::Admin),
            "owner" => Ok(Role::Owner),
            _ => Err(TokenError::Malformed("unknown role")),
        }
    }
}

/// The payload. Short field names because this rides in a WebSocket URL query
/// on some platforms, where every byte is in a log line somewhere.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Claims {
    /// Who: an account id, a device id, or a runner id.
    pub sub: String,
    pub aud: Audience,
    /// Which tenant. Every row in the control plane hangs off this.
    pub org: String,
    pub role: Role,
    /// The channel this token admits the bearer to. `None` on an `api` token.
    ///
    /// A relay token that named no channel would be a token for *every* channel,
    /// so the relay refuses one — see `forge_relay`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chan: Option<String>,
    /// The plan in force when this was minted. Carried for logging and for the
    /// client's own "you are on Free" copy — never for an authorisation
    /// decision, because it is a name and names change.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<String>,
    /// Envelopes per minute this bearer may publish.
    ///
    /// A *number*, not a plan name, so the relay enforces the ceiling without
    /// linking the crate that knows what a plan is — and so re-pricing a tier
    /// takes effect on the next token rather than on the next relay deploy.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rate: Option<u32>,
    /// Unix ms.
    pub iat: i64,
    /// Unix ms. Required — [`verify`] rejects a token without one.
    pub exp: i64,
}

impl Claims {
    pub fn is_expired(&self, now_ms: i64) -> bool {
        now_ms > self.exp + CLOCK_SKEW_MS
    }
}

/* -------------------------------------------------------------------- keys */

/// The control plane's signing key. Exists in exactly one process.
pub struct TokenSigner {
    key: SigningKey,
    kid: String,
}

impl std::fmt::Debug for TokenSigner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TokenSigner")
            .field("kid", &self.kid)
            .field("key", &"<redacted>")
            .finish()
    }
}

impl TokenSigner {
    pub fn generate() -> Self {
        Self::from_key(SigningKey::random(&mut crypto_box::aead::OsRng))
    }

    fn from_key(key: SigningKey) -> Self {
        let verifying = VerifyingKey::from(&key);
        Self {
            kid: key_id(&verifying),
            key,
        }
    }

    pub fn from_secret_base64(encoded: &str) -> Result<Self, TokenError> {
        let bytes = B64
            .decode(encoded.trim())
            .map_err(|_| TokenError::Malformed("signing key is not base64url"))?;
        let key = SigningKey::from_slice(&bytes)
            .map_err(|_| TokenError::Malformed("signing key is not a P-256 scalar"))?;
        Ok(Self::from_key(key))
    }

    pub fn to_secret_base64(&self) -> String {
        B64.encode(self.key.to_bytes())
    }

    pub fn verifier(&self) -> TokenVerifier {
        TokenVerifier {
            key: VerifyingKey::from(&self.key),
            kid: self.kid.clone(),
        }
    }

    pub fn key_id(&self) -> &str {
        &self.kid
    }

    /// Mint a signed token. `now_ms` and `ttl_ms` rather than a clock, so the
    /// same code is used by tests and by the migration that backfills them.
    pub fn mint(&self, claims: &Claims) -> Result<String, TokenError> {
        let header = serde_json::json!({ "alg": "ES256", "typ": "JWT", "kid": self.kid });
        let header =
            B64.encode(serde_json::to_vec(&header).map_err(|_| TokenError::Malformed("header"))?);
        let payload =
            B64.encode(serde_json::to_vec(claims).map_err(|_| TokenError::Malformed("claims"))?);

        let signing_input = format!("{header}.{payload}");
        let signature: Signature = self.key.sign(signing_input.as_bytes());
        Ok(format!(
            "{signing_input}.{}",
            B64.encode(signature.to_bytes())
        ))
    }
}

/// The public half. What the relay holds, and what `/v1/auth/jwks` serves.
#[derive(Debug, Clone)]
pub struct TokenVerifier {
    key: VerifyingKey,
    kid: String,
}

impl TokenVerifier {
    pub fn from_public_base64(encoded: &str) -> Result<Self, TokenError> {
        let bytes = B64
            .decode(encoded.trim())
            .map_err(|_| TokenError::Malformed("public key is not base64url"))?;
        let key = VerifyingKey::from_sec1_bytes(&bytes)
            .map_err(|_| TokenError::Malformed("public key is not a P-256 point"))?;
        Ok(Self {
            kid: key_id(&key),
            key,
        })
    }

    /// SEC1 compressed, base64url. What the relay is configured with.
    pub fn to_public_base64(&self) -> String {
        B64.encode(self.key.to_encoded_point(true).as_bytes())
    }

    pub fn key_id(&self) -> &str {
        &self.kid
    }

    /// Verify a token and return its claims.
    ///
    /// Order matters and is deliberate: signature first, then expiry, then
    /// audience. Checking claims before the signature means acting on numbers an
    /// attacker chose.
    pub fn verify(
        &self,
        token: &str,
        expected: Audience,
        now_ms: i64,
    ) -> Result<Claims, TokenError> {
        let mut parts = token.trim().split('.');
        let (Some(header), Some(payload), Some(signature), None) =
            (parts.next(), parts.next(), parts.next(), parts.next())
        else {
            return Err(TokenError::Malformed("expected three dot-separated parts"));
        };

        // The header is parsed only to reject an algorithm we do not implement.
        // There is no code path in this function that skips the check below, so
        // `alg: none` cannot be honoured even if this parse were wrong.
        let header_json: serde_json::Value = serde_json::from_slice(
            &B64.decode(header)
                .map_err(|_| TokenError::Malformed("header is not base64url"))?,
        )
        .map_err(|_| TokenError::Malformed("header is not JSON"))?;
        if header_json.get("alg").and_then(|alg| alg.as_str()) != Some("ES256") {
            return Err(TokenError::Malformed("unsupported algorithm"));
        }

        let signature_bytes = B64
            .decode(signature)
            .map_err(|_| TokenError::Malformed("signature is not base64url"))?;
        let signature = Signature::from_slice(&signature_bytes)
            .map_err(|_| TokenError::Malformed("signature is not 64 bytes"))?;

        let signing_input = format!("{header}.{payload}");
        self.key
            .verify(signing_input.as_bytes(), &signature)
            .map_err(|_| TokenError::BadSignature)?;

        let claims: Claims = serde_json::from_slice(
            &B64.decode(payload)
                .map_err(|_| TokenError::Malformed("payload is not base64url"))?,
        )
        .map_err(|_| TokenError::Malformed("payload is not a claim set"))?;

        if claims.is_expired(now_ms) {
            return Err(TokenError::Expired);
        }
        if claims.aud != expected {
            return Err(TokenError::WrongAudience {
                expected,
                found: claims.aud,
            });
        }
        Ok(claims)
    }
}

/// A stable, non-secret name for a key, so a rotation can be rolled out with
/// both keys live rather than as a flag day.
fn key_id(key: &VerifyingKey) -> String {
    use sha2::{Digest as _, Sha256};
    let digest = Sha256::digest(key.to_encoded_point(true).as_bytes());
    B64.encode(&digest[..8])
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_785_369_600_000;

    fn claims(aud: Audience) -> Claims {
        Claims {
            sub: "device-1".into(),
            aud,
            org: "org-1".into(),
            role: Role::Member,
            chan: Some("forge-abc".into()),
            plan: Some("pro".into()),
            rate: Some(1_200),
            iat: NOW,
            exp: NOW + CHANNEL_TOKEN_TTL_MS,
        }
    }

    #[test]
    fn a_token_round_trips() {
        let signer = TokenSigner::generate();
        let token = signer.mint(&claims(Audience::Relay)).unwrap();

        let opened = signer
            .verifier()
            .verify(&token, Audience::Relay, NOW + 1_000)
            .unwrap();
        assert_eq!(opened, claims(Audience::Relay));
    }

    #[test]
    fn the_relay_only_needs_the_public_half() {
        let signer = TokenSigner::generate();
        let token = signer.mint(&claims(Audience::Relay)).unwrap();

        // Exactly what an operator pastes into `forge-relay --auth-key`.
        let published = signer.verifier().to_public_base64();
        let relay = TokenVerifier::from_public_base64(&published).unwrap();

        assert!(relay.verify(&token, Audience::Relay, NOW).is_ok());
        assert_eq!(relay.key_id(), signer.key_id());
    }

    #[test]
    fn another_signers_token_is_refused() {
        let real = TokenSigner::generate();
        let forger = TokenSigner::generate();
        let forged = forger.mint(&claims(Audience::Relay)).unwrap();

        assert_eq!(
            real.verifier().verify(&forged, Audience::Relay, NOW),
            Err(TokenError::BadSignature)
        );
    }

    #[test]
    fn rewriting_a_claim_breaks_the_signature() {
        let signer = TokenSigner::generate();
        let token = signer.mint(&claims(Audience::Relay)).unwrap();

        // The attack this is here to stop: escalate `role` to owner, or point
        // `chan` at somebody else's runner.
        let mut parts: Vec<&str> = token.split('.').collect();
        let mut tampered: Claims = serde_json::from_slice(&B64.decode(parts[1]).unwrap()).unwrap();
        tampered.role = Role::Owner;
        tampered.chan = Some("forge-somebody-else".into());
        let rewritten = B64.encode(serde_json::to_vec(&tampered).unwrap());
        parts[1] = &rewritten;

        assert_eq!(
            signer
                .verifier()
                .verify(&parts.join("."), Audience::Relay, NOW),
            Err(TokenError::BadSignature)
        );
    }

    #[test]
    fn an_alg_none_token_is_refused() {
        // The classic JWT failure. There is no branch here that skips
        // verification, so this fails at the header check *and* would fail at
        // the signature one.
        let signer = TokenSigner::generate();
        let header = B64.encode(br#"{"alg":"none","typ":"JWT"}"#);
        let payload = B64.encode(serde_json::to_vec(&claims(Audience::Relay)).unwrap());
        let token = format!("{header}.{payload}.");

        assert_eq!(
            signer.verifier().verify(&token, Audience::Relay, NOW),
            Err(TokenError::Malformed("unsupported algorithm"))
        );
    }

    #[test]
    fn an_expired_token_is_refused() {
        let signer = TokenSigner::generate();
        let token = signer.mint(&claims(Audience::Relay)).unwrap();

        assert_eq!(
            signer.verifier().verify(
                &token,
                Audience::Relay,
                NOW + CHANNEL_TOKEN_TTL_MS + CLOCK_SKEW_MS + 1
            ),
            Err(TokenError::Expired)
        );
        // ...but survives a minute of clock drift, which a home server has.
        assert!(
            signer
                .verifier()
                .verify(&token, Audience::Relay, NOW + CHANNEL_TOKEN_TTL_MS + 1)
                .is_ok()
        );
    }

    #[test]
    fn a_token_for_the_api_cannot_be_replayed_at_the_relay() {
        let signer = TokenSigner::generate();
        let token = signer.mint(&claims(Audience::Api)).unwrap();

        assert_eq!(
            signer.verifier().verify(&token, Audience::Relay, NOW),
            Err(TokenError::WrongAudience {
                expected: Audience::Relay,
                found: Audience::Api,
            })
        );
    }

    #[test]
    fn a_malformed_token_is_an_error_not_a_panic() {
        let verifier = TokenSigner::generate().verifier();
        for bad in ["", "a.b", "a.b.c.d", "!!!.???.###", "....."] {
            assert!(verifier.verify(bad, Audience::Relay, NOW).is_err());
        }
    }

    #[test]
    fn a_signing_key_survives_a_save_and_load() {
        let original = TokenSigner::generate();
        let restored = TokenSigner::from_secret_base64(&original.to_secret_base64()).unwrap();

        assert_eq!(restored.key_id(), original.key_id());
        let token = restored.mint(&claims(Audience::Relay)).unwrap();
        assert!(
            original
                .verifier()
                .verify(&token, Audience::Relay, NOW)
                .is_ok()
        );
    }

    #[test]
    fn a_signer_never_prints_its_key() {
        let signer = TokenSigner::generate();
        let rendered = format!("{signer:?}");
        assert!(rendered.contains("redacted"));
        assert!(!rendered.contains(&signer.to_secret_base64()));
    }

    #[test]
    fn roles_are_ordered_by_capability() {
        assert!(Role::Owner > Role::Admin);
        assert!(Role::Admin > Role::Member);
        assert!(Role::Member > Role::Runner);
        assert!(Role::Runner > Role::Viewer);

        // The one that matters: a runner cannot approve its own request.
        assert!(!Role::Runner.can_decide());
        assert!(Role::Member.can_decide());
        assert!(!Role::Admin.can_bill());
        assert!(Role::Owner.can_bill());
    }
}
