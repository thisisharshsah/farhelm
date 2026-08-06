//! The types the runner, the gateway, the relay and every client agree on.
//!
//! Every enum that lands in a `TEXT` column has an explicit `as_str` /
//! `FromStr` pair. The string form is the storage and wire format, so it is
//! part of the schema contract — do not change a variant's string without a
//! migration.
//!
//! Nothing here decides anything. The rules that read these shapes — what makes
//! a command destructive, when a budget is exhausted, what a step transition is
//! allowed to be — live in `forge-domain`, so that a client can depend on the
//! contract without linking the policy.

use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Serialize};

/// A value stored in a `TEXT` column did not match any known variant.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseEnumError {
    pub kind: &'static str,
    pub value: String,
}

impl fmt::Display for ParseEnumError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "unknown {}: {:?}", self.kind, self.value)
    }
}

impl std::error::Error for ParseEnumError {}

/// Generates `as_str`, `Display`, `FromStr`, and `ALL` for a simple C-like enum.
macro_rules! text_enum {
    (
        $(#[$meta:meta])*
        $name:ident { $($variant:ident => $text:literal),+ $(,)? }
    ) => {
        $(#[$meta])*
        #[derive(
            Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize,
        )]
        pub enum $name {
            // Each variant is renamed to *its own* storage string rather than
            // relying on `rename_all`. A derived convention and an explicit
            // `as_str` will agree right up until they do not: `ClaudeCode` is
            // `claude-code` in the database and was `claude_code` over JSON, so
            // an API that echoed a stored value could not parse it back.
            $(#[serde(rename = $text)] $variant),+
        }

        impl $name {
            pub const ALL: &'static [$name] = &[$($name::$variant),+];

            pub const fn as_str(self) -> &'static str {
                match self {
                    $($name::$variant => $text),+
                }
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                // `pad`, not `write_str`, so `{tier:<10}` in the dashboard aligns.
                f.pad(self.as_str())
            }
        }

        impl FromStr for $name {
            type Err = ParseEnumError;

            fn from_str(s: &str) -> Result<Self, Self::Err> {
                match s {
                    $($text => Ok($name::$variant),)+
                    other => Err(ParseEnumError {
                        kind: stringify!($name),
                        value: other.to_owned(),
                    }),
                }
            }
        }
    };
}

text_enum! {
    /// Which agent a session wraps.
    ///
    /// Adding a variant needs a matching row in [`crate::agent::AGENTS`]; a test
    /// there fails otherwise. Stored as text, so new variants are backward
    /// compatible with an existing database.
    ///
    /// `Forge` is the odd one out: RelayForge's own agent, which has no binary
    /// and no terminal. It runs in-process through the cost gateway and proposes
    /// a diff rather than editing the working tree.
    Agent {
        ClaudeCode => "claude-code",
        Codex => "codex",
        OpenCode => "opencode",
        Aider => "aider",
        Gemini => "gemini",
        Cursor => "cursor",
        Shell => "shell",
        Forge => "forge",
    }
}

text_enum! {
    /// Session lifecycle. `AwaitingApproval` is the state the phone/watch acts on.
    SessionStatus {
        Running => "running",
        AwaitingApproval => "awaiting_approval",
        Paused => "paused",
        Done => "done",
        Dead => "dead",
    }
}

text_enum! {
    /// Model tier a call was routed to (pipeline stage 4).
    ///
    /// NOTE: `Batch` sits in the same column as `Small`/`Large`, so a batched
    /// call loses which model tier ran it — that costs us the tier split in the
    /// dashboard for deferred work. Ships as designed for v1; the migration-safe
    /// fix is a separate `dispatch` column, added when C6 lands.
    Tier {
        Small => "small",
        Large => "large",
        Batch => "batch",
    }
}

text_enum! {
    /// What the call was for. Drives the static router table (M2).
    TaskType {
        Triage => "triage",
        SelectFiles => "select_files",
        Summarize => "summarize",
        CommitMsg => "commit_msg",
        Title => "title",
        Edit => "edit",
        Refactor => "refactor",
        Plan => "plan",
        HardDebug => "hard_debug",
    }
}

text_enum! {
    /// Why a call cost $0. `None` on the event means the call actually ran.
    Avoided {
        PreGate => "pre_gate",
        ResponseCache => "response_cache",
    }
}

text_enum! {
    /// Risk class assigned by the destructive-command classifier (D3).
    Risk {
        Low => "low",
        Medium => "medium",
        Destructive => "destructive",
    }
}

text_enum! {
    Decision {
        Approved => "approved",
        Denied => "denied",
        Timeout => "timeout",
    }
}

text_enum! {
    DecidedVia {
        Watch => "watch",
        Phone => "phone",
        Web => "web",
        AutoPolicy => "auto_policy",
    }
}

text_enum! {
    PlanStepStatus {
        Todo => "todo",
        Active => "active",
        Done => "done",
        Skipped => "skipped",
        Failed => "failed",
    }
}

text_enum! {
    DeviceKind {
        Phone => "phone",
        Watch => "watch",
        Web => "web",
    }
}

/// A machine the runner daemon is installed on.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Machine {
    pub id: String,
    pub name: String,
    pub pubkey: String,
    pub last_seen_at: Option<i64>,
    pub created_at: i64,
}

/// A git repository known to a machine.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Repo {
    pub id: String,
    pub machine_id: String,
    pub path: String,
    pub name: String,
    /// `None` = no repo cap.
    pub budget_usd: Option<f64>,
}

/// One agent process lifecycle.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Session {
    pub id: String,
    pub repo_id: String,
    pub agent: Agent,
    pub tmux_target: Option<String>,
    pub status: SessionStatus,
    pub plan_id: Option<String>,
    pub budget_usd: Option<f64>,
    pub spent_usd: f64,
    pub started_at: i64,
    pub ended_at: Option<i64>,
    /// The agent's own session id, learned from the first hook callback. `None`
    /// for a session the runner started but the agent has not called back from.
    pub agent_session_id: Option<String>,
}

/// Token counts for a single model call, as reported by the provider.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Usage {
    pub input_tokens: u32,
    pub output_tokens: u32,
    pub cache_write_tokens: u32,
    pub cache_read_tokens: u32,
}

impl Usage {
    /// Cache-read ratio, the Appendix A metric: `read / (read + input)`.
    ///
    /// Returns `None` when no billable input flowed, so an idle session reads as
    /// "no data" rather than 0% and drags the average down.
    pub fn cache_read_ratio(&self) -> Option<f64> {
        let denominator = u64::from(self.cache_read_tokens) + u64::from(self.input_tokens);
        if denominator == 0 {
            return None;
        }
        Some(f64::from(self.cache_read_tokens) / denominator as f64)
    }
}

/// One row of the cost ledger. Append-only: `cost_usd` is computed at write
/// time so later price-table edits never rewrite history.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UsageEvent {
    pub id: String,
    pub session_id: String,
    pub model: String,
    pub tier: Tier,
    pub task_type: TaskType,
    pub usage: Usage,
    pub cost_usd: f64,
    pub avoided: Option<Avoided>,
    pub created_at: i64,
}

/// Budget state for a session or repo (`GET /v1/budget`).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Budget {
    pub cap_usd: Option<f64>,
    pub spent_usd: f64,
}

impl Budget {
    /// Fraction of the cap consumed. `None` when uncapped.
    pub fn pct(&self) -> Option<f64> {
        match self.cap_usd {
            Some(cap) if cap > 0.0 => Some(self.spent_usd / cap),
            _ => None,
        }
    }

    /// Pipeline stage 1: hard stop at 100%.
    pub fn is_exhausted(&self) -> bool {
        self.pct().is_some_and(|pct| pct >= 1.0)
    }

    /// Pipeline stage 1: wrist alert at 80%.
    pub fn is_warning(&self) -> bool {
        self.pct().is_some_and(|pct| pct >= 0.8)
    }
}

/// A file-backed plan. `content_hash` is what makes the file authoritative:
/// when it stops matching the file on disk, the mirror is rebuilt.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Plan {
    pub id: String,
    pub repo_id: String,
    pub file_path: String,
    pub content_hash: String,
    pub created_at: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlanStep {
    pub id: String,
    pub plan_id: String,
    /// 1-based position in the plan.
    pub ordinal: i64,
    pub title: String,
    pub status: PlanStepStatus,
    /// Commit created when the step completed (B1's checkpoint-per-step).
    pub checkpoint_sha: Option<String>,
}

/// A paired client device.
///
/// `pubkey` is what makes it a device rather than a stranger: the runner will
/// only accept commands it can verify against one of these.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Device {
    pub id: String,
    pub kind: DeviceKind,
    /// base64url X25519 public key, from `forge_crypto`.
    pub pubkey: String,
    /// WebPush endpoint, once the device registers one.
    pub push_token: Option<String>,
    pub paired_at: i64,
}

/// One permission request and its outcome. Kept forever: it is both the audit
/// trail and the training data for auto-approve policy.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Approval {
    pub id: String,
    pub session_id: String,
    /// `bash`, `write_file`, ...
    pub tool: String,
    /// The command or file summary shown on the card.
    pub payload: String,
    pub risk: Risk,
    /// `None` while the approval is still pending.
    pub decision: Option<Decision>,
    pub decided_via: Option<DecidedVia>,
    pub requested_at: i64,
    pub decided_at: Option<i64>,
}

impl Approval {
    pub fn is_pending(&self) -> bool {
        self.decision.is_none()
    }

    /// Destructive actions never get a one-tap wrist approval (D3) — the
    /// friction is the point.
    pub fn allows_watch_decision(&self) -> bool {
        self.risk != Risk::Destructive
    }

    /// Notification → decision latency, the Appendix A metric.
    pub fn latency_ms(&self) -> Option<i64> {
        Some(self.decided_at? - self.requested_at)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approval(risk: Risk) -> Approval {
        Approval {
            id: "approval-1".into(),
            session_id: "session-1".into(),
            tool: "bash".into(),
            payload: "pytest tests/billing -x".into(),
            risk,
            decision: None,
            decided_via: None,
            requested_at: 1_000,
            decided_at: None,
        }
    }

    #[test]
    fn destructive_approvals_are_phone_only() {
        assert!(approval(Risk::Low).allows_watch_decision());
        assert!(approval(Risk::Medium).allows_watch_decision());
        assert!(!approval(Risk::Destructive).allows_watch_decision());
    }

    #[test]
    fn latency_is_unknown_until_a_decision_lands() {
        let mut pending = approval(Risk::Low);
        assert!(pending.is_pending());
        assert_eq!(pending.latency_ms(), None);

        pending.decision = Some(Decision::Approved);
        pending.decided_via = Some(DecidedVia::Watch);
        pending.decided_at = Some(4_200);
        assert!(!pending.is_pending());
        assert_eq!(pending.latency_ms(), Some(3_200));
    }

    #[test]
    fn text_enums_round_trip_through_their_storage_form() {
        for tier in Tier::ALL {
            assert_eq!(Tier::from_str(tier.as_str()).unwrap(), *tier);
        }
        for task in TaskType::ALL {
            assert_eq!(TaskType::from_str(task.as_str()).unwrap(), *task);
        }
        for status in SessionStatus::ALL {
            assert_eq!(SessionStatus::from_str(status.as_str()).unwrap(), *status);
        }
    }

    #[test]
    fn unknown_text_is_an_error_not_a_silent_default() {
        let err = Tier::from_str("enormous").unwrap_err();
        assert_eq!(err.value, "enormous");
    }

    #[test]
    fn cache_read_ratio_is_none_when_nothing_was_billed() {
        assert_eq!(Usage::default().cache_read_ratio(), None);
    }

    #[test]
    fn cache_read_ratio_ignores_output_and_cache_writes() {
        let usage = Usage {
            input_tokens: 1_000,
            output_tokens: 9_999,
            cache_write_tokens: 9_999,
            cache_read_tokens: 3_000,
        };
        assert_eq!(usage.cache_read_ratio(), Some(0.75));
    }

    #[test]
    fn a_task_is_settled_once_a_human_or_a_failure_has_spoken() {
        assert!(!TaskStatus::Running.is_settled());
        assert!(!TaskStatus::AwaitingReview.is_settled());
        for settled in [
            TaskStatus::Applied,
            TaskStatus::Rejected,
            TaskStatus::NoChanges,
            TaskStatus::Failed,
            TaskStatus::Reverted,
        ] {
            assert!(settled.is_settled(), "{settled} should be terminal");
        }
    }

    #[test]
    fn only_an_applied_change_set_can_be_undone() {
        assert!(TaskStatus::Applied.can_revert());
        for cannot in [
            TaskStatus::Running,
            TaskStatus::AwaitingReview,
            // Never landed.
            TaskStatus::Rejected,
            TaskStatus::NoChanges,
            TaskStatus::Failed,
            // Already undone.
            TaskStatus::Reverted,
        ] {
            assert!(!cannot.can_revert(), "{cannot} should not offer an undo");
        }
    }

    #[test]
    fn budget_thresholds_fire_at_80_and_100_percent() {
        let at = |spent| Budget {
            cap_usd: Some(10.0),
            spent_usd: spent,
        };
        assert!(!at(7.9).is_warning());
        assert!(at(8.0).is_warning());
        assert!(!at(8.0).is_exhausted());
        assert!(at(10.0).is_exhausted());
    }

    #[test]
    fn an_uncapped_budget_never_stops_a_session() {
        let uncapped = Budget {
            cap_usd: None,
            spent_usd: 999.0,
        };
        assert_eq!(uncapped.pct(), None);
        assert!(!uncapped.is_warning());
        assert!(!uncapped.is_exhausted());
    }
}

#[cfg(test)]
mod wire_format_tests {
    use super::*;

    /// Every enum stored as text must serialise to the same string it is stored
    /// as, in every direction.
    ///
    /// This is not pedantry. `Agent::ClaudeCode` was `claude-code` in SQLite and
    /// `claude_code` over JSON, because `as_str` was explicit and serde was
    /// deriving `rename_all`. The API therefore could not accept the agent id
    /// its own `/v1/agents` endpoint advertised.
    macro_rules! assert_wire_agrees {
        ($name:ident) => {
            for variant in $name::ALL {
                let json = serde_json::to_string(variant).unwrap();
                let unquoted = json.trim_matches('"');
                assert_eq!(
                    unquoted,
                    variant.as_str(),
                    "{}::{:?} serialises as {:?} but is stored as {:?}",
                    stringify!($name),
                    variant,
                    unquoted,
                    variant.as_str(),
                );
                // And back, so a stored value parses through serde too.
                let round_tripped: $name = serde_json::from_str(&json).unwrap();
                assert_eq!(round_tripped, *variant);
                assert_eq!($name::from_str(variant.as_str()).unwrap(), *variant);
            }
        };
    }

    #[test]
    fn every_text_enum_has_one_wire_format() {
        assert_wire_agrees!(Agent);
        assert_wire_agrees!(SessionStatus);
        assert_wire_agrees!(PlanStepStatus);
        assert_wire_agrees!(Risk);
        assert_wire_agrees!(Decision);
        assert_wire_agrees!(DecidedVia);
        assert_wire_agrees!(Tier);
        assert_wire_agrees!(TaskType);
        assert_wire_agrees!(DeviceKind);
        assert_wire_agrees!(TaskStatus);
        assert_wire_agrees!(BatchStatus);
    }

    #[test]
    fn an_agent_id_from_the_api_parses_back() {
        // The exact failure this replaces: `/v1/agents` advertised `opencode`
        // and `POST /v1/sessions` answered "unknown variant `opencode`".
        for variant in Agent::ALL {
            let advertised = variant.as_str();
            let body = format!(r#"{{"agent":"{advertised}"}}"#);
            #[derive(serde::Deserialize)]
            struct Body {
                agent: Agent,
            }
            let parsed: Body = serde_json::from_str(&body).unwrap();
            assert_eq!(parsed.agent, *variant);
        }
    }
}

text_enum! {
    /// Where a queued batch item is in its life (C6).
    ///
    /// `Queued` → `Submitted` → one of the four settled states. Nothing goes
    /// backwards: a batch that expired is resubmitted as a *new* item, so the
    /// ledger never has two rows claiming the same work.
    BatchStatus {
        Queued => "queued",
        Submitted => "submitted",
        Succeeded => "succeeded",
        Errored => "errored",
        Expired => "expired",
        Canceled => "canceled",
    }
}

impl BatchStatus {
    /// True once the provider has said something final about this item.
    pub fn is_settled(self) -> bool {
        matches!(
            self,
            BatchStatus::Succeeded
                | BatchStatus::Errored
                | BatchStatus::Expired
                | BatchStatus::Canceled
        )
    }
}

text_enum! {
    /// Where a native agent task is in its life.
    ///
    /// `AwaitingReview` is the state a human acts on — the diff equivalent of
    /// [`SessionStatus::AwaitingApproval`]. Everything after it is terminal:
    /// a rejected task is never re-decided, it is re-run as a *new* task, so
    /// the audit trail keeps both the change set that was refused and the one
    /// that replaced it.
    TaskStatus {
        Running => "running",
        AwaitingReview => "awaiting_review",
        Applied => "applied",
        Rejected => "rejected",
        NoChanges => "no_changes",
        Failed => "failed",
        Reverted => "reverted",
    }
}

impl TaskStatus {
    /// True once the task will not change again on its own.
    pub fn is_settled(self) -> bool {
        !matches!(self, TaskStatus::Running | TaskStatus::AwaitingReview)
    }

    /// True when the change set is on disk and could be taken off again.
    ///
    /// Only `Applied`. A rejected task never landed, and a reverted one has
    /// already been undone — offering "undo" on either would be offering to do
    /// nothing, which reads as a bug the first time somebody presses it.
    pub fn can_revert(self) -> bool {
        matches!(self, TaskStatus::Applied)
    }
}

/// One run of the native agent: a prompt, and the change set it proposed.
///
/// The two JSON columns are opaque strings here, like `BatchItem::request_json`.
/// `forge-core` is the domain crate and deliberately does not depend on
/// `serde_json`; the shapes inside them belong to `forge-agent`, which is where
/// they are parsed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AgentTask {
    pub id: String,
    /// Spend is billed to a session like any other model call, so the ledger,
    /// the budget guard and the dashboard need no knowledge of tasks.
    pub session_id: String,
    pub repo_id: String,
    pub prompt: String,
    pub status: TaskStatus,
    /// The agent's closing message.
    pub summary: String,
    /// The serialised `ChangeSet` a reviewer is shown.
    pub diff_json: String,
    /// The serialised staging overlay `apply` writes from. Held separately from
    /// the diff so a phone can render a review card without being sent the full
    /// contents of every touched file.
    pub staged_json: String,
    pub files_changed: i64,
    pub lines_added: i64,
    pub lines_removed: i64,
    pub steps: i64,
    pub cost_usd: f64,
    pub error: Option<String>,
    /// Why a reviewer said no. Handed back to the agent verbatim on a retry.
    pub review_note: Option<String>,
    /// The frontier model's verdict on the diff (C10): `pass` | `concerns` |
    /// `fail`. `None` means **not judged**, which is a different thing from
    /// judged and found fine — a card must never render one as the other.
    pub verify_grade: Option<String>,
    pub verify_notes: Option<String>,
    /// Which model judged it. The router's configuration changes between tasks,
    /// and "Opus says concerns" is worth more than "Haiku says concerns".
    pub verify_model: Option<String>,
    pub decided_via: Option<DecidedVia>,
    pub created_at: i64,
    pub updated_at: i64,
    pub decided_at: Option<i64>,
}

impl AgentTask {
    pub fn is_pending_review(&self) -> bool {
        self.status == TaskStatus::AwaitingReview
    }

    /// `3 files, +42 −17`. The line a notification leads with.
    pub fn change_summary(&self) -> String {
        format!(
            "{} file{}, +{} −{}",
            self.files_changed,
            if self.files_changed == 1 { "" } else { "s" },
            self.lines_added,
            self.lines_removed
        )
    }
}

/// One deferred call, waiting for or returned from the Batch API.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BatchItem {
    pub id: String,
    pub session_id: String,
    /// What the provider echoes back on each result. The only thing tying an
    /// answer — and its cost — to the row that asked for it.
    pub custom_id: String,
    pub task_type: TaskType,
    pub model: String,
    /// The assembled Messages params, verbatim.
    pub request_json: String,
    pub batch_id: Option<String>,
    pub status: BatchStatus,
    pub response_text: Option<String>,
    pub error: Option<String>,
    pub queued_at: i64,
    pub submitted_at: Option<i64>,
    pub settled_at: Option<i64>,
}
