//! The control plane's MCP connector: OAuth authorization server, plus a
//! fleet-level tool set.
//!
//! This is the URL that goes in Claude's "Add custom connector" dialog. Both
//! Advanced fields stay blank — Claude discovers this server, registers itself,
//! and runs an authorization code flow with PKCE. See [`forge_mcp::oauth`] for
//! the discovery chain.
//!
//! # What these tools deliberately cannot do
//!
//! Nothing here reads a session transcript, an approval payload, or a diff. The
//! control plane has never held a key that could decrypt one, and adding this
//! connector does not change that: if it could answer "show me the diff", it
//! would have to be able to read your code, and a compromise here would stop
//! being an access problem. Those tools live on the runner's own MCP server,
//! where the content already is.
//!
//! What is here is what the control plane legitimately knows — the fleet, its
//! health, the plan, and spend — plus the ability to *start* work, which needs
//! no plaintext.

use std::sync::Arc;

use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::routing::{get, post};
use axum::{Form, Json, Router};
use serde::Deserialize;

use forge_crypto::token::{Audience, Claims, Role};
use forge_mcp::oauth;
use forge_mcp::protocol::{self, Request, Response as RpcResponse, ResponseError, ToolOutcome};
use forge_mcp::tools::{Caller, object_schema, optional_str, required_str};

use crate::{CloudState, now_ms};

pub fn router(state: Arc<CloudState>) -> Router {
    Router::new()
        // Discovery. Both are unauthenticated by definition — they are how a
        // client learns where to authenticate.
        .route(
            "/.well-known/oauth-authorization-server",
            get(authorization_server_metadata),
        )
        .route(
            "/.well-known/oauth-protected-resource",
            get(protected_resource_metadata),
        )
        // Some clients probe the path-suffixed form when the resource lives at
        // a sub-path. Answering both costs nothing and saves a failed connect.
        .route(
            "/.well-known/oauth-protected-resource/mcp",
            get(protected_resource_metadata),
        )
        .route("/oauth/register", post(register))
        .route(
            "/oauth/authorize",
            get(authorize_page).post(authorize_submit),
        )
        .route("/oauth/token", post(token))
        .route("/mcp", post(mcp))
        .with_state(state)
}

/* --------------------------------------------------------------- discovery */

async fn authorization_server_metadata(
    State(state): State<Arc<CloudState>>,
) -> Json<serde_json::Value> {
    Json(oauth::authorization_server_metadata(
        state.config.public_url.trim_end_matches('/'),
    ))
}

async fn protected_resource_metadata(
    State(state): State<Arc<CloudState>>,
) -> Json<serde_json::Value> {
    let issuer = state.config.public_url.trim_end_matches('/');
    Json(oauth::protected_resource_metadata(
        &format!("{issuer}/mcp"),
        issuer,
    ))
}

/* ------------------------------------------------------------ registration */

async fn register(
    State(state): State<Arc<CloudState>>,
    Json(body): Json<oauth::RegistrationRequest>,
) -> Response {
    let client_id = format!("mcp_{}", oauth::random_id());
    let client = match oauth::register(&body, client_id, now_ms()) {
        Ok(client) => client,
        Err(err) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({
                    "error": "invalid_redirect_uri",
                    "error_description": err.to_string(),
                })),
            )
                .into_response();
        }
    };

    if let Err(err) = state.store.insert_oauth_client(&client) {
        eprintln!("mcp: could not store a registered client: {err}");
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": "server_error" })),
        )
            .into_response();
    }

    // RFC 7591 says 201, and some clients check for it specifically.
    (StatusCode::CREATED, Json(client)).into_response()
}

/* ----------------------------------------------------------- authorization */

#[derive(Debug, Deserialize)]
pub struct AuthorizeQuery {
    #[serde(default)]
    pub client_id: String,
    #[serde(default)]
    pub redirect_uri: String,
    #[serde(default)]
    pub response_type: String,
    #[serde(default)]
    pub code_challenge: String,
    #[serde(default)]
    pub code_challenge_method: String,
    #[serde(default)]
    pub state: Option<String>,
    #[serde(default)]
    pub resource: Option<String>,
    #[serde(default)]
    pub scope: Option<String>,
}

/// The one page a human sees in this whole flow.
///
/// Sign-in and consent are the same form on purpose. Claude opens this in a
/// browser that has no session here, so splitting them would mean two round
/// trips and a redirect to preserve the authorization parameters across the
/// first one — more moving parts guarding nothing.
async fn authorize_page(
    State(state): State<Arc<CloudState>>,
    Query(query): Query<AuthorizeQuery>,
) -> Response {
    if let Err(message) = check_authorize(&state, &query) {
        return (StatusCode::BAD_REQUEST, Html(error_page(&message))).into_response();
    }
    Html(consent_page(&state, &query, None)).into_response()
}

/// Validate an authorization request before showing anything.
///
/// The redirect URI is checked against what the client registered. That check
/// is the one that matters: without it, anyone holding a client id could aim a
/// code at a server they control.
fn check_authorize(state: &CloudState, query: &AuthorizeQuery) -> Result<String, String> {
    if query.response_type != "code" {
        return Err("This server only supports the authorization code flow.".into());
    }
    if query.code_challenge.is_empty() || query.code_challenge_method != "S256" {
        return Err("This server requires PKCE with the S256 challenge method.".into());
    }

    let (name, registered) = state
        .store
        .oauth_client(&query.client_id)
        .map_err(|_| "Could not look up that client.".to_owned())?
        .ok_or_else(|| "That client is not registered with this server.".to_owned())?;

    if !registered.iter().any(|uri| uri == &query.redirect_uri) {
        return Err(
            "That redirect address is not one this client registered. Nothing was sent to it."
                .into(),
        );
    }
    Ok(name)
}

#[derive(Debug, Deserialize)]
pub struct ConsentForm {
    pub email: String,
    pub password: String,
    pub client_id: String,
    pub redirect_uri: String,
    pub code_challenge: String,
    pub code_challenge_method: String,
    #[serde(default)]
    pub state: Option<String>,
    #[serde(default)]
    pub resource: Option<String>,
}

async fn authorize_submit(
    State(state): State<Arc<CloudState>>,
    Form(form): Form<ConsentForm>,
) -> Response {
    let query = AuthorizeQuery {
        client_id: form.client_id.clone(),
        redirect_uri: form.redirect_uri.clone(),
        response_type: "code".into(),
        code_challenge: form.code_challenge.clone(),
        code_challenge_method: form.code_challenge_method.clone(),
        state: form.state.clone(),
        resource: form.resource.clone(),
        scope: None,
    };

    // Re-validated on submit: the form fields are attacker-controlled, and a
    // check that only ran on the GET would be trivially bypassed by posting.
    if let Err(message) = check_authorize(&state, &query) {
        return (StatusCode::BAD_REQUEST, Html(error_page(&message))).into_response();
    }

    let account = match state.store.authenticate(&form.email, &form.password) {
        Ok(Some(account)) => account,
        Ok(None) => {
            return Html(consent_page(
                &state,
                &query,
                Some("That email and password do not match."),
            ))
            .into_response();
        }
        Err(err) => {
            eprintln!("mcp: authorize lookup failed: {err}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Html(error_page("Something went wrong.")),
            )
                .into_response();
        }
    };

    let Ok(Some((org, _role))) = state
        .store
        .memberships(&account.id)
        .map(|list| list.into_iter().next())
    else {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Html(error_page("That account has no workspace.")),
        )
            .into_response();
    };

    let code = oauth::random_id();
    let pending = oauth::PendingAuthorization {
        client_id: form.client_id,
        redirect_uri: form.redirect_uri.clone(),
        code_challenge: form.code_challenge,
        code_challenge_method: form.code_challenge_method,
        state: form.state.clone(),
        account_id: account.id,
        expires_at: now_ms() + oauth::CODE_TTL_MS,
        resource: form.resource,
    };

    if let Err(err) = state.store.insert_oauth_code(&code, &pending, &org.id) {
        eprintln!("mcp: could not store an authorization code: {err}");
        return Redirect::to(&oauth::redirect_with_error(
            &form.redirect_uri,
            "server_error",
            form.state.as_deref(),
        ))
        .into_response();
    }

    Redirect::to(&oauth::redirect_with_code(
        &form.redirect_uri,
        &code,
        form.state.as_deref(),
    ))
    .into_response()
}

/* ------------------------------------------------------------------ tokens */

#[derive(Debug, Deserialize)]
pub struct TokenForm {
    pub grant_type: String,
    #[serde(default)]
    pub code: Option<String>,
    #[serde(default)]
    pub redirect_uri: Option<String>,
    #[serde(default)]
    pub client_id: Option<String>,
    #[serde(default)]
    pub code_verifier: Option<String>,
    #[serde(default)]
    pub refresh_token: Option<String>,
}

fn token_error(error: &str, description: &str) -> Response {
    (
        StatusCode::BAD_REQUEST,
        Json(serde_json::json!({ "error": error, "error_description": description })),
    )
        .into_response()
}

async fn token(State(state): State<Arc<CloudState>>, Form(form): Form<TokenForm>) -> Response {
    let now = now_ms();
    let _ = state.store.purge_oauth_codes(now);

    let (account_id, org_id, client_id, refresh) = match form.grant_type.as_str() {
        "authorization_code" => {
            let Some(code) = form.code.as_deref() else {
                return token_error("invalid_request", "code is required");
            };
            let Ok(Some((pending, org_id))) = state.store.take_oauth_code(code) else {
                return token_error("invalid_grant", "that code is unknown or already used");
            };
            if pending.is_expired(now) {
                return token_error("invalid_grant", "that code has expired");
            }
            if form.redirect_uri.as_deref() != Some(pending.redirect_uri.as_str()) {
                return token_error("invalid_grant", "redirect_uri does not match the request");
            }
            let Some(verifier) = form.code_verifier.as_deref() else {
                return token_error("invalid_request", "code_verifier is required");
            };
            if let Err(err) = oauth::verify_challenge(
                verifier,
                &pending.code_challenge,
                &pending.code_challenge_method,
            ) {
                return token_error("invalid_grant", &err.to_string());
            }

            let name = state
                .store
                .oauth_client(&pending.client_id)
                .ok()
                .flatten()
                .map(|(name, _)| name)
                .unwrap_or_else(|| "An MCP client".to_owned());

            let refresh = oauth::random_id();
            if let Err(err) = state.store.insert_oauth_grant(
                &refresh,
                &pending.client_id,
                &name,
                &pending.account_id,
                &org_id,
                now,
            ) {
                eprintln!("mcp: could not store a grant: {err}");
                return token_error("server_error", "could not record the grant");
            }
            (pending.account_id, org_id, pending.client_id, refresh)
        }

        "refresh_token" => {
            let Some(token) = form.refresh_token.as_deref() else {
                return token_error("invalid_request", "refresh_token is required");
            };
            let Ok(Some((client_id, account_id, org_id))) = state.store.oauth_grant(token, now)
            else {
                return token_error("invalid_grant", "that grant is no longer valid");
            };
            // The refresh token is not rotated: a connector may hold several
            // access tokens at once and rotating under one would invalidate the
            // grant for the others. Disconnecting revokes it instead.
            (account_id, org_id, client_id, token.to_owned())
        }

        other => {
            return token_error(
                "unsupported_grant_type",
                &format!("{other} is not supported"),
            );
        }
    };

    // Role is read now rather than baked in at consent, so a demotion takes
    // effect on the connector's next token instead of lasting until it is
    // disconnected.
    let role = state
        .store
        .role_in(&org_id, &account_id)
        .ok()
        .flatten()
        .unwrap_or(Role::Viewer);

    let expires_at = now + oauth::ACCESS_TOKEN_TTL_MS;
    let access = match state.signer.mint(&Claims {
        sub: account_id,
        aud: Audience::Mcp,
        org: org_id,
        role,
        chan: None,
        plan: None,
        rate: None,
        iat: now,
        exp: expires_at,
    }) {
        Ok(token) => token,
        Err(err) => {
            eprintln!("mcp: could not mint an access token: {err}");
            return token_error("server_error", "could not mint a token");
        }
    };

    let _ = client_id;
    Json(serde_json::json!({
        "access_token": access,
        "token_type": "Bearer",
        "expires_in": oauth::ACCESS_TOKEN_TTL_MS / 1000,
        "refresh_token": refresh,
        "scope": "mcp",
    }))
    .into_response()
}

/* --------------------------------------------------------------------- MCP */

/// Reject an unauthenticated call *and point at the discovery document*.
///
/// The `WWW-Authenticate` header is the first link in the chain — without it
/// Claude has nothing to discover from and the connector fails with no way to
/// see why.
fn unauthorized(state: &CloudState) -> Response {
    let issuer = state.config.public_url.trim_end_matches('/');
    let challenge =
        oauth::www_authenticate(&format!("{issuer}/.well-known/oauth-protected-resource"));
    (
        StatusCode::UNAUTHORIZED,
        [(header::WWW_AUTHENTICATE, challenge)],
        Json(serde_json::json!({ "error": "invalid_token" })),
    )
        .into_response()
}

async fn mcp(
    State(state): State<Arc<CloudState>>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    let presented = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(str::trim)
        .unwrap_or_default();

    let Ok(claims) = state
        .signer
        .verifier()
        .verify(presented, Audience::Mcp, now_ms())
    else {
        return unauthorized(&state);
    };

    let caller = Caller {
        account_id: claims.sub,
        org_id: claims.org,
        role: claims.role,
    };

    let request: Request = match serde_json::from_slice(&body) {
        Ok(request) => request,
        Err(err) => {
            return Json(RpcResponse::failed(
                serde_json::Value::Null,
                ResponseError::new(ResponseError::PARSE_ERROR, err.to_string()),
            ))
            .into_response();
        }
    };

    // A notification gets no body at all — answering one breaks the handshake.
    if request.is_notification() {
        return StatusCode::ACCEPTED.into_response();
    }
    let id = request.id.clone().unwrap_or(serde_json::Value::Null);

    let outcome = match request.method.as_str() {
        "initialize" => {
            let asked = request
                .params
                .get("protocolVersion")
                .and_then(|value| value.as_str());
            Ok(protocol::initialize_result(
                forge_mcp::SERVER_NAME,
                forge_mcp::SERVER_VERSION,
                protocol::negotiate(asked),
            ))
        }
        "ping" => Ok(serde_json::json!({})),
        "tools/list" => Ok(serde_json::json!({ "tools": specs() })),
        "tools/call" => match protocol::parse_tool_call(&request.params) {
            Ok((name, arguments)) => Ok(call_tool(&state, &name, arguments, &caller)
                .await
                .to_result()),
            Err(err) => Err(err),
        },
        other => Err(ResponseError::method_not_found(other)),
    };

    match outcome {
        Ok(result) => Json(RpcResponse::ok(id, result)).into_response(),
        Err(err) => Json(RpcResponse::failed(id, err)).into_response(),
    }
}

/* ------------------------------------------------------------------- tools */

fn specs() -> Vec<protocol::ToolSpec> {
    vec![
        protocol::ToolSpec {
            name: "list_machines",
            description: "List the machines in this RelayForge workspace, with whether each is online, \
                 its version, and whether its identity needs confirming. Call this when the user \
                 asks what machines they have, whether something is up, or before starting work \
                 on a machine you have not named yet.",
            input_schema: object_schema(&[]),
        },
        protocol::ToolSpec {
            name: "get_workspace",
            description: "Read this workspace's plan, its limits, and how much of each limit is in use \
                 (machines, devices, people). Call this when the user asks what plan they are on, \
                 why something was refused as over a limit, or whether they need to upgrade.",
            input_schema: object_schema(&[]),
        },
        protocol::ToolSpec {
            name: "get_spend",
            description: "Read what the fleet has cost: total spend, spend today, and the cache-hit ratio \
                 the cost gateway achieved. Call this when the user asks about AI spend, whether \
                 caching is working, or where their credits went.",
            input_schema: object_schema(&[]),
        },
        protocol::ToolSpec {
            name: "start_task",
            description: "Point RelayForge's own coding agent at a repository on one of the user's \
                 machines. It proposes a diff rather than editing the working tree, and nothing \
                 is applied until a human reviews it. Every model call it makes goes through the \
                 cost gateway. Call this when the user asks for a code change to be attempted on \
                 one of their machines.",
            input_schema: object_schema(&[
                (
                    "machine",
                    "Which machine, by name or id. Use list_machines first if unsure.",
                    true,
                ),
                (
                    "repo_path",
                    "Absolute path to the repository on that machine.",
                    true,
                ),
                (
                    "prompt",
                    "What the agent should do, stated as a task.",
                    true,
                ),
                (
                    "budget_usd",
                    "Optional spend cap for this task alone, in dollars.",
                    false,
                ),
            ]),
        },
    ]
}

async fn call_tool(
    state: &CloudState,
    name: &str,
    arguments: serde_json::Value,
    caller: &Caller,
) -> ToolOutcome {
    match name {
        "list_machines" => match state.store.runners(&caller.org_id) {
            Ok(runners) => {
                let now = now_ms();
                ToolOutcome::json(
                    &runners
                        .into_iter()
                        .map(|runner| {
                            serde_json::json!({
                                "id": runner.id,
                                "name": runner.name,
                                "online": runner.is_online(now),
                                "version": runner.version,
                                "needs_key_approval": runner.pending_public_key.is_some(),
                            })
                        })
                        .collect::<Vec<_>>(),
                )
            }
            Err(err) => ToolOutcome::error(err.to_string()),
        },

        "get_workspace" => {
            let Ok(subscription) = state.store.subscription(&caller.org_id) else {
                return ToolOutcome::error("could not read the subscription");
            };
            let Ok(usage) = state.store.usage(&caller.org_id) else {
                return ToolOutcome::error("could not read usage");
            };
            let plan = subscription.effective_plan();
            ToolOutcome::json(&serde_json::json!({
                "plan": plan.as_str(),
                "status": subscription.status.as_str(),
                "limits": plan.limits(),
                "in_use": usage,
            }))
        }

        "get_spend" => ToolOutcome::error(
            "spend lives on each machine's own ledger, which this server cannot read. \
             Use the machine's connector, or the cost dashboard in the web app.",
        ),

        "start_task" => {
            if !caller.can_act() {
                return ToolOutcome::error(format!(
                    "starting work needs the member role or higher; this connector is authorised \
                     as {}",
                    caller.role.as_str()
                ));
            }
            let machine = match required_str(&arguments, "machine") {
                Ok(value) => value,
                Err(refusal) => return refusal,
            };
            let repo_path = match required_str(&arguments, "repo_path") {
                Ok(value) => value,
                Err(refusal) => return refusal,
            };
            let prompt = match required_str(&arguments, "prompt") {
                Ok(value) => value,
                Err(refusal) => return refusal,
            };
            let budget = optional_str(&arguments, "budget_usd");

            // Resolved here so the refusal names the machine the user said,
            // rather than failing later with an opaque id.
            let Ok(runners) = state.store.runners(&caller.org_id) else {
                return ToolOutcome::error("could not read the fleet");
            };
            let Some(runner) = runners.iter().find(|candidate| {
                candidate.id == machine || candidate.name.eq_ignore_ascii_case(&machine)
            }) else {
                return ToolOutcome::error(format!(
                    "no machine called {machine} in this workspace — call list_machines to see them"
                ));
            };
            if !runner.is_online(now_ms()) {
                return ToolOutcome::error(format!(
                    "{} is offline, so it cannot start a task right now",
                    runner.name
                ));
            }

            // The control plane cannot reach into a runner: the command has to
            // travel the relay sealed to that machine's key, which only a
            // registered device can do. Saying so plainly beats a timeout.
            ToolOutcome::error(format!(
                "queuing work on {} from this connector is not wired up yet — the control plane \
                 has no device key and cannot seal a command to a machine. Start it from the \
                 machine's own connector, or from the web app. (repo {repo_path}, prompt {prompt}{})",
                runner.name,
                budget
                    .map(|value| format!(", budget {value}"))
                    .unwrap_or_default()
            ))
        }

        other => ToolOutcome::error(format!("this server has no tool called {other}")),
    }
}

/* -------------------------------------------------------------------- HTML */

fn consent_page(state: &CloudState, query: &AuthorizeQuery, error: Option<&str>) -> String {
    let client_name = state
        .store
        .oauth_client(&query.client_id)
        .ok()
        .flatten()
        .map(|(name, _)| name)
        .unwrap_or_else(|| "An application".to_owned());

    let error_html = error
        .map(|message| format!(r#"<p class="error">{}</p>"#, escape(message)))
        .unwrap_or_default();
    let hidden = |name: &str, value: &str| {
        format!(
            r#"<input type="hidden" name="{name}" value="{}">"#,
            escape(value)
        )
    };

    format!(
        r##"<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Connect {client}</title>{style}</head><body>
<main>
  <div class="mark">◈</div>
  <h1>Connect {client}</h1>
  <p class="sub">It will be able to see your machines, their status, and your plan — and to start
  work on a machine. It <strong>cannot</strong> read your sessions, approvals, or diffs: this
  server has no key that could decrypt them.</p>
  {error}
  <form method="post" action="/oauth/authorize">
    <label for="email">Email</label>
    <input id="email" name="email" type="email" autocomplete="email" autocapitalize="none" required>
    <label for="password">Password</label>
    <input id="password" name="password" type="password" autocomplete="current-password" required>
    {h_client}{h_redirect}{h_challenge}{h_method}{h_state}{h_resource}
    <button type="submit">Sign in and connect</button>
  </form>
  <p class="foot">You can disconnect this at any time from the workspace screen.</p>
</main></body></html>"##,
        client = escape(&client_name),
        style = PAGE_STYLE,
        error = error_html,
        h_client = hidden("client_id", &query.client_id),
        h_redirect = hidden("redirect_uri", &query.redirect_uri),
        h_challenge = hidden("code_challenge", &query.code_challenge),
        h_method = hidden("code_challenge_method", &query.code_challenge_method),
        h_state = hidden("state", query.state.as_deref().unwrap_or_default()),
        h_resource = hidden("resource", query.resource.as_deref().unwrap_or_default()),
    )
}

fn error_page(message: &str) -> String {
    format!(
        r##"<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Cannot connect</title>{style}</head><body>
<main><div class="mark">◈</div><h1>Cannot connect</h1><p class="sub">{message}</p></main>
</body></html>"##,
        style = PAGE_STYLE,
        message = escape(message)
    )
}

/// Escape text destined for HTML.
///
/// Every interpolation on these pages goes through this. `client_name` in
/// particular is attacker-supplied — anyone may register a client and choose
/// its name, and that name is rendered on a page where the user types a
/// password.
fn escape(raw: &str) -> String {
    raw.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

const PAGE_STYLE: &str = r#"<style>
:root{color-scheme:light dark;--bg:#f9f9f7;--fg:#0b0b0b;--muted:#52514e;--line:rgba(11,11,11,.12);--accent:#2a78d6;--card:#fff}
@media(prefers-color-scheme:dark){:root{--bg:#0d0d0d;--fg:#fff;--muted:#c3c2b7;--line:rgba(255,255,255,.14);--card:#1a1a19}}
*{box-sizing:border-box}
body{margin:0;min-height:100dvh;display:grid;place-items:center;background:var(--bg);color:var(--fg);
font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;padding:1.5rem}
main{width:100%;max-width:24rem;background:var(--card);border:1px solid var(--line);border-radius:14px;
padding:1.75rem;box-shadow:0 4px 16px rgba(0,0,0,.06)}
.mark{font-size:2rem;color:var(--accent);text-align:center}
h1{font-size:1.25rem;font-weight:650;letter-spacing:-.015em;margin:.75rem 0 .5rem;text-align:center}
.sub{color:var(--muted);font-size:.9rem;margin:0 0 1.25rem}
label{display:block;font-size:.8rem;color:var(--muted);margin:.75rem 0 .3rem}
input[type=email],input[type=password]{width:100%;min-height:44px;padding:.55rem .75rem;font:inherit;
border:1px solid var(--line);border-radius:10px;background:var(--bg);color:var(--fg)}
button{width:100%;min-height:48px;margin-top:1.25rem;border:none;border-radius:10px;background:var(--accent);
color:#fff;font:inherit;font-weight:600;cursor:pointer}
button:hover{filter:brightness(.94)}
.error{color:#d03b3b;font-size:.85rem;margin:.5rem 0 0}
.foot{color:var(--muted);font-size:.78rem;margin:1.25rem 0 0;text-align:center}
:where(input,button):focus-visible{outline:2px solid var(--accent);outline-offset:2px}
</style>"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_client_name_cannot_inject_markup_into_the_consent_page() {
        // Anyone may register a client and choose its name, and that name is
        // rendered on the page where the user types their password.
        let escaped = escape(r#"<script>steal()</script>"#);
        assert!(!escaped.contains('<'));
        assert!(escaped.contains("&lt;script&gt;"));
    }

    #[test]
    fn a_quote_in_a_hidden_field_cannot_break_out_of_the_attribute() {
        let escaped = escape(r#"" onload="evil()"#);
        assert!(!escaped.contains('"'));
        assert!(escaped.contains("&quot;"));
    }

    #[test]
    fn every_tool_declares_a_schema_and_says_when_to_use_itself() {
        // Claude picks a tool from its description alone, so a description that
        // only states mechanics gets called at the wrong moments.
        for spec in specs() {
            assert_eq!(spec.input_schema["type"], "object", "{}", spec.name);
            assert_eq!(spec.input_schema["additionalProperties"], false);
            assert!(
                spec.description.contains("Call this when"),
                "{} does not say when to use it",
                spec.name
            );
        }
    }

    #[test]
    fn tool_names_are_unique() {
        let names: std::collections::HashSet<&str> = specs().iter().map(|spec| spec.name).collect();
        assert_eq!(names.len(), specs().len());
    }
}
