//! Demo fixtures.
//!
//! Builds the fleet from the §4 wireframes so the UI can be developed against
//! realistic shapes before the tmux session manager (M1) exists. Costs are real
//! — they run through the actual price table and ledger, not hardcoded strings.

use forge_app::id::new_id;
use forge_app::ledger::{Call, Ledger};
use forge_app::store::prelude::*;
use forge_domain::plan;
use forge_proto::types::{
    Agent, Approval, Avoided, Machine, Plan, PlanStep, Repo, Risk, Session, SessionStatus,
    TaskType, Tier, Usage,
};
use forge_sqlite::SqliteStore;

pub struct SeedIds {
    /// The session the wireframes centre on: mid-plan, awaiting approval.
    pub active_session: String,
    pub pending_approval: String,
}

const PAYMENTS_PLAN: &str = "\
---
tier: large
---
# Fix webhook retry

- [x] Reproduce failing case
- [x] Add regression test
- [>] Patch retry backoff {tier=large}
- [ ] Update docs
- [ ] Add metrics for retry attempts
- [ ] Backfill failed webhooks
- [ ] Ship behind a flag
";

const PORTFOLIO_PLAN: &str = "\
# Refresh the case studies

- [x] Rewrite the intro
- [x] Swap in new screenshots
- [x] Fix the mobile layout
";

const MINUTE_MS: i64 = 60 * 1_000;
const HOUR_MS: i64 = 60 * MINUTE_MS;

fn store_plan(
    store: &SqliteStore,
    repo_id: &str,
    source: &str,
    created_at: i64,
) -> Result<String, Box<dyn std::error::Error>> {
    let parsed = plan::parse(source)?;
    let plan_id = new_id();
    store.upsert_plan(&Plan {
        id: plan_id.clone(),
        repo_id: repo_id.to_owned(),
        file_path: "PLAN.md".into(),
        content_hash: parsed.content_hash,
        created_at,
    })?;

    let steps: Vec<PlanStep> = parsed
        .steps
        .iter()
        .map(|parsed| PlanStep {
            id: new_id(),
            plan_id: plan_id.clone(),
            ordinal: parsed.ordinal,
            title: parsed.title.clone(),
            status: parsed.status,
            checkpoint_sha: None,
        })
        .collect();
    store.replace_plan_steps(&plan_id, &steps)?;
    Ok(plan_id)
}

/// Populate an empty database with the wireframe fleet.
pub fn seed(store: &SqliteStore, now: i64) -> Result<SeedIds, Box<dyn std::error::Error>> {
    let hetzner = new_id();
    let home = new_id();
    store.upsert_machine(&Machine {
        id: hetzner.clone(),
        name: "hetzner-1".into(),
        pubkey: "demo-hetzner".into(),
        last_seen_at: Some(now),
        created_at: now - 30 * 24 * HOUR_MS,
    })?;
    store.upsert_machine(&Machine {
        id: home.clone(),
        name: "home-server".into(),
        pubkey: "demo-home".into(),
        last_seen_at: Some(now - 5 * MINUTE_MS),
        created_at: now - 60 * 24 * HOUR_MS,
    })?;

    let payments = new_id();
    let portfolio = new_id();
    let experiments = new_id();
    store.upsert_repo(&Repo {
        id: payments.clone(),
        machine_id: hetzner.clone(),
        path: "/srv/payments-api".into(),
        name: "payments-api".into(),
        budget_usd: Some(10.00),
    })?;
    store.upsert_repo(&Repo {
        id: portfolio.clone(),
        machine_id: home,
        path: "/srv/portfolio-site".into(),
        name: "portfolio-site".into(),
        budget_usd: Some(5.00),
    })?;
    store.upsert_repo(&Repo {
        id: experiments.clone(),
        machine_id: hetzner,
        path: "/srv/ml-experiments".into(),
        name: "ml-experiments".into(),
        budget_usd: None,
    })?;

    let payments_plan = store_plan(store, &payments, PAYMENTS_PLAN, now - 3 * HOUR_MS)?;
    let portfolio_plan = store_plan(store, &portfolio, PORTFOLIO_PLAN, now - 2 * 24 * HOUR_MS)?;

    let active_session = new_id();
    store.upsert_session(&Session {
        id: active_session.clone(),
        repo_id: payments.clone(),
        agent: Agent::ClaudeCode,
        tmux_target: Some("forge:3.1".into()),
        status: SessionStatus::AwaitingApproval,
        plan_id: Some(payments_plan),
        budget_usd: Some(2.00),
        spent_usd: 0.0,
        started_at: now - 3 * HOUR_MS,
        ended_at: None,
        agent_session_id: None,
    })?;

    let done_session = new_id();
    store.upsert_session(&Session {
        id: done_session.clone(),
        repo_id: portfolio,
        agent: Agent::OpenCode,
        tmux_target: None,
        status: SessionStatus::Done,
        plan_id: Some(portfolio_plan),
        budget_usd: Some(1.00),
        spent_usd: 0.0,
        started_at: now - 2 * 24 * HOUR_MS,
        ended_at: Some(now - 47 * HOUR_MS),
        agent_session_id: None,
    })?;

    let dead_session = new_id();
    store.upsert_session(&Session {
        id: dead_session.clone(),
        repo_id: experiments,
        agent: Agent::ClaudeCode,
        tmux_target: Some("forge:1.0".into()),
        status: SessionStatus::Dead,
        plan_id: None,
        budget_usd: None,
        spent_usd: 0.0,
        started_at: now - 6 * HOUR_MS,
        ended_at: Some(now - 2 * HOUR_MS),
        agent_session_id: None,
    })?;

    let ledger = Ledger::new(store);

    // A day of work on the active session: cheap triage and file selection on
    // the small tier, edits on the large tier reading a warm cache, and a
    // handful of calls the pre-gate answered for free.
    for hour in (0..6).rev() {
        let at = now - hour * HOUR_MS;
        ledger.record_at(
            Call::new(
                &active_session,
                "claude-haiku-4-5",
                Tier::Small,
                TaskType::SelectFiles,
                Usage {
                    input_tokens: 4_100,
                    output_tokens: 220,
                    cache_write_tokens: 0,
                    cache_read_tokens: 0,
                },
            ),
            at,
        )?;
        ledger.record_at(
            Call::new(
                &active_session,
                "claude-haiku-4-5",
                Tier::Small,
                TaskType::Summarize,
                Usage {
                    input_tokens: 6_800,
                    output_tokens: 410,
                    cache_write_tokens: 0,
                    cache_read_tokens: 0,
                },
            ),
            at + 4 * MINUTE_MS,
        )?;
        ledger.record_at(
            Call::new(
                &active_session,
                "claude-opus-5",
                Tier::Large,
                TaskType::Edit,
                Usage {
                    input_tokens: 2_600,
                    output_tokens: 1_150,
                    cache_write_tokens: if hour == 5 { 26_000 } else { 0 },
                    cache_read_tokens: 128_000,
                },
            ),
            at + 11 * MINUTE_MS,
        )?;
        if hour % 2 == 0 {
            ledger.record_at(
                Call::avoided(
                    &active_session,
                    "claude-opus-5",
                    Tier::Large,
                    TaskType::HardDebug,
                    Avoided::PreGate,
                ),
                at + 18 * MINUTE_MS,
            )?;
        }
    }

    // The finished session: a plan that ran overnight on the batch queue.
    for hour in (0..3).rev() {
        ledger.record_at(
            Call::new(
                &done_session,
                "claude-sonnet-5",
                Tier::Batch,
                TaskType::Refactor,
                Usage {
                    input_tokens: 8_200,
                    output_tokens: 2_400,
                    cache_write_tokens: 0,
                    cache_read_tokens: 61_000,
                },
            ),
            now - (47 + hour) * HOUR_MS,
        )?;
    }

    let pending_approval = new_id();
    store.create_approval(&Approval {
        id: pending_approval.clone(),
        session_id: active_session.clone(),
        tool: "bash".into(),
        payload: "pytest tests/billing -x".into(),
        risk: Risk::Low,
        decision: None,
        decided_via: None,
        requested_at: now - 40 * 1_000,
        decided_at: None,
    })?;

    Ok(SeedIds {
        active_session,
        pending_approval,
    })
}

/// Canned terminal output for the active session, so the tail in Flow 3 has
/// something to render before the tmux bridge lands.
pub const DEMO_OUTPUT: &[&str] = &[
    "$ pytest tests/billing -x",
    "collected 34 items",
    "tests/billing/test_invoice.py ..........          [ 29%]",
    "tests/billing/test_retry.py ....F",
    "",
    "FAILED test_retry_after_500 - assert 3 == 5",
    "  retry_backoff() gave up after 3 attempts, expected 5",
    "",
    "2 passed, 1 failed in 4.21s",
    "",
    "Reading src/billing/retry.py …",
    "Patching exponential backoff ceiling",
];

#[cfg(test)]
mod tests {
    use super::*;
    use forge_domain::plan::PlanProgress;
    use forge_domain::{ApprovalRules as _, BudgetRules as _};

    const NOW_MS: i64 = 1_785_369_600_000;

    fn seeded() -> (SqliteStore, SeedIds) {
        let store = SqliteStore::open_in_memory().unwrap();
        let ids = seed(&store, NOW_MS).unwrap();
        (store, ids)
    }

    #[test]
    fn the_fleet_has_one_session_per_wireframe_row() {
        let (store, _) = seeded();
        let sessions = store.list_sessions().unwrap();
        assert_eq!(sessions.len(), 3);

        let statuses: Vec<_> = sessions.iter().map(|s| s.status).collect();
        assert!(statuses.contains(&SessionStatus::AwaitingApproval));
        assert!(statuses.contains(&SessionStatus::Done));
        assert!(statuses.contains(&SessionStatus::Dead));
    }

    #[test]
    fn the_active_session_sits_on_step_three_of_seven() {
        let (store, ids) = seeded();
        let session = store.get_session(&ids.active_session).unwrap().unwrap();
        let steps = store
            .list_plan_steps(session.plan_id.as_deref().unwrap())
            .unwrap();

        let progress = PlanProgress::of(&steps);
        assert_eq!(progress.total, 7);
        assert_eq!(progress.current_ordinal, Some(3));
        assert_eq!(
            progress.current_title.as_deref(),
            Some("Patch retry backoff")
        );
    }

    #[test]
    fn spend_lands_inside_the_session_cap() {
        let (store, ids) = seeded();
        let budget = store.session_budget(&ids.active_session).unwrap();
        assert!(budget.spent_usd > 0.0, "seed produced no spend");
        assert!(
            !budget.is_exhausted(),
            "seeded spend ${:.4} blew the cap",
            budget.spent_usd
        );
    }

    #[test]
    fn the_seeded_approval_is_pending_and_wrist_decidable() {
        let (store, ids) = seeded();
        let pending = store.list_pending_approvals().unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].id, ids.pending_approval);
        assert!(pending[0].allows_watch_decision());
    }

    #[test]
    fn seeding_is_idempotent_enough_to_re_run_on_a_fresh_database() {
        let (store, _) = seeded();
        let second = SqliteStore::open_in_memory().unwrap();
        seed(&second, NOW_MS).unwrap();
        assert_eq!(
            store.list_sessions().unwrap().len(),
            second.list_sessions().unwrap().len()
        );
    }
}
