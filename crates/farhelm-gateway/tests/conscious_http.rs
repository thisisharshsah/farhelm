//! Conscious, the owner's private gateway, over real HTTP against a stand-in.
//!
//! Conscious speaks the same Messages API, so it is the same client with four
//! differences, each checked on the wire here because each fails only against
//! the real thing: the URL already names the project, the component rides on
//! `X-Conscious-Client`, `CONSCIOUS_MODEL` replaces the routed name, and there
//! is no Batch API — so a deferrable call runs live and says so, and a local
//! model is never billed at Anthropic's rates.
//!
//! The last test talks to the live gateway and is `#[ignore]`d: run it with the
//! three `CONSCIOUS_*` variables exported and `--ignored`.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use axum::extract::State;
use axum::http::{HeaderMap, Uri};
use axum::routing::post;
use axum::{Json, Router};
use farhelm_app::store::prelude::*;
use farhelm_domain::price::price_of;
use farhelm_gateway::dispatch::{AnthropicClient, ModelClient, ModelRequest};
use farhelm_gateway::prompt::{StableContext, assemble};
use farhelm_gateway::{CompleteRequest, Gateway, GatewayConfig, Served};
use farhelm_proto::types::{Agent, Machine, Repo, Session, SessionStatus, TaskType};
use farhelm_sqlite::SqliteStore;

const NOW: i64 = 1_785_369_600_000;

#[derive(Default)]
struct Seen {
    path: Mutex<Option<String>>,
    headers: Mutex<Option<HeaderMap>>,
    body: Mutex<Option<serde_json::Value>>,
}

async fn messages(
    State(seen): State<Arc<Seen>>,
    uri: Uri,
    headers: HeaderMap,
    Json(body): Json<serde_json::Value>,
) -> Json<serde_json::Value> {
    *seen.path.lock().unwrap() = Some(uri.path().to_owned());
    *seen.headers.lock().unwrap() = Some(headers);
    *seen.body.lock().unwrap() = Some(body);
    // What Conscious does with an unknown name: answer on its default model,
    // and say so in `model`.
    Json(serde_json::json!({
        "model": "gpt-oss-20b",
        "content": [{ "type": "text", "text": "ok" }],
        "stop_reason": "end_turn",
        "usage": { "input_tokens": 1_000_000, "output_tokens": 1_000_000 },
    }))
}

/// A stand-in serving `/p/farhelm/v1/messages`, as Conscious does.
async fn spawn(seen: Arc<Seen>) -> String {
    let app = Router::new()
        .route("/p/farhelm/v1/messages", post(messages))
        .with_state(seen);
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let addr: SocketAddr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    format!("http://{addr}/p/farhelm")
}

fn request(purpose: Option<TaskType>) -> ModelRequest {
    ModelRequest {
        model: "claude-sonnet-5".into(),
        max_tokens: 64,
        effort: None,
        plan: assemble(
            &StableContext::default(),
            "hello",
            &price_of("claude-sonnet-5").unwrap(),
        ),
        purpose,
    }
}

fn store() -> SqliteStore {
    let store = SqliteStore::open_in_memory().unwrap();
    store
        .upsert_machine(&Machine {
            id: "m1".into(),
            name: "laptop".into(),
            pubkey: "k".into(),
            last_seen_at: Some(NOW),
            created_at: NOW,
        })
        .unwrap();
    store
        .upsert_repo(&Repo {
            id: "r1".into(),
            machine_id: "m1".into(),
            path: "/srv/api".into(),
            name: "api".into(),
            budget_usd: None,
        })
        .unwrap();
    store
        .upsert_session(&Session {
            id: "s1".into(),
            repo_id: "r1".into(),
            agent: Agent::ClaudeCode,
            tmux_target: None,
            status: SessionStatus::Running,
            plan_id: None,
            budget_usd: None,
            spent_usd: 0.0,
            started_at: NOW,
            ended_at: None,
            agent_session_id: None,
        })
        .unwrap();
    store
}

#[tokio::test]
async fn a_call_goes_to_the_project_url_with_its_key_and_component() {
    let seen = Arc::new(Seen::default());
    let base = spawn(Arc::clone(&seen)).await;
    // A trailing slash, as a pasted URL often has.
    let client = AnthropicClient::conscious(
        format!("{base}/"),
        Some("cs-key".into()),
        Some("gpt-oss-20b".into()),
    );

    let response = client
        .complete(request(Some(TaskType::Edit)))
        .await
        .unwrap();

    assert_eq!(
        seen.path.lock().unwrap().as_deref(),
        Some("/p/farhelm/v1/messages")
    );
    let headers = seen.headers.lock().unwrap().clone().unwrap();
    assert_eq!(headers["x-api-key"], "cs-key");
    assert_eq!(headers["x-conscious-client"], "farhelm/edit");
    assert!(headers.contains_key("anthropic-version"));
    // Fallbacks are an Anthropic beta; Conscious gets neither half of it.
    assert!(!headers.contains_key("anthropic-beta"));
    let body = seen.body.lock().unwrap().clone().unwrap();
    assert_eq!(body["model"], "gpt-oss-20b", "CONSCIOUS_MODEL replaces it");
    assert!(body.get("fallbacks").is_none());

    assert_eq!(response.text, "ok");
    assert_eq!(response.model, "local/gpt-oss-20b");
}

#[tokio::test]
async fn without_a_model_or_purpose_the_name_goes_as_is_tagged_dispatch() {
    let seen = Arc::new(Seen::default());
    let base = spawn(Arc::clone(&seen)).await;
    let client = AnthropicClient::conscious(base, Some("cs-key".into()), None);

    client.complete(request(None)).await.unwrap();

    let headers = seen.headers.lock().unwrap().clone().unwrap();
    assert_eq!(headers["x-conscious-client"], "farhelm/dispatch");
    let body = seen.body.lock().unwrap().clone().unwrap();
    assert_eq!(body["model"], "claude-sonnet-5", "Conscious maps the name");
}

#[tokio::test]
async fn deferrable_work_runs_live_and_says_so_because_conscious_cannot_batch() {
    let seen = Arc::new(Seen::default());
    let base = spawn(Arc::clone(&seen)).await;
    // Batching switched *on*: the provider, not the config, is what refuses it.
    let config = GatewayConfig {
        batch_enabled: true,
        ..GatewayConfig::default()
    };
    let gateway = Gateway::new(
        store(),
        AnthropicClient::conscious(base, Some("cs-key".into()), Some("gpt-oss-20b".into())),
        config,
    );
    let mut call = CompleteRequest::new("s1", TaskType::Summarize, "nightly summary");
    call.deferrable = true;

    let response = gateway.complete(call).await.unwrap();

    assert_eq!(response.trace.served, Served::Live);
    assert!(response.trace.batch_downgraded);
    assert!(response.batch_item_id.is_none());
    assert_eq!(response.text, "ok");
    assert_eq!(
        seen.headers.lock().unwrap().clone().unwrap()["x-conscious-client"],
        "farhelm/summarize"
    );
    // A million tokens each way would be dollars on any Anthropic model.
    assert_eq!(response.model, "local/gpt-oss-20b");
    assert_eq!(response.cost_usd, 0.0, "a local model is not billed");
}

/// Against the running gateway. Needs `CONSCIOUS_API_URL`, `CONSCIOUS_API_KEY`
/// and optionally `CONSCIOUS_MODEL` exported.
#[tokio::test]
#[ignore = "talks to the live Conscious gateway"]
async fn live_conscious_answers_through_the_gateway() {
    let client = AnthropicClient::from_env().expect("CONSCIOUS_* exported");
    assert_eq!(client.provider_name(), "conscious");
    let gateway = Gateway::new(store(), client, GatewayConfig::default());
    let call = CompleteRequest::new("s1", TaskType::Triage, "Reply with the single word: ready");

    let response = gateway.complete(call).await.unwrap();

    println!(
        "model={} text={:?} usage={:?} cost_usd={}",
        response.model, response.text, response.usage, response.cost_usd
    );
    assert!(response.served_live());
    assert!(response.model.starts_with("local/"));
    assert_eq!(response.cost_usd, 0.0);
    assert!(response.usage.input_tokens > 0);
}
