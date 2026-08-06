//! The request pipeline — every model-bound call passes through here.
//!
//! §6's stages, in the order they are actually computable:
//!
//! ```text
//! 1 budget    → hard stop at the cap, warn at 80%
//! 2 pre-gate  → fmt/lint/typecheck/tests; all green on a verify task → $0
//! 4 router    → task type (and any PLAN.md pin) picks the tier and model
//! 5 context   → retrieval, not file dumps
//! 6 assembler → cache-shaped prompt, breakpoints at stable/volatile borders
//! 3 cache     → exact-prompt hit → $0
//! 7 dispatch  → live call (batch queue is C6, not built)
//! 8 ledger    → priced once, written once, budget moved in the same transaction
//! ```
//!
//! Stage 3 runs after 4–6 rather than before, because an exact-prompt cache key
//! cannot exist until the prompt does — the key has to include the routed model
//! and the retrieved context, or it would collide across genuinely different
//! calls. The property that matters is preserved: the zero-cost exits (2 and 3)
//! both still happen before any spend.

use std::path::PathBuf;
use std::time::Duration;

use forge_core::id::new_id;
use forge_core::ledger::{Call, Ledger, LedgerError};
use forge_core::price::{UnknownModel, price_of};
use forge_core::store::{Store, StoreError};
use forge_core::time::now_ms;
use forge_core::types::{Avoided, BatchItem, BatchStatus, Budget, TaskType, Tier, Usage};
use forge_domain::BudgetRules as _;

use crate::cache;
use crate::compaction;
use crate::context::{ContextBudget, RepoContext, build as build_context};
use crate::dispatch::{
    DEFAULT_MAX_TOKENS, DispatchError, Effort, ModelClient, ModelRequest, Refusal, ToolCall,
    messages_params,
};
use crate::pregate::{self, PreGateReport};
use crate::prompt::{BreakpointNote, StableContext, Turn, assemble};
use crate::router::{Models, Route, Slot, route};

#[derive(Debug, Clone)]
pub struct GatewayConfig {
    pub models: Models,
    pub context: ContextBudget,
    pub max_tokens: u32,
    pub pregate_timeout: Duration,
    pub cache_ttl_ms: i64,
    /// The Batch API queue (C6). Until it exists, a deferrable call is dispatched
    /// live and billed at live rates — the ledger never claims a discount that
    /// was not applied.
    pub batch_enabled: bool,
    /// When and how much conversation history to compact (C7). `None` never
    /// compacts, which is the right setting for short-lived sessions.
    pub compaction: Option<crate::compaction::CompactionPolicy>,
}

impl Default for GatewayConfig {
    fn default() -> Self {
        Self {
            models: Models::default(),
            context: ContextBudget::default(),
            max_tokens: DEFAULT_MAX_TOKENS,
            pregate_timeout: pregate::DEFAULT_TIMEOUT,
            cache_ttl_ms: cache::DEFAULT_TTL_MS,
            batch_enabled: false,
            compaction: Some(crate::compaction::CompactionPolicy::default()),
        }
    }
}

#[derive(Debug, Clone)]
pub struct CompleteRequest {
    pub session_id: String,
    pub task_type: TaskType,
    /// A `{tier=…}` pin from the plan step this call belongs to.
    pub tier_pin: Option<Tier>,
    /// What changes this turn. Becomes the dynamic tail, after the pre-gate
    /// digest is prepended.
    pub instruction: String,
    /// The stable half of the prompt. `repo_map` is overwritten by stage 5 when
    /// a repo path is supplied.
    pub stable: StableContext,
    /// Enables the pre-gate and retrieval. Without it both stages are skipped.
    pub repo_path: Option<PathBuf>,
    /// True when the whole point of the call is "is this correct?" — a green
    /// pre-gate answers that for free.
    pub verify_only: bool,
    /// Caller is willing to wait for the nightly batch flush.
    pub deferrable: bool,
}

impl CompleteRequest {
    pub fn new(
        session_id: impl Into<String>,
        task_type: TaskType,
        instruction: impl Into<String>,
    ) -> Self {
        Self {
            session_id: session_id.into(),
            task_type,
            tier_pin: None,
            instruction: instruction.into(),
            stable: StableContext::default(),
            repo_path: None,
            verify_only: false,
            deferrable: false,
        }
    }
}

/// How the call was ultimately served.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Served {
    /// The provider answered.
    Live,
    /// Stage 2: the deterministic checks were all green.
    PreGate,
    /// Stage 3: an identical prompt had been answered before.
    ResponseCache,
    /// Stage 7a: queued for the Batch API instead of dispatched (C6).
    ///
    /// There is no text yet. `batch_item_id` on the response is how the caller
    /// collects it later — usually hours later.
    Queued,
}

/// What each stage did, for the dashboard and for explaining a surprising bill.
#[derive(Debug, Clone, serde::Serialize)]
pub struct StageTrace {
    pub budget: Budget,
    pub budget_warning: bool,
    pub pregate: Option<PreGateReport>,
    pub route: Route,
    pub context: RepoContext,
    pub breakpoints: usize,
    pub breakpoint_notes: Vec<BreakpointNote>,
    pub cache_key: Option<String>,
    pub served: Served,
    /// Set when `deferrable` was requested but batching is switched off, so the
    /// call was dispatched live and billed at live rates. The trace must never
    /// claim a discount the bill did not get.
    pub batch_downgraded: bool,
}

#[derive(Debug, Clone)]
pub struct CompleteResponse {
    pub text: String,
    /// The model that produced the answer — may differ from the routed one when
    /// a server-side fallback served the turn.
    pub model: String,
    pub tier: Tier,
    pub usage: Usage,
    pub cost_usd: f64,
    pub avoided: Option<Avoided>,
    pub refusal: Option<Refusal>,
    /// Tools the model wants run before it will continue. Empty on every
    /// zero-cost exit, because none of them can produce one.
    pub tool_calls: Vec<ToolCall>,
    /// Set when the call was queued rather than answered (C6). `text` is empty;
    /// this is what to ask for later.
    pub batch_item_id: Option<String>,
    /// Set when history was compacted (C7): **use this from now on**.
    ///
    /// The gateway holds no session state, so the caller owns the history. Not
    /// storing this means re-summarising the same turns every turn — paying for
    /// the summary repeatedly *and* throwing away the prompt cache each time,
    /// which is worse than never compacting at all.
    pub compacted_history: Option<Vec<Turn>>,
    pub trace: StageTrace,
}

impl CompleteResponse {
    /// True when the provider was actually called — the two zero-cost exits
    /// both report false.
    pub fn served_live(&self) -> bool {
        self.trace.served == Served::Live
    }
}

#[derive(Debug)]
pub enum GatewayError {
    /// Stage 1 hard stop. Carries which budget tripped so the caller can say so.
    BudgetExhausted {
        scope: &'static str,
        budget: Budget,
    },
    Store(StoreError),
    Ledger(LedgerError),
    Dispatch(DispatchError),
    Price(UnknownModel),
}

impl std::fmt::Display for GatewayError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GatewayError::BudgetExhausted { scope, budget } => write!(
                f,
                "{scope} budget exhausted: ${:.4} of ${:.2}",
                budget.spent_usd,
                budget.cap_usd.unwrap_or(0.0)
            ),
            GatewayError::Store(err) => write!(f, "{err}"),
            GatewayError::Ledger(err) => write!(f, "{err}"),
            GatewayError::Dispatch(err) => write!(f, "{err}"),
            GatewayError::Price(err) => write!(f, "{err}"),
        }
    }
}

impl std::error::Error for GatewayError {}

impl From<StoreError> for GatewayError {
    fn from(err: StoreError) -> Self {
        GatewayError::Store(err)
    }
}

impl From<LedgerError> for GatewayError {
    fn from(err: LedgerError) -> Self {
        GatewayError::Ledger(err)
    }
}

impl From<DispatchError> for GatewayError {
    fn from(err: DispatchError) -> Self {
        GatewayError::Dispatch(err)
    }
}

/// Effort by slot. The cheap tier does not need to think hard about triage, and
/// the frontier tier is only worth its rate at the depth it was chosen for.
const fn effort_for(slot: Slot) -> Effort {
    match slot {
        Slot::Small => Effort::Low,
        Slot::Large => Effort::High,
        // xhigh is the recommended setting for coding and agentic work.
        Slot::Frontier => Effort::XHigh,
    }
}

pub struct Gateway<S, C> {
    store: S,
    client: C,
    config: GatewayConfig,
}

impl<S: Store, C: ModelClient> Gateway<S, C> {
    pub fn new(store: S, client: C, config: GatewayConfig) -> Self {
        Self {
            store,
            client,
            config,
        }
    }

    pub fn config(&self) -> &GatewayConfig {
        &self.config
    }

    /// Summarise the turns a compaction plan wants to drop (C7).
    ///
    /// Always on the small tier, never on the routed model. Condensing a
    /// transcript is the cheapest kind of work there is, and paying frontier
    /// rates for it would undo the saving it exists to produce.
    ///
    /// Returns the summary and what it cost. Billed through the ledger like any
    /// other call — it is one — so a session's spend reflects it.
    async fn summarise(
        &self,
        session_id: &str,
        plan: &compaction::CompactionPlan,
        at_ms: i64,
    ) -> Result<(String, f64), GatewayError> {
        let model = self.config.models.small.clone();
        let price = price_of(&model).map_err(GatewayError::Price)?;

        // A bare prompt, deliberately: no repo map, no tools, no history. The
        // transcript is the entire input, and adding anything else would both
        // cost more and give the summariser something else to talk about.
        let stable = StableContext {
            system: "You compact coding-session transcripts.".into(),
            ..StableContext::default()
        };
        let assembled = assemble(
            &stable,
            &compaction::summarise_instruction(&plan.transcript()),
            &price,
        );

        let response = self
            .client
            .complete(ModelRequest {
                model: model.clone(),
                max_tokens: self.config.max_tokens,
                // Low effort: this is condensation, not reasoning.
                effort: Some(Effort::Low),
                plan: assembled,
            })
            .await?;

        let event = Ledger::new(&self.store).record_at(
            Call::new(
                session_id,
                &response.model,
                Tier::Small,
                TaskType::Summarize,
                response.usage,
            ),
            at_ms,
        )?;

        Ok((response.text, event.cost_usd))
    }

    pub async fn complete(
        &self,
        request: CompleteRequest,
    ) -> Result<CompleteResponse, GatewayError> {
        let at_ms = now_ms();

        // ---- stage 1: budget ------------------------------------------------
        let session_budget = self.store.session_budget(&request.session_id)?;
        if session_budget.is_exhausted() {
            return Err(GatewayError::BudgetExhausted {
                scope: "session",
                budget: session_budget,
            });
        }

        // The repo cap is the outer ring: a single session can be well inside
        // its own cap while the repo as a whole is not.
        if let Some(session) = self.store.get_session(&request.session_id)? {
            let repo_budget = self.store.repo_budget(&session.repo_id)?;
            if repo_budget.is_exhausted() {
                return Err(GatewayError::BudgetExhausted {
                    scope: "repo",
                    budget: repo_budget,
                });
            }
        }

        // ---- stage 2: deterministic pre-gate --------------------------------
        let pregate = match &request.repo_path {
            Some(repo) => Some(pregate::run_detected(repo, self.config.pregate_timeout).await),
            None => None,
        };

        if let Some(report) = &pregate
            && report.all_green()
            && request.verify_only
        {
            // The compiler already answered. Record the call that did not happen
            // so "saved by pre-gate" is a measured number, not a claim.
            let event = Ledger::new(&self.store).record_at(
                Call::avoided(
                    &request.session_id,
                    &self.config.models.small,
                    Tier::Small,
                    request.task_type,
                    Avoided::PreGate,
                ),
                at_ms,
            )?;

            return Ok(CompleteResponse {
                text: "All deterministic checks passed.".into(),
                model: event.model,
                tier: event.tier,
                usage: Usage::default(),
                cost_usd: 0.0,
                avoided: Some(Avoided::PreGate),
                refusal: None,
                tool_calls: Vec::new(),
                batch_item_id: None,
                compacted_history: None,
                trace: StageTrace {
                    budget: session_budget,
                    budget_warning: session_budget.is_warning(),
                    pregate,
                    route: route(
                        request.task_type,
                        request.tier_pin,
                        false,
                        &self.config.models,
                    ),
                    context: RepoContext::default(),
                    breakpoints: 0,
                    breakpoint_notes: Vec::new(),
                    cache_key: None,
                    served: Served::PreGate,
                    batch_downgraded: false,
                },
            });
        }

        // ---- stage 4: routing -----------------------------------------------
        let batch_downgraded = request.deferrable && !self.config.batch_enabled;
        let deferrable = request.deferrable && self.config.batch_enabled;
        let route = route(
            request.task_type,
            request.tier_pin,
            deferrable,
            &self.config.models,
        );
        let price = price_of(&route.model).map_err(GatewayError::Price)?;

        // ---- stage 5: retrieval ---------------------------------------------
        let context = match &request.repo_path {
            Some(repo) => build_context(repo, &request.instruction, &self.config.context),
            None => RepoContext::default(),
        };

        // ---- stage 5a: history compaction (C7) ------------------------------
        //
        // Before assembly, because a compacted history is what gets assembled.
        // The summary call is billed like any other — it is a real call — and
        // the caller is handed the new history to store, because re-summarising
        // the same turns every turn would cost more than never compacting.
        let mut stable = request.stable.clone();
        let mut compacted: Option<Vec<Turn>> = None;
        let mut compaction_cost = 0.0;

        if let Some(policy) = self.config.compaction
            && let Some(plan) = compaction::plan(&stable.history, &policy)
        {
            match self.summarise(&request.session_id, &plan, at_ms).await {
                Ok((summary, cost)) => {
                    let history = compaction::apply(&summary, plan);
                    stable.history = history.clone();
                    compacted = Some(history);
                    compaction_cost = cost;
                }
                // A failed summary is not a failed call. Carrying the full
                // history costs more than it should; refusing to answer costs
                // the user their turn.
                Err(err) => eprintln!("compaction: {err}; continuing uncompacted"),
            }
        }

        // ---- stage 6: cache-shaped assembly --------------------------------
        if !context.is_empty() {
            stable.repo_map = context.render();
        }

        // Only pre-gate *failures* enter the prompt, and they go in the dynamic
        // tail — never ahead of a breakpoint.
        let dynamic = match pregate.as_ref().and_then(PreGateReport::digest) {
            Some(digest) => format!("{digest}\n\n{}", request.instruction),
            None => request.instruction.clone(),
        };

        let plan = assemble(&stable, &dynamic, &price);

        // ---- stage 3: exact response cache ---------------------------------
        let cache_key =
            cache::is_cacheable(request.task_type).then(|| cache::key(&route.model, &plan));

        if let Some(key) = &cache_key
            && let Some(hit) = self.store.cache_get(key, at_ms)?
        {
            let event = Ledger::new(&self.store).record_at(
                Call::avoided(
                    &request.session_id,
                    &route.model,
                    route.tier,
                    request.task_type,
                    Avoided::ResponseCache,
                ),
                at_ms,
            )?;

            return Ok(CompleteResponse {
                text: hit,
                model: event.model,
                tier: event.tier,
                usage: Usage::default(),
                cost_usd: 0.0,
                avoided: Some(Avoided::ResponseCache),
                refusal: None,
                tool_calls: Vec::new(),
                batch_item_id: None,
                compacted_history: None,
                trace: StageTrace {
                    budget: session_budget,
                    budget_warning: session_budget.is_warning(),
                    pregate,
                    route,
                    context,
                    breakpoints: plan.breakpoints(),
                    breakpoint_notes: plan.notes.clone(),
                    cache_key: cache_key.clone(),
                    served: Served::ResponseCache,
                    batch_downgraded,
                },
            });
        }

        // ---- stage 7a: queue, if this can wait ------------------------------
        //
        // Before dispatch, because the whole point is not to dispatch. The
        // prompt is assembled and priced exactly as a live call would be, then
        // stored verbatim: a flush hours from now sends what was decided on,
        // not whatever the repo looks like by then.
        if deferrable {
            let breakpoints = plan.breakpoints();
            let breakpoint_notes = plan.notes.clone();
            let item_id = new_id();

            let item = BatchItem {
                id: item_id.clone(),
                session_id: request.session_id.clone(),
                // Prefixed so a result belonging to another tool sharing this
                // API key is recognisably not ours.
                custom_id: format!("forge-{item_id}"),
                task_type: request.task_type,
                model: route.model.clone(),
                // Exactly what a live dispatch would have sent — same function,
                // so the batched call cannot be assembled differently from the
                // live one it replaces. No `fallbacks`: a refused batch item is
                // resubmittable, and that path is unverified against the real
                // endpoint.
                request_json: messages_params(&ModelRequest {
                    model: route.model.clone(),
                    max_tokens: self.config.max_tokens,
                    effort: Some(effort_for(route.slot)),
                    plan: plan.clone(),
                })
                .to_string(),
                batch_id: None,
                status: BatchStatus::Queued,
                response_text: None,
                error: None,
                queued_at: at_ms,
                submitted_at: None,
                settled_at: None,
            };
            self.store.enqueue_batch_item(&item)?;

            return Ok(CompleteResponse {
                // No text, and no pretending otherwise. The caller asked for
                // this by setting `deferrable`.
                text: String::new(),
                model: route.model.clone(),
                tier: Tier::Batch,
                usage: Usage::default(),
                // Nothing is billed until the batch settles and the real token
                // counts come back — at half rates.
                cost_usd: 0.0,
                avoided: None,
                refusal: None,
                tool_calls: Vec::new(),
                batch_item_id: Some(item_id),
                compacted_history: compacted.clone(),
                trace: StageTrace {
                    budget: session_budget,
                    budget_warning: session_budget.is_warning(),
                    pregate,
                    route,
                    context,
                    breakpoints,
                    breakpoint_notes,
                    cache_key,
                    served: Served::Queued,
                    batch_downgraded: false,
                },
            });
        }

        // ---- stage 7: dispatch ----------------------------------------------
        let breakpoints = plan.breakpoints();
        let breakpoint_notes = plan.notes.clone();

        let response = self
            .client
            .complete(ModelRequest {
                model: route.model.clone(),
                max_tokens: self.config.max_tokens,
                effort: Some(effort_for(route.slot)),
                plan,
            })
            .await?;

        // ---- stage 8: ledger ------------------------------------------------
        // Priced against the model that *ran*, not the one requested: a
        // server-side fallback bills at its own rates, and pretending otherwise
        // would put a wrong number in an append-only table.
        let event = Ledger::new(&self.store).record_at(
            Call::new(
                &request.session_id,
                &response.model,
                route.tier,
                request.task_type,
                response.usage,
            ),
            at_ms,
        )?;

        // A refused turn is never cached — the next attempt should get a real
        // answer rather than a replayed decline.
        //
        // Nor is a turn that asked for tools. The cache stores text, so a hit
        // would hand the caller an answer with the model's tool calls silently
        // dropped, and an agent loop reading that would conclude the turn was
        // over. Guarding the *write* rather than the read is what makes every
        // hit safe by construction: nothing tool-shaped is ever in there.
        if let Some(key) = &cache_key
            && response.refusal.is_none()
            && response.tool_calls.is_empty()
            && !response.text.is_empty()
        {
            self.store
                .cache_put(key, &response.text, at_ms, self.config.cache_ttl_ms)?;
        }

        Ok(CompleteResponse {
            text: response.text,
            model: response.model,
            tier: event.tier,
            usage: response.usage,
            // Includes the summary call when one was made. A turn that
            // compacted really did cost that much; reporting only the answer
            // would make compaction look free.
            cost_usd: event.cost_usd + compaction_cost,
            avoided: None,
            refusal: response.refusal,
            tool_calls: response.tool_calls,
            batch_item_id: None,
            compacted_history: compacted,
            trace: StageTrace {
                budget: self.store.session_budget(&request.session_id)?,
                budget_warning: session_budget.is_warning(),
                pregate,
                route,
                context,
                breakpoints,
                breakpoint_notes,
                cache_key,
                served: Served::Live,
                batch_downgraded,
            },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dispatch::StubClient;
    use crate::prompt::Turn;
    use forge_core::store::{SqliteStore, TimeRange};
    use forge_core::types::{Agent, Machine, Repo, Session, SessionStatus};

    const NOW: i64 = 1_785_369_600_000;

    pub(super) fn store_with(session_cap: Option<f64>, repo_cap: Option<f64>) -> SqliteStore {
        let store = SqliteStore::open_in_memory().unwrap();
        store
            .upsert_machine(&Machine {
                id: "m1".into(),
                name: "hetzner-1".into(),
                pubkey: "pk".into(),
                last_seen_at: Some(NOW),
                created_at: NOW,
            })
            .unwrap();
        store
            .upsert_repo(&Repo {
                id: "r1".into(),
                machine_id: "m1".into(),
                path: "/srv/payments-api".into(),
                name: "payments-api".into(),
                budget_usd: repo_cap,
            })
            .unwrap();
        store
            .upsert_session(&Session {
                id: "s1".into(),
                repo_id: "r1".into(),
                agent: Agent::ClaudeCode,
                tmux_target: None,
                status: SessionStatus::Running,
                plan_id: None,
                budget_usd: session_cap,
                spent_usd: 0.0,
                started_at: NOW,
                ended_at: None,
                agent_session_id: None,
            })
            .unwrap();
        store
    }

    pub(super) fn bulky_stable() -> StableContext {
        StableContext {
            system: "You are a coding agent. ".repeat(500),
            history: vec![Turn::user("earlier turn")],
            ..StableContext::default()
        }
    }

    fn gateway(store: SqliteStore, client: StubClient) -> Gateway<SqliteStore, StubClient> {
        Gateway::new(store, client, GatewayConfig::default())
    }

    /// A gateway with the batch queue switched on (C6).
    fn batching_gateway() -> Gateway<SqliteStore, StubClient> {
        let config = GatewayConfig {
            batch_enabled: true,
            ..GatewayConfig::default()
        };
        Gateway::new(store_with(Some(5.0), None), StubClient::new("ok"), config)
    }

    fn deferrable_request() -> CompleteRequest {
        let mut request = CompleteRequest::new("s1", TaskType::Summarize, "nightly summary");
        request.stable = bulky_stable();
        request.deferrable = true;
        request
    }

    #[tokio::test]
    async fn a_live_call_is_priced_and_recorded() {
        let gw = gateway(store_with(Some(5.0), None), StubClient::new("patched it"));
        let mut request = CompleteRequest::new("s1", TaskType::Edit, "fix the retry");
        request.stable = bulky_stable();

        let response = gw.complete(request).await.unwrap();

        assert_eq!(response.text, "patched it");
        assert!(response.served_live());
        assert!(response.cost_usd > 0.0);
        assert_eq!(
            gw.store.list_usage("s1", TimeRange::ALL).unwrap().len(),
            1,
            "the call must land in the ledger"
        );
    }

    #[tokio::test]
    async fn an_exhausted_session_budget_stops_before_dispatch() {
        let store = store_with(Some(0.000_01), None);
        let client = StubClient::new("should not run");
        // Burn the cap with one real call first.
        let gw = gateway(store, client);
        let mut first = CompleteRequest::new("s1", TaskType::Edit, "one");
        first.stable = bulky_stable();
        gw.complete(first).await.unwrap();

        let mut second = CompleteRequest::new("s1", TaskType::Edit, "two");
        second.stable = bulky_stable();
        let err = gw.complete(second).await.unwrap_err();

        assert!(matches!(
            err,
            GatewayError::BudgetExhausted {
                scope: "session",
                ..
            }
        ));
        assert_eq!(gw.client.call_count(), 1, "no second provider call");
    }

    #[tokio::test]
    async fn an_exhausted_repo_budget_stops_an_uncapped_session() {
        let store = store_with(None, Some(0.000_01));
        let gw = gateway(store, StubClient::new("x"));

        let mut first = CompleteRequest::new("s1", TaskType::Edit, "one");
        first.stable = bulky_stable();
        gw.complete(first).await.unwrap();

        let mut second = CompleteRequest::new("s1", TaskType::Edit, "two");
        second.stable = bulky_stable();
        assert!(matches!(
            gw.complete(second).await.unwrap_err(),
            GatewayError::BudgetExhausted { scope: "repo", .. }
        ));
    }

    #[tokio::test]
    async fn a_repeated_cacheable_question_costs_nothing_the_second_time() {
        let gw = gateway(
            store_with(Some(5.0), None),
            StubClient::new("it retries thrice"),
        );

        let ask = || {
            let mut request =
                CompleteRequest::new("s1", TaskType::Summarize, "explain retry_backoff");
            request.stable = bulky_stable();
            request
        };

        let first = gw.complete(ask()).await.unwrap();
        let second = gw.complete(ask()).await.unwrap();

        assert_eq!(first.avoided, None);
        assert_eq!(second.avoided, Some(Avoided::ResponseCache));
        assert_eq!(second.text, first.text, "the cached answer must match");
        assert_eq!(second.cost_usd, 0.0);
        assert_eq!(gw.client.call_count(), 1, "the model was asked once");
    }

    #[tokio::test]
    async fn a_mutating_task_is_never_served_from_cache() {
        let gw = gateway(store_with(Some(5.0), None), StubClient::new("edited"));

        let ask = || {
            let mut request = CompleteRequest::new("s1", TaskType::Edit, "same edit twice");
            request.stable = bulky_stable();
            request
        };

        gw.complete(ask()).await.unwrap();
        let second = gw.complete(ask()).await.unwrap();

        assert_eq!(second.avoided, None);
        assert_eq!(gw.client.call_count(), 2);
        assert!(second.trace.cache_key.is_none());
    }

    #[tokio::test]
    async fn a_refused_turn_is_recorded_but_not_cached() {
        let gw = gateway(store_with(Some(5.0), None), StubClient::refusing());
        let mut request = CompleteRequest::new("s1", TaskType::Summarize, "something declined");
        request.stable = bulky_stable();

        let response = gw.complete(request.clone()).await.unwrap();
        assert!(response.refusal.is_some());
        assert!(response.text.is_empty());

        // The next attempt must reach the provider rather than replay a decline.
        gw.complete(request).await.unwrap();
        assert_eq!(gw.client.call_count(), 2);
    }

    #[tokio::test]
    async fn a_green_pre_gate_answers_a_verify_task_for_free() {
        let repo = std::env::temp_dir().join(format!("forge-gw-green-{}", std::process::id()));
        std::fs::create_dir_all(&repo).unwrap();
        std::fs::write(repo.join("go.mod"), "module x").unwrap();

        let gw = gateway(store_with(Some(5.0), None), StubClient::new("unused"));
        let mut request = CompleteRequest::new("s1", TaskType::HardDebug, "is this correct?");
        request.repo_path = Some(repo.clone());
        request.verify_only = true;

        let response = gw.complete(request).await.unwrap();

        // gofmt/go vet/go test are absent in the test environment, which the
        // gate reports as green rather than as failures.
        assert_eq!(response.avoided, Some(Avoided::PreGate));
        assert_eq!(response.cost_usd, 0.0);
        assert_eq!(gw.client.call_count(), 0, "the model was never asked");

        std::fs::remove_dir_all(&repo).ok();
    }

    #[tokio::test]
    async fn a_plan_pin_reaches_the_dispatched_model() {
        let gw = gateway(store_with(Some(5.0), None), StubClient::new("ok"));
        let mut request = CompleteRequest::new("s1", TaskType::Edit, "small edit");
        request.stable = bulky_stable();
        request.tier_pin = Some(Tier::Small);

        let response = gw.complete(request).await.unwrap();
        assert_eq!(response.model, "claude-haiku-4-5");
        assert_eq!(response.tier, Tier::Small);
        assert_eq!(gw.client.calls()[0].model, "claude-haiku-4-5");
    }

    #[tokio::test]
    async fn deferrable_work_is_queued_rather_than_dispatched() {
        // The whole point of C6: this call does not reach the provider now, and
        // is not billed now. It is billed when it settles, at half rates.
        let gw = batching_gateway();
        let response = gw.complete(deferrable_request()).await.unwrap();

        assert_eq!(response.trace.served, Served::Queued);
        assert!(response.batch_item_id.is_some());
        assert!(
            response.text.is_empty(),
            "there is no answer yet, and it says so"
        );
        assert_eq!(response.cost_usd, 0.0, "nothing is billed until it settles");
        assert!(!response.trace.batch_downgraded);
        assert!(!response.served_live());
    }

    #[tokio::test]
    async fn a_queued_call_stores_what_a_live_one_would_have_sent() {
        // A flush hours later must send what was assembled and decided on, not
        // whatever the repo looks like by then.
        let gw = batching_gateway();
        let id = gw
            .complete(deferrable_request())
            .await
            .unwrap()
            .batch_item_id
            .unwrap();
        let item = gw.store.get_batch_item(&id).unwrap().unwrap();

        let params: serde_json::Value = serde_json::from_str(&item.request_json).unwrap();
        assert_eq!(params["model"], item.model);
        assert!(params["messages"].is_array());
        assert!(params.get("max_tokens").is_some());
        // Not a live-dispatch concern that leaked in: a batch item is
        // resubmittable, and server-side fallbacks are unverified there.
        assert!(params.get("fallbacks").is_none());
    }

    #[tokio::test]
    async fn a_queued_calls_custom_id_marks_it_as_ours() {
        // The API key may be shared. A result whose custom id is not ours must
        // be recognisable as somebody else's, and never billed here.
        let gw = batching_gateway();
        let id = gw
            .complete(deferrable_request())
            .await
            .unwrap()
            .batch_item_id
            .unwrap();
        let item = gw.store.get_batch_item(&id).unwrap().unwrap();
        assert!(item.custom_id.starts_with("forge-"));
    }

    #[tokio::test]
    async fn urgent_work_is_never_queued_even_with_batching_on() {
        let gw = batching_gateway();
        let mut request = CompleteRequest::new("s1", TaskType::Edit, "fix the retry now");
        request.stable = bulky_stable();

        let response = gw.complete(request).await.unwrap();
        assert_eq!(response.trace.served, Served::Live);
        assert!(response.batch_item_id.is_none());
    }

    #[tokio::test]
    async fn deferrable_work_is_billed_live_while_the_batch_queue_is_unbuilt() {
        let gw = gateway(store_with(Some(5.0), None), StubClient::new("ok"));
        let mut request = CompleteRequest::new("s1", TaskType::Summarize, "nightly summary");
        request.stable = bulky_stable();
        request.deferrable = true;

        let response = gw.complete(request).await.unwrap();

        assert!(response.trace.batch_downgraded);
        assert_ne!(
            response.tier,
            Tier::Batch,
            "the ledger must not claim a discount that was not applied"
        );
    }

    #[tokio::test]
    async fn effort_scales_with_the_slot() {
        let gw = gateway(store_with(Some(5.0), None), StubClient::new("ok"));

        let cases = [
            (TaskType::Triage, Effort::Low),
            (TaskType::Edit, Effort::High),
            (TaskType::Plan, Effort::XHigh),
        ];

        for (task, _) in cases {
            let mut request = CompleteRequest::new("s1", task, "work");
            request.stable = bulky_stable();
            gw.complete(request).await.unwrap();
        }

        let efforts: Vec<_> = gw.client.calls().iter().map(|call| call.effort).collect();
        let expected: Vec<_> = cases.iter().map(|(_, effort)| Some(*effort)).collect();
        assert_eq!(efforts, expected);
    }

    #[tokio::test]
    async fn the_second_turn_reads_the_prompt_cache() {
        let gw = gateway(store_with(Some(5.0), None), StubClient::new("ok"));

        let mut first = CompleteRequest::new("s1", TaskType::Edit, "first instruction");
        first.stable = bulky_stable();
        let first = gw.complete(first).await.unwrap();

        let mut second = CompleteRequest::new("s1", TaskType::Edit, "second instruction");
        second.stable = bulky_stable();
        let second = gw.complete(second).await.unwrap();

        assert!(
            first.usage.cache_write_tokens > 0,
            "cold prefix should be written"
        );
        assert!(
            second.usage.cache_read_tokens > 0,
            "warm prefix should be read"
        );
        assert!(second.cost_usd < first.cost_usd);
    }

    #[tokio::test]
    async fn the_trace_explains_why_breakpoints_were_skipped() {
        let gw = gateway(store_with(Some(5.0), None), StubClient::new("ok"));
        // No stable context at all: nothing long enough to cache.
        let response = gw
            .complete(CompleteRequest::new("s1", TaskType::Triage, "hi"))
            .await
            .unwrap();

        assert_eq!(response.trace.breakpoints, 0);
        assert!(
            response
                .trace
                .breakpoint_notes
                .iter()
                .all(|note| !note.placed)
        );
    }
}

#[cfg(test)]
mod compaction_tests {
    use super::tests::{bulky_stable, store_with};
    use super::*;
    use crate::compaction::CompactionPolicy;
    use crate::dispatch::StubClient;
    use forge_core::store::{SqliteStore, TimeRange};

    /// Every usage row for a session, whenever it happened.
    fn usage(gw: &Gateway<SqliteStore, StubClient>) -> Vec<forge_core::types::UsageEvent> {
        gw.store.list_usage("s1", TimeRange::ALL).unwrap()
    }

    /// A history long enough to trip the default policy.
    fn long_history() -> Vec<Turn> {
        (0..30_usize)
            .map(|index| {
                let text = format!("turn {index} ").repeat(600);
                if index.is_multiple_of(2) {
                    Turn::user(text)
                } else {
                    Turn::assistant(text)
                }
            })
            .collect()
    }

    fn compacting_gateway() -> Gateway<SqliteStore, StubClient> {
        Gateway::new(
            store_with(Some(50.0), None),
            StubClient::new("a terse summary"),
            GatewayConfig::default(),
        )
    }

    #[tokio::test]
    async fn a_long_session_gets_its_history_compacted() {
        let gw = compacting_gateway();
        let mut request = CompleteRequest::new("s1", TaskType::Edit, "keep going");
        request.stable = StableContext {
            history: long_history(),
            ..bulky_stable()
        };

        let response = gw.complete(request).await.unwrap();

        let compacted = response
            .compacted_history
            .expect("a 30-turn history should compact");
        assert!(compacted.len() < 30);
        assert!(compacted[0].text.contains("Earlier in this session"));
    }

    #[tokio::test]
    async fn a_short_session_is_left_alone() {
        // Compaction that does not pay for itself is a loss: a summary call plus
        // a thrown-away prompt cache, to save almost nothing.
        let gw = compacting_gateway();
        let mut request = CompleteRequest::new("s1", TaskType::Edit, "keep going");
        request.stable = bulky_stable();

        let response = gw.complete(request).await.unwrap();
        assert!(response.compacted_history.is_none());
    }

    #[tokio::test]
    async fn the_summary_call_is_billed_and_reported() {
        // A turn that compacted really did cost that much. Reporting only the
        // answer would make compaction look free, which is the one thing this
        // feature must not appear to be.
        let gw = compacting_gateway();
        let mut request = CompleteRequest::new("s1", TaskType::Edit, "keep going");
        request.stable = StableContext {
            history: long_history(),
            ..bulky_stable()
        };

        let response = gw.complete(request).await.unwrap();

        // Two ledger rows for one turn: the summary and the answer.
        let events = usage(&gw);
        assert_eq!(events.len(), 2);
        assert!(
            events
                .iter()
                .any(|event| event.task_type == TaskType::Summarize)
        );
        // And the reported cost covers both.
        let total: f64 = events.iter().map(|event| event.cost_usd).sum();
        assert!((response.cost_usd - total).abs() < 1e-9);
    }

    #[tokio::test]
    async fn the_summary_is_written_by_the_small_tier() {
        // Paying frontier rates to condense a transcript would undo the saving
        // the feature exists to produce.
        let gw = compacting_gateway();
        let mut request = CompleteRequest::new("s1", TaskType::Plan, "what next");
        request.stable = StableContext {
            history: long_history(),
            ..bulky_stable()
        };

        gw.complete(request).await.unwrap();

        let summary = usage(&gw)
            .into_iter()
            .find(|event| event.task_type == TaskType::Summarize)
            .expect("a summary call");
        assert_eq!(summary.tier, Tier::Small);
        assert_eq!(summary.model, GatewayConfig::default().models.small);
    }

    #[tokio::test]
    async fn compaction_can_be_switched_off() {
        let gw = Gateway::new(
            store_with(Some(50.0), None),
            StubClient::new("ok"),
            GatewayConfig {
                compaction: None,
                ..GatewayConfig::default()
            },
        );
        let mut request = CompleteRequest::new("s1", TaskType::Edit, "keep going");
        request.stable = StableContext {
            history: long_history(),
            ..bulky_stable()
        };

        let response = gw.complete(request).await.unwrap();
        assert!(response.compacted_history.is_none());
        assert_eq!(usage(&gw).len(), 1);
    }

    #[tokio::test]
    async fn a_compacted_history_does_not_compact_again_next_turn() {
        // The failure this rules out: re-summarising every turn, paying for the
        // summary repeatedly *and* invalidating the prompt cache each time —
        // strictly worse than never compacting.
        let gw = compacting_gateway();
        let mut first = CompleteRequest::new("s1", TaskType::Edit, "keep going");
        first.stable = StableContext {
            history: long_history(),
            ..bulky_stable()
        };

        let compacted = gw
            .complete(first)
            .await
            .unwrap()
            .compacted_history
            .expect("first turn compacts");

        let mut second = CompleteRequest::new("s1", TaskType::Edit, "and again");
        second.stable = StableContext {
            history: compacted,
            ..bulky_stable()
        };
        assert!(
            gw.complete(second)
                .await
                .unwrap()
                .compacted_history
                .is_none(),
            "the caller stored the compacted history, so there is nothing left to cut"
        );
    }

    #[tokio::test]
    async fn a_custom_policy_is_respected() {
        let gw = Gateway::new(
            store_with(Some(50.0), None),
            StubClient::new("summary"),
            GatewayConfig {
                compaction: Some(CompactionPolicy {
                    trigger_bytes: 1_000,
                    keep_recent: 2,
                    min_turns: 2,
                }),
                ..GatewayConfig::default()
            },
        );
        let mut request = CompleteRequest::new("s1", TaskType::Edit, "go");
        request.stable = StableContext {
            history: (0..6)
                .map(|i| Turn::user("x".repeat(500) + &i.to_string()))
                .collect(),
            ..bulky_stable()
        };

        let response = gw.complete(request).await.unwrap();
        assert_eq!(
            response.compacted_history.unwrap().len(),
            3,
            "summary + 2 kept"
        );
    }
}
