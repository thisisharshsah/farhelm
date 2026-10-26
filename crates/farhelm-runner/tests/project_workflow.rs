//! Real HTTP checks for direct project ownership and its existing task controls.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use farhelm_app::{project_workflow::ProjectWorkflow, store::prelude::*};
use farhelm_crypto::Identity;
use farhelm_gateway::{Gateway, GatewayConfig, ProviderClient};
use farhelm_proto::types::{Agent, AgentTask, Project, Repo, Session, SessionStatus, TaskStatus};
use farhelm_runner::{
    api::{self, LocalAuth},
    state::AppState,
};
use farhelm_sqlite::SqliteStore;
use reqwest::{Client, StatusCode};
use serde_json::{Value, json};

struct Server {
    url: String,
    http: Client,
    task: tokio::task::JoinHandle<()>,
}
impl Server {
    async fn new(state: Arc<AppState>, token: Option<&str>) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let auth = token
            .map(LocalAuth::with_token)
            .unwrap_or_else(LocalAuth::open);
        let task = tokio::spawn(async move {
            axum::serve(listener, api::router_with_auth(state, auth))
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
    fn url(&self, path: &str) -> String {
        format!("{}{path}", self.url)
    }
    async fn get(&self, path: &str) -> Value {
        self.http
            .get(self.url(path))
            .send()
            .await
            .unwrap()
            .error_for_status()
            .unwrap()
            .json()
            .await
            .unwrap()
    }
    async fn post(&self, path: &str, body: Value) -> Value {
        self.http
            .post(self.url(path))
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
    async fn project(&self, name: &str) -> String {
        self.post("/v1/projects", json!({"name":name})).await["id"]
            .as_str()
            .unwrap()
            .into()
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}

struct Database(PathBuf);
impl Database {
    fn new() -> Self {
        Self(std::env::temp_dir().join(format!(
            "farhelm-project-workflow-{}.db",
            farhelm_app::id::new_id()
        )))
    }
}
impl Drop for Database {
    fn drop(&mut self) {
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{suffix}", self.0.display()));
        }
    }
}

fn state(store: SqliteStore, gateway: bool) -> Arc<AppState> {
    AppState::build(
        store,
        move |store| {
            gateway.then(|| {
                // Requests in these boundary tests must be rejected before dispatch.
                let client = ProviderClient::from_toml(
                    r#"
version=1
policy="local_only"
[routes]
small="fixture"
large="fixture"
frontier="fixture"
[providers.fixture]
kind="openai_compatible"
base_url="http://127.0.0.1:9/v1"
data_location="local"
[models.fixture]
provider="fixture"
model="fixture"
tools=true
max_output_tokens=128
"#,
                )
                .unwrap();
                let models = client.models().unwrap();
                Gateway::new(
                    store,
                    client,
                    GatewayConfig {
                        models,
                        ..GatewayConfig::default()
                    },
                )
            })
        },
        Arc::new(Identity::generate()),
        None,
    )
}

fn repo(state: &AppState, id: &str, machine: Option<&str>, path: &str) -> Repo {
    let machine_id = machine.unwrap_or(&state.machine_id);
    let _ = state.store.upsert_machine(&farhelm_proto::types::Machine {
        id: machine_id.into(),
        name: machine_id.into(),
        pubkey: machine_id.into(),
        last_seen_at: None,
        created_at: 1,
    });
    let repo = Repo {
        id: id.into(),
        machine_id: machine_id.into(),
        path: path.into(),
        name: format!("Repository {id}"),
        budget_usd: None,
    };
    state.store.upsert_repo(&repo).unwrap();
    repo
}

fn insert_task(
    state: &AppState,
    project_id: &str,
    repo: &Repo,
    id: &str,
    status: TaskStatus,
) -> AgentTask {
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
        prompt: format!("Private prompt for {id}"),
        status,
        summary: "Private summary".into(),
        diff_json: String::new(),
        worktree_json: String::new(),
        files_changed: 0,
        lines_added: 0,
        lines_removed: 0,
        steps: 0,
        cost_usd: 0.0,
        error: None,
        review_note: Some("Use a different approach".into()),
        verify_grade: None,
        verify_notes: None,
        verify_model: None,
        decided_via: None,
        created_at: 1,
        updated_at: 1,
        decided_at: None,
    };
    // Production starts insert running rows atomically, then execution records
    // their result through the existing task store.
    let mut running = task.clone();
    running.status = TaskStatus::Running;
    ProjectWorkflow::new(Arc::clone(&state.store), &state.machine_id)
        .unwrap()
        .insert_task(project_id, &session, &running, None)
        .unwrap();
    state.store.upsert_task(&task).unwrap();
    task
}

#[tokio::test]
async fn registered_repo_listing_does_not_scan_register_or_return_other_machines() {
    let state = state(SqliteStore::open_in_memory().unwrap(), false);
    let server = Server::new(Arc::clone(&state), None).await;
    assert_eq!(server.get("/v1/repos").await, json!([]));
    assert!(
        state
            .store
            .list_repos(&state.machine_id)
            .unwrap()
            .is_empty()
    );
    // Reading from the repository checkout must not implicitly register its
    // working directory or siblings; only explicitly stored rows appear.
    let local = repo(&state, "registered", None, "/synthetic/local");
    repo(
        &state,
        "foreign",
        Some("foreign-machine"),
        "/synthetic/foreign",
    );
    assert_eq!(
        server.get("/v1/repos").await,
        json!([{
            "id":local.id,"name":local.name,"path":local.path,
        }])
    );
    assert!(state.store.list_repos("").unwrap().is_empty());
}

#[tokio::test]
async fn registered_repository_pages_attachment_and_scope_survive_restart() {
    let database = Database::new();
    let first = state(SqliteStore::open(&database.0).unwrap(), false);
    for id in ["repo-a", "repo-b", "repo-c"] {
        repo(&first, id, None, &format!("/fixture/{id}"));
    }
    repo(
        &first,
        "other-machine",
        Some("foreign-machine"),
        "/private/foreign-path",
    );
    let server = Server::new(Arc::clone(&first), None).await;
    let project = server.project("Local workflow").await;
    let page = server
        .get(&format!("/v1/projects/{project}/repo-candidates?limit=2"))
        .await;
    assert_eq!(page["repositories"].as_array().unwrap().len(), 2);
    assert_eq!(page["repositories"][0]["id"], "repo-c");
    assert_eq!(page["next_cursor"], "repo-b");
    let last = server
        .get(&format!(
            "/v1/projects/{project}/repo-candidates?limit=2&after=repo-b"
        ))
        .await;
    assert_eq!(last["repositories"][0]["id"], "repo-a");
    assert_eq!(last["next_cursor"], Value::Null);
    let attached = server
        .post(
            &format!("/v1/projects/{project}/repos"),
            json!({"repo_id":"repo-a"}),
        )
        .await;
    assert_eq!(
        attached,
        json!({"id":"repo-a","name":"Repository repo-a","path":"/fixture/repo-a"})
    );
    assert_eq!(
        server
            .post(
                &format!("/v1/projects/{project}/repos"),
                json!({"repo_id":"repo-a"})
            )
            .await,
        attached
    );
    server
        .post(
            &format!("/v1/projects/{project}/repos"),
            json!({"repo_id":"repo-c"}),
        )
        .await;
    for body in [
        json!({"repo_path":"/arbitrary/new-path"}),
        json!({"repo_id":"repo-a","path":"/injected/path"}),
    ] {
        assert_eq!(
            server
                .http
                .post(server.url(&format!("/v1/projects/{project}/repos")))
                .json(&body)
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::UNPROCESSABLE_ENTITY
        );
    }
    let foreign = Project {
        id: "foreign-project".into(),
        workspace_id: "foreign-workspace".into(),
        name: "Private name".into(),
        description: "Private description".into(),
        budget_cap_usd: None,
        created_at: 1,
        updated_at: 1,
    };
    first.store.put_project(&foreign).unwrap();
    for (pid, rid) in [
        (project.as_str(), "other-machine"),
        ("foreign-project", "repo-a"),
        ("missing", "repo-a"),
    ] {
        let response = server
            .http
            .post(server.url(&format!("/v1/projects/{pid}/repos")))
            .json(&json!({"repo_id":rid}))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
        assert_eq!(
            response.json::<Value>().await.unwrap(),
            json!({"error":"project resource not found"})
        );
    }
    drop(server);
    drop(first);
    let reopened = state(SqliteStore::open(&database.0).unwrap(), false);
    let server = Server::new(reopened, None).await;
    let page = server
        .get(&format!("/v1/projects/{project}/repos?limit=1"))
        .await;
    assert_eq!(page["repositories"][0]["id"], "repo-c");
    assert_eq!(page["next_cursor"], "repo-c");
    let last = server
        .get(&format!(
            "/v1/projects/{project}/repos?limit=1&after=repo-c"
        ))
        .await;
    assert_eq!(last["repositories"], json!([attached]));
    assert_eq!(last["next_cursor"], Value::Null);
}

#[tokio::test]
async fn task_history_is_scoped_paginated_and_keeps_project_context_across_restart() {
    let database = Database::new();
    let first = state(SqliteStore::open(&database.0).unwrap(), false);
    let registered = repo(&first, "shared-repo", None, "/fixture/shared-repo");
    let server = Server::new(Arc::clone(&first), None).await;
    let project = server.project("One").await;
    let other = server.project("Two").await;
    for pid in [&project, &other] {
        server
            .post(
                &format!("/v1/projects/{pid}/repos"),
                json!({"repo_id":registered.id}),
            )
            .await;
    }
    for id in ["task-a", "task-b", "task-c"] {
        insert_task(&first, &project, &registered, id, TaskStatus::Rejected);
    }
    insert_task(
        &first,
        &other,
        &registered,
        "task-private",
        TaskStatus::Rejected,
    );
    let first_page = server
        .get(&format!("/v1/projects/{project}/tasks?limit=2"))
        .await;
    assert_eq!(first_page["tasks"].as_array().unwrap().len(), 2);
    assert_eq!(first_page["tasks"][0]["id"], "task-c");
    assert_eq!(first_page["next_cursor"], "task-b");
    let last = server
        .get(&format!(
            "/v1/projects/{project}/tasks?limit=2&after=task-b"
        ))
        .await;
    assert_eq!(last["tasks"][0]["id"], "task-a");
    assert_eq!(last["next_cursor"], Value::Null);
    for suffix in ["", "/review", "/revert"] {
        let url = server.url(&format!(
            "/v1/projects/{project}/tasks/task-private{suffix}"
        ));
        let request = if suffix.is_empty() {
            server.http.get(url)
        } else {
            server.http.post(url).json(&json!({"decision":"reject"}))
        };
        let response = request.send().await.unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
        assert_eq!(
            response.json::<Value>().await.unwrap(),
            json!({"error":"project resource not found"})
        );
    }
    assert_eq!(
        first
            .store
            .get_task("task-private")
            .unwrap()
            .unwrap()
            .status,
        TaskStatus::Rejected
    );
    drop(server);
    drop(first);
    let server = Server::new(state(SqliteStore::open(&database.0).unwrap(), false), None).await;
    let detail = server
        .get(&format!("/v1/projects/{project}/tasks/task-c"))
        .await;
    assert_eq!(detail["prompt"], "Private prompt for task-c");
    assert_eq!(detail["status"], "rejected");
    assert!(detail.get("project_id").is_none());
}

#[tokio::test]
async fn retries_require_the_same_project_repository_and_scoped_route() {
    let state = state(SqliteStore::open_in_memory().unwrap(), true);
    let path = std::env::temp_dir().to_string_lossy().into_owned();
    let registered = repo(&state, "registered", None, &path);
    let another = repo(&state, "another", None, "/fixture/another");
    let server = Server::new(Arc::clone(&state), None).await;
    let project = server.project("One").await;
    let other = server.project("Two").await;
    for pid in [&project, &other] {
        for id in [&registered.id, &another.id] {
            server
                .post(&format!("/v1/projects/{pid}/repos"), json!({"repo_id":id}))
                .await;
        }
    }
    insert_task(
        &state,
        &project,
        &registered,
        "previous",
        TaskStatus::Rejected,
    );
    for (pid, rid) in [
        (other.as_str(), registered.id.as_str()),
        (project.as_str(), another.id.as_str()),
    ] {
        let response = server
            .http
            .post(server.url(&format!("/v1/projects/{pid}/tasks")))
            .json(&json!({"repo_id":rid,"prompt":"Retry","retry_of":"previous"}))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
        assert_eq!(
            response.json::<Value>().await.unwrap(),
            json!({"error":"project resource not found"})
        );
    }
    let legacy = server
        .http
        .post(server.url("/v1/tasks"))
        .json(&json!({"repo_path":path,"prompt":"Retry","retry_of":"previous"}))
        .send()
        .await
        .unwrap();
    assert_eq!(legacy.status(), StatusCode::CONFLICT);
    assert_eq!(
        legacy.json::<Value>().await.unwrap()["error"],
        "retry this task from its project"
    );
    assert_eq!(state.store.list_tasks(100).unwrap().len(), 1);
    assert_eq!(
        state
            .running_tasks
            .load(std::sync::atomic::Ordering::SeqCst),
        0
    );
}

#[tokio::test]
async fn workflow_validation_and_token_checks_run_before_mutation() {
    let state = state(SqliteStore::open_in_memory().unwrap(), false);
    let server = Server::new(Arc::clone(&state), None).await;
    let project = server.project("Validation").await;
    for suffix in ["repo-candidates", "repos", "tasks"] {
        for query in [
            "limit=0",
            "limit=101",
            "limit=-1",
            "after=",
            "workspace_id=foreign",
        ] {
            assert_eq!(
                server
                    .http
                    .get(server.url(&format!("/v1/projects/{project}/{suffix}?{query}")))
                    .send()
                    .await
                    .unwrap()
                    .status(),
                StatusCode::UNPROCESSABLE_ENTITY
            );
        }
    }
    for body in [
        json!({"repo_id":"x","prompt":" "}),
        json!({"repo_id":"x","prompt":"Valid","repo_path":"/injected"}),
        json!({"repo_id":"x","prompt":"Valid","max_steps":0}),
        json!({"repo_id":"x","prompt":"Valid","max_steps":257}),
        json!({"repo_id":"x","prompt":"Valid","budget_usd":-1}),
        json!({"repo_id":"x","prompt":"x".repeat(65537)}),
    ] {
        assert_eq!(
            server
                .http
                .post(server.url(&format!("/v1/projects/{project}/tasks")))
                .json(&body)
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::UNPROCESSABLE_ENTITY
        );
    }
    let protected = Server::new(Arc::clone(&state), Some("fixture-token")).await;
    for suffix in [
        "repo-candidates",
        "repos",
        "tasks",
        "tasks/missing",
        "tasks/missing/review",
        "tasks/missing/revert",
    ] {
        let url = protected.url(&format!("/v1/projects/{project}/{suffix}"));
        let request = if suffix.ends_with("review") || suffix.ends_with("revert") {
            protected.http.post(url).json(&json!({"decision":"reject"}))
        } else {
            protected.http.get(url)
        };
        assert_eq!(
            request.send().await.unwrap().status(),
            StatusCode::UNAUTHORIZED
        );
    }
    for suffix in ["repos", "tasks"] {
        assert_eq!(
            protected
                .http
                .post(protected.url(&format!("/v1/projects/{project}/{suffix}")))
                .json(&json!({"repo_id":"x","prompt":"Valid"}))
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
    }
    assert_eq!(
        protected
            .http
            .get(protected.url(&format!("/v1/projects/{project}/tasks")))
            .bearer_auth("fixture-token")
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );
    assert!(state.store.list_tasks(100).unwrap().is_empty());
}
