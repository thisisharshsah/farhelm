//! `POST /v1/messages` — the Anthropic Messages API, served by the gateway.
//!
//! # Why this exists when `/v1/complete` already did
//!
//! `/v1/complete` takes the gateway's own shape: a session id, a task type, and
//! a prompt already split into the half that never changes and the one
//! instruction that does. That split is the point — it is what makes prompt
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
//! eight stages — budget, pre-gate, routing, retrieval, compaction,
//! cache-shaped assembly, response cache, dispatch — without being modified.
//!
//! # What is lost in the translation, stated plainly
//!
//! The Messages API has no session id and no task type, and the gateway needs
//! both: one to attribute spend, the other to route to a tier. They are read
//! from `metadata.user_id` and an `x-forge-task` header, and defaulted when
//! absent. A default task type means default routing — correct, and not as
//! cheap as telling the gateway that this call is a commit message.
//!
//! Multi-block content is flattened to text. The gateway's prompt model is
//! text-plus-tools, so images and documents in a request would be silently
//! dropped — which is why they are refused instead. Silently ignoring part of a
//! prompt and then billing for the answer is the worst available behaviour.
//!
//! # Streaming
//!
//! Honestly synthetic. The gateway answers in one piece — it has to, because
//! the response cache and the batch queue both need a complete answer to store
//! — so a streamed response is the finished text emitted as one delta inside a
//! correctly-framed SSE envelope.
//!
//! It is implemented anyway because most clients send `stream: true` by
//! default and treat a refusal as the endpoint being broken. The framing is
//! real, the incrementality is not, and no client can tell the difference
//! except by timing.

use std::sync::Arc;

use axum::{
    Json,
    extract::State,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response, Sse, sse::Event},
};
use forge_gateway::{CompleteRequest, GatewayError, prompt::Turn};
use forge_proto::types::TaskType;
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
}

impl SystemField {
    fn flatten(&self) -> Result<String, ApiError> {
        match self {
            SystemField::Text(text) => Ok(text.clone()),
            SystemField::Blocks(blocks) => flatten_blocks(blocks),
        }
    }
}

impl MessageContent {
    fn flatten(&self) -> Result<String, ApiError> {
        match self {
            MessageContent::Text(text) => Ok(text.clone()),
            MessageContent::Blocks(blocks) => flatten_blocks(blocks),
        }
    }
}

/// Text and tool results survive; anything else is refused rather than dropped.
fn flatten_blocks(blocks: &[ContentBlock]) -> Result<String, ApiError> {
    let mut out = Vec::new();
    for block in blocks {
        match block.kind.as_str() {
            "text" => out.push(block.text.clone().unwrap_or_default()),
            "tool_result" => {
                let rendered = match &block.content {
                    Some(serde_json::Value::String(text)) => text.clone(),
                    Some(value) => value.to_string(),
                    None => String::new(),
                };
                out.push(rendered);
            }
            // Refused, not skipped. A prompt that quietly loses its image and
            // is then billed for the answer is worse than one that fails.
            other => {
                return Err(ApiError::new(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    format!(
                        "content block `{other}` is not supported by the gateway — \
                         it holds text and tools only, and dropping the rest \
                         silently would bill you for an answer to a prompt you \
                         did not send"
                    ),
                ));
            }
        }
    }
    Ok(out.join("\n"))
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
    pub forge: ForgeTrace,
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
pub struct ForgeTrace {
    pub tier: forge_proto::types::Tier,
    pub cost_usd: f64,
    /// `pre_gate` or `response_cache` when the answer cost nothing.
    pub avoided: Option<forge_proto::types::Avoided>,
    pub served: String,
}

/* ----------------------------------------------------------------- handler */

/// Where spend is attributed when the caller does not say.
///
/// One bucket rather than one per request: a fresh id per call would make the
/// budget stage meaningless, since nothing would ever have a history to be
/// measured against.
const DEFAULT_SESSION: &str = "anthropic-compat";

/// Turn a Messages request into a gateway request.
///
/// Split out from the handler so the translation — which is where every
/// interesting decision lives — can be tested without a model provider, a
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
            "the last message must be from the user — assistant prefill is not \
             supported",
        ));
    }

    let session_id = body
        .metadata
        .as_ref()
        .and_then(|meta| meta.user_id.clone())
        .or_else(|| header_str(headers, "x-forge-session"))
        .unwrap_or_else(|| DEFAULT_SESSION.to_owned());

    let task_type = match header_str(headers, "x-forge-task") {
        Some(raw) => raw.parse().map_err(|_| {
            ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                format!(
                    "x-forge-task: `{raw}` is not a task type — one of {}",
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

    let mut request = CompleteRequest::new(&session_id, task_type, last.content.flatten()?);
    request.stable.system = match &body.system {
        Some(field) => field.flatten()?,
        None => String::new(),
    };
    request.stable.tools = body.tools;
    request.stable.history = body
        .messages
        .iter()
        .take(body.messages.len() - 1)
        .map(|message| {
            Ok(Turn {
                role: match message.role.as_str() {
                    "assistant" => forge_gateway::prompt::Role::Assistant,
                    _ => forge_gateway::prompt::Role::User,
                },
                text: message.content.flatten()?,
            })
        })
        .collect::<Result<Vec<_>, ApiError>>()?;
    request.repo_path = header_str(headers, "x-forge-repo").map(Into::into);
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

    let Some(gateway) = &state.gateway else {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "no model provider configured — set ANTHROPIC_API_KEY or \
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
        id: format!("msg_{}", forge_app::id::new_id()),
        kind: "message",
        role: "assistant",
        model: response.model.clone(),
        content,
        stop_reason: if has_tools { "tool_use" } else { "end_turn" },
        stop_sequence: None,
        usage: OutUsage {
            input_tokens: response.usage.input_tokens,
            output_tokens: response.usage.output_tokens,
            cache_creation_input_tokens: response.usage.cache_write_tokens,
            cache_read_input_tokens: response.usage.cache_read_tokens,
        },
        forge: ForgeTrace {
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
    use forge_gateway::prompt::Role;

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
    fn a_tool_result_survives_the_flattening() {
        // An agent loop sends the tool's output back as a block. Losing it
        // would leave the model answering without the thing it asked for.
        let request = translate(
            &headers(&[]),
            body(serde_json::json!({
                "messages": [{"role": "user", "content": [
                    {"type": "tool_result", "content": "exit 0"},
                    {"type": "text", "text": "did it work?"},
                ]}],
            })),
        )
        .unwrap();
        assert!(request.instruction.contains("exit 0"));
        assert!(request.instruction.contains("did it work?"));
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
            &headers(&[("x-forge-session", "from-header")]),
            body(serde_json::json!({"messages": [{"role": "user", "content": "hi"}]})),
        )
        .unwrap();
        assert_eq!(request.session_id, "from-header");
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
            &headers(&[("x-forge-task", "commit_msg")]),
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
            &headers(&[("x-forge-task", "chat")]),
            body(serde_json::json!({"messages": [{"role": "user", "content": "hi"}]})),
        )
        .unwrap_err();
        assert!(err.message().contains("commit_msg"));
        assert!(err.message().contains("hard_debug"));
    }
}
