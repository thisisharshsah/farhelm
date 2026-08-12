//! When a budget is in trouble, and who may clear a destructive command.
//!
//! Two small rules that had been living on the wire types themselves. They look
//! like accessors and are not: both contain a decision that can change without
//! anything on the wire changing, which is exactly the kind of thing that
//! belongs behind an import a reader can see.

use forge_proto::types::{Approval, Budget, DecidedVia, Risk};
use forge_proto::views::BudgetView;

/// Fraction of a cap at which the wrist starts warning (C5).
///
/// Passing 80% is worth interrupting someone for; passing 50% is not, and a
/// warning that fires early is one people learn to dismiss.
pub const WARNING_AT: f64 = 0.8;

/// Fraction of a cap at which the gateway refuses to dispatch.
///
/// Stage 1's hard stop. Exactly 1.0, not slightly over: a session that has spent
/// its cap has spent its cap.
pub const EXHAUSTED_AT: f64 = 1.0;

/// The budget thresholds.
///
/// An extension trait rather than inherent methods, because [`Budget`] is a wire
/// type and belongs to `forge-proto`. The upside of being forced into this shape
/// is that `use forge_domain::BudgetRules` appears at the top of every file that
/// consults the policy, which is honest — these are not field reads.
pub trait BudgetRules {
    /// Fraction of the cap consumed. `None` when uncapped, so an unlimited
    /// session reads as "no answer" rather than as 0%.
    fn pct(&self) -> Option<f64>;

    /// Pipeline stage 1: hard stop.
    fn is_exhausted(&self) -> bool;

    /// Pipeline stage 1: wrist alert.
    fn is_warning(&self) -> bool;
}

impl BudgetRules for Budget {
    fn pct(&self) -> Option<f64> {
        match self.cap_usd {
            // A zero cap is treated as no cap rather than as instantly
            // exhausted: dividing by it yields infinity, and a session nobody
            // meant to cap would refuse its first call.
            Some(cap) if cap > 0.0 => Some(self.spent_usd / cap),
            _ => None,
        }
    }

    fn is_exhausted(&self) -> bool {
        self.pct().is_some_and(|pct| pct >= EXHAUSTED_AT)
    }

    fn is_warning(&self) -> bool {
        self.pct().is_some_and(|pct| pct >= WARNING_AT)
    }
}

/// The D3 rule: what a wrist is allowed to decide.
pub trait ApprovalRules {
    /// Destructive actions never get a one-tap wrist approval — the friction is
    /// the point.
    ///
    /// Enforced server-side on every transport, because a client that skipped it
    /// would otherwise be the whole defence.
    fn allows_watch_decision(&self) -> bool;

    /// Whether `via` may decide this approval at all.
    ///
    /// The watch rule generalised, because a second surface now has the same
    /// problem for a different reason. A watch is barred from destructive
    /// commands because a wrist tap is too easy; a **connector** is barred
    /// because the decider is a language model, and the entire premise of this
    /// system is that a human clears the dangerous ones. An agent that could
    /// approve its own `rm -rf` is an agent supervising itself.
    ///
    /// Enforced server-side on every transport, because a client that skipped
    /// it would otherwise be the whole defence.
    fn allows_decision_from(&self, via: DecidedVia) -> bool;
}

impl ApprovalRules for Approval {
    fn allows_watch_decision(&self) -> bool {
        self.risk != Risk::Destructive
    }

    fn allows_decision_from(&self, via: DecidedVia) -> bool {
        match via {
            // Both are "convenient enough to be dangerous", for different
            // reasons; both stop at the same line.
            DecidedVia::Watch | DecidedVia::Connector => self.risk != Risk::Destructive,
            // A person at a full screen, or the policy engine that was
            // configured by one.
            DecidedVia::Phone | DecidedVia::Web | DecidedVia::AutoPolicy => true,
        }
    }
}

/// Render a budget for a client.
///
/// A free function rather than `impl From<Budget> for BudgetView`, because both
/// types belong to `forge-proto` and the orphan rule puts that impl there — which
/// is where the thresholds used to leak back in. The mapping is the policy: it
/// turns two numbers into the one word every client switches on, and it happens
/// once, here, so that four implementations cannot disagree about where the
/// lines are.
pub fn budget_view(budget: Budget) -> BudgetView {
    BudgetView {
        cap_usd: budget.cap_usd,
        spent_usd: budget.spent_usd,
        pct: budget.pct(),
        state: if budget.is_exhausted() {
            "stop"
        } else if budget.is_warning() {
            "warn"
        } else {
            "ok"
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use forge_proto::types::{DecidedVia, Decision};

    fn capped(spent: f64) -> Budget {
        Budget {
            cap_usd: Some(10.0),
            spent_usd: spent,
        }
    }

    #[test]
    fn the_thresholds_fire_at_80_and_100_percent() {
        assert!(!capped(7.9).is_warning());
        assert!(capped(8.0).is_warning(), "80% exactly is already a warning");
        assert!(!capped(8.0).is_exhausted());
        assert!(capped(10.0).is_exhausted(), "100% exactly is a hard stop");
        assert!(capped(11.0).is_exhausted());
    }

    #[test]
    fn an_exhausted_budget_is_also_a_warning() {
        // The wrist alert must not stop firing because the session went past the
        // cap; "you are over" is the more urgent version of "you are close".
        assert!(capped(10.0).is_warning());
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

    #[test]
    fn a_zero_cap_is_no_cap_rather_than_instant_exhaustion() {
        // Dividing by it would be infinity, and a session nobody meant to cap
        // would refuse its very first call.
        let zero = Budget {
            cap_usd: Some(0.0),
            spent_usd: 0.0,
        };
        assert_eq!(zero.pct(), None);
        assert!(!zero.is_exhausted());
    }

    fn approval(risk: Risk) -> Approval {
        Approval {
            id: "a1".into(),
            session_id: "s1".into(),
            tool: "bash".into(),
            payload: "rm -rf /".into(),
            risk,
            decision: None,
            decided_via: None,
            requested_at: 0,
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
    fn the_rule_is_about_risk_not_about_whether_it_was_decided() {
        let mut decided = approval(Risk::Destructive);
        decided.decision = Some(Decision::Approved);
        decided.decided_via = Some(DecidedVia::Phone);
        assert!(!decided.allows_watch_decision());
    }

    #[test]
    fn the_view_carries_the_word_clients_switch_on() {
        assert_eq!(budget_view(capped(0.0)).state, "ok");
        assert_eq!(budget_view(capped(8.0)).state, "warn");
        assert_eq!(budget_view(capped(10.0)).state, "stop");
        assert_eq!(
            budget_view(Budget {
                cap_usd: None,
                spent_usd: 999.0,
            })
            .state,
            "ok",
            "an uncapped session is never shown as stopped"
        );
    }
}

#[cfg(test)]
mod surface_tests {
    use super::*;
    use forge_proto::types::Risk;

    fn approval(risk: Risk) -> Approval {
        Approval {
            id: "a1".into(),
            session_id: "s1".into(),
            tool: "Bash".into(),
            payload: "rm -rf build".into(),
            risk,
            decision: None,
            decided_via: None,
            requested_at: 0,
            decided_at: None,
        }
    }

    #[test]
    fn a_connector_may_clear_an_ordinary_command() {
        // Read-and-approve is most of what a connector is for; barring it
        // entirely would make the connector useless rather than safe.
        assert!(approval(Risk::Low).allows_decision_from(DecidedVia::Connector));
        assert!(approval(Risk::Medium).allows_decision_from(DecidedVia::Connector));
    }

    #[test]
    fn a_connector_may_never_clear_a_destructive_one() {
        // The premise of the whole system: a human clears the dangerous ones.
        // An agent that could approve its own `rm -rf` supervises itself.
        assert!(!approval(Risk::Destructive).allows_decision_from(DecidedVia::Connector));
    }

    #[test]
    fn a_watch_still_stops_at_the_same_line() {
        assert!(approval(Risk::Low).allows_decision_from(DecidedVia::Watch));
        assert!(!approval(Risk::Destructive).allows_decision_from(DecidedVia::Watch));
        // The older, narrower rule agrees with the general one.
        assert_eq!(
            approval(Risk::Destructive).allows_watch_decision(),
            approval(Risk::Destructive).allows_decision_from(DecidedVia::Watch)
        );
    }

    #[test]
    fn a_person_at_a_full_screen_may_clear_anything() {
        for via in [DecidedVia::Phone, DecidedVia::Web] {
            assert!(
                approval(Risk::Destructive).allows_decision_from(via),
                "{via}"
            );
        }
    }
}
