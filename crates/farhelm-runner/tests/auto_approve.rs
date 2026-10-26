//! Auto-approve through the real local HTTP API, on the path a hook-bridged
//! agent actually takes: `POST /v1/hooks/tool-request` blocks until a person
//! decides — unless the session's standing level already covers the request.

use std::sync::Arc;
use std::time::{Duration, Instant};

use farhelm_crypto::Identity;
use farhelm_runner::api::{self, LocalAuth};
use farhelm_runner::state::AppState;
use farhelm_sqlite::SqliteStore;
use reqwest::{Client, StatusCode};
use serde_json::{Value, json};
use tokio::sync::oneshot;

struct Server {
    url: String,
    http: Client,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<()>>,
}

impl Server {
    async fn start(state: Arc<AppState>) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let (shutdown, signal) = oneshot::channel();
        let router = api::router_with_auth(state, LocalAuth::open());
        let task = tokio::spawn(async move {
            axum::serve(listener, router)
                .with_graceful_shutdown(async {
                    let _ = signal.await;
                })
                .await
                .unwrap();
        });
        Self {
            url,
            http: Client::builder()
                .timeout(Duration::from_secs(10))
                .build()
                .unwrap(),
            shutdown: Some(shutdown),
            task: Some(task),
        }
    }

    async fn stop(mut self) {
        let _ = self.shutdown.take().unwrap().send(());
        tokio::time::timeout(Duration::from_secs(5), self.task.take().unwrap())
            .await
            .unwrap()
            .unwrap();
    }

    /// What the hook bridge sends when the agent wants to run something.
    async fn tool_request(&self, payload: &str, wait_ms: u64) -> Value {
        let response = self
            .http
            .post(format!("{}/v1/hooks/tool-request", self.url))
            .json(&json!({
                "agent_session_id": "agent-1",
                "cwd": "/srv/payments-api",
                "tool": "Bash",
                "payload": payload,
                "wait_ms": wait_ms,
            }))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        response.json().await.unwrap()
    }

    async fn fleet(&self) -> Value {
        let response = self
            .http
            .get(format!("{}/v1/fleet", self.url))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        response.json().await.unwrap()
    }

    async fn set_level(&self, session_id: &str, level: &str) -> reqwest::Response {
        self.http
            .post(format!(
                "{}/v1/sessions/{session_id}/auto-approve",
                self.url
            ))
            .json(&json!({ "level": level }))
            .send()
            .await
            .unwrap()
    }
}

#[tokio::test]
async fn a_hook_bridged_command_is_cleared_without_a_card_once_the_level_covers_it() {
    let state = farhelm_runner::test_support::state(
        SqliteStore::open_in_memory().unwrap(),
        Arc::new(Identity::generate()),
    );
    let server = Server::start(state).await;

    // Before anybody delegates anything: the request waits, nobody answers,
    // and it is denied by default. This is the behaviour the user was seeing
    // on every command.
    let first = server.tool_request("cargo test", 200).await;
    assert_eq!(first["decision"], "timeout");
    assert_eq!(first["risk"], "medium");
    let session_id = first["session_id"].as_str().unwrap().to_owned();

    let fleet = server.fleet().await;
    assert_eq!(fleet["sessions"].as_array().unwrap().len(), 1);
    assert_eq!(fleet["sessions"][0]["auto_approve"], "off");

    // The web app sets the level for this session.
    let response = server.set_level(&session_id, "medium").await;
    assert_eq!(response.status(), StatusCode::OK);
    let view: Value = response.json().await.unwrap();
    assert_eq!(view["auto_approve"], "medium");
    assert_eq!(view["id"], session_id);

    // The same request now returns at once, approved, without a card.
    let started = Instant::now();
    let second = server.tool_request("cargo test", 10_000).await;
    assert_eq!(second["decision"], "approved");
    assert!(
        second["reason"].as_str().unwrap().contains("auto-approved"),
        "{}",
        second["reason"]
    );
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "the hook should not have waited: {:?}",
        started.elapsed()
    );
    let fleet = server.fleet().await;
    assert!(fleet["pending_approvals"].as_array().unwrap().is_empty());
    assert_eq!(fleet["sessions"][0]["auto_approve"], "medium");
    // Still `running` — it was never blocked.
    assert_eq!(fleet["sessions"][0]["status"], "running");

    // A destructive command under the same level still waits for a person.
    let third = server.tool_request("rm -rf ./build", 200).await;
    assert_eq!(third["decision"], "timeout");
    assert_eq!(third["risk"], "destructive");

    // An invalid level is a 4xx, not a silent `off`.
    let response = server.set_level(&session_id, "everything").await;
    assert!(response.status().is_client_error(), "{}", response.status());
    // And an unknown session is a 404.
    let response = server.set_level("nope", "low").await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND);

    server.stop().await;
}
