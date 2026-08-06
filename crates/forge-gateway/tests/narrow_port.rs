//! The gateway's storage bound, exercised by writing a double for it.
//!
//! This test is the argument for splitting the store port, made by construction
//! rather than by assertion: the fake below is the *whole* of what the pipeline
//! needs from storage. Under the old `S: Store` bound it would have had to be
//! forty methods, thirty-six of them `unimplemented!()`, which is why nobody
//! wrote one and every gateway test went through real SQLite instead.
//!
//! It also pins the claim in `GatewayStore`'s doc comment. If someone adds a
//! `store.list_devices()` to the pipeline, this file stops compiling — which is
//! the point. Widening what the gateway may touch should be a decision, not
//! something that happens because the bound already allowed it.

use std::cell::RefCell;
use std::collections::HashMap;

use forge_app::store::{BatchStore, LedgerStore, ResponseCache, Result, SessionStore, TimeRange};
use forge_proto::types::{BatchItem, BatchStatus, Budget, Session, UsageEvent};

/// Everything the cost pipeline can reach, and nothing else.
struct FakeStore {
    session: Option<Session>,
    budget: Budget,
    repo_budget: Budget,
    usage: RefCell<Vec<UsageEvent>>,
    cache: RefCell<HashMap<String, String>>,
    queued: RefCell<Vec<BatchItem>>,
}

/// Uncapped and empty. Written out rather than derived because `Budget` has no
/// `Default` — and should not grow one for a test's convenience, since "an
/// unconfigured budget" is a decision the wire type has deliberately declined to
/// make.
impl Default for FakeStore {
    fn default() -> Self {
        let uncapped = Budget {
            cap_usd: None,
            spent_usd: 0.0,
        };
        Self {
            session: None,
            budget: uncapped,
            repo_budget: uncapped,
            usage: RefCell::new(Vec::new()),
            cache: RefCell::new(HashMap::new()),
            queued: RefCell::new(Vec::new()),
        }
    }
}

// Not `Sync`-safe, and does not need to be: the bounds below are exactly what
// `Gateway` requires, and `RefCell` is enough for a single-threaded test.
impl SessionStore for FakeStore {
    fn upsert_session(&self, _session: &Session) -> Result<()> {
        Ok(())
    }
    fn get_session(&self, _id: &str) -> Result<Option<Session>> {
        Ok(self.session.clone())
    }
    fn list_sessions(&self) -> Result<Vec<Session>> {
        Ok(self.session.clone().into_iter().collect())
    }
    fn find_session_by_agent_id(&self, _agent_session_id: &str) -> Result<Option<Session>> {
        Ok(None)
    }
}

impl LedgerStore for FakeStore {
    fn record_usage(&self, event: &UsageEvent) -> Result<()> {
        self.usage.borrow_mut().push(event.clone());
        Ok(())
    }
    fn list_usage(&self, _session_id: &str, _range: TimeRange) -> Result<Vec<UsageEvent>> {
        Ok(self.usage.borrow().clone())
    }
    fn session_budget(&self, _session_id: &str) -> Result<Budget> {
        Ok(self.budget)
    }
    fn repo_budget(&self, _repo_id: &str) -> Result<Budget> {
        Ok(self.repo_budget)
    }
}

impl ResponseCache for FakeStore {
    fn cache_get(&self, key_hash: &str, _now_ms: i64) -> Result<Option<String>> {
        Ok(self.cache.borrow().get(key_hash).cloned())
    }
    fn cache_put(&self, key_hash: &str, response: &str, _now: i64, _ttl: i64) -> Result<()> {
        self.cache
            .borrow_mut()
            .insert(key_hash.to_owned(), response.to_owned());
        Ok(())
    }
    fn cache_purge_expired(&self, _now_ms: i64) -> Result<usize> {
        Ok(0)
    }
}

impl BatchStore for FakeStore {
    fn enqueue_batch_item(&self, item: &BatchItem) -> Result<()> {
        self.queued.borrow_mut().push(item.clone());
        Ok(())
    }
    fn list_queued_batch_items(&self, _limit: usize) -> Result<Vec<BatchItem>> {
        Ok(self.queued.borrow().clone())
    }
    fn list_submitted_batch_items(&self) -> Result<Vec<BatchItem>> {
        Ok(Vec::new())
    }
    fn get_batch_item(&self, _id: &str) -> Result<Option<BatchItem>> {
        Ok(None)
    }
    fn list_batch_items_for_session(&self, _session_id: &str) -> Result<Vec<BatchItem>> {
        Ok(Vec::new())
    }
    fn mark_batch_submitted(&self, _ids: &[String], _batch: &str, _at: i64) -> Result<()> {
        Ok(())
    }
    fn settle_batch_item(
        &self,
        _custom_id: &str,
        _status: BatchStatus,
        _response_text: Option<&str>,
        _error: Option<&str>,
        _settled_at: i64,
    ) -> Result<()> {
        Ok(())
    }
}

/// The fake satisfies the gateway's bound — which is the assertion.
///
/// It implements four of the nine role ports. It does not implement
/// `ApprovalStore`, `DeviceStore`, `PlanStore`, `TaskStore` or `FleetStore`, so
/// it is not a `Store` at all, and the fact that this compiles is the proof that
/// the gateway never needed to be handed one.
fn assert_is_a_gateway_store<S: forge_gateway::GatewayStore>(_store: &S) {}

#[test]
fn the_gateway_needs_four_ports_not_the_whole_store() {
    let fake = FakeStore::default();
    assert_is_a_gateway_store(&fake);
}

/// The pipeline's budget guard, driven entirely through the fake.
#[tokio::test]
async fn an_exhausted_session_budget_stops_a_call_without_touching_sqlite() {
    use forge_gateway::dispatch::StubClient;
    use forge_gateway::{CompleteRequest, Gateway, GatewayConfig, GatewayError};
    use forge_proto::types::{Agent, SessionStatus, TaskType};

    let fake = FakeStore {
        session: Some(Session {
            id: "s1".into(),
            repo_id: "r1".into(),
            agent: Agent::Forge,
            tmux_target: None,
            status: SessionStatus::Running,
            plan_id: None,
            budget_usd: Some(1.0),
            spent_usd: 1.0,
            started_at: 0,
            ended_at: None,
            agent_session_id: None,
        }),
        // Spent its cap exactly, which is the hard stop.
        budget: Budget {
            cap_usd: Some(1.0),
            spent_usd: 1.0,
        },
        ..FakeStore::default()
    };

    let gateway = Gateway::new(
        fake,
        StubClient::new("never reached"),
        GatewayConfig::default(),
    );
    let err = gateway
        .complete(CompleteRequest::new("s1", TaskType::Edit, "do a thing"))
        .await
        .expect_err("an exhausted session must not dispatch");

    assert!(
        matches!(
            err,
            GatewayError::BudgetExhausted {
                scope: "session",
                ..
            }
        ),
        "expected a session-scoped budget stop, got {err}"
    );
}
