//! Wall-clock helpers. Every timestamp in the schema is unix milliseconds.

use std::time::{SystemTime, UNIX_EPOCH};

/// Milliseconds since the unix epoch.
///
/// Saturates at 0 if the system clock is set before 1970 — a nonsense clock
/// should not panic a long-running daemon.
pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| i64::try_from(elapsed.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn now_is_after_the_project_started() {
        // 2026-01-01T00:00:00Z
        assert!(now_ms() > 1_767_225_600_000);
    }

    #[test]
    fn now_is_monotonic_enough_for_ordering() {
        assert!(now_ms() <= now_ms());
    }
}
