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
pub mod types;

pub use plan::{ParsedPlan, PlanProgress};
pub use price::{CacheTtl, ModelPrice, Quote, QuoteContext, quote};
pub use store::{DecisionOutcome, SqliteStore, Store, StoreError, TimeRange};
pub use types::{
    Agent, Approval, Avoided, BatchItem, BatchStatus, Budget, DecidedVia, Decision, Machine, Plan,
    PlanStep, PlanStepStatus, Repo, Risk, Session, SessionStatus, TaskType, Tier, Usage,
    UsageEvent,
};
