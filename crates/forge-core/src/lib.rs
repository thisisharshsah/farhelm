//! RelayForge storage: the `Store` port, its SQLite implementation, and the
//! cost ledger written through it.
//!
//! # What this crate is now, and what it was
//!
//! It used to be called the domain crate and claimed, in this header, to have
//! "no async runtime and no network I/O by design — the part of the system that
//! is cheap to test". That was not true: it depended directly on `rusqlite`,
//! opened files, and read the clock. It had become the place things went when
//! more than one crate needed them.
//!
//! What is genuinely shared now lives where it can be depended on cheaply — the
//! wire contract in `forge-proto`, the rules in `forge-domain`, neither of which
//! can perform I/O. What is left here is the part that always was I/O, plus two
//! ambient capabilities ([`id`], [`time`]) that are next to become ports.
//!
//! The `agent`, `plan`, `price`, `risk` and `types` modules below are
//! re-exports, kept so callers can migrate a file at a time rather than in one
//! commit. They are not the definitions.

pub mod id;
pub mod ledger;
pub mod store;
pub mod time;

/// The rules, re-exported.
///
/// Pricing, risk classification, the plan state machine and the agent table
/// moved to `forge-domain`, which depends on nothing but `forge-proto` and so
/// cannot read a clock, open a file, or await. These re-exports keep the old
/// paths working while the callers are migrated; they go when the callers do.
pub mod agent {
    pub use forge_domain::agent::*;
}
pub mod plan {
    pub use forge_domain::plan::*;
}
pub mod price {
    pub use forge_domain::price::*;
}
pub mod risk {
    pub use forge_domain::risk::*;
}

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
pub use store::{DecisionOutcome, SqliteStore, StoreError, TimeRange, prelude::*};
pub use types::{
    Agent, Approval, Avoided, BatchItem, BatchStatus, Budget, DecidedVia, Decision, Machine, Plan,
    PlanStep, PlanStepStatus, Repo, Risk, Session, SessionStatus, TaskType, Tier, Usage,
    UsageEvent,
};
