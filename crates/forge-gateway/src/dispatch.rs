//! Pipeline stage 7 — dispatch.
//!
//! One trait so the pipeline can be exercised without a network or an API key,
//! plus the real Anthropic Messages API client. There is no official Rust SDK,
//! so this speaks raw HTTP against `/v1/messages`.
//!
//! Three provider details this encodes deliberately:
//!  - **`stop_reason` is checked before `content` is read.** A safety-classifier
//!    decline returns HTTP 200 with an empty `content` array; code that indexes
//!    `content[0]` panics on it.
//!  - **Server-side fallbacks are on by default.** A refusal in the middle of an
//!    agent loop stalls the agent; `fallbacks: "default"` lets the API re-serve
//!    the request on another model in the same call.
//!  - **No sampling parameters are ever sent.** `temperature`, `top_p` and
//!    `top_k` are rejected outright by the current models.

use std::sync::Mutex;
use std::time::Duration;

use forge_proto::types::Usage;
use serde::{Deserialize, Serialize};

use crate::prompt::{PromptPlan, approx_tokens};

/// Non-streaming ceiling. Above roughly this, requests risk the provider's HTTP
/// timeout and must stream instead — a change for when the gateway learns to
/// forward a stream to the agent.
pub const DEFAULT_MAX_TOKENS: u32 = 16_000;

pub const ANTHROPIC_VERSION: &str = "2023-06-01";
/// Gates the `fallbacks: "default"` scalar form specifically. The array form
/// uses an earlier, different header — pairing either with the other is a 400.
pub const FALLBACK_BETA: &str = "server-side-fallback-2026-07-01";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Effort {
    Low,
    Medium,
    High,
    #[serde(rename = "xhigh")]
    XHigh,
    Max,
}

impl Effort {
    pub const fn as_str(self) -> &'static str {
        match self {
            Effort::Low => "low",
            Effort::Medium => "medium",
            Effort::High => "high",
            Effort::XHigh => "xhigh",
            Effort::Max => "max",
        }
    }
}

#[derive(Debug, Clone)]
pub struct ModelRequest {
    pub model: String,
    pub max_tokens: u32,
    pub effort: Option<Effort>,
    pub plan: PromptPlan,
}

/// A safety-classifier decline. Not an error in the transport sense — the call
/// succeeded, the model declined.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Refusal {
    pub category: Option<String>,
    pub explanation: Option<String>,
}

/// One `tool_use` block the model emitted.
///
/// Lives here rather than in the agent crate because it is a *wire* shape: the
/// provider decides what a tool call looks like, and the gateway is the only
/// thing that talks to the provider.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolCall {
    /// The provider's id for this call, echoed back with its result.
    pub id: String,
    pub name: String,
    pub input: serde_json::Value,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ModelResponse {
    pub text: String,
    pub usage: Usage,
    /// The model that actually produced the message — may differ from the one
    /// requested when a fallback served the turn.
    pub model: String,
    pub stop_reason: Option<String>,
    /// `Some` when the whole chain declined. `text` is empty in that case.
    pub refusal: Option<Refusal>,
    /// Tools the model wants run before it can continue. Non-empty exactly when
    /// `stop_reason` is `tool_use`.
    pub tool_calls: Vec<ToolCall>,
}

#[derive(Debug)]
pub enum DispatchError {
    Transport(String),
    /// A non-2xx response. `status` and the provider's message, verbatim.
    Api {
        status: u16,
        message: String,
    },
    Decode(String),
    /// No API key configured — a setup problem, not a runtime one.
    NotConfigured,
}

impl std::fmt::Display for DispatchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DispatchError::Transport(msg) => write!(f, "transport: {msg}"),
            DispatchError::Api { status, message } => write!(f, "provider {status}: {message}"),
            DispatchError::Decode(msg) => write!(f, "could not decode response: {msg}"),
            DispatchError::NotConfigured => f.write_str(
                "no model provider configured — set ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN",
            ),
        }
    }
}

impl std::error::Error for DispatchError {}

pub trait ModelClient: Send + Sync {
    fn complete(
        &self,
        request: ModelRequest,
    ) -> impl std::future::Future<Output = Result<ModelResponse, DispatchError>> + Send;
}

/// The Messages params for a request, without anything transport-specific.
///
/// Shared with the batch queue (C6), which sends the *same* params through
/// `POST /v1/messages/batches`. Two copies of this would drift, and the way you
/// would find out is a batched call being assembled differently — and priced
/// differently — from the live one it was meant to replace.
pub fn messages_params(request: &ModelRequest) -> serde_json::Value {
    let mut body = serde_json::json!({
        "model": request.model,
        "max_tokens": request.max_tokens,
        "messages": request.plan.messages,
    });

    if !request.plan.system.is_empty() {
        body["system"] = serde_json::to_value(&request.plan.system).unwrap_or_default();
    }
    if !request.plan.tools.is_empty() {
        body["tools"] = serde_json::Value::Array(request.plan.tools.clone());
    }
    if let Some(effort) = request.effort {
        body["output_config"] = serde_json::json!({ "effort": effort.as_str() });
    }
    // No temperature / top_p / top_k: rejected by the current models.
    body
}

/* ------------------------------------------------------------------ wire types */

#[derive(Debug, Deserialize)]
struct WireUsage {
    #[serde(default)]
    input_tokens: u32,
    #[serde(default)]
    output_tokens: u32,
    #[serde(default)]
    cache_creation_input_tokens: u32,
    #[serde(default)]
    cache_read_input_tokens: u32,
}

#[derive(Debug, Deserialize)]
struct WireBlock {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    text: String,
    // Only present on `tool_use` blocks. Defaulted rather than required so a
    // block type nobody here has heard of cannot fail the whole decode.
    #[serde(default)]
    id: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    input: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
struct WireStopDetails {
    #[serde(default)]
    category: Option<String>,
    #[serde(default)]
    explanation: Option<String>,
}

#[derive(Debug, Deserialize)]
struct WireResponse {
    #[serde(default)]
    model: String,
    #[serde(default)]
    content: Vec<WireBlock>,
    #[serde(default)]
    stop_reason: Option<String>,
    #[serde(default)]
    stop_details: Option<WireStopDetails>,
    #[serde(default)]
    usage: Option<WireUsage>,
}

impl WireResponse {
    fn into_response(self, requested_model: &str) -> ModelResponse {
        let usage = self
            .usage
            .map(|wire| Usage {
                input_tokens: wire.input_tokens,
                output_tokens: wire.output_tokens,
                cache_write_tokens: wire.cache_creation_input_tokens,
                cache_read_tokens: wire.cache_read_input_tokens,
            })
            .unwrap_or_default();

        let refused = self.stop_reason.as_deref() == Some("refusal");

        // A refusal carries no tool calls, and reading them from an empty
        // `content` would produce an agent loop that runs a declined turn.
        let tool_calls = if refused {
            Vec::new()
        } else {
            self.content
                .iter()
                .filter(|block| block.kind == "tool_use")
                .map(|block| ToolCall {
                    id: block.id.clone(),
                    name: block.name.clone(),
                    input: block
                        .input
                        .clone()
                        .unwrap_or(serde_json::Value::Object(Default::default())),
                })
                .collect()
        };

        ModelResponse {
            // Guarded: on a refusal `content` is empty, and on any response it
            // may hold non-text blocks that must not be concatenated blindly.
            text: if refused {
                String::new()
            } else {
                self.content
                    .iter()
                    .filter(|block| block.kind == "text")
                    .map(|block| block.text.as_str())
                    .collect::<Vec<_>>()
                    .join("")
            },
            tool_calls,
            usage,
            model: if self.model.is_empty() {
                requested_model.to_owned()
            } else {
                self.model
            },
            refusal: refused.then(|| {
                let details = self.stop_details.unwrap_or(WireStopDetails {
                    category: None,
                    explanation: None,
                });
                Refusal {
                    category: details.category,
                    explanation: details.explanation,
                }
            }),
            stop_reason: self.stop_reason,
        }
    }
}

/* ------------------------------------------------------------- real client */

/// A whitespace-only key is the same as no key — an exported-but-empty variable
/// is a common shell mishap, and treating it as configured turns a setup problem
/// into a 401 on the first real call.
fn usable_key(raw: Option<String>) -> Option<String> {
    raw.filter(|key| !key.trim().is_empty())
}

/// How a request proves who it is.
///
/// The two forms are different headers, not two spellings of one — a bearer
/// token sent as `x-api-key` is a 401, and the OAuth beta header is required
/// alongside it or `/v1/messages` refuses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Credential {
    /// A `sk-ant-api…` key from the Console, on `x-api-key`.
    ApiKey(String),
    /// A short-lived bearer token — what `ant auth print-credentials
    /// --access-token` prints, or a Workload Identity Federation exchange.
    AuthToken(String),
}

/// Gates OAuth bearer tokens on `/v1/messages`. Sending one without this header
/// is rejected even though the token itself is valid.
pub const OAUTH_BETA: &str = "oauth-2025-04-20";

pub struct AnthropicClient {
    credential: Credential,
    base_url: String,
    http: reqwest::Client,
    /// Opt into server-side fallbacks. On by default; a refused call in an
    /// agent loop is worse than a slightly more expensive one.
    fallbacks: bool,
}

impl AnthropicClient {
    pub fn new(api_key: impl Into<String>) -> Self {
        Self::with_credential(Credential::ApiKey(api_key.into()))
    }

    pub fn with_credential(credential: Credential) -> Self {
        Self {
            credential,
            base_url: "https://api.anthropic.com".into(),
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(600))
                .build()
                .expect("reqwest client"),
            fallbacks: true,
        }
    }

    /// Read a credential from the environment. `None` when there is none, so the
    /// runner can start and serve the read-only API with no provider configured.
    ///
    /// Resolution order matches the official SDKs': `ANTHROPIC_API_KEY` first,
    /// then `ANTHROPIC_AUTH_TOKEN`. The second exists because a static Console
    /// key is not the only credential the API takes — a short-lived bearer token
    /// works too, and requiring a key would turn "I am already authenticated"
    /// into "go and mint a secret".
    ///
    /// A blank value counts as unset in both cases: an exported-but-empty
    /// variable is a common shell mishap, and honouring it turns a setup problem
    /// into a 401 on the first real call.
    ///
    /// `ANTHROPIC_BASE_URL` redirects to a compatible endpoint — a local
    /// vLLM/Ollama shim for the self-hosted small tier (§7), or a test server.
    pub fn from_env() -> Option<Self> {
        let credential = usable_key(std::env::var("ANTHROPIC_API_KEY").ok())
            .map(Credential::ApiKey)
            .or_else(|| {
                usable_key(std::env::var("ANTHROPIC_AUTH_TOKEN").ok()).map(Credential::AuthToken)
            })?;

        let client = Self::with_credential(credential);
        Some(match std::env::var("ANTHROPIC_BASE_URL") {
            Ok(base) if !base.trim().is_empty() => {
                client.with_base_url(base.trim_end_matches('/').to_owned())
            }
            _ => client,
        })
    }

    /// How this client will describe itself in the startup banner.
    pub fn credential_kind(&self) -> &'static str {
        match self.credential {
            Credential::ApiKey(_) => "api key",
            Credential::AuthToken(_) => "auth token",
        }
    }

    /// Point at a different endpoint — a local vLLM/Ollama shim, or a test server.
    pub fn with_base_url(mut self, base_url: impl Into<String>) -> Self {
        self.base_url = base_url.into();
        self
    }

    pub fn without_fallbacks(mut self) -> Self {
        self.fallbacks = false;
        self
    }

    fn body(&self, request: &ModelRequest) -> serde_json::Value {
        let mut body = messages_params(request);
        if self.fallbacks {
            // The scalar form routes by refusal category, so there is no
            // fallback model list here to go stale.
            body["fallbacks"] = serde_json::Value::String("default".into());
        }
        body
    }

    /// Every beta this request opts into, as one comma-separated header.
    ///
    /// `anthropic-beta` is a list, not a slot: sending the header twice keeps
    /// only the last one, so a bearer-token call with fallbacks on would
    /// silently lose whichever was set second.
    fn beta_header(&self) -> Option<String> {
        let mut betas: Vec<&str> = Vec::new();
        if self.fallbacks {
            betas.push(FALLBACK_BETA);
        }
        if matches!(self.credential, Credential::AuthToken(_)) {
            betas.push(OAUTH_BETA);
        }
        (!betas.is_empty()).then(|| betas.join(","))
    }
}

impl ModelClient for AnthropicClient {
    async fn complete(&self, request: ModelRequest) -> Result<ModelResponse, DispatchError> {
        let mut builder = self
            .http
            .post(format!("{}/v1/messages", self.base_url))
            .header("anthropic-version", ANTHROPIC_VERSION)
            .header("content-type", "application/json");

        // Different headers, not two spellings of one: a bearer token sent as
        // `x-api-key` is a 401.
        builder = match &self.credential {
            Credential::ApiKey(key) => builder.header("x-api-key", key),
            Credential::AuthToken(token) => {
                builder.header("authorization", format!("Bearer {token}"))
            }
        };

        if let Some(betas) = self.beta_header() {
            builder = builder.header("anthropic-beta", betas);
        }

        let response = builder
            .json(&self.body(&request))
            .send()
            .await
            .map_err(|err| DispatchError::Transport(err.to_string()))?;

        let status = response.status();
        let text = response
            .text()
            .await
            .map_err(|err| DispatchError::Transport(err.to_string()))?;

        if !status.is_success() {
            let message = serde_json::from_str::<serde_json::Value>(&text)
                .ok()
                .and_then(|body| {
                    body.get("error")?
                        .get("message")?
                        .as_str()
                        .map(str::to_owned)
                })
                .unwrap_or(text);
            return Err(DispatchError::Api {
                status: status.as_u16(),
                message,
            });
        }

        let wire: WireResponse =
            serde_json::from_str(&text).map_err(|err| DispatchError::Decode(err.to_string()))?;
        Ok(wire.into_response(&request.model))
    }
}

/* -------------------------------------------------------------- stub client */

/// A client that answers locally and simulates the provider's prefix caching.
///
/// It exists so the cache-shaped assembly in [`crate::prompt`] can be *measured*
/// rather than asserted. The simulation follows the real rule: a request reads
/// from the **longest breakpoint prefix it has seen before** and writes the
/// remainder. So a prompt whose prefix drifts scores zero here exactly as it
/// would in production, and a conversation that only appends keeps hitting its
/// earlier breakpoints — which is the behaviour worth verifying.
pub struct StubClient {
    seen_prefixes: Mutex<std::collections::HashSet<String>>,
    reply: String,
    calls: Mutex<Vec<ModelRequest>>,
    refuse: bool,
}

impl StubClient {
    pub fn new(reply: impl Into<String>) -> Self {
        Self {
            seen_prefixes: Mutex::new(std::collections::HashSet::new()),
            reply: reply.into(),
            calls: Mutex::new(Vec::new()),
            refuse: false,
        }
    }

    /// Always decline, to exercise the refusal path.
    pub fn refusing() -> Self {
        Self {
            refuse: true,
            ..Self::new("")
        }
    }

    pub fn call_count(&self) -> usize {
        self.calls.lock().expect("stub calls poisoned").len()
    }

    pub fn calls(&self) -> Vec<ModelRequest> {
        self.calls.lock().expect("stub calls poisoned").clone()
    }
}

impl ModelClient for StubClient {
    async fn complete(&self, request: ModelRequest) -> Result<ModelResponse, DispatchError> {
        let full_prefix = request.plan.stable_prefix();
        let tail_tokens = approx_tokens(request.plan.dynamic_tail()) as u32;
        let model = request.model.clone();

        // Provider caches are per-model, so the model id is part of the key.
        let scope = |prefix: &str| format!("{model}\0{prefix}");

        let (read_tokens, write_tokens) = {
            let mut seen = self.seen_prefixes.lock().expect("stub cache poisoned");
            let breakpoints = request.plan.cache_prefixes();

            // The longest previously-seen breakpoint prefix is what gets read.
            let matched = breakpoints
                .iter()
                .rev()
                .find(|prefix| seen.contains(&scope(prefix)))
                .cloned()
                .unwrap_or_default();

            for prefix in &breakpoints {
                seen.insert(scope(prefix));
            }

            let read = approx_tokens(&matched) as u32;
            // Everything cacheable beyond the hit is written this turn. Without
            // any breakpoints nothing is written *or* read — an uncacheable
            // prompt bills its whole prefix as plain input, below.
            let cacheable = breakpoints
                .last()
                .map(|prefix| approx_tokens(prefix) as u32)
                .unwrap_or(0);
            (read, cacheable.saturating_sub(read))
        };

        // A prefix with no breakpoint is not cached at all, so it lands in
        // `input_tokens` at full price — exactly what the real API does.
        let uncached_prefix = approx_tokens(&full_prefix) as u32 - (read_tokens + write_tokens);

        self.calls
            .lock()
            .expect("stub calls poisoned")
            .push(request);

        if self.refuse {
            return Ok(ModelResponse {
                text: String::new(),
                usage: Usage::default(),
                model,
                stop_reason: Some("refusal".into()),
                refusal: Some(Refusal {
                    category: Some("cyber".into()),
                    explanation: None,
                }),
                tool_calls: Vec::new(),
            });
        }

        Ok(ModelResponse {
            text: self.reply.clone(),
            usage: Usage {
                input_tokens: tail_tokens + uncached_prefix,
                output_tokens: approx_tokens(&self.reply) as u32,
                cache_write_tokens: write_tokens,
                cache_read_tokens: read_tokens,
            },
            model,
            stop_reason: Some("end_turn".into()),
            refusal: None,
            tool_calls: Vec::new(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prompt::{StableContext, assemble};
    use forge_domain::price::price_of;

    fn request(model: &str, tail: &str) -> ModelRequest {
        let stable = StableContext {
            system: "x".repeat(4_000),
            ..StableContext::default()
        };
        ModelRequest {
            model: model.to_owned(),
            max_tokens: DEFAULT_MAX_TOKENS,
            effort: Some(Effort::High),
            plan: assemble(&stable, tail, &price_of("claude-opus-5").unwrap()),
        }
    }

    #[test]
    fn a_refusal_yields_no_text_even_if_content_is_present() {
        let wire: WireResponse = serde_json::from_str(
            r#"{"model":"claude-opus-5","content":[],"stop_reason":"refusal",
                "stop_details":{"category":"cyber","explanation":"declined"},
                "usage":{"input_tokens":10,"output_tokens":0}}"#,
        )
        .unwrap();

        let response = wire.into_response("claude-opus-5");
        assert!(response.text.is_empty());
        let refusal = response.refusal.unwrap();
        assert_eq!(refusal.category.as_deref(), Some("cyber"));
    }

    #[test]
    fn non_text_blocks_are_not_concatenated_into_the_answer() {
        let wire: WireResponse = serde_json::from_str(
            r#"{"model":"m","content":[
                 {"type":"thinking","text":"internal"},
                 {"type":"text","text":"the answer"}],
               "stop_reason":"end_turn"}"#,
        )
        .unwrap();

        assert_eq!(wire.into_response("m").text, "the answer");
    }

    #[test]
    fn tool_use_blocks_come_back_as_calls_alongside_the_text() {
        let wire: WireResponse = serde_json::from_str(
            r#"{"model":"m","content":[
                 {"type":"text","text":"Let me look."},
                 {"type":"tool_use","id":"toolu_9","name":"read_file",
                  "input":{"path":"src/retry.rs"}}],
               "stop_reason":"tool_use"}"#,
        )
        .unwrap();

        let response = wire.into_response("m");
        assert_eq!(response.text, "Let me look.");
        assert_eq!(response.tool_calls.len(), 1);
        assert_eq!(response.tool_calls[0].id, "toolu_9");
        assert_eq!(response.tool_calls[0].name, "read_file");
        assert_eq!(response.tool_calls[0].input["path"], "src/retry.rs");
    }

    #[test]
    fn a_refusal_carries_no_tool_calls_even_if_blocks_are_present() {
        // Running a tool from a turn the model declined would be the agent loop
        // acting on an instruction that was never issued.
        let wire: WireResponse = serde_json::from_str(
            r#"{"model":"m","content":[
                 {"type":"tool_use","id":"t","name":"run","input":{"command":"x"}}],
               "stop_reason":"refusal"}"#,
        )
        .unwrap();

        let response = wire.into_response("m");
        assert!(response.tool_calls.is_empty());
        assert!(response.refusal.is_some());
    }

    #[test]
    fn a_tool_use_block_with_no_input_becomes_an_empty_object() {
        let wire: WireResponse = serde_json::from_str(
            r#"{"model":"m","content":[{"type":"tool_use","id":"t","name":"list_files"}],
                "stop_reason":"tool_use"}"#,
        )
        .unwrap();
        assert_eq!(
            wire.into_response("m").tool_calls[0].input,
            serde_json::json!({})
        );
    }

    #[test]
    fn cache_fields_map_to_the_ledgers_names() {
        let wire: WireResponse = serde_json::from_str(
            r#"{"model":"m","content":[{"type":"text","text":"hi"}],
                "usage":{"input_tokens":1,"output_tokens":2,
                         "cache_creation_input_tokens":3,"cache_read_input_tokens":4}}"#,
        )
        .unwrap();

        let usage = wire.into_response("m").usage;
        assert_eq!(usage.cache_write_tokens, 3);
        assert_eq!(usage.cache_read_tokens, 4);
    }

    #[test]
    fn a_response_with_no_usage_block_does_not_explode() {
        let wire: WireResponse =
            serde_json::from_str(r#"{"model":"m","content":[{"type":"text","text":"hi"}]}"#)
                .unwrap();
        assert_eq!(wire.into_response("m").usage, Usage::default());
    }

    #[test]
    fn the_request_body_never_carries_sampling_parameters() {
        let client = AnthropicClient::new("test-key");
        let body = client.body(&request("claude-opus-5", "hello"));

        for rejected in ["temperature", "top_p", "top_k"] {
            assert!(
                body.get(rejected).is_none(),
                "{rejected} is rejected by current models"
            );
        }
        assert_eq!(body["output_config"]["effort"], "high");
        assert_eq!(body["fallbacks"], "default");
    }

    #[test]
    fn fallbacks_can_be_turned_off() {
        let client = AnthropicClient::new("k").without_fallbacks();
        assert!(
            client
                .body(&request("claude-opus-5", "hi"))
                .get("fallbacks")
                .is_none()
        );
    }

    #[test]
    fn empty_system_and_tools_are_omitted_rather_than_sent_blank() {
        let client = AnthropicClient::new("k");
        let bare = ModelRequest {
            model: "m".into(),
            max_tokens: 16,
            effort: None,
            plan: assemble(
                &StableContext::default(),
                "hi",
                &price_of("claude-opus-5").unwrap(),
            ),
        };
        let body = client.body(&bare);
        assert!(body.get("system").is_none());
        assert!(body.get("tools").is_none());
        assert!(body.get("output_config").is_none());
    }

    #[test]
    fn a_blank_or_missing_key_counts_as_unconfigured() {
        assert_eq!(usable_key(None), None);
        assert_eq!(usable_key(Some("   ".into())), None);
        assert_eq!(usable_key(Some("".into())), None);
        assert_eq!(
            usable_key(Some("sk-ant-real".into())),
            Some("sk-ant-real".into())
        );
    }

    #[test]
    fn an_api_key_and_a_bearer_token_are_different_headers() {
        // Not two spellings of one credential: a bearer token sent as
        // `x-api-key` is a 401, and an API key on `authorization` likewise.
        let key = AnthropicClient::new("sk-ant-real");
        assert_eq!(key.credential_kind(), "api key");

        let token = AnthropicClient::with_credential(Credential::AuthToken("oat-abc".into()));
        assert_eq!(token.credential_kind(), "auth token");
    }

    #[test]
    fn a_bearer_token_opts_into_the_oauth_beta() {
        // Without it, `/v1/messages` refuses a token that is otherwise valid.
        let token = AnthropicClient::with_credential(Credential::AuthToken("oat-abc".into()));
        let betas = token.beta_header().unwrap();
        assert!(betas.contains(OAUTH_BETA));
    }

    #[test]
    fn both_betas_ride_one_header_rather_than_overwriting_each_other() {
        // `anthropic-beta` is a list, not a slot. Setting the header twice keeps
        // only the last, so a token call with fallbacks on would silently drop
        // whichever was written second.
        let token = AnthropicClient::with_credential(Credential::AuthToken("oat-abc".into()));
        let betas = token.beta_header().unwrap();
        assert!(betas.contains(FALLBACK_BETA), "{betas}");
        assert!(betas.contains(OAUTH_BETA), "{betas}");
        assert_eq!(betas.split(',').count(), 2, "{betas}");
    }

    #[test]
    fn an_api_key_does_not_ask_for_the_oauth_beta() {
        let key = AnthropicClient::new("sk-ant-real");
        assert_eq!(key.beta_header().as_deref(), Some(FALLBACK_BETA));

        // And with fallbacks off there is nothing to send at all.
        assert!(
            AnthropicClient::new("sk-ant-real")
                .without_fallbacks()
                .beta_header()
                .is_none()
        );
    }

    #[tokio::test]
    async fn the_stub_reports_a_cold_prefix_then_a_warm_one() {
        let client = StubClient::new("ok");

        let first = client
            .complete(request("claude-opus-5", "one"))
            .await
            .unwrap();
        assert!(first.usage.cache_write_tokens > 0);
        assert_eq!(first.usage.cache_read_tokens, 0);

        let second = client
            .complete(request("claude-opus-5", "two"))
            .await
            .unwrap();
        assert_eq!(second.usage.cache_write_tokens, 0);
        assert!(second.usage.cache_read_tokens > 0);
        assert_eq!(client.call_count(), 2);
    }

    #[tokio::test]
    async fn appending_to_history_still_reads_the_earlier_breakpoints() {
        let client = StubClient::new("ok");
        let base = StableContext {
            system: "x".repeat(8_000),
            repo_map: "y".repeat(8_000),
            history: vec![crate::prompt::Turn::user("turn one")],
            ..StableContext::default()
        };
        let price = price_of("claude-opus-5").unwrap();

        let first = ModelRequest {
            model: "claude-opus-5".into(),
            max_tokens: 16,
            effort: None,
            plan: assemble(&base, "a", &price),
        };
        client.complete(first).await.unwrap();

        // A new turn appended to history: the system and repo-map breakpoints
        // must still be read, with only the appended turn written.
        let mut grown = base.clone();
        grown.history.push(crate::prompt::Turn::user("turn two"));
        let second = client
            .complete(ModelRequest {
                model: "claude-opus-5".into(),
                max_tokens: 16,
                effort: None,
                plan: assemble(&grown, "b", &price),
            })
            .await
            .unwrap();

        assert!(
            second.usage.cache_read_tokens > 3_000,
            "earlier prefix not reused"
        );
        assert!(
            second.usage.cache_write_tokens > 0,
            "the new turn should be written"
        );
        assert!(
            second.usage.cache_write_tokens < second.usage.cache_read_tokens,
            "appending must write far less than it reads"
        );
    }

    #[tokio::test]
    async fn an_uncacheable_prompt_bills_its_whole_prefix_as_input() {
        let client = StubClient::new("ok");
        // Far below any model's minimum cacheable length, so no breakpoints.
        let short = StableContext {
            system: "Be brief.".into(),
            ..StableContext::default()
        };
        let plan = assemble(&short, "hello", &price_of("claude-opus-5").unwrap());
        assert_eq!(plan.breakpoints(), 0);

        let response = client
            .complete(ModelRequest {
                model: "claude-opus-5".into(),
                max_tokens: 16,
                effort: None,
                plan,
            })
            .await
            .unwrap();

        assert_eq!(response.usage.cache_read_tokens, 0);
        assert_eq!(response.usage.cache_write_tokens, 0);
        assert!(response.usage.input_tokens > 0);
    }

    #[tokio::test]
    async fn the_stub_cache_is_per_model_like_the_real_one() {
        let client = StubClient::new("ok");
        client
            .complete(request("claude-opus-5", "q"))
            .await
            .unwrap();

        let other = client
            .complete(request("claude-haiku-4-5", "q"))
            .await
            .unwrap();
        assert_eq!(
            other.usage.cache_read_tokens, 0,
            "a different model must not read another model's cache"
        );
    }
}
