//! RelayForge's rules.
//!
//! What a call costs, what counts as destructive, what a plan is allowed to do
//! next, and what each agent can honestly be supervised through. Everything here
//! is a pure function of its arguments.
//!
//! # No clock, no filesystem, no network, no async
//!
//! That is enforced by what this crate depends on: `forge-proto` for the shapes,
//! `sha2` and `toml` for two pure transforms, and nothing else. There is no
//! `tokio`, no `rusqlite`, no `reqwest`, and no way to read the time.
//!
//! It is not an aesthetic rule. These are the parts of the system whose
//! behaviour is worth being certain about — a misclassified `rm -rf`, a price
//! table that bills the wrong rate, a plan that skips a step it should have run
//! — and certainty comes from being able to test them exhaustively without
//! arranging a world first. `forge-core` claimed this property in its own doc
//! header ("no async runtime and no network I/O by design — the part of the
//! system that is cheap to test") while depending directly on `rusqlite`.
//!
//! Where a rule needs the outside world, the *outside world* is the parameter:
//! [`price::quote`] takes a timestamp rather than reading a clock, and
//! [`risk::Policy`] parses text rather than opening a file. Whoever has the
//! clock or the file passes what it found.
//!
//! # Rules over shapes it does not own
//!
//! The types live in `forge-proto`, because four client implementations agree on
//! them. Rust will not let an inherent method be added to a type from another
//! crate, so rules over those shapes are extension traits — [`BudgetRules`],
//! [`ApprovalRules`]. That is a feature rather than a workaround: the import
//! makes it visible at each call site that a *policy* is being consulted, not a
//! field being read.

pub mod agent;
pub mod budget;
pub mod plan;
pub mod price;
pub mod risk;

pub use budget::{ApprovalRules, BudgetRules, budget_view};
pub use plan::{ParsedPlan, PlanProgress};
pub use price::{CacheTtl, ModelPrice, Quote, QuoteContext, quote};
