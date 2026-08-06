//! What a *device* can ask the runner to do.
//!
//! Deliberately small: anything a device can make the runner do is on this list,
//! and adding to it is a decision rather than an accident.
//!
//! Both transports carry these. The localhost HTTP API turns a route and a body
//! into one; the relay link opens a sealed envelope and finds one already. They
//! meet at a single executor, which is what stops a new transport from shipping
//! without the rule that a destructive command cannot be cleared from a watch.

use serde::{Deserialize, Serialize};

use crate::hello::Hello;
use crate::types::Decision;

/// What a paired device can put inside a sealed envelope.
///
/// Almost always a [`Command`]. A [`Hello`] is the exception, and it is what
/// makes the protocol able to change: it tells the runner what this device can
/// handle, so a new event can be sent to devices that understand it and withheld
/// from those that do not.
///
/// # Untagged, deliberately
///
/// A `Command` is `{"type": "decide", ...}`. Adding an outer tag to distinguish
/// the two would have rewritten that shape and broken every shipped client, so
/// the two are told apart by their contents instead: a `Hello` has `protocol`
/// and no `type`, a `Command` has `type` and no `protocol`. `serde(untagged)`
/// tries each in order.
///
/// The cost of untagged is a poor error message when neither matches — serde
/// reports "data did not match any variant" rather than naming the field that
/// was wrong. That is acceptable here because the sender is a paired device
/// whose message already decrypted, so a malformed frame is a version skew
/// rather than an attack, and the runner's answer to either is the same: ignore
/// it and keep the link up.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum DeviceFrame {
    /// Sent once, on connect, by a client new enough to send one.
    Hello(Hello),
    Command(Command),
}

/// A command from a paired device.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Command {
    /// Approve or deny a pending permission request.
    Decide {
        approval_id: String,
        decision: Decision,
    },
    /// Send a short instruction to a running session (A4).
    Instruct { session_id: String, text: String },
    /// Pause, resume, or skip a plan step (B3).
    PlanControl {
        session_id: String,
        action: PlanAction,
    },
    /// Ask for one session's detail: plan, output tail, pending approval.
    SessionSnapshot { session_id: String },
    /// Ask for one session's cost dashboard — the third snapshot type.
    ///
    /// `since_ms` bounds the window the same way `?since_ms=` does on the HTTP
    /// endpoint. `None` means everything, which is what the screen opens with.
    /// The `default` is load-bearing: a shipped client that omits the field must
    /// keep parsing.
    DashboardSnapshot {
        session_id: String,
        #[serde(default)]
        since_ms: Option<i64>,
    },
    /// Approve or reject a native agent task's proposed change set.
    ///
    /// The diff equivalent of [`Command::Decide`], and the reason the review
    /// screen works from a phone at all. Approving *writes files*, which is why
    /// it goes through the same gated path as everything else here rather than
    /// being an HTTP-only endpoint.
    ReviewTask {
        task_id: String,
        decision: Review,
        #[serde(default)]
        note: Option<String>,
    },
    /// Ask for one task's detail, including the diff to review.
    TaskSnapshot { task_id: String },
    /// Ask for the task list. No diffs — see [`crate::views::TaskView`].
    TaskList,
    /// Take an applied change set back off the working tree.
    ///
    /// Available from a phone for the same reason approving is: the overlay kept
    /// both sides, so this writes back only what the agent replaced, and it
    /// refuses outright if anything has moved since.
    RevertTask { task_id: String },
    /// Ask for the current fleet.
    ///
    /// A device on the relay has no request/response channel — it receives
    /// events on one socket and sends on the same one — so "what is the state
    /// right now" has to be a message like any other. The HTTP client uses
    /// `GET /v1/fleet` instead and never sends this.
    Snapshot,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlanAction {
    Pause,
    Resume,
    Skip,
}

/// A reviewer's verdict on a proposed change set.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Review {
    Approve,
    Reject,
}

#[cfg(test)]
mod frame_tests {
    use super::*;
    use crate::hello::{Capability, Hello};
    use crate::types::Decision;

    fn every_command() -> Vec<Command> {
        vec![
            Command::Decide {
                approval_id: "a1".into(),
                decision: Decision::Approved,
            },
            Command::Instruct {
                session_id: "s1".into(),
                text: "focus on retries".into(),
            },
            Command::PlanControl {
                session_id: "s1".into(),
                action: PlanAction::Skip,
            },
            Command::SessionSnapshot {
                session_id: "s1".into(),
            },
            Command::DashboardSnapshot {
                session_id: "s1".into(),
                since_ms: None,
            },
            Command::ReviewTask {
                task_id: "t1".into(),
                decision: Review::Reject,
                note: None,
            },
            Command::TaskSnapshot {
                task_id: "t1".into(),
            },
            Command::TaskList,
            Command::RevertTask {
                task_id: "t1".into(),
            },
            Command::Snapshot,
        ]
    }

    /// The whole risk of `untagged`, tested exhaustively.
    ///
    /// If any command could also satisfy `Hello`, serde would silently pick the
    /// first matching variant and the runner would record a capability
    /// announcement instead of approving something. `Command::TaskList` and
    /// `Command::Snapshot` are the ones to watch: they serialise to a single
    /// `type` key and nothing else, which is as close to an empty object as this
    /// enum gets.
    #[test]
    fn no_command_is_mistaken_for_a_hello() {
        for command in every_command() {
            let json = serde_json::to_string(&command).unwrap();
            let frame: DeviceFrame = serde_json::from_str(&json).unwrap();
            assert_eq!(
                frame,
                DeviceFrame::Command(command.clone()),
                "{json} parsed as the wrong frame"
            );
        }
    }

    /// ...and the other direction.
    #[test]
    fn a_hello_is_not_mistaken_for_a_command() {
        for hello in [
            Hello::default(),
            Hello::current(&[Capability::TASK_REVIEW, Capability::DASHBOARD]),
            Hello {
                agent: Some("relayforge-ios/0.1.0".into()),
                ..Hello::default()
            },
        ] {
            let json = serde_json::to_string(&hello).unwrap();
            let frame: DeviceFrame = serde_json::from_str(&json).unwrap();
            assert_eq!(
                frame,
                DeviceFrame::Hello(hello),
                "{json} parsed as a command"
            );
        }
    }

    /// A command's bytes are unchanged by the frame existing.
    ///
    /// The reason `DeviceFrame` is untagged rather than tagged: every shipped
    /// client seals a bare `Command`, and wrapping it would have been a breaking
    /// change disguised as a refactor.
    #[test]
    fn wrapping_a_command_in_a_frame_does_not_change_its_bytes() {
        for command in every_command() {
            assert_eq!(
                serde_json::to_string(&DeviceFrame::Command(command.clone())).unwrap(),
                serde_json::to_string(&command).unwrap(),
            );
        }
    }

    /// Neither shape matches, so the frame is refused rather than guessed.
    #[test]
    fn an_unrecognised_frame_is_an_error() {
        assert!(serde_json::from_str::<DeviceFrame>(r#"{"type":"self_destruct"}"#).is_err());
        assert!(serde_json::from_str::<DeviceFrame>(r#"{"nonsense":true}"#).is_err());
    }
}
