//! Per-session auto-approval: which approvals the runner may clear on a
//! person's behalf, and who may change that.
//!
//! The level is a delegation from a person to the policy engine for one
//! session. Two lines are fixed and have no setting:
//!
//! - A destructive command is never auto-approved. The classifier errs toward
//!   over-classifying, so this costs at most one extra tap.
//! - Only a person at a full screen (phone or web app) may change the level. A
//!   watch is barred for the same reason it cannot clear a destructive command,
//!   and a connector because a model widening its own permissions is exactly
//!   what supervision exists to prevent.
//!
//! This governs command approvals only. Applying a task's diff stays a human
//! review whatever the level is.

use farhelm_proto::types::{AutoApprove, DecidedVia, Risk};

/// Whether `level` clears an approval of `risk` without asking anyone.
pub fn auto_approves(level: AutoApprove, risk: Risk) -> bool {
    match risk {
        Risk::Destructive => false,
        Risk::Medium => level == AutoApprove::Medium,
        Risk::Low => matches!(level, AutoApprove::Low | AutoApprove::Medium),
    }
}

/// Whether a request arriving from `via` may change a session's level.
pub fn may_set_auto_approve(via: DecidedVia) -> bool {
    matches!(via, DecidedVia::Phone | DecidedVia::Web)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn destructive_is_never_auto_approved() {
        for level in [AutoApprove::Off, AutoApprove::Low, AutoApprove::Medium] {
            assert!(!auto_approves(level, Risk::Destructive), "{level:?}");
        }
    }

    #[test]
    fn each_level_clears_exactly_its_band() {
        assert!(!auto_approves(AutoApprove::Off, Risk::Low));
        assert!(!auto_approves(AutoApprove::Off, Risk::Medium));
        assert!(auto_approves(AutoApprove::Low, Risk::Low));
        assert!(!auto_approves(AutoApprove::Low, Risk::Medium));
        assert!(auto_approves(AutoApprove::Medium, Risk::Low));
        assert!(auto_approves(AutoApprove::Medium, Risk::Medium));
    }

    #[test]
    fn only_a_person_at_a_full_screen_changes_the_level() {
        assert!(may_set_auto_approve(DecidedVia::Phone));
        assert!(may_set_auto_approve(DecidedVia::Web));
        assert!(!may_set_auto_approve(DecidedVia::Watch));
        assert!(!may_set_auto_approve(DecidedVia::Connector));
        assert!(!may_set_auto_approve(DecidedVia::AutoPolicy));
    }
}
