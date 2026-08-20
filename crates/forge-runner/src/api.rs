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
use forge_app::id::new_id;
use forge_app::store::{TimeRange, prelude::*};
use forge_app::time::now_ms;
use forge_domain::BudgetRules as _;
use forge_gateway::prompt::{StableContext, Turn};
use forge_gateway::{CompleteRequest as GatewayRequest, GatewayError};
use forge_proto::types::{Approval, DecidedVia, Decision, Session, SessionStatus, TaskType};
use futures_util::stream::Stream;
use serde::{Deserialize, Serialize};
use tokio_stream::StreamExt;
use tokio_stream::wrappers::BroadcastStream;
use tower_http::cors::CorsLayer;
use tower_http::services::{ServeDir, ServeFile};

use crate::commands;
use crate::state::{AppState, ServerEvent};

/// Build the API router, optionally serving a built PWA from `app_dir`.
///
/// Unknown paths fall back to `index.html` so the hash-routed client survives a
/// hard refresh. `/v1/*` is matched first and never reaches the fallback.
pub fn router_with_app(state: Arc<AppState>, app_dir: Option<PathBuf>) -> Router {
    router_with_app_and_auth(state, app_dir, LocalAuth::open())
}

pub fn router_with_app_and_auth(
    state: Arc<AppState>,
    app_dir: Option<PathBuf>,
    auth: LocalAuth,
) -> Router {
    let api = router_with_auth(state, auth);
    match app_dir {
        Some(dir) => {
            let index = dir.join("index.html");
            api.fallback_service(ServeDir::new(dir).fallback(ServeFile::new(index)))
        }
        None => api,
    }
}

/// Who may talk to the runner's own HTTP API.
///
/// # The hole this closes
///
/// The runner binds loopback, so nothing on the network can reach it. That was
/// taken as sufficient, and it is not: `CorsLayer::permissive()` told every
/// browser that **any** website may make cross-origin requests here *and read
/// the response*. A page in a tab the user already had open could enumerate
/// their repositories, start a session, and approve a destructive command — from
/// the outside, over a port that is "only local".
///
/// So the origin list is now explicit, and there is a token for the case where
/// somebody deliberately binds this to a real interface.
#[derive(Debug, Clone, Default)]
pub struct LocalAuth {
    /// Required on every `/v1/*` request when set. Minted automatically when the
    /// runner is bound to anything other than loopback, because at that point
    /// the network *is* the threat model.
    pub token: Option<String>,
}

impl LocalAuth {
    pub fn open() -> Self {
        Self::default()
    }

    pub fn with_token(token: impl Into<String>) -> Self {
        Self {
            token: Some(token.into()),
        }
    }
}

/// Paths reachable without the local token.
///
/// `/v1/health` only: a supervisor, a container probe, or a person with `curl`
/// needs to be able to ask "are you up" without holding a credential, and the
/// answer contains nothing.
fn is_public_path(path: &str) -> bool {
    path == "/v1/health"
}

pub fn router(state: Arc<AppState>) -> Router {
    router_with_auth(state, LocalAuth::open())
}

pub fn router_with_auth(state: Arc<AppState>, auth: LocalAuth) -> Router {
    let router = base_router(state);
    match auth.token {
        Some(token) => router.layer(axum::middleware::from_fn(
            move |request: axum::extract::Request, next: axum::middleware::Next| {
                let token = token.clone();
                async move {
                    if is_public_path(request.uri().path()) {
                        return next.run(request).await;
                    }
                    let presented = request
                        .headers()
                        .get(axum::http::header::AUTHORIZATION)
                        .and_then(|value| value.to_str().ok())
                        .and_then(|value| value.strip_prefix("Bearer "))
                        .map(str::trim)
                        .unwrap_or_default();

                    if presented.len() == token.len()
                        && presented
                            .bytes()
                            .zip(token.bytes())
                            .fold(0u8, |acc, (a, b)| acc | (a ^ b))
                            == 0
                    {
                        return next.run(request).await;
                    }
                    (
                        StatusCode::UNAUTHORIZED,
                        Json(serde_json::json!({
                            "error": "this runner requires its local API token"
                        })),
                    )
                        .into_response()
                }
            },
        )),
        None => router,
    }
}

fn base_router(state: Arc<AppState>) -> Router {
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
        // The same gateway, in the shape every existing tool already speaks.
        .route("/v1/messages", post(crate::messages::messages))
        .route("/v1/hooks/tool-request", post(hook_tool_request))
        .route("/v1/hooks/stop", post(hook_stop))
        .route("/v1/hooks/notification", post(hook_notification))
        .route("/v1/status", get(status))
        .route("/v1/events", get(events))
        .route("/v1/pair/offer", post(pair_offer))
        .route("/v1/pair/claim", post(pair_claim))
        .route("/v1/devices", get(list_devices))
        .route("/v1/agents", get(list_agents))
        .route("/v1/batch", get(batch_queue))
        .route("/v1/health", get(health))
        .layer(local_cors())
        .with_state(state)
}

/// Cross-origin access, restricted to the things that actually need it.
///
/// The production app is served *by this process*, so it is same-origin and
/// needs no CORS at all. React Native sends no `Origin` header, so it is not
/// subject to CORS either. That leaves exactly one legitimate cross-origin
/// caller — the Vite dev server — and the previous `permissive()` was handing
/// the same access to every website on the internet.
fn local_cors() -> CorsLayer {
    use axum::http::{HeaderName, Method};

    const DEV_ORIGINS: &[&str] = &[
        "http://localhost:5173",
        "http://127.0.0.1:5173",
        "http://localhost:4173",
        "http://127.0.0.1:4173",
    ];

    CorsLayer::new()
        .allow_methods([Method::GET, Method::POST, Method::OPTIONS])
        .allow_headers([
            HeaderName::from_static("authorization"),
            HeaderName::from_static("content-type"),
        ])
        .allow_origin(
            DEV_ORIGINS
                .iter()
                .filter_map(|origin| origin.parse().ok())
                .collect::<Vec<axum::http::HeaderValue>>(),
        )
}

// ---------------------------------------------------------------- errors

#[derive(Debug)]
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

    /// The status a client will see. For tests in sibling modules.
    #[cfg(test)]
    pub fn status(&self) -> StatusCode {
        self.status
    }

    /// For tests in sibling modules.
    #[cfg(test)]
    pub fn message(&self) -> &str {
        &self.message
    }

    /// For handlers in sibling modules. The fields stay private so a status and
    /// a message are always chosen together, rather than one being filled in
    /// and the other left at whatever `Default` would have given.
    pub fn new(status: StatusCode, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
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

impl From<ViewError> for ApiError {
    fn from(err: ViewError) -> Self {
        let status = match &err {
            ViewError::NotFound(_) => StatusCode::NOT_FOUND,
            ViewError::Store(_) => StatusCode::INTERNAL_SERVER_ERROR,
        };
        Self {
            status,
            message: err.to_string(),
        }
    }
}

impl From<forge_app::store::StoreError> for ApiError {
    fn from(err: forge_app::store::StoreError) -> Self {
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

/// `GET /v1/tasks` — every task, newest first.
async fn list_tasks(State(state): State<Arc<AppState>>) -> ApiResult<Vec<TaskView>> {
    Ok(Json(build_task_list(&state)?))
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
    Ok(Json(task_view(&Lookups::new(state.store.as_ref())?, task)))
}

/// `GET /v1/tasks/{id}` — the review screen's payload.
async fn task_detail(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> ApiResult<TaskDetail> {
    Ok(Json(build_task_detail(&state, &id)?))
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
    Ok(Json(task_view(&Lookups::new(state.store.as_ref())?, task)))
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
    Ok(Json(task_view(&Lookups::new(state.store.as_ref())?, task)))
}

/// `GET /v1/agents` — what this machine can start, and what it cannot.
///
/// `installed` is computed per request rather than cached: agents get installed
/// while the runner is up, and a stale "not installed" is a worse answer than a
/// PATH lookup.
async fn list_agents() -> Json<Vec<AgentView>> {
    Json(crate::views::build_agent_list())
}

// ---------------------------------------------------------------- read models
//
// The shapes moved to `forge-proto`. They are what four client implementations
// agree on, and keeping them here forced `commands::execute` — the path both
// transports share — to depend on this module for its reply types. Assembly
// stays here; the contract does not.

pub use forge_proto::views::{
    AgentView, ApprovalView, BatchQueueView, BudgetView, DashboardView, FleetView, PlanStepView,
    SessionDetail, SessionView, SpendBucket, TaskDetail, TaskView, TierSlice,
};

// Assembly lives in `crate::views`, which knows nothing about HTTP. These
// handlers are the thin part: a route, a body, a status code.
use crate::views::{
    Lookups, ViewError, approval_view, build_dashboard, build_fleet_view, build_session_detail,
    build_task_detail, build_task_list, task_view, view_of,
};

// ---------------------------------------------------------------- assembly

// ---------------------------------------------------------------- handlers

async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "ok": true }))
}

async fn list_sessions(State(state): State<Arc<AppState>>) -> ApiResult<Vec<SessionView>> {
    let lookups = Lookups::new(state.store.as_ref())?;
    let sessions = state.store.list_sessions()?;
    let views = sessions
        .iter()
        .map(|session| view_of(&state, &lookups, session))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Json(views))
}

/// What this runner can actually do right now.
///
/// Separate from `/v1/health`, which answers "is the process alive" and is what
/// a deploy script polls. This answers the question a person has: *why is
/// nothing happening*. The daemon is the only thing that can: it holds the
/// gateway, it knows which relay it dialled, and under launchd or systemd its
/// environment is not the one a terminal would see — so a check run from a
/// shell cannot read any of it.
#[derive(Debug, Serialize)]
pub struct RunnerStatus {
    /// `/v1/complete` and `/v1/messages` are open. Without it agent tasks
    /// cannot run at all.
    pub gateway: bool,
    /// Reachable from a phone, rather than from this machine's browser only.
    pub relay: Option<String>,
    pub machine_id: String,
    /// Agents installed on this machine, by id.
    pub agents: Vec<String>,
    /// Sessions this runner has ever recorded. Zero with hooks installed means
    /// nothing has reached it yet.
    pub sessions: i64,
    pub version: String,
}

async fn status(State(state): State<Arc<AppState>>) -> ApiResult<RunnerStatus> {
    // The same list `/v1/agents` serves, filtered. Deriving "installed" a
    // second way here is how two endpoints end up disagreeing about whether
    // Claude Code is on this machine.
    let agents = crate::views::build_agent_list()
        .into_iter()
        .filter(|agent| agent.installed)
        .map(|agent| agent.id)
        .collect();

    Ok(Json(RunnerStatus {
        gateway: state.gateway.is_some(),
        relay: state.relay.as_ref().map(|relay| relay.url.clone()),
        machine_id: state.machine_id.clone(),
        agents,
        sessions: state
            .store
            .list_sessions()
            .map(|s| s.len() as i64)
            .unwrap_or(0),
        version: env!("CARGO_PKG_VERSION").to_owned(),
    }))
}

async fn fleet(State(state): State<Arc<AppState>>) -> ApiResult<FleetView> {
    Ok(Json(build_fleet_view(&state)?))
}

async fn session_detail(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> ApiResult<SessionDetail> {
    Ok(Json(build_session_detail(&state, &id)?))
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
) -> ApiResult<Vec<forge_proto::types::UsageEvent>> {
    let range = TimeRange {
        since_ms: query.since_ms,
        until_ms: None,
    };
    Ok(Json(state.store.list_usage(&id, range)?))
}

async fn list_approvals(State(state): State<Arc<AppState>>) -> ApiResult<Vec<ApprovalView>> {
    let lookups = Lookups::new(state.store.as_ref())?;
    let approvals = state
        .store
        .list_pending_approvals()?
        .into_iter()
        .map(|approval| approval_view(&state, &lookups, approval))
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
    Ok(Json(approval_view(
        &state,
        &Lookups::new(state.store.as_ref())?,
        approval,
    )?))
}

async fn session_dashboard(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Query(query): Query<UsageQuery>,
) -> ApiResult<DashboardView> {
    Ok(Json(build_dashboard(&state, &id, query.since_ms)?))
}

/* --------------------------------------------------- session lifecycle */

#[derive(Debug, Deserialize)]
pub struct StartSessionBody {
    /// Absolute path to the repo the agent should work in.
    pub repo_path: String,
    /// `claude-code` (default) or `opencode`.
    #[serde(default)]
    pub agent: Option<forge_proto::types::Agent>,
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
    // The shared implementation, so this path and the relay's cannot diverge.
    Ok(Json(
        commands::start_session(&state, &body.repo_path, body.agent).await?,
    ))
}

/// `POST /v1/sessions/{id}/stop` — end a session and its pane.
async fn stop_session(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> ApiResult<SessionView> {
    Ok(Json(commands::stop_session(&state, &id).await?))
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
            // No relay configured. The offer is still minted — `forge-runner
            // pair` renders it, and it is the only way to see this machine's
            // public key and channel without reading the database — but a client
            // will refuse to claim it, because there is nowhere for the device to
            // connect. See `claimPairing` in packages/client-core/src/crypto.ts.
            url: String::new(),
            // The channel this runner *would* publish on, derived the one way it
            // is ever derived. This used to be `machine_id`, which is a different
            // string entirely: an offer minted before `--relay` was configured
            // named a channel the runner would never publish on, so a device that
            // somehow kept it would have listened to silence.
            channel: forge_proto::channel_for(state.identity.public_key().as_str()),
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
    pub kind: forge_proto::types::DeviceKind,
    /// The device's own public key.
    pub public_key: String,
}

/// `POST /v1/pair/claim` — redeem a code and register the device.
async fn pair_claim(
    State(state): State<Arc<AppState>>,
    Json(body): Json<PairClaimBody>,
) -> ApiResult<forge_proto::types::Device> {
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

    let device = forge_proto::types::Device {
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
) -> ApiResult<Vec<forge_proto::types::Device>> {
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
    pub risk: forge_proto::types::Risk,
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
            let repo = forge_proto::types::Repo {
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
        agent: forge_proto::types::Agent::ClaudeCode,
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
    let risk = forge_domain::risk::classify_with(&state.policy, &body.tool, &body.payload);

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
    pub tier_pin: Option<forge_proto::types::Tier>,
    #[serde(default)]
    pub verify_only: bool,
    #[serde(default)]
    pub deferrable: bool,
}

#[derive(Debug, Serialize)]
pub struct CompleteView {
    pub text: String,
    pub model: String,
    pub tier: forge_proto::types::Tier,
    pub usage: forge_proto::types::Usage,
    pub cost_usd: f64,
    /// `pre_gate` or `response_cache` when the call cost nothing.
    pub avoided: Option<forge_proto::types::Avoided>,
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
        budget: forge_domain::budget_view(budget),
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
