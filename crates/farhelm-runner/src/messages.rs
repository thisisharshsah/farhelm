//! `POST /v1/messages`: the Anthropic Messages API, served by the gateway.
//!
//! # Why this exists when `/v1/complete` already did
//!
//! `/v1/complete` takes the gateway's own shape: a session id, a task type, and
//! a prompt already split into the half that never changes and the one
//! instruction that does. That split is the point: it is what makes prompt
//! caching pay, and a caller physically cannot interleave a timestamp into the
//! stable half because the two are separate fields.
//!
//! It is also a shape nothing else speaks. The docstring on `/v1/complete` said
//! it was "the endpoint an agent points `ANTHROPIC_BASE_URL` at", and that was
//! not true: point a real client at it and every request fails on an unknown
//! field. So "route your AI through your own system" meant "rewrite every tool
//! you own", which is not a thing anybody does.
//!
//! This endpoint speaks the wire format tools already emit. Set
//! `ANTHROPIC_BASE_URL` to the runner and existing software goes through the
//! eight stages (budget, pre-gate, routing, retrieval, compaction,
//! cache-shaped assembly, response cache, dispatch) without being modified.
//!
//! # What is lost in the translation, stated plainly
//!
//! The Messages API has no session id and no task type, and the gateway needs
//! both: one to attribute spend, the other to route to a tier. They are read
//! from `metadata.user_id` and an `x-farhelm-task` header, and defaulted when
//! absent. A default task type means default routing: correct, and not as
//! cheap as telling the gateway that this call is a commit message.
//!
//! Text, assistant tool calls and matching user tool results survive translation.
//! Images/documents and unsupported blocks are refused rather than dropped.
//! Tool IDs, arguments and error status remain structured across turns; tool-like
//! text never becomes an executable call.
//!
//! # Streaming
//!
//! Honestly synthetic. The gateway answers in one piece (it has to, because
//! the response cache and the batch queue both need a complete answer to store),
//! so a streamed response is the finished text emitted as one delta inside a
//! correctly-framed SSE envelope.
//!
//! It is implemented anyway because most clients send `stream: true` by
//! default and treat a refusal as the endpoint being broken. The framing is
//! real, the incrementality is not, and no client can tell the difference
//! except by timing.

use std::collections::HashSet;
use std::sync::Arc;

use axum::{
    Json,
    extract::State,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response, Sse, sse::Event},
};
use farhelm_gateway::{
    CompleteRequest, GatewayError, ToolCall,
    prompt::{Role, ToolResult, Turn},
};
use farhelm_proto::types::TaskType;
use serde::{Deserialize, Serialize};

use crate::api::ApiError;
use crate::state::AppState;

/* ----------------------------------------------------------------- request */

#[derive(Debug, Deserialize)]
pub struct MessagesBody {
    /// Accepted and not honoured: the router picks the tier. Echoed back in the
    /// response as the model that actually ran, which is the honest answer.
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub max_tokens: Option<u32>,
    #[serde(default)]
    pub system: Option<SystemField>,
    pub messages: Vec<InboundMessage>,
    #[serde(default)]
    pub tools: Vec<serde_json::Value>,
    #[serde(default)]
    pub metadata: Option<Metadata>,
    #[serde(default)]
    pub stream: bool,
}

#[derive(Debug, Deserialize)]
pub struct Metadata {
    #[serde(default)]
    pub user_id: Option<String>,
}

/// `system` is either a string or a list of blocks, depending on the client.
#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub enum SystemField {
    Text(String),
    Blocks(Vec<ContentBlock>),
}

#[derive(Debug, Deserialize)]
pub struct InboundMessage {
    pub role: String,
    pub content: MessageContent,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub enum MessageContent {
    Text(String),
    Blocks(Vec<ContentBlock>),
}

#[derive(Debug, Deserialize)]
pub struct ContentBlock {
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub text: Option<String>,
    /// `tool_result` carries its payload here rather than in `text`.
    #[serde(default)]
    pub content: Option<serde_json::Value>,
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub input: Option<serde_json::Value>,
    #[serde(default)]
    pub tool_use_id: Option<String>,
    #[serde(default)]
    pub is_error: bool,
    #[serde(default)]
    pub toolset_name: Option<String>,
}

impl SystemField {
    fn flatten(&self) -> Result<String, ApiError> {
        match self {
            SystemField::Text(text) => Ok(text.clone()),
            SystemField::Blocks(blocks) => flatten_text_blocks(blocks),
        }
    }
}

impl InboundMessage {
    fn to_turn(&self) -> Result<Turn, ApiError> {
        let role = match self.role.as_str() {
            "user" => Role::User,
            "assistant" => Role::Assistant,
            other => {
                return Err(invalid(format!(
                    "message role `{other}` is not supported; use user or assistant"
                )));
            }
        };
        let mut turn = match role {
            Role::User => Turn::user(""),
            Role::Assistant => Turn::assistant(""),
        };
        match &self.content {
            MessageContent::Text(text) => turn.text = text.clone(),
            MessageContent::Blocks(blocks) => {
                let mut text = Vec::new();
                for block in blocks {
                    if block.toolset_name.is_some() {
                        return Err(invalid("toolset members are not supported by this gateway"));
                    }
                    match block.kind.as_str() {
                        "text" => text.push(required(&block.text, "text.text")?.to_owned()),
                        "tool_use" if role == Role::Assistant => {
                            let input = block
                                .input
                                .as_ref()
                                .filter(|value| value.is_object())
                                .ok_or_else(|| invalid("tool_use.input must be a JSON object"))?;
                            turn.tool_calls.push(ToolCall {
                                id: nonempty(&block.id, "tool_use.id")?.to_owned(),
                                name: nonempty(&block.name, "tool_use.name")?.to_owned(),
                                input: input.clone(),
                            });
                        }
                        "tool_result" if role == Role::User => {
                            if !text.is_empty() {
                                return Err(invalid(
                                    "tool_result blocks must precede text in a user message",
                                ));
                            }
                            turn.tool_results.push(ToolResult {
                                tool_use_id: nonempty(
                                    &block.tool_use_id,
                                    "tool_result.tool_use_id",
                                )?
                                .to_owned(),
                                content: tool_result_text(block.content.as_ref())?,
                                is_error: block.is_error,
                            });
                        }
                        "tool_use" | "tool_result" => {
                            return Err(invalid(format!(
                                "{} is not valid in a {} message",
                                block.kind, self.role,
                            )));
                        }
                        other => return Err(unsupported(other)),
                    }
                }
                turn.text = text.join("\n");
            }
        }
        Ok(turn)
    }
}

fn invalid(message: impl Into<String>) -> ApiError {
    ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, message)
}

fn unsupported(kind: &str) -> ApiError {
    invalid(format!(
        "content block `{kind}` is not supported by the gateway; supported blocks are text, assistant tool_use and user tool_result"
    ))
}

fn required<'a>(value: &'a Option<String>, field: &str) -> Result<&'a str, ApiError> {
    value
        .as_deref()
        .ok_or_else(|| invalid(format!("{field} is required")))
}

fn nonempty<'a>(value: &'a Option<String>, field: &str) -> Result<&'a str, ApiError> {
    let value = required(value, field)?;
    if value.trim().is_empty() {
        return Err(invalid(format!("{field} must not be empty")));
    }
    Ok(value)
}

fn flatten_text_blocks(blocks: &[ContentBlock]) -> Result<String, ApiError> {
    blocks
        .iter()
        .map(|block| {
            if block.kind != "text" {
                return Err(unsupported(&block.kind));
            }
            Ok(required(&block.text, "text.text")?.to_owned())
        })
        .collect::<Result<Vec<_>, _>>()
        .map(|parts| parts.join("\n"))
}

fn tool_result_text(value: Option<&serde_json::Value>) -> Result<String, ApiError> {
    match value {
        None => Ok(String::new()),
        Some(serde_json::Value::String(text)) => Ok(text.clone()),
        Some(serde_json::Value::Array(blocks)) => {
            let blocks: Vec<ContentBlock> =
                serde_json::from_value(serde_json::Value::Array(blocks.clone())).map_err(|_| {
                    invalid("tool_result.content must contain supported text blocks")
                })?;
            flatten_text_blocks(&blocks)
        }
        Some(_) => Err(invalid(
            "tool_result.content must be a string or text block array",
        )),
    }
}

/// Every result belongs to the immediately preceding assistant tool turn.
/// Requiring the whole exchange prevents orphan/duplicate results and avoids
/// forwarding a partial tool conversation to a runtime with different rules.
fn validate_tool_pairs(turns: &[Turn]) -> Result<(), ApiError> {
    let mut seen = HashSet::new();
    let mut pending = HashSet::new();
    for turn in turns {
        if !pending.is_empty() && turn.role != Role::User {
            return Err(invalid(
                "assistant tool calls require matching results in the next user message",
            ));
        }
        for result in &turn.tool_results {
            if !pending.remove(result.tool_use_id.as_str()) {
                return Err(invalid(
                    "tool_result has an unknown or duplicate tool_use_id",
                ));
            }
        }
        if !pending.is_empty() {
            return Err(invalid(
                "the next user message must provide a result for every assistant tool call",
            ));
        }
        for call in &turn.tool_calls {
            if !seen.insert(call.id.as_str()) {
                return Err(invalid(
                    "tool_use.id must be unique within the conversation",
                ));
            }
            pending.insert(call.id.as_str());
        }
    }
    if !pending.is_empty() {
        return Err(invalid("assistant tool calls are missing their results"));
    }
    Ok(())
}

/* ---------------------------------------------------------------- response */

#[derive(Debug, Serialize)]
pub struct MessagesView {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub role: &'static str,
    pub model: String,
    pub content: Vec<OutBlock>,
    pub stop_reason: &'static str,
    pub stop_sequence: Option<String>,
    pub usage: OutUsage,
    /// Not in Anthropic's schema, and deliberately kept: the whole reason to
    /// route through here is to be able to answer "why did that cost that".
    /// Clients ignore unknown fields, so it costs nothing to carry.
    pub forge: FarhelmTrace,
}

#[derive(Debug, Serialize)]
#[serde(untagged)]
pub enum OutBlock {
    Text {
        #[serde(rename = "type")]
        kind: &'static str,
        text: String,
    },
    ToolUse {
        #[serde(rename = "type")]
        kind: &'static str,
        id: String,
        name: String,
        input: serde_json::Value,
    },
}

#[derive(Debug, Serialize)]
pub struct OutUsage {
    pub input_tokens: u32,
    pub output_tokens: u32,
    pub cache_creation_input_tokens: u32,
    pub cache_read_input_tokens: u32,
}

#[derive(Debug, Serialize)]
pub struct FarhelmTrace {
    pub tier: farhelm_proto::types::Tier,
    pub cost_usd: f64,
    /// `pre_gate` or `response_cache` when the answer cost nothing.
    pub avoided: Option<farhelm_proto::types::Avoided>,
    pub served: String,
}

/* ----------------------------------------------------------------- handler */

/// Where spend is attributed when the caller does not say.
///
/// One bucket rather than one per request: a fresh id per call would make the
/// budget stage meaningless, since nothing would ever have a history to be
/// measured against.
const DEFAULT_SESSION: &str = "anthropic-compat";

/// Which session a compat call belongs to, when the body does not say.
const SESSION_HEADER: &str = "x-farhelm-session";
/// What that header was called before the rename. Anything already configured
/// to send it keeps working; nothing new is told about it.
const LEGACY_SESSION_HEADER: &str = "x-forge-session";
/// What kind of turn this is, which is what the router prices and routes on.
const TASK_HEADER: &str = "x-farhelm-task";
/// The pre-rename spelling, still accepted.
const LEGACY_TASK_HEADER: &str = "x-forge-task";
/// Which repository the call is about.
const REPO_HEADER: &str = "x-farhelm-repo";
/// The pre-rename spelling, still accepted.
const LEGACY_REPO_HEADER: &str = "x-forge-repo";

/// Turn a Messages request into a gateway request.
///
/// Split out from the handler so the translation (which is where every
/// interesting decision lives) can be tested without a model provider, a
/// gateway or a network. It also fixes an ordering bug worth naming: the
/// provider check used to run first, so a client with a malformed request got
/// "no model provider configured" and went looking for a missing API key
/// instead of at its own JSON.
pub fn translate(headers: &HeaderMap, body: MessagesBody) -> Result<CompleteRequest, ApiError> {
    // The last user turn is what changes; everything before it is history the
    // cache can hold on to. A trailing assistant turn is a prefill, which the
    // gateway has no way to express, so it is refused rather than dropped.
    let Some(last) = body.messages.last() else {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "messages must not be empty",
        ));
    };
    if last.role != "user" {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "the last message must be from the user; assistant prefill is not \
             supported",
        ));
    }

    let session_id = body
        .metadata
        .as_ref()
        .and_then(|meta| meta.user_id.clone())
        .or_else(|| header_str(headers, SESSION_HEADER))
        .or_else(|| header_str(headers, LEGACY_SESSION_HEADER))
        .unwrap_or_else(|| DEFAULT_SESSION.to_owned());

    let task_type = match header_str(headers, TASK_HEADER)
        .or_else(|| header_str(headers, LEGACY_TASK_HEADER))
    {
        Some(raw) => raw.parse().map_err(|_| {
            ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                format!(
                    "{TASK_HEADER}: `{raw}` is not a task type; one of {}",
                    TaskType::ALL
                        .iter()
                        .map(|task| task.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
            )
        })?,
        // Edit is the honest default: it is what an unlabelled agent turn
        // almost always is, and it routes to a capable tier rather than a cheap
        // one. Guessing cheap to look good on a dashboard would be a way of
        // failing the caller quietly.
        None => TaskType::Edit,
    };

    let mut turns = body
        .messages
        .iter()
        .map(InboundMessage::to_turn)
        .collect::<Result<Vec<_>, _>>()?;
    validate_tool_pairs(&turns)?;
    let last = turns.pop().expect("nonempty messages checked above");
    let mut request = CompleteRequest::new(&session_id, task_type, last.text);
    request.tool_results = last.tool_results;
    request.stable.system = match &body.system {
        Some(field) => field.flatten()?,
        None => String::new(),
    };
    request.stable.tools = body.tools;
    request.stable.history = turns;
    request.repo_path = header_str(headers, REPO_HEADER)
        .or_else(|| header_str(headers, LEGACY_REPO_HEADER))
        .map(Into::into);
    Ok(request)
}

pub async fn messages(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<MessagesBody>,
) -> Result<Response, ApiError> {
    // Read before the body is moved into the translation.
    let stream = body.stream;
    // Validated before the provider is looked at, so a bad request says so.
    let request = translate(&headers, body)?;

    // The gateway attributes spend to a session, and a caller coming in over
    // the Messages API has no reason to have created one: it does not know
    // this system exists. Making them create one first would be the exact
    // "do the same thing again before you can start" this endpoint is meant to
    // remove, so the bucket creates itself on first use.
    ensure_bucket(&state, request.session_id.as_str())?;

    let Some(gateway) = &state.gateway else {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "no model provider configured; set ANTHROPIC_API_KEY or \
             ANTHROPIC_AUTH_TOKEN and restart",
        ));
    };

    let response = gateway.complete(request).await.map_err(|err| match err {
        GatewayError::BudgetExhausted { .. } => {
            ApiError::new(StatusCode::PAYMENT_REQUIRED, err.to_string())
        }
        GatewayError::Dispatch(_) => ApiError::new(StatusCode::BAD_GATEWAY, err.to_string()),
        other => ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, other.to_string()),
    })?;

    let has_tools = !response.tool_calls.is_empty();
    if has_tools
        && matches!(
            response.stop_reason.as_deref(),
            Some("max_tokens" | "length" | "model_context_window_exceeded")
        )
    {
        return Err(ApiError::new(
            StatusCode::BAD_GATEWAY,
            "the provider response was truncated with incomplete tool calls; no executable calls were returned",
        ));
    }
    let mut content: Vec<OutBlock> = Vec::new();
    if !response.text.is_empty() {
        content.push(OutBlock::Text {
            kind: "text",
            text: response.text.clone(),
        });
    }
    for call in &response.tool_calls {
        content.push(OutBlock::ToolUse {
            kind: "tool_use",
            id: call.id.clone(),
            name: call.name.clone(),
            input: call.input.clone(),
        });
    }

    let view = MessagesView {
        id: format!("msg_{}", farhelm_app::id::new_id()),
        kind: "message",
        role: "assistant",
        model: response.model.clone(),
        content,
        stop_reason: messages_stop_reason(response.stop_reason.as_deref(), has_tools),
        stop_sequence: None,
        usage: OutUsage {
            input_tokens: response.usage.input_tokens,
            output_tokens: response.usage.output_tokens,
            cache_creation_input_tokens: response.usage.cache_write_tokens,
            cache_read_input_tokens: response.usage.cache_read_tokens,
        },
        forge: FarhelmTrace {
            tier: response.tier,
            cost_usd: response.cost_usd,
            avoided: response.avoided,
            served: format!("{:?}", response.trace.served).to_lowercase(),
        },
    };

    if stream {
        return Ok(stream_of(view).into_response());
    }
    Ok(Json(view).into_response())
}

fn messages_stop_reason(reason: Option<&str>, has_tools: bool) -> &'static str {
    if has_tools {
        return "tool_use";
    }
    match reason {
        Some("max_tokens" | "length" | "model_context_window_exceeded") => "max_tokens",
        Some("refusal" | "content_filter") => "refusal",
        Some("stop_sequence") => "stop_sequence",
        _ => "end_turn",
    }
}

/// Create the session a request is billed against, if it is not there yet.
///
/// Idempotent, and deliberately cheap: one lookup on the common path, two
/// inserts exactly once per bucket. The repo row exists because a session
/// belongs to one; there is no real checkout behind an API call, so it points
/// at the runner's own home and is named for what it is.
fn ensure_bucket(state: &AppState, session_id: &str) -> Result<(), ApiError> {
    use farhelm_app::store::{FleetStore, SessionStore};
    use farhelm_proto::types::{Agent, Repo, Session, SessionStatus};

    let store_err = |err: farhelm_app::store::StoreError| {
        ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, err.to_string())
    };

    if state
        .store
        .get_session(session_id)
        .map_err(store_err)?
        .is_some()
    {
        return Ok(());
    }

    let repo_id = format!("repo-api-{}", state.machine_id);
    if state.store.get_repo(&repo_id).map_err(store_err)?.is_none() {
        state
            .store
            .upsert_repo(&Repo {
                id: repo_id.clone(),
                machine_id: state.machine_id.clone(),
                path: String::new(),
                name: "API calls".to_owned(),
                budget_usd: None,
            })
            .map_err(store_err)?;
    }

    state
        .store
        .upsert_session(&Session {
            id: session_id.to_owned(),
            repo_id,
            // The gateway is the agent here: nothing else is driving this turn.
            agent: Agent::Farhelm,
            tmux_target: None,
            // Running, not Done: a bucket that is closed the moment it is
            // created would show up in the fleet as a finished session, and
            // every subsequent call would be spend against a dead one.
            status: SessionStatus::Running,
            plan_id: None,
            // No cap by default. A cap invented here would start refusing calls
            // for a reason the caller never chose and cannot see.
            budget_usd: None,
            spent_usd: 0.0,
            started_at: farhelm_app::time::now_ms(),
            ended_at: None,
            agent_session_id: None,
        })
        .map_err(store_err)?;
    Ok(())
}

fn header_str(headers: &HeaderMap, name: &str) -> Option<String> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned)
        .filter(|value| !value.is_empty())
}

/// The finished answer, in the frames a streaming client expects.
///
/// Every event a Messages stream is required to emit, in order, with the whole
/// text as a single delta. Clients accumulate deltas, so one large delta
/// assembles to exactly the same string as a thousand small ones.
fn stream_of(
    view: MessagesView,
) -> Sse<impl futures_util::Stream<Item = Result<Event, std::convert::Infallible>>> {
    use serde_json::json;

    let mut events: Vec<Event> = Vec::new();
    let push = |events: &mut Vec<Event>, name: &str, data: serde_json::Value| {
        events.push(Event::default().event(name).data(data.to_string()));
    };

    push(
        &mut events,
        "message_start",
        json!({"type": "message_start", "message": {
            "id": view.id, "type": "message", "role": "assistant",
            "model": view.model, "content": [], "stop_reason": null,
            "stop_sequence": null,
            "usage": {"input_tokens": view.usage.input_tokens, "output_tokens": 0},
        }}),
    );

    for (index, block) in view.content.iter().enumerate() {
        match block {
            OutBlock::Text { text, .. } => {
                push(
                    &mut events,
                    "content_block_start",
                    json!({
                        "type": "content_block_start", "index": index,
                        "content_block": {"type": "text", "text": ""},
                    }),
                );
                push(
                    &mut events,
                    "content_block_delta",
                    json!({
                        "type": "content_block_delta", "index": index,
                        "delta": {"type": "text_delta", "text": text},
                    }),
                );
            }
            OutBlock::ToolUse {
                id, name, input, ..
            } => {
                push(
                    &mut events,
                    "content_block_start",
                    json!({
                        "type": "content_block_start", "index": index,
                        "content_block": {"type": "tool_use", "id": id, "name": name, "input": {}},
                    }),
                );
                push(
                    &mut events,
                    "content_block_delta",
                    json!({
                        "type": "content_block_delta", "index": index,
                        "delta": {"type": "input_json_delta", "partial_json": input.to_string()},
                    }),
                );
            }
        }
        push(
            &mut events,
            "content_block_stop",
            json!({"type": "content_block_stop", "index": index}),
        );
    }

    push(
        &mut events,
        "message_delta",
        json!({
            "type": "message_delta",
            "delta": {"stop_reason": view.stop_reason, "stop_sequence": null},
            "usage": {"output_tokens": view.usage.output_tokens},
        }),
    );
    push(&mut events, "message_stop", json!({"type": "message_stop"}));

    Sse::new(futures_util::stream::iter(events.into_iter().map(Ok)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn body(json: serde_json::Value) -> MessagesBody {
        serde_json::from_value(json).expect("a valid Messages request")
    }

    fn headers(pairs: &[(&str, &str)]) -> HeaderMap {
        let mut map = HeaderMap::new();
        for (name, value) in pairs {
            map.insert(
                axum::http::HeaderName::from_bytes(name.as_bytes()).unwrap(),
                value.parse().unwrap(),
            );
        }
        map
    }

    #[test]
    fn the_last_user_turn_is_the_instruction_and_the_rest_is_history() {
        let request = translate(
            &headers(&[]),
            body(serde_json::json!({
                "messages": [
                    {"role": "user", "content": "first"},
                    {"role": "assistant", "content": "answer"},
                    {"role": "user", "content": "second"},
                ],
            })),
        )
        .unwrap();

        // The split is the whole point: history is the half that can be cached,
        // the instruction is the half that cannot.
        assert_eq!(request.instruction, "second");
        assert_eq!(request.stable.history.len(), 2);
        assert_eq!(request.stable.history[1].role, Role::Assistant);
        assert_eq!(request.stable.history[1].text, "answer");
    }

    #[test]
    fn a_system_prompt_lands_in_the_stable_half() {
        // Where it can be cached. A system prompt in the instruction would be
        // re-sent uncached on every turn, which is the exact cost this gateway
        // exists to avoid.
        let request = translate(
            &headers(&[]),
            body(serde_json::json!({
                "system": "you are terse",
                "messages": [{"role": "user", "content": "hi"}],
            })),
        )
        .unwrap();
        assert_eq!(request.stable.system, "you are terse");
        assert!(request.instruction.contains("hi"));
    }

    #[test]
    fn a_block_form_system_prompt_is_joined() {
        let request = translate(
            &headers(&[]),
            body(serde_json::json!({
                "system": [{"type": "text", "text": "one"}, {"type": "text", "text": "two"}],
                "messages": [{"role": "user", "content": "hi"}],
            })),
        )
        .unwrap();
        assert_eq!(request.stable.system, "one\ntwo");
    }

    #[test]
    fn tool_calls_and_results_survive_translation_without_flattening() {
        let request = translate(&headers(&[]), body(serde_json::json!({
            "messages": [
                {"role": "user", "content": "inspect the repository"},
                {"role": "assistant", "content": [
                    {"type": "text", "text": "Inspecting."},
                    {"type": "tool_use", "id": "call-1", "name": "run", "input": {"command": "cargo test"}},
                ]},
                {"role": "user", "content": [
                    {"type": "tool_result", "tool_use_id": "call-1", "content": [{"type": "text", "text": "exit 1"}], "is_error": true},
                    {"type": "text", "text": "fix the failure"},
                ]},
            ],
        }))).unwrap();
        assert_eq!(request.instruction, "fix the failure");
        assert_eq!(request.tool_results[0].tool_use_id, "call-1");
        assert_eq!(request.tool_results[0].content, "exit 1");
        assert!(request.tool_results[0].is_error);
        let call = &request.stable.history[1].tool_calls[0];
        assert_eq!(call.id, "call-1");
        assert_eq!(call.name, "run");
        assert_eq!(call.input["command"], "cargo test");
        assert_eq!(request.stable.history[1].text, "Inspecting.");
    }

    #[test]
    fn malformed_or_unpaired_tool_history_is_refused() {
        let call = serde_json::json!({
            "role": "assistant", "content": [{
                "type": "tool_use", "id": "call-1", "name": "read_file", "input": {"path": "a.rs"},
            }],
        });
        let result = serde_json::json!({
            "role": "user", "content": [{
                "type": "tool_result", "tool_use_id": "call-1", "content": "contents",
            }],
        });
        let initial = serde_json::json!({"role": "user", "content": "inspect"});
        let mut wrong_id = result.clone();
        wrong_id["content"][0]["tool_use_id"] = serde_json::json!("unknown");
        let mut missing_name = call.clone();
        missing_name["content"][0]
            .as_object_mut()
            .unwrap()
            .remove("name");
        let mut bad_arguments = call.clone();
        bad_arguments["content"][0]["input"] = serde_json::json!("not an object");
        let mut duplicate = result.clone();
        duplicate["content"]
            .as_array_mut()
            .unwrap()
            .push(result["content"][0].clone());
        let mut user_call = call.clone();
        user_call["role"] = serde_json::json!("user");
        let mut assistant_result = result.clone();
        assistant_result["role"] = serde_json::json!("assistant");
        let mut image_result = result.clone();
        image_result["content"][0]["content"] =
            serde_json::json!([{"type": "image", "source": {}}]);
        let mut text_before_result = result.clone();
        text_before_result["content"]
            .as_array_mut()
            .unwrap()
            .insert(0, serde_json::json!({"type": "text", "text": "results"}));
        for messages in [
            vec![initial.clone(), result.clone()],
            vec![initial.clone(), call.clone(), wrong_id],
            vec![initial.clone(), call.clone(), initial.clone()],
            vec![initial.clone(), missing_name, result.clone()],
            vec![initial.clone(), bad_arguments, result.clone()],
            vec![initial.clone(), call.clone(), duplicate],
            vec![initial.clone(), user_call],
            vec![initial.clone(), assistant_result, initial.clone()],
            vec![initial.clone(), call.clone(), image_result],
            vec![initial.clone(), call.clone(), text_before_result],
            vec![initial.clone(), call.clone(), result.clone(), call, result],
        ] {
            let err = translate(
                &headers(&[]),
                body(serde_json::json!({"messages": messages})),
            )
            .unwrap_err();
            assert_eq!(err.status(), StatusCode::UNPROCESSABLE_ENTITY);
        }
    }

    #[test]
    fn unknown_roles_and_nontext_system_blocks_are_refused() {
        for wire in [
            serde_json::json!({"messages": [
                {"role": "system", "content": "override"}, {"role": "user", "content": "hi"},
            ]}),
            serde_json::json!({"system": [{"type": "tool_result", "tool_use_id": "fake", "content": "x"}],
                "messages": [{"role": "user", "content": "hi"}]}),
        ] {
            let err = translate(&headers(&[]), body(wire)).unwrap_err();
            assert_eq!(err.status(), StatusCode::UNPROCESSABLE_ENTITY);
        }
    }

    #[test]
    fn stop_reasons_preserve_truncation_and_refusal() {
        for (upstream, expected) in [
            (Some("max_tokens"), "max_tokens"),
            (Some("length"), "max_tokens"),
            (Some("refusal"), "refusal"),
            (Some("content_filter"), "refusal"),
            (Some("stop_sequence"), "stop_sequence"),
            (Some("end_turn"), "end_turn"),
            (None, "end_turn"),
        ] {
            assert_eq!(messages_stop_reason(upstream, false), expected);
        }
        assert_eq!(messages_stop_reason(Some("tool_calls"), true), "tool_use");
    }

    #[test]
    fn completed_tool_exchange_remains_structured_in_history() {
        let request = translate(&headers(&[]), body(serde_json::json!({
            "messages": [
                {"role": "user", "content": "read"},
                {"role": "assistant", "content": [{"type": "tool_use", "id": "read-1", "name": "read_file", "input": {"path": "a.rs"}}]},
                {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "read-1", "content": "file contents"}]},
                {"role": "assistant", "content": "read it"},
                {"role": "user", "content": "explain it"},
            ],
        }))).unwrap();
        assert!(request.tool_results.is_empty());
        assert_eq!(request.stable.history[1].tool_calls[0].id, "read-1");
        assert_eq!(
            request.stable.history[2].tool_results[0].tool_use_id,
            "read-1"
        );
        assert_eq!(
            request.stable.history[2].tool_results[0].content,
            "file contents"
        );
    }

    #[test]
    fn an_image_is_refused_rather_than_dropped() {
        // Billing for an answer to a prompt the caller did not send is the one
        // outcome worse than failing.
        let err = translate(
            &headers(&[]),
            body(serde_json::json!({
                "messages": [{"role": "user", "content": [{"type": "image", "source": {}}]}],
            })),
        )
        .unwrap_err();
        assert_eq!(err.status(), StatusCode::UNPROCESSABLE_ENTITY);
        assert!(err.message().contains("image"));
    }

    #[test]
    fn an_assistant_prefill_is_refused() {
        let err = translate(
            &headers(&[]),
            body(serde_json::json!({
                "messages": [
                    {"role": "user", "content": "x"},
                    {"role": "assistant", "content": "partial"},
                ],
            })),
        )
        .unwrap_err();
        assert_eq!(err.status(), StatusCode::UNPROCESSABLE_ENTITY);
    }

    #[test]
    fn an_empty_conversation_is_refused() {
        let err = translate(&headers(&[]), body(serde_json::json!({"messages": []}))).unwrap_err();
        assert_eq!(err.status(), StatusCode::UNPROCESSABLE_ENTITY);
    }

    #[test]
    fn spend_is_attributed_to_the_caller_when_it_says_who_it_is() {
        let request = translate(
            &headers(&[]),
            body(serde_json::json!({
                "metadata": {"user_id": "sess-42"},
                "messages": [{"role": "user", "content": "hi"}],
            })),
        )
        .unwrap();
        assert_eq!(request.session_id, "sess-42");
    }

    #[test]
    fn a_header_names_the_session_when_metadata_does_not() {
        let request = translate(
            &headers(&[("x-farhelm-session", "from-header")]),
            body(serde_json::json!({"messages": [{"role": "user", "content": "hi"}]})),
        )
        .unwrap();
        assert_eq!(request.session_id, "from-header");
    }

    #[test]
    fn the_headers_this_used_to_answer_to_still_work() {
        // Anything already pointed at this endpoint (a shell alias, a CI job,
        // another tool's config) is sending the old spelling. A rename that
        // stops reading it turns every one of those calls into an unattributed
        // edit, which is a billing and routing regression with no error to
        // notice it by.
        let request = translate(
            &headers(&[
                ("x-forge-session", "old-name"),
                ("x-forge-task", "commit_msg"),
            ]),
            body(serde_json::json!({"messages": [{"role": "user", "content": "hi"}]})),
        )
        .unwrap();
        assert_eq!(request.session_id, "old-name");
        assert_eq!(request.task_type, TaskType::CommitMsg);
    }

    #[test]
    fn the_current_header_wins_over_the_one_it_replaced() {
        let request = translate(
            &headers(&[
                ("x-farhelm-session", "current"),
                ("x-forge-session", "old-name"),
            ]),
            body(serde_json::json!({"messages": [{"role": "user", "content": "hi"}]})),
        )
        .unwrap();
        assert_eq!(request.session_id, "current");
    }

    #[test]
    fn everything_unattributed_shares_one_bucket() {
        // Not a fresh id per call: that would give the budget stage nothing to
        // measure against, and every request would look like the first.
        let request = translate(
            &headers(&[]),
            body(serde_json::json!({"messages": [{"role": "user", "content": "hi"}]})),
        )
        .unwrap();
        assert_eq!(request.session_id, DEFAULT_SESSION);
    }

    #[test]
    fn an_unlabelled_call_routes_as_an_edit() {
        let request = translate(
            &headers(&[]),
            body(serde_json::json!({"messages": [{"role": "user", "content": "hi"}]})),
        )
        .unwrap();
        assert_eq!(request.task_type, TaskType::Edit);
    }

    #[test]
    fn a_labelled_call_routes_to_what_it_says() {
        let request = translate(
            &headers(&[("x-farhelm-task", "commit_msg")]),
            body(serde_json::json!({"messages": [{"role": "user", "content": "hi"}]})),
        )
        .unwrap();
        assert_eq!(request.task_type, TaskType::CommitMsg);
    }

    #[test]
    fn an_unknown_task_type_names_the_ones_that_exist() {
        // "invalid" on its own leaves the caller guessing at a closed set they
        // cannot see from the wire.
        let err = translate(
            &headers(&[("x-farhelm-task", "chat")]),
            body(serde_json::json!({"messages": [{"role": "user", "content": "hi"}]})),
        )
        .unwrap_err();
        assert!(err.message().contains("commit_msg"));
        assert!(err.message().contains("hard_debug"));
    }
}
