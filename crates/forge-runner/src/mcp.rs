//! This machine as a remote MCP server.
//!
//! The second half of the connector story. The control plane's connector knows
//! the *fleet*; this one knows what is actually happening on one machine —
//! sessions, pending approvals, proposed diffs, what it all cost — because the
//! data is already here in plaintext. Nothing new decrypts anything: the
//! alternative was giving the control plane a device key, which would have
//! ended the property that compromising it costs you access rather than
//! content.
//!
//! # Resource server, not authorization server
//!
//! There is exactly one authorization server — the control plane — so a person
//! signs in once, with the account they already have. This server publishes
//! metadata pointing at it and verifies the tokens it mints, the same way
//! `forge-relay` verifies channel tokens. It holds no client registry, no
//! passwords, and no signing key.
//!
//! # Two checks, not one
//!
//! A valid token is not sufficient. It must also carry **this machine's
//! organisation** — otherwise any RelayForge account anywhere could point a
//! connector at this URL and read someone else's sessions. [`Gate::admit`] is
//! where both checks live.
//!
//! # What a connector may not do
//!
//! Clear a destructive command. `forge_domain`'s rule bars it at the executor,
//! so it holds on this path as it does on every other — but it is worth saying
//! here too, because this is the surface where it would be most tempting to
//! make an exception. An agent that could approve its own `rm -rf` is an agent
//! supervising itself.

use std::sync::Arc;

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};

use forge_crypto::token::{Audience, TokenVerifier};
use forge_mcp::oauth;
use forge_mcp::protocol::{self, Request, Response as RpcResponse, ResponseError, ToolOutcome};
use forge_mcp::tools::{Caller, object_schema, optional_str, required_str};
use forge_proto::types::{DecidedVia, Decision};

use crate::state::AppState;

/// Everything this server needs to decide whether a caller is allowed in.
#[derive(Clone)]
pub struct Gate {
    /// The control plane's verifying half. Fetched at startup, exactly as the
    /// relay fetches it — this process cannot mint a token.
    pub verifier: TokenVerifier,
    /// The organisation this machine belongs to. A token for any other is
    /// refused even though it is perfectly valid.
    pub org_id: String,
    /// This server's own public URL, for the metadata document.
    pub public_url: String,
    /// Where the authorization server lives.
    pub issuer: String,
}

impl Gate {
    fn admit(&self, presented: &str) -> Option<Caller> {
        let claims = self
            .verifier
            .verify(presented, Audience::Mcp, forge_app::time::now_ms())
            .ok()?;

        // The check a resource server is most likely to forget. Without it,
        // every RelayForge account on the internet can read this machine.
        if claims.org != self.org_id {
            eprintln!(
                "mcp: refused a token for {} — this machine belongs to {}",
                claims.org, self.org_id
            );
            return None;
        }

        Some(Caller {
            account_id: claims.sub,
            org_id: claims.org,
            role: claims.role,
        })
    }
}

pub struct McpState {
    pub app: Arc<AppState>,
    pub gate: Gate,
}

pub fn router(state: Arc<McpState>) -> Router {
    Router::new()
        .route(
            "/.well-known/oauth-protected-resource",
            get(protected_resource_metadata),
        )
        .route(
            "/.well-known/oauth-protected-resource/mcp",
            get(protected_resource_metadata),
        )
        .route("/mcp", post(mcp))
        .with_state(state)
}

async fn protected_resource_metadata(
    State(state): State<Arc<McpState>>,
) -> Json<serde_json::Value> {
    Json(oauth::protected_resource_metadata(
        &format!("{}/mcp", state.gate.public_url.trim_end_matches('/')),
        state.gate.issuer.trim_end_matches('/'),
    ))
}

async fn mcp(
    State(state): State<Arc<McpState>>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Response {
    let presented = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(str::trim)
        .unwrap_or_default();

    let Some(caller) = state.gate.admit(presented) else {
        let challenge = oauth::www_authenticate(&format!(
            "{}/.well-known/oauth-protected-resource",
            state.gate.public_url.trim_end_matches('/')
        ));
        return (
            StatusCode::UNAUTHORIZED,
            [(header::WWW_AUTHENTICATE, challenge)],
            Json(serde_json::json!({ "error": "invalid_token" })),
        )
            .into_response();
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

    if request.is_notification() {
        return StatusCode::ACCEPTED.into_response();
    }
    let id = request.id.clone().unwrap_or(serde_json::Value::Null);

    let outcome = match request.method.as_str() {
        "initialize" => Ok(protocol::initialize_result(
            forge_mcp::SERVER_NAME,
            forge_mcp::SERVER_VERSION,
            protocol::negotiate(
                request
                    .params
                    .get("protocolVersion")
                    .and_then(|value| value.as_str()),
            ),
        )),
        "ping" => Ok(serde_json::json!({})),
        "tools/list" => Ok(serde_json::json!({ "tools": specs() })),
        "tools/call" => match protocol::parse_tool_call(&request.params) {
            Ok((name, arguments)) => Ok(call(&state.app, &name, arguments, &caller)
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
            name: "list_sessions",
            description: "List the agent sessions on this machine: which repository each is in, what \
                 it is doing, whether it is waiting on a human, and what it has spent. Call \
                 this when the user asks what is running, what is stuck, or where their \
                 credits are going.",
            input_schema: object_schema(&[]),
        },
        protocol::ToolSpec {
            name: "list_approvals",
            description: "List the commands waiting for a human decision, with the exact command text \
                 and how risky it was judged to be. Call this when the user asks whether \
                 anything is blocked, or before deciding anything — an agent stalls until \
                 these are answered.",
            input_schema: object_schema(&[]),
        },
        protocol::ToolSpec {
            name: "decide_approval",
            description: "Approve or deny one pending command, unblocking the agent that is waiting. \
                 Destructive commands are refused here by design and must be cleared by a \
                 person. Call this only when the user has told you what they want done — read \
                 the command back to them first if there is any doubt.",
            input_schema: object_schema(&[
                ("approval_id", "Which approval, from list_approvals.", true),
                ("decision", "Either `approved` or `denied`.", true),
            ]),
        },
        protocol::ToolSpec {
            name: "list_tasks",
            description: "List the change sets this machine's own coding agent has proposed, and their \
                 review state. Call this when the user asks what is waiting to be reviewed or \
                 what the agent has been working on.",
            input_schema: object_schema(&[]),
        },
        protocol::ToolSpec {
            name: "get_task",
            description: "Read one proposed change set in full, including its unified diff, what it \
                 cost, and any verification notes. Call this before reviewing a task, and \
                 when the user asks what a change actually does.",
            input_schema: object_schema(&[("task_id", "Which task, from list_tasks.", true)]),
        },
        protocol::ToolSpec {
            name: "review_task",
            description: "Approve a proposed change set onto disk, or reject it with a reason the next \
                 attempt will be given. Nothing is written until this is called. Call this only \
                 on the user's explicit instruction — you are applying edits to their working \
                 tree.",
            input_schema: object_schema(&[
                ("task_id", "Which task, from list_tasks.", true),
                ("decision", "Either `approve` or `reject`.", true),
                (
                    "note",
                    "Why. Required in spirit for a rejection — it is handed to the next attempt.",
                    false,
                ),
            ]),
        },
        protocol::ToolSpec {
            name: "start_task",
            description: "Point this machine's coding agent at a repository. It proposes a diff rather \
                 than editing the working tree, and every model call it makes goes through the \
                 cost gateway — cache, cheaper-tier routing, compaction, batching. Call this \
                 when the user asks for a code change to be attempted here.",
            input_schema: object_schema(&[
                (
                    "repo_path",
                    "Absolute path to the repository on this machine.",
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
        protocol::ToolSpec {
            name: "get_spend",
            description: "Read what this machine has spent and how well the cost gateway is doing: \
                 today's spend, the cache-hit ratio, and what was avoided. Call this when the \
                 user asks about AI cost, whether caching is working, or where credits went.",
            input_schema: object_schema(&[]),
        },
    ]
}

async fn call(
    state: &Arc<AppState>,
    name: &str,
    arguments: serde_json::Value,
    caller: &Caller,
) -> ToolOutcome {
    // Everything a connector does is recorded as one, never disguised as a
    // person — the audit trail's whole job is telling those apart.
    let via = DecidedVia::Connector;

    match name {
        "list_sessions" => match crate::views::build_fleet_view(state) {
            Ok(fleet) => ToolOutcome::json(&fleet),
            Err(err) => ToolOutcome::error(err.to_string()),
        },

        "list_approvals" => match crate::views::build_fleet_view(state) {
            Ok(fleet) => ToolOutcome::json(&fleet.pending_approvals),
            Err(err) => ToolOutcome::error(err.to_string()),
        },

        "decide_approval" => {
            if !caller.can_act() {
                return refuse_role(caller);
            }
            let approval_id = match required_str(&arguments, "approval_id") {
                Ok(value) => value,
                Err(refusal) => return refusal,
            };
            let raw = match required_str(&arguments, "decision") {
                Ok(value) => value,
                Err(refusal) => return refusal,
            };
            let decision = match raw.to_ascii_lowercase().as_str() {
                "approved" | "approve" | "allow" => Decision::Approved,
                "denied" | "deny" | "reject" => Decision::Denied,
                other => {
                    return ToolOutcome::error(format!(
                        "`{other}` is not a decision — use `approved` or `denied`"
                    ));
                }
            };

            run(
                state,
                forge_proto::commands::Command::Decide {
                    approval_id,
                    decision,
                },
                via,
            )
            .await
        }

        "list_tasks" => match crate::views::build_task_list(state) {
            Ok(tasks) => ToolOutcome::json(&tasks),
            Err(err) => ToolOutcome::error(err.to_string()),
        },

        "get_task" => {
            let task_id = match required_str(&arguments, "task_id") {
                Ok(value) => value,
                Err(refusal) => return refusal,
            };
            match crate::views::build_task_detail(state, &task_id) {
                Ok(detail) => ToolOutcome::json(&detail),
                Err(err) => ToolOutcome::error(err.to_string()),
            }
        }

        "review_task" => {
            if !caller.can_act() {
                return refuse_role(caller);
            }
            let task_id = match required_str(&arguments, "task_id") {
                Ok(value) => value,
                Err(refusal) => return refusal,
            };
            let raw = match required_str(&arguments, "decision") {
                Ok(value) => value,
                Err(refusal) => return refusal,
            };
            let decision = match raw.to_ascii_lowercase().as_str() {
                "approve" | "approved" | "apply" => forge_proto::commands::Review::Approve,
                "reject" | "rejected" | "deny" => forge_proto::commands::Review::Reject,
                other => {
                    return ToolOutcome::error(format!(
                        "`{other}` is not a review — use `approve` or `reject`"
                    ));
                }
            };

            run(
                state,
                forge_proto::commands::Command::ReviewTask {
                    task_id,
                    decision,
                    note: optional_str(&arguments, "note"),
                },
                via,
            )
            .await
        }

        "start_task" => {
            if !caller.can_act() {
                return refuse_role(caller);
            }
            let repo_path = match required_str(&arguments, "repo_path") {
                Ok(value) => value,
                Err(refusal) => return refusal,
            };
            let prompt = match required_str(&arguments, "prompt") {
                Ok(value) => value,
                Err(refusal) => return refusal,
            };
            let budget_usd = optional_str(&arguments, "budget_usd")
                .and_then(|raw| raw.trim_start_matches('$').parse::<f64>().ok());

            run(
                state,
                forge_proto::commands::Command::StartTask {
                    repo_path,
                    prompt,
                    budget_usd,
                    retry_of: None,
                },
                via,
            )
            .await
        }

        "get_spend" => match crate::views::build_fleet_view(state) {
            Ok(fleet) => ToolOutcome::json(&serde_json::json!({
                "today_usd": fleet.today_usd,
                "cache_hit_ratio": fleet.cache_hit_ratio,
                "sessions": fleet.sessions.len(),
            })),
            Err(err) => ToolOutcome::error(err.to_string()),
        },

        other => ToolOutcome::error(format!("this machine has no tool called {other}")),
    }
}

/// Run a command through the shared executor.
///
/// Everything goes through [`crate::commands::execute`] rather than touching
/// the store directly — that is where the destructive-command rule lives, and a
/// transport that reached around it would be a transport that shipped without
/// it.
async fn run(
    state: &Arc<AppState>,
    command: forge_proto::commands::Command,
    via: DecidedVia,
) -> ToolOutcome {
    match crate::commands::execute(state, command, via).await {
        Ok(outcome) => match serde_json::to_value(&outcome) {
            Ok(value) => ToolOutcome::json(&value),
            Err(err) => ToolOutcome::error(err.to_string()),
        },
        // A refusal is the tool saying no, not the call failing — Claude should
        // read it and tell the user why, which is exactly what happens when a
        // destructive command comes back here.
        Err(err) => ToolOutcome::error(err.to_string()),
    }
}

fn refuse_role(caller: &Caller) -> ToolOutcome {
    ToolOutcome::error(format!(
        "this needs the member role or higher; the connector is authorised as {}",
        caller.role.as_str()
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use forge_crypto::token::{Claims, Role, TokenSigner};

    fn gate(signer: &TokenSigner, org_id: &str) -> Gate {
        Gate {
            verifier: signer.verifier(),
            org_id: org_id.to_owned(),
            public_url: "https://mac.example.com".into(),
            issuer: "https://farhelm.aurovie.com".into(),
        }
    }

    fn token(signer: &TokenSigner, org: &str, aud: Audience) -> String {
        let now = forge_app::time::now_ms();
        signer
            .mint(&Claims {
                sub: "acc_1".into(),
                aud,
                org: org.into(),
                role: Role::Member,
                chan: None,
                plan: None,
                rate: None,
                iat: now,
                exp: now + 600_000,
            })
            .unwrap()
    }

    #[test]
    fn a_token_for_this_machines_org_is_admitted() {
        let signer = TokenSigner::generate();
        let gate = gate(&signer, "org_mine");
        let caller = gate
            .admit(&token(&signer, "org_mine", Audience::Mcp))
            .expect("should be admitted");
        assert_eq!(caller.org_id, "org_mine");
        assert_eq!(caller.account_id, "acc_1");
    }

    #[test]
    fn a_valid_token_for_another_org_is_refused() {
        // The check a resource server is most likely to forget. Without it,
        // every RelayForge account on the internet can read this machine.
        let signer = TokenSigner::generate();
        let gate = gate(&signer, "org_mine");
        assert!(
            gate.admit(&token(&signer, "org_theirs", Audience::Mcp))
                .is_none()
        );
    }

    #[test]
    fn a_token_for_the_control_plane_api_is_not_a_connector_token() {
        let signer = TokenSigner::generate();
        let gate = gate(&signer, "org_mine");
        assert!(
            gate.admit(&token(&signer, "org_mine", Audience::Api))
                .is_none()
        );
    }

    #[test]
    fn a_token_from_another_signer_is_refused() {
        let ours = TokenSigner::generate();
        let theirs = TokenSigner::generate();
        let gate = gate(&ours, "org_mine");
        assert!(
            gate.admit(&token(&theirs, "org_mine", Audience::Mcp))
                .is_none()
        );
    }

    #[test]
    fn nothing_is_admitted_without_a_token() {
        let signer = TokenSigner::generate();
        assert!(gate(&signer, "org_mine").admit("").is_none());
        assert!(gate(&signer, "org_mine").admit("not-a-token").is_none());
    }

    #[test]
    fn every_tool_declares_a_schema_and_says_when_to_use_itself() {
        for spec in specs() {
            assert_eq!(spec.input_schema["type"], "object", "{}", spec.name);
            assert_eq!(spec.input_schema["additionalProperties"], false);
            assert!(
                spec.description.contains("Call this"),
                "{} does not say when to use it",
                spec.name
            );
        }
    }

    #[test]
    fn the_write_tools_warn_about_what_they_do() {
        // These apply edits and unblock agents. The description is the only
        // place Claude learns to be careful with them.
        let specs = specs();
        let review = specs.iter().find(|s| s.name == "review_task").unwrap();
        assert!(review.description.contains("explicit instruction"));

        let decide = specs.iter().find(|s| s.name == "decide_approval").unwrap();
        assert!(decide.description.contains("Destructive"));
    }
}
