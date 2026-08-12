//! How a host registers the tools it serves.
//!
//! `forge-cloud` and `forge-runner` expose different tool sets over the same
//! protocol, so the protocol layer takes a registry rather than knowing about
//! either. A host implements [`ToolSet`]; everything else — dispatch, the error
//! shapes, the handshake — is shared.
//!
//! # Descriptions are the interface
//!
//! Claude decides whether to call a tool from its name and description alone,
//! so those are load-bearing text, not documentation. Say **when** to reach for
//! it, not only what it does: a description that states its trigger condition
//! gets called at the right moments, and one that only describes mechanics gets
//! called at the wrong ones or not at all.

use crate::protocol::{ToolOutcome, ToolSpec};

/// A set of tools one server exposes.
pub trait ToolSet: Send + Sync {
    /// What `tools/list` returns. Stable for the life of the process — the
    /// handshake advertises `listChanged: false`.
    fn specs(&self) -> Vec<ToolSpec>;

    /// Run one tool. `account_id` and `org_id` come from the verified token, not
    /// from the arguments — a tool that took its own tenant id from Claude would
    /// be one prompt injection away from reading another workspace.
    fn call(
        &self,
        name: &str,
        arguments: serde_json::Value,
        caller: &Caller,
    ) -> impl std::future::Future<Output = ToolOutcome> + Send;
}

/// Who is on the other end of a tool call, established by the access token.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Caller {
    pub account_id: String,
    pub org_id: String,
    pub role: forge_crypto::token::Role,
}

impl Caller {
    /// Whether this caller may take an action that changes something.
    ///
    /// Deliberately checked per tool rather than at the door: a connector is a
    /// third party running with a user's authority, so read-only tools should
    /// stay available even to a role that cannot approve anything.
    pub fn can_act(&self) -> bool {
        self.role.can_decide()
    }
}

/// Build a JSON Schema object for a tool with named string properties.
///
/// A helper because every schema here has the same shape and writing them by
/// hand is how `inputSchema` ends up subtly wrong — a missing `type`, a
/// property with no description, a `required` naming a field that is not there.
pub fn object_schema(properties: &[(&str, &str, bool)]) -> serde_json::Value {
    let mut fields = serde_json::Map::new();
    let mut required = Vec::new();

    for (name, description, is_required) in properties {
        fields.insert(
            (*name).to_owned(),
            serde_json::json!({ "type": "string", "description": description }),
        );
        if *is_required {
            required.push(serde_json::Value::String((*name).to_owned()));
        }
    }

    serde_json::json!({
        "type": "object",
        "properties": serde_json::Value::Object(fields),
        "required": serde_json::Value::Array(required),
        // Claude invents plausible-looking extra arguments when a schema does
        // not forbid them; refusing here turns that into a validation error it
        // can see rather than a silently ignored field.
        "additionalProperties": false,
    })
}

/// Read a required string argument.
pub fn required_str(arguments: &serde_json::Value, name: &str) -> Result<String, ToolOutcome> {
    arguments
        .get(name)
        .and_then(|value| value.as_str())
        .filter(|value| !value.trim().is_empty())
        .map(str::to_owned)
        .ok_or_else(|| ToolOutcome::error(format!("the `{name}` argument is required")))
}

/// Read an optional string argument.
pub fn optional_str(arguments: &serde_json::Value, name: &str) -> Option<String> {
    arguments
        .get(name)
        .and_then(|value| value.as_str())
        .filter(|value| !value.trim().is_empty())
        .map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;
    use forge_crypto::token::Role;

    #[test]
    fn a_schema_marks_only_the_required_fields() {
        let schema = object_schema(&[
            ("machine", "Which machine", true),
            ("since", "Optional window", false),
        ]);

        assert_eq!(schema["type"], "object");
        assert_eq!(schema["required"].as_array().unwrap().len(), 1);
        assert_eq!(schema["required"][0], "machine");
        assert_eq!(schema["properties"]["since"]["type"], "string");
        assert!(!schema["properties"]["since"]["description"].is_null());
    }

    #[test]
    fn a_schema_refuses_invented_arguments() {
        // Claude fills in plausible extra fields when nothing forbids it.
        let schema = object_schema(&[("a", "x", true)]);
        assert_eq!(schema["additionalProperties"], false);
    }

    #[test]
    fn a_missing_required_argument_is_a_readable_refusal() {
        let failure = required_str(&serde_json::json!({}), "machine").unwrap_err();
        assert!(failure.is_error);
        assert!(failure.text.contains("machine"));
    }

    #[test]
    fn a_blank_argument_counts_as_missing() {
        // An empty string reaching a lookup produces a confusing "not found"
        // instead of "you did not say which".
        assert!(required_str(&serde_json::json!({ "machine": "   " }), "machine").is_err());
        assert_eq!(
            optional_str(&serde_json::json!({ "since": "" }), "since"),
            None
        );
    }

    #[test]
    fn a_viewer_may_read_but_not_act() {
        let viewer = Caller {
            account_id: "a".into(),
            org_id: "o".into(),
            role: Role::Viewer,
        };
        let member = Caller {
            role: Role::Member,
            ..viewer.clone()
        };
        assert!(!viewer.can_act());
        assert!(member.can_act());
    }
}
