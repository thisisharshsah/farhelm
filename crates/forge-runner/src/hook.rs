//! The Claude Code hook bridge (M1).
//!
//! `forge-runner hook` is registered as a hook command. Claude Code runs it as a
//! child process, writes the event as JSON on stdin, and reads a decision as
//! JSON from stdout. That makes the bridge language-agnostic — nothing about it
//! requires the runner to be written in the agent's language.
//!
//! ## The failure mode is the design
//!
//! This process sits between the agent and its next action. Three rules follow:
//!
//! 1. **Unreachable runner ⇒ `defer`, never `allow`.** Deferring hands the
//!    decision back to Claude Code's own permission flow, so a developer at the
//!    terminal sees the usual prompt. RelayForge being down degrades to plain
//!    Claude Code rather than to an unsupervised agent.
//! 2. **Nobody answered ⇒ `deny`, never `allow`.** An unanswered request is
//!    recorded as `timeout` and denied with a reason. The agent can retry or ask
//!    differently; it cannot proceed unsupervised.
//! 3. **Never exit 2 on an internal error.** Exit 2 makes stderr a *blocking*
//!    reason, which would turn a bug in this bridge into a blocked agent. Bugs
//!    exit 0 with `defer`.
//!
//! ## Schema drift
//!
//! The design document's own risk register flags hook-API drift. Every field is
//! parsed with `#[serde(default)]` and unknown fields are ignored, so a new key
//! in the payload cannot crash the bridge. The fields consumed here are from the
//! documented schema as of August 2026; [`HookEvent`] is the one place to update
//! if they move.

use serde::{Deserialize, Serialize};

/// Everything the bridge understands, normalised away from the wire shape.
#[derive(Debug, Clone, PartialEq)]
pub enum HookEvent {
    /// A tool is about to run and needs a decision.
    ToolRequest {
        /// Which wire event this came from — the reply shape differs.
        kind: RequestKind,
        session_id: String,
        cwd: String,
        tool_name: String,
        /// Rendered for the approval card: the command, or the file being written.
        payload: String,
        tool_use_id: Option<String>,
    },
    /// The agent finished its turn.
    Stopped {
        session_id: String,
        cwd: String,
        last_message: String,
    },
    /// The agent wants attention.
    Notified {
        session_id: String,
        cwd: String,
        notification_type: String,
        message: String,
    },
    /// A documented event the bridge has no opinion about.
    Ignored { hook_event_name: String },
}

/// Which permission event fired. They carry the same information and take
/// *different* reply shapes, which is the only reason the distinction survives
/// this far into the code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequestKind {
    PreToolUse,
    PermissionRequest,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    Allow,
    Deny,
    /// Hand the decision back to Claude Code's normal permission flow.
    Defer,
}

/* ------------------------------------------------------------- wire input */

#[derive(Debug, Deserialize, Default)]
#[serde(default)]
struct WireEvent {
    hook_event_name: String,
    session_id: String,
    cwd: String,
    tool_name: String,
    tool_input: serde_json::Value,
    tool_use_id: Option<String>,
    last_assistant_message: String,
    notification_type: String,
    message: String,
}

/// Render `tool_input` into the one line a human decides on.
///
/// Bash carries a command; edits carry a path. Anything else falls back to
/// compact JSON, which is ugly but never lies about what was requested.
fn summarise(tool_name: &str, input: &serde_json::Value) -> String {
    let field = |key: &str| input.get(key).and_then(|value| value.as_str());

    if let Some(command) = field("command") {
        return command.to_owned();
    }

    if let Some(path) = field("file_path").or_else(|| field("path")) {
        let action = match tool_name.to_lowercase().as_str() {
            "write" => "write",
            "edit" | "multiedit" | "str_replace_based_edit_tool" => "edit",
            "read" => "read",
            _ => "touch",
        };
        return format!("{action} {path}");
    }

    if let Some(url) = field("url") {
        return url.to_owned();
    }
    if let Some(query) = field("query").or_else(|| field("pattern")) {
        return query.to_owned();
    }

    match input {
        serde_json::Value::Null => tool_name.to_owned(),
        other => other.to_string(),
    }
}

/// Parse a hook payload. Unrecognised events become [`HookEvent::Ignored`]
/// rather than an error — a hook that fails on an event it was not asked about
/// is a hook that breaks on the next release.
pub fn parse(raw: &str) -> Result<HookEvent, serde_json::Error> {
    let wire: WireEvent = serde_json::from_str(raw)?;

    Ok(match wire.hook_event_name.as_str() {
        name @ ("PreToolUse" | "PermissionRequest") => HookEvent::ToolRequest {
            kind: if name == "PreToolUse" {
                RequestKind::PreToolUse
            } else {
                RequestKind::PermissionRequest
            },
            payload: summarise(&wire.tool_name, &wire.tool_input),
            session_id: wire.session_id,
            cwd: wire.cwd,
            tool_name: wire.tool_name,
            tool_use_id: wire.tool_use_id,
        },
        "Stop" | "SubagentStop" => HookEvent::Stopped {
            session_id: wire.session_id,
            cwd: wire.cwd,
            last_message: wire.last_assistant_message,
        },
        "Notification" => HookEvent::Notified {
            session_id: wire.session_id,
            cwd: wire.cwd,
            notification_type: wire.notification_type,
            message: wire.message,
        },
        other => HookEvent::Ignored {
            hook_event_name: other.to_owned(),
        },
    })
}

/* ------------------------------------------------------------ wire output */

#[derive(Debug, Serialize)]
struct PreToolUseOutput<'a> {
    #[serde(rename = "hookEventName")]
    hook_event_name: &'a str,
    #[serde(rename = "permissionDecision")]
    permission_decision: &'a str,
    #[serde(rename = "permissionDecisionReason")]
    permission_decision_reason: String,
}

#[derive(Debug, Serialize)]
struct PermissionRequestDecision<'a> {
    behavior: &'a str,
}

#[derive(Debug, Serialize)]
struct PermissionRequestOutput<'a> {
    #[serde(rename = "hookEventName")]
    hook_event_name: &'a str,
    decision: PermissionRequestDecision<'a>,
}

/// Build the JSON Claude Code expects on stdout for a decision.
///
/// The two permission events take genuinely different shapes:
/// `PreToolUse` uses `permissionDecision`, `PermissionRequest` nests a
/// `decision.behavior`. `PermissionRequest` has no "defer" — omitting the
/// decision entirely is how you fall back to the normal flow there.
pub fn decision_json(kind: RequestKind, decision: Decision, reason: &str) -> serde_json::Value {
    match kind {
        RequestKind::PreToolUse => serde_json::json!({
            "hookSpecificOutput": PreToolUseOutput {
                hook_event_name: "PreToolUse",
                permission_decision: match decision {
                    Decision::Allow => "allow",
                    Decision::Deny => "deny",
                    Decision::Defer => "defer",
                },
                permission_decision_reason: reason.to_owned(),
            }
        }),
        RequestKind::PermissionRequest => match decision {
            Decision::Defer => serde_json::json!({ "systemMessage": reason }),
            _ => serde_json::json!({
                "hookSpecificOutput": PermissionRequestOutput {
                    hook_event_name: "PermissionRequest",
                    decision: PermissionRequestDecision {
                        behavior: if decision == Decision::Allow { "allow" } else { "deny" },
                    },
                }
            }),
        },
    }
}

/// The reply for a non-decision event: acknowledge and stay out of the way.
pub fn acknowledge() -> serde_json::Value {
    serde_json::json!({ "continue": true, "suppressOutput": true })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verbatim from the documented schema, so a drift in the real payload
    /// shows up here as a failing test rather than in production.
    const PRE_TOOL_USE: &str = r#"{
        "session_id": "abc123",
        "prompt_id": "550e8400-e29b-41d4-a716-446655440000",
        "transcript_path": "/home/user/.claude/projects/x/transcript.jsonl",
        "cwd": "/home/user/my-project",
        "permission_mode": "default",
        "hook_event_name": "PreToolUse",
        "effort": { "level": "high" },
        "tool_name": "Bash",
        "tool_input": {
            "command": "rm -rf /tmp/build",
            "description": "Clean build artifacts",
            "timeout": 120000,
            "run_in_background": false
        },
        "tool_use_id": "toolu_01ABC123"
    }"#;

    #[test]
    fn a_pre_tool_use_payload_becomes_a_tool_request() {
        match parse(PRE_TOOL_USE).unwrap() {
            HookEvent::ToolRequest {
                kind,
                session_id,
                cwd,
                tool_name,
                payload,
                tool_use_id,
            } => {
                assert_eq!(kind, RequestKind::PreToolUse);
                assert_eq!(session_id, "abc123");
                assert_eq!(cwd, "/home/user/my-project");
                assert_eq!(tool_name, "Bash");
                assert_eq!(payload, "rm -rf /tmp/build");
                assert_eq!(tool_use_id.as_deref(), Some("toolu_01ABC123"));
            }
            other => panic!("expected a tool request, got {other:?}"),
        }
    }

    #[test]
    fn an_unknown_field_does_not_break_the_bridge() {
        // Hook payloads gain fields between releases; that must never be fatal.
        let payload = r#"{"hook_event_name":"PreToolUse","session_id":"s",
            "tool_name":"Bash","tool_input":{"command":"ls"},
            "some_field_added_next_year": {"nested": true}}"#;
        assert!(matches!(
            parse(payload).unwrap(),
            HookEvent::ToolRequest { .. }
        ));
    }

    #[test]
    fn a_missing_field_does_not_break_the_bridge_either() {
        let event = parse(r#"{"hook_event_name":"PreToolUse"}"#).unwrap();
        assert!(matches!(event, HookEvent::ToolRequest { .. }));
    }

    #[test]
    fn an_unrecognised_event_is_ignored_rather_than_rejected() {
        let event = parse(r#"{"hook_event_name":"SomeFutureEvent","session_id":"s"}"#).unwrap();
        assert_eq!(
            event,
            HookEvent::Ignored {
                hook_event_name: "SomeFutureEvent".into()
            }
        );
    }

    #[test]
    fn malformed_json_is_an_error_not_a_silent_allow() {
        assert!(parse("not json at all").is_err());
    }

    #[test]
    fn stop_carries_the_last_message() {
        let event = parse(
            r#"{"hook_event_name":"Stop","session_id":"s","cwd":"/w",
                "last_assistant_message":"All tests pass."}"#,
        )
        .unwrap();
        assert_eq!(
            event,
            HookEvent::Stopped {
                session_id: "s".into(),
                cwd: "/w".into(),
                last_message: "All tests pass.".into(),
            }
        );
    }

    #[test]
    fn notification_carries_its_type() {
        match parse(
            r#"{"hook_event_name":"Notification","session_id":"s","cwd":"/w",
                "notification_type":"agent_needs_input","message":"Waiting."}"#,
        )
        .unwrap()
        {
            HookEvent::Notified {
                notification_type,
                message,
                ..
            } => {
                assert_eq!(notification_type, "agent_needs_input");
                assert_eq!(message, "Waiting.");
            }
            other => panic!("expected a notification, got {other:?}"),
        }
    }

    #[test]
    fn a_bash_call_is_summarised_as_its_command() {
        let input = serde_json::json!({ "command": "pytest -x", "description": "run tests" });
        assert_eq!(summarise("Bash", &input), "pytest -x");
    }

    #[test]
    fn an_edit_is_summarised_as_the_path_it_touches() {
        let input = serde_json::json!({ "file_path": "src/retry.rs", "old_string": "a" });
        assert_eq!(summarise("Edit", &input), "edit src/retry.rs");
        assert_eq!(summarise("Write", &input), "write src/retry.rs");
    }

    #[test]
    fn an_unknown_tool_shape_falls_back_to_json_rather_than_lying() {
        let input = serde_json::json!({ "unexpected": 42 });
        assert_eq!(summarise("Mystery", &input), r#"{"unexpected":42}"#);
    }

    #[test]
    fn a_tool_with_no_input_is_summarised_as_its_name() {
        assert_eq!(
            summarise("Something", &serde_json::Value::Null),
            "Something"
        );
    }

    #[test]
    fn pre_tool_use_replies_use_permission_decision() {
        let json = decision_json(
            RequestKind::PreToolUse,
            Decision::Allow,
            "approved from phone",
        );
        assert_eq!(json["hookSpecificOutput"]["permissionDecision"], "allow");
        assert_eq!(json["hookSpecificOutput"]["hookEventName"], "PreToolUse");
        assert_eq!(
            json["hookSpecificOutput"]["permissionDecisionReason"],
            "approved from phone"
        );
    }

    #[test]
    fn permission_request_replies_nest_a_behavior() {
        let json = decision_json(RequestKind::PermissionRequest, Decision::Deny, "denied");
        assert_eq!(json["hookSpecificOutput"]["decision"]["behavior"], "deny");
        assert_eq!(
            json["hookSpecificOutput"]["hookEventName"],
            "PermissionRequest"
        );
    }

    #[test]
    fn deferring_a_permission_request_omits_the_decision_entirely() {
        // There is no "defer" behaviour on that event — saying nothing is how
        // you fall through to the normal permission flow.
        let json = decision_json(
            RequestKind::PermissionRequest,
            Decision::Defer,
            "runner down",
        );
        assert!(json.get("hookSpecificOutput").is_none());
        assert_eq!(json["systemMessage"], "runner down");
    }

    #[test]
    fn deferring_a_pre_tool_use_is_an_explicit_decision_value() {
        let json = decision_json(RequestKind::PreToolUse, Decision::Defer, "runner down");
        assert_eq!(json["hookSpecificOutput"]["permissionDecision"], "defer");
    }
}
