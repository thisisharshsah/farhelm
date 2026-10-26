//! Project conversations through the real local HTTP API.
//!
//! No model provider is configured here on purpose: the point is the claim,
//! the truthful failure, the replay and the scope, none of which should need a
//! model to be exercised. The reply itself is the gateway's job and is covered
//! by its own conformance fixtures.

use std::sync::Arc;
use std::time::Duration;

use farhelm_app::store::prelude::*;
use farhelm_crypto::Identity;
use farhelm_proto::types::Repo;
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
                .timeout(Duration::from_secs(5))
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

    async fn post(&self, path: &str, body: Value) -> (StatusCode, Value) {
        let response = self
            .http
            .post(format!("{}{path}", self.url))
            .json(&body)
            .send()
            .await
            .unwrap();
        let status = response.status();
        (status, response.json().await.unwrap_or(Value::Null))
    }

    async fn get(&self, path: &str) -> (StatusCode, Value) {
        let response = self
            .http
            .get(format!("{}{path}", self.url))
            .send()
            .await
            .unwrap();
        let status = response.status();
        (status, response.json().await.unwrap_or(Value::Null))
    }
}

#[tokio::test]
async fn a_message_is_claimed_answered_truthfully_and_replayed() {
    let state = farhelm_runner::test_support::state(
        SqliteStore::open_in_memory().unwrap(),
        Arc::new(Identity::generate()),
    );
    state
        .store
        .upsert_repo(&Repo {
            id: "repo-1".into(),
            machine_id: state.machine_id.clone(),
            path: "/srv/payments-api".into(),
            name: "payments-api".into(),
            budget_usd: None,
        })
        .unwrap();
    let server = Server::start(Arc::clone(&state)).await;

    let (status, project) = server
        .post("/v1/projects", json!({ "name": "Payments" }))
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let project_id = project["id"].as_str().unwrap().to_owned();

    // A conversation needs an attached repository: refused before, created after.
    let (status, _) = server
        .post(
            &format!("/v1/projects/{project_id}/chats"),
            json!({ "repo_id": "repo-1", "title": "Retry policy" }),
        )
        .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = server
        .post(
            &format!("/v1/projects/{project_id}/repos"),
            json!({ "repo_id": "repo-1" }),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let (status, detail) = server
        .post(
            &format!("/v1/projects/{project_id}/chats"),
            json!({ "repo_id": "repo-1", "title": "Retry policy", "budget_usd": 0.5 }),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED, "{detail}");
    let chat_id = detail["conversation"]["id"].as_str().unwrap().to_owned();
    assert_eq!(detail["conversation"]["repo_id"], "repo-1");

    // The claim is answered at once with the turn pending.
    let (status, reply) = server
        .post(
            &format!("/v1/projects/{project_id}/chats/{chat_id}/messages"),
            json!({ "content": "Why does the retry loop spin?", "request_id": "req-1" }),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{reply}");
    assert_eq!(reply["turn"]["request_id"], "req-1");
    assert_eq!(reply["detail"]["messages"].as_array().unwrap().len(), 1);

    // With no provider the turn settles as failed, and says why.
    let mut settled = None;
    for _ in 0..100 {
        let (_, detail) = server
            .get(&format!("/v1/projects/{project_id}/chats/{chat_id}"))
            .await;
        if detail["latest_turn"]["status"] != "pending" {
            settled = Some(detail);
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let detail = settled.expect("the turn settles without a provider");
    assert_eq!(detail["latest_turn"]["status"], "failed");
    assert!(
        detail["latest_turn"]["error"]
            .as_str()
            .unwrap()
            .contains("no model provider"),
        "{}",
        detail["latest_turn"]
    );
    assert_eq!(detail["messages"].as_array().unwrap().len(), 1);

    // A resend replays the recorded failure; the same id with other words is refused.
    let (status, replay) = server
        .post(
            &format!("/v1/projects/{project_id}/chats/{chat_id}/messages"),
            json!({ "content": "Why does the retry loop spin?", "request_id": "req-1" }),
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(replay["turn"]["status"], "failed");
    let (status, _) = server
        .post(
            &format!("/v1/projects/{project_id}/chats/{chat_id}/messages"),
            json!({ "content": "Something else", "request_id": "req-1" }),
        )
        .await;
    assert_eq!(status, StatusCode::CONFLICT);

    // Listing and an unknown project.
    let (status, page) = server
        .get(&format!("/v1/projects/{project_id}/chats?limit=10"))
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(page["conversations"].as_array().unwrap().len(), 1);
    let (status, _) = server.get("/v1/projects/nope/chats").await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    server.stop().await;
}
