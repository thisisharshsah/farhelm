//! The control plane's HTTP API.
//!
//! Three kinds of caller, three kinds of credential, and they are never
//! interchangeable:
//!
//! | Caller | Presents | Extractor |
//! |---|---|---|
//! | A person, from a browser or a phone | an access token (`aud: api`) | [`Caller`] |
//! | A machine, enrolling for the first time | an enrolment key (`frg_…`) | inline, in [`enroll_runner`] |
//! | A machine, already enrolled | a runner token (`aud: api`, `role: runner`) | [`RunnerCaller`] |
//!
//! # The tenancy rule
//!
//! Every handler that touches organisation data goes through [`Caller::org`],
//! which is the *only* place a membership is checked. There is no handler that
//! takes an `org_id` from the request body — it comes from the token, and the
//! token was minted against a membership row. That is what keeps "multi-tenant"
//! from meaning "one forgotten `WHERE org_id = ?` away from a data leak".

use std::sync::Arc;

use axum::extract::{FromRequestParts, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, patch, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};

use forge_crypto::token::{Audience, Claims, Role};

use crate::billing::BillingError;
use crate::model::{
    Account, Device, EnrollmentKey, Org, Runner, RunnerView, Subscription, Workspace,
};
use crate::plan::{Limits, Plan, Resource, Usage, may_add};
use crate::secret;
use crate::store::{StoreError, new_id};
use crate::{CloudState, now_ms};

/// How long an access token is good for.
///
/// An hour is a deliberate compromise: role and plan changes are baked into the
/// token, so this is also the worst-case staleness of a demotion. Shorter would
/// mean a refresh round trip in the middle of a phone's approval flow, which is
/// the one moment latency is actually visible.
pub const ACCESS_TOKEN_TTL_MS: i64 = 60 * 60 * 1_000;

/// Refresh tokens last a month and rotate on every use, so a phone that sits in
/// a drawer for a fortnight still opens without a password.
pub const REFRESH_TOKEN_TTL_MS: i64 = 30 * 24 * 60 * 60 * 1_000;

pub fn router(state: Arc<CloudState>) -> Router {
    Router::new()
        // -- unauthenticated
        .route("/v1/auth/signup", post(signup))
        .route("/v1/auth/login", post(login))
        .route("/v1/auth/refresh", post(refresh))
        .route("/v1/auth/logout", post(logout))
        .route("/v1/auth/public-key", get(public_key))
        .route("/v1/billing/webhook", post(webhook))
        .route("/v1/health", get(health))
        // -- a person
        .route("/v1/workspace", get(workspace))
        .route("/v1/account/password", post(change_password))
        .route("/v1/members", get(list_members).post(add_member))
        .route("/v1/members/{account_id}", delete(remove_member))
        .route("/v1/devices", get(list_devices).post(register_device))
        .route("/v1/devices/{id}", delete(forget_device))
        .route("/v1/runners", get(list_runners))
        .route(
            "/v1/runners/{id}",
            patch(rename_runner).delete(forget_runner),
        )
        .route("/v1/runners/{id}/approve-key", post(approve_key))
        .route("/v1/channel-token", post(channel_token))
        .route(
            "/v1/enrollment-keys",
            get(list_enrollment_keys).post(create_enrollment_key),
        )
        .route("/v1/enrollment-keys/{id}", delete(revoke_enrollment_key))
        .route("/v1/billing", get(billing_state))
        .route("/v1/billing/checkout", post(checkout))
        .route("/v1/billing/portal", post(portal))
        // -- a machine
        .route("/v1/runners/enroll", post(enroll_runner))
        .route("/v1/runners/heartbeat", post(heartbeat))
        // The clients are served from the same origin in production (one
        // Cloudflare tunnel, one hostname), but a dev server and the React
        // Native app are both cross-origin.
        .layer(cors())
        .layer(axum::middleware::from_fn(record_change))
        .with_state(state)
}

/// One line per request that changes something.
///
/// Written after a device disappeared from a workspace and there was no way to
/// answer "what removed it" — not from the logs, not from the database, which
/// stores current state and no history. The absence was the problem: with three
/// clients, a CLI and two MCP connectors all able to call `DELETE`, "it must
/// have been one of those" is not an answer anybody can act on.
///
/// Reads are not logged. They are the overwhelming majority of traffic, they
/// change nothing, and burying the mutations among them is how a log stops
/// being read. `GET` is skipped for that reason rather than for volume.
///
/// Deliberately not an audit *table*. That is a different feature with its own
/// retention and access questions, and this answers the operational question —
/// what happened to my workspace, and roughly when — at a hundredth of the
/// cost.
async fn record_change(
    request: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let method = request.method().clone();
    if method == axum::http::Method::GET || method == axum::http::Method::HEAD {
        return next.run(request).await;
    }
    let path = request.uri().path().to_owned();
    let response = next.run(request).await;

    // Never the body, and never the `authorization` header: this file's whole
    // job is to hold credentials that must not end up somewhere they can be
    // read back. The status and the path are enough to reconstruct a sequence.
    eprintln!("{method} {path} -> {}", response.status().as_u16());
    response
}

fn cors() -> tower_http::cors::CorsLayer {
    use axum::http::{HeaderName, Method};
    tower_http::cors::CorsLayer::new()
        .allow_methods([
            Method::GET,
            Method::POST,
            Method::PATCH,
            Method::DELETE,
            Method::OPTIONS,
        ])
        .allow_headers([
            HeaderName::from_static("authorization"),
            HeaderName::from_static("content-type"),
        ])
        // Credentials ride in the `Authorization` header, never in a cookie, so
        // there is no ambient authority for another origin to borrow and no
        // reason to restrict the origin list.
        .allow_origin(tower_http::cors::Any)
}

/* -------------------------------------------------------------------- errors */

pub struct ApiError {
    status: StatusCode,
    message: String,
    /// Set when the refusal is a plan limit, so the client can offer the
    /// upgrade instead of just saying no.
    upgrade_to: Option<Plan>,
}

impl ApiError {
    fn new(status: StatusCode, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
            upgrade_to: None,
        }
    }

    fn unauthorized(message: impl Into<String>) -> Self {
        Self::new(StatusCode::UNAUTHORIZED, message)
    }

    fn forbidden(message: impl Into<String>) -> Self {
        Self::new(StatusCode::FORBIDDEN, message)
    }

    fn bad_request(message: impl Into<String>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, message)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(serde_json::json!({
                "error": self.message,
                "upgrade_to": self.upgrade_to,
            })),
        )
            .into_response()
    }
}

impl From<StoreError> for ApiError {
    fn from(err: StoreError) -> Self {
        let status = match &err {
            StoreError::Conflict(_) => StatusCode::CONFLICT,
            StoreError::NotFound(_) => StatusCode::NOT_FOUND,
            StoreError::Backend(_) => StatusCode::INTERNAL_SERVER_ERROR,
        };
        // A backend error's text is for the operator's log, not the user's
        // screen: it can carry column names and file paths.
        let message = match &err {
            StoreError::Backend(_) => "something went wrong on our side".to_owned(),
            other => other.to_string(),
        };
        if let StoreError::Backend(detail) = &err {
            eprintln!("store error: {detail}");
        }
        Self::new(status, message)
    }
}

impl From<crate::plan::LimitExceeded> for ApiError {
    fn from(err: crate::plan::LimitExceeded) -> Self {
        Self {
            status: StatusCode::PAYMENT_REQUIRED,
            upgrade_to: err.upgrade_to,
            message: err.to_string(),
        }
    }
}

impl From<BillingError> for ApiError {
    fn from(err: BillingError) -> Self {
        let status = match &err {
            BillingError::Disabled => StatusCode::NOT_IMPLEMENTED,
            BillingError::BadSignature => StatusCode::BAD_REQUEST,
            BillingError::NoSuchPrice(_) => StatusCode::BAD_REQUEST,
            BillingError::Upstream(_) => StatusCode::BAD_GATEWAY,
        };
        Self::new(status, err.to_string())
    }
}

type ApiResult<T> = Result<Json<T>, ApiError>;

/* ---------------------------------------------------------------- extractors */

/// An authenticated person, with the organisation and role their token names.
pub struct Caller {
    pub account_id: String,
    pub org_id: String,
    pub role: Role,
}

impl Caller {
    /// Assert this caller may do something needing `least`.
    fn requires(&self, least: Role) -> Result<(), ApiError> {
        if self.role >= least {
            return Ok(());
        }
        Err(ApiError::forbidden(format!(
            "this needs the {} role or higher; you are {}",
            least.as_str(),
            self.role.as_str()
        )))
    }
}

impl FromRequestParts<Arc<CloudState>> for Caller {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &Arc<CloudState>,
    ) -> Result<Self, Self::Rejection> {
        let claims = verify_bearer(parts, state, Audience::Api)?;
        if claims.role == Role::Runner {
            return Err(ApiError::forbidden(
                "this endpoint is for a signed-in person, not a runner",
            ));
        }
        Ok(Caller {
            account_id: claims.sub,
            org_id: claims.org,
            role: claims.role,
        })
    }
}

/// An enrolled machine, checking in.
pub struct RunnerCaller {
    pub runner_id: String,
    pub org_id: String,
}

impl FromRequestParts<Arc<CloudState>> for RunnerCaller {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &Arc<CloudState>,
    ) -> Result<Self, Self::Rejection> {
        let claims = verify_bearer(parts, state, Audience::Api)?;
        if claims.role != Role::Runner {
            return Err(ApiError::forbidden("this endpoint is for a runner"));
        }
        Ok(RunnerCaller {
            runner_id: claims.sub,
            org_id: claims.org,
        })
    }
}

fn bearer(parts: &Parts) -> Result<&str, ApiError> {
    parts
        .headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(str::trim)
        .filter(|token| !token.is_empty())
        .ok_or_else(|| ApiError::unauthorized("sign in to continue"))
}

fn verify_bearer(
    parts: &Parts,
    state: &CloudState,
    audience: Audience,
) -> Result<Claims, ApiError> {
    state
        .signer
        .verifier()
        .verify(bearer(parts)?, audience, now_ms())
        .map_err(|err| ApiError::unauthorized(err.to_string()))
}

/* ------------------------------------------------------------------ payloads */

#[derive(Debug, Deserialize)]
pub struct SignupBody {
    pub email: String,
    pub password: String,
    pub name: String,
    /// Defaults to "<name>'s workspace". A solo user should never have to think
    /// about the fact that there is an organisation underneath.
    #[serde(default)]
    pub org_name: Option<String>,
    #[serde(default)]
    pub device_label: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct LoginBody {
    pub email: String,
    pub password: String,
    #[serde(default)]
    pub device_label: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct AuthResponse {
    pub access_token: String,
    /// Expiry as unix ms, so a client can refresh *before* a request fails
    /// rather than discovering it mid-approval.
    pub access_expires_at: i64,
    pub refresh_token: String,
    pub workspace: Workspace,
}

#[derive(Debug, Deserialize)]
pub struct RefreshBody {
    pub refresh_token: String,
}

#[derive(Debug, Serialize)]
pub struct RefreshResponse {
    pub access_token: String,
    pub access_expires_at: i64,
    pub refresh_token: String,
}

/* ---------------------------------------------------------------------- auth */

async fn signup(
    State(state): State<Arc<CloudState>>,
    Json(body): Json<SignupBody>,
) -> ApiResult<AuthResponse> {
    let email = body.email.trim();
    if !looks_like_email(email) {
        return Err(ApiError::bad_request("that does not look like an email"));
    }
    let name = body.name.trim();
    if name.is_empty() {
        return Err(ApiError::bad_request("a name is required"));
    }

    let hash = secret::hash_password(&body.password)
        .map_err(|err| ApiError::bad_request(err.to_string()))?;
    let org_name = body
        .org_name
        .as_deref()
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| format!("{name}'s workspace"));

    let now = now_ms();
    let (account, org) = state
        .store
        .create_account(email, name, &hash, &org_name, now)?;

    issue(&state, account, org, Role::Owner, body.device_label, now).map(Json)
}

async fn login(
    State(state): State<Arc<CloudState>>,
    Json(body): Json<LoginBody>,
) -> ApiResult<AuthResponse> {
    let account = state
        .store
        .authenticate(&body.email, &body.password)?
        .ok_or_else(|| ApiError::unauthorized("that email and password do not match"))?;

    let now = now_ms();
    // The first organisation is the one a session lands in. Switching is a
    // future affordance; today an account has exactly one until somebody is
    // invited to a second.
    let (org, role) = state
        .store
        .memberships(&account.id)?
        .into_iter()
        .next()
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "this account has no workspace",
            )
        })?;

    state.store.touch_account(&account.id, now)?;
    issue(&state, account, org, role, body.device_label, now).map(Json)
}

/// Mint the pair of tokens a fresh session needs, and the workspace to render.
fn issue(
    state: &CloudState,
    account: Account,
    org: Org,
    role: Role,
    device_label: Option<String>,
    now: i64,
) -> Result<AuthResponse, ApiError> {
    let subscription = state.store.subscription(&org.id)?;
    let access_expires_at = now + ACCESS_TOKEN_TTL_MS;

    let access_token = state
        .signer
        .mint(&Claims {
            sub: account.id.clone(),
            aud: Audience::Api,
            org: org.id.clone(),
            role,
            chan: None,
            plan: Some(subscription.effective_plan().as_str().to_owned()),
            // No rate: this token never reaches the relay, and a limit that
            // applies nowhere is a limit somebody will later assume applies.
            rate: None,
            iat: now,
            exp: access_expires_at,
        })
        .map_err(|err| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, err.to_string()))?;

    let refresh_token = secret::random_secret();
    state.store.insert_refresh_token(
        &account.id,
        &refresh_token,
        device_label.as_deref().unwrap_or("a device"),
        now,
        now + REFRESH_TOKEN_TTL_MS,
    )?;

    let workspace = build_workspace(state, account, org, role, subscription, now)?;
    Ok(AuthResponse {
        access_token,
        access_expires_at,
        refresh_token,
        workspace,
    })
}

async fn refresh(
    State(state): State<Arc<CloudState>>,
    Json(body): Json<RefreshBody>,
) -> ApiResult<RefreshResponse> {
    let now = now_ms();
    let replacement = secret::random_secret();
    let account_id = state
        .store
        .rotate_refresh_token(
            &body.refresh_token,
            &replacement,
            now,
            now + REFRESH_TOKEN_TTL_MS,
        )?
        .ok_or_else(|| ApiError::unauthorized("that session has expired — sign in again"))?;

    let (org, role) = state
        .store
        .memberships(&account_id)?
        .into_iter()
        .next()
        .ok_or_else(|| ApiError::unauthorized("that account has no workspace"))?;
    let subscription = state.store.subscription(&org.id)?;
    let access_expires_at = now + ACCESS_TOKEN_TTL_MS;

    let access_token = state
        .signer
        .mint(&Claims {
            sub: account_id.clone(),
            aud: Audience::Api,
            org: org.id,
            role,
            chan: None,
            plan: Some(subscription.effective_plan().as_str().to_owned()),
            // No rate: this token never reaches the relay, and a limit that
            // applies nowhere is a limit somebody will later assume applies.
            rate: None,
            iat: now,
            exp: access_expires_at,
        })
        .map_err(|err| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, err.to_string()))?;

    state.store.touch_account(&account_id, now)?;
    Ok(Json(RefreshResponse {
        access_token,
        access_expires_at,
        refresh_token: replacement,
    }))
}

async fn logout(
    State(state): State<Arc<CloudState>>,
    Json(body): Json<RefreshBody>,
) -> Result<StatusCode, ApiError> {
    state
        .store
        .revoke_refresh_token(&body.refresh_token, now_ms())?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Debug, Deserialize)]
pub struct PasswordBody {
    pub current: String,
    pub next: String,
}

async fn change_password(
    caller: Caller,
    State(state): State<Arc<CloudState>>,
    Json(body): Json<PasswordBody>,
) -> Result<StatusCode, ApiError> {
    let account = state.store.account(&caller.account_id)?;
    state
        .store
        .authenticate(&account.email, &body.current)?
        .ok_or_else(|| ApiError::forbidden("that is not your current password"))?;

    let hash =
        secret::hash_password(&body.next).map_err(|err| ApiError::bad_request(err.to_string()))?;
    state.store.update_password(&caller.account_id, &hash)?;
    // Changing a password is what someone does *because* they think a session
    // was stolen. Leaving the other sessions alive would defeat the point.
    state
        .store
        .revoke_all_refresh_tokens(&caller.account_id, now_ms())?;
    Ok(StatusCode::NO_CONTENT)
}

/// `GET /v1/auth/public-key` — what `forge-relay --auth-key` needs.
///
/// Public by design: it is the *verifying* half. Serving it means an operator
/// configures the relay by pointing it at the control plane rather than by
/// copying a key between two machines and getting it wrong.
async fn public_key(State(state): State<Arc<CloudState>>) -> Json<serde_json::Value> {
    let verifier = state.signer.verifier();
    Json(serde_json::json!({
        "alg": "ES256",
        "kid": verifier.key_id(),
        "key": verifier.to_public_base64(),
    }))
}

async fn health(State(state): State<Arc<CloudState>>) -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "ok": true,
        "schema": state.store.schema_version().unwrap_or(-1),
        "billing": state.billing.is_enabled(),
        "relay": state.config.relay_url,
    }))
}

/* ----------------------------------------------------------------- workspace */

fn build_workspace(
    state: &CloudState,
    account: Account,
    org: Org,
    role: Role,
    subscription: Subscription,
    now: i64,
) -> Result<Workspace, ApiError> {
    let runners = state
        .store
        .runners(&org.id)?
        .into_iter()
        .map(|runner| RunnerView::of(runner, now))
        .collect();

    Ok(Workspace {
        limits: subscription.effective_plan().limits(),
        usage: state.store.usage(&org.id)?,
        devices: state.store.devices(&org.id)?,
        runners,
        relay_url: state.config.relay_url.clone(),
        account,
        org,
        role,
        subscription,
    })
}

async fn workspace(caller: Caller, State(state): State<Arc<CloudState>>) -> ApiResult<Workspace> {
    let now = now_ms();
    let account = state.store.account(&caller.account_id)?;
    let org = state
        .store
        .memberships(&caller.account_id)?
        .into_iter()
        .find(|(org, _)| org.id == caller.org_id)
        .map(|(org, _)| org)
        .ok_or_else(|| ApiError::forbidden("you are not a member of that workspace"))?;
    let subscription = state.store.subscription(&caller.org_id)?;

    Ok(Json(build_workspace(
        &state,
        account,
        org,
        caller.role,
        subscription,
        now,
    )?))
}

/* ------------------------------------------------------------------- members */

#[derive(Debug, Serialize)]
pub struct MemberView {
    #[serde(flatten)]
    pub account: Account,
    pub role: Role,
}

async fn list_members(
    caller: Caller,
    State(state): State<Arc<CloudState>>,
) -> ApiResult<Vec<MemberView>> {
    Ok(Json(
        state
            .store
            .members(&caller.org_id)?
            .into_iter()
            .map(|(account, role)| MemberView { account, role })
            .collect(),
    ))
}

#[derive(Debug, Deserialize)]
pub struct AddMemberBody {
    pub email: String,
    pub role: Role,
}

/// Add someone who already has an account.
///
/// No invitation emails: this deployment has no mail transport, and a feature
/// that silently does nothing is worse than one that is absent. The person signs
/// up, then an admin adds them by address.
async fn add_member(
    caller: Caller,
    State(state): State<Arc<CloudState>>,
    Json(body): Json<AddMemberBody>,
) -> ApiResult<MemberView> {
    caller.requires(Role::Admin)?;
    if body.role > caller.role {
        return Err(ApiError::forbidden(
            "you cannot grant a role above your own",
        ));
    }

    let account = state.store.account_by_email(&body.email)?.ok_or_else(|| {
        ApiError::new(
            StatusCode::NOT_FOUND,
            "nobody with that email has signed up yet — ask them to create an account first",
        )
    })?;

    // Already a member? Then this is a role change, not a seat.
    let existing = state.store.role_in(&caller.org_id, &account.id)?;
    if existing.is_none() {
        let subscription = state.store.subscription(&caller.org_id)?;
        may_add(
            subscription.effective_plan(),
            state.store.usage(&caller.org_id)?,
            Resource::Member,
        )?;
    }

    state
        .store
        .add_member(&caller.org_id, &account.id, body.role, now_ms())?;
    Ok(Json(MemberView {
        account,
        role: body.role,
    }))
}

async fn remove_member(
    caller: Caller,
    State(state): State<Arc<CloudState>>,
    Path(account_id): Path<String>,
) -> Result<StatusCode, ApiError> {
    // Leaving is always allowed; removing somebody else needs admin.
    if account_id != caller.account_id {
        caller.requires(Role::Admin)?;
    }
    state.store.remove_member(&caller.org_id, &account_id)?;
    Ok(StatusCode::NO_CONTENT)
}

/* ------------------------------------------------------------------- devices */

#[derive(Debug, Deserialize)]
pub struct RegisterDeviceBody {
    pub kind: forge_proto::types::DeviceKind,
    pub name: String,
    /// base64url X25519 public key, generated on the device. The secret half
    /// stays there — this server has never been able to decrypt a session and
    /// this endpoint does not change that.
    pub public_key: String,
}

async fn register_device(
    caller: Caller,
    State(state): State<Arc<CloudState>>,
    Json(body): Json<RegisterDeviceBody>,
) -> ApiResult<Device> {
    forge_crypto::PublicKey::parse(&body.public_key)
        .map_err(|err| ApiError::bad_request(err.to_string()))?;

    // Re-registering the same key is idempotent. A PWA that clears its storage
    // and re-derives the same identity should not consume a second seat.
    if let Some(existing) = state.store.device_by_key(&body.public_key)? {
        if existing.org_id != caller.org_id {
            return Err(ApiError::forbidden(
                "that device key is registered to another workspace",
            ));
        }
        state.store.touch_device(&existing.id, now_ms())?;
        return Ok(Json(existing));
    }

    let subscription = state.store.subscription(&caller.org_id)?;
    may_add(
        subscription.effective_plan(),
        state.store.usage(&caller.org_id)?,
        Resource::Device,
    )?;

    let now = now_ms();
    let device = Device {
        id: new_id("dev"),
        org_id: caller.org_id.clone(),
        account_id: caller.account_id.clone(),
        kind: body.kind,
        name: sane_name(&body.name, "A device"),
        public_key: body.public_key,
        created_at: now,
        last_seen_at: now,
    };
    state.store.insert_device(&device)?;
    Ok(Json(device))
}

async fn list_devices(
    caller: Caller,
    State(state): State<Arc<CloudState>>,
) -> ApiResult<Vec<Device>> {
    Ok(Json(state.store.devices(&caller.org_id)?))
}

async fn forget_device(
    caller: Caller,
    State(state): State<Arc<CloudState>>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    let device = state.store.device(&id)?;
    if device.org_id != caller.org_id {
        return Err(ApiError::forbidden("that device is not in this workspace"));
    }
    // Your own device is yours to remove; anyone else's needs admin.
    if device.account_id != caller.account_id {
        caller.requires(Role::Admin)?;
    }
    state.store.delete_device(&id)?;
    Ok(StatusCode::NO_CONTENT)
}

/* ------------------------------------------------------------------- runners */

async fn list_runners(
    caller: Caller,
    State(state): State<Arc<CloudState>>,
) -> ApiResult<Vec<RunnerView>> {
    let now = now_ms();
    Ok(Json(
        state
            .store
            .runners(&caller.org_id)?
            .into_iter()
            .map(|runner| RunnerView::of(runner, now))
            .collect(),
    ))
}

#[derive(Debug, Deserialize)]
pub struct RenameBody {
    pub name: String,
}

async fn rename_runner(
    caller: Caller,
    State(state): State<Arc<CloudState>>,
    Path(id): Path<String>,
    Json(body): Json<RenameBody>,
) -> ApiResult<RunnerView> {
    let runner = owned_runner(&state, &caller, &id)?;
    caller.requires(Role::Member)?;
    state.store.rename_runner(&runner.id, &body.name)?;
    Ok(Json(RunnerView::of(
        state.store.runner(&runner.id)?,
        now_ms(),
    )))
}

/// Accept a machine's new identity after it changed.
///
/// The one place trust-on-first-use is deliberately broken, and it needs an
/// admin: a runner whose key changed is either a reinstalled machine or
/// somebody standing in front of one, and this endpoint cannot tell which.
async fn approve_key(
    caller: Caller,
    State(state): State<Arc<CloudState>>,
    Path(id): Path<String>,
) -> ApiResult<RunnerView> {
    owned_runner(&state, &caller, &id)?;
    caller.requires(Role::Admin)?;
    Ok(Json(RunnerView::of(
        state.store.approve_pending_key(&id)?,
        now_ms(),
    )))
}

async fn forget_runner(
    caller: Caller,
    State(state): State<Arc<CloudState>>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    owned_runner(&state, &caller, &id)?;
    caller.requires(Role::Admin)?;
    state.store.delete_runner(&id)?;
    Ok(StatusCode::NO_CONTENT)
}

/// Fetch a runner and prove it belongs to the caller's organisation.
fn owned_runner(state: &CloudState, caller: &Caller, id: &str) -> Result<Runner, ApiError> {
    let runner = state.store.runner(id)?;
    if runner.org_id != caller.org_id {
        // A 404 rather than a 403: whether a runner id exists in *another*
        // workspace is not this caller's business.
        return Err(ApiError::new(
            StatusCode::NOT_FOUND,
            format!("runner {id} not found"),
        ));
    }
    Ok(runner)
}

/* ------------------------------------------------------------ runner enrolment */

#[derive(Debug, Deserialize)]
pub struct EnrollBody {
    pub name: String,
    /// The runner's long-term X25519 public key, from its keystore.
    pub public_key: String,
    pub version: String,
}

#[derive(Debug, Serialize)]
pub struct EnrollResponse {
    pub runner_id: String,
    pub org_id: String,
    pub channel: String,
    pub relay_url: String,
    /// An `aud: api`, `role: runner` token. The runner keeps this and heartbeats
    /// with it; the enrolment key is not needed again.
    pub runner_token: String,
    pub runner_token_expires_at: i64,
    /// Set when this machine's key differs from the pinned one. The runner keeps
    /// working on its old channel; a human has to approve the change.
    pub key_change_pending: bool,
}

/// `POST /v1/runners/enroll` — a machine joins the fleet by itself.
///
/// This is the whole of "no pairing codes": one enrolment key, pasted into a
/// config file once, and every machine started with it appears in the fleet.
///
/// The mitigation for that convenience is trust-on-first-use pinning. A stolen
/// enrolment key can register a *new* machine — which is visible in the fleet
/// and revocable — but cannot quietly take over an existing one, because a key
/// that does not match the pinned one is parked rather than applied.
async fn enroll_runner(
    State(state): State<Arc<CloudState>>,
    headers: axum::http::HeaderMap,
    Json(body): Json<EnrollBody>,
) -> ApiResult<EnrollResponse> {
    let key = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(str::trim)
        .ok_or_else(|| ApiError::unauthorized("an enrolment key is required"))?;

    let now = now_ms();
    let org_id = state
        .store
        .redeem_enrollment_key(key, now)?
        .ok_or_else(|| ApiError::unauthorized("that enrolment key is not valid"))?;

    forge_crypto::PublicKey::parse(&body.public_key)
        .map_err(|err| ApiError::bad_request(err.to_string()))?;

    // Already known by this exact key: a restart, not a new machine.
    let (runner, key_change_pending) = match state.store.runner_by_key(&body.public_key)? {
        Some(existing) if existing.org_id == org_id => {
            state.store.touch_runner(&existing.id, &body.version, now)?;
            (existing, false)
        }
        Some(_) => {
            return Err(ApiError::forbidden(
                "that machine is enrolled in another workspace",
            ));
        }
        None => {
            // A machine with this *name* already enrolled under a different
            // key is the reinstall case. Park the new key rather than
            // minting a second runner or silently repointing the channel.
            let by_name = state
                .store
                .runners(&org_id)?
                .into_iter()
                .find(|runner| runner.name.eq_ignore_ascii_case(body.name.trim()));

            match by_name {
                Some(existing) => {
                    state
                        .store
                        .set_pending_key(&existing.id, Some(&body.public_key))?;
                    state.store.touch_runner(&existing.id, &body.version, now)?;
                    (state.store.runner(&existing.id)?, true)
                }
                None => {
                    let subscription = state.store.subscription(&org_id)?;
                    may_add(
                        subscription.effective_plan(),
                        state.store.usage(&org_id)?,
                        Resource::Runner,
                    )?;

                    let runner = Runner {
                        id: new_id("run"),
                        org_id: org_id.clone(),
                        name: sane_name(&body.name, "A machine"),
                        channel: forge_proto::channel_for(&body.public_key),
                        public_key: body.public_key.clone(),
                        pending_public_key: None,
                        created_at: now,
                        last_seen_at: now,
                        version: body.version.clone(),
                    };
                    state.store.insert_runner(&runner)?;
                    (runner, false)
                }
            }
        }
    };

    let expires_at = now + forge_crypto::token::RUNNER_TOKEN_TTL_MS;
    let runner_token = mint_runner_token(&state, &runner, now, expires_at)?;

    Ok(Json(EnrollResponse {
        runner_id: runner.id,
        org_id: runner.org_id,
        channel: runner.channel,
        relay_url: state.config.relay_url.clone(),
        runner_token,
        runner_token_expires_at: expires_at,
        key_change_pending,
    }))
}

#[derive(Debug, Deserialize)]
pub struct HeartbeatBody {
    pub version: String,
}

#[derive(Debug, Serialize)]
pub struct HeartbeatResponse {
    pub channel: String,
    pub relay_url: String,
    /// Short-lived, `aud: relay`. This is what the runner presents to the relay,
    /// and re-asking for it every few minutes is what makes deleting a runner
    /// take effect without telling the relay anything.
    pub channel_token: String,
    pub channel_token_expires_at: i64,
    /// A fresh `aud: api` token, so a long-running daemon never has to be
    /// restarted to get one.
    pub runner_token: String,
    pub plan: Plan,
    pub limits: Limits,
    pub key_change_pending: bool,
    /// Every device in the organisation that this runner should seal events to.
    ///
    /// **This is how revocation reaches a runner.** Devices register their keys
    /// with the control plane, not with the runner, so the runner reconciles its
    /// local list to this one on every heartbeat: a phone removed in the web app
    /// stops receiving within one interval, without anything having to tell the
    /// runner directly.
    pub devices: Vec<DeviceKey>,
}

/// The public half of a device, and nothing else. Enough to encrypt to it.
#[derive(Debug, Serialize)]
pub struct DeviceKey {
    pub id: String,
    pub kind: forge_proto::types::DeviceKind,
    pub public_key: String,
}

async fn heartbeat(
    caller: RunnerCaller,
    State(state): State<Arc<CloudState>>,
    Json(body): Json<HeartbeatBody>,
) -> ApiResult<HeartbeatResponse> {
    let now = now_ms();
    // A runner deleted in the web app has no row, so this 404s and the daemon
    // stops. That is the revocation path.
    let runner = state.store.runner(&caller.runner_id)?;
    if runner.org_id != caller.org_id {
        return Err(ApiError::forbidden("that runner is not in this workspace"));
    }
    state.store.touch_runner(&runner.id, &body.version, now)?;

    let subscription = state.store.subscription(&runner.org_id)?;
    let plan = subscription.effective_plan();
    let channel_expires_at = now + forge_crypto::token::CHANNEL_TOKEN_TTL_MS;

    let channel_token = state
        .signer
        .mint(&Claims {
            sub: runner.id.clone(),
            aud: Audience::Relay,
            org: runner.org_id.clone(),
            role: Role::Runner,
            chan: Some(runner.channel.clone()),
            plan: Some(plan.as_str().to_owned()),
            rate: Some(plan.limits().relay_messages_per_minute),
            iat: now,
            exp: channel_expires_at,
        })
        .map_err(|err| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, err.to_string()))?;

    let runner_token = mint_runner_token(
        &state,
        &runner,
        now,
        now + forge_crypto::token::RUNNER_TOKEN_TTL_MS,
    )?;

    let devices = state
        .store
        .devices(&runner.org_id)?
        .into_iter()
        .map(|device| DeviceKey {
            id: device.id,
            kind: device.kind,
            public_key: device.public_key,
        })
        .collect();

    Ok(Json(HeartbeatResponse {
        channel: runner.channel,
        relay_url: state.config.relay_url.clone(),
        channel_token,
        channel_token_expires_at: channel_expires_at,
        runner_token,
        plan,
        limits: plan.limits(),
        key_change_pending: runner.pending_public_key.is_some(),
        devices,
    }))
}

fn mint_runner_token(
    state: &CloudState,
    runner: &Runner,
    now: i64,
    expires_at: i64,
) -> Result<String, ApiError> {
    state
        .signer
        .mint(&Claims {
            sub: runner.id.clone(),
            aud: Audience::Api,
            org: runner.org_id.clone(),
            role: Role::Runner,
            chan: Some(runner.channel.clone()),
            plan: None,
            rate: None,
            iat: now,
            exp: expires_at,
        })
        .map_err(|err| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, err.to_string()))
}

/* -------------------------------------------------------------- channel token */

#[derive(Debug, Deserialize)]
pub struct ChannelTokenBody {
    pub runner_id: String,
    /// The device asking. Its public key is what the runner will seal to.
    pub device_id: String,
}

#[derive(Debug, Serialize)]
pub struct ChannelTokenResponse {
    pub token: String,
    pub expires_at: i64,
    pub channel: String,
    pub relay_url: String,
    /// The runner's **pinned** key. This is the value that replaces the QR code:
    /// the device learns who to encrypt to from an authenticated API call rather
    /// than from a photograph.
    pub runner_public_key: String,
}

/// `POST /v1/channel-token` — a seat on a runner's channel, for fifteen minutes.
///
/// Refused for a runner with a pending key change: handing out a token then
/// would mean devices talking to a machine whose identity nobody has confirmed.
async fn channel_token(
    caller: Caller,
    State(state): State<Arc<CloudState>>,
    Json(body): Json<ChannelTokenBody>,
) -> ApiResult<ChannelTokenResponse> {
    let runner = owned_runner(&state, &caller, &body.runner_id)?;
    if runner.pending_public_key.is_some() {
        return Err(ApiError::forbidden(
            "this machine's identity changed — an admin has to confirm it before devices reconnect",
        ));
    }

    let device = state.store.device(&body.device_id)?;
    if device.org_id != caller.org_id || device.account_id != caller.account_id {
        return Err(ApiError::forbidden("that device is not yours"));
    }

    let now = now_ms();
    state.store.touch_device(&device.id, now)?;
    let subscription = state.store.subscription(&caller.org_id)?;
    let expires_at = now + forge_crypto::token::CHANNEL_TOKEN_TTL_MS;

    let token = state
        .signer
        .mint(&Claims {
            // The *device*, not the account: the relay's rate limit and the
            // runner's audit trail both want to name the surface that acted.
            sub: device.id.clone(),
            aud: Audience::Relay,
            org: caller.org_id.clone(),
            role: caller.role,
            chan: Some(runner.channel.clone()),
            plan: Some(subscription.effective_plan().as_str().to_owned()),
            rate: Some(
                subscription
                    .effective_plan()
                    .limits()
                    .relay_messages_per_minute,
            ),
            iat: now,
            exp: expires_at,
        })
        .map_err(|err| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, err.to_string()))?;

    Ok(Json(ChannelTokenResponse {
        token,
        expires_at,
        channel: runner.channel,
        relay_url: state.config.relay_url.clone(),
        runner_public_key: runner.public_key,
    }))
}

/* ------------------------------------------------------------ enrolment keys */

#[derive(Debug, Deserialize)]
pub struct CreateKeyBody {
    pub name: String,
}

#[derive(Debug, Serialize)]
pub struct CreatedKey {
    #[serde(flatten)]
    pub key: EnrollmentKey,
    /// Shown once. There is no endpoint that returns it again, because there is
    /// nowhere it is stored.
    pub token: String,
}

async fn create_enrollment_key(
    caller: Caller,
    State(state): State<Arc<CloudState>>,
    Json(body): Json<CreateKeyBody>,
) -> ApiResult<CreatedKey> {
    caller.requires(Role::Admin)?;

    let token = secret::new_enrollment_key();
    let key = EnrollmentKey {
        id: new_id("key"),
        org_id: caller.org_id.clone(),
        name: sane_name(&body.name, "Enrolment key"),
        prefix: secret::displayed_prefix(&token),
        created_at: now_ms(),
        created_by: caller.account_id.clone(),
        last_used_at: None,
        revoked_at: None,
    };
    state
        .store
        .insert_enrollment_key(&key, &secret::hash_token(&token))?;

    Ok(Json(CreatedKey { key, token }))
}

async fn list_enrollment_keys(
    caller: Caller,
    State(state): State<Arc<CloudState>>,
) -> ApiResult<Vec<EnrollmentKey>> {
    caller.requires(Role::Admin)?;
    Ok(Json(state.store.enrollment_keys(&caller.org_id)?))
}

async fn revoke_enrollment_key(
    caller: Caller,
    State(state): State<Arc<CloudState>>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    caller.requires(Role::Admin)?;
    state
        .store
        .revoke_enrollment_key(&caller.org_id, &id, now_ms())?;
    Ok(StatusCode::NO_CONTENT)
}

/* ------------------------------------------------------------------- billing */

#[derive(Debug, Serialize)]
pub struct PlanCard {
    pub plan: Plan,
    pub name: &'static str,
    pub monthly_cents: u32,
    pub limits: Limits,
    /// False for Free, and for any plan this deployment has no price for.
    pub purchasable: bool,
    pub current: bool,
}

#[derive(Debug, Serialize)]
pub struct BillingState {
    pub enabled: bool,
    pub subscription: Subscription,
    pub usage: Usage,
    pub plans: Vec<PlanCard>,
}

async fn billing_state(
    caller: Caller,
    State(state): State<Arc<CloudState>>,
) -> ApiResult<BillingState> {
    let subscription = state.store.subscription(&caller.org_id)?;
    let purchasable = state.billing.purchasable();
    let current = subscription.effective_plan();

    Ok(Json(BillingState {
        enabled: state.billing.is_enabled(),
        usage: state.store.usage(&caller.org_id)?,
        plans: Plan::ALL
            .iter()
            .map(|plan| PlanCard {
                plan: *plan,
                name: plan.display_name(),
                monthly_cents: plan.monthly_cents(),
                limits: plan.limits(),
                purchasable: purchasable.contains(plan),
                current: *plan == current,
            })
            .collect(),
        subscription,
    }))
}

#[derive(Debug, Deserialize)]
pub struct CheckoutBody {
    pub plan: Plan,
}

#[derive(Debug, Serialize)]
pub struct RedirectResponse {
    pub url: String,
}

async fn checkout(
    caller: Caller,
    State(state): State<Arc<CloudState>>,
    Json(body): Json<CheckoutBody>,
) -> ApiResult<RedirectResponse> {
    caller.requires(Role::Owner)?;
    let account = state.store.account(&caller.account_id)?;
    let subscription = state.store.subscription(&caller.org_id)?;

    let url = state
        .billing
        .checkout_url(
            body.plan,
            &caller.org_id,
            subscription.customer_id.as_deref(),
            &account.email,
            &format!("{}/#/billing?checkout=done", state.config.public_url),
            &format!("{}/#/billing?checkout=cancelled", state.config.public_url),
        )
        .await?;

    Ok(Json(RedirectResponse { url }))
}

async fn portal(
    caller: Caller,
    State(state): State<Arc<CloudState>>,
) -> ApiResult<RedirectResponse> {
    caller.requires(Role::Owner)?;
    let subscription = state.store.subscription(&caller.org_id)?;
    let customer = subscription
        .customer_id
        .ok_or_else(|| ApiError::bad_request("there is no subscription to manage yet"))?;

    let url = state
        .billing
        .portal_url(&customer, &format!("{}/#/billing", state.config.public_url))
        .await?;
    Ok(Json(RedirectResponse { url }))
}

/// `POST /v1/billing/webhook` — Stripe telling us what happened.
///
/// Takes the raw body, not `Json`: the signature covers the exact bytes, and
/// deserialising then re-serialising changes them.
async fn webhook(
    State(state): State<Arc<CloudState>>,
    headers: axum::http::HeaderMap,
    body: axum::body::Bytes,
) -> Result<StatusCode, ApiError> {
    let signature = headers
        .get("stripe-signature")
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default();

    let now = now_ms();
    let Some(change) = state.billing.handle_webhook(&body, signature, now)? else {
        // A signed event this system does not act on. 200 so Stripe stops
        // retrying it.
        return Ok(StatusCode::OK);
    };

    // Resolve the tenant: the org id if the event carried one, otherwise the
    // customer we already have on file. An event that matches neither is not
    // ours to act on.
    let org_id = match change.org_id.clone() {
        Some(org_id) => Some(org_id),
        None => match &change.customer_id {
            Some(customer) => state.store.org_by_customer(customer)?,
            None => None,
        },
    };
    let Some(org_id) = org_id else {
        eprintln!("billing webhook could not be matched to a workspace");
        return Ok(StatusCode::OK);
    };

    let mut subscription = state.store.subscription(&org_id)?;

    // `checkout.session.completed` arrives first and knows the customer but not
    // the price; the subscription event that follows knows the price. Letting
    // the first one write a plan would flap Pro→Team on every upgrade, so it
    // only fills in identifiers.
    let is_checkout = change.subscription_id.is_some() && change.current_period_end.is_none();
    if !is_checkout {
        subscription.plan = change.plan;
        subscription.status = change.status;
        subscription.current_period_end = change.current_period_end;
        subscription.cancel_at_period_end = change.cancel_at_period_end;
    }
    if let Some(customer) = change.customer_id {
        subscription.customer_id = Some(customer);
    }
    if let Some(id) = change.subscription_id {
        subscription.subscription_id = Some(id);
    }
    subscription.updated_at = now;

    state.store.save_subscription(&subscription)?;
    Ok(StatusCode::OK)
}

/* -------------------------------------------------------------------- helpers */

/// Names come from clients and end up on screens. Trim, cap, and fall back —
/// a device called `""` renders as a gap nobody can tap.
fn sane_name(name: &str, fallback: &str) -> String {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return fallback.to_owned();
    }
    trimmed.chars().take(64).collect()
}

/// Enough to catch a typo, not enough to reject a valid address.
///
/// Deliberately not a regex: every "correct" email regex on the internet rejects
/// addresses that RFC 5322 allows, and the real validation is that a person can
/// sign in with it.
fn looks_like_email(email: &str) -> bool {
    let mut parts = email.split('@');
    let (Some(local), Some(domain), None) = (parts.next(), parts.next(), parts.next()) else {
        return false;
    };
    !local.is_empty()
        && domain.contains('.')
        && !domain.starts_with('.')
        && !domain.ends_with('.')
        && !email.contains(char::is_whitespace)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn obvious_typos_are_caught_and_valid_addresses_are_not() {
        for good in [
            "harsh@example.com",
            "a.b+tag@sub.example.co.uk",
            "x@y.z",
            "weird!#$%@example.com",
        ] {
            assert!(looks_like_email(good), "rejected {good}");
        }
        for bad in [
            "",
            "harsh",
            "harsh@",
            "@example.com",
            "harsh@example",
            "harsh@.com",
            "harsh@example.",
            "two@at@example.com",
            "has space@example.com",
        ] {
            assert!(!looks_like_email(bad), "accepted {bad}");
        }
    }

    #[test]
    fn names_are_trimmed_capped_and_never_empty() {
        assert_eq!(sane_name("  mac-studio  ", "fallback"), "mac-studio");
        assert_eq!(sane_name("   ", "A machine"), "A machine");
        assert_eq!(sane_name(&"x".repeat(200), "f").len(), 64);
    }

    #[test]
    fn a_role_check_is_a_comparison_not_a_whitelist() {
        let caller = |role| Caller {
            account_id: "a".into(),
            org_id: "o".into(),
            role,
        };
        assert!(caller(Role::Owner).requires(Role::Admin).is_ok());
        assert!(caller(Role::Admin).requires(Role::Admin).is_ok());
        assert!(caller(Role::Member).requires(Role::Admin).is_err());
        assert!(caller(Role::Viewer).requires(Role::Member).is_err());
    }
}
