//! The cost ledger — pipeline stage 8.
//!
//! Every model-bound call ends here: priced once, written once, and added to
//! the session's spend in the same transaction. The ledger exists before the
//! first model call so there is never a period where spend is untracked.

use std::collections::BTreeMap;
use std::fmt;

use crate::id::new_id;
use crate::price::{CacheTtl, QuoteContext, UnknownModel, quote};
use crate::store::{LedgerStore, StoreError, TimeRange};
use crate::time::now_ms;
use crate::types::{Avoided, TaskType, Tier, Usage, UsageEvent};

#[derive(Debug)]
pub enum LedgerError {
    Price(UnknownModel),
    Store(StoreError),
}

impl fmt::Display for LedgerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LedgerError::Price(err) => write!(f, "{err}"),
            LedgerError::Store(err) => write!(f, "{err}"),
        }
    }
}

impl std::error::Error for LedgerError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            LedgerError::Price(err) => Some(err),
            LedgerError::Store(err) => Some(err),
        }
    }
}

impl From<UnknownModel> for LedgerError {
    fn from(err: UnknownModel) -> Self {
        LedgerError::Price(err)
    }
}

impl From<StoreError> for LedgerError {
    fn from(err: StoreError) -> Self {
        LedgerError::Store(err)
    }
}

/// One completed (or deliberately skipped) model call, before pricing.
#[derive(Debug, Clone)]
pub struct Call<'a> {
    pub session_id: &'a str,
    pub model: &'a str,
    pub tier: Tier,
    pub task_type: TaskType,
    pub usage: Usage,
    /// `Some` when the pipeline returned without calling the model at all
    /// (stage 2 pre-gate, stage 3 response cache). Those rows cost $0 and are
    /// what "saved by pre-gate: 41 calls" counts.
    pub avoided: Option<Avoided>,
    pub cache_ttl: CacheTtl,
}

impl<'a> Call<'a> {
    /// A live interactive call with the default cache TTL.
    pub fn new(
        session_id: &'a str,
        model: &'a str,
        tier: Tier,
        task_type: TaskType,
        usage: Usage,
    ) -> Self {
        Self {
            session_id,
            model,
            tier,
            task_type,
            usage,
            avoided: None,
            cache_ttl: CacheTtl::FiveMinutes,
        }
    }

    /// A call the pipeline short-circuited. Costs nothing, still recorded.
    pub fn avoided(
        session_id: &'a str,
        model: &'a str,
        tier: Tier,
        task_type: TaskType,
        reason: Avoided,
    ) -> Self {
        Self {
            avoided: Some(reason),
            ..Self::new(session_id, model, tier, task_type, Usage::default())
        }
    }
}

pub struct Ledger<S> {
    store: S,
}

impl<S: LedgerStore> Ledger<S> {
    pub fn new(store: S) -> Self {
        Self { store }
    }

    pub fn store(&self) -> &S {
        &self.store
    }

    /// Price a call, append it, and move the session's spend.
    pub fn record(&self, call: Call<'_>) -> Result<UsageEvent, LedgerError> {
        self.record_at(call, now_ms())
    }

    /// [`Ledger::record`] with an explicit timestamp, so tests and replays are
    /// not at the mercy of the wall clock.
    pub fn record_at(&self, call: Call<'_>, at_ms: i64) -> Result<UsageEvent, LedgerError> {
        let ctx = QuoteContext {
            at_ms,
            cache_ttl: call.cache_ttl,
            batch: call.tier == Tier::Batch,
        };

        // An avoided call never reached the provider, so it bills nothing —
        // even if a caller hands us token counts by mistake.
        let (usage, cost_usd) = match call.avoided {
            Some(_) => (Usage::default(), 0.0),
            None => {
                let quote = quote(call.model, &call.usage, ctx)?;
                (call.usage, quote.total_usd())
            }
        };

        let event = UsageEvent {
            id: new_id(),
            session_id: call.session_id.to_owned(),
            model: call.model.to_owned(),
            tier: call.tier,
            task_type: call.task_type,
            usage,
            cost_usd,
            avoided: call.avoided,
            created_at: at_ms,
        };

        self.store.record_usage(&event)?;
        Ok(event)
    }

    /// Roll up a session's ledger for the dashboard (C9).
    pub fn summarize(&self, session_id: &str, range: TimeRange) -> Result<Summary, LedgerError> {
        let events = self.store.list_usage(session_id, range)?;
        Ok(Summary::from_events(&events))
    }
}

/// What the cost dashboard renders.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Summary {
    pub calls: usize,
    pub total_usd: f64,
    pub usage: Usage,
    /// Spend per tier, for the "tokens by tier" bar.
    pub usd_by_tier: BTreeMap<Tier, f64>,
    /// Calls the pipeline never made, by reason.
    pub avoided_calls: BTreeMap<Avoided, usize>,
}

impl Summary {
    pub fn from_events(events: &[UsageEvent]) -> Self {
        let mut summary = Summary::default();
        for event in events {
            summary.calls += 1;
            summary.total_usd += event.cost_usd;
            summary.usage.input_tokens = summary
                .usage
                .input_tokens
                .saturating_add(event.usage.input_tokens);
            summary.usage.output_tokens = summary
                .usage
                .output_tokens
                .saturating_add(event.usage.output_tokens);
            summary.usage.cache_write_tokens = summary
                .usage
                .cache_write_tokens
                .saturating_add(event.usage.cache_write_tokens);
            summary.usage.cache_read_tokens = summary
                .usage
                .cache_read_tokens
                .saturating_add(event.usage.cache_read_tokens);
            *summary.usd_by_tier.entry(event.tier).or_default() += event.cost_usd;
            if let Some(reason) = event.avoided {
                *summary.avoided_calls.entry(reason).or_default() += 1;
            }
        }
        summary
    }

    /// The Appendix A cache-read ratio target (≥ 70%).
    pub fn cache_read_ratio(&self) -> Option<f64> {
        self.usage.cache_read_ratio()
    }
}

impl fmt::Display for Summary {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f, "calls        {}", self.calls)?;
        writeln!(f, "spend        ${:.4}", self.total_usd)?;
        match self.cache_read_ratio() {
            Some(ratio) => writeln!(f, "cache hit    {:.0}%", ratio * 100.0)?,
            None => writeln!(f, "cache hit    n/a")?,
        }
        for (tier, usd) in &self.usd_by_tier {
            writeln!(f, "  {tier:<10} ${usd:.4}")?;
        }
        for (reason, count) in &self.avoided_calls {
            writeln!(f, "  avoided via {reason}: {count}")?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{FleetStore, SessionStore, SqliteStore};
    use crate::types::{Agent, Machine, Repo, Session, SessionStatus};

    const NOW_MS: i64 = 1_785_369_600_000;

    fn ledger() -> Ledger<SqliteStore> {
        let store = SqliteStore::open_in_memory().unwrap();
        store
            .upsert_machine(&Machine {
                id: "machine-1".into(),
                name: "hetzner-1".into(),
                pubkey: "pk".into(),
                last_seen_at: Some(NOW_MS),
                created_at: NOW_MS,
            })
            .unwrap();
        store
            .upsert_repo(&Repo {
                id: "repo-1".into(),
                machine_id: "machine-1".into(),
                path: "/srv/payments-api".into(),
                name: "payments-api".into(),
                budget_usd: Some(10.0),
            })
            .unwrap();
        store
            .upsert_session(&Session {
                id: "session-1".into(),
                repo_id: "repo-1".into(),
                agent: Agent::ClaudeCode,
                tmux_target: None,
                status: SessionStatus::Running,
                plan_id: None,
                budget_usd: Some(5.0),
                spent_usd: 0.0,
                started_at: NOW_MS,
                ended_at: None,
                agent_session_id: None,
            })
            .unwrap();
        Ledger::new(store)
    }

    fn edit_usage() -> Usage {
        Usage {
            input_tokens: 2_000,
            output_tokens: 500,
            cache_write_tokens: 0,
            cache_read_tokens: 40_000,
        }
    }

    #[test]
    fn a_recorded_call_produces_a_cost_number() {
        let ledger = ledger();
        let event = ledger
            .record_at(
                Call::new(
                    "session-1",
                    "claude-opus-5",
                    Tier::Large,
                    TaskType::Edit,
                    edit_usage(),
                ),
                NOW_MS,
            )
            .unwrap();

        // 2_000 input @ $5/MTok + 500 output @ $25/MTok + 40_000 cache reads @ $0.50/MTok
        let expected = 0.010 + 0.0125 + 0.020;
        assert!(
            (event.cost_usd - expected).abs() < 1e-9,
            "got {}",
            event.cost_usd
        );
        assert!(!event.id.is_empty());
    }

    #[test]
    fn an_avoided_call_costs_nothing_and_carries_no_tokens() {
        let ledger = ledger();
        let event = ledger
            .record_at(
                Call::avoided(
                    "session-1",
                    "claude-opus-5",
                    Tier::Large,
                    TaskType::Triage,
                    Avoided::PreGate,
                ),
                NOW_MS,
            )
            .unwrap();

        assert_eq!(event.cost_usd, 0.0);
        assert_eq!(event.usage, Usage::default());
        assert_eq!(
            ledger
                .store()
                .session_budget("session-1")
                .unwrap()
                .spent_usd,
            0.0
        );
    }

    #[test]
    fn token_counts_on_an_avoided_call_are_discarded_not_billed() {
        let ledger = ledger();
        let mut call = Call::new(
            "session-1",
            "claude-opus-5",
            Tier::Large,
            TaskType::Triage,
            edit_usage(),
        );
        call.avoided = Some(Avoided::ResponseCache);

        let event = ledger.record_at(call, NOW_MS).unwrap();
        assert_eq!(event.cost_usd, 0.0);
        assert_eq!(event.usage, Usage::default());
    }

    #[test]
    fn a_batch_tier_call_gets_the_batch_discount() {
        let ledger = ledger();
        let live = ledger
            .record_at(
                Call::new(
                    "session-1",
                    "claude-opus-5",
                    Tier::Large,
                    TaskType::Summarize,
                    edit_usage(),
                ),
                NOW_MS,
            )
            .unwrap();
        let batched = ledger
            .record_at(
                Call::new(
                    "session-1",
                    "claude-opus-5",
                    Tier::Batch,
                    TaskType::Summarize,
                    edit_usage(),
                ),
                NOW_MS,
            )
            .unwrap();

        assert!((batched.cost_usd - live.cost_usd / 2.0).abs() < 1e-12);
    }

    #[test]
    fn an_unpriced_model_is_rejected_before_anything_is_written() {
        let ledger = ledger();
        let err = ledger
            .record_at(
                Call::new(
                    "session-1",
                    "some-model-we-forgot",
                    Tier::Large,
                    TaskType::Edit,
                    edit_usage(),
                ),
                NOW_MS,
            )
            .unwrap_err();

        assert!(matches!(err, LedgerError::Price(_)));
        assert_eq!(
            ledger.summarize("session-1", TimeRange::ALL).unwrap().calls,
            0
        );
    }

    #[test]
    fn the_summary_splits_spend_by_tier_and_counts_avoided_calls() {
        let ledger = ledger();
        ledger
            .record_at(
                Call::new(
                    "session-1",
                    "claude-haiku-4-5",
                    Tier::Small,
                    TaskType::Triage,
                    edit_usage(),
                ),
                NOW_MS,
            )
            .unwrap();
        ledger
            .record_at(
                Call::new(
                    "session-1",
                    "claude-opus-5",
                    Tier::Large,
                    TaskType::Edit,
                    edit_usage(),
                ),
                NOW_MS,
            )
            .unwrap();
        ledger
            .record_at(
                Call::avoided(
                    "session-1",
                    "claude-opus-5",
                    Tier::Large,
                    TaskType::Edit,
                    Avoided::PreGate,
                ),
                NOW_MS,
            )
            .unwrap();

        let summary = ledger.summarize("session-1", TimeRange::ALL).unwrap();
        assert_eq!(summary.calls, 3);
        assert_eq!(summary.usd_by_tier.len(), 2);
        assert!(summary.usd_by_tier[&Tier::Small] < summary.usd_by_tier[&Tier::Large]);
        assert_eq!(summary.avoided_calls[&Avoided::PreGate], 1);
        // 80_000 cache reads against 4_000 fresh input tokens.
        assert!(summary.cache_read_ratio().unwrap() > 0.9);
    }

    #[test]
    fn summarized_spend_matches_the_session_budget() {
        let ledger = ledger();
        for _ in 0..5 {
            ledger
                .record_at(
                    Call::new(
                        "session-1",
                        "claude-opus-5",
                        Tier::Large,
                        TaskType::Edit,
                        edit_usage(),
                    ),
                    NOW_MS,
                )
                .unwrap();
        }

        let summary = ledger.summarize("session-1", TimeRange::ALL).unwrap();
        let budget = ledger.store().session_budget("session-1").unwrap();
        assert!((summary.total_usd - budget.spent_usd).abs() < 1e-9);
    }
}
