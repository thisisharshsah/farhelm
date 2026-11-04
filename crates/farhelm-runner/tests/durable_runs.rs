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
        mode: farhelm_proto::types::WorkMode::Agent,
        model: None,
        work_item_id: None,
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

/* ------------------------------------------- leases, fencing and resume */

const TTL: i64 = 30_000;

#[test]
fn a_live_lease_is_left_alone_and_an_expired_one_is_taken_over() {
    let state = state();
    let repo = TempRepo::new("lease");
    running_task(&state, "task-owned", &repo, String::new());

    // Another runner on this database owns it, with time left.
    let now = farhelm_app::time::now_ms();
    let theirs = state
        .store
        .claim_task_lease("task-owned", "other-runner", now, TTL, true)
        .unwrap()
        .expect("an unleased run can be claimed");

    // Neither startup nor the sweep may settle a run somebody still owns.
    assert_eq!(farhelm_runner::task::reconcile_after_restart(&state), 0);
    assert_eq!(farhelm_runner::task::sweep_expired_leases(&state), 0);
    assert_eq!(
        state.store.get_task("task-owned").unwrap().unwrap().status,
        TaskStatus::Running
    );

    // Its lease runs out without a renewal: the sweep takes it over.
    let later = now + TTL + 1;
    assert!(
        state
            .store
            .claim_task_lease("task-owned", "probe", now, TTL, false)
            .unwrap()
            .is_none(),
        "not expired yet at `now`"
    );
    let taken = state
        .store
        .claim_task_lease("task-owned", "recovery", later, TTL, false)
        .unwrap()
        .expect("an expired lease can be taken over");
    assert!(taken > theirs, "a takeover bumps the fencing generation");

    // The old owner wakes up and tries to renew and to record its result.
    assert!(
        !state
            .store
            .renew_task_lease("task-owned", "other-runner", theirs, later, TTL)
            .unwrap()
    );
    let mut stale = state.store.get_task("task-owned").unwrap().unwrap();
    stale.status = TaskStatus::NoChanges;
    assert!(
        !state
            .store
            .finish_task_fenced(&stale, "other-runner", theirs, None)
            .unwrap(),
        "a stale writer is refused"
    );
    assert_eq!(
        state.store.get_task("task-owned").unwrap().unwrap().status,
        TaskStatus::Running,
        "and nothing it wrote landed"
    );

    // The current owner's write lands and releases the lease.
    assert!(
        state
            .store
            .finish_task_fenced(&stale, "recovery", taken, None)
            .unwrap()
    );
    assert_eq!(
        state.store.get_task("task-owned").unwrap().unwrap().status,
        TaskStatus::NoChanges
    );
}

#[test]
fn renewal_is_fenced_by_generation_not_by_expiry() {
    let state = state();
    let repo = TempRepo::new("renew");
    running_task(&state, "task-nap", &repo, String::new());
    let generation = state
        .store
        .claim_task_lease("task-nap", "me", NOW, TTL, true)
        .unwrap()
        .unwrap();
    // A laptop that slept past its lease, with nobody taking over meanwhile,
    // keeps its run.
    assert!(
        state
            .store
            .renew_task_lease("task-nap", "me", generation, NOW + 10 * TTL, TTL)
            .unwrap()
    );
}

/// A run interrupted after one checkpointed edit, its checkout untouched since.
fn interrupted_after_an_edit(state: &Arc<AppState>, repo: &TempRepo, id: &str) -> Worktree {
    let worktree = Worktree::create(&repo.0, id).unwrap();
    running_task(state, id, repo, serde_json::to_string(&worktree).unwrap());

    let read = state
        .store
        .begin_task_step(id, "read_file", r#"{"path":"README.md"}"#, NOW + 1)
        .unwrap();
    state
        .store
        .finish_task_step(id, read, "base", false, NOW + 2)
        .unwrap();
    let edit = state
        .store
        .begin_task_step(id, "write_file", r#"{"path":"src.rs"}"#, NOW + 3)
        .unwrap();
    std::fs::write(worktree.path().join("src.rs"), "fn bounded() {}\n").unwrap();
    state
        .store
        .finish_task_step(id, edit, "wrote src.rs", false, NOW + 4)
        .unwrap();
    let commit = worktree.checkpoint("step 2").unwrap();
    state
        .store
        .set_task_step_checkpoint(id, edit, &commit)
        .unwrap();
    // The process dies during the next model call: no step is open.
    assert_eq!(farhelm_runner::task::reconcile_after_restart(state), 1);
    worktree
}

#[test]
fn a_run_interrupted_between_steps_can_resume_from_its_checkpoint() {
    let state = state();
    let repo = TempRepo::new("resumable");
    let worktree = interrupted_after_an_edit(&state, &repo, "task-resume");

    let task = state.store.get_task("task-resume").unwrap().unwrap();
    assert_eq!(task.status, TaskStatus::AwaitingReview, "still reviewable");
    let recovery = farhelm_runner::task::recovery(&state, "task-resume").unwrap();
    assert!(recovery.resumable, "{recovery:?}");
    assert_eq!(recovery.checkpoint_step, Some(2));
    assert!(recovery.interrupted_at.is_some());

    // Someone edits the checkout by hand: it is no longer the known state.
    std::fs::write(worktree.path().join("src.rs"), "fn edited() {}\n").unwrap();
    let recovery = farhelm_runner::task::recovery(&state, "task-resume").unwrap();
    assert!(!recovery.resumable);
    assert!(
        recovery
            .reason
            .as_deref()
            .unwrap()
            .contains("changed after"),
        "{recovery:?}"
    );
}

#[test]
fn a_run_interrupted_inside_a_command_is_not_resumable() {
    let state = state();
    let repo = TempRepo::new("mid-command");
    let worktree = Worktree::create(&repo.0, "task-mid").unwrap();
    running_task(
        &state,
        "task-mid",
        &repo,
        serde_json::to_string(&worktree).unwrap(),
    );
    std::fs::write(worktree.path().join("out.txt"), "partial\n").unwrap();
    state
        .store
        .begin_task_step("task-mid", "run", r#"{"command":"make"}"#, NOW)
        .unwrap();
    assert_eq!(farhelm_runner::task::reconcile_after_restart(&state), 1);

    let recovery = farhelm_runner::task::recovery(&state, "task-mid").unwrap();
    assert!(!recovery.resumable);
    assert!(
        recovery
            .reason
            .as_deref()
            .unwrap()
            .contains("middle of a step"),
        "{recovery:?}"
    );
}

#[test]
fn a_run_that_finished_on_its_own_is_not_resumable() {
    let state = state();
    let repo = TempRepo::new("finished");
    let task = running_task(&state, "task-done", &repo, String::new());
    let generation = state
        .store
        .claim_task_lease(&task.id, "me", NOW, TTL, true)
        .unwrap()
        .unwrap();
    let mut done = task.clone();
    done.status = TaskStatus::Failed;
    assert!(
        state
            .store
            .finish_task_fenced(&done, "me", generation, None)
            .unwrap()
    );
    let recovery = farhelm_runner::task::recovery(&state, "task-done").unwrap();
    assert!(!recovery.resumable);
    assert!(recovery.interrupted_at.is_none());
}

#[test]
fn a_review_decided_first_wins_over_a_resume() {
    let state = state();
    let repo = TempRepo::new("race");
    interrupted_after_an_edit(&state, &repo, "task-race");

    state
        .store
        .decide_task(
            "task-race",
            TaskStatus::Rejected,
            farhelm_proto::types::DecidedVia::Web,
            Some("not this"),
            NOW + 10,
        )
        .unwrap();
    assert!(
        state
            .store
            .resume_task("task-race", "me", NOW + 11, TTL)
            .unwrap()
            .is_none()
    );
    // And the reverse: once resumed, it cannot be resumed twice.
    let state = self::state();
    let repo = TempRepo::new("twice");
    interrupted_after_an_edit(&state, &repo, "task-twice");
    assert!(
        state
            .store
            .resume_task("task-twice", "me", NOW, TTL)
            .unwrap()
            .is_some()
    );
    assert!(
        state
            .store
            .resume_task("task-twice", "me", NOW, TTL)
            .unwrap()
            .is_none()
    );
    assert_eq!(
        state.store.get_task("task-twice").unwrap().unwrap().status,
        TaskStatus::Running
    );
}

#[tokio::test]
async fn recovery_and_resume_are_served_over_http() {
    let state = state();
    let repo = TempRepo::new("resume-http");
    interrupted_after_an_edit(&state, &repo, "task-rhttp");

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let router = api::router_with_auth(Arc::clone(&state), LocalAuth::open());
    let server = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .unwrap();

    let recovery: Value = http
        .get(format!("{url}/v1/tasks/task-rhttp/recovery"))
        .send()
        .await
        .unwrap()
        .error_for_status()
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(recovery["resumable"], true);
    assert_eq!(recovery["checkpoint_step"], 2);

    // No model provider in this runner: the resume is refused for that
    // reason, and the run stays as it was.
    let resumed = http
        .post(format!("{url}/v1/tasks/task-rhttp/resume"))
        .send()
        .await
        .unwrap();
    assert_eq!(resumed.status(), reqwest::StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        state.store.get_task("task-rhttp").unwrap().unwrap().status,
        TaskStatus::AwaitingReview
    );
    server.abort();
}
