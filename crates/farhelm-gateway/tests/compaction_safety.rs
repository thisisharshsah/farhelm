//! A paid summary is not necessarily a usable replacement for conversation
//! history. Keep the original history unless the summary finished completely.

use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
};

use farhelm_app::store::{TimeRange, prelude::*};
use farhelm_domain::price::TokenRates;
use farhelm_gateway::{
    CompleteRequest, Gateway, GatewayConfig, GatewayError, ModelClient, ModelRequest,
    ModelResponse, Served, StableContext, ToolCall, Turn,
    compaction::CompactionPolicy,
    dispatch::{DispatchError, Refusal},
};
use farhelm_proto::types::{
    Agent, Avoided, BatchStatus, Dispatch, Machine, Repo, Session, SessionStatus, TaskType, Usage,
};
use farhelm_sqlite::SqliteStore;
use serde_json::json;

const NOW: i64 = 1_785_369_600_000;

fn store(session_cap: Option<f64>, repo_cap: Option<f64>) -> SqliteStore {
    let store = SqliteStore::open_in_memory().unwrap();
    store
        .upsert_machine(&Machine {
            id: "m1".into(),
            name: "test".into(),
            pubkey: "test".into(),
            last_seen_at: Some(NOW),
            created_at: NOW,
        })
        .unwrap();
    store
        .upsert_repo(&Repo {
            id: "r1".into(),
            machine_id: "m1".into(),
            path: "/unused".into(),
            name: "test".into(),
            budget_usd: repo_cap,
        })
        .unwrap();
    store
        .upsert_session(&Session {
            id: "s1".into(),
            repo_id: "r1".into(),
            agent: Agent::Farhelm,
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

struct QueuedClient {
    replies: Mutex<VecDeque<ModelResponse>>,
    calls: Arc<Mutex<Vec<ModelRequest>>>,
}

impl ModelClient for QueuedClient {
    async fn complete(&self, request: ModelRequest) -> Result<ModelResponse, DispatchError> {
        let model = request.model.clone();
        self.calls.lock().unwrap().push(request);
        let mut reply = self
            .replies
            .lock()
            .unwrap()
            .pop_front()
            .ok_or_else(|| DispatchError::Decode("unexpected provider call".into()))?;
        reply.model = model;
        Ok(reply)
    }

    fn billing_rates(&self, _: &str) -> Option<TokenRates> {
        Some(TokenRates::new(1.0, 1.0, 1.0, 1.0).unwrap())
    }
}

fn response(text: &str, stop_reason: Option<&str>, input_tokens: u32) -> ModelResponse {
    ModelResponse {
        text: text.into(),
        usage: Usage {
            input_tokens,
            ..Usage::default()
        },
        model: String::new(),
        stop_reason: stop_reason.map(str::to_owned),
        refusal: None,
        tool_calls: Vec::new(),
    }
}

fn setup(summary: ModelResponse) -> (QueuedClient, Arc<Mutex<Vec<ModelRequest>>>) {
    let calls = Arc::new(Mutex::new(Vec::new()));
    (
        QueuedClient {
            replies: Mutex::new(VecDeque::from([
                summary,
                response("final answer", Some("end_turn"), 2_000_000),
            ])),
            calls: calls.clone(),
        },
        calls,
    )
}

fn config() -> GatewayConfig {
    GatewayConfig {
        compaction: Some(CompactionPolicy {
            trigger_bytes: 1,
            keep_recent: 1,
            min_turns: 2,
        }),
        ..GatewayConfig::default()
    }
}

fn request() -> CompleteRequest {
    let mut request = CompleteRequest::new("s1", TaskType::Edit, "continue the work");
    request.stable = StableContext {
        history: vec![
            Turn::user("Original user requirement: preserve record identifiers."),
            Turn::assistant("Original decision: migrate storage incrementally."),
            Turn::user("Recent user instruction: run the focused checks."),
        ],
        ..StableContext::default()
    };
    request
}

#[tokio::test]
async fn unusable_summaries_keep_history_and_their_charges_are_reported() {
    let mut refused = response("", Some("refusal"), 1_000_000);
    refused.refusal = Some(Refusal {
        category: None,
        explanation: Some("declined".into()),
    });
    let mut tool = response("", Some("tool_use"), 1_000_000);
    tool.tool_calls.push(ToolCall {
        id: "call_1".into(),
        name: "read_file".into(),
        input: json!({}),
    });
    for (case, summary) in [
        (
            "truncated",
            response("partial summary", Some("length"), 1_000_000),
        ),
        (
            "max_tokens",
            response("partial summary", Some("max_tokens"), 1_000_000),
        ),
        ("refused", refused),
        ("tool call", tool),
        ("empty", response("", Some("stop"), 1_000_000)),
        ("whitespace", response("  \n", Some("end_turn"), 1_000_000)),
        (
            "unfinished",
            response("possibly incomplete summary", None, 1_000_000),
        ),
    ] {
        let store = store(None, None);
        let (client, calls) = setup(summary);
        let gateway = Gateway::new(&store, client, config());
        let result = gateway.complete(request()).await.unwrap();
        assert!(
            result.compacted_history.is_none(),
            "{case} replaced history"
        );
        let calls = calls.lock().unwrap();
        assert_eq!(calls.len(), 2, "{case}");
        let sent = serde_json::to_value(&calls[1].plan.messages)
            .unwrap()
            .to_string();
        assert!(
            sent.contains("Original user requirement"),
            "{case} lost user history"
        );
        assert!(
            sent.contains("Original decision"),
            "{case} lost assistant history"
        );
        assert!(
            sent.contains("Recent user instruction"),
            "{case} lost recent history"
        );
        let events = store.list_usage("s1", TimeRange::ALL).unwrap();
        assert_eq!(events.len(), 2, "{case} omitted a paid call");
        assert_eq!(
            events.iter().map(|event| event.cost_usd).sum::<f64>(),
            3.0,
            "{case}"
        );
        assert_eq!(
            result.cost_usd, 3.0,
            "{case} hid summary charges in response"
        );
    }
}

#[tokio::test]
async fn completed_summary_replaces_history_and_reports_both_calls() {
    let store = store(None, None);
    let (client, calls) = setup(response(
        "Preserve identifiers and migrate storage incrementally.",
        Some("stop"),
        1_000_000,
    ));
    let gateway = Gateway::new(&store, client, config());
    let result = gateway.complete(request()).await.unwrap();
    let compacted = result.compacted_history.unwrap();
    assert_eq!(compacted.len(), 2);
    assert!(compacted[0].text.contains("Preserve identifiers"));
    assert_eq!(
        compacted[1].text,
        "Recent user instruction: run the focused checks."
    );
    assert_eq!(calls.lock().unwrap().len(), 2);
    assert_eq!(result.cost_usd, 3.0);
}

#[tokio::test]
async fn summary_that_exhausts_session_or_repo_budget_prevents_main_dispatch() {
    for (scope, session_cap, repo_cap) in [("session", Some(0.5), None), ("repo", None, Some(0.5))]
    {
        let store = store(session_cap, repo_cap);
        let (client, calls) = setup(response("Finished summary.", Some("stop"), 1_000_000));
        let gateway = Gateway::new(&store, client, config());
        let error = gateway.complete(request()).await.unwrap_err();
        assert!(
            matches!(error, GatewayError::BudgetExhausted { scope: actual, .. } if actual == scope),
            "{scope}: {error}"
        );
        assert_eq!(
            calls.lock().unwrap().len(),
            1,
            "{scope} dispatched main call after summary spent the cap"
        );
        let events = store.list_usage("s1", TimeRange::ALL).unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].cost_usd, 1.0);
    }
}

#[tokio::test]
async fn a_cache_hit_reports_summary_cost_and_returns_history_to_prevent_repeated_compaction() {
    let store = store(None, None);
    let summary = response(
        "Preserve identifiers and migrate storage incrementally.",
        Some("stop"),
        1_000_000,
    );
    let (mut client, calls) = setup(summary.clone());
    // First request: summarize, dispatch, populate the response cache.
    // Second request: summarize the same original history, then use that cache.
    client.replies.get_mut().unwrap().push_back(summary);
    let gateway = Gateway::new(&store, client, config());
    let mut first = request();
    first.task_type = TaskType::Summarize;
    let first = gateway.complete(first).await.unwrap();
    assert_eq!(first.trace.served, Served::Live);
    assert_eq!(first.cost_usd, 3.0);

    let before = store.list_usage("s1", TimeRange::ALL).unwrap().len();
    let mut second = request();
    second.task_type = TaskType::Summarize;
    let second = gateway.complete(second).await.unwrap();
    assert_eq!(second.trace.served, Served::ResponseCache);
    assert_eq!(second.avoided, Some(Avoided::ResponseCache));
    assert_eq!(second.text, "final answer");
    assert_eq!(second.usage, Usage::default());
    assert_eq!(second.cost_usd, 1.0);
    let events = store.list_usage("s1", TimeRange::ALL).unwrap();
    assert_eq!(
        events[before..]
            .iter()
            .map(|event| event.cost_usd)
            .sum::<f64>(),
        second.cost_usd
    );
    assert_eq!(
        events[before..]
            .iter()
            .filter(|event| event.avoided == Some(Avoided::ResponseCache))
            .count(),
        1
    );
    assert_eq!(calls.lock().unwrap().len(), 3);
    let compacted = second
        .compacted_history
        .expect("cache hit must return newly compacted history");
    assert_eq!(compacted.len(), 2);

    // Once the caller accepts that history, the next identical request is free
    // and does not pay for the same summary again.
    let mut third = request();
    third.task_type = TaskType::Summarize;
    third.stable.history = compacted;
    let third = gateway.complete(third).await.unwrap();
    assert_eq!(third.trace.served, Served::ResponseCache);
    assert_eq!(third.cost_usd, 0.0);
    assert_eq!(calls.lock().unwrap().len(), 3);
}

#[tokio::test]
async fn a_queued_answer_reports_already_charged_summary_cost_and_retains_compacted_history() {
    let store = store(None, None);
    let (client, calls) = setup(response(
        "Preserve identifiers and migrate storage incrementally.",
        Some("stop"),
        1_000_000,
    ));
    let gateway = Gateway::new(
        &store,
        client,
        GatewayConfig {
            batch_enabled: true,
            ..config()
        },
    );
    let mut queued = request();
    queued.deferrable = true;
    let queued = gateway.complete(queued).await.unwrap();
    assert_eq!(queued.trace.served, Served::Queued);
    assert_eq!(queued.dispatch, Dispatch::Batch);
    assert!(queued.text.is_empty());
    assert_eq!(queued.usage, Usage::default());
    assert_eq!(queued.cost_usd, 1.0);
    assert_eq!(queued.compacted_history.unwrap().len(), 2);
    assert_eq!(
        calls.lock().unwrap().len(),
        1,
        "queued main answer must not dispatch yet"
    );
    let events = store.list_usage("s1", TimeRange::ALL).unwrap();
    assert_eq!(
        events.len(),
        1,
        "only the live summary should be billed now"
    );
    assert_eq!(
        events.iter().map(|event| event.cost_usd).sum::<f64>(),
        queued.cost_usd
    );
    let item = store
        .get_batch_item(queued.batch_item_id.as_deref().unwrap())
        .unwrap()
        .unwrap();
    assert_eq!(item.status, BatchStatus::Queued);
    assert!(item.request_json.contains("Preserve identifiers"));
    assert!(!item.request_json.contains("Original user requirement"));
}
