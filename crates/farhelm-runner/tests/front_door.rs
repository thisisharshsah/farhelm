//! The front door end to end: another project's OpenAI-style client calls
//! models through the runner, under its own key, model rules and daily limit,
//! with its spend in its own ledger session and its cache kept to itself.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use axum::extract::State;
use axum::routing::post;
use axum::{Json, Router};
use farhelm_gateway::{Gateway, GatewayConfig, ProviderClient};
use farhelm_runner::clients::{self, Client, ClientsFile};
use farhelm_runner::state::AppState;
use farhelm_sqlite::SqliteStore;
use serde_json::{Value, json};

/// A model server that answers every request with the model it was asked for,
/// and keeps the requests.
async fn chat(State(seen): State<Arc<Mutex<Vec<Value>>>>, Json(body): Json<Value>) -> Json<Value> {
    let model = body["model"].as_str().unwrap_or_default().to_owned();
    seen.lock().unwrap().push(body);
    Json(json!({
        "model": model,
        "choices": [{ "index": 0, "message": { "role": "assistant", "content": format!("answered by {model}") }, "finish_reason": "stop" }],
        "usage": { "prompt_tokens": 40, "completion_tokens": 10 }
    }))
}

async fn serve(router: Router) -> SocketAddr {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    addr
}

struct Fixture {
    runner: SocketAddr,
    state: Arc<AppState>,
    seen: Arc<Mutex<Vec<Value>>>,
    everest_key: String,
    lacuna_key: String,
}

async fn fixture() -> Fixture {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let model_server = serve(
        Router::new()
            .route("/v1/chat/completions", post(chat))
            .with_state(Arc::clone(&seen)),
    )
    .await;
    let client = ProviderClient::from_toml(&format!(
        r#"
version = 1
policy = "local_only"
[routes]
small = "coder"
large = "coder"
frontier = "coder"
[providers.engine]
kind = "openai_compatible"
base_url = "http://{model_server}/v1"
data_location = "local"
[models.coder]
provider = "engine"
model = "qwen3-coder-30b"
tools = true
max_output_tokens = 512
[models.gpt-oss-20b]
provider = "engine"
model = "gpt-oss-20b"
tools = true
max_output_tokens = 512
"#
    ))
    .unwrap();
    let config = GatewayConfig {
        models: client.models().unwrap(),
        ..GatewayConfig::default()
    };
    let state = AppState::build(
        SqliteStore::open_in_memory().unwrap(),
        move |store| Some(Gateway::new(store, client, config)),
        Arc::new(farhelm_crypto::Identity::generate()),
        None,
    );

    let everest_key = clients::new_key();
    let lacuna_key = clients::new_key();
    let mut file = ClientsFile::default();
    file.clients.insert(
        "everest".into(),
        Client {
            key_sha256: clients::hash_key(&everest_key),
            default_model: Some("gpt-oss-20b".into()),
            models: vec!["gpt-oss-20b".into()],
            daily_token_limit: None,
        },
    );
    file.clients.insert(
        "lacuna".into(),
        Client {
            key_sha256: clients::hash_key(&lacuna_key),
            default_model: None,
            models: Vec::new(),
            // Two calls of 50 tokens each fit; the third is refused.
            daily_token_limit: Some(100),
        },
    );
    let runner = serve(farhelm_runner::front_door::router(Arc::clone(&state), file)).await;
    Fixture {
        runner,
        state,
        seen,
        everest_key,
        lacuna_key,
    }
}

async fn ask(
    fixture: &Fixture,
    client: &str,
    key: &str,
    model: &str,
    prompt: &str,
) -> (u16, Value) {
    let response = reqwest::Client::new()
        .post(format!("http://{}/p/{client}/v1/chat/completions", fixture.runner))
        .bearer_auth(key)
        .json(&json!({ "model": model, "messages": [{ "role": "user", "content": prompt }], "temperature": 0.2 }))
        .send()
        .await
        .unwrap();
    let status = response.status().as_u16();
    (status, response.json().await.unwrap())
}

#[tokio::test]
async fn a_client_reaches_its_models_only_with_its_own_key() {
    let fixture = fixture().await;

    // The right key, a declared model it may use.
    let (status, body) = ask(
        &fixture,
        "everest",
        &fixture.everest_key,
        "gpt-oss-20b",
        "hello",
    )
    .await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["object"], "chat.completion");
    assert_eq!(
        body["choices"][0]["message"]["content"],
        "answered by gpt-oss-20b"
    );
    assert_eq!(body["model"], "local/engine/gpt-oss-20b");
    assert_eq!(body["usage"]["total_tokens"], 50);

    // Another client's key, or none, gets nothing; and the answer does not say
    // whether the client exists.
    let (status, wrong) = ask(
        &fixture,
        "everest",
        &fixture.lacuna_key,
        "gpt-oss-20b",
        "hello",
    )
    .await;
    assert_eq!(status, 401);
    let (status, unknown) = ask(
        &fixture,
        "nobody",
        &fixture.lacuna_key,
        "gpt-oss-20b",
        "hello",
    )
    .await;
    assert_eq!(status, 401);
    assert_eq!(wrong["error"]["message"], unknown["error"]["message"]);

    // A declared model it may not use is refused, not quietly swapped.
    let (status, body) = ask(&fixture, "everest", &fixture.everest_key, "coder", "hello").await;
    assert_eq!(status, 403, "{body}");

    // A name the registry does not declare goes to the client's default.
    let (status, body) = ask(
        &fixture,
        "everest",
        &fixture.everest_key,
        "gpt-oss-20b-old-name",
        "hi",
    )
    .await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["model"], "local/engine/gpt-oss-20b");

    // Only the two accepted calls reached the model server.
    assert_eq!(fixture.seen.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn spend_is_the_clients_own_and_the_daily_limit_holds() {
    let fixture = fixture().await;
    let key = fixture.lacuna_key.clone();

    // No default model: the gateway's routing picks one.
    let (status, body) = ask(&fixture, "lacuna", &key, "", "first").await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["model"], "local/engine/qwen3-coder-30b");
    let (status, _) = ask(&fixture, "lacuna", &key, "", "second").await;
    assert_eq!(status, 200);
    let (status, body) = ask(&fixture, "lacuna", &key, "", "third").await;
    assert_eq!(status, 429, "{body}");
    assert_eq!(body["error"]["type"], "rate_limit_error");

    let spent = fixture
        .state
        .store
        .session_tokens_since(&clients::session_id("lacuna"), 0)
        .unwrap();
    assert_eq!(spent, 100);
    assert_eq!(
        fixture
            .state
            .store
            .session_tokens_since(&clients::session_id("everest"), 0)
            .unwrap(),
        0
    );
}

#[tokio::test]
async fn the_models_list_shows_what_the_client_may_use() {
    let fixture = fixture().await;
    let body: Value = reqwest::Client::new()
        .get(format!("http://{}/p/everest/v1/models", fixture.runner))
        .header("x-api-key", &fixture.everest_key)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let ids: Vec<&str> = body["data"]
        .as_array()
        .unwrap()
        .iter()
        .map(|model| model["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, ["gpt-oss-20b"]);
}

#[tokio::test]
async fn a_streamed_answer_is_framed_as_chunks_and_done() {
    let fixture = fixture().await;
    let text = reqwest::Client::new()
        .post(format!("http://{}/p/everest/v1/chat/completions", fixture.runner))
        .bearer_auth(&fixture.everest_key)
        .json(&json!({ "model": "gpt-oss-20b", "stream": true, "messages": [{ "role": "user", "content": "hi" }] }))
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    let data: Vec<&str> = text
        .lines()
        .filter_map(|line| line.strip_prefix("data: "))
        .collect();
    assert_eq!(data.last(), Some(&"[DONE]"));
    let first: Value = serde_json::from_str(data[0]).unwrap();
    assert_eq!(first["object"], "chat.completion.chunk");
    assert_eq!(
        first["choices"][0]["delta"]["content"],
        "answered by gpt-oss-20b"
    );
    let finish: Value = serde_json::from_str(data[1]).unwrap();
    assert_eq!(finish["choices"][0]["finish_reason"], "stop");
}

#[tokio::test]
async fn one_clients_cached_answer_is_never_anothers() {
    let fixture = fixture().await;
    let summarize = |client: &'static str, key: String| {
        let runner = fixture.runner;
        async move {
            let response = reqwest::Client::new()
                .post(format!("http://{runner}/p/{client}/v1/messages"))
                .header("x-api-key", key)
                .header("x-farhelm-task", "summarize")
                .json(&json!({ "model": "gpt-oss-20b", "max_tokens": 64,
                               "messages": [{ "role": "user", "content": "Summarize: the same text." }] }))
                .send()
                .await
                .unwrap();
            assert_eq!(response.status().as_u16(), 200);
        }
    };
    summarize("everest", fixture.everest_key.clone()).await;
    summarize("everest", fixture.everest_key.clone()).await;
    assert_eq!(
        fixture.seen.lock().unwrap().len(),
        1,
        "the repeat is served from everest's cache"
    );
    summarize("lacuna", fixture.lacuna_key.clone()).await;
    assert_eq!(
        fixture.seen.lock().unwrap().len(),
        2,
        "lacuna must not get everest's cached answer"
    );
}
