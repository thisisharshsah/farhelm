//! The OAuth 2.1 authorization server Claude discovers and registers with.
//!
//! This is what makes the connector dialog's two "Advanced settings" fields
//! optional. Claude finds the authorization server from metadata, **registers
//! itself** (RFC 7591 dynamic client registration), and runs an authorization
//! code flow with PKCE. Nobody types a client id or a secret anywhere.
//!
//! # The discovery chain
//!
//! ```text
//!   1. POST /mcp with no token          → 401 + WWW-Authenticate naming (2)
//!   2. GET /.well-known/oauth-protected-resource → names the authorization server
//!   3. GET /.well-known/oauth-authorization-server → registration/authorize/token
//!   4. POST /register                    → a client id, minted on the spot
//!   5. GET /authorize  → sign in → consent → redirect with a code
//!   6. POST /token     → an access token
//! ```
//!
//! Step 1 is the one people skip. Without a `WWW-Authenticate` header carrying
//! `resource_metadata`, Claude has nothing to discover *from* and the connector
//! simply fails to connect with no explanation.
//!
//! # Why PKCE is required rather than optional
//!
//! OAuth 2.1 makes PKCE mandatory for every client, and a public client — which
//! a dynamically-registered one is — has no secret to fall back on. Without it,
//! an authorization code intercepted on the redirect is enough to mint a token.
//! [`verify_challenge`] is the check that makes interception useless.

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use serde::{Deserialize, Serialize};

/// How long an authorization code is good for.
///
/// Codes are single-use and redeemed within seconds of being issued by a client
/// that is already waiting. A minute is generous; anything longer is a window
/// for a code that leaked into a redirect log.
pub const CODE_TTL_MS: i64 = 60 * 1_000;

/// Access tokens for MCP. Short, because a connector reconnects freely and the
/// refresh token is what carries the long-lived grant.
pub const ACCESS_TOKEN_TTL_MS: i64 = 60 * 60 * 1_000;

/* --------------------------------------------------------------- discovery */

/// RFC 9728 — what a *resource* server publishes so a client can find its
/// authorization server.
pub fn protected_resource_metadata(resource: &str, issuer: &str) -> serde_json::Value {
    serde_json::json!({
        "resource": resource,
        "authorization_servers": [issuer],
        "bearer_methods_supported": ["header"],
        "scopes_supported": ["mcp"],
    })
}

/// RFC 8414 — what the *authorization* server publishes about itself.
pub fn authorization_server_metadata(issuer: &str) -> serde_json::Value {
    serde_json::json!({
        "issuer": issuer,
        "authorization_endpoint": format!("{issuer}/oauth/authorize"),
        "token_endpoint": format!("{issuer}/oauth/token"),
        // Present, and load-bearing: its absence is what forces a human to fill
        // in a client id and secret by hand.
        "registration_endpoint": format!("{issuer}/oauth/register"),
        "response_types_supported": ["code"],
        "grant_types_supported": ["authorization_code", "refresh_token"],
        // S256 only. `plain` is in the RFC and provides no protection at all —
        // offering it lets a client opt out of the thing PKCE is for.
        "code_challenge_methods_supported": ["S256"],
        "token_endpoint_auth_methods_supported": ["none", "client_secret_post"],
        "scopes_supported": ["mcp"],
    })
}

/// The header that starts the whole discovery chain.
///
/// Returned on a 401 from the MCP endpoint. `resource_metadata` is the pointer
/// Claude follows; without it there is nothing to discover and the connector
/// fails with no way to tell why.
pub fn www_authenticate(resource_metadata_url: &str) -> String {
    format!(r#"Bearer realm="relayforge", resource_metadata="{resource_metadata_url}""#)
}

/* ------------------------------------------------------------ registration */

/// What a client sends to `/oauth/register`.
#[derive(Debug, Clone, Deserialize)]
pub struct RegistrationRequest {
    #[serde(default)]
    pub client_name: Option<String>,
    #[serde(default)]
    pub redirect_uris: Vec<String>,
    #[serde(default)]
    pub grant_types: Vec<String>,
    #[serde(default)]
    pub token_endpoint_auth_method: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct RegisteredClient {
    pub client_id: String,
    pub client_name: String,
    pub redirect_uris: Vec<String>,
    /// Unix ms. Zero means "does not expire", per RFC 7591.
    pub client_id_issued_at: i64,
    pub token_endpoint_auth_method: &'static str,
    pub grant_types: Vec<&'static str>,
    pub response_types: Vec<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RegistrationError {
    /// No redirect URI, or one that cannot be a redirect target.
    InvalidRedirectUri(String),
}

impl std::fmt::Display for RegistrationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RegistrationError::InvalidRedirectUri(why) => write!(f, "{why}"),
        }
    }
}

/// Register a client.
///
/// Open registration, which is what the specification intends here: the client
/// id is a public identifier, not a credential, and the security of the flow
/// rests on the redirect URI and PKCE rather than on who was allowed to
/// register. What is *not* open is the redirect target — see [`check_redirect`].
pub fn register(
    request: &RegistrationRequest,
    client_id: String,
    now_ms: i64,
) -> Result<RegisteredClient, RegistrationError> {
    if request.redirect_uris.is_empty() {
        return Err(RegistrationError::InvalidRedirectUri(
            "at least one redirect_uri is required".into(),
        ));
    }
    for uri in &request.redirect_uris {
        check_redirect(uri)?;
    }

    Ok(RegisteredClient {
        client_id,
        client_name: request
            .client_name
            .clone()
            .unwrap_or_else(|| "An MCP client".to_owned()),
        redirect_uris: request.redirect_uris.clone(),
        client_id_issued_at: now_ms,
        // A dynamically-registered client is public: it runs where its user can
        // read it, so a secret would be a secret in name only. PKCE is what
        // actually protects the exchange.
        token_endpoint_auth_method: "none",
        grant_types: vec!["authorization_code", "refresh_token"],
        response_types: vec!["code"],
    })
}

/// Is this a redirect target we will send a code to?
///
/// HTTPS only, with an exception for loopback so a developer can test against a
/// local client. The rule that matters is the one against **open redirects**: a
/// URI with a fragment, or a non-http scheme, can be used to smuggle a code
/// somewhere the user did not agree to.
pub fn check_redirect(uri: &str) -> Result<(), RegistrationError> {
    let refuse = |why: &str| Err(RegistrationError::InvalidRedirectUri(why.to_owned()));

    if uri.contains('#') {
        return refuse("a redirect_uri may not contain a fragment");
    }
    if uri.starts_with("https://") {
        return Ok(());
    }
    if uri.starts_with("http://127.0.0.1")
        || uri.starts_with("http://localhost")
        || uri.starts_with("http://[::1]")
    {
        return Ok(());
    }
    refuse("a redirect_uri must be https, or http on loopback")
}

/* -------------------------------------------------------------------- PKCE */

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PkceError {
    /// The method was absent, or was `plain`.
    UnsupportedMethod,
    /// The verifier did not hash to the challenge.
    Mismatch,
    /// Outside RFC 7636's 43–128 characters.
    MalformedVerifier,
}

impl std::fmt::Display for PkceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PkceError::UnsupportedMethod => {
                f.write_str("only the S256 challenge method is accepted")
            }
            PkceError::Mismatch => f.write_str("code_verifier does not match code_challenge"),
            PkceError::MalformedVerifier => {
                f.write_str("code_verifier must be 43 to 128 characters")
            }
        }
    }
}

/// Check a `code_verifier` against the `code_challenge` stored at authorize
/// time.
///
/// This is the whole of PKCE, and it is why an intercepted authorization code
/// is worthless: whoever redeems it must also present the secret that produced
/// the challenge, which never crossed the network.
pub fn verify_challenge(verifier: &str, challenge: &str, method: &str) -> Result<(), PkceError> {
    if method != "S256" {
        return Err(PkceError::UnsupportedMethod);
    }
    if verifier.len() < 43 || verifier.len() > 128 {
        return Err(PkceError::MalformedVerifier);
    }

    use sha2::{Digest as _, Sha256};
    let computed = B64.encode(Sha256::digest(verifier.as_bytes()));

    // Constant time: a byte-by-byte comparison that returns early leaks how
    // much of the challenge was guessed correctly.
    if computed.len() != challenge.len() {
        return Err(PkceError::Mismatch);
    }
    let equal = computed
        .bytes()
        .zip(challenge.bytes())
        .fold(0u8, |acc, (a, b)| acc | (a ^ b))
        == 0;

    if equal {
        Ok(())
    } else {
        Err(PkceError::Mismatch)
    }
}

/* ----------------------------------------------------------- authorization */

/// An authorization request, parked between `/authorize` and `/token`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingAuthorization {
    pub client_id: String,
    pub redirect_uri: String,
    pub code_challenge: String,
    pub code_challenge_method: String,
    /// Opaque client state, echoed back on the redirect.
    pub state: Option<String>,
    /// Which account approved it. Filled in after the user signs in.
    pub account_id: String,
    pub expires_at: i64,
    /// The resource this code may be exchanged for a token for (RFC 8707).
    pub resource: Option<String>,
}

impl PendingAuthorization {
    pub fn is_expired(&self, now_ms: i64) -> bool {
        now_ms >= self.expires_at
    }
}

/// Build the redirect back to the client after consent.
///
/// `state` is echoed verbatim — it is the client's CSRF defence and mangling it
/// silently breaks the flow.
pub fn redirect_with_code(redirect_uri: &str, code: &str, state: Option<&str>) -> String {
    let joiner = if redirect_uri.contains('?') { '&' } else { '?' };
    let mut url = format!("{redirect_uri}{joiner}code={}", urlencode(code));
    if let Some(state) = state {
        url.push_str(&format!("&state={}", urlencode(state)));
    }
    url
}

/// Build the redirect for a refusal, so the client learns why rather than
/// hanging on a callback that never arrives.
pub fn redirect_with_error(redirect_uri: &str, error: &str, state: Option<&str>) -> String {
    let joiner = if redirect_uri.contains('?') { '&' } else { '?' };
    let mut url = format!("{redirect_uri}{joiner}error={}", urlencode(error));
    if let Some(state) = state {
        url.push_str(&format!("&state={}", urlencode(state)));
    }
    url
}

/// Percent-encode everything outside the unreserved set.
///
/// Deliberately conservative: an authorization code is base64url, which is
/// already safe, but `state` is arbitrary client data and a stray `&` in it
/// would forge a query parameter.
fn urlencode(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for byte in raw.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char)
            }
            other => out.push_str(&format!("%{other:02X}")),
        }
    }
    out
}

/// 256 bits, base64url. Used for codes, client ids, and refresh tokens.
pub fn random_id() -> String {
    use rand_core::RngCore as _;
    let mut bytes = [0u8; 32];
    rand_core::OsRng.fill_bytes(&mut bytes);
    B64.encode(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_785_369_600_000;

    /// A verifier and the challenge it produces, computed the way a client does.
    fn pkce_pair() -> (String, String) {
        use sha2::{Digest as _, Sha256};
        let verifier = "a".repeat(64);
        let challenge = B64.encode(Sha256::digest(verifier.as_bytes()));
        (verifier, challenge)
    }

    #[test]
    fn discovery_metadata_names_the_registration_endpoint() {
        // Its absence is exactly what forces a human to paste a client id and
        // secret into the connector dialog's Advanced fields.
        let metadata = authorization_server_metadata("https://farhelm.aurovie.com");
        assert_eq!(
            metadata["registration_endpoint"],
            "https://farhelm.aurovie.com/oauth/register"
        );
        assert_eq!(metadata["code_challenge_methods_supported"][0], "S256");
    }

    #[test]
    fn plain_pkce_is_not_offered() {
        // `plain` is in the RFC and provides no protection — offering it lets a
        // client opt out of the only thing protecting the code.
        let metadata = authorization_server_metadata("https://x");
        let methods = metadata["code_challenge_methods_supported"]
            .as_array()
            .unwrap();
        assert_eq!(methods.len(), 1);
        assert_eq!(methods[0], "S256");
    }

    #[test]
    fn the_challenge_header_points_at_the_resource_metadata() {
        // The first link in the discovery chain. Without it Claude has nowhere
        // to start and the connector fails silently.
        let header = www_authenticate("https://x/.well-known/oauth-protected-resource");
        assert!(header.starts_with("Bearer "));
        assert!(
            header
                .contains(r#"resource_metadata="https://x/.well-known/oauth-protected-resource""#)
        );
    }

    #[test]
    fn protected_resource_metadata_names_its_authorization_server() {
        let metadata = protected_resource_metadata(
            "https://mac.example.com/mcp",
            "https://farhelm.aurovie.com",
        );
        assert_eq!(metadata["resource"], "https://mac.example.com/mcp");
        assert_eq!(
            metadata["authorization_servers"][0],
            "https://farhelm.aurovie.com"
        );
    }

    #[test]
    fn registration_mints_a_public_client() {
        let request = RegistrationRequest {
            client_name: Some("Claude".into()),
            redirect_uris: vec!["https://claude.ai/api/mcp/auth_callback".into()],
            grant_types: vec![],
            token_endpoint_auth_method: None,
        };
        let client = register(&request, "cid".into(), NOW).unwrap();

        assert_eq!(client.token_endpoint_auth_method, "none");
        assert_eq!(client.client_name, "Claude");
        assert_eq!(client.client_id_issued_at, NOW);
    }

    #[test]
    fn registration_without_a_redirect_uri_is_refused() {
        let request = RegistrationRequest {
            client_name: None,
            redirect_uris: vec![],
            grant_types: vec![],
            token_endpoint_auth_method: None,
        };
        assert!(register(&request, "cid".into(), NOW).is_err());
    }

    #[test]
    fn only_https_and_loopback_may_receive_a_code() {
        assert!(check_redirect("https://claude.ai/api/mcp/auth_callback").is_ok());
        assert!(check_redirect("http://127.0.0.1:8080/cb").is_ok());
        assert!(check_redirect("http://localhost:3000/cb").is_ok());

        // Plain http to a real host would put a code on the wire in clear.
        assert!(check_redirect("http://evil.example.com/cb").is_err());
        // A fragment is how an open redirect smuggles a code elsewhere.
        assert!(check_redirect("https://claude.ai/cb#/../evil").is_err());
        assert!(check_redirect("javascript:alert(1)").is_err());
    }

    #[test]
    fn a_matching_verifier_passes() {
        let (verifier, challenge) = pkce_pair();
        assert!(verify_challenge(&verifier, &challenge, "S256").is_ok());
    }

    #[test]
    fn a_stolen_code_is_useless_without_the_verifier() {
        // The property PKCE exists for, stated as a test.
        let (_verifier, challenge) = pkce_pair();
        let attacker = "b".repeat(64);
        assert_eq!(
            verify_challenge(&attacker, &challenge, "S256"),
            Err(PkceError::Mismatch)
        );
    }

    #[test]
    fn plain_is_refused_even_when_the_values_match() {
        // With `plain` the challenge *is* the verifier, so anyone holding the
        // authorization request can satisfy it. Refuse the method outright.
        let verifier = "a".repeat(64);
        assert_eq!(
            verify_challenge(&verifier, &verifier, "plain"),
            Err(PkceError::UnsupportedMethod)
        );
    }

    #[test]
    fn a_verifier_outside_the_legal_length_is_refused() {
        let (_, challenge) = pkce_pair();
        assert_eq!(
            verify_challenge("short", &challenge, "S256"),
            Err(PkceError::MalformedVerifier)
        );
        assert_eq!(
            verify_challenge(&"a".repeat(129), &challenge, "S256"),
            Err(PkceError::MalformedVerifier)
        );
    }

    #[test]
    fn a_code_expires() {
        let pending = PendingAuthorization {
            client_id: "cid".into(),
            redirect_uri: "https://claude.ai/cb".into(),
            code_challenge: "c".into(),
            code_challenge_method: "S256".into(),
            state: None,
            account_id: "acc_1".into(),
            expires_at: NOW + CODE_TTL_MS,
            resource: None,
        };
        assert!(!pending.is_expired(NOW));
        assert!(pending.is_expired(NOW + CODE_TTL_MS));
    }

    #[test]
    fn the_redirect_carries_the_code_and_echoes_state() {
        let url = redirect_with_code("https://claude.ai/cb", "the-code", Some("xyz"));
        assert_eq!(url, "https://claude.ai/cb?code=the-code&state=xyz");
    }

    #[test]
    fn a_redirect_uri_that_already_has_a_query_is_appended_to() {
        let url = redirect_with_code("https://claude.ai/cb?a=1", "c", None);
        assert_eq!(url, "https://claude.ai/cb?a=1&code=c");
    }

    #[test]
    fn state_cannot_forge_a_query_parameter() {
        // Arbitrary client data lands in a URL; an unescaped `&` in it would
        // let a client inject parameters into its own callback.
        let url = redirect_with_code("https://claude.ai/cb", "c", Some("a&code=evil"));

        // The injected text survives as data, escaped — the `&` and `=` that
        // would have made it a second parameter are percent-encoded.
        assert!(url.ends_with("&state=a%26code%3Devil"));
        // …so there is still exactly one real `code` parameter, and it is ours.
        assert_eq!(url.matches("code=").count(), 1);
        assert!(url.contains("?code=c&"));
    }

    #[test]
    fn a_refusal_redirects_rather_than_hanging() {
        let url = redirect_with_error("https://claude.ai/cb", "access_denied", Some("xyz"));
        assert_eq!(url, "https://claude.ai/cb?error=access_denied&state=xyz");
    }

    #[test]
    fn ids_do_not_repeat() {
        let ids: std::collections::HashSet<String> = (0..256).map(|_| random_id()).collect();
        assert_eq!(ids.len(), 256);
    }
}
