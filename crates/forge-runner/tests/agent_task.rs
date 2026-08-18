//! A native agent task, end to end, over real HTTP.
//!
//! Everything except the model is real: the runner's own router, the cost
//! gateway, the Messages-API client, the approval queue, the staging overlay,
//! the review endpoint, and the write to disk. The model is a stand-in server
//! answering with the documented `tool_use` shape, which means this exercises
//! the wire format rather than a Rust struct somebody hand-built.
//!
//! What it proves, in order:
//!
//! 1. `POST /v1/tasks` returns immediately and the loop runs detached.
//! 2. An `edit_file` reaches the staging overlay and **not** the working tree.
//! 3. A `run` raises an approval, is classified, and blocks until answered.
//! 4. The task lands in `awaiting_review` with a diff a client can render.
//! 5. `POST /v1/tasks/{id}/review` writes exactly what was reviewed.
//!
//! And the two refusals that matter: a change set cannot be approved from a
//! watch, and a second approval cannot apply it twice.

use forge_sqlite::SqliteStore;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::State;
use axum::routing::post;
use axum::{Json, Router};
use forge_app::store::prelude::*;
use forge_gateway::{AnthropicClient, Gateway, GatewayConfig};
use forge_proto::types::TaskStatus;
use forge_runner::state::AppState;

/// The scripted replies, in order. Each is a Messages API response body.
#[derive(Default)]
struct Provider {
    replies: Mutex<Vec<serde_json::Value>>,
    /// Every request body received, so prompt shape can be asserted.
    seen: Mutex<Vec<serde_json::Value>>,
}

fn tool_use(id: &str, name: &str, input: serde_json::Value) -> serde_json::Value {
    serde_json::json!({
        "model": "claude-sonnet-5",
        "content": [{ "type": "tool_use", "id": id, "name": name, "input": input }],
        "stop_reason": "tool_use",
        "usage": { "input_tokens": 400, "output_tokens": 90,
                   "cache_creation_input_tokens": 0, "cache_read_input_tokens": 1200 }
    })
}

fn final_text(text: &str) -> serde_json::Value {
    serde_json::json!({
        "model": "claude-sonnet-5",
        "content": [{ "type": "text", "text": text }],
        "stop_reason": "end_turn",
        "usage": { "input_tokens": 300, "output_tokens": 40,
                   "cache_creation_input_tokens": 0, "cache_read_input_tokens": 1800 }
    })
}

async fn messages(
    State(provider): State<Arc<Provider>>,
    Json(body): Json<serde_json::Value>,
) -> Json<serde_json::Value> {
    provider.seen.lock().unwrap().push(body);
    let mut replies = provider.replies.lock().unwrap();
    Json(if replies.is_empty() {
        final_text("(the script ran out)")
    } else {
        replies.remove(0)
    })
}

async fn spawn_provider(provider: Arc<Provider>) -> SocketAddr {
    let app = Router::new()
        .route("/v1/messages", post(messages))
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

/// Runner state whose gateway points at the stand-in provider.
fn state_for(provider_addr: SocketAddr) -> Arc<AppState> {
    AppState::build(
        SqliteStore::open_in_memory().unwrap(),
        move |store| {
            Some(Gateway::new(
                store,
                AnthropicClient::new("test-key")
                    .with_base_url(format!("http://{provider_addr}"))
                    // The stand-in does not implement the fallback beta header.
                    .without_fallbacks(),
                GatewayConfig::default(),
            ))
        },
        Arc::new(forge_crypto::Identity::generate()),
        None,
    )
}

struct TempRepo(PathBuf);

impl TempRepo {
    /// A real repository — a task cuts a branch before it does anything, so
    /// there is no running one outside git.
    fn new(name: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("forge-e2e-{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let repo = Self(dir);
        repo.git(&["init", "-q", "-b", "main"]);
        repo
    }

    fn git(&self, args: &[&str]) {
        let status = std::process::Command::new("git")
            .arg("-C")
            .arg(&self.0)
            .args(args)
            .status()
            .expect("git should be installed");
        assert!(status.success(), "git {args:?} failed");
    }

    /// Commit what has been written, so the branch has a base to cut from.
    /// A task cuts from `HEAD`, so uncommitted content is content it will not
    /// see.
    fn commit(&self) {
        self.git(&["add", "-A"]);
        self.git(&[
            "-c",
            "user.name=test",
            "-c",
            "user.email=test@example.invalid",
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            "base",
        ]);
    }

    fn write(&self, relative: &str, content: &str) {
        std::fs::write(self.0.join(relative), content).unwrap();
    }
    fn read(&self, relative: &str) -> String {
        std::fs::read_to_string(self.0.join(relative)).unwrap()
    }
    fn path(&self) -> String {
        self.0.display().to_string()
    }
}

impl Drop for TempRepo {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Serve the runner's real router on a loopback port.
async fn spawn_runner(state: Arc<AppState>) -> String {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let addr = listener.local_addr().unwrap();
    let router = forge_runner::api::router(state);
    tokio::spawn(async move {
        let _ = axum::serve(listener, router).await;
    });
    format!("http://{addr}")
}

/// Poll until a task reaches a status, or give up.
async fn wait_for_status(
    http: &reqwest::Client,
    base: &str,
    task_id: &str,
    status: TaskStatus,
) -> serde_json::Value {
    for _ in 0..200 {
        let task: serde_json::Value = http
            .get(format!("{base}/v1/tasks/{task_id}"))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        if task["status"] == status.as_str() {
            return task;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("task never reached {status}");
}

#[tokio::test]
async fn a_task_proposes_a_diff_and_only_writes_it_once_approved() {
    let repo = TempRepo::new("propose");
    repo.write("src.txt", "fn greet() {\n    say(\"old\");\n}\n");
    repo.commit();

    let provider = Arc::new(Provider {
        replies: Mutex::new(vec![
            tool_use(
                "toolu_1",
                "read_file",
                serde_json::json!({ "path": "src.txt" }),
            ),
            tool_use(
                "toolu_2",
                "edit_file",
                serde_json::json!({
                    "path": "src.txt",
                    "old_string": "\"old\"",
                    "new_string": "\"new\""
                }),
            ),
            final_text("Replaced the greeting string."),
        ]),
        seen: Mutex::new(Vec::new()),
    });

    let addr = spawn_provider(Arc::clone(&provider)).await;
    let state = state_for(addr);
    let base = spawn_runner(Arc::clone(&state)).await;
    let http = reqwest::Client::new();

    let started: serde_json::Value = http
        .post(format!("{base}/v1/tasks"))
        .json(&serde_json::json!({
            "repo_path": repo.path(),
            "prompt": "Change the greeting to new"
        }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    // Returns immediately, before the loop has done anything.
    assert_eq!(started["status"], "running");
    let task_id = started["id"].as_str().unwrap().to_owned();

    let task = wait_for_status(&http, &base, &task_id, TaskStatus::AwaitingReview).await;

    assert_eq!(task["files_changed"], 1);
    assert_eq!(task["lines_added"], 1);
    assert_eq!(task["lines_removed"], 1);
    assert_eq!(task["change_summary"], "1 file, +1 −1");
    assert_eq!(task["summary"], "Replaced the greeting string.");
    assert!(
        task["cost_usd"].as_f64().unwrap() > 0.0,
        "the task was billed nothing — the ledger never saw it"
    );

    // The diff is structured, not a blob the client has to parse.
    let file = &task["changes"]["files"][0];
    assert_eq!(file["path"], "src.txt");
    assert_eq!(file["kind"], "modified");
    assert!(
        task["patch"]
            .as_str()
            .unwrap()
            .contains("+    say(\"new\");")
    );

    // Nothing has touched the working tree.
    assert_eq!(repo.read("src.txt"), "fn greet() {\n    say(\"old\");\n}\n");

    // A watch cannot approve a change set.
    let refused = http
        .post(format!("{base}/v1/tasks/{task_id}/review"))
        .json(&serde_json::json!({ "decision": "approve", "via": "watch" }))
        .send()
        .await
        .unwrap();
    assert_eq!(refused.status(), 409);
    assert_eq!(repo.read("src.txt"), "fn greet() {\n    say(\"old\");\n}\n");

    // A phone can.
    let applied: serde_json::Value = http
        .post(format!("{base}/v1/tasks/{task_id}/review"))
        .json(&serde_json::json!({ "decision": "approve", "via": "phone" }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    assert_eq!(applied["status"], "applied");
    assert_eq!(repo.read("src.txt"), "fn greet() {\n    say(\"new\");\n}\n");

    // And a second tap does not apply it again.
    let again = http
        .post(format!("{base}/v1/tasks/{task_id}/review"))
        .json(&serde_json::json!({ "decision": "approve", "via": "web" }))
        .send()
        .await
        .unwrap();
    assert_eq!(again.status(), 409);
}

#[tokio::test]
async fn a_command_the_agent_wants_to_run_raises_an_approval_and_blocks() {
    let repo = TempRepo::new("approval");
    repo.write("a.txt", "x\n");
    repo.commit();

    let provider = Arc::new(Provider {
        replies: Mutex::new(vec![
            tool_use(
                "toolu_1",
                "run",
                // Destructive on purpose: the classifier has to see it.
                serde_json::json!({ "command": "rm -rf build" }),
            ),
            final_text("I did not run it."),
        ]),
        seen: Mutex::new(Vec::new()),
    });

    let addr = spawn_provider(Arc::clone(&provider)).await;
    let state = state_for(addr);
    let base = spawn_runner(Arc::clone(&state)).await;
    let http = reqwest::Client::new();

    http.post(format!("{base}/v1/tasks"))
        .json(&serde_json::json!({ "repo_path": repo.path(), "prompt": "clean up" }))
        .send()
        .await
        .unwrap();

    // The loop blocks here until somebody answers.
    let approval = loop {
        let pending: Vec<serde_json::Value> = http
            .get(format!("{base}/v1/approvals"))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        if let Some(first) = pending.first() {
            break first.clone();
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    };

    assert_eq!(approval["tool"], "run");
    assert_eq!(approval["payload"], "rm -rf build");
    assert_eq!(
        approval["risk"], "destructive",
        "the runner's own agent skipped the classifier"
    );

    // A watch cannot clear a destructive command, whichever agent asked.
    let approval_id = approval["id"].as_str().unwrap();
    let refused = http
        .post(format!("{base}/v1/approvals/{approval_id}/decision"))
        .json(&serde_json::json!({ "decision": "approved", "via": "watch" }))
        .send()
        .await
        .unwrap();
    assert_eq!(refused.status(), 403);

    // Deny it from the phone; the agent is told, and finishes.
    http.post(format!("{base}/v1/approvals/{approval_id}/decision"))
        .json(&serde_json::json!({ "decision": "denied", "via": "phone" }))
        .send()
        .await
        .unwrap();

    let tasks: Vec<serde_json::Value> = loop {
        let tasks: Vec<serde_json::Value> = http
            .get(format!("{base}/v1/tasks"))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        if tasks
            .first()
            .is_some_and(|task| task["status"] != "running")
        {
            break tasks;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    };

    assert_eq!(tasks[0]["status"], "no_changes");
    assert!(!repo.0.join("build").exists());

    let decided = state.store.list_pending_approvals().unwrap();
    assert!(decided.is_empty(), "the approval was never settled");
}

#[tokio::test]
async fn the_prompt_sent_to_the_provider_is_cache_shaped() {
    // The loop is the gateway's biggest caller. If its prompts do not carry
    // breakpoints, the cost reduction the project commits to is fiction.
    //
    // The repo below is deliberately *realistic* rather than minimal. Tools
    // plus the frozen system prompt come to roughly 875 tokens, and Sonnet 5
    // will not cache a prefix under 1024 — so a one-file fixture produces no
    // breakpoint, correctly, and would have tested nothing. The repo map is
    // what carries the prefix over the line in real use, and it only exists if
    // there is something to retrieve.
    let repo = TempRepo::new("cacheshape");
    repo.commit();
    for index in 0..8 {
        repo.write(
            &format!("retry_{index}.rs"),
            &format!(
                "// retry backoff, module {index}\n\
                 pub fn retry_backoff(attempts: u32) -> u64 {{\n\
                 \x20   let backoff = 1u64 << attempts.min(10);\n\
                 \x20   backoff.min(30_000)\n\
                 }}\n"
            )
            .repeat(12),
        );
    }

    let provider = Arc::new(Provider {
        replies: Mutex::new(vec![
            tool_use("toolu_1", "list_files", serde_json::json!({})),
            final_text("done"),
        ]),
        seen: Mutex::new(Vec::new()),
    });

    let addr = spawn_provider(Arc::clone(&provider)).await;
    let state = state_for(addr);
    let base = spawn_runner(Arc::clone(&state)).await;
    let http = reqwest::Client::new();

    let started: serde_json::Value = http
        .post(format!("{base}/v1/tasks"))
        .json(&serde_json::json!({
            "repo_path": repo.path(),
            "prompt": "Explain the retry backoff behaviour"
        }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    wait_for_status(
        &http,
        &base,
        started["id"].as_str().unwrap(),
        TaskStatus::NoChanges,
    )
    .await;

    let seen = provider.seen.lock().unwrap();
    assert_eq!(seen.len(), 2, "expected two turns");

    let first = &seen[0];
    // Tools are sent, and in the order `forge_agent::tools::definitions` fixes.
    let tools = first["tools"].as_array().expect("tools were not sent");
    assert_eq!(tools[0]["name"], "read_file");
    assert_eq!(tools.last().unwrap()["name"], "run");

    let system = first["system"].as_array().expect("system was not sent");
    assert!(
        system
            .iter()
            .any(|block| block["cache_control"]["type"] == "ephemeral"),
        "no breakpoint on the system blocks: {system:#?}"
    );

    // The second turn's system half is byte-identical to the first's. That is
    // the whole property: a prefix that moved would be rewritten rather than
    // read, and every breakpoint ahead of the change would score zero. It is
    // also why step 2 does not re-run retrieval — a repo map recomputed from a
    // different instruction would land here as different bytes.
    assert_eq!(first["system"], seen[1]["system"]);
    assert_eq!(first["tools"], seen[1]["tools"]);

    // History grows by appending, so turn 2's messages start with turn 1's.
    let first_messages = first["messages"].as_array().unwrap();
    let second_messages = seen[1]["messages"].as_array().unwrap();
    assert!(second_messages.len() > first_messages.len());
    assert_eq!(
        second_messages[0]["content"][0]["text"],
        first_messages[0]["content"][0]["text"]
    );

    // No sampling parameters, which the current models reject outright.
    for rejected in ["temperature", "top_p", "top_k"] {
        assert!(first.get(rejected).is_none(), "{rejected} was sent");
    }
}

/// Reject → retry → approve. The loop the review screen exists to close.
#[tokio::test]
async fn a_rejected_change_set_comes_back_carrying_the_reason_it_was_refused() {
    let repo = TempRepo::new("retry");
    repo.write("a.txt", "original\n");
    repo.commit();

    let provider = Arc::new(Provider {
        replies: Mutex::new(vec![
            // First attempt: does the wrong thing.
            tool_use(
                "toolu_1",
                "write_file",
                serde_json::json!({ "path": "a.txt", "content": "wrong\n" }),
            ),
            final_text("Rewrote it."),
            // C10 fires after every change set, including this one.
            final_text("VERDICT: pass\nLooks consistent with the ask."),
            // Second attempt, after the rejection.
            tool_use(
                "toolu_2",
                "write_file",
                serde_json::json!({ "path": "a.txt", "content": "right\n" }),
            ),
            final_text("Rewrote it properly this time."),
            final_text("VERDICT: pass\nBetter."),
        ]),
        seen: Mutex::new(Vec::new()),
    });

    let addr = spawn_provider(Arc::clone(&provider)).await;
    let state = state_for(addr);
    let base = spawn_runner(Arc::clone(&state)).await;
    let http = reqwest::Client::new();

    let first: serde_json::Value = http
        .post(format!("{base}/v1/tasks"))
        .json(&serde_json::json!({
            "repo_path": repo.path(), "prompt": "Fix the greeting"
        }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let first_id = first["id"].as_str().unwrap().to_owned();
    wait_for_status(&http, &base, &first_id, TaskStatus::AwaitingReview).await;

    // Reject it, with a reason.
    let rejected: serde_json::Value = http
        .post(format!("{base}/v1/tasks/{first_id}/review"))
        .json(&serde_json::json!({
            "decision": "reject",
            "via": "phone",
            "note": "that is not the greeting, it is the error message"
        }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(rejected["status"], "rejected");
    assert_eq!(
        repo.read("a.txt"),
        "original\n",
        "a rejection wrote to disk"
    );

    // Retry it.
    let retry: serde_json::Value = http
        .post(format!("{base}/v1/tasks"))
        .json(&serde_json::json!({
            "repo_path": repo.path(),
            "prompt": "Fix the greeting",
            "retry_of": first_id
        }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let retry_id = retry["id"].as_str().unwrap().to_owned();
    wait_for_status(&http, &base, &retry_id, TaskStatus::AwaitingReview).await;

    // The reason, the previous summary, and the refused patch all reached the
    // model — which is the entire point of storing `review_note`.
    //
    // Request 0 and 1 are the first attempt's drafting turns, 2 is its
    // verification, so 3 is the retry's opening instruction.
    let retry_request = provider.seen.lock().unwrap()[3].clone();
    let sent = retry_request.to_string();
    assert!(
        sent.contains("that is not the greeting"),
        "the rejection reason never reached the model"
    );
    assert!(sent.contains("was rejected"));
    assert!(sent.contains("+wrong"), "the refused patch was not shown");

    // The row still reads as the human's ask, not as a wall of patch.
    assert_eq!(retry["prompt"], "Fix the greeting");

    // And the original is untouched: a retry sits beside a rejection, never
    // replaces it.
    let original: serde_json::Value = http
        .get(format!("{base}/v1/tasks/{first_id}"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(original["status"], "rejected");
    assert_eq!(
        original["review_note"],
        "that is not the greeting, it is the error message"
    );

    http.post(format!("{base}/v1/tasks/{retry_id}/review"))
        .json(&serde_json::json!({ "decision": "approve", "via": "phone" }))
        .send()
        .await
        .unwrap();
    assert_eq!(repo.read("a.txt"), "right\n");
}

/// C10, from the provider's JSON to the field a review card reads.
#[tokio::test]
async fn the_frontier_models_read_of_the_diff_lands_on_the_review_card() {
    let repo = TempRepo::new("verify");
    repo.write("a.txt", "before\n");
    repo.commit();

    let provider = Arc::new(Provider {
        replies: Mutex::new(vec![
            tool_use(
                "toolu_1",
                "write_file",
                serde_json::json!({ "path": "a.txt", "content": "after\n" }),
            ),
            final_text("Rewrote it."),
            // The verification turn.
            final_text("VERDICT: concerns\nNothing tests the new value."),
        ]),
        seen: Mutex::new(Vec::new()),
    });

    let addr = spawn_provider(Arc::clone(&provider)).await;
    let state = state_for(addr);
    let base = spawn_runner(Arc::clone(&state)).await;
    let http = reqwest::Client::new();

    let started: serde_json::Value = http
        .post(format!("{base}/v1/tasks"))
        .json(&serde_json::json!({ "repo_path": repo.path(), "prompt": "rewrite it" }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let task = wait_for_status(
        &http,
        &base,
        started["id"].as_str().unwrap(),
        TaskStatus::AwaitingReview,
    )
    .await;

    assert_eq!(task["verify_grade"], "concerns");
    assert_eq!(task["verify_notes"], "Nothing tests the new value.");

    // Three provider calls: two drafting, one verifying.
    let seen = provider.seen.lock().unwrap();
    assert_eq!(seen.len(), 3);

    let verifier = &seen[2];
    // Routed to the frontier model, unlike the drafting turns.
    assert_eq!(verifier["model"], "claude-opus-5");
    assert_eq!(seen[0]["model"], "claude-sonnet-5");

    // And it was sent the patch, with no tools and no history to carry.
    let sent = verifier.to_string();
    assert!(
        sent.contains("+after"),
        "the verifier was not sent the patch"
    );
    assert!(
        verifier.get("tools").is_none(),
        "the verifier was given tools"
    );
    assert_eq!(
        verifier["messages"].as_array().unwrap().len(),
        1,
        "the verifier was sent conversation history"
    );

    // Its cost is in the task's total, not hidden.
    assert!(task["cost_usd"].as_f64().unwrap() > 0.0);
}

#[tokio::test]
async fn a_verification_that_cannot_be_parsed_never_reads_as_a_pass() {
    let repo = TempRepo::new("unparseable");
    repo.write("a.txt", "before\n");
    repo.commit();

    let provider = Arc::new(Provider {
        replies: Mutex::new(vec![
            tool_use(
                "toolu_1",
                "write_file",
                serde_json::json!({ "path": "a.txt", "content": "after\n" }),
            ),
            final_text("done"),
            // No VERDICT line at all.
            final_text("Honestly this seems completely fine to me."),
        ]),
        seen: Mutex::new(Vec::new()),
    });

    let addr = spawn_provider(Arc::clone(&provider)).await;
    let base = spawn_runner(state_for(addr)).await;
    let http = reqwest::Client::new();

    let started: serde_json::Value = http
        .post(format!("{base}/v1/tasks"))
        .json(&serde_json::json!({ "repo_path": repo.path(), "prompt": "x" }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let task = wait_for_status(
        &http,
        &base,
        started["id"].as_str().unwrap(),
        TaskStatus::AwaitingReview,
    )
    .await;

    assert_eq!(
        task["verify_grade"], "concerns",
        "an unreadable verdict was reported as a pass"
    );
}

#[tokio::test]
async fn a_waiting_change_set_reaches_the_home_screen_and_the_task_list() {
    let repo = TempRepo::new("fleet");
    repo.write("a.txt", "before\n");
    repo.commit();

    let provider = Arc::new(Provider {
        replies: Mutex::new(vec![
            tool_use(
                "toolu_1",
                "write_file",
                serde_json::json!({ "path": "a.txt", "content": "after\n" }),
            ),
            final_text("done"),
        ]),
        seen: Mutex::new(Vec::new()),
    });

    let addr = spawn_provider(Arc::clone(&provider)).await;
    let state = state_for(addr);
    let base = spawn_runner(Arc::clone(&state)).await;
    let http = reqwest::Client::new();

    let started: serde_json::Value = http
        .post(format!("{base}/v1/tasks"))
        .json(&serde_json::json!({ "repo_path": repo.path(), "prompt": "x" }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let id = started["id"].as_str().unwrap().to_owned();
    wait_for_status(&http, &base, &id, TaskStatus::AwaitingReview).await;

    // The home screen carries it, so a woken phone renders in one round trip.
    let fleet: serde_json::Value = http
        .get(format!("{base}/v1/fleet"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let waiting = fleet["tasks_awaiting_review"].as_array().unwrap();
    assert_eq!(waiting.len(), 1);
    assert_eq!(waiting[0]["change_summary"], "1 file, +1 −1");
    // And no diff rides along on it.
    assert!(waiting[0].get("changes").is_none());

    // Once decided it drops off, rather than sitting there already answered.
    http.post(format!("{base}/v1/tasks/{id}/review"))
        .json(&serde_json::json!({ "decision": "approve", "via": "web" }))
        .send()
        .await
        .unwrap();

    let fleet: serde_json::Value = http
        .get(format!("{base}/v1/fleet"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert!(
        fleet["tasks_awaiting_review"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}

/// Apply → undo. The property that makes "Apply to disk" safe to press.
#[tokio::test]
async fn an_applied_change_set_can_be_taken_back_off_disk() {
    let repo = TempRepo::new("undo");
    repo.write("a.txt", "original\n");
    repo.commit();

    let provider = Arc::new(Provider {
        replies: Mutex::new(vec![
            tool_use(
                "toolu_1",
                "write_file",
                serde_json::json!({ "path": "a.txt", "content": "changed\n" }),
            ),
            final_text("Changed it."),
            final_text("VERDICT: pass\nFine."),
        ]),
        seen: Mutex::new(Vec::new()),
    });

    let addr = spawn_provider(Arc::clone(&provider)).await;
    let base = spawn_runner(state_for(addr)).await;
    let http = reqwest::Client::new();

    let started: serde_json::Value = http
        .post(format!("{base}/v1/tasks"))
        .json(&serde_json::json!({ "repo_path": repo.path(), "prompt": "change it" }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let id = started["id"].as_str().unwrap().to_owned();
    wait_for_status(&http, &base, &id, TaskStatus::AwaitingReview).await;

    // Undo is not offered before it lands.
    let too_early = http
        .post(format!("{base}/v1/tasks/{id}/revert"))
        .json(&serde_json::json!({ "via": "web" }))
        .send()
        .await
        .unwrap();
    assert_eq!(too_early.status(), 409);

    http.post(format!("{base}/v1/tasks/{id}/review"))
        .json(&serde_json::json!({ "decision": "approve", "via": "phone" }))
        .send()
        .await
        .unwrap();
    assert_eq!(repo.read("a.txt"), "changed\n");

    let undone: serde_json::Value = http
        .post(format!("{base}/v1/tasks/{id}/revert"))
        .json(&serde_json::json!({ "via": "phone" }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    assert_eq!(undone["status"], "reverted");
    assert_eq!(repo.read("a.txt"), "original\n");

    // And it cannot be undone twice back into the change it just removed.
    let again = http
        .post(format!("{base}/v1/tasks/{id}/revert"))
        .json(&serde_json::json!({ "via": "web" }))
        .send()
        .await
        .unwrap();
    assert_eq!(again.status(), 409);
    assert_eq!(repo.read("a.txt"), "original\n");
}

/// The cost guard: fifty POSTs must not become fifty agents.
#[tokio::test]
async fn the_runner_refuses_to_draft_more_tasks_than_its_ceiling() {
    let repo = TempRepo::new("cap");
    repo.write("a.txt", "x\n");
    repo.commit();

    // A provider that never answers, so every started task stays in the loop
    // holding its slot for the duration of this test.
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let app = Router::new().route(
            "/v1/messages",
            post(|| async {
                tokio::time::sleep(Duration::from_secs(30)).await;
                Json(serde_json::json!({}))
            }),
        );
        let _ = axum::serve(listener, app).await;
    });

    let base = spawn_runner(state_for(addr)).await;
    let http = reqwest::Client::new();

    let start = || {
        http.post(format!("{base}/v1/tasks"))
            .json(&serde_json::json!({ "repo_path": repo.path(), "prompt": "x" }))
            .send()
    };

    let mut accepted = 0;
    let mut refused = 0;
    for _ in 0..8 {
        let response = start().await.unwrap();
        if response.status() == 429 {
            refused += 1;
        } else {
            assert!(response.status().is_success());
            accepted += 1;
        }
        // The slot is claimed inside `start`, but the loop is spawned — give it
        // a moment to actually be running before the next request.
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    assert_eq!(
        accepted,
        forge_runner::task::MAX_CONCURRENT_TASKS,
        "the runner started more concurrent agents than its own ceiling"
    );
    assert_eq!(refused, 8 - forge_runner::task::MAX_CONCURRENT_TASKS);

    // A refusal writes nothing: only the accepted ones have rows.
    let tasks: Vec<serde_json::Value> = http
        .get(format!("{base}/v1/tasks"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(tasks.len(), forge_runner::task::MAX_CONCURRENT_TASKS);
}

#[tokio::test]
async fn a_task_started_without_a_provider_is_refused_rather_than_queued() {
    let repo = TempRepo::new("noprovider");
    repo.commit();
    let state = forge_runner::test_support::state(
        SqliteStore::open_in_memory().unwrap(),
        Arc::new(forge_crypto::Identity::generate()),
    );
    let base = spawn_runner(Arc::clone(&state)).await;

    let response = reqwest::Client::new()
        .post(format!("{base}/v1/tasks"))
        .json(&serde_json::json!({ "repo_path": repo.path(), "prompt": "x" }))
        .send()
        .await
        .unwrap();

    assert_eq!(response.status(), 503);
    assert!(state.store.list_tasks(10).unwrap().is_empty());
}

#[tokio::test]
async fn a_task_on_a_path_that_is_not_a_directory_is_a_bad_request() {
    let provider = Arc::new(Provider::default());
    let addr = spawn_provider(Arc::clone(&provider)).await;
    let base = spawn_runner(state_for(addr)).await;

    let response = reqwest::Client::new()
        .post(format!("{base}/v1/tasks"))
        .json(&serde_json::json!({
            "repo_path": "/nowhere/at/all", "prompt": "x"
        }))
        .send()
        .await
        .unwrap();

    assert_eq!(response.status(), 400);
}

/// Belt and braces: the decision path used by the relay is the same one.
#[tokio::test]
async fn reviewing_over_the_command_layer_enforces_the_same_rules() {
    use forge_proto::types::DecidedVia;
    use forge_runner::commands::{Command, Outcome, execute};

    let repo = TempRepo::new("commands");
    repo.write("a.txt", "before\n");
    repo.commit();

    let provider = Arc::new(Provider {
        replies: Mutex::new(vec![
            tool_use(
                "toolu_1",
                "write_file",
                serde_json::json!({ "path": "a.txt", "content": "after\n" }),
            ),
            final_text("rewrote it"),
        ]),
        seen: Mutex::new(Vec::new()),
    });

    let addr = spawn_provider(Arc::clone(&provider)).await;
    let state = state_for(addr);
    let base = spawn_runner(Arc::clone(&state)).await;
    let http = reqwest::Client::new();

    let started: serde_json::Value = http
        .post(format!("{base}/v1/tasks"))
        .json(&serde_json::json!({ "repo_path": repo.path(), "prompt": "rewrite" }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let task_id = started["id"].as_str().unwrap().to_owned();
    wait_for_status(&http, &base, &task_id, TaskStatus::AwaitingReview).await;

    // A watch is refused here too — the rule lives in one place.
    assert!(
        execute(
            &state,
            Command::ReviewTask {
                task_id: task_id.clone(),
                decision: forge_runner::task::Review::Approve,
                note: None,
            },
            DecidedVia::Watch,
        )
        .await
        .is_err()
    );
    assert_eq!(repo.read("a.txt"), "before\n");

    // The snapshot a phone would render carries the diff.
    match execute(
        &state,
        Command::TaskSnapshot {
            task_id: task_id.clone(),
        },
        DecidedVia::Phone,
    )
    .await
    .unwrap()
    {
        Outcome::TaskSnapshot(detail) => {
            assert_eq!(detail.changes.files.len(), 1);
            assert!(detail.patch.contains("+after"));
        }
        other => panic!("expected a task snapshot, got {other:?}"),
    }

    match execute(
        &state,
        Command::ReviewTask {
            task_id,
            decision: forge_runner::task::Review::Approve,
            note: None,
        },
        DecidedVia::Phone,
    )
    .await
    .unwrap()
    {
        Outcome::TaskReviewed {
            status, recorded, ..
        } => {
            assert_eq!(status, TaskStatus::Applied);
            assert!(recorded);
        }
        other => panic!("expected a review outcome, got {other:?}"),
    }
    assert_eq!(repo.read("a.txt"), "after\n");
}
