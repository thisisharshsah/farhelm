//! The Batches API client, over real HTTP against a stand-in provider.
//!
//! `batch.rs`'s unit tests use a fake `BatchClient`, so they check the queue's
//! logic but never the wire. This checks the wire: that the JSON this crate
//! submits is the shape the API documents, and that it can read back the JSONL
//! results format — including that the token counts survive the round trip and
//! land in the ledger at half rates.
//!
//! What it still cannot show is whether the *real* endpoint agrees. No API key
//! here. The shapes come from the documented Batches API; treat the first real
//! flush as the proving run.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use axum::extract::State;
use axum::routing::{get, post};
use axum::{Json, Router};
use forge_core::store::{SqliteStore, Store};
use forge_core::types::{
    Agent, BatchItem, BatchStatus, Machine, Repo, Session, SessionStatus, TaskType,
};
use forge_gateway::batch::{AnthropicBatchClient, BatchQueue};

const NOW: i64 = 1_785_369_600_000;
/// One million input tokens on Haiku 4.5 — $1.00 live, $0.50 batched.
const MILLION: u64 = 1_000_000;

#[derive(Default)]
struct Provider {
    /// The custom ids of everything submitted, in order.
    submitted: Mutex<Vec<String>>,
    /// The params of the first request, so their shape can be asserted.
    first_params: Mutex<Option<serde_json::Value>>,
}

async fn create(
    State(provider): State<Arc<Provider>>,
    Json(body): Json<serde_json::Value>,
) -> Json<serde_json::Value> {
    let requests = body["requests"].as_array().cloned().unwrap_or_default();
    *provider.first_params.lock().unwrap() = requests.first().map(|r| r["params"].clone());
    *provider.submitted.lock().unwrap() = requests
        .iter()
        .filter_map(|r| r["custom_id"].as_str().map(str::to_owned))
        .collect();

    Json(serde_json::json!({
        "id": "batch_test",
        "processing_status": "ended",
    }))
}

async fn state() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "id": "batch_test", "processing_status": "ended" }))
}

/// The results endpoint answers JSONL, not JSON — one object per line.
async fn results(State(provider): State<Arc<Provider>>) -> String {
    provider
        .submitted
        .lock()
        .unwrap()
        .iter()
        .map(|custom_id| {
            serde_json::json!({
                "custom_id": custom_id,
                "result": {
                    "type": "succeeded",
                    "message": {
                        "content": [{ "type": "text", "text": "batched answer" }],
                        "usage": {
                            "input_tokens": MILLION,
                            "output_tokens": 0,
                            "cache_creation_input_tokens": 0,
                            "cache_read_input_tokens": 0,
                        }
                    }
                }
            })
            .to_string()
        })
        .collect::<Vec<_>>()
        .join("\n")
}

async fn spawn_provider(provider: Arc<Provider>) -> SocketAddr {
    let app = Router::new()
        .route("/v1/messages/batches", post(create))
        .route("/v1/messages/batches/{id}", get(state))
        .route("/v1/messages/batches/{id}/results", get(results))
        .with_state(provider);
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    addr
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

fn enqueue(store: &SqliteStore, index: usize) {
    store
        .enqueue_batch_item(&BatchItem {
            id: format!("b{index}"),
            session_id: "s1".into(),
            custom_id: format!("forge-b{index}"),
            task_type: TaskType::Summarize,
            model: "claude-haiku-4-5".into(),
            request_json: r#"{"model":"claude-haiku-4-5","max_tokens":1024,
                              "messages":[{"role":"user","content":"summarise"}]}"#
                .into(),
            batch_id: None,
            status: BatchStatus::Queued,
            response_text: None,
            error: None,
            queued_at: NOW,
            submitted_at: None,
            settled_at: None,
        })
        .unwrap();
}

#[tokio::test]
async fn queued_work_goes_out_and_comes_back_billed_at_half_rates() {
    let provider = Arc::new(Provider::default());
    let addr = spawn_provider(Arc::clone(&provider)).await;

    let store = store();
    enqueue(&store, 0);
    enqueue(&store, 1);

    let queue = BatchQueue::new(
        &store,
        AnthropicBatchClient::new("test-key", format!("http://{addr}")),
    );

    let flushed = queue.flush(NOW).await.unwrap();
    assert_eq!(flushed.submitted, 2);
    assert_eq!(flushed.batch_id.as_deref(), Some("batch_test"));
    assert_eq!(
        *provider.submitted.lock().unwrap(),
        ["forge-b0", "forge-b1"],
        "the provider received both, under the ids we can match results by"
    );

    let collected = queue.collect(NOW + 3_600_000).await.unwrap();
    assert_eq!(collected.settled, 2);
    assert_eq!(collected.succeeded, 2);

    // Two million input tokens on Haiku 4.5 is $2.00 live. The entire point of
    // C6 is that this number is half of that.
    assert!(
        (collected.cost_usd - 1.00).abs() < 1e-6,
        "expected $1.00 at batch rates, got ${:.4}",
        collected.cost_usd
    );
    assert!((store.session_budget("s1").unwrap().spent_usd - 1.00).abs() < 1e-6);

    let item = store.get_batch_item("b0").unwrap().unwrap();
    assert_eq!(item.status, BatchStatus::Succeeded);
    assert_eq!(item.response_text.as_deref(), Some("batched answer"));
}

#[tokio::test]
async fn the_submitted_params_are_the_messages_api_shape() {
    let provider = Arc::new(Provider::default());
    let addr = spawn_provider(Arc::clone(&provider)).await;

    let store = store();
    enqueue(&store, 0);

    BatchQueue::new(
        &store,
        AnthropicBatchClient::new("test-key", format!("http://{addr}")),
    )
    .flush(NOW)
    .await
    .unwrap();

    let params = provider.first_params.lock().unwrap().clone().unwrap();
    // A batch request carries ordinary Messages params, nested under `params`.
    // Getting this wrong is a 400 from the real endpoint with nothing useful in
    // it.
    assert_eq!(params["model"], "claude-haiku-4-5");
    assert!(params["messages"].is_array());
    assert!(params["max_tokens"].is_number());
}

#[tokio::test]
async fn a_provider_that_refuses_the_batch_leaves_the_work_queued() {
    // The recoverable failure. The unrecoverable one would be marking it sent.
    let store = store();
    enqueue(&store, 0);

    let queue = BatchQueue::new(
        &store,
        // Nothing listening: connection refused.
        AnthropicBatchClient::new("test-key", "http://127.0.0.1:1"),
    );

    assert!(queue.flush(NOW).await.is_err());
    assert_eq!(store.list_queued_batch_items(10).unwrap().len(), 1);
    assert_eq!(store.session_budget("s1").unwrap().spent_usd, 0.0);
}
