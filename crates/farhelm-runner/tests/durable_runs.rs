//! What survives a runner restart (ADR 0004, first form).
//!
//! A task's branch is written down before its first model call and every tool
//! exchange is a ledger row, so a process that dies mid-run leaves enough
//! behind for the next start to turn interrupted edits into a reviewable
//! change set instead of a bare "failed".

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use farhelm_agent::Worktree;
use farhelm_app::store::prelude::*;
use farhelm_crypto::Identity;
use farhelm_proto::types::{Agent, AgentTask, Repo, Session, SessionStatus, TaskStatus};
use farhelm_runner::api::{self, LocalAuth};
use farhelm_runner::state::AppState;
use farhelm_sqlite::SqliteStore;
use serde_json::Value;

const NOW: i64 = 1_785_369_600_000;

/// A real repository with one commit, because a worktree needs a base.
struct TempRepo(PathBuf);

impl TempRepo {
    fn new(name: &str) -> Self {
        let dir = std::env::temp_dir().join(format!(
            "farhelm-durable-{name}-{}",
            farhelm_app::id::new_id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let repo = Self(dir);
        repo.git(&["init", "-q", "-b", "main"]);
        std::fs::write(repo.0.join("README.md"), "base\n").unwrap();
        repo.git(&["add", "-A"]);
        repo.git(&[
            "-c",
            "user.name=test",
            "-c",
            "user.email=test@example.invalid",
            "commit",
            "-q",
            "-m",
            "base",
        ]);
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
}

impl Drop for TempRepo {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn state() -> Arc<AppState> {
    farhelm_runner::test_support::state(
        SqliteStore::open_in_memory().unwrap(),
        Arc::new(Identity::generate()),
    )
}

/// A task that was `running` when the process stopped, on `repo`.
fn running_task(state: &AppState, id: &str, repo: &TempRepo, worktree_json: String) -> AgentTask {
    // One row per repository path, as the runner keeps it: several tasks on
    // the same checkout share it.
    let path = repo.0.display().to_string();
    let repo_row = match state
        .store
        .find_repo_by_path(&state.machine_id, &path)
        .unwrap()
    {
        Some(existing) => existing,
        None => {
            let fresh = Repo {
                id: format!("repo-{id}"),
                machine_id: state.machine_id.clone(),
                path,
                name: "payments-api".into(),
                budget_usd: None,
            };
            state.store.upsert_repo(&fresh).unwrap();
            fresh
        }
    };
    let session = Session {
        id: format!("session-{id}"),
        repo_id: repo_row.id.clone(),
        agent: Agent::Farhelm,
        tmux_target: None,
        status: SessionStatus::Running,
        plan_id: None,
        budget_usd: None,
        spent_usd: 0.0,
        started_at: NOW,
        ended_at: None,
        agent_session_id: None,
    };
    state.store.upsert_session(&session).unwrap();
    let task = AgentTask {
        id: id.into(),
        session_id: session.id,
        repo_id: repo_row.id,
        prompt: "Bound the retry backoff".into(),
        status: TaskStatus::Running,
        summary: String::new(),
        diff_json: String::new(),
        worktree_json,
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
        decided_via: None,
        created_at: NOW,
        updated_at: NOW,
        decided_at: None,
    };
    state.store.upsert_task(&task).unwrap();
    task
}

#[test]
fn interrupted_edits_become_a_change_set_awaiting_review() {
    let state = state();
    let repo = TempRepo::new("edits");

    // What `Supervisor::started` records before the first model call, and
    // what the loop had done by the time the process died: one finished
    // tool, one still running, and a file written on the branch.
    let worktree = Worktree::create(&repo.0, "task-1").unwrap();
    std::fs::write(worktree.path().join("src.rs"), "fn bounded() {}\n").unwrap();
    let task = running_task(
        &state,
        "task-1",
        &repo,
        serde_json::to_string(&worktree).unwrap(),
    );
    let first = state
        .store
        .begin_task_step(&task.id, "read_file", r#"{"path":"README.md"}"#, NOW + 1)
        .unwrap();
    state
        .store
        .finish_task_step(&task.id, first, "base", false, NOW + 2)
        .unwrap();
    let second = state
        .store
        .begin_task_step(&task.id, "run", r#"{"command":"cargo test"}"#, NOW + 3)
        .unwrap();
    assert_eq!((first, second), (1, 2));

    assert_eq!(farhelm_runner::task::reconcile_after_restart(&state), 1);

    let task = state.store.get_task("task-1").unwrap().unwrap();
    assert_eq!(task.status, TaskStatus::AwaitingReview, "{task:?}");
    assert_eq!(task.files_changed, 1);
    assert_eq!(task.lines_added, 1);
    assert_eq!(task.steps, 2);
    assert!(task.error.is_none());
    assert!(task.summary.contains("Interrupted"), "{}", task.summary);
    assert!(
        task.summary.contains("2 recorded steps"),
        "{}",
        task.summary
    );
    // The diff is right there for the review screen.
    let changes: Value = serde_json::from_str(&task.diff_json).unwrap();
    assert_eq!(changes["files"][0]["path"], "src.rs");

    // The ledger no longer claims a tool is running in a dead process.
    let steps = state.store.list_task_steps("task-1").unwrap();
    assert_eq!(steps.len(), 2);
    assert_eq!(steps[0].output.as_deref(), Some("base"));
    assert!(!steps[0].is_error);
    assert!(steps[1].finished_at.is_some());
    assert!(steps[1].is_error);
    assert!(steps[1].output.as_deref().unwrap().contains("interrupted"));

    // The session is closed with the task.
    let session = state.store.get_session("session-task-1").unwrap().unwrap();
    assert_eq!(session.status, SessionStatus::Done);
    assert!(session.ended_at.is_some());

    // Running it again settles nothing: the task is no longer `running`.
    assert_eq!(farhelm_runner::task::reconcile_after_restart(&state), 0);
}

#[test]
fn a_task_with_no_surviving_edits_still_fails_honestly() {
    let state = state();
    let repo = TempRepo::new("clean");

    // Branch recorded, checkout intact, nothing written on it.
    let untouched = Worktree::create(&repo.0, "task-clean").unwrap();
    running_task(
        &state,
        "task-clean",
        &repo,
        serde_json::to_string(&untouched).unwrap(),
    );
    // No branch recorded at all: died before `started`.
    running_task(&state, "task-early", &repo, String::new());
    // Branch recorded, but the checkout is gone from disk.
    let removed = Worktree::create(&repo.0, "task-gone").unwrap();
    let json = serde_json::to_string(&removed).unwrap();
    removed.discard().unwrap();
    running_task(&state, "task-gone", &repo, json);

    assert_eq!(farhelm_runner::task::reconcile_after_restart(&state), 3);
    for id in ["task-clean", "task-early", "task-gone"] {
        let task = state.store.get_task(id).unwrap().unwrap();
        assert_eq!(task.status, TaskStatus::Failed, "{id}");
        assert!(
            task.error.as_deref().unwrap().contains("runner stopped"),
            "{id}"
        );
        assert!(task.diff_json.is_empty(), "{id}");
    }
}

#[tokio::test]
async fn the_step_ledger_is_readable_over_http() {
    let state = state();
    let repo = TempRepo::new("http");
    let task = running_task(&state, "task-http", &repo, String::new());
    let ordinal = state
        .store
        .begin_task_step(&task.id, "search", r#"{"query":"backoff"}"#, NOW)
        .unwrap();
    state
        .store
        .finish_task_step(&task.id, ordinal, "3 matches", false, NOW + 1)
        .unwrap();
    // A second settle is ignored: the first answer stands.
    state
        .store
        .finish_task_step(&task.id, ordinal, "overwritten", true, NOW + 2)
        .unwrap();

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let router = api::router_with_auth(Arc::clone(&state), LocalAuth::open());
    let server = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .unwrap();

    let steps: Vec<Value> = http
        .get(format!("{url}/v1/tasks/task-http/steps"))
        .send()
        .await
        .unwrap()
        .error_for_status()
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(steps.len(), 1);
    assert_eq!(steps[0]["ordinal"], 1);
    assert_eq!(steps[0]["tool"], "search");
    assert_eq!(steps[0]["output"], "3 matches");
    assert_eq!(steps[0]["is_error"], false);

    let missing = http
        .get(format!("{url}/v1/tasks/nope/steps"))
        .send()
        .await
        .unwrap();
    assert_eq!(missing.status(), reqwest::StatusCode::NOT_FOUND);
    server.abort();
}
