//! RelayForge control plane.
//!
//! The piece the original design deliberately did not have. §1 of the design
//! document put "team/multi-tenant features" out of scope and built everything
//! around a single runner keypair: one machine, one channel, one implicit user.
//! That works right up to the first person who owns two laptops, and it has no
//! answer at all to "who is allowed to do this" or "what are they paying for".
//!
//! This crate adds exactly one thing: **an identity that is not a keypair**.
//! Accounts, organisations, roles and plans live here; the runner registry lives
//! here; and the short-lived tokens that get a device onto a relay channel are
//! minted here.
//!
//! # What it deliberately does *not* do
//!
//! It never sees a session, an approval, a diff, or a repository path. Devices
//! still generate their own keys and still seal everything to a runner's public
//! key, exactly as they did before — this service hands out *addresses and
//! permissions*, not content. Compromising it lets an attacker add a machine to
//! a fleet or read a billing address. It does not let them read a single line of
//! anyone's code, which is the property `forge-crypto` exists to protect and the
//! reason it was worth building auth this way rather than terminating the
//! encryption at a server.
//!
//! ```text
//!   forge-runner ──enrol/heartbeat──▶ forge-cloud ◀──sign in──── web / mobile
//!        │                          (accounts, plans,                 │
//!        │                           runner registry)                 │
//!        │                                 │                          │
//!        │                          channel tokens (15 min)           │
//!        │                                 ▼                          │
//!        └────────────── sealed envelopes ─────────────────────────────┘
//!                              forge-relay
//!                     (verifies tokens, reads nothing)
//! ```

pub mod api;
pub mod billing;
pub mod mcp;
pub mod model;
pub mod plan;
pub mod secret;
pub mod store;

use forge_crypto::token::TokenSigner;

use crate::billing::Billing;
use crate::store::CloudStore;

pub const DEFAULT_PORT: u16 = 7844;

/// Where this deployment lives. Everything a client needs to know that is not
/// in a token.
#[derive(Debug, Clone)]
pub struct CloudConfig {
    /// The relay devices should dial. Handed out in every workspace and
    /// heartbeat response, so no client ever hard-codes it and a relay move is
    /// a server-side change.
    pub relay_url: String,
    /// This deployment's own origin. Used to build Stripe return URLs, which is
    /// the one place the server has to know its own public name.
    pub public_url: String,
}

impl Default for CloudConfig {
    fn default() -> Self {
        Self {
            relay_url: "ws://127.0.0.1:7843".to_owned(),
            public_url: "http://127.0.0.1:7844".to_owned(),
        }
    }
}

pub struct CloudState {
    pub store: CloudStore,
    /// The only key in the system that can mint a token. Losing it signs
    /// everyone out; leaking it is total compromise of *access*, though still
    /// not of content.
    pub signer: TokenSigner,
    pub billing: Billing,
    pub config: CloudConfig,
}

/// Unix milliseconds.
///
/// The one impure function in this crate, kept in one place so every module
/// below takes `now_ms` as a parameter and stays testable.
pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_clock_is_plausibly_now() {
        // Catches the classic seconds/milliseconds mix-up, which would make
        // every token look expired or eternal.
        let now = now_ms();
        assert!(now > 1_700_000_000_000, "clock looks like seconds: {now}");
        assert!(now < 4_000_000_000_000, "clock is implausibly far ahead");
    }
}
