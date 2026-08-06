//! The runner's localhost HTTP API — §6's "Gateway API", plus the read models
//! the phone and web clients render.
//!
//! Handlers call SQLite directly rather than through `spawn_blocking`. At
//! single-user scale every query here is a sub-millisecond read against a local
//! file; the blocking-pool hop would cost more than it saves. Revisit if the
//! team tier ever puts Postgres behind this.

use std::convert::Infallible;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use forge_core::id::new_id;
use forge_core::plan::PlanProgress;
use forge_core::store::{Store, TimeRange};
use forge_core::time::now_ms;
use forge_core::types::{
    Approval, Budget, DecidedVia, Decision, PlanStep, PlanStepStatus, Session, SessionStatus,
    TaskType,
};
use forge_gateway::prompt::{StableContext, Turn};
use forge_gateway::{CompleteRequest as GatewayRequest, GatewayError};
use futures_util::stream::Stream;
use serde::{Deserialize, Serialize};
use tokio_stream::StreamExt;
use tokio_stream::wrappers::BroadcastStream;
use tower_http::cors::CorsLayer;
use tower_http::services::{ServeDir, ServeFile};

use crate::commands;
use crate::session::SessionManager;
use crate::state::{AppState, OutputLine, ServerEvent};

/// Build the API router, optionally serving a built PWA from `app_dir`.
///
/// Unknown paths fall back to `index.html` so the hash-routed client survives a
/// hard refresh. `/v1/*` is matched first and never reaches the fallback.
pub fn router_with_app(state: Arc<AppState>, app_dir: Option<PathBuf>) -> Router {
    let api = router(state);
    match app_dir {
        Some(dir) => {
            let index = dir.join("index.html");
            api.fallback_service(ServeDir::new(dir).fallback(ServeFile::new(index)))
        }
        None => api,
    }
}

pub fn router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/v1/fleet", get(fleet))
        .route("/v1/sessions", get(list_sessions).post(start_session))
        .route("/v1/sessions/{id}/stop", post(stop_session))
        .route("/v1/sessions/{id}", get(session_detail))
        .route("/v1/sessions/{id}/instruction", post(send_instruction))
        .route("/v1/sessions/{id}/plan", post(plan_control))
        .route("/v1/sessions/{id}/usage", get(session_usage))
        .route("/v1/sessions/{id}/dashboard", get(session_dashboard))
        .route("/v1/approvals", get(list_approvals))
        .route("/v1/approvals/{id}/decision", post(decide))
        .route("/v1/tasks", get(list_tasks).post(start_task))
        .route("/v1/tasks/{id}", get(task_detail))
        .route("/v1/tasks/{id}/review", post(review_task))
        .route("/v1/tasks/{id}/revert", post(revert_task))
        .route("/v1/complete", post(complete))
        .route("/v1/hooks/tool-request", post(hook_tool_request))
        .route("/v1/hooks/stop", post(hook_stop))
        .route("/v1/hooks/notification", post(hook_notification))
        .route("/v1/events", get(events))
        .route("/v1/pair/offer", post(pair_offer))
        .route("/v1/pair/claim", post(pair_claim))
        .route("/v1/devices", get(list_devices))
        .route("/v1/agents", get(list_agents))
        .route("/v1/batch", get(batch_queue))
        .route("/v1/health", get(health))
        // The PWA is served from Vite in dev and from a different origin on the
        // phone, so the localhost API has to allow it. The runner binds to
        // loopback; this is not an internet-facing surface.
        .layer(CorsLayer::permissive())
        .with_state(state)
}

// ---------------------------------------------------------------- errors

pub struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn not_found(what: impl Into<String>) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            message: what.into(),
        }
    }
}

impl From<crate::commands::CommandError> for ApiError {
    fn from(err: crate::commands::CommandError) -> Self {
        use crate::commands::CommandError;
        let status = match &err {
            CommandError::NotFound(_) => StatusCode::NOT_FOUND,
            CommandError::Forbidden(_) => StatusCode::FORBIDDEN,
            CommandError::Conflict(_) => StatusCode::CONFLICT,
            CommandError::Terminal(_) => StatusCode::BAD_GATEWAY,
            CommandError::Store(_) | CommandError::Internal(_) => StatusCode::INTERNAL_SERVER_ERROR,
        };
        Self {
            status,
            message: err.to_string(),
        }
    }
}

impl From<forge_core::store::StoreError> for ApiError {
    fn from(err: forge_core::store::StoreError) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: err.to_string(),
        }
    }
}

impl From<crate::task::TaskError> for ApiError {
    fn from(err: crate::task::TaskError) -> Self {
        use crate::task::TaskError;
        let status = match &err {
            TaskError::NotADirectory(_) => StatusCode::BAD_REQUEST,
            TaskError::NotFound(_) => StatusCode::NOT_FOUND,
            // 429, with the same meaning it has anywhere else: come back.
            TaskError::TooBusy(_) => StatusCode::TOO_MANY_REQUESTS,
            // Includes "you cannot approve a diff from a watch", which is a 403
            // for the same reason the destructive-command rule is.
            TaskError::Conflict(_) => StatusCode::CONFLICT,
            TaskError::NoProvider => StatusCode::SERVICE_UNAVAILABLE,
            TaskError::Apply(_) | TaskError::Store(_) => StatusCode::INTERNAL_SERVER_ERROR,
        };
        Self {
            status,
            message: err.to_string(),
        }
    }
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(serde_json::json!({ "error": self.message })),
        )
            .into_response()
    }
}

type ApiResult<T> = Result<Json<T>, ApiError>;

/// What is waiting in the Batch API queue, and what it has cost so far (C6).
#[derive(Debug, Clone, Serialize)]
pub struct BatchQueueView {
    pub queued: usize,
    pub in_flight: usize,
    pub items: Vec<forge_core::types::BatchItem>,
}

/// `GET /v1/batch` — the deferred-work queue.
///
/// Exists because queued work is invisible otherwise: a deferrable call returns
/// an id and nothing else, and "where did my summary go" needs an answer that is
/// not "read the database".
async fn batch_queue(State(state): State<Arc<AppState>>) -> ApiResult<BatchQueueView> {
    let queued = state.store.list_queued_batch_items(200)?;
    let in_flight = state.store.list_submitted_batch_items()?;

    let mut items = queued.clone();
    items.extend(in_flight.iter().cloned());
    Ok(Json(BatchQueueView {
        queued: queued.len(),
        in_flight: in_flight.len(),
        items,
    }))
}

/* --------------------------------------------------- native agent tasks */

/// A task as a list renders it.
///
/// Deliberately without `diff_json` or `staged_json`: the change set can be
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
    pub status: forge_core::types::TaskStatus,
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
    pub changes: forge_agent::ChangeSet,
    /// The patch as text, for copying out or piping to `git apply`.
    pub patch: String,
    pub output: Vec<OutputLine>,
}

fn task_view(state: &AppState, task: forge_core::types::AgentTask) -> TaskView {
    let repo = state.store.get_repo(&task.repo_id).ok().flatten();
    let repo_name = repo
        .as_ref()
        .map(|repo| repo.name.clone())
        .unwrap_or_default();
    let repo_path = repo.map(|repo| repo.path).unwrap_or_default();

    TaskView {
        change_summary: task.change_summary(),
        id: task.id,
        session_id: task.session_id,
        repo_id: task.repo_id,
        repo_name,
        repo_path,
        prompt: task.prompt,
        status: task.status,
        summary: task.summary,
        files_changed: task.files_changed,
        lines_added: task.lines_added,
        lines_removed: task.lines_removed,
        steps: task.steps,
        cost_usd: task.cost_usd,
        error: task.error,
        review_note: task.review_note,
        verify_grade: task.verify_grade,
        verify_notes: task.verify_notes,
        verify_model: task.verify_model,
        decided_via: task.decided_via,
        created_at: task.created_at,
        updated_at: task.updated_at,
        decided_at: task.decided_at,
    }
}

/// `GET /v1/tasks` — every task, newest first.
async fn list_tasks(State(state): State<Arc<AppState>>) -> ApiResult<Vec<TaskView>> {
    Ok(Json(build_task_list(&state)?))
}

/// Shared with the relay, so a phone and a browser see the same list.
pub(crate) fn build_task_list(state: &Arc<AppState>) -> Result<Vec<TaskView>, ApiError> {
    Ok(state
        .store
        .list_tasks(100)?
        .into_iter()
        .map(|task| task_view(state, task))
        .collect())
}

/// `POST /v1/tasks` — start the native agent on a repo.
///
/// Returns as soon as the row exists. A task takes minutes and the client that
/// asked for it may be a phone about to lose signal; progress arrives on
/// `/v1/events` and the answer is a row, not a response body.
async fn start_task(
    State(state): State<Arc<AppState>>,
    Json(body): Json<crate::task::StartTask>,
) -> ApiResult<TaskView> {
    let task = crate::task::start(&state, body)?;
    Ok(Json(task_view(&state, task)))
}

/// `GET /v1/tasks/{id}` — the review screen's payload.
async fn task_detail(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> ApiResult<TaskDetail> {
    Ok(Json(build_task_detail(&state, &id)?))
}

/// The same payload the relay serves, so a phone reviewing over a relay and a
/// browser on loopback are looking at the same bytes.
pub(crate) fn build_task_detail(state: &Arc<AppState>, id: &str) -> Result<TaskDetail, ApiError> {
    let task = state
        .store
        .get_task(id)?
        .ok_or_else(|| ApiError::not_found(format!("task {id}")))?;

    // A change set that will not parse is reported as an empty one rather than
    // a 500: the rest of the row — what it cost, what went wrong, the output
    // tail — is exactly what somebody debugging that would want to see.
    let changes: forge_agent::ChangeSet = serde_json::from_str(&task.diff_json).unwrap_or_default();
    let output = state.output_tail(&task.session_id, 200);

    Ok(TaskDetail {
        patch: changes.render(),
        changes,
        task: task_view(state, task),
        output,
    })
}

#[derive(Debug, Deserialize)]
pub struct ReviewBody {
    pub decision: crate::task::Review,
    /// Why. Required in spirit for a rejection — it is what the next attempt
    /// is handed — but not enforced, because a reviewer on a train should not
    /// be blocked from saying no.
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub via: Option<DecidedVia>,
}

/// `POST /v1/tasks/{id}/review` — approve a change set onto disk, or reject it.
async fn review_task(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(body): Json<ReviewBody>,
) -> ApiResult<TaskView> {
    let task = crate::task::review(
        &state,
        &id,
        body.decision,
        body.note.as_deref().filter(|note| !note.trim().is_empty()),
        body.via.unwrap_or(DecidedVia::Web),
    )?;
    Ok(Json(task_view(&state, task)))
}

#[derive(Debug, Deserialize)]
pub struct RevertBody {
    #[serde(default)]
    pub via: Option<DecidedVia>,
}

/// `POST /v1/tasks/{id}/revert` — take an applied change set back off disk.
///
/// The overlay kept both sides, so this is `apply` in reverse. It refuses if any
/// touched file has changed since — undoing over somebody's later edit would
/// discard *their* work.
async fn revert_task(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    body: Option<Json<RevertBody>>,
) -> ApiResult<TaskView> {
    let via = body
        .and_then(|Json(body)| body.via)
        .unwrap_or(DecidedVia::Web);
    let task = crate::task::revert(&state, &id, via)?;
    Ok(Json(task_view(&state, task)))
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

/// `GET /v1/agents` — what this machine can start, and what it cannot.
///
/// `installed` is computed per request rather than cached: agents get installed
/// while the runner is up, and a stale "not installed" is a worse answer than a
/// PATH lookup.
async fn list_agents() -> Json<Vec<AgentView>> {
    use forge_core::agent::{ApprovalChannel, Confidence};

    Json(
        forge_core::agent::AGENTS
            .iter()
            .map(|spec| AgentView {
                id: spec.agent.as_str().to_owned(),
                name: spec.display_name.to_owned(),
                binary: spec.binary.to_owned(),
                installed: spec.binary.is_empty() || crate::pty::binary_exists(spec.binary),
                approvals: match spec.approvals {
                    ApprovalChannel::Hook => "hook",
                    ApprovalChannel::Prompt(_) => "prompt",
                    ApprovalChannel::Native => "native",
                    ApprovalChannel::None => "none",
                },
                supervised: spec.is_supervised(),
                verified: match spec.approvals {
                    // Native has no bridge and no pane to parse, so there is no
                    // gap between the agent and the queue that could drift.
                    ApprovalChannel::Hook | ApprovalChannel::Native => true,
                    ApprovalChannel::Prompt(dialect) => dialect.confidence == Confidence::Verified,
                    ApprovalChannel::None => false,
                },
                note: spec.note.to_owned(),
            })
            .collect(),
    )
}

// ---------------------------------------------------------------- read models

/// Budget as the UI needs it: the bar, the number, and the traffic light.
#[derive(Debug, Clone, Serialize)]
pub struct BudgetView {
    pub cap_usd: Option<f64>,
    pub spent_usd: f64,
    pub pct: Option<f64>,
    /// `ok` | `warn` (≥80%) | `stop` (≥100%).
    pub state: &'static str,
}

impl From<Budget> for BudgetView {
    fn from(budget: Budget) -> Self {
        Self {
            cap_usd: budget.cap_usd,
            spent_usd: budget.spent_usd,
            pct: budget.pct(),
            state: if budget.is_exhausted() {
                "stop"
            } else if budget.is_warning() {
                "warn"
            } else {
                "ok"
            },
        }
    }
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

// ---------------------------------------------------------------- assembly

/// Builds a [`SessionView`]. Issues a handful of small reads per session rather
/// than one join, keeping the `Store` trait narrow enough to reimplement.
fn view_of(state: &AppState, session: &Session) -> Result<SessionView, ApiError> {
    let repo = state
        .store
        .get_repo(&session.repo_id)?
        .ok_or_else(|| ApiError::not_found(format!("repo {}", session.repo_id)))?;
    let machine = state.store.get_machine(&repo.machine_id)?;

    let plan = match &session.plan_id {
        Some(plan_id) => {
            let steps = state.store.list_plan_steps(plan_id)?;
            (!steps.is_empty()).then(|| PlanProgress::of(&steps))
        }
        None => None,
    };

    let awaiting_approval_id = state
        .store
        .list_pending_approvals()?
        .into_iter()
        .find(|approval| approval.session_id == session.id)
        .map(|approval| approval.id);

    Ok(SessionView {
        id: session.id.clone(),
        repo_name: repo.name,
        machine_name: machine.map(|m| m.name).unwrap_or_else(|| "unknown".into()),
        agent: session.agent.to_string(),
        status: session.status,
        is_live: matches!(
            session.status,
            SessionStatus::Running | SessionStatus::AwaitingApproval | SessionStatus::Paused
        ),
        plan,
        budget: state.store.session_budget(&session.id)?.into(),
        started_at: session.started_at,
        ended_at: session.ended_at,
        awaiting_approval_id,
    })
}

fn approval_view(state: &AppState, approval: Approval) -> Result<ApprovalView, ApiError> {
    let session = state
        .store
        .get_session(&approval.session_id)?
        .ok_or_else(|| ApiError::not_found(format!("session {}", approval.session_id)))?;
    let repo = state.store.get_repo(&session.repo_id)?;

    Ok(ApprovalView {
        allows_watch_decision: approval.allows_watch_decision(),
        repo_name: repo.map(|r| r.name).unwrap_or_else(|| "unknown".into()),
        budget: state.store.session_budget(&approval.session_id)?.into(),
        approval,
    })
}

// ---------------------------------------------------------------- handlers

async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "ok": true }))
}

async fn list_sessions(State(state): State<Arc<AppState>>) -> ApiResult<Vec<SessionView>> {
    let sessions = state.store.list_sessions()?;
    let views = sessions
        .iter()
        .map(|session| view_of(&state, session))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Json(views))
}

async fn fleet(State(state): State<Arc<AppState>>) -> ApiResult<FleetView> {
    Ok(Json(build_fleet_view(&state)?))
}

/// The home screen, assembled.
///
/// Shared with the relay link: a remote device has no request/response channel,
/// so it asks for this over the same socket it receives events on.
pub(crate) fn build_fleet_view(state: &Arc<AppState>) -> Result<FleetView, ApiError> {
    let sessions = state.store.list_sessions()?;
    let views = sessions
        .iter()
        .map(|session| view_of(state, session))
        .collect::<Result<Vec<_>, _>>()?;

    let pending_approvals = state
        .store
        .list_pending_approvals()?
        .into_iter()
        .map(|approval| approval_view(state, approval))
        .collect::<Result<Vec<_>, _>>()?;

    // "Today" is the last 24h rather than a calendar day: the runner has no
    // notion of the phone's timezone, and a rolling window is what the strip
    // actually means to someone glancing at it.
    let since = TimeRange::since(now_ms() - 24 * 60 * 60 * 1_000);
    let mut today_usd = 0.0;
    let mut cache_reads: u64 = 0;
    let mut fresh_input: u64 = 0;
    for session in &sessions {
        for event in state.store.list_usage(&session.id, since)? {
            today_usd += event.cost_usd;
            cache_reads += u64::from(event.usage.cache_read_tokens);
            fresh_input += u64::from(event.usage.input_tokens);
        }
    }

    let tasks_awaiting_review = state
        .store
        .list_tasks_awaiting_review()?
        .into_iter()
        .map(|task| task_view(state, task))
        .collect();

    Ok(FleetView {
        sessions: views,
        pending_approvals,
        tasks_awaiting_review,
        today_usd,
        cache_hit_ratio: (cache_reads + fresh_input > 0)
            .then(|| cache_reads as f64 / (cache_reads + fresh_input) as f64),
    })
}

async fn session_detail(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> ApiResult<SessionDetail> {
    Ok(Json(build_session_detail(&state, &id)?))
}

/// One session, assembled. Shared with the relay link for the same reason
/// [`build_fleet_view`] is.
pub(crate) fn build_session_detail(
    state: &Arc<AppState>,
    id: &str,
) -> Result<SessionDetail, ApiError> {
    let session = state
        .store
        .get_session(id)?
        .ok_or_else(|| ApiError::not_found(format!("session {id}")))?;
    let view = view_of(state, &session)?;

    let steps = match &session.plan_id {
        Some(plan_id) => state
            .store
            .list_plan_steps(plan_id)?
            .iter()
            .map(PlanStepView::from)
            .collect(),
        None => Vec::new(),
    };

    let pending_approval = match &view.awaiting_approval_id {
        Some(approval_id) => state
            .store
            .get_approval(approval_id)?
            .map(|approval| approval_view(state, approval))
            .transpose()?,
        None => None,
    };

    Ok(SessionDetail {
        session: view,
        steps,
        output: state.output_tail(id, 80),
        pending_approval,
    })
}

#[derive(Debug, Deserialize)]
pub struct InstructionBody {
    pub text: String,
}

async fn send_instruction(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(body): Json<InstructionBody>,
) -> ApiResult<serde_json::Value> {
    match commands::execute(
        &state,
        commands::Command::Instruct {
            session_id: id,
            text: body.text,
        },
        DecidedVia::Web,
    )
    .await?
    {
        commands::Outcome::Instructed { delivered, .. } => Ok(Json(serde_json::json!({
            "delivered": delivered,
            "note": if delivered {
                serde_json::Value::Null
            } else {
                "this session has no terminal the runner controls".into()
            },
        }))),
        other => Err(ApiError {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: format!("unexpected outcome: {other:?}"),
        }),
    }
}

#[derive(Debug, Deserialize)]
pub struct PlanControlBody {
    pub action: commands::PlanAction,
}

async fn plan_control(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(body): Json<PlanControlBody>,
) -> ApiResult<Vec<PlanStepView>> {
    match commands::execute(
        &state,
        commands::Command::PlanControl {
            session_id: id,
            action: body.action,
        },
        DecidedVia::Web,
    )
    .await?
    {
        commands::Outcome::PlanChanged { steps, .. } => {
            Ok(Json(steps.iter().map(PlanStepView::from).collect()))
        }
        other => Err(ApiError {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: format!("unexpected outcome: {other:?}"),
        }),
    }
}

#[derive(Debug, Deserialize)]
pub struct UsageQuery {
    pub since_ms: Option<i64>,
}

async fn session_usage(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Query(query): Query<UsageQuery>,
) -> ApiResult<Vec<forge_core::types::UsageEvent>> {
    let range = TimeRange {
        since_ms: query.since_ms,
        until_ms: None,
    };
    Ok(Json(state.store.list_usage(&id, range)?))
}

async fn list_approvals(State(state): State<Arc<AppState>>) -> ApiResult<Vec<ApprovalView>> {
    let approvals = state
        .store
        .list_pending_approvals()?
        .into_iter()
        .map(|approval| approval_view(&state, approval))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Json(approvals))
}

#[derive(Debug, Deserialize)]
pub struct DecisionBody {
    pub decision: Decision,
    pub via: DecidedVia,
}

async fn decide(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(body): Json<DecisionBody>,
) -> ApiResult<ApprovalView> {
    // The guard and the race resolution both live in `commands`, shared with the
    // relay link — a decision arriving over the relay gets identical treatment.
    commands::execute(
        &state,
        commands::Command::Decide {
            approval_id: id.clone(),
            decision: body.decision,
        },
        body.via,
    )
    .await?;

    let approval = state
        .store
        .get_approval(&id)?
        .ok_or_else(|| ApiError::not_found(format!("approval {id}")))?;
    Ok(Json(approval_view(&state, approval)?))
}

async fn session_dashboard(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Query(query): Query<UsageQuery>,
) -> ApiResult<DashboardView> {
    Ok(Json(build_dashboard(&state, &id, query.since_ms)?))
}

/// Flow 4, assembled.
///
/// Shared with the relay link — the third snapshot type. Until this existed the
/// cost dashboard was the one screen a paired phone could not open, because a
/// remote device has no request/response channel and there was nothing for it to
/// ask for. Both surfaces now render the same bytes.
pub(crate) fn build_dashboard(
    state: &Arc<AppState>,
    id: &str,
    since_ms: Option<i64>,
) -> Result<DashboardView, ApiError> {
    let session = state
        .store
        .get_session(id)?
        .ok_or_else(|| ApiError::not_found(format!("session {id}")))?;
    let repo = state.store.get_repo(&session.repo_id)?;

    let range = TimeRange {
        since_ms,
        until_ms: None,
    };
    let events = state.store.list_usage(id, range)?;
    let summary = forge_core::ledger::Summary::from_events(&events);

    let by_tier = summary
        .usd_by_tier
        .iter()
        .map(|(tier, usd)| TierSlice {
            tier: tier.to_string(),
            usd: *usd,
            share: if summary.total_usd > 0.0 {
                usd / summary.total_usd
            } else {
                0.0
            },
        })
        .collect();

    const BUCKET_MS: i64 = 60 * 60 * 1_000;
    let mut spend_series: Vec<SpendBucket> = Vec::new();
    for event in &events {
        let bucket = event.created_at - event.created_at.rem_euclid(BUCKET_MS);
        match spend_series.last_mut() {
            Some(last) if last.at_ms == bucket => last.usd += event.cost_usd,
            _ => spend_series.push(SpendBucket {
                at_ms: bucket,
                usd: event.cost_usd,
            }),
        }
    }

    Ok(DashboardView {
        session_id: id.to_owned(),
        repo_name: repo.map(|r| r.name).unwrap_or_else(|| "unknown".into()),
        calls: summary.calls,
        total_usd: summary.total_usd,
        cache_hit_ratio: summary.cache_read_ratio(),
        by_tier,
        avoided_calls: summary.avoided_calls.values().sum(),
        spend_series,
        budget: state.store.session_budget(id)?.into(),
    })
}

/* --------------------------------------------------- session lifecycle */

#[derive(Debug, Deserialize)]
pub struct StartSessionBody {
    /// Absolute path to the repo the agent should work in.
    pub repo_path: String,
    /// `claude-code` (default) or `opencode`.
    #[serde(default)]
    pub agent: Option<forge_core::types::Agent>,
}

/// `POST /v1/sessions` — start an agent in a repo.
///
/// The MVP starts sessions at the runner (A6, start-from-phone, is P1), but the
/// endpoint is the same one a phone would call, so bringing A6 forward is a
/// client change rather than a server one.
async fn start_session(
    State(state): State<Arc<AppState>>,
    Json(body): Json<StartSessionBody>,
) -> ApiResult<SessionView> {
    let path = std::path::Path::new(&body.repo_path);
    if !path.is_dir() {
        return Err(ApiError {
            status: StatusCode::BAD_REQUEST,
            message: format!("{} is not a directory on this machine", body.repo_path),
        });
    }

    let repo = match state
        .store
        .find_repo_by_path(&state.machine_id, &body.repo_path)?
    {
        Some(repo) => repo,
        None => {
            let repo = forge_core::types::Repo {
                id: new_id(),
                machine_id: state.machine_id.clone(),
                path: body.repo_path.clone(),
                name: path
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_else(|| body.repo_path.clone()),
                budget_usd: None,
            };
            state.store.upsert_repo(&repo)?;
            repo
        }
    };

    let agent = body.agent.unwrap_or(forge_core::types::Agent::ClaudeCode);

    // Checked before anything is written. Starting a session for an agent that
    // is not installed would leave a row pointing at a pane that died instantly,
    // and the user would see "dead" with no reason given.
    let spec = forge_core::agent::spec(agent);
    if !spec.binary.is_empty() && !crate::pty::binary_exists(spec.binary) {
        return Err(ApiError {
            status: StatusCode::SERVICE_UNAVAILABLE,
            message: format!(
                "{} is not installed on this machine — `{}` is not on PATH",
                spec.display_name, spec.binary
            ),
        });
    }

    let manager = SessionManager::new(Arc::clone(&state), Arc::clone(&state.terminal));
    let session = manager.start(&repo, agent).await.map_err(|err| ApiError {
        // A missing tmux is a setup problem on the runner box, not a bad request.
        status: StatusCode::SERVICE_UNAVAILABLE,
        message: err.to_string(),
    })?;

    Ok(Json(view_of(&state, &session)?))
}

/// `POST /v1/sessions/{id}/stop` — end a session and its pane.
async fn stop_session(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> ApiResult<SessionView> {
    let manager = SessionManager::new(Arc::clone(&state), Arc::clone(&state.terminal));
    manager.stop(&id).await.map_err(|err| ApiError {
        status: StatusCode::BAD_GATEWAY,
        message: err.to_string(),
    })?;

    let session = state
        .store
        .get_session(&id)?
        .ok_or_else(|| ApiError::not_found(format!("session {id}")))?;
    Ok(Json(view_of(&state, &session)?))
}

/* ------------------------------------------------------------ device pairing */

/// `POST /v1/pair/offer` — mint a single-use pairing offer.
///
/// The payload is what goes in the QR code: where the relay is, which channel,
/// the runner's public key, and a code good once before it expires.
async fn pair_offer(State(state): State<Arc<AppState>>) -> ApiResult<forge_crypto::PairingOffer> {
    let relay = state
        .relay
        .clone()
        .unwrap_or_else(|| crate::state::RelayInfo {
            // Without a relay the offer still works for a device on the same
            // network; it just has nowhere remote to connect.
            url: String::new(),
            channel: state.machine_id.clone(),
        });

    let offer = state
        .pairing
        .lock()
        .expect("pairing broker poisoned")
        .offer(
            &relay.url,
            &relay.channel,
            state.identity.public_key(),
            now_ms(),
        );
    Ok(Json(offer))
}

#[derive(Debug, Deserialize)]
pub struct PairClaimBody {
    /// The one-time code from the QR.
    pub code: String,
    pub kind: forge_core::types::DeviceKind,
    /// The device's own public key.
    pub public_key: String,
}

/// `POST /v1/pair/claim` — redeem a code and register the device.
async fn pair_claim(
    State(state): State<Arc<AppState>>,
    Json(body): Json<PairClaimBody>,
) -> ApiResult<forge_core::types::Device> {
    // Redeemed first: a claim with a bad key must still burn the code, or a
    // photographed QR could be retried until something sticks.
    state
        .pairing
        .lock()
        .expect("pairing broker poisoned")
        .redeem(&body.code, now_ms())
        .map_err(|err| ApiError {
            status: StatusCode::FORBIDDEN,
            message: err.to_string(),
        })?;

    let public_key = forge_crypto::PublicKey::parse(&body.public_key).map_err(|err| ApiError {
        status: StatusCode::BAD_REQUEST,
        message: err.to_string(),
    })?;

    let device = forge_core::types::Device {
        id: new_id(),
        kind: body.kind,
        pubkey: public_key.to_string(),
        push_token: None,
        paired_at: now_ms(),
    };
    state.store.upsert_device(&device)?;
    Ok(Json(device))
}

/// `GET /v1/devices` — what is paired. Public keys only; no secrets exist here.
async fn list_devices(
    State(state): State<Arc<AppState>>,
) -> ApiResult<Vec<forge_core::types::Device>> {
    Ok(Json(state.store.list_devices()?))
}

/* ------------------------------------------------------- the hook bridge */

/// How long a tool request waits for a human before it is denied.
///
/// Generous, because push notification is the mechanism and a person may be
/// away from the phone. It is a ceiling, not a target: the Appendix A goal is a
/// median under five seconds.
const DEFAULT_APPROVAL_WAIT: Duration = Duration::from_secs(15 * 60);

#[derive(Debug, Deserialize)]
pub struct ToolRequestBody {
    /// The *agent's* session id, from the hook payload.
    pub agent_session_id: String,
    /// The agent's working directory — how the request finds its repo.
    pub cwd: String,
    pub tool: String,
    /// The command or file summary the human decides on.
    pub payload: String,
    #[serde(default)]
    pub wait_ms: Option<u64>,
}

#[derive(Debug, Serialize)]
pub struct ToolRequestView {
    /// `approved` | `denied` | `timeout`.
    pub decision: Decision,
    pub reason: String,
    pub approval_id: String,
    pub session_id: String,
    pub risk: forge_core::types::Risk,
}

/// Resolve (or create) the RelayForge session behind an agent's hook callback.
///
/// A hook can fire for a repo the runner has never seen — an agent started by
/// hand, in a directory nobody registered. Refusing would make the bridge
/// useless in exactly the case it is most needed, so the runner adopts it.
fn resolve_session(
    state: &AppState,
    agent_session_id: &str,
    cwd: &str,
) -> Result<Session, ApiError> {
    if let Some(session) = state.store.find_session_by_agent_id(agent_session_id)? {
        return Ok(session);
    }

    let now = now_ms();
    let repo = match state.store.find_repo_by_path(&state.machine_id, cwd)? {
        Some(repo) => repo,
        None => {
            let repo = forge_core::types::Repo {
                id: new_id(),
                machine_id: state.machine_id.clone(),
                path: cwd.to_owned(),
                name: std::path::Path::new(cwd)
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_else(|| cwd.to_owned()),
                // No cap by default: inventing one would stop work the user
                // never asked to have stopped. Caps are set deliberately.
                budget_usd: None,
            };
            state.store.upsert_repo(&repo)?;
            repo
        }
    };

    let session = Session {
        id: new_id(),
        repo_id: repo.id,
        agent: forge_core::types::Agent::ClaudeCode,
        tmux_target: None,
        status: SessionStatus::Running,
        plan_id: None,
        budget_usd: None,
        spent_usd: 0.0,
        started_at: now,
        ended_at: None,
        agent_session_id: Some(agent_session_id.to_owned()),
    };
    state.store.upsert_session(&session)?;
    Ok(session)
}

/// Wait for a decision on an approval, or record a timeout.
///
/// Subscribes to the event bus **before** re-reading the store, so a decision
/// landing in the gap between the two cannot be missed — without that ordering
/// this blocks for the full timeout on an already-answered request.
pub(crate) async fn await_decision(
    state: &Arc<AppState>,
    approval_id: &str,
    wait: Duration,
) -> Result<Approval, ApiError> {
    let mut events = state.events.subscribe();

    let settled = |state: &AppState| -> Result<Option<Approval>, ApiError> {
        Ok(state
            .store
            .get_approval(approval_id)?
            .filter(|approval| !approval.is_pending()))
    };

    if let Some(approval) = settled(state)? {
        return Ok(approval);
    }

    let deadline = tokio::time::Instant::now() + wait;
    loop {
        match tokio::time::timeout_at(deadline, events.recv()).await {
            Ok(Ok(ServerEvent::ApprovalDecision {
                approval_id: id, ..
            })) if id == approval_id => {
                if let Some(approval) = settled(state)? {
                    return Ok(approval);
                }
            }
            // Any other event, or a lagged receiver: re-check and keep waiting.
            Ok(Ok(_)) | Ok(Err(_)) => {
                if let Some(approval) = settled(state)? {
                    return Ok(approval);
                }
            }
            Err(_) => break,
        }
    }

    // Nobody answered. Record it as a timeout so the audit trail says so, and
    // let the caller deny — an unanswered request must never become an allow.
    let outcome = state.store.decide_approval(
        approval_id,
        Decision::Timeout,
        DecidedVia::AutoPolicy,
        now_ms(),
    )?;
    Ok(outcome.approval().clone())
}

/// `POST /v1/hooks/tool-request` — blocks until a human decides.
async fn hook_tool_request(
    State(state): State<Arc<AppState>>,
    Json(body): Json<ToolRequestBody>,
) -> ApiResult<ToolRequestView> {
    let session = resolve_session(&state, &body.agent_session_id, &body.cwd)?;

    // One classifier, server-side. A compromised or outdated hook binary cannot
    // talk the runner into treating `rm -rf` as low risk.
    let risk = forge_core::risk::classify_with(&state.policy, &body.tool, &body.payload);

    let approval = Approval {
        id: new_id(),
        session_id: session.id.clone(),
        tool: body.tool.clone(),
        payload: body.payload.clone(),
        risk,
        decision: None,
        decided_via: None,
        requested_at: now_ms(),
        decided_at: None,
    };
    state.store.create_approval(&approval)?;

    let mut waiting = session.clone();
    waiting.status = SessionStatus::AwaitingApproval;
    state.store.upsert_session(&waiting)?;

    state.push_output(
        &session.id,
        format!("⏳ awaiting approval — {} {}", body.tool, body.payload),
        now_ms(),
    );
    state.publish(ServerEvent::ApprovalRequest {
        approval: approval.clone(),
    });
    state.publish(ServerEvent::SessionUpsert {
        session_id: session.id.clone(),
    });

    let wait = body
        .wait_ms
        .map(Duration::from_millis)
        .unwrap_or(DEFAULT_APPROVAL_WAIT);
    let settled = await_decision(&state, &approval.id, wait).await?;

    let mut resumed = session.clone();
    resumed.status = SessionStatus::Running;
    state.store.upsert_session(&resumed)?;
    state.publish(ServerEvent::SessionUpsert {
        session_id: session.id.clone(),
    });

    let decision = settled.decision.unwrap_or(Decision::Timeout);
    let reason = match decision {
        Decision::Approved => format!(
            "approved from {}",
            settled
                .decided_via
                .map(|via| via.to_string())
                .unwrap_or_else(|| "an unknown device".into())
        ),
        Decision::Denied => "denied by the developer".to_owned(),
        Decision::Timeout => {
            // Sub-second waits only occur in tests, but "within 0s" reads as a
            // bug report rather than an explanation.
            let elapsed = if wait.as_secs() > 0 {
                format!("{}s", wait.as_secs())
            } else {
                format!("{}ms", wait.as_millis())
            };
            format!("no response within {elapsed} — denied by default")
        }
    };
    state.push_output(&session.id, format!("• {reason}"), now_ms());

    Ok(Json(ToolRequestView {
        decision,
        reason,
        approval_id: settled.id,
        session_id: session.id,
        risk,
    }))
}

#[derive(Debug, Deserialize)]
pub struct HookNoticeBody {
    pub agent_session_id: String,
    pub cwd: String,
    #[serde(default)]
    pub message: String,
    /// Only present on `Notification` events.
    #[serde(default)]
    pub notification_type: Option<String>,
}

/// `POST /v1/hooks/stop` — the agent finished its turn.
async fn hook_stop(
    State(state): State<Arc<AppState>>,
    Json(body): Json<HookNoticeBody>,
) -> ApiResult<serde_json::Value> {
    let session = resolve_session(&state, &body.agent_session_id, &body.cwd)?;

    if !body.message.trim().is_empty() {
        state.push_output(&session.id, body.message.trim(), now_ms());
    }

    // Idle, not finished: a Stop means the turn ended, and the next user message
    // starts another. Marking it `done` here would garbage-collect a live
    // session out of the fleet view.
    let mut idle = session.clone();
    idle.status = SessionStatus::Paused;
    state.store.upsert_session(&idle)?;
    state.publish(ServerEvent::SessionUpsert {
        session_id: session.id.clone(),
    });

    Ok(Json(serde_json::json!({ "session_id": session.id })))
}

/// `POST /v1/hooks/notification` — the agent wants attention.
async fn hook_notification(
    State(state): State<Arc<AppState>>,
    Json(body): Json<HookNoticeBody>,
) -> ApiResult<serde_json::Value> {
    let session = resolve_session(&state, &body.agent_session_id, &body.cwd)?;

    let kind = body.notification_type.as_deref().unwrap_or("notification");
    state.push_output(
        &session.id,
        format!("🔔 {kind}: {}", body.message.trim()),
        now_ms(),
    );
    state.publish(ServerEvent::SessionUpsert {
        session_id: session.id.clone(),
    });

    Ok(Json(serde_json::json!({ "session_id": session.id })))
}

/* ------------------------------------------------------- the cost gateway */

/// `POST /v1/complete` — §6's gateway API.
///
/// This is the endpoint an agent points `ANTHROPIC_BASE_URL`-style redirection
/// at (full-gateway mode). Everything the caller sends is split into the stable
/// half of the prompt and the one instruction that changes, because that split
/// is what makes prompt caching work — the gateway will not accept a blob and
/// guess where the boundary is.
#[derive(Debug, Deserialize)]
pub struct CompleteBody {
    pub session_id: String,
    pub task_type: TaskType,
    /// What changes this turn.
    pub instruction: String,
    /// Frozen system prompt. No dates, no ids — anything volatile here destroys
    /// the cache for every turn that follows.
    #[serde(default)]
    pub system: String,
    #[serde(default)]
    pub conventions: String,
    #[serde(default)]
    pub history: Vec<Turn>,
    #[serde(default)]
    pub tools: Vec<serde_json::Value>,
    /// Absolute path. Enables the pre-gate and retrieval.
    #[serde(default)]
    pub repo_path: Option<String>,
    #[serde(default)]
    pub tier_pin: Option<forge_core::types::Tier>,
    #[serde(default)]
    pub verify_only: bool,
    #[serde(default)]
    pub deferrable: bool,
}

#[derive(Debug, Serialize)]
pub struct CompleteView {
    pub text: String,
    pub model: String,
    pub tier: forge_core::types::Tier,
    pub usage: forge_core::types::Usage,
    pub cost_usd: f64,
    /// `pre_gate` or `response_cache` when the call cost nothing.
    pub avoided: Option<forge_core::types::Avoided>,
    pub refusal: Option<forge_gateway::dispatch::Refusal>,
    pub budget: BudgetView,
    /// What each stage did — the answer to "why did that cost what it cost".
    pub trace: forge_gateway::StageTrace,
}

async fn complete(
    State(state): State<Arc<AppState>>,
    Json(body): Json<CompleteBody>,
) -> ApiResult<CompleteView> {
    let Some(gateway) = &state.gateway else {
        return Err(ApiError {
            status: StatusCode::SERVICE_UNAVAILABLE,
            message: "no model provider configured — set ANTHROPIC_API_KEY or \
                 ANTHROPIC_AUTH_TOKEN and restart"
                .into(),
        });
    };

    let mut request = GatewayRequest::new(&body.session_id, body.task_type, &body.instruction);
    request.stable = StableContext {
        tools: body.tools,
        system: body.system,
        conventions: body.conventions,
        repo_map: String::new(),
        history: body.history,
    };
    request.repo_path = body.repo_path.as_deref().map(PathBuf::from);
    request.tier_pin = body.tier_pin;
    request.verify_only = body.verify_only;
    request.deferrable = body.deferrable;

    let response = gateway.complete(request).await.map_err(|err| match err {
        // 402 rather than 400: the request was valid, the money ran out. An
        // agent can distinguish "fix your call" from "top up or raise the cap".
        GatewayError::BudgetExhausted { .. } => ApiError {
            status: StatusCode::PAYMENT_REQUIRED,
            message: err.to_string(),
        },
        GatewayError::Dispatch(_) => ApiError {
            status: StatusCode::BAD_GATEWAY,
            message: err.to_string(),
        },
        other => ApiError {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: other.to_string(),
        },
    })?;

    let budget = state.store.session_budget(&body.session_id)?;
    if budget.is_warning() {
        state.publish(ServerEvent::BudgetAlert {
            session_id: body.session_id.clone(),
            pct: budget.pct().unwrap_or(0.0),
            hard_stop: budget.is_exhausted(),
        });
    }
    state.publish(ServerEvent::SessionUpsert {
        session_id: body.session_id.clone(),
    });

    Ok(Json(CompleteView {
        text: response.text,
        model: response.model,
        tier: response.tier,
        usage: response.usage,
        cost_usd: response.cost_usd,
        avoided: response.avoided,
        refusal: response.refusal,
        budget: budget.into(),
        trace: response.trace,
    }))
}

/// Server-sent events. Chosen over a WebSocket for the local API because it is
/// one-directional (commands are plain POSTs) and reconnects for free.
async fn events(
    State(state): State<Arc<AppState>>,
) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let stream = BroadcastStream::new(state.events.subscribe()).filter_map(|event| {
        // A lagged receiver yields an error; drop it and keep streaming rather
        // than tearing down the connection. The client re-fetches on reconnect.
        let event = event.ok()?;
        Some(Ok(Event::default().json_data(&event).unwrap_or_default()))
    });

    Sse::new(stream).keep_alive(
        KeepAlive::new()
            .interval(Duration::from_secs(15))
            .text("keep-alive"),
    )
}
