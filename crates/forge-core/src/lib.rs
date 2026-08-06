//! RelayForge core: domain types, the price table, and the storage boundary.
//!
//! Everything the runner, the cost gateway, and the relay agree on lives here.
//! The crate has no async runtime and no network I/O by design — it is the part
//! of the system that is cheap to test.

pub mod agent;
pub mod id;
pub mod ledger;
pub mod plan;
pub mod price;
pub mod risk;
pub mod store;
pub mod time;

/// The wire contract, re-exported.
///
/// These types moved to `forge-proto` — they are what four separate client
/// implementations agree on, and they had no business living behind a crate
/// that also opens SQLite connections. This re-export keeps the old paths
/// working while the callers are migrated; it goes away when they are.
pub mod types {
    pub use forge_proto::types::*;
}

pub use plan::{ParsedPlan, PlanProgress};
pub use price::{CacheTtl, ModelPrice, Quote, QuoteContext, quote};
pub use store::{DecisionOutcome, SqliteStore, Store, StoreError, TimeRange};
pub use types::{
    Agent, Approval, Avoided, BatchItem, BatchStatus, Budget, DecidedVia, Decision, Machine, Plan,
    PlanStep, PlanStepStatus, Repo, Risk, Session, SessionStatus, TaskType, Tier, Usage,
    UsageEvent,
};
