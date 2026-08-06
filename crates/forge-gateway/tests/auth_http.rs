//! What the dispatch client actually puts on the wire, per credential.
//!
//! `beta_header()` is unit-tested, but a unit test cannot catch the request
//! builder attaching the wrong header, attaching it twice, or dropping it. This
//! captures the real headers from a stand-in server, because the failure being
//! guarded against is a 401 that only appears against the real endpoint:
//!
//!  - a bearer token sent as `x-api-key` is rejected even though it is valid
//!  - a bearer token without `anthropic-beta: oauth-2025-04-20` is rejected too
//!  - `anthropic-beta` set twice keeps only the last, silently losing a beta

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use axum::extract::State;
use axum::http::HeaderMap;
use axum::routing::post;
use axum::{Json, Router};
use forge_core::price::price_of;
use forge_gateway::dispatch::{
    ANTHROPIC_VERSION, AnthropicClient, Credential, FALLBACK_BETA, ModelClient, ModelRequest,
    OAUTH_BETA,
};
use forge_gateway::prompt::{StableContext, assemble};

#[derive(Default)]
struct Seen {
    headers: Mutex<Option<HeaderMap>>,
}

async fn messages(
    State(seen): State<Arc<Seen>>,
    headers: HeaderMap,
    Json(_body): Json<serde_json::Value>,
) -> Json<serde_json::Value> {
    *seen.headers.lock().unwrap() = Some(headers);
    Json(serde_json::json!({
        "model": "claude-sonnet-5",
        "content": [{ "type": "text", "text": "ok" }],
        "stop_reason": "end_turn",
    }))
}

async fn spawn(seen: Arc<Seen>) -> SocketAddr {
    let app = Router::new()
        .route("/v1/messages", post(messages))
        .with_state(seen);
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    addr
}

fn request() -> ModelRequest {
    ModelRequest {
        model: "claude-sonnet-5".into(),
        max_tokens: 64,
        effort: None,
        plan: assemble(
            &StableContext::default(),
            "hello",
            &price_of("claude-sonnet-5").unwrap(),
        ),
    }
}

/// Send one request through `client` and return the headers the server saw.
async fn headers_for(build: impl FnOnce(String) -> AnthropicClient) -> HeaderMap {
    let seen = Arc::new(Seen::default());
    let addr = spawn(Arc::clone(&seen)).await;
    let client = build(format!("http://{addr}"));

    client.complete(request()).await.unwrap();
    seen.headers.lock().unwrap().clone().expect("a request")
}

#[tokio::test]
async fn an_api_key_goes_on_x_api_key() {
    let headers = headers_for(|base| AnthropicClient::new("sk-ant-real").with_base_url(base)).await;

    assert_eq!(headers["x-api-key"], "sk-ant-real");
    assert!(
        !headers.contains_key("authorization"),
        "an API key was also sent as a bearer token"
    );
    assert_eq!(headers["anthropic-version"], ANTHROPIC_VERSION);
}

#[tokio::test]
async fn a_bearer_token_goes_on_authorization_and_never_on_x_api_key() {
    let headers = headers_for(|base| {
        AnthropicClient::with_credential(Credential::AuthToken("oat-abc".into()))
            .with_base_url(base)
    })
    .await;

    assert_eq!(headers["authorization"], "Bearer oat-abc");
    assert!(
        !headers.contains_key("x-api-key"),
        "a bearer token was sent as x-api-key — the API answers 401 to that"
    );
}

#[tokio::test]
async fn a_bearer_token_carries_the_oauth_beta_alongside_the_fallback_one() {
    let headers = headers_for(|base| {
        AnthropicClient::with_credential(Credential::AuthToken("oat-abc".into()))
            .with_base_url(base)
    })
    .await;

    // One header, both values. Two `.header("anthropic-beta", …)` calls would
    // leave only the second, and the loss is silent.
    let betas = headers
        .get_all("anthropic-beta")
        .iter()
        .map(|value| value.to_str().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(betas.len(), 1, "anthropic-beta was set more than once");
    assert!(betas[0].contains(OAUTH_BETA), "{betas:?}");
    assert!(betas[0].contains(FALLBACK_BETA), "{betas:?}");
}

#[tokio::test]
async fn an_api_key_does_not_carry_the_oauth_beta() {
    let headers = headers_for(|base| AnthropicClient::new("sk-ant-real").with_base_url(base)).await;

    assert_eq!(headers["anthropic-beta"], FALLBACK_BETA);
}

#[tokio::test]
async fn fallbacks_off_and_an_api_key_sends_no_beta_header_at_all() {
    let headers = headers_for(|base| {
        AnthropicClient::new("sk-ant-real")
            .with_base_url(base)
            .without_fallbacks()
    })
    .await;

    assert!(!headers.contains_key("anthropic-beta"));
}
