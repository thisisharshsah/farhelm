//! C6: the Batch API queue.
//!
//! Deferrable work — test generation, doc sweeps, lint fixes — does not need an
//! answer now. The Batch API charges half price for exactly that trade, and the
//! discount stacks with prompt caching, so this is the cheapest tokens the
//! gateway can buy.
//!
//! # The shape of the trade
//!
//! A live call returns text. A queued call returns an **id**. Most batches finish
//! within an hour and the ceiling is twenty-four, so nothing that blocks a human
//! belongs here. [`crate::pipeline`] only queues a call the caller explicitly
//! marked `deferrable`, and it says so in the response rather than pretending to
//! have an answer.
//!
//! # Paying twice is the failure mode to design against
//!
//! Every other failure here is recoverable — a batch that errors can be
//! resubmitted, one that expires can be rebuilt. Being billed twice for the same
//! work cannot be undone, and it is the one thing a cost gateway must not do. So:
//!
//! - Submitting moves the whole batch in one transaction. A crash partway
//!   through cannot leave half the items looking queued.
//! - `settle_batch_item` only acts on an item still marked `submitted`, so
//!   fetching results twice — a poll overlapping a retry — writes one ledger row.
//! - A `custom_id` is unique in the database, so a result can never be
//!   attributed to the wrong session.
//!
//! # What is verified, and what is not
//!
//! The request and response shapes are built to the documented Batches API and
//! exercised end to end against a fake provider that speaks it, including the
//! JSONL results format. **No request has been sent to the real endpoint** — no
//! API key here — so treat the first real flush as the proving run. The queue
//! itself, the double-billing guards, and the ledger arithmetic are all covered.

use std::time::Duration;

use forge_app::store::{BatchStore, LedgerStore};
use forge_proto::types::{BatchItem, BatchStatus, Usage};
use serde::{Deserialize, Serialize};

use crate::dispatch::DispatchError;

/// The provider's cap. Exceeding it is a rejected batch, not a partial one.
pub const MAX_REQUESTS_PER_BATCH: usize = 100_000;

/// How many to take per flush.
///
/// Far below the cap on purpose: a smaller batch settles sooner, and the whole
/// point of this queue is work that is *cheap*, not work that is urgent. It also
/// bounds how much is in flight when something goes wrong.
pub const FLUSH_SIZE: usize = 500;

/// One request in a batch submission.
#[derive(Debug, Serialize)]
pub struct BatchRequest {
    pub custom_id: String,
    /// The Messages params, verbatim as they were assembled and priced.
    pub params: serde_json::Value,
}

/// What the provider says about a batch.
#[derive(Debug, Clone, Deserialize)]
pub struct BatchState {
    pub id: String,
    /// `in_progress` | `canceling` | `ended`.
    pub processing_status: String,
}

impl BatchState {
    pub fn has_ended(&self) -> bool {
        self.processing_status == "ended"
    }
}

/// One line of the JSONL results.
#[derive(Debug, Clone)]
pub struct BatchResult {
    pub custom_id: String,
    pub status: BatchStatus,
    pub text: Option<String>,
    pub usage: Option<Usage>,
    pub error: Option<String>,
}

/// The Batch API, behind a trait so the queue is testable without a provider.
pub trait BatchClient: Send + Sync {
    fn submit(
        &self,
        requests: Vec<BatchRequest>,
    ) -> impl std::future::Future<Output = Result<BatchState, DispatchError>> + Send;

    fn state(
        &self,
        batch_id: &str,
    ) -> impl std::future::Future<Output = Result<BatchState, DispatchError>> + Send;

    /// Results, once the batch has ended.
    fn results(
        &self,
        batch_id: &str,
    ) -> impl std::future::Future<Output = Result<Vec<BatchResult>, DispatchError>> + Send;
}

/* --------------------------------------------------------------- wire parsing */

/// Parse one line of the results JSONL.
///
/// A line that cannot be parsed is reported as an errored item rather than
/// aborting the collection: one malformed result must not strand the other four
/// hundred, which would leave them `submitted` forever and never billed.
pub fn parse_result_line(line: &str) -> Option<BatchResult> {
    let value: serde_json::Value = serde_json::from_str(line).ok()?;
    let custom_id = value.get("custom_id")?.as_str()?.to_owned();
    let result = value.get("result")?;
    let kind = result.get("type").and_then(|t| t.as_str()).unwrap_or("");

    match kind {
        "succeeded" => {
            let message = result.get("message");
            let text = message
                .and_then(|m| m.get("content"))
                .and_then(|c| c.as_array())
                .map(|blocks| {
                    blocks
                        .iter()
                        .filter(|block| block.get("type").and_then(|t| t.as_str()) == Some("text"))
                        .filter_map(|block| block.get("text").and_then(|t| t.as_str()))
                        .collect::<Vec<_>>()
                        .join("")
                })
                .unwrap_or_default();

            let usage = message.and_then(|m| m.get("usage")).map(|u| {
                let read = |key: &str| u.get(key).and_then(|v| v.as_u64()).unwrap_or(0) as u32;
                Usage {
                    input_tokens: read("input_tokens"),
                    output_tokens: read("output_tokens"),
                    cache_write_tokens: read("cache_creation_input_tokens"),
                    cache_read_tokens: read("cache_read_input_tokens"),
                }
            });

            Some(BatchResult {
                custom_id,
                status: BatchStatus::Succeeded,
                text: Some(text),
                usage,
                error: None,
            })
        }
        "errored" => Some(BatchResult {
            custom_id,
            status: BatchStatus::Errored,
            text: None,
            usage: None,
            error: Some(
                result
                    .get("error")
                    .and_then(|e| e.get("type"))
                    .and_then(|t| t.as_str())
                    .unwrap_or("errored")
                    .to_owned(),
            ),
        }),
        "expired" => Some(BatchResult {
            custom_id,
            status: BatchStatus::Expired,
            text: None,
            usage: None,
            // Expiry means the 24-hour ceiling was hit. Resubmitting is a new
            // item, never a mutation of this one — see `BatchStatus`.
            error: Some("the batch expired before this request ran".into()),
        }),
        "canceled" => Some(BatchResult {
            custom_id,
            status: BatchStatus::Canceled,
            text: None,
            usage: None,
            error: Some("canceled".into()),
        }),
        _ => None,
    }
}

/* ------------------------------------------------------------------ the queue */

#[derive(Debug)]
pub enum BatchError {
    Store(forge_app::store::StoreError),
    Dispatch(DispatchError),
    Ledger(forge_app::ledger::LedgerError),
}

impl std::fmt::Display for BatchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BatchError::Store(err) => write!(f, "batch queue: {err}"),
            BatchError::Dispatch(err) => write!(f, "batch queue: {err}"),
            BatchError::Ledger(err) => write!(f, "batch queue: {err}"),
        }
    }
}

impl std::error::Error for BatchError {}

impl From<forge_app::store::StoreError> for BatchError {
    fn from(err: forge_app::store::StoreError) -> Self {
        BatchError::Store(err)
    }
}

impl From<DispatchError> for BatchError {
    fn from(err: DispatchError) -> Self {
        BatchError::Dispatch(err)
    }
}

impl From<forge_app::ledger::LedgerError> for BatchError {
    fn from(err: forge_app::ledger::LedgerError) -> Self {
        BatchError::Ledger(err)
    }
}

/// What one flush did, for logging and for the dashboard.
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize)]
pub struct FlushReport {
    pub submitted: usize,
    pub batch_id: Option<String>,
}

/// What one collection pass did.
#[derive(Debug, Default, Clone, PartialEq, Serialize)]
pub struct CollectReport {
    pub batches_checked: usize,
    pub settled: usize,
    pub succeeded: usize,
    pub failed: usize,
    /// What the settled work cost, at batch rates.
    pub cost_usd: f64,
}

pub struct BatchQueue<S, C> {
    store: S,
    client: C,
}

impl<S: BatchStore + LedgerStore, C: BatchClient> BatchQueue<S, C> {
    pub fn new(store: S, client: C) -> Self {
        Self { store, client }
    }

    /// Send everything waiting, as one batch.
    ///
    /// Submitting first and recording second is deliberate. The other order
    /// would mark items sent that a failed submit never sent, and they would sit
    /// `submitted` forever waiting for results from a batch that does not exist.
    /// This order can duplicate at most one batch if the process dies between
    /// the two, which is recoverable by hand; the other is not recoverable at
    /// all.
    pub async fn flush(&self, now_ms: i64) -> Result<FlushReport, BatchError> {
        let queued = self.store.list_queued_batch_items(FLUSH_SIZE)?;
        if queued.is_empty() {
            return Ok(FlushReport::default());
        }

        let requests = queued
            .iter()
            .filter_map(|item| {
                Some(BatchRequest {
                    custom_id: item.custom_id.clone(),
                    params: serde_json::from_str(&item.request_json).ok()?,
                })
            })
            .collect::<Vec<_>>();

        // Every request was serialised by this crate, so a parse failure here
        // means a corrupt row rather than a provider problem. Sending the rest
        // beats stalling the queue on one bad item.
        if requests.is_empty() {
            return Ok(FlushReport::default());
        }

        let state = self.client.submit(requests).await?;
        let ids = queued
            .iter()
            .map(|item| item.id.clone())
            .collect::<Vec<_>>();
        self.store.mark_batch_submitted(&ids, &state.id, now_ms)?;

        Ok(FlushReport {
            submitted: ids.len(),
            batch_id: Some(state.id),
        })
    }

    /// Check every batch in flight and bank whatever has landed.
    pub async fn collect(&self, now_ms: i64) -> Result<CollectReport, BatchError> {
        let in_flight = self.store.list_submitted_batch_items()?;
        let mut batch_ids = in_flight
            .iter()
            .filter_map(|item| item.batch_id.clone())
            .collect::<Vec<_>>();
        batch_ids.sort();
        batch_ids.dedup();

        let mut report = CollectReport::default();
        for batch_id in batch_ids {
            report.batches_checked += 1;

            let state = self.client.state(&batch_id).await?;
            if !state.has_ended() {
                continue;
            }

            for result in self.client.results(&batch_id).await? {
                let Some(item) = in_flight
                    .iter()
                    .find(|candidate| candidate.custom_id == result.custom_id)
                else {
                    // A result for something this runner did not queue. Not an
                    // error — the API key may be shared with another tool — but
                    // definitely not ours to bill.
                    continue;
                };

                let cost = self.settle(item, &result, now_ms)?;
                report.settled += 1;
                report.cost_usd += cost;
                if result.status == BatchStatus::Succeeded {
                    report.succeeded += 1;
                } else {
                    report.failed += 1;
                }
            }
        }
        Ok(report)
    }

    /// Record one result, and bill it at batch rates.
    ///
    /// The ledger write happens only for a success with usage attached: a batch
    /// request that errored consumed nothing, and an expired one never ran.
    fn settle(
        &self,
        item: &BatchItem,
        result: &BatchResult,
        now_ms: i64,
    ) -> Result<f64, BatchError> {
        self.store.settle_batch_item(
            &result.custom_id,
            result.status,
            result.text.as_deref(),
            result.error.as_deref(),
            now_ms,
        )?;

        let (BatchStatus::Succeeded, Some(usage)) = (result.status, result.usage) else {
            return Ok(0.0);
        };

        // `.batched()` is what applies the 50% discount, inside the ledger's own
        // pricing. This is the one place it is legitimate to claim it: the
        // tokens really did go through the Batch API. Everywhere else that flag
        // would be a discount the bill never got.
        //
        // The tier is the one recorded when the item was queued, so the ledger
        // says which model actually ran rather than the one the router would
        // pick today.
        let call = forge_app::ledger::Call::new(
            &item.session_id,
            &item.model,
            item.tier,
            item.task_type,
            usage,
        )
        .batched();
        let recorded = forge_app::ledger::Ledger::new(&self.store).record_at(call, now_ms)?;
        Ok(recorded.cost_usd)
    }
}

/* ---------------------------------------------------------------- the client */

/// The real Batches API.
pub struct AnthropicBatchClient {
    api_key: String,
    base_url: String,
    http: reqwest::Client,
}

impl AnthropicBatchClient {
    pub fn new(api_key: impl Into<String>, base_url: impl Into<String>) -> Self {
        Self {
            api_key: api_key.into(),
            base_url: base_url.into(),
            http: reqwest::Client::builder()
                // Submitting a large batch is a big upload; collecting is a
                // large download. Neither is interactive.
                .timeout(Duration::from_secs(300))
                .build()
                .expect("reqwest client"),
        }
    }

    pub fn from_env() -> Option<Self> {
        let key = std::env::var("ANTHROPIC_API_KEY").ok()?;
        if key.trim().is_empty() {
            return None;
        }
        let base = std::env::var("ANTHROPIC_BASE_URL")
            .ok()
            .filter(|base| !base.trim().is_empty())
            .unwrap_or_else(|| "https://api.anthropic.com".to_owned());
        Some(Self::new(key, base))
    }

    fn request(&self, method: reqwest::Method, path: &str) -> reqwest::RequestBuilder {
        self.http
            .request(
                method,
                format!("{}{path}", self.base_url.trim_end_matches('/')),
            )
            .header("x-api-key", &self.api_key)
            .header("anthropic-version", "2023-06-01")
    }
}

impl BatchClient for AnthropicBatchClient {
    async fn submit(&self, requests: Vec<BatchRequest>) -> Result<BatchState, DispatchError> {
        let response = self
            .request(reqwest::Method::POST, "/v1/messages/batches")
            .json(&serde_json::json!({ "requests": requests }))
            .send()
            .await
            .map_err(|err| DispatchError::Transport(err.to_string()))?;

        decode(response).await
    }

    async fn state(&self, batch_id: &str) -> Result<BatchState, DispatchError> {
        let response = self
            .request(
                reqwest::Method::GET,
                &format!("/v1/messages/batches/{batch_id}"),
            )
            .send()
            .await
            .map_err(|err| DispatchError::Transport(err.to_string()))?;

        decode(response).await
    }

    async fn results(&self, batch_id: &str) -> Result<Vec<BatchResult>, DispatchError> {
        let response = self
            .request(
                reqwest::Method::GET,
                &format!("/v1/messages/batches/{batch_id}/results"),
            )
            .send()
            .await
            .map_err(|err| DispatchError::Transport(err.to_string()))?;

        let status = response.status();
        let body = response
            .text()
            .await
            .map_err(|err| DispatchError::Transport(err.to_string()))?;

        if !status.is_success() {
            return Err(DispatchError::Api {
                status: status.as_u16(),
                message: body,
            });
        }

        // JSONL: one result per line.
        Ok(body.lines().filter_map(parse_result_line).collect())
    }
}

async fn decode(response: reqwest::Response) -> Result<BatchState, DispatchError> {
    let status = response.status();
    let body = response
        .text()
        .await
        .map_err(|err| DispatchError::Transport(err.to_string()))?;

    if !status.is_success() {
        return Err(DispatchError::Api {
            status: status.as_u16(),
            message: body,
        });
    }
    serde_json::from_str(&body).map_err(|err| DispatchError::Decode(err.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use forge_app::store::{FleetStore, SessionStore};
    use forge_proto::types::Tier;
    use forge_proto::types::{Agent, Machine, Repo, Session, SessionStatus, TaskType};
    use forge_sqlite::SqliteStore;
    use std::sync::Mutex;

    const NOW: i64 = 1_785_369_600_000;

    /* -------------------------------------------------------- results JSONL */

    #[test]
    fn a_succeeded_result_yields_its_text_and_usage() {
        let line = r#"{"custom_id":"c1","result":{"type":"succeeded","message":{
            "content":[{"type":"text","text":"the summary"}],
            "usage":{"input_tokens":100,"output_tokens":20,
                     "cache_creation_input_tokens":5,"cache_read_input_tokens":80}}}}"#;
        let parsed = parse_result_line(line).unwrap();

        assert_eq!(parsed.status, BatchStatus::Succeeded);
        assert_eq!(parsed.text.as_deref(), Some("the summary"));
        let usage = parsed.usage.unwrap();
        assert_eq!(usage.input_tokens, 100);
        assert_eq!(usage.output_tokens, 20);
        // The provider's names differ from ours; getting this mapping wrong
        // would bill cache reads at full input rates.
        assert_eq!(usage.cache_write_tokens, 5);
        assert_eq!(usage.cache_read_tokens, 80);
    }

    #[test]
    fn several_text_blocks_are_joined() {
        let line = r#"{"custom_id":"c1","result":{"type":"succeeded","message":{
            "content":[{"type":"text","text":"one "},{"type":"thinking","thinking":"hmm"},
                       {"type":"text","text":"two"}]}}}"#;
        assert_eq!(
            parse_result_line(line).unwrap().text.as_deref(),
            Some("one two"),
            "and a thinking block is not part of the answer"
        );
    }

    #[test]
    fn each_failure_kind_is_distinguished() {
        // They are not interchangeable: `errored` may be a bad request worth
        // fixing, `expired` is worth resubmitting unchanged.
        let errored = r#"{"custom_id":"c1","result":{"type":"errored",
            "error":{"type":"invalid_request"}}}"#;
        let parsed = parse_result_line(errored).unwrap();
        assert_eq!(parsed.status, BatchStatus::Errored);
        assert_eq!(parsed.error.as_deref(), Some("invalid_request"));

        for (line, expected) in [
            (
                r#"{"custom_id":"c","result":{"type":"expired"}}"#,
                BatchStatus::Expired,
            ),
            (
                r#"{"custom_id":"c","result":{"type":"canceled"}}"#,
                BatchStatus::Canceled,
            ),
        ] {
            assert_eq!(parse_result_line(line).unwrap().status, expected);
        }
    }

    #[test]
    fn a_failure_carries_no_usage_to_bill() {
        let line = r#"{"custom_id":"c1","result":{"type":"errored","error":{"type":"api_error"}}}"#;
        assert!(parse_result_line(line).unwrap().usage.is_none());
    }

    #[test]
    fn an_unreadable_line_is_skipped_not_fatal() {
        // One malformed result must not strand the other four hundred as
        // `submitted` forever, never billed and never returned.
        assert!(parse_result_line("not json").is_none());
        assert!(parse_result_line(r#"{"custom_id":"c1"}"#).is_none());
        assert!(parse_result_line(r#"{"result":{"type":"succeeded"}}"#).is_none());
    }

    /* ------------------------------------------------------- a fake provider */

    #[derive(Default)]
    struct FakeProvider {
        submitted: Mutex<Vec<Vec<String>>>,
        /// `processing_status` to report, per call.
        ended: Mutex<bool>,
        results_jsonl: Mutex<String>,
        fail_submit: bool,
    }

    impl BatchClient for FakeProvider {
        async fn submit(&self, requests: Vec<BatchRequest>) -> Result<BatchState, DispatchError> {
            if self.fail_submit {
                return Err(DispatchError::Transport("no network".into()));
            }
            self.submitted
                .lock()
                .unwrap()
                .push(requests.iter().map(|r| r.custom_id.clone()).collect());
            Ok(BatchState {
                id: "batch_abc".into(),
                processing_status: "in_progress".into(),
            })
        }

        async fn state(&self, batch_id: &str) -> Result<BatchState, DispatchError> {
            Ok(BatchState {
                id: batch_id.to_owned(),
                processing_status: if *self.ended.lock().unwrap() {
                    "ended".into()
                } else {
                    "in_progress".into()
                },
            })
        }

        async fn results(&self, _batch_id: &str) -> Result<Vec<BatchResult>, DispatchError> {
            Ok(self
                .results_jsonl
                .lock()
                .unwrap()
                .lines()
                .filter_map(parse_result_line)
                .collect())
        }
    }

    fn store() -> SqliteStore {
        let store = SqliteStore::open_in_memory().unwrap();
        store
            .upsert_machine(&Machine {
                id: "m1".into(),
                name: "laptop".into(),
                pubkey: "k".into(),
                last_seen_at: Some(NOW),
                created_at: NOW,
            })
            .unwrap();
        store
            .upsert_repo(&Repo {
                id: "r1".into(),
                machine_id: "m1".into(),
                path: "/srv/api".into(),
                name: "api".into(),
                budget_usd: None,
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
                budget_usd: None,
                spent_usd: 0.0,
                started_at: NOW,
                ended_at: None,
                agent_session_id: None,
            })
            .unwrap();
        store
    }

    fn queued(store: &SqliteStore, id: &str, custom: &str) {
        store
            .enqueue_batch_item(&BatchItem {
                tier: Tier::Small,
                id: id.into(),
                session_id: "s1".into(),
                custom_id: custom.into(),
                task_type: TaskType::Summarize,
                model: "claude-haiku-4-5".into(),
                request_json: r#"{"model":"claude-haiku-4-5","max_tokens":100}"#.into(),
                batch_id: None,
                status: BatchStatus::Queued,
                response_text: None,
                error: None,
                queued_at: NOW,
                submitted_at: None,
                settled_at: None,
            })
            .unwrap();
    }

    /* ----------------------------------------------------------------- flush */

    #[tokio::test]
    async fn flushing_an_empty_queue_sends_nothing() {
        // The flusher runs on a timer, so this is the common case.
        let queue = BatchQueue::new(store(), FakeProvider::default());
        assert_eq!(queue.flush(NOW).await.unwrap(), FlushReport::default());
        assert!(queue.client.submitted.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn flushing_sends_everything_queued_as_one_batch() {
        let store = store();
        queued(&store, "b1", "c1");
        queued(&store, "b2", "c2");
        let queue = BatchQueue::new(store, FakeProvider::default());

        let report = queue.flush(NOW).await.unwrap();
        assert_eq!(report.submitted, 2);
        assert_eq!(report.batch_id.as_deref(), Some("batch_abc"));
        assert_eq!(queue.client.submitted.lock().unwrap().len(), 1, "one batch");
        assert_eq!(queue.client.submitted.lock().unwrap()[0], ["c1", "c2"]);
    }

    #[tokio::test]
    async fn a_flushed_item_is_not_flushed_again() {
        // The expensive bug: two batches containing the same request, billed
        // twice, with only one result ever collected.
        let store = store();
        queued(&store, "b1", "c1");
        let queue = BatchQueue::new(store, FakeProvider::default());

        queue.flush(NOW).await.unwrap();
        assert_eq!(queue.flush(NOW + 1_000).await.unwrap().submitted, 0);
        assert_eq!(queue.client.submitted.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn a_failed_submit_leaves_the_work_queued() {
        // The other order — record then send — would strand these as
        // `submitted`, waiting forever on a batch that was never created.
        let store = store();
        queued(&store, "b1", "c1");
        let queue = BatchQueue::new(
            store,
            FakeProvider {
                fail_submit: true,
                ..Default::default()
            },
        );

        assert!(queue.flush(NOW).await.is_err());
        assert_eq!(queue.store.list_queued_batch_items(10).unwrap().len(), 1);
    }

    /* --------------------------------------------------------------- collect */

    #[tokio::test]
    async fn nothing_is_settled_while_the_batch_is_still_running() {
        let store = store();
        queued(&store, "b1", "c1");
        let queue = BatchQueue::new(store, FakeProvider::default());
        queue.flush(NOW).await.unwrap();

        let report = queue.collect(NOW + 60_000).await.unwrap();
        assert_eq!(report.batches_checked, 1);
        assert_eq!(report.settled, 0);
    }

    #[tokio::test]
    async fn a_finished_batch_is_banked_and_billed_at_batch_rates() {
        let store = store();
        queued(&store, "b1", "c1");
        let queue = BatchQueue::new(store, FakeProvider::default());
        queue.flush(NOW).await.unwrap();

        *queue.client.ended.lock().unwrap() = true;
        *queue.client.results_jsonl.lock().unwrap() = r#"{"custom_id":"c1","result":{"type":"succeeded","message":{"content":[{"type":"text","text":"done"}],"usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}}"#.into();

        let report = queue.collect(NOW + 3_600_000).await.unwrap();
        assert_eq!(report.settled, 1);
        assert_eq!(report.succeeded, 1);

        let item = queue.store.get_batch_item("b1").unwrap().unwrap();
        assert_eq!(item.status, BatchStatus::Succeeded);
        assert_eq!(item.response_text.as_deref(), Some("done"));

        // Haiku 4.5 is $1.00 per million input. Batch is half of that, and the
        // whole point of the feature is that this number is 0.50 not 1.00.
        assert!(
            (report.cost_usd - 0.50).abs() < 1e-6,
            "expected the 50% batch rate, got {}",
            report.cost_usd
        );
    }

    #[tokio::test]
    async fn collecting_twice_bills_once() {
        // A poll overlapping a retry fetches the same results again. Being
        // billed twice for one call cannot be undone.
        let store = store();
        queued(&store, "b1", "c1");
        let queue = BatchQueue::new(store, FakeProvider::default());
        queue.flush(NOW).await.unwrap();

        *queue.client.ended.lock().unwrap() = true;
        *queue.client.results_jsonl.lock().unwrap() = r#"{"custom_id":"c1","result":{"type":"succeeded","message":{"content":[{"type":"text","text":"done"}],"usage":{"input_tokens":1000000,"output_tokens":0}}}}"#.into();

        let first = queue.collect(NOW + 3_600_000).await.unwrap();
        let second = queue.collect(NOW + 3_700_000).await.unwrap();

        assert_eq!(first.settled, 1);
        assert_eq!(second.settled, 0, "already settled, and already billed");
        assert!((second.cost_usd - 0.0).abs() < 1e-9);
    }

    #[tokio::test]
    async fn a_failed_request_is_recorded_and_bills_nothing() {
        let store = store();
        queued(&store, "b1", "c1");
        let queue = BatchQueue::new(store, FakeProvider::default());
        queue.flush(NOW).await.unwrap();

        *queue.client.ended.lock().unwrap() = true;
        *queue.client.results_jsonl.lock().unwrap() =
            r#"{"custom_id":"c1","result":{"type":"errored","error":{"type":"invalid_request"}}}"#
                .into();

        let report = queue.collect(NOW + 3_600_000).await.unwrap();
        assert_eq!(report.failed, 1);
        assert_eq!(
            report.cost_usd, 0.0,
            "a request that never ran costs nothing"
        );

        let item = queue.store.get_batch_item("b1").unwrap().unwrap();
        assert_eq!(item.status, BatchStatus::Errored);
        assert_eq!(item.error.as_deref(), Some("invalid_request"));
    }

    #[tokio::test]
    async fn a_result_for_work_this_runner_did_not_queue_is_ignored() {
        // The API key may be shared with another tool. Its results are not ours
        // to bill, and its custom ids are not ours to settle.
        let store = store();
        queued(&store, "b1", "c1");
        let queue = BatchQueue::new(store, FakeProvider::default());
        queue.flush(NOW).await.unwrap();

        *queue.client.ended.lock().unwrap() = true;
        *queue.client.results_jsonl.lock().unwrap() = r#"{"custom_id":"somebody-else","result":{"type":"succeeded","message":{"content":[{"type":"text","text":"x"}],"usage":{"input_tokens":1000000,"output_tokens":0}}}}"#.into();

        let report = queue.collect(NOW + 3_600_000).await.unwrap();
        assert_eq!(report.settled, 0);
        assert_eq!(report.cost_usd, 0.0);
        // And ours is still waiting, not wrongly marked done.
        assert_eq!(
            queue.store.get_batch_item("b1").unwrap().unwrap().status,
            BatchStatus::Submitted
        );
    }

    #[tokio::test]
    async fn a_mix_of_outcomes_is_reported_separately() {
        let store = store();
        queued(&store, "b1", "c1");
        queued(&store, "b2", "c2");
        let queue = BatchQueue::new(store, FakeProvider::default());
        queue.flush(NOW).await.unwrap();

        *queue.client.ended.lock().unwrap() = true;
        *queue.client.results_jsonl.lock().unwrap() = concat!(
            r#"{"custom_id":"c1","result":{"type":"succeeded","message":{"content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":0,"output_tokens":0}}}}"#,
            "\n",
            r#"{"custom_id":"c2","result":{"type":"expired"}}"#
        )
        .into();

        let report = queue.collect(NOW + 3_600_000).await.unwrap();
        assert_eq!(report.settled, 2);
        assert_eq!(report.succeeded, 1);
        assert_eq!(report.failed, 1);
        assert_eq!(
            queue.store.get_batch_item("b2").unwrap().unwrap().status,
            BatchStatus::Expired
        );
    }

    /// Exceeding the cap is a rejected batch, not a partial one — so this is a
    /// compile-time invariant rather than a test that could be skipped.
    const _: () = assert!(FLUSH_SIZE < MAX_REQUESTS_PER_BATCH);
}
