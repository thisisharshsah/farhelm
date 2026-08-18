//! The read models a client renders.
//!
//! These are what `GET /v1/fleet` returns and what a `Command::Snapshot` reply
//! carries — the same bytes either way, which is the point. They are mirrored by
//! hand in `packages/client-core/src/api.ts` and, for the subset a wrist can
//! show, in the watch's Swift.
//!
//! # Why they are not in the HTTP module any more
//!
//! They used to live in `forge-runner/src/api.rs`, beside the axum handlers, and
//! that put a dependency in backwards. `commands::execute` — the transport
//! independent path that both the localhost API and the relay link run through —
//! had to name `crate::api::FleetView` for its reply type and call
//! `crate::api::build_fleet_view` to produce it. The layer whose whole job is to
//! not know about transports could not be compiled without the HTTP one.
//!
//! Errors show the same seam from the other side: those builders returned
//! `ApiError`, which carries a `StatusCode`. The relay has no status codes. It
//! was constructing 404s in order to throw them away.
//!
//! # Views, not entities
//!
//! A view is denormalised on purpose: [`SessionView`] carries `repo_name` and
//! `machine_name` because the screen shows them and a phone should not issue
//! three requests to render one row. That is also why they are `Serialize` only
//! — nothing sends one *to* the runner, so a `Deserialize` impl would just be an
//! invitation to start.

use serde::{Deserialize, Serialize};

use crate::diff::ChangeSet;
use crate::types::{Approval, DecidedVia, PlanStep, PlanStepStatus, SessionStatus, TaskStatus};

/// Budget as the UI needs it: the bar, the number, and the traffic light.
///
/// `state` is computed server-side so that four client implementations cannot
/// disagree about where the line is. This type only names the three answers —
/// the thresholds, and the mapping that picks between them, are policy and live
/// in `forge_domain::budget`.
#[derive(Debug, Clone, Serialize)]
pub struct BudgetView {
    pub cap_usd: Option<f64>,
    pub spent_usd: f64,
    pub pct: Option<f64>,
    /// `ok` | `warn` (≥80%) | `stop` (≥100%).
    pub state: &'static str,
}

impl PlanProgress {
    /// Fold a plan's steps into the glance.
    ///
    /// A projection of one wire shape onto another, which is why it is here. The
    /// plan *state machine* — which transitions are legal, what pausing does —
    /// is a rule and lives in `forge-domain`.
    pub fn of(steps: &[PlanStep]) -> Self {
        let current = steps
            .iter()
            .find(|step| step.status == PlanStepStatus::Active);
        Self {
            settled: steps
                .iter()
                .filter(|step| {
                    matches!(step.status, PlanStepStatus::Done | PlanStepStatus::Skipped)
                })
                .count(),
            total: steps.len(),
            current_ordinal: current.map(|step| step.ordinal),
            current_title: current.map(|step| step.title.clone()),
        }
    }

    /// True when no step remains that could still run.
    pub fn is_complete(&self) -> bool {
        self.total > 0 && self.settled == self.total
    }
}

impl From<&PlanStep> for PlanStepView {
    fn from(step: &PlanStep) -> Self {
        Self {
            ordinal: step.ordinal,
            title: step.title.clone(),
            status: step.status,
            checkpoint_sha: step.checkpoint_sha.clone(),
        }
    }
}

/// Where a plan stands, for the watch glance and the session list (B2).
///
/// The struct is the contract; deriving one from a list of steps is a rule and
/// lives in `forge-domain`.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct PlanProgress {
    /// Steps that reached a terminal state (done or skipped).
    pub settled: usize,
    pub total: usize,
    /// 1-based ordinal of the step in flight, if any.
    pub current_ordinal: Option<i64>,
    pub current_title: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SessionView {
    pub id: String,
    pub repo_name: String,
    pub machine_name: String,
    pub agent: String,
    pub status: SessionStatus,
    /// True when the session is live enough to act on — the ● / ○ glyph.
    pub is_live: bool,
    pub plan: Option<PlanProgress>,
    pub budget: BudgetView,
    pub started_at: i64,
    pub ended_at: Option<i64>,
    pub awaiting_approval_id: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct PlanStepView {
    pub ordinal: i64,
    pub title: String,
    pub status: PlanStepStatus,
    pub checkpoint_sha: Option<String>,
}

/// An approval card. Carries the budget because §4's wireframe review found the
/// moment of approval is the moment of spend — the bar belongs on the card.
#[derive(Debug, Clone, Serialize)]
pub struct ApprovalView {
    #[serde(flatten)]
    pub approval: Approval,
    pub repo_name: String,
    /// False for destructive commands: they must be decided on the phone (D3).
    pub allows_watch_decision: bool,
    pub budget: BudgetView,
}

#[derive(Debug, Clone, Serialize)]
pub struct SessionDetail {
    #[serde(flatten)]
    pub session: SessionView,
    pub steps: Vec<PlanStepView>,
    pub output: Vec<OutputLine>,
    pub pending_approval: Option<ApprovalView>,
}

/// The home screen: every session plus the cost strip along the bottom.
#[derive(Debug, Clone, Serialize)]
pub struct FleetView {
    pub sessions: Vec<SessionView>,
    pub pending_approvals: Vec<ApprovalView>,
    /// Change sets waiting on a human, oldest first.
    ///
    /// Carried on the fleet snapshot rather than behind a second request so a
    /// relayed device gets them for free — a phone that has just been woken has
    /// one round trip's patience, and this is the thing it was woken *for*.
    /// `TaskView` has no diff in it, so this stays a few hundred bytes however
    /// large the change sets are.
    pub tasks_awaiting_review: Vec<TaskView>,
    pub today_usd: f64,
    pub cache_hit_ratio: Option<f64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TierSlice {
    pub tier: String,
    pub usd: f64,
    pub share: f64,
}

/// Flow 4 — the cost dashboard.
#[derive(Debug, Clone, Serialize)]
pub struct DashboardView {
    pub session_id: String,
    pub repo_name: String,
    pub calls: usize,
    pub total_usd: f64,
    pub cache_hit_ratio: Option<f64>,
    pub by_tier: Vec<TierSlice>,
    pub avoided_calls: usize,
    /// Spend per hour over the requested window, oldest first — the sparkline.
    pub spend_series: Vec<SpendBucket>,
    pub budget: BudgetView,
}

#[derive(Debug, Clone, Serialize)]
pub struct SpendBucket {
    pub at_ms: i64,
    pub usd: f64,
}

/// One line of an agent's live output.
///
/// Not persisted: §6 sends `output_chunk` over the wire and forgets it. `seq` is
/// monotonic per session so a reconnecting client can tell what it missed — and,
/// because the in-memory tail is bounded, tell that lines were dropped rather
/// than silently missing them.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OutputLine {
    pub seq: u64,
    pub text: String,
    pub at_ms: i64,
}

/// A task as a list renders it.
///
/// Deliberately without `diff_json` or `worktree_json`: the change set can be
/// megabytes, and a list of twenty tasks would ship all twenty copies of it to
/// a phone that is showing one line each.
#[derive(Debug, Clone, Serialize)]
pub struct TaskView {
    pub id: String,
    pub session_id: String,
    pub repo_id: String,
    pub repo_name: String,
    /// The absolute path on this machine. Needed to retry a rejected task —
    /// `repo_name` is a display label and would resolve to nothing.
    pub repo_path: String,
    pub prompt: String,
    pub status: TaskStatus,
    /// The agent's closing message.
    pub summary: String,
    pub files_changed: i64,
    pub lines_added: i64,
    pub lines_removed: i64,
    /// `3 files, +42 −17`.
    pub change_summary: String,
    pub steps: i64,
    pub cost_usd: f64,
    pub error: Option<String>,
    pub review_note: Option<String>,
    /// C10's verdict: `pass` | `concerns` | `fail`. `null` means **not judged**,
    /// which a client must not render as a pass.
    pub verify_grade: Option<String>,
    pub verify_notes: Option<String>,
    pub verify_model: Option<String>,
    pub decided_via: Option<DecidedVia>,
    pub created_at: i64,
    pub updated_at: i64,
    pub decided_at: Option<i64>,
}

/// One task, with the diff a reviewer decides on.
#[derive(Debug, Clone, Serialize)]
pub struct TaskDetail {
    #[serde(flatten)]
    pub task: TaskView,
    /// Parsed, not the stored string — a client should not have to JSON-decode
    /// a field it just JSON-decoded.
    pub changes: ChangeSet,
    /// The patch as text, for copying out or piping to `git apply`.
    pub patch: String,
    pub output: Vec<OutputLine>,
}

/// What is waiting in the Batch API queue, and what it has cost so far (C6).
#[derive(Debug, Clone, Serialize)]
pub struct BatchQueueView {
    pub queued: usize,
    pub in_flight: usize,
    pub items: Vec<crate::types::BatchItem>,
}

/// One agent the runner can start, and how honest it can be about supervising it.
#[derive(Debug, Clone, Serialize)]
pub struct AgentView {
    pub id: String,
    pub name: String,
    pub binary: String,
    /// Whether the binary is on this machine's PATH right now.
    pub installed: bool,
    /// `hook` | `prompt` | `none`. How a decision reaches the agent.
    pub approvals: &'static str,
    /// False when nothing is gated — a plain shell, for instance.
    pub supervised: bool,
    /// True when the approval path has been checked against the real binary.
    /// The prompt dialects are pattern matching on terminal output and say so.
    pub verified: bool,
    pub note: String,
}
