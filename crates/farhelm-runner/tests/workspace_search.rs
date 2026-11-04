//! `GET /v1/search` over real HTTP: one query across the local workspace's
//! projects, tasks, runs and conversation titles.

use std::sync::Arc;
use std::time::Duration;

use farhelm_app::{project_workflow::ProjectWorkflow, store::prelude::*};
use farhelm_crypto::Identity;
use farhelm_proto::types::{
    Agent, AgentTask, Conversation, Project, Repo, Session, SessionStatus, TaskStatus,
};
use farhelm_runner::api::{self, LocalAuth};
use farhelm_runner::state::AppState;
use farhelm_sqlite::SqliteStore;
use reqwest::{Client, StatusCode};
use serde_json::{Value, json};

struct Server {
    url: String,
    http: Client,
    task: tokio::task::JoinHandle<()>,
}

impl Server {
    async fn new(state: Arc<AppState>) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            axum::serve(listener, api::router_with_auth(state, LocalAuth::open()))
                .await
                .unwrap()
        });
        Self {
            url,
            task,
            http: Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(5))
                .build()
                .unwrap(),
        }
    }

    async fn post(&self, path: &str, body: Value) -> Value {
        self.http
            .post(format!("{}{path}", self.url))
            .json(&body)
            .send()
            .await
            .unwrap()
            .error_for_status()
            .unwrap()
            .json()
            .await
            .unwrap()
    }

    async fn search(&self, query: &str) -> (StatusCode, Value) {
        let response = self
            .http
            .get(format!("{}/v1/search", self.url))
            .query(&[("q", query)])
            .send()
            .await
            .unwrap();
        let status = response.status();
        (status, response.json().await.unwrap_or(Value::Null))
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn state() -> Arc<AppState> {
    farhelm_runner::test_support::state(
        SqliteStore::open_in_memory().unwrap(),
        Arc::new(Identity::generate()),
    )
}

fn repo(state: &AppState) -> Repo {
    let repo = Repo {
        id: "repo-search".into(),
        machine_id: state.machine_id.clone(),
        path: "/synthetic/payments".into(),
        name: "payments".into(),
        budget_usd: None,
    };
    state.store.upsert_repo(&repo).unwrap();
    repo
}

fn run(state: &AppState, project_id: &str, repo: &Repo, id: &str, prompt: &str, summary: &str) {
    let session = Session {
        id: format!("session-{id}"),
        repo_id: repo.id.clone(),
        agent: Agent::Farhelm,
        tmux_target: None,
        status: SessionStatus::Running,
        plan_id: None,
        budget_usd: None,
        spent_usd: 0.0,
        started_at: 1,
        ended_at: None,
        agent_session_id: None,
    };
    let task = AgentTask {
        id: id.into(),
        session_id: session.id.clone(),
        repo_id: repo.id.clone(),
        prompt: prompt.into(),
        status: TaskStatus::Running,
        summary: summary.into(),
        diff_json: String::new(),
        worktree_json: String::new(),
        files_changed: 0,
        lines_added: 0,
        lines_removed: 0,
        steps: 0,
        cost_usd: 0.0,
        error: None,
        review_note: None,
        verify_grade: None,
        verify_notes: None,
        verify_model: None,
        mode: farhelm_proto::types::WorkMode::Agent,
        model: None,
        work_item_id: None,
        decided_via: None,
        created_at: 3,
        updated_at: 3,
        decided_at: None,
    };
    ProjectWorkflow::new(Arc::clone(&state.store), &state.machine_id)
        .unwrap()
        .insert_task(project_id, &session, &task, None)
        .unwrap();
}

#[tokio::test]
async fn one_query_finds_every_kind_of_thing_and_nothing_outside_the_workspace() {
    let state = state();
    let server = Server::new(Arc::clone(&state)).await;
    let repo = repo(&state);

    let payments = server
        .post(
            "/v1/projects",
            json!({"name": "Payments", "description": "Webhook retries and refunds"}),
        )
        .await["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let other = server
        .post("/v1/projects", json!({"name": "Docs site"}))
        .await["id"]
        .as_str()
        .unwrap()
        .to_owned();
    server
        .post(
            &format!("/v1/projects/{payments}/repos"),
            json!({"repo_id": repo.id}),
        )
        .await;
    server
        .post(
            &format!("/v1/projects/{other}/work-items"),
            json!({"title": "Write the setup guide", "description": "Cover the retry settings too."}),
        )
        .await;
    state
        .store
        .put_conversation(&Conversation {
            id: "conv-1".into(),
            project_id: payments.clone(),
            title: "Why do RETRIES pile up?".into(),
            created_at: 4,
            updated_at: 4,
        })
        .unwrap();
    run(
        &state,
        &payments,
        &repo,
        "run-1",
        "Bound the webhook backoff",
        "Capped the retry delay at 30 s and added a test.",
    );
    // Another workspace's project, matching, must never be returned.
    state
        .store
        .put_project(&Project {
            id: "foreign".into(),
            workspace_id: "someone-else".into(),
            name: "Retry everything".into(),
            description: String::new(),
            budget_cap_usd: None,
            created_at: 9,
            updated_at: 9,
        })
        .unwrap();

    let (status, found) = server.search("  retr  ").await;
    assert_eq!(status, StatusCode::OK, "{found}");
    assert_eq!(found["query"], "retr");
    assert_eq!(found["truncated"], false);
    let hits = found["hits"].as_array().unwrap();
    let mut kinds: Vec<&str> = hits
        .iter()
        .map(|hit| hit["kind"].as_str().unwrap())
        .collect();
    kinds.sort();
    assert_eq!(kinds, ["conversation", "project", "run", "task"], "{found}");
    assert!(hits.iter().all(|hit| hit["id"] != "foreign"), "{found}");

    let by_kind = |kind: &str| hits.iter().find(|hit| hit["kind"] == kind).unwrap().clone();
    // A match in the longer text comes with the passage that matched.
    let task = by_kind("task");
    assert_eq!(task["project_name"], "Docs site");
    assert_eq!(task["status"], "todo");
    assert!(
        task["snippet"].as_str().unwrap().contains("retry settings"),
        "{task}"
    );
    let run = by_kind("run");
    assert_eq!(run["title"], "Bound the webhook backoff");
    assert!(
        run["snippet"].as_str().unwrap().contains("retry delay"),
        "{run}"
    );
    // A match in the title needs no snippet; case is folded.
    let conversation = by_kind("conversation");
    assert!(conversation["snippet"].is_null(), "{conversation}");
    assert_eq!(conversation["project_id"], payments.as_str());
}

#[tokio::test]
async fn queries_are_validated_literal_and_bounded() {
    let state = state();
    let server = Server::new(Arc::clone(&state)).await;
    server
        .post("/v1/projects", json!({"name": "Spend 100% of the cap"}))
        .await;
    server
        .post("/v1/projects", json!({"name": "Spend 1000 dollars"}))
        .await;

    // `%` matches itself, not everything.
    let (_, found) = server.search("100%").await;
    assert_eq!(found["hits"].as_array().unwrap().len(), 1, "{found}");

    for bad in ["x", " ", &"y".repeat(201)] {
        let (status, _) = server.search(bad).await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{bad:?}");
    }

    let limited = server
        .http
        .get(format!("{}/v1/search?q=spend&limit=1", server.url))
        .send()
        .await
        .unwrap()
        .json::<Value>()
        .await
        .unwrap();
    assert_eq!(limited["hits"].as_array().unwrap().len(), 1);
    assert_eq!(limited["truncated"], true);

    let unknown = server
        .http
        .get(format!("{}/v1/search?q=spend&kind=run", server.url))
        .send()
        .await
        .unwrap();
    assert_eq!(unknown.status(), StatusCode::UNPROCESSABLE_ENTITY);
}
