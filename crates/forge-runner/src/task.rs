//! Native agent tasks, from "start" to "applied".
//!
//! This is where [`forge_agent`] meets the daemon. The agent crate knows how to
//! think; this module knows about sessions, approval rows, the event bus, and
//! the fact that a human might be on a train.
//!
//! ## The shape of a task
//!
//! ```text
//! POST /v1/tasks                    row: running
//!   └─ spawned loop
//!        ├─ read/search/edit …      staged, no card
//!        └─ run "cargo test"        card → classifier → phone → typed answer
//!   ↓
//! awaiting_review                   push: "3 files, +42 −17"
//!   ├─ approve → apply → applied
//!   └─ reject  → rejected, with a reason the next task is handed
//! ```
//!
//! ## Two rules the runner enforces, not the agent
//!
//! 1. **A task is billed to a session.** It creates one, so the ledger, the
//!    budget guard, the cost dashboard and the fleet view all work on tasks
//!    without any of them knowing tasks exist.
//! 2. **A destructive command still cannot be cleared from a wrist.** The
//!    `run` tool raises an ordinary [`Approval`], through
//!    [`forge_core::risk::classify_with`] and the same policy file. Nothing
//!    about being the runner's own agent buys it a shortcut.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use forge_agent::{Outcome, TaskSpec, Verdict, Workspace};
use forge_core::id::new_id;
use forge_core::store::{TaskOutcome, prelude::*};
use forge_core::time::now_ms;
use forge_core::types::{
    Agent, AgentTask, Approval, DecidedVia, Decision, Repo, Session, SessionStatus, TaskStatus,
};
use serde::Deserialize;

use crate::state::{AppState, ServerEvent};

/// How long a `run` inside a task waits for a human before it is denied.
///
/// Shorter than the hook bridge's fifteen minutes on purpose. A blocked hook is
/// a developer's own terminal sitting idle in front of them; a blocked task is a
/// background job holding a model connection open, and denying it early lets the
/// agent say "I could not run the tests" in a change set you can still read.
pub const RUN_APPROVAL_WAIT: Duration = Duration::from_secs(5 * 60);

/// How many tasks may be drafting at once.
///
/// **This is a cost guard, not a performance one.** Nothing in `start` blocks,
/// so without a ceiling fifty POSTs are fifty agents on the frontier of a
/// budget, in parallel, each holding a model connection open. A stuck retry
/// button on a phone would do it by accident. The repo cap would eventually
/// stop them, but "eventually" is measured in dollars and a repo has no cap by
/// default.
///
/// Three is deliberately small. A task is minutes of wall-clock and a human
/// reviews its diff at the end; queueing the fourth costs nothing anybody
/// notices, and the alternative failure is expensive and silent.
pub const MAX_CONCURRENT_TASKS: usize = 3;

/// Ceiling on a whole change set, across every file it touches.
///
/// `Workspace` already caps a single file. This is the other axis: a task that
/// rewrote two hundred of them would put a row in SQLite that the fleet query
/// then reads, and produce a diff no human is going to review on a phone.
/// Refusing to *store* it would throw the work away, so instead the change set
/// is kept and flagged — the task is still reviewable, one file at a time.
pub const MAX_CHANGE_SET_BYTES: usize = 4 * 1024 * 1024;

/// Holds one of [`MAX_CONCURRENT_TASKS`] slots for as long as a loop runs.
///
/// Released on `Drop`, so a loop that panics or is cancelled frees its slot
/// rather than leaking it. A counter incremented at the top of `drive` and
/// decremented at the bottom would not survive either.
struct TaskSlot(Arc<AppState>);

impl TaskSlot {
    /// `None` when the runner is already at its ceiling.
    fn claim(state: &Arc<AppState>) -> Option<Self> {
        use std::sync::atomic::Ordering;
        let running = &state.running_tasks;
        loop {
            let current = running.load(Ordering::SeqCst);
            if current >= MAX_CONCURRENT_TASKS {
                return None;
            }
            // Compare-and-swap rather than `fetch_add` then check: two requests
            // arriving together would both see room and both take it.
            if running
                .compare_exchange(current, current + 1, Ordering::SeqCst, Ordering::SeqCst)
                .is_ok()
            {
                return Some(TaskSlot(Arc::clone(state)));
            }
        }
    }
}

impl Drop for TaskSlot {
    fn drop(&mut self) {
        self.0
            .running_tasks
            .fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
    }
}

#[derive(Debug)]
pub enum TaskError {
    NotADirectory(String),
    NotFound(String),
    /// Already at [`MAX_CONCURRENT_TASKS`].
    TooBusy(usize),
    /// The task is not in a state where this makes sense — already decided,
    /// still running.
    Conflict(String),
    /// No credential in the environment, so there is no agent to run.
    NoProvider,
    /// The change set could not be written. The task stays reviewable.
    Apply(String),
    Store(forge_core::store::StoreError),
}

impl std::fmt::Display for TaskError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TaskError::NotADirectory(path) => {
                write!(f, "{path} is not a directory on this machine")
            }
            TaskError::NotFound(what) => write!(f, "not found: {what}"),
            TaskError::TooBusy(running) => write!(
                f,
                "{running} tasks are already running, which is the limit — \
                 wait for one to finish, or review a diff that is waiting"
            ),
            TaskError::Conflict(why) => f.write_str(why),
            TaskError::NoProvider => f.write_str(
                "no model provider configured — set ANTHROPIC_API_KEY or \
                 ANTHROPIC_AUTH_TOKEN to run agent tasks",
            ),
            TaskError::Apply(why) => write!(f, "could not apply the change set: {why}"),
            TaskError::Store(err) => write!(f, "{err}"),
        }
    }
}

impl std::error::Error for TaskError {}

impl From<forge_core::store::StoreError> for TaskError {
    fn from(err: forge_core::store::StoreError) -> Self {
        TaskError::Store(err)
    }
}

/// What a client sends to start a task.
#[derive(Debug, Clone, Deserialize)]
pub struct StartTask {
    /// Absolute path to the repository on this machine.
    pub repo_path: String,
    pub prompt: String,
    /// Cap for this task alone. Independent of the repo cap, which still
    /// applies as the outer ring.
    #[serde(default)]
    pub budget_usd: Option<f64>,
    #[serde(default)]
    pub max_steps: Option<usize>,
    /// A rejected task to try again, differently.
    ///
    /// Its prompt, its change set, and the reason it was refused are composed
    /// into this task's instruction — see [`retry_prompt`]. The original row is
    /// never touched: a rejection is a permanent record, and a retry is a new
    /// attempt beside it rather than an edit to the one that failed.
    #[serde(default)]
    pub retry_of: Option<String>,
}

/// How much of a rejected patch to show the next attempt.
///
/// Enough to see what was tried; not so much that a rejected 40-file sweep
/// costs more to describe than it did to produce.
const MAX_RETRY_PATCH_BYTES: usize = 12 * 1024;

/// Compose the instruction for a retry.
///
/// The rejection note is the point. Everything else here is context for it: an
/// agent told only "no" will usually produce the same change again, and an agent
/// told "no, because this breaks the retry cap" will not.
pub fn retry_prompt(previous: &AgentTask) -> String {
    let mut out = previous.prompt.clone();

    out.push_str("\n\n---\nA previous attempt at this was rejected. ");
    out.push_str("Do not simply repeat it.\n");

    if !previous.summary.trim().is_empty() {
        out.push_str(&format!(
            "\nWhat that attempt did: {}\n",
            previous.summary.trim()
        ));
    }

    match previous.review_note.as_deref().map(str::trim) {
        Some(note) if !note.is_empty() => {
            out.push_str(&format!("\nWhy it was rejected: {note}\n"));
        }
        // A rejection with no reason still has to be reported. Inventing one, or
        // staying silent about the rejection entirely, would both be worse: the
        // agent needs to know its last change set was refused even when nobody
        // said why.
        _ => out.push_str("\nNo reason was given for the rejection.\n"),
    }

    let changes: forge_agent::ChangeSet =
        serde_json::from_str(&previous.diff_json).unwrap_or_default();
    if !changes.is_empty() {
        let mut patch = changes.render();
        if patch.len() > MAX_RETRY_PATCH_BYTES {
            let mut end = MAX_RETRY_PATCH_BYTES;
            while end > 0 && !patch.is_char_boundary(end) {
                end -= 1;
            }
            patch.truncate(end);
            patch.push_str("\n[patch truncated]\n");
        }
        out.push_str(&format!("\nThe change set that was rejected:\n\n{patch}"));
    }

    out
}

/// A reviewer's answer. Part of the wire contract — it arrives inside a
/// `Command::ReviewTask` — so it lives in `forge-proto`.
pub use forge_proto::commands::Review;

/* ------------------------------------------------------------- supervisor */

/// [`forge_agent::Supervisor`] wired to the runner's approval queue.
pub struct RunnerSupervisor {
    state: Arc<AppState>,
    session_id: String,
}

impl RunnerSupervisor {
    pub fn new(state: Arc<AppState>, session_id: impl Into<String>) -> Self {
        Self {
            state,
            session_id: session_id.into(),
        }
    }
}

impl forge_agent::Supervisor for RunnerSupervisor {
    async fn request(&self, tool: &str, payload: &str) -> Verdict {
        // Server-side, with the local policy file layered on — the same call
        // the hook bridge makes. A native agent gets no dispensation.
        let risk = forge_core::risk::classify_with(&self.state.policy, tool, payload);

        let approval = Approval {
            id: new_id(),
            session_id: self.session_id.clone(),
            tool: tool.to_owned(),
            payload: payload.to_owned(),
            risk,
            decision: None,
            decided_via: None,
            requested_at: now_ms(),
            decided_at: None,
        };

        if let Err(err) = self.state.store.create_approval(&approval) {
            // The queue is how a human says yes. If it cannot be written to,
            // the answer is no — an unrecordable approval must never become an
            // approval.
            return Verdict::Denied(format!("the approval could not be recorded: {err}"));
        }

        self.note(&format!("⏳ awaiting approval — {payload}"));
        self.state.publish(ServerEvent::ApprovalRequest {
            approval: approval.clone(),
        });
        self.state.publish(ServerEvent::SessionUpsert {
            session_id: self.session_id.clone(),
        });

        let settled =
            match crate::api::await_decision(&self.state, &approval.id, RUN_APPROVAL_WAIT).await {
                Ok(settled) => settled,
                Err(err) => return Verdict::Denied(err.to_string()),
            };

        match settled.decision {
            Some(Decision::Approved) => {
                self.note("• approved");
                Verdict::Approved
            }
            Some(Decision::Denied) => Verdict::Denied("denied by the developer".into()),
            // Timeout, or a row that somehow has no decision: both deny.
            _ => Verdict::Denied(format!(
                "nobody answered within {} minutes",
                RUN_APPROVAL_WAIT.as_secs() / 60
            )),
        }
    }

    fn note(&self, text: &str) {
        self.state.push_output(&self.session_id, text, now_ms());
    }
}

/* ------------------------------------------------------------------ start */

/// Resolve (or adopt) the repo row for a path on this machine.
fn resolve_repo(state: &AppState, repo_path: &str) -> Result<Repo, TaskError> {
    if let Some(repo) = state
        .store
        .find_repo_by_path(&state.machine_id, repo_path)?
    {
        return Ok(repo);
    }
    let repo = Repo {
        id: new_id(),
        machine_id: state.machine_id.clone(),
        path: repo_path.to_owned(),
        name: Path::new(repo_path)
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| repo_path.to_owned()),
        // No cap by default: inventing one would stop work nobody asked to stop.
        budget_usd: None,
    };
    state.store.upsert_repo(&repo)?;
    Ok(repo)
}

/// A fresh task row and the session it bills to.
fn create_rows(state: &AppState, request: &StartTask) -> Result<(AgentTask, Session), TaskError> {
    let repo = resolve_repo(state, &request.repo_path)?;
    let now = now_ms();

    let session = Session {
        id: new_id(),
        repo_id: repo.id.clone(),
        agent: Agent::Forge,
        tmux_target: None,
        status: SessionStatus::Running,
        plan_id: None,
        budget_usd: request.budget_usd,
        spent_usd: 0.0,
        started_at: now,
        ended_at: None,
        agent_session_id: None,
    };
    state.store.upsert_session(&session)?;

    let task = AgentTask {
        id: new_id(),
        session_id: session.id.clone(),
        repo_id: repo.id,
        prompt: request.prompt.clone(),
        status: TaskStatus::Running,
        summary: String::new(),
        diff_json: String::new(),
        staged_json: String::new(),
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
        created_at: now,
        updated_at: now,
        decided_at: None,
    };
    state.store.upsert_task(&task)?;
    Ok((task, session))
}

/// What the agent is actually asked, which is not always what the row stores.
///
/// A retry composes its instruction from the attempt it is replacing. The row
/// keeps the *original* prompt, so the task list still reads as the thing the
/// human asked for rather than as a wall of patch.
fn resolve_instruction(state: &AppState, request: &StartTask) -> Result<String, TaskError> {
    let Some(id) = &request.retry_of else {
        return Ok(request.prompt.clone());
    };

    let previous = state
        .store
        .get_task(id)?
        .ok_or_else(|| TaskError::NotFound(format!("task {id}")))?;

    // Only a *rejected* task. Retrying one that is still awaiting review would
    // put two agents on the same change set before anybody had decided about
    // the first; retrying an applied one would propose undoing work that landed.
    if previous.status != TaskStatus::Rejected {
        return Err(TaskError::Conflict(format!(
            "task {id} is {}, and only a rejected task can be retried",
            previous.status
        )));
    }

    Ok(retry_prompt(&previous))
}

/// Start a task. Returns as soon as the row exists; the loop runs detached.
///
/// Deliberately not blocking: a task takes minutes, and the client that started
/// it is a phone that may be in a tunnel by the time it finishes. Progress
/// arrives over the event bus, and the result is a row that outlives the
/// connection that asked for it.
pub fn start(state: &Arc<AppState>, request: StartTask) -> Result<AgentTask, TaskError> {
    if state.gateway.is_none() {
        return Err(TaskError::NoProvider);
    }
    if !Path::new(&request.repo_path).is_dir() {
        return Err(TaskError::NotADirectory(request.repo_path.clone()));
    }

    // Claimed before any row is written, so a refusal leaves nothing behind.
    let slot = TaskSlot::claim(state).ok_or(TaskError::TooBusy(MAX_CONCURRENT_TASKS))?;

    let instruction = resolve_instruction(state, &request)?;
    let (task, session) = create_rows(state, &request)?;
    state.push_output(&session.id, format!("▶ {}", request.prompt), now_ms());
    if request.retry_of.is_some() {
        state.push_output(
            &session.id,
            "↻ retrying a rejected change set, with the reason".to_owned(),
            now_ms(),
        );
    }
    publish(state, &task);

    let spawned = Arc::clone(state);
    let task_id = task.id.clone();
    let spec = {
        let mut spec = TaskSpec::new(
            session.id.clone(),
            PathBuf::from(&request.repo_path),
            instruction,
        );
        if let Some(max_steps) = request.max_steps.filter(|steps| *steps > 0) {
            spec.max_steps = max_steps;
        }
        spec
    };

    tokio::spawn(async move {
        // The slot moves in here and is released when this future ends, however
        // it ends.
        let _slot = slot;
        drive(spawned, task_id, spec).await;
    });

    Ok(task)
}

/// Settle tasks left `running` by a runner that stopped.
///
/// A task is a spawned loop and a database row. The loop does not survive a
/// restart; the row does. Without this, every crash leaves a task that says
/// "working…" forever, holding a place in the fleet view and — once the cap
/// existed — potentially a slot it can never give back.
///
/// Marked `failed` rather than retried: the work was interrupted at an unknown
/// point, whatever it had staged is gone with the process, and re-running it
/// automatically would spend money nobody asked for at startup.
pub fn reconcile_after_restart(state: &Arc<AppState>) -> usize {
    let Ok(tasks) = state.store.list_tasks(500) else {
        return 0;
    };

    let mut settled = 0;
    for mut task in tasks {
        if task.status != TaskStatus::Running {
            continue;
        }
        task.status = TaskStatus::Failed;
        task.error = Some("the runner stopped while this task was working".into());
        task.updated_at = now_ms();
        if state.store.upsert_task(&task).is_ok() {
            settled += 1;
            publish(state, &task);
        }
    }
    settled
}

/// Run the loop and record what it produced.
async fn drive(state: Arc<AppState>, task_id: String, spec: TaskSpec) {
    let Some(gateway) = state.gateway.as_ref() else {
        return;
    };
    let supervisor = RunnerSupervisor::new(Arc::clone(&state), &spec.session_id);
    let outcome = forge_agent::run(gateway, &supervisor, &spec).await;

    let Ok(Some(mut task)) = state.store.get_task(&task_id) else {
        return;
    };

    task.summary = outcome.summary.clone();
    task.cost_usd = outcome.cost_usd;
    task.steps = outcome.steps as i64;
    task.files_changed = outcome.changes.files.len() as i64;
    task.lines_added = outcome.changes.added() as i64;
    task.lines_removed = outcome.changes.removed() as i64;
    task.updated_at = now_ms();

    // C10's verdict, if one was obtained. Left null otherwise — "not judged" and
    // "judged and found fine" are different answers and must not collapse.
    if let Some(assessment) = &outcome.assessment {
        task.verify_grade = Some(assessment.grade.as_str().to_owned());
        task.verify_notes = Some(assessment.notes.clone()).filter(|notes| !notes.is_empty());
        task.verify_model = Some(assessment.model.clone()).filter(|model| !model.is_empty());
    }

    // Serialising the overlay is what lets a review card survive a restart.
    // If it fails the task is still *reviewable* — the diff is separate — but
    // it could not be applied, so say so now rather than at approval time.
    //
    // The size check comes first for the same reason: better to refuse a change
    // set at the point it was produced than to write megabytes into a row the
    // fleet query then reads on every refresh.
    let staged_bytes = outcome.workspace.staged_bytes();
    if staged_bytes > MAX_CHANGE_SET_BYTES {
        task.error = Some(format!(
            "the change set is {staged_bytes} bytes across {} files, over the \
             {MAX_CHANGE_SET_BYTES}-byte limit — it was not stored, so it cannot \
             be applied. Ask for a narrower change.",
            outcome.changes.files.len()
        ));
    } else {
        match serde_json::to_string(&outcome.workspace) {
            Ok(json) => task.staged_json = json,
            Err(err) => {
                task.error = Some(format!("the staged change set could not be stored: {err}"));
            }
        }
    }
    task.diff_json = serde_json::to_string(&outcome.changes).unwrap_or_default();

    task.status = match &outcome.outcome {
        _ if task.error.is_some() => TaskStatus::Failed,
        Outcome::Proposed | Outcome::StepLimit => TaskStatus::AwaitingReview,
        Outcome::NoChanges => TaskStatus::NoChanges,
        Outcome::Refused(why) => {
            task.error = Some(why.clone());
            TaskStatus::Failed
        }
        Outcome::BudgetExhausted(why) | Outcome::Failed(why) => {
            task.error = Some(why.clone());
            // A budget stop that still produced edits is worth reviewing: the
            // work is done and paid for, and throwing it away helps nobody.
            if outcome.changes.is_empty() {
                TaskStatus::Failed
            } else {
                TaskStatus::AwaitingReview
            }
        }
    };

    let closing = match task.status {
        TaskStatus::AwaitingReview => {
            format!("✅ proposed {} — waiting for review", task.change_summary())
        }
        TaskStatus::NoChanges => "• finished with no changes".to_owned(),
        _ => format!(
            "✗ {}",
            task.error.as_deref().unwrap_or("the task did not finish")
        ),
    };
    state.push_output(&spec.session_id, closing, now_ms());

    // The session is done either way: a task is one shot, and leaving it
    // `running` would keep it in the fleet view forever.
    if let Ok(Some(mut session)) = state.store.get_session(&spec.session_id) {
        session.status = SessionStatus::Done;
        session.ended_at = Some(now_ms());
        let _ = state.store.upsert_session(&session);
    }

    let _ = state.store.upsert_task(&task);
    publish(&state, &task);
    state.publish(ServerEvent::SessionUpsert {
        session_id: spec.session_id.clone(),
    });
}

/* ----------------------------------------------------------------- review */

/// Approve or reject a proposed change set.
///
/// Approving writes the files. That is the only place in this crate that does,
/// and it happens after [`forge_core::store::Store::decide_task`] has already
/// won the race against every other device looking at the same card — so two
/// phones tapping at once apply the change set once.
pub fn review(
    state: &Arc<AppState>,
    task_id: &str,
    review: Review,
    note: Option<&str>,
    via: DecidedVia,
) -> Result<AgentTask, TaskError> {
    let task = state
        .store
        .get_task(task_id)?
        .ok_or_else(|| TaskError::NotFound(format!("task {task_id}")))?;

    if !task.is_pending_review() {
        return Err(TaskError::Conflict(format!(
            "task {task_id} is {}, not awaiting review",
            task.status
        )));
    }

    // D3, applied to diffs. A change set is not a shell command, but approving
    // one from a wrist is still a decision made without reading it — and the
    // whole point of a diff is that somebody read it.
    if via == DecidedVia::Watch {
        return Err(TaskError::Conflict(
            "a change set cannot be approved from a watch — open it on a phone".into(),
        ));
    }

    let target = match review {
        Review::Approve => TaskStatus::Applied,
        Review::Reject => TaskStatus::Rejected,
    };

    let outcome = state
        .store
        .decide_task(task_id, target, via, note, now_ms())?;

    let mut decided = match outcome {
        TaskOutcome::Recorded(task) => task,
        // Somebody else already answered. Return what they decided rather than
        // applying anything a second time.
        TaskOutcome::AlreadyDecided(task) => return Ok(task),
    };

    if review == Review::Approve {
        match apply(&decided) {
            Ok(written) => {
                state.push_output(
                    &decided.session_id,
                    format!("✔ applied {} file(s)", written.len()),
                    now_ms(),
                );
            }
            Err(err) => {
                // The decision stands — a reviewer said yes — but the write did
                // not happen. Recording it as `failed` with the reason is more
                // honest than reporting a change set that is not on disk.
                decided.status = TaskStatus::Failed;
                decided.error = Some(err.to_string());
                decided.updated_at = now_ms();
                state.store.upsert_task(&decided)?;
                state.push_output(&decided.session_id, format!("✗ {err}"), now_ms());
                publish(state, &decided);
                return Err(TaskError::Apply(err.to_string()));
            }
        }
    } else {
        state.push_output(
            &decided.session_id,
            format!(
                "✗ change set rejected{}",
                note.map(|note| format!(" — {note}")).unwrap_or_default()
            ),
            now_ms(),
        );
    }

    publish(state, &decided);
    Ok(decided)
}

/// Write an approved change set to the working tree.
fn apply(task: &AgentTask) -> Result<Vec<String>, TaskError> {
    overlay(task)?
        .apply()
        .map_err(|err| TaskError::Apply(err.to_string()))
}

fn overlay(task: &AgentTask) -> Result<Workspace, TaskError> {
    serde_json::from_str(&task.staged_json)
        .map_err(|err| TaskError::Apply(format!("the stored change set is unreadable: {err}")))
}

/// Take an applied change set back off the working tree.
///
/// The overlay held both sides all along, so undoing is the same walk with them
/// swapped — see [`forge_agent::Workspace::revert`]. This is what keeps
/// "applied" from being the one irreversible step in a system where every other
/// one is undone by doing nothing.
///
/// Refuses if any touched file has moved since: reverting over somebody's later
/// edit would throw *their* work away, which is the mistake this whole feature
/// exists to prevent in the other direction.
pub fn revert(
    state: &Arc<AppState>,
    task_id: &str,
    via: DecidedVia,
) -> Result<AgentTask, TaskError> {
    let mut task = state
        .store
        .get_task(task_id)?
        .ok_or_else(|| TaskError::NotFound(format!("task {task_id}")))?;

    if !task.status.can_revert() {
        return Err(TaskError::Conflict(format!(
            "task {task_id} is {}, and only an applied change set can be undone",
            task.status
        )));
    }

    let written = overlay(&task)?
        .revert()
        .map_err(|err| TaskError::Apply(err.to_string()))?;

    task.status = TaskStatus::Reverted;
    task.decided_via = Some(via);
    task.updated_at = now_ms();
    task.decided_at = Some(now_ms());
    state.store.upsert_task(&task)?;

    state.push_output(
        &task.session_id,
        format!("↶ undone — {} file(s) put back", written.len()),
        now_ms(),
    );
    publish(state, &task);
    Ok(task)
}

fn publish(state: &AppState, task: &AgentTask) {
    state.publish(ServerEvent::TaskUpsert {
        task_id: task.id.clone(),
        session_id: task.session_id.clone(),
        status: task.status,
        summary: task.change_summary(),
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use forge_core::store::SqliteStore;

    fn state() -> Arc<AppState> {
        AppState::with_gateway(SqliteStore::open_in_memory().unwrap(), |_| None)
    }

    struct TempRepo(PathBuf);

    impl TempRepo {
        fn new(name: &str) -> Self {
            let dir = std::env::temp_dir().join(format!("forge-runner-task-{name}"));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir)
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

    /// A task row parked in `awaiting_review` with a real staged change.
    fn awaiting(state: &Arc<AppState>, repo: &TempRepo, before: &str, after: &str) -> AgentTask {
        std::fs::write(repo.0.join("a.txt"), before).unwrap();

        let mut workspace = Workspace::open(&repo.0).unwrap();
        workspace.stage_write("a.txt", after).unwrap();
        let changes = workspace.changes();

        let (mut task, _) = create_rows(
            state,
            &StartTask {
                repo_path: repo.path(),
                prompt: "change it".into(),
                budget_usd: None,
                max_steps: None,
                retry_of: None,
            },
        )
        .unwrap();

        task.status = TaskStatus::AwaitingReview;
        task.staged_json = serde_json::to_string(&workspace).unwrap();
        task.diff_json = serde_json::to_string(&changes).unwrap();
        task.files_changed = changes.files.len() as i64;
        task.lines_added = changes.added() as i64;
        task.lines_removed = changes.removed() as i64;
        state.store.upsert_task(&task).unwrap();
        task
    }

    #[test]
    fn approving_writes_the_change_set_and_settles_the_task() {
        let state = state();
        let repo = TempRepo::new("approve");
        let task = awaiting(&state, &repo, "before\n", "after\n");

        let decided = review(&state, &task.id, Review::Approve, None, DecidedVia::Phone).unwrap();

        assert_eq!(decided.status, TaskStatus::Applied);
        assert_eq!(
            std::fs::read_to_string(repo.0.join("a.txt")).unwrap(),
            "after\n"
        );
    }

    #[test]
    fn rejecting_keeps_the_working_tree_exactly_as_it_was() {
        let state = state();
        let repo = TempRepo::new("reject");
        let task = awaiting(&state, &repo, "before\n", "after\n");

        let decided = review(
            &state,
            &task.id,
            Review::Reject,
            Some("wrong approach"),
            DecidedVia::Web,
        )
        .unwrap();

        assert_eq!(decided.status, TaskStatus::Rejected);
        assert_eq!(decided.review_note.as_deref(), Some("wrong approach"));
        assert_eq!(
            std::fs::read_to_string(repo.0.join("a.txt")).unwrap(),
            "before\n"
        );
    }

    #[test]
    fn a_change_set_cannot_be_approved_from_a_watch() {
        let state = state();
        let repo = TempRepo::new("watch");
        let task = awaiting(&state, &repo, "before\n", "after\n");

        assert!(matches!(
            review(&state, &task.id, Review::Approve, None, DecidedVia::Watch),
            Err(TaskError::Conflict(_))
        ));
        assert_eq!(
            std::fs::read_to_string(repo.0.join("a.txt")).unwrap(),
            "before\n"
        );
    }

    #[test]
    fn a_second_approval_does_not_write_the_files_twice() {
        // The failure: two phones on one notification, and the second tap
        // applying a change set against a tree that already moved.
        let state = state();
        let repo = TempRepo::new("twice");
        let task = awaiting(&state, &repo, "before\n", "after\n");

        review(&state, &task.id, Review::Approve, None, DecidedVia::Phone).unwrap();
        std::fs::write(repo.0.join("a.txt"), "a human edited this\n").unwrap();

        assert!(matches!(
            review(&state, &task.id, Review::Approve, None, DecidedVia::Web),
            Err(TaskError::Conflict(_))
        ));
        assert_eq!(
            std::fs::read_to_string(repo.0.join("a.txt")).unwrap(),
            "a human edited this\n"
        );
    }

    #[test]
    fn approving_a_stale_change_set_fails_loudly_rather_than_clobbering() {
        let state = state();
        let repo = TempRepo::new("stale");
        let task = awaiting(&state, &repo, "before\n", "after\n");

        // Somebody edits the file while the card sits on a phone.
        std::fs::write(repo.0.join("a.txt"), "human edit\n").unwrap();

        assert!(matches!(
            review(&state, &task.id, Review::Approve, None, DecidedVia::Phone),
            Err(TaskError::Apply(_))
        ));
        assert_eq!(
            std::fs::read_to_string(repo.0.join("a.txt")).unwrap(),
            "human edit\n"
        );
        let stored = state.store.get_task(&task.id).unwrap().unwrap();
        assert_eq!(stored.status, TaskStatus::Failed);
        assert!(stored.error.unwrap().contains("changed on disk"));
    }

    #[test]
    fn reviewing_a_task_that_is_still_running_is_a_conflict() {
        let state = state();
        let repo = TempRepo::new("running");
        let (task, _) = create_rows(
            &state,
            &StartTask {
                repo_path: repo.path(),
                prompt: "x".into(),
                budget_usd: None,
                max_steps: None,
                retry_of: None,
            },
        )
        .unwrap();

        assert!(matches!(
            review(&state, &task.id, Review::Approve, None, DecidedVia::Phone),
            Err(TaskError::Conflict(_))
        ));
    }

    /// A rejected task, with a reason and a real change set behind it.
    fn rejected(state: &Arc<AppState>, repo: &TempRepo, note: Option<&str>) -> AgentTask {
        let task = awaiting(state, repo, "before\n", "after\n");
        review(state, &task.id, Review::Reject, note, DecidedVia::Phone).unwrap();
        state.store.get_task(&task.id).unwrap().unwrap()
    }

    #[test]
    fn a_retry_hands_the_agent_the_reason_it_was_rejected() {
        // The whole point. An agent told only "no" produces the same change
        // again; an agent told *why* does not.
        let state = state();
        let repo = TempRepo::new("retry-reason");
        let previous = rejected(&state, &repo, Some("this breaks the retry cap"));

        let prompt = retry_prompt(&previous);
        assert!(
            prompt.starts_with("change it"),
            "the original ask must lead"
        );
        assert!(prompt.contains("this breaks the retry cap"));
        assert!(prompt.contains("was rejected"));
        assert!(prompt.contains("Do not simply repeat it"));
    }

    #[test]
    fn a_retry_shows_the_agent_the_patch_that_was_refused() {
        let state = state();
        let repo = TempRepo::new("retry-patch");
        let previous = rejected(&state, &repo, Some("wrong file"));

        let prompt = retry_prompt(&previous);
        assert!(
            prompt.contains("+after"),
            "the rejected patch is not in the prompt"
        );
        assert!(prompt.contains("--- a/a.txt"));
    }

    #[test]
    fn a_rejection_with_no_reason_still_says_it_was_rejected() {
        // Staying silent would leave the agent believing its last change set
        // landed, and it would build the next one on top of a change that is
        // not there.
        let state = state();
        let repo = TempRepo::new("retry-silent");
        let previous = rejected(&state, &repo, None);

        let prompt = retry_prompt(&previous);
        assert!(prompt.contains("was rejected"));
        assert!(prompt.contains("No reason was given"));
    }

    #[test]
    fn an_oversized_rejected_patch_is_truncated_rather_than_resent_whole() {
        let state = state();
        let repo = TempRepo::new("retry-huge");
        let mut previous = rejected(&state, &repo, Some("too much"));

        // A change set far past the cap.
        let huge: String = (0..40_000).map(|i| format!("line {i}\n")).collect();
        let mut workspace = Workspace::open(&repo.0).unwrap();
        workspace.stage_write("a.txt", huge).unwrap();
        previous.diff_json = serde_json::to_string(&workspace.changes()).unwrap();

        let prompt = retry_prompt(&previous);
        assert!(prompt.contains("[patch truncated]"));
        assert!(prompt.len() < MAX_RETRY_PATCH_BYTES * 2);
    }

    fn retry_request(repo: &TempRepo, retry_of: Option<&str>) -> StartTask {
        StartTask {
            repo_path: repo.path(),
            prompt: "x".into(),
            budget_usd: None,
            max_steps: None,
            retry_of: retry_of.map(str::to_owned),
        }
    }

    #[test]
    fn only_a_rejected_task_can_be_retried() {
        let state = state();
        let repo = TempRepo::new("retry-state");

        // Awaiting review: retrying would put a second agent on a change set
        // nobody has decided about yet.
        let waiting = awaiting(&state, &repo, "before\n", "after\n");
        assert!(matches!(
            resolve_instruction(&state, &retry_request(&repo, Some(&waiting.id))),
            Err(TaskError::Conflict(_))
        ));

        // Applied: retrying would propose undoing work that landed.
        let applied = awaiting(&state, &repo, "before\n", "after\n");
        review(
            &state,
            &applied.id,
            Review::Approve,
            None,
            DecidedVia::Phone,
        )
        .unwrap();
        assert!(matches!(
            resolve_instruction(&state, &retry_request(&repo, Some(&applied.id))),
            Err(TaskError::Conflict(_))
        ));
    }

    #[test]
    fn a_rejected_task_resolves_to_a_composed_instruction() {
        let state = state();
        let repo = TempRepo::new("retry-resolve");
        let previous = rejected(&state, &repo, Some("wrong approach"));

        let instruction =
            resolve_instruction(&state, &retry_request(&repo, Some(&previous.id))).unwrap();
        assert!(instruction.contains("wrong approach"));
        // And the plain path is left exactly alone.
        assert_eq!(
            resolve_instruction(&state, &retry_request(&repo, None)).unwrap(),
            "x"
        );
    }

    #[test]
    fn retrying_a_task_that_does_not_exist_is_not_found() {
        let state = state();
        let repo = TempRepo::new("retry-missing");
        assert!(matches!(
            resolve_instruction(&state, &retry_request(&repo, Some("nope"))),
            Err(TaskError::NotFound(_))
        ));
    }

    #[test]
    fn a_rejection_leaves_the_original_row_intact_for_the_retry_to_read() {
        // A retry is a *new* task beside the rejected one, never an edit to it.
        // The audit trail has to keep both the change set that was refused and
        // the one that replaced it.
        let state = state();
        let repo = TempRepo::new("retry-audit");
        let previous = rejected(&state, &repo, Some("no"));

        assert_eq!(previous.status, TaskStatus::Rejected);
        assert_eq!(previous.review_note.as_deref(), Some("no"));
        assert!(!previous.diff_json.is_empty());
    }

    #[test]
    fn undoing_an_applied_change_set_puts_the_files_back() {
        let state = state();
        let repo = TempRepo::new("undo");
        let task = awaiting(&state, &repo, "before\n", "after\n");

        review(&state, &task.id, Review::Approve, None, DecidedVia::Phone).unwrap();
        assert_eq!(
            std::fs::read_to_string(repo.0.join("a.txt")).unwrap(),
            "after\n"
        );

        let undone = revert(&state, &task.id, DecidedVia::Web).unwrap();
        assert_eq!(undone.status, TaskStatus::Reverted);
        assert_eq!(
            std::fs::read_to_string(repo.0.join("a.txt")).unwrap(),
            "before\n"
        );
    }

    #[test]
    fn only_an_applied_change_set_can_be_undone() {
        let state = state();
        let repo = TempRepo::new("undo-state");

        // Awaiting review: nothing has landed, so there is nothing to take back.
        let waiting = awaiting(&state, &repo, "before\n", "after\n");
        assert!(matches!(
            revert(&state, &waiting.id, DecidedVia::Web),
            Err(TaskError::Conflict(_))
        ));

        // Rejected: likewise.
        let refused = rejected(&state, &repo, Some("no"));
        assert!(matches!(
            revert(&state, &refused.id, DecidedVia::Web),
            Err(TaskError::Conflict(_))
        ));
    }

    #[test]
    fn undoing_twice_is_refused_rather_than_reapplying_the_original() {
        let state = state();
        let repo = TempRepo::new("undo-twice");
        let task = awaiting(&state, &repo, "before\n", "after\n");

        review(&state, &task.id, Review::Approve, None, DecidedVia::Phone).unwrap();
        revert(&state, &task.id, DecidedVia::Web).unwrap();

        assert!(matches!(
            revert(&state, &task.id, DecidedVia::Web),
            Err(TaskError::Conflict(_))
        ));
        assert_eq!(
            std::fs::read_to_string(repo.0.join("a.txt")).unwrap(),
            "before\n"
        );
    }

    #[test]
    fn undoing_refuses_when_somebody_edited_the_file_since() {
        // The mirror of the stale check on apply. Undoing over a later edit
        // would throw away work that was never the agent's to touch.
        let state = state();
        let repo = TempRepo::new("undo-stale");
        let task = awaiting(&state, &repo, "before\n", "after\n");
        review(&state, &task.id, Review::Approve, None, DecidedVia::Phone).unwrap();

        std::fs::write(repo.0.join("a.txt"), "a human kept going\n").unwrap();

        assert!(matches!(
            revert(&state, &task.id, DecidedVia::Web),
            Err(TaskError::Apply(_))
        ));
        assert_eq!(
            std::fs::read_to_string(repo.0.join("a.txt")).unwrap(),
            "a human kept going\n"
        );
        // And the task still says `applied`, because it still is.
        assert_eq!(
            state.store.get_task(&task.id).unwrap().unwrap().status,
            TaskStatus::Applied
        );
    }

    #[test]
    fn the_concurrency_cap_holds_and_releases() {
        let state = state();

        let slots: Vec<_> = (0..MAX_CONCURRENT_TASKS)
            .map(|_| TaskSlot::claim(&state).expect("under the cap"))
            .collect();
        assert!(
            TaskSlot::claim(&state).is_none(),
            "the cap did not hold — an unbounded spawn is an unbounded bill"
        );

        drop(slots);
        assert!(
            TaskSlot::claim(&state).is_some(),
            "slots were not released when their loops ended"
        );
    }

    #[test]
    fn a_task_refused_for_being_over_the_cap_leaves_no_row_behind() {
        let state = state();
        let repo = TempRepo::new("cap");
        let _held: Vec<_> = (0..MAX_CONCURRENT_TASKS)
            .map(|_| TaskSlot::claim(&state).unwrap())
            .collect();

        // No provider here, so this cannot reach the loop — what matters is
        // that a refusal at any stage writes nothing.
        let _ = start(
            &state,
            StartTask {
                repo_path: repo.path(),
                prompt: "x".into(),
                budget_usd: None,
                max_steps: None,
                retry_of: None,
            },
        );
        assert!(state.store.list_tasks(10).unwrap().is_empty());
    }

    #[test]
    fn a_task_left_running_by_a_restart_is_settled_rather_than_stuck() {
        let state = state();
        let repo = TempRepo::new("restart");
        let (task, _) = create_rows(
            &state,
            &StartTask {
                repo_path: repo.path(),
                prompt: "x".into(),
                budget_usd: None,
                max_steps: None,
                retry_of: None,
            },
        )
        .unwrap();
        assert_eq!(task.status, TaskStatus::Running);

        assert_eq!(reconcile_after_restart(&state), 1);

        let settled = state.store.get_task(&task.id).unwrap().unwrap();
        assert_eq!(settled.status, TaskStatus::Failed);
        assert!(settled.error.unwrap().contains("runner stopped"));

        // Idempotent: a second startup finds nothing left to settle.
        assert_eq!(reconcile_after_restart(&state), 0);
    }

    #[test]
    fn starting_without_a_provider_says_so_rather_than_creating_a_dead_task() {
        let state = state();
        let repo = TempRepo::new("noprovider");
        assert!(matches!(
            start(
                &state,
                StartTask {
                    repo_path: repo.path(),
                    prompt: "x".into(),
                    budget_usd: None,
                    max_steps: None,
                    retry_of: None,
                }
            ),
            Err(TaskError::NoProvider)
        ));
        assert!(state.store.list_tasks(10).unwrap().is_empty());
    }

    #[test]
    fn a_task_creates_a_session_it_can_be_billed_to() {
        let state = state();
        let repo = TempRepo::new("session");
        let (task, session) = create_rows(
            &state,
            &StartTask {
                repo_path: repo.path(),
                prompt: "x".into(),
                budget_usd: Some(2.50),
                max_steps: None,
                retry_of: None,
            },
        )
        .unwrap();

        assert_eq!(task.session_id, session.id);
        assert_eq!(session.agent, Agent::Forge);
        assert_eq!(
            state.store.session_budget(&session.id).unwrap().cap_usd,
            Some(2.50)
        );
    }
}
