//! RelayForge cost gateway.
//!
//! Every model-bound call in the system passes through [`Gateway::complete`].
//! That is the whole design: the gateway is not an optimisation bolted onto a
//! relay, it is the single place where cost policy can be enforced, because it
//! is the only path to a provider.
//!
//! The stages, and what each one is for:
//!
//! | Stage | Module | Saves by |
//! |---|---|---|
//! | 1 budget | [`pipeline`] | refusing to spend past a cap |
//! | 2 pre-gate | [`pregate`] | letting a compiler answer instead of a model |
//! | 3 response cache | [`cache`] | not asking a question twice |
//! | 4 router | [`router`] | not paying frontier rates for triage |
//! | 5 context | [`context`] | sending line ranges instead of whole files |
//! | 6 assembler | [`prompt`] | keeping the prompt prefix byte-stable so it caches |
//! | 7 dispatch | [`dispatch`] | (batch deferral, C6 — not built) |
//! | 8 ledger | `forge_core::ledger` | pricing once, at write time |
//!
//! Stages 2 and 3 are zero-cost exits; 4, 5 and 6 shrink what a call costs.
//! They are independent multipliers, which is why the combined effect is much
//! larger than any one of them.

pub mod batch;
pub mod cache;
pub mod compaction;
pub mod context;
pub mod dispatch;
pub mod pipeline;
pub mod pregate;
pub mod prompt;
pub mod router;

pub use dispatch::{
    AnthropicClient, Effort, ModelClient, ModelRequest, ModelResponse, StubClient, ToolCall,
};
pub use pipeline::{
    CompleteRequest, CompleteResponse, Gateway, GatewayConfig, GatewayError, Served, StageTrace,
};
pub use prompt::{StableContext, Turn};
pub use router::{Models, Route};
