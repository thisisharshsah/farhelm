//! Projects through the real local HTTP API, including its scope and token boundary.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use farhelm_app::store::WorkspaceStore;
use farhelm_crypto::Identity;
use farhelm_proto::types::{Project, ProjectPage};
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
    async fn start(state: Arc<AppState>, auth: LocalAuth) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let (shutdown, signal) = oneshot::channel();
        let router = api::router_with_auth(state, auth);
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

    async fn create(&self, body: Value) -> Project {
        let response = self
            .http
            .post(format!("{}/v1/projects", self.url))
            .json(&body)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CREATED);
        response.json().await.unwrap()
    }

    async fn page(&self, query: &str) -> ProjectPage {
        let response = self
            .http
            .get(format!("{}/v1/projects{query}", self.url))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        response.json().await.unwrap()
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        if let Some(signal) = self.shutdown.take() {
            let _ = signal.send(());
        }
    }
}

fn state(store: SqliteStore) -> Arc<AppState> {
    AppState::build(store, |_| None, Arc::new(Identity::generate()), None)
}

struct Database(PathBuf);

impl Database {
    fn new() -> Self {
        Self(
            std::env::temp_dir().join(format!("farhelm-projects-{}.db", farhelm_app::id::new_id())),
        )
    }
}

impl Drop for Database {
    fn drop(&mut self) {
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{suffix}", self.0.display()));
        }
    }
}

#[tokio::test]
async fn create_list_and_detail_persist_across_runner_restart() {
    let database = Database::new();
    let before = farhelm_app::time::now_ms();
    let created = {
        let state = state(SqliteStore::open(&database.0).unwrap());
        let scope = state.store.local_workspace_id().unwrap();
        let server = Server::start(state, LocalAuth::open()).await;
        let empty = server.page("").await;
        assert!(empty.projects.is_empty());
        assert_eq!(empty.next_cursor, None);

        let created = server
            .create(json!({"name":"  Model research  ", "description":"Plan\n\tEvaluate"}))
            .await;
        assert_eq!(created.name, "Model research");
        assert_eq!(created.description, "Plan\n\tEvaluate");
        assert_eq!(created.workspace_id, scope);
        assert_eq!(created.budget_cap_usd, None);
        assert!(created.created_at >= before && created.created_at <= farhelm_app::time::now_ms());
        assert_eq!(created.updated_at, created.created_at);
        assert_eq!(created.id.len(), 36);
        assert_eq!(
            &created.id[14..15],
            "7",
            "identities are generated as UUIDv7"
        );
        assert_eq!(server.page("").await.projects, vec![created.clone()]);
        server.stop().await;
        created
    };

    let reopened = state(SqliteStore::open(&database.0).unwrap());
    assert_eq!(
        reopened.store.local_workspace_id().unwrap(),
        created.workspace_id
    );
    let server = Server::start(reopened, LocalAuth::open()).await;
    let response = server
        .http
        .get(format!("{}/v1/projects/{}", server.url, created.id))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.json::<Project>().await.unwrap(), created);
    assert_eq!(server.page("").await.projects, vec![created]);
    server.stop().await;
}

#[tokio::test]
async fn bounded_keyset_pages_do_not_repeat_rows_when_a_new_project_is_added() {
    let server = Server::start(
        state(SqliteStore::open_in_memory().unwrap()),
        LocalAuth::open(),
    )
    .await;
    let mut created = Vec::new();
    for index in 0..5 {
        created.push(
            server
                .create(json!({"name":format!("Project {index}")}))
                .await,
        );
    }
    let first = server.page("?limit=2").await;
    assert_eq!(first.projects, vec![created[4].clone(), created[3].clone()]);
    assert_eq!(first.next_cursor.as_deref(), Some(created[3].id.as_str()));

    let newest = server.create(json!({"name":"Added between pages"})).await;
    let mut collected = first.projects;
    let mut cursor = first.next_cursor;
    while let Some(after) = cursor {
        let next = server.page(&format!("?limit=2&after={after}")).await;
        assert!(
            !next.projects.is_empty(),
            "a returned cursor must lead to another row"
        );
        assert!(next.projects.len() <= 2);
        collected.extend(next.projects);
        cursor = next.next_cursor;
        assert!(
            collected.len() <= 5,
            "pagination must terminate without repeating rows"
        );
    }
    created.reverse();
    assert_eq!(collected, created);
    let unique: BTreeSet<_> = collected.iter().map(|project| &project.id).collect();
    assert_eq!(unique.len(), 5);
    assert_eq!(server.page("?limit=100").await.projects[0], newest);
    server.stop().await;
}

#[tokio::test]
async fn foreign_projects_are_hidden_and_cannot_be_requested_as_a_workspace() {
    let state = state(SqliteStore::open_in_memory().unwrap());
    let foreign = Project {
        id: farhelm_app::id::new_id(),
        workspace_id: "another-workspace".into(),
        name: "Private foreign project".into(),
        description: "Private foreign description".into(),
        budget_cap_usd: None,
        created_at: 1,
        updated_at: 1,
    };
    state.store.put_project(&foreign).unwrap();
    let server = Server::start(Arc::clone(&state), LocalAuth::open()).await;
    let own = server.create(json!({"name":"Local project"})).await;
    assert_eq!(server.page("").await.projects, vec![own]);

    let foreign_response = server
        .http
        .get(format!("{}/v1/projects/{}", server.url, foreign.id))
        .send()
        .await
        .unwrap();
    let missing_response = server
        .http
        .get(format!(
            "{}/v1/projects/{}",
            server.url,
            farhelm_app::id::new_id()
        ))
        .send()
        .await
        .unwrap();
    assert_eq!(foreign_response.status(), StatusCode::NOT_FOUND);
    assert_eq!(missing_response.status(), StatusCode::NOT_FOUND);
    assert_eq!(
        foreign_response.json::<Value>().await.unwrap(),
        missing_response.json::<Value>().await.unwrap()
    );

    let response = server
        .http
        .get(format!(
            "{}/v1/projects?workspace_id=another-workspace",
            server.url
        ))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(state.store.get_project(&foreign.id).unwrap(), Some(foreign));
    server.stop().await;
}

#[tokio::test]
async fn scope_injection_and_invalid_content_never_create_a_project() {
    let state = state(SqliteStore::open_in_memory().unwrap());
    let server = Server::start(Arc::clone(&state), LocalAuth::open()).await;
    for body in [
        json!({"name":"Injected", "workspace_id":"another-workspace"}),
        json!({"name":"Injected", "id":farhelm_app::id::new_id()}),
        json!({"name":"Injected", "budget_cap_usd":100.0}),
        json!({"name":"   "}),
        json!({"name":"Line\nBreak"}),
        json!({"name":"é".repeat(121)}),
        json!({"name":"Valid", "description":"x".repeat(4001)}),
        json!({"name":"Valid", "description":"hidden\u{1b}escape"}),
    ] {
        let response = server
            .http
            .post(format!("{}/v1/projects", server.url))
            .json(&body)
            .send()
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::UNPROCESSABLE_ENTITY,
            "invalid body: {body}"
        );
    }
    let response = server
        .http
        .post(format!("{}/v1/projects", server.url))
        .header("content-type", "application/json")
        .body("{\"name\":")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let response = server
        .http
        .post(format!("{}/v1/projects", server.url))
        .json(&json!({"name":"Valid", "description":"x".repeat(25 * 1024)}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
    assert!(server.page("").await.projects.is_empty());
    assert!(
        state
            .store
            .list_projects(&state.store.local_workspace_id().unwrap())
            .unwrap()
            .is_empty()
    );
    server.stop().await;
}

#[tokio::test]
async fn malformed_pagination_is_rejected_instead_of_becoming_an_unbounded_query() {
    let server = Server::start(
        state(SqliteStore::open_in_memory().unwrap()),
        LocalAuth::open(),
    )
    .await;
    for query in [
        "?limit=0",
        "?limit=101",
        "?limit=-1",
        "?limit=many",
        "?limit=18446744073709551616",
        "?after=",
        "?after=not-a-uuid",
        "?after=019A10A0-0000-7000-8000-000000000000",
        "?after=019a10a0000070008000000000000000",
        "?after=line%0Abreak",
    ] {
        let response = server
            .http
            .get(format!("{}/v1/projects{query}", server.url))
            .send()
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::UNPROCESSABLE_ENTITY,
            "query {query}"
        );
    }
    server.stop().await;
}

#[tokio::test]
async fn projects_share_the_runner_token_boundary() {
    let state = state(SqliteStore::open_in_memory().unwrap());
    let server = Server::start(
        Arc::clone(&state),
        LocalAuth::with_token("fixture-local-token"),
    )
    .await;
    for path in [
        "/v1/projects",
        "/v1/projects/019a10a0-0000-7000-8000-000000000000",
    ] {
        let response = server
            .http
            .get(format!("{}{path}", server.url))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }
    let response = server
        .http
        .post(format!("{}/v1/projects", server.url))
        .json(&json!({"name":"Unauthorized write"}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    assert!(
        state
            .store
            .list_projects(&state.store.local_workspace_id().unwrap())
            .unwrap()
            .is_empty()
    );

    let response = server
        .http
        .post(format!("{}/v1/projects", server.url))
        .bearer_auth("fixture-local-token")
        .json(&json!({"name":"Authorized write"}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    let created: Project = response.json().await.unwrap();
    for path in [
        "/v1/projects".to_owned(),
        format!("/v1/projects/{}", created.id),
    ] {
        let response = server
            .http
            .get(format!("{}{path}", server.url))
            .bearer_auth("fixture-local-token")
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
    }
    let response = server
        .http
        .get(format!("{}/v1/projects", server.url))
        .bearer_auth("incorrect-token")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(
        server
            .http
            .get(format!("{}/v1/health", server.url))
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );
    server.stop().await;
}
