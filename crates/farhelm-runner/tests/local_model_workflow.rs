//! The configured local Chat Completions path, from task creation to review.
//!
//! Only inference is scripted. HTTP routing, policy, accounting, file tools,
//! command approval, Git worktrees, verification and review use production code.

use std::collections::VecDeque;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::post;
use axum::{Json, Router};
use farhelm_app::store::{TimeRange, prelude::*};
use farhelm_gateway::{Gateway, GatewayConfig, ProviderClient};
use farhelm_runner::state::AppState;
use farhelm_sqlite::SqliteStore;
use serde_json::{Value, json};

const UPSTREAM_MODEL: &str = "fixture-code";
const ACTUAL_MODEL: &str = "fixture-code-revision-2";
const LEDGER_MODEL: &str = "local/fixture/fixture-code-revision-2";
const BEFORE: &str = "fn greet() {\n    say(\"old\");\n}\n";
const AFTER: &str = "fn greet() {\n    say(\"new\");\n}\n";

#[derive(Default)]
struct Provider {
    replies: Mutex<VecDeque<Value>>,
    requests: Mutex<Vec<Value>>,
}

fn completion(message: Value, finish_reason: &str) -> Value {
    json!({
        "model": ACTUAL_MODEL,
        "choices": [{ "index": 0, "message": message, "finish_reason": finish_reason }],
        "usage": {
            "prompt_tokens": 120,
            "completion_tokens": 12,
            "prompt_tokens_details": { "cached_tokens": 20, "cache_write_tokens": 10 }
        }
    })
}

fn tool_call(id: &str, name: &str, arguments: Value) -> Value {
    completion(
        json!({
            "role": "assistant", "content": null,
            "tool_calls": [{
                "id": id, "type": "function",
                "function": { "name": name, "arguments": arguments.to_string() }
            }]
        }),
        "tool_calls",
    )
}

fn final_text(text: &str) -> Value {
    completion(json!({ "role": "assistant", "content": text }), "stop")
}

async fn chat_completions(
    State(provider): State<Arc<Provider>>,
    Json(body): Json<Value>,
) -> (StatusCode, Json<Value>) {
    provider.requests.lock().unwrap().push(body);
    match provider.replies.lock().unwrap().pop_front() {
        Some(reply) => (StatusCode::OK, Json(reply)),
        None => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": { "message": "fixture exhausted" } })),
        ),
    }
}

/// Abort fixture listeners when the test finishes, including assertion failures.
struct TestServer {
    addr: SocketAddr,
    task: tokio::task::JoinHandle<()>,
}

impl TestServer {
    async fn start(router: Router) -> Self {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let addr = listener.local_addr().unwrap();
        let task = tokio::spawn(async move {
            axum::serve(listener, router).await.unwrap();
        });
        Self { addr, task }
    }

    fn url(&self, path: &str) -> String {
        format!("http://{}{path}", self.addr)
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

struct TempRepo(PathBuf);

impl TempRepo {
    fn seeded() -> Self {
        let path = std::env::temp_dir().join(format!(
            "farhelm-local-workflow-{}",
            farhelm_app::id::new_id()
        ));
        // Never delete a pre-existing directory belonging to another test.
        std::fs::create_dir(&path).unwrap();
        let repo = Self(path);
        repo.git(&["init", "-q", "-b", "main"]);
        std::fs::write(repo.0.join("src.txt"), BEFORE).unwrap();
        repo.git(&["add", "src.txt"]);
        repo.git(&[
            "-c",
            "user.name=Farhelm fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "commit",
            "-q",
            "-m",
            "Seed greeting",
        ]);
        repo
    }

    fn git(&self, args: &[&str]) {
        let output = std::process::Command::new("git")
            .arg("-C")
            .arg(&self.0)
            .args(args)
            .output()
            .expect("Git is required for the native agent workflow");
        assert!(
            output.status.success(),
            "git {args:?} failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn read_source(&self) -> String {
        std::fs::read_to_string(self.0.join("src.txt")).unwrap()
    }
}

impl Drop for TempRepo {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn state_for(provider: &TestServer) -> Arc<AppState> {
    let client = ProviderClient::from_toml(&format!(
        r#"
version = 1
policy = "local_only"
[routes]
small = "local-code"
large = "local-code"
frontier = "local-code"
[providers.fixture]
kind = "openai_compatible"
base_url = "{}"
data_location = "local"
[models.local-code]
provider = "fixture"
model = "{UPSTREAM_MODEL}"
tools = true
max_output_tokens = 512
"#,
        provider.url("/v1")
    ))
    .unwrap();
    let config = GatewayConfig {
        models: client.models().unwrap(),
        ..GatewayConfig::default()
    };
    AppState::build(
        SqliteStore::open_in_memory().unwrap(),
        move |store| Some(Gateway::new(store, client, config)),
        Arc::new(farhelm_crypto::Identity::generate()),
        None,
    )
}

async fn get_json(http: &reqwest::Client, url: String) -> Value {
    http.get(url)
        .send()
        .await
        .unwrap()
        .error_for_status()
        .unwrap()
        .json()
        .await
        .unwrap()
}

async fn post_json(http: &reqwest::Client, url: String, body: Value) -> Value {
    http.post(url)
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

fn assert_tool_history(request: &Value, expected_ids: &[&str]) {
    let mut pending = VecDeque::new();
    let mut result_ids = Vec::new();
    for message in request["messages"].as_array().unwrap() {
        if let Some(calls) = message["tool_calls"].as_array() {
            assert_eq!(message["role"], "assistant");
            for call in calls {
                assert_eq!(call["type"], "function");
                let input: Value =
                    serde_json::from_str(call["function"]["arguments"].as_str().unwrap()).unwrap();
                assert!(input.is_object());
                pending.push_back(call["id"].as_str().unwrap());
            }
        }
        if message["role"] == "tool" {
            let id = message["tool_call_id"].as_str().unwrap();
            assert_eq!(pending.pop_front(), Some(id));
            // A successful result is the tool's plain output; only a failure
            // is wrapped with `is_error`.
            let result = message["content"].as_str().unwrap();
            assert!(
                serde_json::from_str::<Value>(result)
                    .map_or(true, |value| value.get("is_error").is_none()),
                "a success must not be wrapped: {result}"
            );
            match id {
                "read-1" => assert!(result.contains("say(\"old\")")),
                "edit-2" => assert_eq!(result, "edited src.txt"),
                "run-3" => assert!(result.starts_with("exit 0\n")),
                _ => panic!("unexpected tool result {id}"),
            }
            result_ids.push(id);
        }
    }
    assert!(
        pending.is_empty(),
        "tool calls were not paired with results"
    );
    assert_eq!(result_ids, expected_ids);
}

async fn supervised_reviewable_workflow(project_scoped: bool) {
    let repo = TempRepo::seeded();
    let provider = Arc::new(Provider {
        replies: Mutex::new(VecDeque::from([
            tool_call("read-1", "read_file", json!({ "path": "src.txt" })),
            tool_call(
                "edit-2",
                "edit_file",
                json!({ "path": "src.txt", "old_string": "\"old\"", "new_string": "\"new\"" }),
            ),
            // This fixed fixture command runs only after the test approves it.
            tool_call("run-3", "run", json!({ "command": "git diff --check" })),
            final_text("Changed the greeting and checked the diff."),
            final_text("VERDICT: pass\nThe greeting matches the requested change."),
        ])),
        ..Provider::default()
    });
    let model_server = TestServer::start(
        Router::new()
            .route("/v1/chat/completions", post(chat_completions))
            .with_state(Arc::clone(&provider)),
    )
    .await;
    let state = state_for(&model_server);
    let runner = TestServer::start(farhelm_runner::api::router(Arc::clone(&state))).await;
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .no_proxy()
        .build()
        .unwrap();

    let project_tasks = if project_scoped {
        let registered = farhelm_proto::types::Repo {
            id: "registered-fixture-repo".into(),
            machine_id: state.machine_id.clone(),
            path: repo.0.to_string_lossy().into_owned(),
            name: "Greeting fixture".into(),
            budget_usd: None,
        };
        state.store.upsert_repo(&registered).unwrap();
        let project = post_json(
            &http,
            runner.url("/v1/projects"),
            json!({"name":"Greeting project"}),
        )
        .await;
        let project_id = project["id"].as_str().unwrap();
        post_json(
            &http,
            runner.url(&format!("/v1/projects/{project_id}/repos")),
            json!({"repo_id":registered.id}),
        )
        .await;
        Some(format!("/v1/projects/{project_id}/tasks"))
    } else {
        None
    };
    let task_collection = project_tasks.as_deref().unwrap_or("/v1/tasks");
    let request = if project_scoped {
        json!({"repo_id":"registered-fixture-repo", "prompt":"Change the greeting from old to new and check the diff."})
    } else {
        json!({"repo_path":repo.0, "prompt":"Change the greeting from old to new and check the diff."})
    };
    let started = post_json(&http, runner.url(task_collection), request).await;
    assert_eq!(started["status"], "running");
    let task_id = started["id"].as_str().unwrap();
    let task_path = format!("{task_collection}/{task_id}");

    let approval = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let pending = get_json(&http, runner.url("/v1/approvals")).await;
            if let Some(approval) = pending.as_array().unwrap().first() {
                break approval.clone();
            }
            let task = get_json(&http, runner.url(&task_path)).await;
            assert_eq!(
                task["status"], "running",
                "task failed before approval: {task}"
            );
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("native agent did not request command approval");
    assert_eq!(approval["tool"], "run");
    assert_eq!(approval["payload"], "git diff --check");
    assert_eq!(provider.requests.lock().unwrap().len(), 3);
    assert_eq!(repo.read_source(), BEFORE);
    assert_eq!(
        get_json(&http, runner.url(&task_path)).await["status"],
        "running"
    );

    let approval_id = approval["id"].as_str().unwrap();
    post_json(
        &http,
        runner.url(&format!("/v1/approvals/{approval_id}/decision")),
        json!({ "decision": "approved", "via": "web" }),
    )
    .await;

    let task = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let task = get_json(&http, runner.url(&task_path)).await;
            if task["status"] == "awaiting_review" {
                break task;
            }
            assert_eq!(
                task["status"], "running",
                "task did not produce a review: {task}"
            );
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("native agent did not produce a reviewable diff");
    assert_eq!(task["files_changed"], 1);
    assert_eq!(task["lines_added"], 1);
    assert_eq!(task["lines_removed"], 1);
    assert_eq!(
        task["summary"],
        "Changed the greeting and checked the diff."
    );
    assert_eq!(task["verify_grade"], "pass");
    assert_eq!(task["verify_model"], LEDGER_MODEL);
    assert_eq!(task["cost_usd"], 0.0);
    assert!(
        task["patch"]
            .as_str()
            .unwrap()
            .contains("+    say(\"new\");")
    );
    assert_eq!(
        repo.read_source(),
        BEFORE,
        "a proposal bypassed human review"
    );

    let requests = provider.requests.lock().unwrap().clone();
    assert_eq!(
        requests.len(),
        5,
        "drafting and verification must use the configured provider"
    );
    assert!(provider.replies.lock().unwrap().is_empty());
    for request in &requests {
        assert_eq!(request["model"], UPSTREAM_MODEL);
        assert_eq!(request["max_tokens"], 512);
        assert_eq!(request["stream"], false);
    }
    assert_tool_history(&requests[0], &[]);
    assert_tool_history(&requests[1], &["read-1"]);
    assert_tool_history(&requests[2], &["read-1", "edit-2"]);
    assert_tool_history(&requests[3], &["read-1", "edit-2", "run-3"]);
    let verifier = &requests[4];
    assert!(verifier.get("tools").is_none());
    assert!(verifier.to_string().contains("+    say(\\\"new\\\");"));
    assert_tool_history(verifier, &[]);

    let session_id = task["session_id"].as_str().unwrap();
    let usage = state.store.list_usage(session_id, TimeRange::ALL).unwrap();
    assert_eq!(
        usage.len(),
        5,
        "zero-priced local inference still needs accounting"
    );
    for event in usage {
        assert_eq!(event.model, LEDGER_MODEL);
        assert_eq!(event.usage.input_tokens, 90);
        assert_eq!(event.usage.output_tokens, 12);
        assert_eq!(event.usage.cache_read_tokens, 20);
        assert_eq!(event.usage.cache_write_tokens, 10);
        assert_eq!(event.cost_usd, 0.0);
        assert!(
            event.avoided.is_none(),
            "scripted inference was incorrectly recorded as avoided"
        );
    }
    assert!(state.store.list_pending_approvals().unwrap().is_empty());

    let review_path = format!("{task_path}/review");
    let applied = post_json(
        &http,
        runner.url(&review_path),
        json!({ "decision": "approve", "via": "web" }),
    )
    .await;
    assert_eq!(applied["status"], "applied");
    assert_eq!(repo.read_source(), AFTER);
    let again = http
        .post(runner.url(&review_path))
        .json(&json!({ "decision": "approve", "via": "web" }))
        .send()
        .await
        .unwrap();
    assert_eq!(again.status(), StatusCode::CONFLICT);
    assert_eq!(repo.read_source(), AFTER);
    assert_eq!(provider.requests.lock().unwrap().len(), 5);
    if project_scoped {
        let page = get_json(&http, runner.url(task_collection)).await;
        assert_eq!(page["tasks"].as_array().unwrap().len(), 1);
        assert_eq!(page["tasks"][0]["id"], task_id);
        assert_eq!(page["tasks"][0]["status"], "applied");
        assert!(page["tasks"][0].get("project_id").is_none());
        let reverted = post_json(
            &http,
            runner.url(&format!("{task_path}/revert")),
            json!({"via":"web"}),
        )
        .await;
        assert_eq!(reverted["status"], "reverted");
        assert_eq!(repo.read_source(), BEFORE);
    }
}

#[tokio::test]
async fn configured_local_model_completes_a_supervised_reviewable_workflow() {
    supervised_reviewable_workflow(false).await;
}

#[tokio::test]
async fn project_task_uses_supervised_execution_review_and_revert() {
    supervised_reviewable_workflow(true).await;
}
