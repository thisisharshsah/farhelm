//! Noticing that a machine has gone quiet, and saying so.
//!
//! The fleet has always *known* this — [`Runner::is_online`] is a subtraction on
//! `last_seen_at`, and the fleet view has rendered it since the beginning. What
//! it never did was tell anybody. You found out by opening the app and looking,
//! which means you found out when you already suspected, which is exactly when
//! a notification is worth least.
//!
//! That is not a hypothetical gap. This deployment sat unreachable for days
//! while the control plane held `last_seen_at` the whole time and no surface
//! anywhere volunteered it.
//!
//! # Why the control plane is the one that notices
//!
//! Absence cannot be detected by the thing that is absent, and the relay only
//! ever acts on an envelope arriving — an offline machine sends none, so
//! nothing there fires. The control plane is the only party that both knows a
//! machine has stopped reporting and can still reach a phone.
//!
//! # Why this does not weaken the encryption
//!
//! The wake-up carries no payload, exactly as every other one does. The control
//! plane asks the relay to buzz the devices watching a channel; a woken device
//! asks the *control plane* — which it is already authenticated to — what
//! changed, and learns from the fleet view that a machine is offline. No
//! session content is involved, because none is needed: "your machine stopped
//! answering" is a fact about the fleet, not about the work.

use std::collections::HashMap;

use crate::model::Runner;

/// Which machines have gone quiet since the last look.
///
/// Deliberately a pure state machine over observations, so the awkward parts —
/// not shouting on startup, not repeating, recovering — are arguable in a test
/// rather than in production at three in the morning.
#[derive(Debug, Default)]
pub struct FleetWatch {
    /// Runner id → was it online when we last looked.
    seen: HashMap<String, bool>,
    /// Whether we have ever looked.
    seeded: bool,
}

impl FleetWatch {
    pub fn new() -> Self {
        Self::default()
    }

    /// Take a look, and report the machines that have *just* gone offline.
    ///
    /// Three rules, each of which exists to stop a notification people would
    /// learn to ignore:
    ///
    /// **The first look never reports.** Restarting the control plane would
    /// otherwise announce every machine that has been switched off for a month,
    /// every time it restarts. The first pass records; it does not speak.
    ///
    /// **A transition reports once.** Offline is a state and going offline is
    /// an event, and only the event is worth a buzz. Repeating it every tick is
    /// how a phone gets muted.
    ///
    /// **Coming back re-arms it.** A machine that recovers and drops again is a
    /// second event and worth a second notice — that pattern is a flapping link
    /// or a laptop lid, and it is precisely what somebody needs to see.
    pub fn observe(&mut self, runners: &[Runner], now_ms: i64) -> Vec<Runner> {
        let mut went_quiet = Vec::new();

        for runner in runners {
            let online = runner.is_online(now_ms);
            let was_online = self.seen.insert(runner.id.clone(), online);

            if !self.seeded {
                continue;
            }
            // `Some(true)` and nothing else: a machine seen for the first time
            // *after* seeding is newly enrolled, and enrolling is not an event
            // worth waking anybody for even if its first heartbeat is late.
            if was_online == Some(true) && !online {
                went_quiet.push(runner.clone());
            }
        }

        // A runner deleted from the fleet stops being tracked, so this map does
        // not grow for the life of the process.
        let present: std::collections::HashSet<&str> =
            runners.iter().map(|runner| runner.id.as_str()).collect();
        self.seen.retain(|id, _| present.contains(id.as_str()));

        self.seeded = true;
        went_quiet
    }
}

/// How often the fleet is looked at.
///
/// Comfortably under [`Runner::OFFLINE_AFTER_MS`], so a machine is noticed
/// within about a heartbeat of actually crossing the line rather than up to a
/// full interval later.
pub const LOOK_EVERY: std::time::Duration = std::time::Duration::from_secs(30);

/// Watch the fleet and wake the devices of any machine that goes quiet.
///
/// The relay's push endpoint is gated exactly as its socket is, so this mints
/// the same short-lived channel token a runner would present. That is the whole
/// reason the control plane can do this and nothing else can: it holds the only
/// key that mints one.
pub fn spawn(state: std::sync::Arc<crate::CloudState>) {
    tokio::spawn(async move {
        let client = reqwest::Client::new();
        let mut watch = FleetWatch::new();

        loop {
            tokio::time::sleep(LOOK_EVERY).await;

            let now = crate::now_ms();
            // Every workspace, because a control plane serves more than one and
            // a machine going quiet matters to whoever owns it.
            let Ok(orgs) = state.store.orgs() else {
                continue;
            };
            let mut fleet = Vec::new();
            for org in &orgs {
                if let Ok(runners) = state.store.runners(&org.id) {
                    fleet.extend(runners);
                }
            }

            for runner in watch.observe(&fleet, now) {
                match wake(&state, &client, &runner).await {
                    Ok(woken) => println!(
                        "fleet: {} went offline; woke {woken} device(s)",
                        runner.name
                    ),
                    // Logged, never fatal. A push service being unreachable is
                    // not a reason to stop watching the fleet — and the next
                    // drop is still worth reporting.
                    Err(err) => eprintln!("fleet: {} went offline; {err}", runner.name),
                }
            }
        }
    });
}

/// Ask the relay to buzz the devices watching this machine's channel.
async fn wake(
    state: &crate::CloudState,
    client: &reqwest::Client,
    runner: &Runner,
) -> Result<u64, String> {
    use farhelm_crypto::token::{Audience, Claims, Role};

    let now = crate::now_ms();
    let token = state
        .signer
        .mint(&Claims {
            sub: runner.id.clone(),
            aud: Audience::Relay,
            org: runner.org_id.clone(),
            role: Role::Runner,
            chan: Some(runner.channel.clone()),
            plan: None,
            rate: None,
            iat: now,
            exp: now + farhelm_crypto::token::CHANNEL_TOKEN_TTL_MS,
        })
        .map_err(|err| err.to_string())?;

    // `relay_url` is the `wss://` address devices dial. The push endpoint is
    // the same host over HTTP, so the scheme is swapped rather than a second
    // URL being configured — one address to get wrong instead of two.
    let base = state
        .config
        .relay_url
        .replacen("wss://", "https://", 1)
        .replacen("ws://", "http://", 1);
    let url = format!(
        "{}/v1/push/{}?token={token}",
        base.trim_end_matches('/'),
        runner.channel
    );

    let response = client
        .post(&url)
        .timeout(std::time::Duration::from_secs(10))
        .send()
        .await
        .map_err(|err| format!("could not reach the relay: {err}"))?;

    if !response.status().is_success() {
        return Err(format!(
            "the relay refused the wake-up: {}",
            response.status()
        ));
    }
    let body: serde_json::Value = response.json().await.unwrap_or_default();
    Ok(body.get("woken").and_then(|n| n.as_u64()).unwrap_or(0))
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_000_000_000;

    fn runner(id: &str, last_seen: i64) -> Runner {
        Runner {
            id: id.into(),
            org_id: "org1".into(),
            name: format!("machine {id}"),
            public_key: "pk".into(),
            pending_public_key: None,
            channel: format!("forge-{id}"),
            created_at: 0,
            last_seen_at: last_seen,
            version: "0.1.0".into(),
        }
    }

    fn online(id: &str) -> Runner {
        runner(id, NOW)
    }

    fn offline(id: &str) -> Runner {
        runner(id, NOW - Runner::OFFLINE_AFTER_MS - 1)
    }

    #[test]
    fn the_first_look_never_reports() {
        // Otherwise restarting the control plane announces every machine that
        // has been switched off for a month, on every restart.
        let mut watch = FleetWatch::new();
        assert!(watch.observe(&[offline("a"), offline("b")], NOW).is_empty());
    }

    #[test]
    fn going_offline_reports_once() {
        let mut watch = FleetWatch::new();
        watch.observe(&[online("a")], NOW);

        let went = watch.observe(&[offline("a")], NOW);
        assert_eq!(went.len(), 1);
        assert_eq!(went[0].id, "a");

        assert!(
            watch.observe(&[offline("a")], NOW).is_empty(),
            "offline is a state; going offline is the event"
        );
    }

    #[test]
    fn coming_back_re_arms_the_notice() {
        // A flapping link or a laptop lid is exactly what somebody needs to
        // see, so recovery has to make the next drop reportable again.
        let mut watch = FleetWatch::new();
        watch.observe(&[online("a")], NOW);
        assert_eq!(watch.observe(&[offline("a")], NOW).len(), 1);
        watch.observe(&[online("a")], NOW);
        assert_eq!(watch.observe(&[offline("a")], NOW).len(), 1);
    }

    #[test]
    fn a_machine_first_seen_offline_is_not_an_event() {
        // Enrolled while the control plane was not looking, or enrolled and not
        // started yet. Nothing has *happened* to it.
        let mut watch = FleetWatch::new();
        watch.observe(&[online("a")], NOW);

        let went = watch.observe(&[online("a"), offline("new")], NOW);
        assert!(
            went.is_empty(),
            "a machine that has never been seen online has not gone offline"
        );
    }

    #[test]
    fn staying_online_is_never_an_event() {
        let mut watch = FleetWatch::new();
        watch.observe(&[online("a")], NOW);
        assert!(watch.observe(&[online("a")], NOW).is_empty());
    }

    #[test]
    fn several_machines_dropping_at_once_are_all_reported() {
        // A relay outage takes the whole fleet down together, which is the case
        // where reporting only the first would be most misleading.
        let mut watch = FleetWatch::new();
        watch.observe(&[online("a"), online("b"), online("c")], NOW);

        let went = watch.observe(&[offline("a"), offline("b"), online("c")], NOW);
        let mut ids: Vec<_> = went.iter().map(|runner| runner.id.as_str()).collect();
        ids.sort_unstable();
        assert_eq!(ids, vec!["a", "b"]);
    }

    #[test]
    fn a_forgotten_machine_stops_being_tracked() {
        // This map lives for the life of the process, so a fleet that churns
        // must not grow it without bound.
        let mut watch = FleetWatch::new();
        watch.observe(&[online("a"), online("b")], NOW);
        watch.observe(&[online("a")], NOW);
        assert_eq!(watch.seen.len(), 1);
        assert!(watch.seen.contains_key("a"));
    }

    #[test]
    fn a_deleted_machine_that_returns_is_treated_as_new() {
        // It was dropped from the map, so it seeds again rather than reporting
        // a transition from a state nobody is still holding.
        let mut watch = FleetWatch::new();
        watch.observe(&[online("a")], NOW);
        watch.observe(&[], NOW);
        assert!(watch.observe(&[offline("a")], NOW).is_empty());
    }
}
