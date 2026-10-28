//! Non-streaming Chat Completions adapter for explicitly configured runtimes.
//!
//! Compatibility is deliberately limited to text and function tools. Runtime
//! parser/template selection and model capability checks belong to deployment
//! configuration; an HTTP-compatible endpoint alone does not establish them.

use std::collections::HashSet;
use std::time::Duration;

use farhelm_proto::types::Usage;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::dispatch::{DispatchError, ModelClient, ModelRequest, ModelResponse, Refusal, ToolCall};
use crate::prompt::{ContentBlock, Role};

const MAX_RESPONSE_BYTES: usize = 8 * 1024 * 1024;

pub struct OpenAiClient {
    endpoint: reqwest::Url,
    api_key: Option<String>,
    openrouter: bool,
    http: reqwest::Client,
}

impl OpenAiClient {
    pub fn new(
        base_url: &str,
        api_key: Option<String>,
        openrouter: bool,
    ) -> Result<Self, DispatchError> {
        let mut endpoint = reqwest::Url::parse(base_url)
            .map_err(|_| invalid("invalid Chat Completions base URL"))?;
        if !matches!(endpoint.scheme(), "http" | "https")
            || endpoint.host_str().is_none()
            || !endpoint.username().is_empty()
            || endpoint.password().is_some()
            || endpoint.query().is_some()
            || endpoint.fragment().is_some()
        {
            return Err(invalid(
                "Chat Completions base URL has unsupported components",
            ));
        }
        let path = endpoint.path().trim_end_matches('/');
        if !path.ends_with("/v1") {
            return Err(invalid("Chat Completions base URL must end in /v1"));
        }
        endpoint.set_path(&format!("{path}/chat/completions"));
        let api_key = api_key.filter(|key| !key.trim().is_empty());
        if api_key.as_ref().is_some_and(|key| {
            reqwest::header::HeaderValue::from_str(&format!("Bearer {key}")).is_err()
        }) {
            return Err(invalid("provider credential is not a valid HTTP header"));
        }
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(600))
            .connect_timeout(Duration::from_secs(15))
            .redirect(reqwest::redirect::Policy::none())
            // Ambient proxy configuration must not move a local-only request
            // to a different machine. Configure a trusted endpoint explicitly.
            .no_proxy()
            .build()
            .map_err(|_| DispatchError::Transport("could not initialize HTTP client".into()))?;
        Ok(Self {
            endpoint,
            api_key,
            openrouter,
            http,
        })
    }

    pub async fn complete(&self, request: ModelRequest) -> Result<ModelResponse, DispatchError> {
        let body = completion_params(&request, self.openrouter)?;
        let mut pending = self.http.post(self.endpoint.clone()).json(&body);
        if let Some(key) = &self.api_key {
            pending = pending.bearer_auth(key);
        }
        let mut response = pending.send().await.map_err(transport_error)?;
        let status = response.status();
        if !status.is_success() {
            // Provider errors can echo prompt content, credentials and upstream
            // URLs. The status remains useful without copying the remote body.
            return Err(DispatchError::Api {
                status: status.as_u16(),
                message: "Chat Completions request rejected".into(),
            });
        }
        if response
            .content_length()
            .is_some_and(|len| len > MAX_RESPONSE_BYTES as u64)
        {
            return Err(invalid("Chat Completions response exceeds byte limit"));
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(transport_error)? {
            if chunk.len() > MAX_RESPONSE_BYTES.saturating_sub(bytes.len()) {
                return Err(invalid("Chat Completions response exceeds byte limit"));
            }
            bytes.extend_from_slice(&chunk);
        }
        let parsed = parse_response(&bytes)?;
        for call in &parsed.tool_calls {
            if !request
                .plan
                .tools
                .iter()
                .any(|tool| tool["name"].as_str() == Some(&call.name))
            {
                return Err(invalid("response requested an undeclared tool"));
            }
            if request.plan.messages.iter().flat_map(|message| &message.content).any(|block| {
                matches!(block, ContentBlock::ToolUse(previous) if previous.call.id == call.id)
            }) {
                return Err(invalid("response reused a historical tool call ID"));
            }
        }
        Ok(parsed)
    }
}

impl ModelClient for OpenAiClient {
    async fn complete(&self, request: ModelRequest) -> Result<ModelResponse, DispatchError> {
        self.complete(request).await
    }

    fn supports_batch(&self) -> bool {
        false
    }
}

fn invalid(message: &str) -> DispatchError {
    DispatchError::Decode(message.into())
}

fn transport_error(error: reqwest::Error) -> DispatchError {
    let message = if error.is_timeout() {
        "Chat Completions request timed out"
    } else if error.is_connect() {
        "could not connect to Chat Completions endpoint"
    } else {
        "Chat Completions transport failed"
    };
    DispatchError::Transport(message.into())
}

fn valid_identifier(value: &str) -> bool {
    !value.trim().is_empty() && value.len() <= 256 && !value.chars().any(char::is_control)
}

fn tool_definition(definition: &Value) -> Result<Value, DispatchError> {
    let object = definition
        .as_object()
        .ok_or_else(|| invalid("tool definition must be an object"))?;
    if object.keys().any(|key| {
        !matches!(
            key.as_str(),
            "name" | "description" | "input_schema" | "cache_control"
        )
    }) {
        return Err(invalid("unsupported tool definition field"));
    }
    let name = definition
        .get("name")
        .and_then(Value::as_str)
        .filter(|name| valid_identifier(name))
        .ok_or_else(|| invalid("tool definition has no valid name"))?;
    let parameters = definition
        .get("input_schema")
        .filter(|value| value.is_object())
        .ok_or_else(|| invalid("tool definition has no object input schema"))?;
    let mut function = json!({ "name": name, "parameters": parameters });
    if let Some(description) = definition.get("description") {
        if !description.is_string() {
            return Err(invalid("tool description must be a string"));
        }
        function["description"] = description.clone();
    }
    Ok(json!({ "type": "function", "function": function }))
}

fn completion_params(request: &ModelRequest, openrouter: bool) -> Result<Value, DispatchError> {
    if request.model.trim().is_empty() || request.max_tokens == 0 {
        return Err(invalid(
            "model and positive output token limit are required",
        ));
    }
    let mut messages = Vec::new();
    let mut system = Vec::new();
    for block in &request.plan.system {
        if block.kind != "text" {
            return Err(invalid("unsupported system content block"));
        }
        system.push(block.text.as_str());
    }
    if !system.is_empty() {
        messages.push(json!({ "role": "system", "content": system.join("\n\n") }));
    }
    let mut used_ids = HashSet::new();
    let mut pending_ids = HashSet::new();
    for message in &request.plan.messages {
        let mut text = String::new();
        let mut reasoning = String::new();
        let mut calls = Vec::new();
        let mut results = Vec::new();
        for block in &message.content {
            match block {
                ContentBlock::Text(block) if block.kind == "text" => text.push_str(&block.text),
                ContentBlock::Reasoning(block) if message.role == Role::Assistant => {
                    reasoning.push_str(&block.text)
                }
                ContentBlock::ToolUse(block)
                    if block.kind == "tool_use" && message.role == Role::Assistant =>
                {
                    let call = &block.call;
                    if !valid_identifier(&call.id)
                        || !valid_identifier(&call.name)
                        || !call.input.is_object()
                    {
                        return Err(invalid("invalid historical tool call"));
                    }
                    if !used_ids.insert(call.id.clone()) {
                        return Err(invalid("duplicate historical tool call ID"));
                    }
                    calls.push(json!({
                        "id": call.id, "type": "function",
                        "function": { "name": call.name, "arguments": call.input.to_string() }
                    }));
                }
                ContentBlock::ToolResult(block)
                    if block.kind == "tool_result" && message.role == Role::User =>
                {
                    let result = &block.result;
                    if !pending_ids.remove(&result.tool_use_id) {
                        return Err(invalid("tool result has no matching pending call"));
                    }
                    // Chat Completions has no standard is_error field. Keep it
                    // in the tool's content instead of losing failure status.
                    results.push(json!({
                        "role": "tool", "tool_call_id": result.tool_use_id,
                        "content": json!({ "content": result.content, "is_error": result.is_error }).to_string()
                    }));
                }
                _ => return Err(invalid("unsupported message content block or role")),
            }
        }
        if !pending_ids.is_empty()
            && (!text.is_empty() || !calls.is_empty() || message.role == Role::Assistant)
        {
            return Err(invalid(
                "pending tool calls require matching results before continuation",
            ));
        }
        messages.extend(results);
        if message.role == Role::Assistant {
            let mut assistant = json!({ "role": "assistant", "content": if text.is_empty() { Value::Null } else { Value::String(text) } });
            // llama.cpp and vLLM read it back into the model's own reasoning
            // channel (gpt-oss's analysis), where its template expects it.
            if !reasoning.is_empty() {
                assistant["reasoning_content"] = Value::String(reasoning);
            }
            if !calls.is_empty() {
                for call in &calls {
                    pending_ids.insert(call["id"].as_str().unwrap().to_owned());
                }
                assistant["tool_calls"] = Value::Array(calls);
            }
            messages.push(assistant);
        } else if !text.is_empty() || message.content.is_empty() {
            messages.push(json!({ "role": "user", "content": text }));
        }
    }
    if !pending_ids.is_empty() {
        return Err(invalid("tool history ends before matching results"));
    }
    if request.plan.messages.is_empty() {
        return Err(invalid("at least one conversation message is required"));
    }
    let mut body = json!({
        "model": request.model, "messages": messages,
        "max_tokens": request.max_tokens, "stream": false
    });
    if !request.plan.tools.is_empty() {
        let mut names = HashSet::new();
        let tools = request
            .plan
            .tools
            .iter()
            .map(|definition| {
                let tool = tool_definition(definition)?;
                if !names.insert(tool["function"]["name"].as_str().unwrap().to_owned()) {
                    return Err(invalid("duplicate tool definition name"));
                }
                Ok(tool)
            })
            .collect::<Result<Vec<_>, DispatchError>>()?;
        body["tools"] = Value::Array(tools);
        body["tool_choice"] = json!("auto");
    }
    if openrouter {
        body["provider"] = json!({ "allow_fallbacks": false, "require_parameters": true });
    }
    // Gateway effort levels currently describe Anthropic routing. Passing them
    // through would imply unsupported per-model capability negotiation.
    Ok(body)
}

#[derive(Deserialize)]
struct WireResponse {
    model: String,
    choices: Vec<WireChoice>,
    usage: WireUsage,
    #[serde(default)]
    error: Option<Value>,
}

#[derive(Deserialize)]
struct WireChoice {
    message: WireMessage,
    finish_reason: String,
    #[serde(default)]
    error: Option<Value>,
}

#[derive(Deserialize)]
struct WireMessage {
    role: String,
    content: Option<String>,
    #[serde(default)]
    refusal: Option<String>,
    #[serde(default)]
    tool_calls: Vec<WireCall>,
    #[serde(default)]
    reasoning_details: Option<Value>,
    #[serde(default)]
    reasoning: Option<Value>,
    #[serde(default)]
    reasoning_content: Option<Value>,
    #[serde(default)]
    images: Option<Value>,
    #[serde(default)]
    audio: Option<Value>,
    #[serde(default)]
    function_call: Option<Value>,
}

#[derive(Deserialize)]
struct WireCall {
    id: String,
    #[serde(rename = "type")]
    kind: String,
    function: WireFunction,
}

#[derive(Deserialize)]
struct WireFunction {
    name: String,
    arguments: String,
}

#[derive(Deserialize)]
struct WireUsage {
    prompt_tokens: u32,
    completion_tokens: u32,
    #[serde(default)]
    prompt_tokens_details: Option<WirePromptDetails>,
}

#[derive(Default, Deserialize)]
struct WirePromptDetails {
    #[serde(default)]
    cached_tokens: u32,
    #[serde(default)]
    cache_write_tokens: u32,
}

fn nonempty(value: &Option<Value>) -> bool {
    match value {
        None | Some(Value::Null) => false,
        Some(Value::Array(values)) => !values.is_empty(),
        Some(Value::String(value)) => !value.is_empty(),
        Some(_) => true,
    }
}

fn parse_response(bytes: &[u8]) -> Result<ModelResponse, DispatchError> {
    let wire: WireResponse = serde_json::from_slice(bytes)
        .map_err(|_| invalid("invalid Chat Completions response shape or missing usage"))?;
    if wire.error.is_some() || wire.choices.len() != 1 {
        return Err(invalid(
            "Chat Completions must return one successful choice",
        ));
    }
    if !valid_identifier(&wire.model) {
        return Err(invalid("response has no valid actual model"));
    }
    let choice = wire.choices.into_iter().next().unwrap();
    if choice.error.is_some()
        || choice.finish_reason == "error"
        || choice.message.role != "assistant"
    {
        return Err(invalid(
            "Chat Completions returned an unsuccessful assistant choice",
        ));
    }
    let details = wire.usage.prompt_tokens_details.unwrap_or_default();
    let cached = details
        .cached_tokens
        .checked_add(details.cache_write_tokens)
        .ok_or_else(|| invalid("cached token usage overflow"))?;
    let input_tokens = wire
        .usage
        .prompt_tokens
        .checked_sub(cached)
        .ok_or_else(|| invalid("cached token usage exceeds total prompt tokens"))?;
    let message = choice.message;
    if nonempty(&message.images) || nonempty(&message.audio) || nonempty(&message.function_call) {
        return Err(invalid(
            "unsupported generated media or legacy function call",
        ));
    }
    // Reasoning that comes with tool calls must be replayed on the next turn.
    // A plain `reasoning_content` string (llama.cpp, vLLM) can be; structured
    // or differently named reasoning (OpenRouter's `reasoning_details`) needs
    // exact replay this adapter does not do, so it is still refused rather
    // than silently dropped.
    let mut reasoning = None;
    if !message.tool_calls.is_empty() {
        if nonempty(&message.reasoning_details) || nonempty(&message.reasoning) {
            return Err(invalid(
                "tool response requires unsupported reasoning block replay",
            ));
        }
        match &message.reasoning_content {
            Some(Value::String(text)) if !text.is_empty() => reasoning = Some(text.clone()),
            value if nonempty(value) => {
                return Err(invalid("reasoning_content must be a string"));
            }
            _ => {}
        }
    }
    let refusal = if message.refusal.is_some() || choice.finish_reason == "content_filter" {
        Some(Refusal {
            category: Some(choice.finish_reason.clone()),
            explanation: message.refusal,
        })
    } else {
        None
    };
    if refusal.is_some() && !message.tool_calls.is_empty() {
        return Err(invalid("refusal must not contain executable tool calls"));
    }
    let mut ids = HashSet::new();
    let mut tool_calls = Vec::new();
    for call in message.tool_calls {
        if call.kind != "function"
            || !valid_identifier(&call.id)
            || !valid_identifier(&call.function.name)
        {
            return Err(invalid("invalid response tool call identity or type"));
        }
        if !ids.insert(call.id.clone()) {
            return Err(invalid("duplicate response tool call ID"));
        }
        let input: Value = serde_json::from_str(&call.function.arguments)
            .map_err(|_| invalid("tool arguments must be complete JSON"))?;
        if !input.is_object() {
            return Err(invalid("tool arguments must be a JSON object"));
        }
        tool_calls.push(ToolCall {
            id: call.id,
            name: call.function.name,
            input,
        });
    }
    if (choice.finish_reason == "tool_calls") != !tool_calls.is_empty() {
        return Err(invalid("tool calls do not match finish reason"));
    }
    if !matches!(
        choice.finish_reason.as_str(),
        "stop" | "length" | "tool_calls" | "content_filter"
    ) {
        return Err(invalid("response has an unsupported finish reason"));
    }
    Ok(ModelResponse {
        text: if refusal.is_some() {
            String::new()
        } else {
            message.content.unwrap_or_default()
        },
        usage: Usage {
            input_tokens,
            output_tokens: wire.usage.completion_tokens,
            cache_read_tokens: details.cached_tokens,
            cache_write_tokens: details.cache_write_tokens,
        },
        model: wire.model,
        stop_reason: Some(choice.finish_reason),
        refusal,
        tool_calls,
        reasoning,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prompt::{Message, PromptPlan, TextBlock, ToolResult, Turn};
    use axum::{Json, Router, routing::post};

    fn request() -> ModelRequest {
        ModelRequest {
            model: "fixture-model".into(),
            max_tokens: 512,
            effort: Some(crate::dispatch::Effort::High),
            purpose: None,
            plan: PromptPlan {
                tools: vec![
                    json!({ "name": "read_file", "description": "Read", "input_schema": { "type": "object", "properties": { "path": { "type": "string" } } } }),
                ],
                system: vec![TextBlock {
                    kind: "text",
                    text: "Follow policy".into(),
                    cache_control: None,
                }],
                messages: vec![Message::from(&Turn::user("Read src/lib.rs"))],
                notes: vec![],
            },
        }
    }

    fn response() -> Value {
        json!({
            "model": "fixture-model-revision-2",
            "choices": [{ "finish_reason": "stop", "message": { "role": "assistant", "content": "Done" } }],
            "usage": { "prompt_tokens": 100, "completion_tokens": 20, "prompt_tokens_details": { "cached_tokens": 30, "cache_write_tokens": 10 }, "completion_tokens_details": { "reasoning_tokens": 5 } }
        })
    }

    fn tool_response() -> Value {
        let mut value = response();
        value["choices"][0]["finish_reason"] = json!("tool_calls");
        value["choices"][0]["message"]["content"] = Value::Null;
        value["choices"][0]["message"]["tool_calls"] = json!([
            { "id": "call_1", "type": "function", "function": { "name": "read_file", "arguments": "{\"path\":\"src/lib.rs\"}" } }
        ]);
        value
    }

    fn parse(value: &Value) -> Result<ModelResponse, DispatchError> {
        parse_response(&serde_json::to_vec(value).unwrap())
    }

    async fn serve(router: Router) -> (String, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}/v1", listener.local_addr().unwrap());
        let handle = tokio::spawn(async move {
            axum::serve(listener, router).await.unwrap();
        });
        (base, handle)
    }

    #[test]
    fn translates_tool_definition_without_anthropic_cache_controls() {
        let mut request = request();
        request.plan.tools[0]["cache_control"] = json!({ "type": "ephemeral" });
        let value = completion_params(&request, false).unwrap();
        assert_eq!(value["tools"][0]["type"], "function");
        assert_eq!(
            value["tools"][0]["function"]["parameters"],
            request.plan.tools[0]["input_schema"]
        );
        assert_eq!(value["tools"][0]["function"]["description"], "Read");
        assert!(value["tools"][0].get("cache_control").is_none());
        assert!(value.get("reasoning_effort").is_none());
        assert!(value.get("output_config").is_none());
        assert_eq!(value["stream"], false);
    }

    #[test]
    fn openrouter_disables_fallbacks_and_requires_parameter_support() {
        let value = completion_params(&request(), true).unwrap();
        assert_eq!(
            value["provider"],
            json!({ "allow_fallbacks": false, "require_parameters": true })
        );
        assert!(value.get("models").is_none());
    }

    #[test]
    fn unknown_or_missing_completion_semantics_are_not_success() {
        for finish in ["", "unknown", "error", "function_call", "pause_turn"] {
            let mut value = response();
            value["choices"][0]["finish_reason"] = json!(finish);
            assert!(parse(&value).is_err(), "{finish}");
        }
    }

    #[test]
    fn typed_tool_history_round_trips_ids_arguments_results_and_failure() {
        let mut request = request();
        request
            .plan
            .messages
            .push(Message::from(&Turn::assistant_with_tools(
                "Reading",
                vec![ToolCall {
                    id: "history_1".into(),
                    name: "read_file".into(),
                    input: json!({ "path": "src/lib.rs" }),
                }],
            )));
        request
            .plan
            .messages
            .push(Message::from(&Turn::user_with_results(
                "Continue",
                vec![ToolResult {
                    tool_use_id: "history_1".into(),
                    content: "Access denied".into(),
                    is_error: true,
                }],
            )));
        let value = completion_params(&request, false).unwrap();
        assert_eq!(value["messages"][2]["tool_calls"][0]["id"], "history_1");
        assert_eq!(
            value["messages"][2]["tool_calls"][0]["function"]["arguments"],
            "{\"path\":\"src/lib.rs\"}"
        );
        assert_eq!(value["messages"][3]["role"], "tool");
        assert_eq!(value["messages"][3]["tool_call_id"], "history_1");
        let result: Value =
            serde_json::from_str(value["messages"][3]["content"].as_str().unwrap()).unwrap();
        assert_eq!(
            result,
            json!({ "content": "Access denied", "is_error": true })
        );
        assert_eq!(
            value["messages"][4],
            json!({ "role": "user", "content": "Continue" })
        );
    }

    #[test]
    fn reasoning_before_a_tool_call_is_kept_and_sent_back() {
        // gpt-oss on llama.cpp: the analysis comes as `reasoning_content`
        // next to the call, and must return on the following request.
        let mut value = tool_response();
        value["choices"][0]["message"]["reasoning_content"] = json!("We need the file.");
        let parsed = parse(&value).unwrap();
        assert_eq!(parsed.reasoning.as_deref(), Some("We need the file."));

        // Without tool calls there is nothing to replay it for.
        let mut value = response();
        value["choices"][0]["message"]["reasoning_content"] = json!("Thinking.");
        assert_eq!(parse(&value).unwrap().reasoning, None);

        let mut request = request();
        let turn = Turn::assistant_with_tools(
            "",
            vec![ToolCall {
                id: "history_1".into(),
                name: "read_file".into(),
                input: json!({ "path": "src/lib.rs" }),
            }],
        )
        .with_reasoning(parsed.reasoning);
        request.plan.messages.push(Message::from(&turn));
        request
            .plan
            .messages
            .push(Message::from(&Turn::user_with_results(
                "",
                vec![ToolResult {
                    tool_use_id: "history_1".into(),
                    content: "fn main() {}".into(),
                    is_error: false,
                }],
            )));
        let body = completion_params(&request, false).unwrap();
        assert_eq!(
            body["messages"][2]["reasoning_content"],
            "We need the file."
        );
        assert_eq!(body["messages"][2]["tool_calls"][0]["id"], "history_1");
        // Anthropic's request leaves it out: its thinking blocks need its own
        // signatures.
        let anthropic = crate::dispatch::messages_params(&request);
        assert!(!anthropic.to_string().contains("We need the file."));
    }

    #[test]
    fn rejects_orphan_results_unanswered_calls_and_duplicate_history_ids() {
        let mut request = request();
        request
            .plan
            .messages
            .push(Message::from(&Turn::user_with_results(
                "",
                vec![ToolResult {
                    tool_use_id: "missing".into(),
                    content: "oops".into(),
                    is_error: false,
                }],
            )));
        assert!(completion_params(&request, false).is_err());
        request.plan.messages.pop();
        let assistant = Message::from(&Turn::assistant_with_tools(
            "",
            vec![ToolCall {
                id: "call".into(),
                name: "read_file".into(),
                input: json!({}),
            }],
        ));
        request.plan.messages.push(assistant.clone());
        assert!(completion_params(&request, false).is_err());
        request
            .plan
            .messages
            .push(Message::from(&Turn::user_with_results(
                "",
                vec![ToolResult {
                    tool_use_id: "call".into(),
                    content: "OK".into(),
                    is_error: false,
                }],
            )));
        request.plan.messages.push(assistant);
        assert!(completion_params(&request, false).is_err());
    }

    #[test]
    fn rejects_unknown_tool_definition_and_content_types() {
        let mut request = request();
        request.plan.tools[0]["type"] = json!("computer_20250124");
        assert!(completion_params(&request, false).is_err());
        request.plan.tools[0]
            .as_object_mut()
            .unwrap()
            .remove("type");
        request.plan.system[0].kind = "image";
        assert!(completion_params(&request, false).is_err());
    }

    #[test]
    fn preserves_actual_model_finish_reason_and_partitions_cache_tokens() {
        let parsed = parse(&response()).unwrap();
        assert_eq!(parsed.model, "fixture-model-revision-2");
        assert_eq!(parsed.stop_reason.as_deref(), Some("stop"));
        assert_eq!(
            parsed.usage,
            Usage {
                input_tokens: 60,
                output_tokens: 20,
                cache_read_tokens: 30,
                cache_write_tokens: 10
            }
        );
        assert_eq!(parsed.text, "Done");
    }

    #[test]
    fn parses_complete_tool_arguments_and_preserves_tool_finish_reason() {
        let parsed = parse(&tool_response()).unwrap();
        assert_eq!(parsed.stop_reason.as_deref(), Some("tool_calls"));
        assert_eq!(
            parsed.tool_calls,
            vec![ToolCall {
                id: "call_1".into(),
                name: "read_file".into(),
                input: json!({ "path": "src/lib.rs" })
            }]
        );
        assert_eq!(parsed.text, "");
    }

    #[test]
    fn rejects_incomplete_nonobject_and_mismatched_tool_calls() {
        for arguments in ["{\"path\":", "[]", "null", "\"bash\""] {
            let mut value = tool_response();
            value["choices"][0]["message"]["tool_calls"][0]["function"]["arguments"] =
                json!(arguments);
            assert!(parse(&value).is_err(), "{arguments}");
        }
        let mut value = tool_response();
        value["choices"][0]["finish_reason"] = json!("length");
        assert!(parse(&value).is_err());
        let mut value = response();
        value["choices"][0]["finish_reason"] = json!("tool_calls");
        assert!(parse(&value).is_err());
    }

    #[test]
    fn rejects_missing_or_duplicate_tool_ids() {
        let mut value = tool_response();
        value["choices"][0]["message"]["tool_calls"][0]
            .as_object_mut()
            .unwrap()
            .remove("id");
        assert!(parse(&value).is_err());
        let mut value = tool_response();
        let call = value["choices"][0]["message"]["tool_calls"][0].clone();
        value["choices"][0]["message"]["tool_calls"]
            .as_array_mut()
            .unwrap()
            .push(call);
        assert!(parse(&value).is_err());
    }

    #[test]
    fn missing_or_impossible_usage_fails_without_inventing_zero_cost() {
        let mut value = response();
        value.as_object_mut().unwrap().remove("usage");
        assert!(parse(&value).is_err());
        let mut value = response();
        value["usage"]["prompt_tokens"] = json!(1);
        assert!(parse(&value).is_err());
        let mut value = response();
        value["usage"]["completion_tokens"] = json!(-1);
        assert!(parse(&value).is_err());
    }

    #[test]
    fn refusal_is_truthful_and_never_executes_tools() {
        let mut value = response();
        value["choices"][0]["message"]["refusal"] = json!("Cannot comply");
        let parsed = parse(&value).unwrap();
        assert!(parsed.refusal.is_some());
        assert!(parsed.text.is_empty());
        let mut value = tool_response();
        value["choices"][0]["message"]["refusal"] = json!("Cannot comply");
        assert!(parse(&value).is_err());
        let mut value = response();
        value["choices"][0]["finish_reason"] = json!("content_filter");
        assert!(parse(&value).unwrap().refusal.is_some());
    }

    #[test]
    fn rejects_error_choices_media_and_required_reasoning_replay() {
        for (field, value) in [
            ("audio", json!({ "data": "secret" })),
            ("images", json!(["image"])),
            ("function_call", json!({ "name": "exec" })),
        ] {
            let mut response = response();
            response["choices"][0]["message"][field] = value;
            assert!(parse(&response).is_err());
        }
        // Reasoning this adapter cannot replay exactly is refused, never
        // dropped.
        for field in ["reasoning_details", "reasoning"] {
            let mut value = tool_response();
            value["choices"][0]["message"][field] = json!("private reasoning state");
            assert!(parse(&value).is_err());
            value["choices"][0]["message"][field] = json!("");
            assert!(parse(&value).is_ok());
        }
        let mut value = tool_response();
        value["choices"][0]["message"]["reasoning_content"] = json!({ "encrypted": "x" });
        assert!(parse(&value).is_err());
        let mut value = response();
        value["choices"][0]["error"] = json!({ "message": "secret upstream body" });
        assert!(!parse(&value).unwrap_err().to_string().contains("secret"));
    }

    #[test]
    fn validates_base_url_without_echoing_credentials() {
        for base in [
            "file:///tmp/v1",
            "https://secret:password@example.com/v1",
            "https://example.com/v1?key=secret",
            "https://example.com/v1#secret",
            "not-a-url",
            "https://example.com/api",
        ] {
            let error = match OpenAiClient::new(base, None, false) {
                Ok(_) => panic!("accepted {base}"),
                Err(error) => error,
            };
            assert!(!error.to_string().contains("password"));
        }
        assert!(OpenAiClient::new("http://localhost:11434/v1/", None, false).is_ok());
        assert!(OpenAiClient::new("https://openrouter.ai/api/v1", None, true).is_ok());
        assert!(OpenAiClient::new("http://localhost/v1", Some("bad\nkey".into()), false).is_err());
    }

    #[tokio::test]
    async fn sends_authenticated_request_to_chat_completions_endpoint() {
        let (sender, receiver) = tokio::sync::oneshot::channel();
        let sender = std::sync::Arc::new(std::sync::Mutex::new(Some(sender)));
        let router = Router::new().route(
            "/v1/chat/completions",
            post(
                move |headers: axum::http::HeaderMap, Json(body): Json<Value>| {
                    let sender = sender.clone();
                    async move {
                        sender
                            .lock()
                            .unwrap()
                            .take()
                            .unwrap()
                            .send((headers, body))
                            .unwrap();
                        Json(response())
                    }
                },
            ),
        );
        let (base, handle) = serve(router).await;
        let client = OpenAiClient::new(&base, Some("fixture-key".into()), false).unwrap();
        let parsed = client.complete(request()).await.unwrap();
        handle.abort();
        let (headers, body) = receiver.await.unwrap();
        assert_eq!(headers["authorization"], "Bearer fixture-key");
        assert_eq!(body["model"], "fixture-model");
        assert_eq!(parsed.model, "fixture-model-revision-2");
        assert!(!client.supports_batch());
    }

    #[tokio::test]
    async fn does_not_follow_redirects_or_copy_remote_error_body() {
        let router = Router::new().route(
            "/v1/chat/completions",
            post(|| async {
                (
                    axum::http::StatusCode::TEMPORARY_REDIRECT,
                    [("location", "http://localhost:1/stolen")],
                    "secret provider prompt echo",
                )
            }),
        );
        let (base, handle) = serve(router).await;
        let client = OpenAiClient::new(&base, Some("fixture-key".into()), false).unwrap();
        let error = client.complete(request()).await.unwrap_err();
        handle.abort();
        assert!(matches!(error, DispatchError::Api { status: 307, .. }));
        assert!(!error.to_string().contains("secret"));
        assert!(!error.to_string().contains("fixture-key"));
    }

    #[tokio::test]
    async fn rejects_oversized_response() {
        let router = Router::new().route(
            "/v1/chat/completions",
            post(|| async { "x".repeat(MAX_RESPONSE_BYTES + 1) }),
        );
        let (base, handle) = serve(router).await;
        let error = OpenAiClient::new(&base, None, false)
            .unwrap()
            .complete(request())
            .await
            .unwrap_err();
        handle.abort();
        assert!(error.to_string().contains("byte limit"));
    }

    #[tokio::test]
    async fn undeclared_tools_are_rejected_before_execution() {
        let router = Router::new().route(
            "/v1/chat/completions",
            post(|| async { Json(tool_response()) }),
        );
        let (base, handle) = serve(router).await;
        let mut request = request();
        request.plan.tools.clear();
        let error = OpenAiClient::new(&base, None, false)
            .unwrap()
            .complete(request)
            .await
            .unwrap_err();
        handle.abort();
        assert!(error.to_string().contains("undeclared tool"));
    }

    #[tokio::test]
    async fn reused_historical_call_ids_are_rejected_before_execution() {
        let router = Router::new().route(
            "/v1/chat/completions",
            post(|| async { Json(tool_response()) }),
        );
        let (base, handle) = serve(router).await;
        let mut request = request();
        request
            .plan
            .messages
            .push(Message::from(&Turn::assistant_with_tools(
                "",
                vec![ToolCall {
                    id: "call_1".into(),
                    name: "read_file".into(),
                    input: json!({ "path": "src/lib.rs" }),
                }],
            )));
        request
            .plan
            .messages
            .push(Message::from(&Turn::user_with_results(
                "Continue",
                vec![ToolResult {
                    tool_use_id: "call_1".into(),
                    content: "OK".into(),
                    is_error: false,
                }],
            )));
        let error = OpenAiClient::new(&base, None, false)
            .unwrap()
            .complete(request)
            .await
            .unwrap_err();
        handle.abort();
        assert!(error.to_string().contains("historical tool call ID"));
    }
}
