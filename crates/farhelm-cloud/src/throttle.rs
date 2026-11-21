//! Limits on what a caller without an account can make the control plane do.
//!
//! Two things are bounded (security review, H3). Guesses at a password: past
//! a number of failed sign-ins for one account, or from one address, more are
//! refused for a while, a correct one included, or the limit would not stop
//! guessing. And the Argon2 work each sign-in or sign-up costs (19 MiB and
//! tens of milliseconds): only a few run at once, off the async workers, so a
//! burst of them waits its turn instead of stalling heartbeats and tokens.

use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::{Arc, Mutex, PoisonError};

use tokio::sync::{OwnedSemaphorePermit, Semaphore};

/// So many attempts within a window.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limit {
    pub attempts: u32,
    pub window_ms: i64,
}

/// Failed sign-ins for one account.
pub const ACCOUNT_FAILURES: Limit = Limit {
    attempts: 10,
    window_ms: 15 * 60 * 1_000,
};

/// Failed sign-ins from one address. Higher than an account's, since a
/// campus or an office can share an address.
pub const ADDRESS_FAILURES: Limit = Limit {
    attempts: 100,
    window_ms: 15 * 60 * 1_000,
};

/// Sign-ups from one address.
pub const ADDRESS_SIGNUPS: Limit = Limit {
    attempts: 20,
    window_ms: 60 * 60 * 1_000,
};

/// How many Argon2 checks run at once: each holds 19 MiB.
const HASHING_AT_ONCE: usize = 4;

/// Past this many keys, windows that have ended are swept out.
const SWEEP_AT: usize = 10_000;

#[derive(Debug, Clone, Copy)]
struct Window {
    started_at: i64,
    attempts: u32,
    window_ms: i64,
}

pub struct Throttle {
    windows: Mutex<HashMap<String, Window>>,
    hashing: Arc<Semaphore>,
}

impl Default for Throttle {
    fn default() -> Self {
        Self {
            windows: Mutex::new(HashMap::new()),
            hashing: Arc::new(Semaphore::new(HASHING_AT_ONCE)),
        }
    }
}

impl Throttle {
    /// `Ok` when every key is under its limit; otherwise how many
    /// milliseconds until all of them are again.
    pub fn check(&self, keys: &[(String, Limit)], now_ms: i64) -> Result<(), i64> {
        let windows = self.windows.lock().unwrap_or_else(PoisonError::into_inner);
        let wait = keys
            .iter()
            .filter_map(|(key, limit)| {
                let window = windows.get(key)?;
                let age = now_ms - window.started_at;
                (age < limit.window_ms && window.attempts >= limit.attempts)
                    .then_some(limit.window_ms - age)
            })
            .max();
        match wait {
            Some(wait) => Err(wait),
            None => Ok(()),
        }
    }

    /// Counts one attempt against every key.
    pub fn count(&self, keys: &[(String, Limit)], now_ms: i64) {
        let mut windows = self.windows.lock().unwrap_or_else(PoisonError::into_inner);
        if windows.len() >= SWEEP_AT {
            windows.retain(|_, window| now_ms - window.started_at < window.window_ms);
        }
        for (key, limit) in keys {
            let fresh = Window {
                started_at: now_ms,
                attempts: 0,
                window_ms: limit.window_ms,
            };
            let window = windows.entry(key.clone()).or_insert(fresh);
            if now_ms - window.started_at >= limit.window_ms {
                *window = fresh;
            }
            window.attempts = window.attempts.saturating_add(1);
        }
    }

    /// Forgets a key: an account's failures, once its sign-in succeeds.
    pub fn clear(&self, key: &str) {
        self.windows
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(key);
    }

    /// A turn at Argon2 work. Move it into the blocking task that does the
    /// work, so it is held until that work ends even if the caller has gone.
    pub async fn hashing(&self) -> OwnedSemaphorePermit {
        Arc::clone(&self.hashing)
            .acquire_owned()
            .await
            .expect("the hashing semaphore is never closed")
    }
}

/// The key for an account's failed sign-ins, by its normalized email.
pub fn account_key(normalized_email: &str) -> String {
    format!("account:{normalized_email}")
}

/// The key for an address: the address itself, or its /64 for IPv6, since
/// one machine there can choose among many addresses.
pub fn address_key(kind: &str, address: IpAddr) -> String {
    match address {
        IpAddr::V4(v4) => format!("{kind}:{v4}"),
        IpAddr::V6(v6) => {
            let s = v6.segments();
            format!("{kind}:{:x}:{:x}:{:x}:{:x}::/64", s[0], s[1], s[2], s[3])
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIMIT: Limit = Limit {
        attempts: 3,
        window_ms: 1_000,
    };

    #[test]
    fn a_key_is_refused_at_its_limit_until_the_window_ends() {
        let throttle = Throttle::default();
        let keys = [("account:a@example.com".to_owned(), LIMIT)];
        for at in 0..3 {
            assert_eq!(throttle.check(&keys, at), Ok(()));
            throttle.count(&keys, at);
        }
        assert_eq!(throttle.check(&keys, 10), Err(990));
        assert_eq!(throttle.check(&keys, 1_000), Ok(()));
        throttle.count(&keys, 1_000);
        assert_eq!(throttle.check(&keys, 1_001), Ok(()));
    }

    #[test]
    fn clearing_a_key_forgets_its_failures() {
        let throttle = Throttle::default();
        let keys = [("account:a@example.com".to_owned(), LIMIT)];
        for at in 0..3 {
            throttle.count(&keys, at);
        }
        throttle.clear("account:a@example.com");
        assert_eq!(throttle.check(&keys, 5), Ok(()));
    }

    #[test]
    fn ipv6_addresses_share_their_64() {
        let one: IpAddr = "2001:db8:1:2:aaaa::1".parse().unwrap();
        let two: IpAddr = "2001:db8:1:2:bbbb::9".parse().unwrap();
        assert_eq!(address_key("sign-in", one), address_key("sign-in", two));
        let v4: IpAddr = "203.0.113.9".parse().unwrap();
        assert_eq!(address_key("sign-in", v4), "sign-in:203.0.113.9");
    }
}
