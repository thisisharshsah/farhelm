//! Fixtures for integration tests.
//!
//! Public because Rust integration tests are external crates and cannot reach
//! `#[cfg(test)]` code. Nothing here is used by the daemon.

use std::sync::Arc;

use forge_core::store::SqliteStore;
use forge_crypto::Identity;

use crate::state::AppState;

/// Build runner state around a prepared store and identity: no model provider,
/// no relay info, no tmux. The caller wires whatever it is actually testing.
pub fn state(store: SqliteStore, identity: Arc<Identity>) -> Arc<AppState> {
    AppState::build(store, |_| None, identity, None)
}
