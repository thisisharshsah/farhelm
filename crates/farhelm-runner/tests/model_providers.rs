//! Configured inference through the runner's public Messages endpoint and ledger.
//! The only substitute is the local HTTP model server; no live credentials.

use std::sync::{Arc, Mutex};

use axum::{Json, Router, extract::State, routing::post};
use farhelm_app::store::{LedgerStore, TimeRange};
use farhelm_gateway::{Gateway, GatewayConfig, ProviderClient};
use farhelm_runner::state::AppState;
use farhelm_sqlite::SqliteStore;
use serde_json::{Value, json};

struct ModelServer {
    requests: Mutex<Vec<Value>>,
}

async fn completion(
    State(server): State<Arc<ModelServer>>,
    Json(body): Json<Value>,
) -> Json<Value> {
    let mut requests = server.requests.lock().unwrap();
    requests.push(body);
    let (message, finish) = if requests.len() == 1 {
        (
            json!({"role":"assistant", "content":null, "tool_calls":[{
                "id":"call-read", "type":"function", "function":{
                    "name":"read_file", "arguments":"{\"path\":\"README.md\"}"
                }
            }]}),
            "tool_calls",
        )
    } else {
        (
            json!({"role":"assistant", "content":"Read the project instructions."}),
            "length",
        )
    };
    Json(json!({
        "model":"fixture-model-revision", "choices":[{"message":message,"finish_reason":finish}],
        "usage":{"prompt_tokens":100,"completion_tokens":20,
            "prompt_tokens_details":{"cached_tokens":40}}
    }))
}

async fn spawn(app: Router) -> (String, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    (url, task)
}

async fn round_trip(local: bool) {
    let server = Arc::new(ModelServer {
        requests: Mutex::new(Vec::new()),
    });
    let (model_url, model_task) = spawn(
        Router::new()
            .route("/v1/chat/completions", post(completion))
            .with_state(Arc::clone(&server)),
    )
    .await;
    let policy = if local { "local_only" } else { "cloud_allowed" };
    let location = if local { "local" } else { "cloud" };
    let pricing = if local {
        ""
    } else {
        "[models.coder.pricing]\ninput_per_mtok = 2.0\noutput_per_mtok = 8.0\ncache_read_per_mtok = 1.0"
    };
    let source = format!(
        r#"
version = 1
policy = "{policy}"
[routes]
small = "coder"
large = "coder"
frontier = "coder"
[providers.fixture]
kind = "openai_compatible"
base_url = "{model_url}/v1"
data_location = "{location}"
[models.coder]
provider = "fixture"
model = "fixture-model"
tools = true
max_output_tokens = 512
{pricing}
"#
    );
    let provider = ProviderClient::from_toml(&source).unwrap();
    let config = GatewayConfig {
        models: provider.models().unwrap(),
        ..GatewayConfig::default()
    };
    let state = AppState::build(
        SqliteStore::open_in_memory().unwrap(),
        move |store| Some(Gateway::new(store, provider, config)),
        Arc::new(farhelm_crypto::Identity::generate()),
        None,
    );
    let (runner_url, runner_task) = spawn(farhelm_runner::api::router(Arc::clone(&state))).await;
    let http = reqwest::Client::new();
    let tools = json!([{"name":"read_file","description":"Read a project file", "input_schema":{
        "type":"object","properties":{"path":{"type":"string"}},"required":["path"]
    }}]);
    let initial = json!({"role":"user","content":"Read README.md"});
    let response = http
        .post(format!("{runner_url}/v1/messages"))
        .json(&json!({
            "metadata":{"user_id":"fixture-session"}, "tools":tools, "messages":[initial]
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    let first: Value = response.json().await.unwrap();
    assert_eq!(first["stop_reason"], "tool_use");
    assert_eq!(first["content"][0]["id"], "call-read");
    assert_eq!(first["usage"]["input_tokens"], 60);
    assert_eq!(first["usage"]["cache_read_input_tokens"], 40);
    let response = http
        .post(format!("{runner_url}/v1/messages"))
        .json(&json!({
            "metadata":{"user_id":"fixture-session"}, "tools":tools,
            "messages":[initial, {"role":"assistant","content":first["content"]},
                {"role":"user","content":[{"type":"tool_result","tool_use_id":"call-read",
                    "content":"Project instructions","is_error":false}]}]
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    let second: Value = response.json().await.unwrap();
    assert_eq!(second["stop_reason"], "max_tokens");
    assert_eq!(
        second["content"][0]["text"],
        "Read the project instructions."
    );
    let expected_model = if local {
        "local/fixture/fixture-model-revision"
    } else {
        "fixture/fixture-model-revision"
    };
    assert_eq!(second["model"], expected_model);
    {
        let requests = server.requests.lock().unwrap();
        assert_eq!(requests.len(), 2);
        assert_eq!(requests[0]["model"], "fixture-model");
        assert_eq!(requests[0]["max_tokens"], 512);
        assert_eq!(
            requests[1]["messages"][1]["tool_calls"][0]["id"],
            "call-read"
        );
        assert_eq!(requests[1]["messages"][2]["role"], "tool");
        assert_eq!(requests[1]["messages"][2]["tool_call_id"], "call-read");
    }
    let events = state
        .store
        .list_usage("fixture-session", TimeRange::ALL)
        .unwrap();
    assert_eq!(events.len(), 2);
    let per_call = if local { 0.0 } else { 0.00032 };
    for event in events {
        assert_eq!(event.model, expected_model);
        assert!((event.cost_usd - per_call).abs() < 1e-12);
        assert_eq!(event.usage.input_tokens, 60);
        assert_eq!(event.usage.output_tokens, 20);
    }
    let budget = state.store.session_budget("fixture-session").unwrap();
    assert!((budget.spent_usd - per_call * 2.0).abs() < 1e-12);
    runner_task.abort();
    model_task.abort();
}

#[tokio::test]
async fn local_tools_and_usage_survive_a_public_api_round_trip() {
    round_trip(true).await;
}

#[tokio::test]
async fn configured_cloud_rates_update_the_session_budget() {
    round_trip(false).await;
}
