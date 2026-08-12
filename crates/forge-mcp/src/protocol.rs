//! The MCP wire protocol: JSON-RPC 2.0 over HTTP.
//!
//! Deliberately hand-written and small. MCP's request surface for a
//! tools-only server is four methods, and a general-purpose JSON-RPC crate
//! would bring a transport abstraction this does not use plus its own opinion
//! about async. What matters here is being *exactly* right about the shapes
//! Claude sends and expects, which is easier to see — and to test — in a
//! hundred lines than through a framework.
//!
//! # The one asymmetry worth knowing
//!
//! A JSON-RPC **notification** has no `id` and must produce no response body.
//! Claude sends `notifications/initialized` after the handshake, and a server
//! that answers it with a result — or worse, an error — is a server that looks
//! broken at exactly the moment the connection is being established. That is
//! why [`Request::is_notification`] exists and why every dispatch path checks it.

use serde::{Deserialize, Serialize};

/// The protocol revision this server implements.
///
/// Claude negotiates: it sends the version it wants, and a server that speaks
/// something else answers with what it *does* speak rather than failing. So an
/// unknown version is not an error — see [`negotiate`].
pub const PROTOCOL_VERSION: &str = "2025-06-18";

/// Revisions this server can actually talk, newest first.
///
/// `2025-03-26` is still what several shipped clients send. The tool surface is
/// identical between the two, so honouring it costs nothing and refusing it
/// would strand those clients for no benefit.
pub const SUPPORTED_VERSIONS: &[&str] = &["2025-06-18", "2025-03-26"];

/// Agree a protocol version with the client.
///
/// Echo back what they asked for when it is one we speak; otherwise answer with
/// our preferred version and let the client decide whether to continue. That is
/// what the specification asks for, and it is also the behaviour that degrades
/// best: a newer client meeting an older server still gets a usable answer.
pub fn negotiate(requested: Option<&str>) -> &'static str {
    match requested {
        Some(asked) => SUPPORTED_VERSIONS
            .iter()
            .find(|known| **known == asked)
            .copied()
            .unwrap_or(PROTOCOL_VERSION),
        None => PROTOCOL_VERSION,
    }
}

/* ------------------------------------------------------------------ envelope */

#[derive(Debug, Clone, Deserialize)]
pub struct Request {
    #[serde(default)]
    pub jsonrpc: String,
    /// Absent on a notification. Present on everything that expects an answer.
    #[serde(default)]
    pub id: Option<serde_json::Value>,
    pub method: String,
    #[serde(default)]
    pub params: serde_json::Value,
}

impl Request {
    /// A notification expects no response at all — not even an error.
    pub fn is_notification(&self) -> bool {
        self.id.is_none()
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Response {
    pub jsonrpc: &'static str,
    pub id: serde_json::Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ResponseError>,
}

impl Response {
    pub fn ok(id: serde_json::Value, result: serde_json::Value) -> Self {
        Self {
            jsonrpc: "2.0",
            id,
            result: Some(result),
            error: None,
        }
    }

    pub fn failed(id: serde_json::Value, error: ResponseError) -> Self {
        Self {
            jsonrpc: "2.0",
            id,
            result: None,
            error: Some(error),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct ResponseError {
    pub code: i32,
    pub message: String,
}

impl ResponseError {
    /// The four JSON-RPC codes this server can produce. Application failures do
    /// **not** use these — see [`ToolOutcome`].
    pub const PARSE_ERROR: i32 = -32700;
    pub const INVALID_REQUEST: i32 = -32600;
    pub const METHOD_NOT_FOUND: i32 = -32601;
    pub const INVALID_PARAMS: i32 = -32602;
    pub const INTERNAL_ERROR: i32 = -32603;

    pub fn new(code: i32, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    pub fn method_not_found(method: &str) -> Self {
        Self::new(
            Self::METHOD_NOT_FOUND,
            format!("this server does not implement {method}"),
        )
    }

    pub fn invalid_params(why: impl Into<String>) -> Self {
        Self::new(Self::INVALID_PARAMS, why)
    }
}

/* --------------------------------------------------------------------- tools */

/// A tool, as `tools/list` describes it.
///
/// `input_schema` is JSON Schema. Claude reads it to decide how to call the
/// tool, so a vague schema produces vague calls — every property carries a
/// description for the same reason a function signature carries names.
#[derive(Debug, Clone, Serialize)]
pub struct ToolSpec {
    pub name: &'static str,
    pub description: &'static str,
    #[serde(rename = "inputSchema")]
    pub input_schema: serde_json::Value,
}

/// What a tool call produced.
///
/// # Why a failure is not a JSON-RPC error
///
/// A tool that fails has still been *called successfully* — the protocol worked.
/// Returning a JSON-RPC error would tell Claude the call could not be made,
/// which is a different fact and one it cannot act on. `is_error` inside the
/// result lets Claude read what went wrong and try something else, which is the
/// whole point of giving it tools.
#[derive(Debug, Clone)]
pub struct ToolOutcome {
    pub text: String,
    pub is_error: bool,
}

impl ToolOutcome {
    pub fn ok(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            is_error: false,
        }
    }

    /// A refusal or failure Claude should read and reason about.
    pub fn error(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            is_error: true,
        }
    }

    /// Serialise a value as the tool's answer, pretty-printed.
    ///
    /// Pretty rather than compact because the consumer is a language model
    /// reading it as text: newlines and indentation are structure it can use,
    /// and the token cost of whitespace is far smaller than the cost of it
    /// misreading a nested object.
    pub fn json<T: Serialize>(value: &T) -> Self {
        match serde_json::to_string_pretty(value) {
            Ok(text) => Self::ok(text),
            Err(err) => Self::error(format!("could not render the result: {err}")),
        }
    }

    pub fn to_result(&self) -> serde_json::Value {
        serde_json::json!({
            "content": [{ "type": "text", "text": self.text }],
            "isError": self.is_error,
        })
    }
}

/// The `initialize` result.
pub fn initialize_result(server_name: &str, version: &str, protocol: &str) -> serde_json::Value {
    serde_json::json!({
        "protocolVersion": protocol,
        // Tools only. Declaring `resources` or `prompts` we do not serve would
        // make Claude call methods this server answers with -32601.
        "capabilities": { "tools": { "listChanged": false } },
        "serverInfo": { "name": server_name, "version": version },
    })
}

/// Pull `name` and `arguments` out of a `tools/call`.
pub fn parse_tool_call(
    params: &serde_json::Value,
) -> Result<(String, serde_json::Value), ResponseError> {
    let name = params
        .get("name")
        .and_then(|name| name.as_str())
        .ok_or_else(|| ResponseError::invalid_params("tools/call needs a tool name"))?;

    // Absent arguments is legal for a tool that takes none; an explicit `null`
    // means the same thing. Both become an empty object so every tool can read
    // its arguments the same way.
    let arguments = match params.get("arguments") {
        None | Some(serde_json::Value::Null) => serde_json::json!({}),
        Some(value) => value.clone(),
    };

    Ok((name.to_owned(), arguments))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_request_without_an_id_is_a_notification() {
        // The distinction that keeps the handshake working: answering
        // `notifications/initialized` breaks the connection at the worst moment.
        let notification: Request =
            serde_json::from_str(r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
                .unwrap();
        assert!(notification.is_notification());

        let call: Request =
            serde_json::from_str(r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#).unwrap();
        assert!(!call.is_notification());
    }

    #[test]
    fn an_id_of_zero_is_still_an_id() {
        // `Option` on a JSON value, not a truthiness check — id 0 and id null
        // are different requests and only one of them wants an answer.
        let call: Request =
            serde_json::from_str(r#"{"jsonrpc":"2.0","id":0,"method":"ping"}"#).unwrap();
        assert!(!call.is_notification());
    }

    #[test]
    fn a_string_id_round_trips_unchanged() {
        // Ids are opaque: echo back exactly what arrived, whatever its type.
        let call: Request =
            serde_json::from_str(r#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#).unwrap();
        let response = Response::ok(call.id.unwrap(), serde_json::json!({}));
        let rendered = serde_json::to_value(&response).unwrap();
        assert_eq!(rendered["id"], "abc");
    }

    #[test]
    fn a_known_protocol_version_is_echoed_back() {
        assert_eq!(negotiate(Some("2025-06-18")), "2025-06-18");
        assert_eq!(negotiate(Some("2025-03-26")), "2025-03-26");
    }

    #[test]
    fn an_unknown_protocol_version_gets_ours_rather_than_a_failure() {
        // A client from the future should get a usable answer, not a refusal.
        assert_eq!(negotiate(Some("2099-01-01")), PROTOCOL_VERSION);
        assert_eq!(negotiate(None), PROTOCOL_VERSION);
    }

    #[test]
    fn a_response_omits_the_half_it_is_not() {
        // JSON-RPC forbids result and error together; serialising both as null
        // is the most common way to get that wrong.
        let ok = serde_json::to_value(Response::ok(1.into(), serde_json::json!({"a": 1}))).unwrap();
        assert!(ok.get("error").is_none());

        let failed = serde_json::to_value(Response::failed(
            1.into(),
            ResponseError::method_not_found("nope"),
        ))
        .unwrap();
        assert!(failed.get("result").is_none());
        assert_eq!(failed["error"]["code"], ResponseError::METHOD_NOT_FOUND);
    }

    #[test]
    fn a_tool_call_without_arguments_gets_an_empty_object() {
        // So a zero-argument tool does not have to special-case `None`.
        let (name, arguments) =
            parse_tool_call(&serde_json::json!({ "name": "list_machines" })).unwrap();
        assert_eq!(name, "list_machines");
        assert_eq!(arguments, serde_json::json!({}));

        let (_, explicit_null) =
            parse_tool_call(&serde_json::json!({ "name": "x", "arguments": null })).unwrap();
        assert_eq!(explicit_null, serde_json::json!({}));
    }

    #[test]
    fn a_tool_call_without_a_name_is_invalid_params() {
        let failure = parse_tool_call(&serde_json::json!({})).unwrap_err();
        assert_eq!(failure.code, ResponseError::INVALID_PARAMS);
    }

    #[test]
    fn a_failing_tool_is_a_successful_call() {
        // The distinction that lets Claude recover: the call worked, the tool
        // said no. A JSON-RPC error would say the call itself was impossible.
        let outcome = ToolOutcome::error("that machine is offline");
        let rendered = outcome.to_result();
        assert_eq!(rendered["isError"], true);
        assert_eq!(rendered["content"][0]["text"], "that machine is offline");
        assert_eq!(rendered["content"][0]["type"], "text");
    }

    #[test]
    fn initialize_advertises_only_what_is_served() {
        // Declaring `resources` would make Claude call a method we answer with
        // -32601, which reads to a user as a broken connector.
        let result = initialize_result("relayforge", "0.1.0", PROTOCOL_VERSION);
        assert!(result["capabilities"].get("tools").is_some());
        assert!(result["capabilities"].get("resources").is_none());
        assert!(result["capabilities"].get("prompts").is_none());
        assert_eq!(result["serverInfo"]["name"], "relayforge");
    }

    #[test]
    fn a_tool_spec_renders_the_schema_key_camel_cased() {
        // `inputSchema`, not `input_schema` — a snake_case key means Claude
        // sees a tool with no schema and calls it with nothing.
        let spec = ToolSpec {
            name: "x",
            description: "y",
            input_schema: serde_json::json!({"type": "object"}),
        };
        let rendered = serde_json::to_value(&spec).unwrap();
        assert!(rendered.get("inputSchema").is_some());
        assert!(rendered.get("input_schema").is_none());
    }
}
