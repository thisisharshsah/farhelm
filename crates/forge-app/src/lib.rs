//! What RelayForge *does*, and what it needs from the world to do it.
//!
//! Two things live here: the [`store`] ports, and the use cases written against
//! them. A use case is a piece of behaviour that outlives any particular way of
//! reaching it — the cost [`ledger`] is billed identically whether a call
//! arrived over loopback HTTP, over the relay, or from the runner's own agent
//! loop, and none of those transports appear in this crate.
//!
//! ```text
//!   forge-proto   shapes, no rules            (leaf: serde only)
//!        ▲
//!   forge-domain  rules, no I/O               (cannot read a clock)
//!        ▲
//!   forge-app     use cases + ports           ← you are here
//!        ▲
//!   forge-sqlite  one implementation of the ports
//! ```
//!
//! # Ports are roles, not one interface
//!
//! [`store`] declares nine traits rather than one, partitioned by what asks the
//! question. That is what lets the gateway say it needs budgets, the cache and
//! the batch queue — and lets a reader believe it, because the bound would stop
//! compiling if it reached further. `Store` survives as an empty supertrait for
//! the one caller that genuinely touches everything.
//!
//! # What is deliberately *not* a port
//!
//! There is no `Clock` and no `Ids` trait, and that is a decision rather than an
//! omission.
//!
//! The interesting layers already take time as an argument: [`ledger::Ledger`]
//! has `record_at`, the response cache takes `now_ms` on every call, the batch
//! queue takes it on `flush` and `collect`, `forge_domain::price` prices at a
//! timestamp, and pairing codes are redeemed against one. Time is already
//! threaded explicitly through everything whose behaviour depends on it, which
//! is the property a `Clock` port exists to buy.
//!
//! What remains are calls to [`time::now_ms`] at the edges — HTTP handlers, the
//! daemon's own loops, the CLI — which is exactly where reading a clock is
//! legitimate. Injecting a port there would add a type parameter to every
//! handler in exchange for determinism the tests already have. So [`time`] and
//! [`id`] stay concrete, and are the two places in this crate that touch
//! ambient state.

pub mod id;
pub mod ledger;
pub mod store;
pub mod time;

pub use ledger::{Call, Ledger, LedgerError, Summary};
pub use store::{
    ApprovalStore, BatchStore, DecisionOutcome, DeviceStore, FleetStore, LedgerStore, PlanStore,
    ResponseCache, SessionStore, Store, StoreError, TaskOutcome, TaskStore, TimeRange,
};
