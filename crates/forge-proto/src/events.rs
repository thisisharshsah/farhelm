//! What the runner pushes to connected clients.
//!
//! One enum, externally tagged on `type`, carried two ways: over SSE on
//! `/v1/events` for a browser on loopback, and sealed inside an
//! `forge_crypto::Envelope` for a device on the relay. The bytes are the same
//! either way, which is why this is a contract and not a detail of whichever
//! transport happened to be written first.
//!
//! External tagging is what makes the wire forward-compatible in one direction:
//! a client that meets an unknown `type` fails to parse that frame cleanly
//! rather than misreading it as the nearest variant it does know. Negotiating in
//! the *other* direction — the runner knowing what a device can handle before it
//! sends — needs [`crate::hello`], which is defined but not yet spoken.

use serde::{Deserialize, Serialize};

use crate::types::{Approval, Decision, TaskStatus};
use crate::views::OutputLine;

/// Everything pushed to connected clients.
///
/// Round-trips through `Deserialize` as well as `Serialize`, because the device
/// side of the relay link parses exactly these bytes back.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerEvent {
    /// A session's status, plan progress, or spend changed — re-fetch it.
    SessionUpsert {
        session_id: String,
    },
    OutputChunk {
        session_id: String,
        /// Flattened: `seq`, `text` and `at_ms` sit at the top level of the
        /// frame, not under a `line` key. The Swift client depends on that.
        #[serde(flatten)]
        line: OutputLine,
    },
    ApprovalRequest {
        approval: Approval,
    },
    ApprovalDecision {
        approval_id: String,
        session_id: String,
        decision: Decision,
    },
    /// Stage-1 budget guard fired (C5). `pct` is the fraction of cap consumed.
    BudgetAlert {
        session_id: String,
        pct: f64,
        hard_stop: bool,
    },
    /// A native agent task changed state — most importantly, reached
    /// `awaiting_review` with a diff somebody has to look at.
    ///
    /// Carries the headline rather than only an id, so a notification can say
    /// "3 files, +42 −17" without the client fetching the task first. The diff
    /// itself is not in here: it can be megabytes, and this goes to every
    /// connected device on every state change.
    TaskUpsert {
        task_id: String,
        session_id: String,
        status: TaskStatus,
        /// `3 files, +42 −17`.
        summary: String,
    },
}

/// Why a command did not happen.
///
/// Shaped like a [`ServerEvent`] so it arrives on the client's existing event
/// path, but never broadcast — only ever sealed to the device that sent the
/// failing command. Over loopback the client sees an HTTP status instead; on the
/// relay a rejected instruction would otherwise evaporate, and "I tapped it and
/// nothing happened" is the worst failure a remote control surface can have.
///
/// It is a separate type rather than a `ServerEvent` variant because it is not
/// an event: nothing happened. It cannot be broadcast, and giving it a variant
/// would make it possible to publish one by accident.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename = "command_error")]
pub struct CommandRejected {
    pub message: String,
}

impl CommandRejected {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `command_error` is a `type` no `ServerEvent` variant produces, and the
    /// clients switch on `type` across both. Pinned here because the two live in
    /// one namespace on the wire while being separate types in Rust.
    #[test]
    fn a_rejection_does_not_collide_with_an_event_tag() {
        let rejection = serde_json::to_value(CommandRejected::new("nope")).unwrap();
        assert_eq!(
            rejection,
            serde_json::json!({"type": "command_error", "message": "nope"})
        );
        // And it is not mistakable for an event.
        assert!(serde_json::from_value::<ServerEvent>(rejection).is_err());
    }
}
