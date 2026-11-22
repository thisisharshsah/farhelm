//! Security headers on every answer from the control plane.
//!
//! This service hands out tokens and serves the two pages where people type
//! their password: the web app and the sign-in page for MCP connectors. So
//! every answer says what a page from here may run and reach (its own scripts,
//! its own origin and the relay), that no other site may frame it, that
//! browsers must not guess content types, and that no `Referer` leaves with a
//! link. Behind HTTPS, browsers are also told to keep to HTTPS.
//!
//! The policy is built once from [`CloudConfig`], so a deployment with its own
//! relay or address needs no change here. A handler that sets one of these
//! headers itself keeps its own value.
//!
//! What the web app may not do under this policy, so that a new feature knows
//! to change it here: run inline or remote scripts, load styles or images from
//! other sites, connect anywhere but this origin and the relay, use the camera
//! or location, or be shown in a frame.

use std::sync::Arc;

use axum::extract::{Request, State};
use axum::http::{HeaderMap, HeaderName, HeaderValue, header};
use axum::middleware::Next;
use axum::response::Response;

use crate::CloudConfig;

/// How long browsers keep to HTTPS once told: a year, the usual value. Sent
/// only when this deployment's public address is HTTPS.
const HSTS_MAX_AGE_SECONDS: u64 = 365 * 24 * 60 * 60;

/// Used if the built policy cannot be a header value, which the origins and
/// hashes it is made of cannot cause; stricter rather than absent.
const FALLBACK_POLICY: &str =
    "default-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'";

/// The headers, built once at start.
#[derive(Debug, Clone)]
pub struct SecurityHeaders {
    policy: HeaderValue,
    strict_transport: Option<HeaderValue>,
}

impl SecurityHeaders {
    pub fn new(config: &CloudConfig) -> Self {
        let connect = std::iter::once("'self'".to_owned())
            .chain(relay_sources(&config.relay_url))
            .collect::<Vec<_>>()
            .join(" ");
        let policy = [
            "default-src 'self'".to_owned(),
            "script-src 'self'".to_owned(),
            // The connector's sign-in page styles itself inline; only that
            // exact block is allowed, by its hash.
            format!("style-src 'self' {}", crate::mcp::page_style_source()),
            "img-src 'self' data:".to_owned(),
            format!("connect-src {connect}"),
            "worker-src 'self'".to_owned(),
            "manifest-src 'self'".to_owned(),
            "object-src 'none'".to_owned(),
            "base-uri 'none'".to_owned(),
            "frame-ancestors 'none'".to_owned(),
        ]
        .join("; ");
        let https =
            reqwest::Url::parse(&config.public_url).is_ok_and(|url| url.scheme() == "https");
        Self {
            policy: HeaderValue::try_from(policy)
                .unwrap_or_else(|_| HeaderValue::from_static(FALLBACK_POLICY)),
            strict_transport: https.then(|| {
                HeaderValue::try_from(format!("max-age={HSTS_MAX_AGE_SECONDS}; includeSubDomains"))
                    .unwrap_or_else(|_| HeaderValue::from_static("max-age=31536000"))
            }),
        }
    }

    /// The content security policy, as sent.
    pub fn policy(&self) -> &str {
        self.policy.to_str().unwrap_or_default()
    }

    fn add_to(&self, headers: &mut HeaderMap, private: bool) {
        let set = |headers: &mut HeaderMap, name: HeaderName, value: HeaderValue| {
            headers.entry(name).or_insert(value);
        };
        set(
            headers,
            header::CONTENT_SECURITY_POLICY,
            self.policy.clone(),
        );
        set(
            headers,
            header::X_CONTENT_TYPE_OPTIONS,
            HeaderValue::from_static("nosniff"),
        );
        // For browsers that predate `frame-ancestors`.
        set(
            headers,
            header::X_FRAME_OPTIONS,
            HeaderValue::from_static("DENY"),
        );
        set(
            headers,
            header::REFERRER_POLICY,
            HeaderValue::from_static("no-referrer"),
        );
        // The web app's voice input needs the microphone; nothing needs the
        // camera or location.
        set(
            headers,
            HeaderName::from_static("permissions-policy"),
            HeaderValue::from_static("camera=(), geolocation=(), microphone=(self)"),
        );
        if let Some(value) = &self.strict_transport {
            set(headers, header::STRICT_TRANSPORT_SECURITY, value.clone());
        }
        if private {
            set(
                headers,
                header::CACHE_CONTROL,
                HeaderValue::from_static("no-store"),
            );
        }
    }
}

/// Adds the headers to every response.
pub async fn apply(
    State(headers): State<Arc<SecurityHeaders>>,
    request: Request,
    next: Next,
) -> Response {
    let private = carries_secrets(request.uri().path());
    let mut response = next.run(request).await;
    headers.add_to(response.headers_mut(), private);
    response
}

/// Answers that carry tokens or account details: the API, the connector's
/// sign-in and token exchange, and MCP itself. Never stored by a browser or
/// a cache (OAuth requires it of token responses).
fn carries_secrets(path: &str) -> bool {
    path.starts_with("/v1/") || path.starts_with("/oauth/") || path == "/mcp"
}

/// The relay's origin under both schemes: devices hold a WebSocket to it and
/// fetch its push key over HTTP(S), on the same host and port.
fn relay_sources(relay_url: &str) -> Vec<String> {
    let Ok(url) = reqwest::Url::parse(relay_url) else {
        return Vec::new();
    };
    let twin = match url.scheme() {
        "wss" => "https",
        "https" => "wss",
        "ws" => "http",
        "http" => "ws",
        _ => return Vec::new(),
    };
    let Some(host) = url.host_str() else {
        return Vec::new();
    };
    let authority = match url.port() {
        Some(port) => format!("{host}:{port}"),
        None => host.to_owned(),
    };
    vec![
        format!("{}://{authority}", url.scheme()),
        format!("{twin}://{authority}"),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(relay_url: &str, public_url: &str) -> CloudConfig {
        CloudConfig {
            relay_url: relay_url.to_owned(),
            public_url: public_url.to_owned(),
        }
    }

    #[test]
    fn the_relay_is_reachable_by_websocket_and_by_https() {
        assert_eq!(
            relay_sources("wss://relay.example.test"),
            ["wss://relay.example.test", "https://relay.example.test"]
        );
        assert_eq!(
            relay_sources("ws://127.0.0.1:7843/"),
            ["ws://127.0.0.1:7843", "http://127.0.0.1:7843"]
        );
        assert_eq!(
            relay_sources("wss://[::1]:9443/path"),
            ["wss://[::1]:9443", "https://[::1]:9443"]
        );
    }

    #[test]
    fn a_relay_address_that_is_not_one_adds_nothing() {
        assert!(relay_sources("").is_empty());
        assert!(relay_sources("ftp://relay.example.test").is_empty());
        assert!(relay_sources("relay.example.test").is_empty());
    }

    #[test]
    fn the_policy_follows_the_configuration() {
        let headers = SecurityHeaders::new(&config(
            "wss://relay.example.test",
            "https://cloud.example.test",
        ));
        let policy = headers.policy();
        assert!(
            policy.contains(
                "connect-src 'self' wss://relay.example.test https://relay.example.test;"
            )
        );
        assert!(policy.contains("script-src 'self';"));
        assert!(policy.contains("frame-ancestors 'none'"));
        assert!(!policy.contains("unsafe"), "{policy}");
        assert!(headers.strict_transport.is_some());
    }

    #[test]
    fn hsts_is_only_for_an_https_deployment() {
        let headers = SecurityHeaders::new(&config("ws://127.0.0.1:7843", "http://127.0.0.1:7844"));
        assert!(headers.strict_transport.is_none());
    }

    #[test]
    fn secrets_are_never_stored() {
        assert!(carries_secrets("/v1/auth/login"));
        assert!(carries_secrets("/oauth/token"));
        assert!(carries_secrets("/mcp"));
        assert!(!carries_secrets("/"));
        assert!(!carries_secrets("/assets/index.js"));
        assert!(!carries_secrets("/.well-known/oauth-authorization-server"));
    }
}
