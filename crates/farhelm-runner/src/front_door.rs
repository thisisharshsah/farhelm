//! The front door: other projects' model calls, through Farhelm.
//!
//! Each API client (see [`crate::clients`]) has an address shaped like the
//! private gateway it replaces, so moving a project is a change of port:
//!
//! ```text
//! OpenAI-style:    http://127.0.0.1:7842/p/<client>/v1
//! Anthropic-style: http://127.0.0.1:7842/p/<client>        (the SDK adds /v1/messages)
//! ```
//!
//! Every call goes through the gateway like the runner's own: the
//! `local_only` check, the response cache (kept apart per client), the ledger
//! (recorded under the client's session) and the engine. On top of that a
//! client may be held to some models and a number of tokens a day.
//!
//! What a client asks for and does not get, said plainly:
//!
//! - **Model names.** A model the registry declares is used if the client may
//!   use it, and refused if not. An empty or undeclared name is served by the
//!   client's default model (the private gateway behaved the same way), and
//!   the response's `model` says what actually ran.
//! - **Sampling.** `temperature`, `top_p`, `seed` and similar are accepted and
//!   not applied; the gateway owns those. `max_tokens` is bounded by the
//!   registry's limit for the model.
//! - **Streaming.** As for `/v1/messages`: the gateway answers in one piece,
//!   and a streamed response carries it as one correctly framed delta.
//! - **Images and audio** are refused, never dropped.

use std::sync::Arc;

use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response, Sse, sse::Event},
    routing::{get, post},
};
use farhelm_gateway::{
    CompleteRequest, GatewayError, ToolCall,
    prompt::{ToolResult, Turn},
};
use farhelm_proto::types::TaskType;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::api::ApiError;
use crate::clients::{self, Client, ClientsFile};
use crate::messages::{self, MessagesBody};
use crate::state::AppState;

struct FrontDoor {
    app: Arc<AppState>,
    clients: ClientsFile,
    /// The registry's model names, to tell a declared model from a name the
    /// client's previous gateway used.
    models: Vec<String>,
}

pub fn router(app: Arc<AppState>, clients: ClientsFile) -> Router {
    let models = app
        .gateway
        .as_ref()
        .map(|gateway| gateway.client().model_aliases())
        .unwrap_or_default();
    Router::new()
        .route("/p/{client}/v1/models", get(list_models))
        .route("/p/{client}/v1/chat/completions", post(chat_completions))
        .route("/p/{client}/v1/messages", post(anthropic_messages))
        // Long tool histories, not uploads: media is refused anyway.
        .layer(DefaultBodyLimit::max(8 * 1024 * 1024))
        .with_state(Arc::new(FrontDoor {
            app,
            clients,
            models,
        }))
}

/// Problems with a client's configuration that would otherwise surface as a
/// confusing refusal on the first request: a default model the registry does
/// not declare, or one the client may not use.
pub fn check(clients: &ClientsFile, models: &[String]) -> Vec<String> {
    let mut problems = Vec::new();
    for (name, client) in &clients.clients {
        if let Some(model) = &client.default_model {
            if !models.is_empty() && !models.contains(model) {
                problems.push(format!(
                    "client {name}: default model {model} is not in the registry"
                ));
            } else if !client.allows(model) {
                problems.push(format!(
                    "client {name}: may not use its own default model {model}"
                ));
            }
        }
    }
    problems
}

/// An OpenAI-shaped error, which is what clients of this address parse.
#[derive(Debug)]
struct DoorError {
    status: StatusCode,
    message: String,
}

impl DoorError {
    fn new(status: StatusCode, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }
}

impl From<ApiError> for DoorError {
    fn from(err: ApiError) -> Self {
        Self::new(err.status(), err.message().to_owned())
    }
}

impl IntoResponse for DoorError {
    fn into_response(self) -> Response {
        let kind = match self.status {
            StatusCode::UNAUTHORIZED => "authentication_error",
            StatusCode::FORBIDDEN => "permission_error",
            StatusCode::TOO_MANY_REQUESTS => "rate_limit_error",
            status if status.is_client_error() => "invalid_request_error",
            _ => "api_error",
        };
        (
            self.status,
            Json(json!({ "error": { "message": self.message, "type": kind, "code": null } })),
        )
            .into_response()
    }
}

fn presented_key(headers: &HeaderMap) -> Option<String> {
    let bearer = headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(str::trim);
    let api_key = headers
        .get("x-api-key")
        .and_then(|value| value.to_str().ok())
        .map(str::trim);
    bearer.or(api_key).map(str::to_owned)
}

impl FrontDoor {
    fn client(&self, name: &str, headers: &HeaderMap) -> Result<&Client, DoorError> {
        self.clients
            .authenticate(name, presented_key(headers).as_deref())
            .ok_or_else(|| {
                DoorError::new(
                    StatusCode::UNAUTHORIZED,
                    "unknown client or wrong key; send the client's key as \
                     'Authorization: Bearer <key>' or 'x-api-key'",
                )
            })
    }

    /// Which model serves this request. See the module docs.
    fn model_for(&self, client: &Client, requested: &str) -> Result<Option<String>, DoorError> {
        if !requested.is_empty() && self.models.iter().any(|model| model == requested) {
            if !client.allows(requested) {
                return Err(DoorError::new(
                    StatusCode::FORBIDDEN,
                    format!("this client may not use {requested}"),
                ));
            }
            return Ok(Some(requested.to_owned()));
        }
        Ok(client.default_model.clone())
    }

    /// Refuse a call once the client's daily allowance is spent. Counted per
    /// UTC day from the ledger, so it includes every model and endpoint.
    fn within_limit(&self, name: &str, client: &Client) -> Result<(), DoorError> {
        let Some(limit) = client.daily_token_limit else {
            return Ok(());
        };
        let now = farhelm_app::time::now_ms();
        let day_start = now - now.rem_euclid(24 * 60 * 60 * 1000);
        let used = self
            .app
            .store
            .session_tokens_since(&clients::session_id(name), day_start)
            .map_err(|err| DoorError::new(StatusCode::INTERNAL_SERVER_ERROR, err.to_string()))?;
        if used >= limit {
            return Err(DoorError::new(
                StatusCode::TOO_MANY_REQUESTS,
                format!("this client has used {used} of its {limit} tokens today (UTC)"),
            ));
        }
        Ok(())
    }

    /// Bill to the client, keep its cache to itself, use its model, and fill
    /// in its default reasoning effort when the request set none.
    fn scope(
        &self,
        name: &str,
        client: &Client,
        request: &mut CompleteRequest,
        model: Option<String>,
    ) {
        request.session_id = clients::session_id(name);
        request.cache_scope = Some(format!("client:{name}"));
        request.model = model;
        if request.sampling.reasoning_effort.is_none() {
            request.sampling.reasoning_effort = client.default_effort.clone();
        }
    }
}

async fn list_models(
    State(door): State<Arc<FrontDoor>>,
    Path(name): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Value>, DoorError> {
    let client = door.client(&name, &headers)?;
    let data: Vec<Value> = door
        .models
        .iter()
        .filter(|model| client.allows(model))
        .map(|model| json!({ "id": model, "object": "model", "owned_by": "farhelm" }))
        .collect();
    Ok(Json(json!({ "object": "list", "data": data })))
}

/* ------------------------------------------------------- Anthropic style */

async fn anthropic_messages(
    State(door): State<Arc<FrontDoor>>,
    Path(name): Path<String>,
    headers: HeaderMap,
    Json(body): Json<MessagesBody>,
) -> Result<Response, DoorError> {
    let client = door.client(&name, &headers)?;
    door.within_limit(&name, client)?;
    let model = door.model_for(client, &body.model)?;
    let stream = body.stream;
    let max_tokens = body.max_tokens;
    let mut request = messages::translate(&headers, body)?;
    request.max_tokens = max_tokens;
    door.scope(&name, client, &mut request, model);
    Ok(messages::answer(&door.app, request, stream).await?)
}

/* ----------------------------------------------------------- OpenAI style */

#[derive(Debug, Deserialize)]
struct ChatBody {
    #[serde(default)]
    model: String,
    messages: Vec<ChatMessage>,
    #[serde(default)]
    tools: Vec<Value>,
    #[serde(default)]
    stream: bool,
    #[serde(default)]
    max_tokens: Option<u32>,
    #[serde(default)]
    max_completion_tokens: Option<u32>,
    #[serde(default)]
    temperature: Option<f32>,
    #[serde(default)]
    top_p: Option<f32>,
    /// OpenAI's name for it.
    #[serde(default)]
    reasoning_effort: Option<String>,
    /// llama.cpp's and the private gateway's way of passing it.
    #[serde(default)]
    chat_template_kwargs: Option<Value>,
}

#[derive(Debug, Deserialize)]
struct ChatMessage {
    role: String,
    #[serde(default)]
    content: Option<Value>,
    #[serde(default)]
    tool_calls: Vec<ChatToolCall>,
    #[serde(default)]
    tool_call_id: Option<String>,
    /// A reasoning model's analysis from the previous turn, sent back so the
    /// model sees it before its own tool call (gpt-oss needs this).
    #[serde(default)]
    reasoning_content: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ChatToolCall {
    id: String,
    function: ChatFunction,
}

#[derive(Debug, Deserialize)]
struct ChatFunction {
    name: String,
    arguments: String,
}

fn unprocessable(message: impl Into<String>) -> DoorError {
    DoorError::new(StatusCode::UNPROCESSABLE_ENTITY, message)
}

/// Text from a message's content: a string, or text parts.
fn text_of(content: &Option<Value>) -> Result<String, DoorError> {
    match content {
        None | Some(Value::Null) => Ok(String::new()),
        Some(Value::String(text)) => Ok(text.clone()),
        Some(Value::Array(parts)) => {
            let mut text = String::new();
            for part in parts {
                match part.get("type").and_then(Value::as_str) {
                    Some("text") => {
                        text.push_str(part.get("text").and_then(Value::as_str).unwrap_or_default())
                    }
                    other => {
                        return Err(unprocessable(format!(
                            "content part `{}` is not supported; only text is",
                            other.unwrap_or("unknown")
                        )));
                    }
                }
            }
            Ok(text)
        }
        Some(_) => Err(unprocessable(
            "message content must be a string or text parts",
        )),
    }
}

/// An OpenAI function tool as the gateway's tool definition.
fn tool_definition(tool: &Value) -> Result<Value, DoorError> {
    let function = tool
        .get("function")
        .filter(|_| tool.get("type").and_then(Value::as_str) == Some("function"))
        .ok_or_else(|| unprocessable("only function tools are supported"))?;
    let name = function
        .get("name")
        .and_then(Value::as_str)
        .ok_or_else(|| unprocessable("a tool needs a name"))?;
    let mut definition = json!({
        "name": name,
        "input_schema": function.get("parameters").cloned().unwrap_or_else(|| json!({ "type": "object" })),
    });
    if let Some(description) = function.get("description") {
        definition["description"] = description.clone();
    }
    Ok(definition)
}

fn translate_chat(body: &ChatBody) -> Result<CompleteRequest, DoorError> {
    let mut system = Vec::new();
    let mut turns: Vec<Turn> = Vec::new();
    for message in &body.messages {
        match message.role.as_str() {
            "system" | "developer" => system.push(text_of(&message.content)?),
            "user" => {
                let text = text_of(&message.content)?;
                // Prose after tool results belongs to the same user turn.
                match turns.last_mut() {
                    Some(turn)
                        if turn.role == farhelm_gateway::prompt::Role::User
                            && turn.text.is_empty()
                            && !turn.tool_results.is_empty() =>
                    {
                        turn.text = text;
                    }
                    _ => turns.push(Turn::user(text)),
                }
            }
            "assistant" => {
                let calls = message
                    .tool_calls
                    .iter()
                    .map(|call| {
                        let input: Value = serde_json::from_str(&call.function.arguments)
                            .map_err(|_| unprocessable("tool call arguments must be JSON"))?;
                        Ok(ToolCall {
                            id: call.id.clone(),
                            name: call.function.name.clone(),
                            input,
                        })
                    })
                    .collect::<Result<Vec<_>, DoorError>>()?;
                turns.push(
                    Turn::assistant_with_tools(text_of(&message.content)?, calls)
                        .with_reasoning(message.reasoning_content.clone()),
                );
            }
            "tool" => {
                let result = ToolResult {
                    tool_use_id: message
                        .tool_call_id
                        .clone()
                        .ok_or_else(|| unprocessable("a tool message needs tool_call_id"))?,
                    content: text_of(&message.content)?,
                    // Chat Completions has no error flag; the text says it.
                    is_error: false,
                };
                match turns.last_mut() {
                    Some(turn)
                        if turn.role == farhelm_gateway::prompt::Role::User
                            && turn.text.is_empty() =>
                    {
                        turn.tool_results.push(result);
                    }
                    _ => turns.push(Turn::user_with_results("", vec![result])),
                }
            }
            other => {
                return Err(unprocessable(format!(
                    "message role `{other}` is not supported"
                )));
            }
        }
    }
    messages::validate_tool_pairs(&turns)?;
    let last = turns
        .pop()
        .filter(|turn| turn.role == farhelm_gateway::prompt::Role::User)
        .ok_or_else(|| {
            unprocessable("the last message must be from the user or a tool; assistant prefill is not supported")
        })?;
    // Edit is the honest default for an unlabelled call, as on /v1/messages.
    let mut request = CompleteRequest::new("", TaskType::Edit, last.text);
    request.tool_results = last.tool_results;
    request.stable.system = system.join("\n\n");
    request.stable.history = turns;
    request.stable.tools = body
        .tools
        .iter()
        .map(tool_definition)
        .collect::<Result<_, _>>()?;
    request.max_tokens = body.max_completion_tokens.or(body.max_tokens);
    request.sampling.temperature = body.temperature;
    request.sampling.top_p = body.top_p;
    request.sampling.reasoning_effort = body.reasoning_effort.clone().or_else(|| {
        body.chat_template_kwargs
            .as_ref()
            .and_then(|kwargs| kwargs.get("reasoning_effort"))
            .and_then(Value::as_str)
            .map(str::to_owned)
    });
    Ok(request)
}

async fn chat_completions(
    State(door): State<Arc<FrontDoor>>,
    Path(name): Path<String>,
    headers: HeaderMap,
    Json(body): Json<ChatBody>,
) -> Result<Response, DoorError> {
    let client = door.client(&name, &headers)?;
    door.within_limit(&name, client)?;
    let model = door.model_for(client, &body.model)?;
    let mut request = translate_chat(&body)?;
    door.scope(&name, client, &mut request, model);

    messages::ensure_bucket(&door.app, &request.session_id)?;
    let gateway = door.app.gateway.as_ref().ok_or_else(|| {
        DoorError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "no model provider is configured on this runner",
        )
    })?;
    let response = gateway.complete(request).await.map_err(|err| match err {
        GatewayError::BudgetExhausted { .. } => {
            DoorError::new(StatusCode::PAYMENT_REQUIRED, err.to_string())
        }
        GatewayError::Dispatch(_) => DoorError::new(StatusCode::BAD_GATEWAY, err.to_string()),
        other => DoorError::new(StatusCode::INTERNAL_SERVER_ERROR, other.to_string()),
    })?;

    let has_tools = !response.tool_calls.is_empty();
    let truncated = matches!(
        response.stop_reason.as_deref(),
        Some("max_tokens" | "length" | "model_context_window_exceeded")
    );
    if has_tools && truncated {
        return Err(DoorError::new(
            StatusCode::BAD_GATEWAY,
            "the model's answer was cut off inside a tool call; no call was returned",
        ));
    }
    let finish_reason = if has_tools {
        "tool_calls"
    } else if response.refusal.is_some() {
        "content_filter"
    } else if truncated {
        "length"
    } else {
        "stop"
    };
    let tool_calls: Vec<Value> = response
        .tool_calls
        .iter()
        .map(|call| {
            json!({
                "id": call.id, "type": "function",
                "function": { "name": call.name, "arguments": call.input.to_string() },
            })
        })
        .collect();
    let mut message = json!({
        "role": "assistant",
        "content": if response.text.is_empty() && has_tools { Value::Null } else { Value::String(response.text.clone()) },
    });
    if has_tools {
        message["tool_calls"] = Value::Array(tool_calls.clone());
    }
    if let Some(reasoning) = &response.reasoning {
        message["reasoning_content"] = Value::String(reasoning.clone());
    }
    let id = format!("chatcmpl-{}", farhelm_app::id::new_id());
    let created = farhelm_app::time::now_ms() / 1000;
    let prompt_tokens = response.usage.input_tokens
        + response.usage.cache_read_tokens
        + response.usage.cache_write_tokens;
    let usage = json!({
        "prompt_tokens": prompt_tokens,
        "completion_tokens": response.usage.output_tokens,
        "total_tokens": prompt_tokens + response.usage.output_tokens,
        "prompt_tokens_details": { "cached_tokens": response.usage.cache_read_tokens },
    });

    if !body.stream {
        return Ok(Json(json!({
            "id": id, "object": "chat.completion", "created": created,
            "model": response.model,
            "choices": [{ "index": 0, "message": message, "finish_reason": finish_reason }],
            "usage": usage,
        }))
        .into_response());
    }

    // One delta with the whole answer, then the finish, then [DONE].
    let mut delta = message.clone();
    if let Some(calls) = delta.get_mut("tool_calls").and_then(Value::as_array_mut) {
        for (index, call) in calls.iter_mut().enumerate() {
            call["index"] = json!(index);
        }
    }
    let chunk = |delta: Value, finish: Value, usage: Value| {
        json!({
            "id": id, "object": "chat.completion.chunk", "created": created,
            "model": response.model,
            "choices": [{ "index": 0, "delta": delta, "finish_reason": finish }],
            "usage": usage,
        })
        .to_string()
    };
    let events = vec![
        Ok::<_, std::convert::Infallible>(Event::default().data(chunk(
            delta,
            Value::Null,
            Value::Null,
        ))),
        Ok(Event::default().data(chunk(json!({}), json!(finish_reason), usage))),
        Ok(Event::default().data("[DONE]")),
    ];
    Ok(Sse::new(futures_util::stream::iter(events)).into_response())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn body(value: Value) -> ChatBody {
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn a_tool_conversation_becomes_history_and_a_pending_result() {
        let request = translate_chat(&body(json!({
            "model": "gpt-oss-20b",
            "messages": [
                { "role": "system", "content": "Be brief." },
                { "role": "user", "content": [{ "type": "text", "text": "Look up alpha." }] },
                { "role": "assistant", "content": null, "reasoning_content": "Need the tool.",
                  "tool_calls": [{ "id": "c1", "type": "function",
                                   "function": { "name": "lookup", "arguments": "{\"key\":\"alpha\"}" } }] },
                { "role": "tool", "tool_call_id": "c1", "content": "42" },
            ],
            "tools": [{ "type": "function", "function": { "name": "lookup", "description": "Find a value.",
                        "parameters": { "type": "object", "properties": { "key": { "type": "string" } } } } }],
        })))
        .unwrap();
        assert_eq!(request.stable.system, "Be brief.");
        assert_eq!(request.stable.history.len(), 2);
        assert_eq!(
            request.stable.history[1].reasoning.as_deref(),
            Some("Need the tool.")
        );
        assert_eq!(
            request.stable.history[1].tool_calls[0].input,
            json!({ "key": "alpha" })
        );
        assert_eq!(request.tool_results.len(), 1);
        assert_eq!(request.tool_results[0].content, "42");
        assert_eq!(request.stable.tools[0]["name"], "lookup");
        assert_eq!(request.stable.tools[0]["input_schema"]["type"], "object");
    }

    #[test]
    fn the_callers_sampling_and_ceiling_are_kept() {
        let request = translate_chat(&body(json!({
            "messages": [{ "role": "user", "content": "hi" }],
            "max_tokens": 900, "max_completion_tokens": 700, "temperature": 0.2,
            "chat_template_kwargs": { "reasoning_effort": "high" },
        })))
        .unwrap();
        assert_eq!(request.max_tokens, Some(700));
        assert_eq!(request.sampling.temperature, Some(0.2));
        assert_eq!(request.sampling.reasoning_effort.as_deref(), Some("high"));
    }

    #[test]
    fn media_prefill_and_orphan_results_are_refused() {
        let image = body(
            json!({ "messages": [{ "role": "user", "content": [{ "type": "image_url", "image_url": { "url": "x" } }] }] }),
        );
        assert!(translate_chat(&image).is_err());
        let prefill = body(json!({ "messages": [
            { "role": "user", "content": "hi" }, { "role": "assistant", "content": "Sure" } ] }));
        assert!(translate_chat(&prefill).is_err());
        let orphan = body(
            json!({ "messages": [{ "role": "tool", "tool_call_id": "nope", "content": "x" }] }),
        );
        assert!(translate_chat(&orphan).is_err());
    }

    #[test]
    fn a_misconfigured_default_model_is_reported() {
        let mut file = ClientsFile::default();
        file.clients.insert(
            "everest".into(),
            Client {
                key_sha256: "0".repeat(64),
                default_model: Some("gpt-oss-120b".into()),
                models: Vec::new(),
                daily_token_limit: None,
                default_effort: None,
            },
        );
        let problems = check(&file, &["gpt-oss-20b".into()]);
        assert_eq!(problems.len(), 1);
        assert!(problems[0].contains("not in the registry"));
    }
}
