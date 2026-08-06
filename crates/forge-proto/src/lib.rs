//! The RelayForge wire contract.
//!
//! This crate is the answer to one question: *what do the runner and a client
//! have to agree on?* It holds the shapes and nothing else — no rules, no
//! storage, no I/O, no async, and no dependency on any other crate in this
//! workspace. That is what makes it safe for everything else to depend on.
//!
//! # Why this is a crate and not a module
//!
//! Four implementations parse these bytes, and three of them are not compiled
//! here: the web PWA and the React Native app share
//! `packages/client-core/src/api.ts`, and the watch has a hand-written Swift
//! version. When the shapes lived next to the code that produced them — the
//! event enum inside the runner's `state` module, the read models inside its
//! axum handlers — "what is on the wire" was only answerable by reading a web
//! server. Now it is answerable by reading this crate.
//!
//! It also breaks a dependency that pointed the wrong way. The command layer
//! reached *up* into the HTTP module for its reply types, because that is where
//! the read models happened to live, which meant the transport-independent path
//! could not be compiled without axum.
//!
//! # Shape, not policy
//!
//! The line this crate aims to hold is that a type here describes what a field
//! *is*, never what it *means*. [`Risk`] names three classes but does not decide
//! which commands land in them; [`types::PlanStep`] carries a status but not
//! which transitions are legal.
//!
//! Two things are deliberate exceptions:
//!
//! - The `as_str`/`FromStr` pairs. Those are the storage and wire *encoding* of
//!   a variant, which is shape.
//! - Projections between wire shapes, like [`views::PlanProgress::of`]. They
//!   read one contract and produce another and reach for nothing else.
//!
//! And one is a known violation, not a design: [`Budget::is_warning`] and
//! [`Budget::is_exhausted`] carry the 80%/100% thresholds, and
//! `From<Budget> for BudgetView` turns them into the string clients switch on.
//! Those are policy. They arrived here with the verbatim move of the type they
//! hang off and are the next thing out — see `forge-domain`.

pub mod commands;
pub mod diff;
pub mod events;
pub mod hello;
pub mod types;
pub mod views;

pub use commands::{Command, DeviceFrame, PlanAction, Review};
pub use diff::{ChangeKind, ChangeSet, DiffLine, FileDiff, Hunk, Tag};
pub use events::{CommandRejected, ServerEvent};
pub use hello::{Capability, Hello, PROTOCOL_VERSION, ProtocolVersion};
pub use types::{
    Agent, AgentTask, Approval, Avoided, BatchItem, BatchStatus, Budget, DecidedVia, Decision,
    Device, DeviceKind, Dispatch, Machine, ParseEnumError, Plan, PlanStep, PlanStepStatus, Repo,
    Risk, Session, SessionStatus, TaskStatus, TaskType, Tier, Usage, UsageEvent,
};
pub use views::{
    AgentView, ApprovalView, BatchQueueView, BudgetView, DashboardView, FleetView, OutputLine,
    PlanProgress, PlanStepView, SessionDetail, SessionView, SpendBucket, TaskDetail, TaskView,
    TierSlice,
};

/// The relay channel a runner publishes on, derived from its public key.
///
/// `forge-` followed by the first [`CHANNEL_KEY_CHARS`] characters of the
/// base64url public key: stable across restarts without being stored anywhere,
/// and unguessable, which is what keeps a stranger from joining the channel and
/// watching ciphertext go past.
///
/// This lives here, in the crate both binaries already depend on, because it was
/// previously derived twice — once in `forge-runner`'s binary and once in the
/// Tauri app. The two agreed, but nothing made them: they can be pointed at the
/// same `forge.key`, and a drift would have published on a channel no paired
/// device listens to, with no error anywhere to say so.
pub fn channel_for(public_key: &str) -> String {
    format!(
        "forge-{}",
        public_key
            .chars()
            .take(CHANNEL_KEY_CHARS)
            .collect::<String>()
    )
}

/// How much of the public key the channel name carries.
///
/// Changing this unpairs every device that has already stored a channel, so it
/// is a migration rather than a tuning knob.
pub const CHANNEL_KEY_CHARS: usize = 16;

#[cfg(test)]
mod channel_tests {
    use super::*;

    #[test]
    fn a_channel_is_the_prefix_of_its_key() {
        assert_eq!(
            channel_for("kFLWAF8DqRIvUm8gghrfSuEm16Imi1ZSMnZW3kO9pkI"),
            "forge-kFLWAF8DqRIvUm8g"
        );
    }

    #[test]
    fn two_keys_do_not_share_a_channel() {
        // A shared channel would put two runners' ciphertext on one fan-out, and
        // pairing one phone would show it the other machine's traffic.
        assert_ne!(
            channel_for("aaaaaaaaaaaaaaaaaaaa"),
            channel_for("bbbbbbbbbbbbbbbbbbbb")
        );
    }

    #[test]
    fn a_short_key_does_not_panic() {
        // Never reachable with a real 32-byte key, but truncating a string by
        // byte index would have made it a panic rather than a short channel.
        assert_eq!(channel_for("abc"), "forge-abc");
        assert_eq!(channel_for(""), "forge-");
    }
}
