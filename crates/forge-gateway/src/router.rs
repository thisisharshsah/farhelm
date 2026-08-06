//! Pipeline stage 4 — routing.
//!
//! A static table, deliberately. An ML router would need training data the
//! project does not have yet, and the failure mode of a wrong route (a frontier
//! model does triage) is expensive but invisible. A table is auditable: you can
//! read what will happen before you pay for it.

use forge_core::types::{TaskType, Tier};
use serde::{Deserialize, Serialize};

/// Which concrete model backs each tier. Any of these may be a self-hosted
/// endpoint — the price table treats a `local/` id as free (§7's "my own
/// model" small tier).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Models {
    /// Triage, selection, summarising.
    pub small: String,
    /// Edits and refactors.
    pub large: String,
    /// Planning and hard debugging — the calls worth the top rate.
    pub frontier: String,
}

impl Default for Models {
    fn default() -> Self {
        Self {
            small: "claude-haiku-4-5".into(),
            large: "claude-sonnet-5".into(),
            frontier: "claude-opus-5".into(),
        }
    }
}

/// Which slot a task lands in before any override.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Slot {
    Small,
    Large,
    Frontier,
}

impl Slot {
    /// The ledger dimension. `Frontier` and `Large` both bill as the large
    /// tier — the distinction is which model ran, which the ledger records
    /// separately.
    pub const fn tier(self) -> Tier {
        match self {
            Slot::Small => Tier::Small,
            Slot::Large | Slot::Frontier => Tier::Large,
        }
    }
}

/// The table. Read it top to bottom: everything cheap is cheap by default, and
/// only edits and reasoning reach for a big model.
pub const fn slot_for(task: TaskType) -> Slot {
    match task {
        TaskType::Triage
        | TaskType::SelectFiles
        | TaskType::Summarize
        | TaskType::CommitMsg
        | TaskType::Title => Slot::Small,
        TaskType::Edit | TaskType::Refactor => Slot::Large,
        TaskType::Plan | TaskType::HardDebug => Slot::Frontier,
    }
}

/// The routing decision for one call.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Route {
    pub tier: Tier,
    pub slot: Slot,
    pub model: String,
    /// True when a `PLAN.md` tier pin overrode the table.
    pub pinned: bool,
}

/// Route a task, honouring a per-step `{tier=…}` pin from the plan file and the
/// deferrable flag that sends work to the batch queue.
pub fn route(task: TaskType, pin: Option<Tier>, deferrable: bool, models: &Models) -> Route {
    let slot = match pin {
        // A pin names a *tier*, not a model, so a pinned large step still gets
        // the ordinary large model rather than the frontier one. Pinning up to
        // the frontier model is deliberately not expressible from a plan file:
        // it is the one choice worth making in the router config.
        Some(Tier::Small) => Slot::Small,
        Some(Tier::Large) => Slot::Large,
        // `batch` is a dispatch mode, not a capability tier. Pinning it picks
        // the task's natural slot and defers the call.
        Some(Tier::Batch) | None => slot_for(task),
    };

    let model = match slot {
        Slot::Small => &models.small,
        Slot::Large => &models.large,
        Slot::Frontier => &models.frontier,
    };

    // Batch is what the ledger records, because that is what changes the price.
    let tier = if deferrable || pin == Some(Tier::Batch) {
        Tier::Batch
    } else {
        slot.tier()
    };

    Route {
        tier,
        slot,
        model: model.clone(),
        pinned: pin.is_some(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn models() -> Models {
        Models::default()
    }

    #[test]
    fn cheap_work_never_reaches_a_big_model_by_default() {
        for task in [
            TaskType::Triage,
            TaskType::SelectFiles,
            TaskType::Summarize,
            TaskType::CommitMsg,
            TaskType::Title,
        ] {
            let route = route(task, None, false, &models());
            assert_eq!(route.tier, Tier::Small, "{task} should route small");
            assert_eq!(route.model, "claude-haiku-4-5");
        }
    }

    #[test]
    fn edits_get_the_large_model_and_reasoning_gets_the_frontier_one() {
        assert_eq!(
            route(TaskType::Edit, None, false, &models()).model,
            "claude-sonnet-5"
        );
        assert_eq!(
            route(TaskType::Plan, None, false, &models()).model,
            "claude-opus-5"
        );
        assert_eq!(
            route(TaskType::HardDebug, None, false, &models()).model,
            "claude-opus-5"
        );
        // Both still bill as the large tier.
        assert_eq!(
            route(TaskType::Plan, None, false, &models()).tier,
            Tier::Large
        );
    }

    #[test]
    fn a_plan_pin_can_send_an_edit_down_to_the_small_model() {
        let route = route(TaskType::Edit, Some(Tier::Small), false, &models());
        assert_eq!(route.model, "claude-haiku-4-5");
        assert_eq!(route.tier, Tier::Small);
        assert!(route.pinned);
    }

    #[test]
    fn a_plan_pin_cannot_reach_the_frontier_model() {
        // Pinning `large` on a triage task gets the large model, not the
        // frontier one — the expensive slot stays a config decision.
        let route = route(TaskType::Triage, Some(Tier::Large), false, &models());
        assert_eq!(route.model, "claude-sonnet-5");
    }

    #[test]
    fn deferrable_work_bills_as_batch_without_changing_the_model() {
        let live = route(TaskType::Summarize, None, false, &models());
        let deferred = route(TaskType::Summarize, None, true, &models());
        assert_eq!(live.model, deferred.model);
        assert_eq!(deferred.tier, Tier::Batch);
    }

    #[test]
    fn pinning_batch_keeps_the_tasks_natural_model() {
        let route = route(TaskType::Plan, Some(Tier::Batch), false, &models());
        assert_eq!(route.model, "claude-opus-5");
        assert_eq!(route.tier, Tier::Batch);
    }

    #[test]
    fn a_self_hosted_small_tier_is_just_a_model_id() {
        let models = Models {
            small: "local/qwen3-coder".into(),
            ..Models::default()
        };
        assert_eq!(
            route(TaskType::Triage, None, false, &models).model,
            "local/qwen3-coder"
        );
    }
}
