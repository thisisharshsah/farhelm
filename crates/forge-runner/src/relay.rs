//! The runner's side of the relay link (M3).
//!
//! This is what turns a loopback-only daemon into something reachable from a
//! phone on cellular. It dials **outbound** to the relay and keeps the socket
//! open — the runner never listens on a public port, which is the §6 posture.
//!
//! Two directions, both encrypted end to end:
//!
//! - **Out:** every [`ServerEvent`] the runner publishes is sealed once per
//!   paired device and sent. The relay forwards ciphertext.
//! - **In:** envelopes arrive, are opened with the sending device's public key,
//!   and dispatched through [`crate::commands`] — the same path the localhost
//!   API uses, so the destructive-approval rule cannot be skipped by coming in
//!   this way.
//!
//! # Reconnection is the normal case
//!
//! A phone's relay connection drops constantly; the runner's shouldn't, but a
//! VPS reboot, a relay deploy, and a flaky uplink all end the socket. The link
//! reconnects with capped exponential backoff and simply resumes. Nothing is
//! buffered across a disconnect: clients re-fetch state from the runner on
//! reconnect anyway, and a queue of stale `output_chunk`s helps nobody.

use std::sync::Arc;
use std::time::Duration;

use forge_crypto::{Envelope, Identity};
use forge_proto::events::CommandRejected;
use futures_util::{SinkExt as _, StreamExt as _};
use tokio::sync::broadcast;
use tokio_tungstenite::tungstenite::Message;

use crate::commands::{self, Command};
use crate::state::{AppState, ServerEvent};
use forge_core::store::prelude::*;
use forge_core::types::DecidedVia;

/// First reconnect delay; doubles up to [`MAX_BACKOFF`].
const MIN_BACKOFF: Duration = Duration::from_secs(1);
const MAX_BACKOFF: Duration = Duration::from_secs(60);

/// How this runner identifies itself as a sender inside an envelope.
const RUNNER_SENDER_ID: &str = "runner";

/// Which events are worth waking a sleeping device for.
///
/// **This decision has to live here, not in the relay.** The relay only sees
/// ciphertext, so it cannot tell an approval request from a line of build
/// output — and a relay that pushed on every publish would buzz every phone on
/// the channel for as long as an agent kept printing. The runner knows what
/// happened, so the runner asks.
///
/// The bar is: would you want to be interrupted for this? An approval blocks the
/// agent until someone answers, and a budget alert is money leaving. A session
/// changing status or emitting output is something to find when you look.
///
/// A **task** is the strongest case of the three. An approval stalls one tool
/// call; a change set nobody has looked at stalls the whole task, and the work
/// is already paid for. But only when it is *waiting* — a task row changes state
/// several times on its way there, and buzzing on `running` then again on
/// `applied` would train people to ignore the one that mattered.
fn deserves_a_wake_up(event: &ServerEvent) -> bool {
    match event {
        ServerEvent::ApprovalRequest { .. } | ServerEvent::BudgetAlert { .. } => true,
        ServerEvent::TaskUpsert { status, .. } => {
            *status == forge_core::types::TaskStatus::AwaitingReview
        }
        _ => false,
    }
}

/// Ask the relay to wake this channel's push subscribers.
///
/// Best-effort and fire-and-forget: the relay may have no VAPID key, the device
/// may have no subscription, and neither is a reason to disturb the link. The
/// WebSocket has already carried the real event to anything connected.
async fn request_wake_up(config: &RelayConfig) {
    // One stored URL, two schemes: `ws(s)://` for the channel, `http(s)://` for
    // everything else.
    let base = config
        .url
        .trim_end_matches('/')
        .replacen("wss://", "https://", 1)
        .replacen("ws://", "http://", 1);

    let url = format!("{base}/v1/push/{}", config.channel);
    if let Err(err) = reqwest::Client::new()
        .post(&url)
        .timeout(Duration::from_secs(5))
        .send()
        .await
    {
        eprintln!("relay link: could not request a wake-up: {err}");
    }
}

pub struct RelayConfig {
    /// `ws://…` or `wss://…`, without a path.
    pub url: String,
    /// The fan-out group. Public — knowing it grants a seat, not a key.
    pub channel: String,
}

/// Dial the relay and keep the link up for the life of the process.
pub fn spawn(state: Arc<AppState>, identity: Arc<Identity>, config: RelayConfig) {
    tokio::spawn(async move {
        let mut backoff = MIN_BACKOFF;
        loop {
            match run_once(&state, &identity, &config).await {
                Ok(()) => {
                    // A clean close still means reconnecting, just without the
                    // penalty — the relay may simply have been redeployed.
                    backoff = MIN_BACKOFF;
                }
                Err(err) => {
                    eprintln!("relay link: {err}; retrying in {}s", backoff.as_secs());
                }
            }
            tokio::time::sleep(backoff).await;
            backoff = (backoff * 2).min(MAX_BACKOFF);
        }
    });
}

async fn run_once(
    state: &Arc<AppState>,
    identity: &Arc<Identity>,
    config: &RelayConfig,
) -> Result<(), String> {
    let url = format!(
        "{}/v1/channel/{}",
        config.url.trim_end_matches('/'),
        config.channel
    );

    let (socket, _) = tokio_tungstenite::connect_async(&url)
        .await
        .map_err(|err| format!("could not connect to {url}: {err}"))?;
    println!("relay link: connected to {url}");

    let (mut sink, mut stream) = socket.split();

    // Subscribe *before* announcing, so nothing published during setup is lost.
    let mut events = state.events.subscribe();

    loop {
        tokio::select! {
            outgoing = events.recv() => {
                match outgoing {
                    Ok(event) => {
                        for envelope in seal_for_devices(state, identity, config, &event) {
                            let Ok(text) = serde_json::to_string(&envelope) else { continue };
                            if sink.send(Message::Text(text.into())).await.is_err() {
                                return Ok(());
                            }
                        }
                        // Only after the envelope is on the wire: a device woken
                        // before the thing it should read has been sent would
                        // connect, find nothing, and go back to sleep.
                        if deserves_a_wake_up(&event) {
                            request_wake_up(config).await;
                        }
                    }
                    // Falling behind means dropping events, not the link: the
                    // client re-fetches on its next poll regardless.
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => return Ok(()),
                }
            }

            incoming = stream.next() => {
                let Some(message) = incoming else { return Ok(()) };
                let Ok(message) = message else { return Ok(()) };

                match message {
                    Message::Text(text) => {
                        let Ok(envelope) = serde_json::from_str::<Envelope>(&text) else {
                            continue;
                        };
                        // A reply goes back to the asking device only — a
                        // snapshot nobody else requested is noise on their link.
                        if let Some(reply) = handle_envelope(state, identity, config, envelope).await
                            && let Ok(text) = serde_json::to_string(&reply)
                            && sink.send(Message::Text(text.into())).await.is_err()
                        {
                            return Ok(());
                        }
                    }
                    Message::Close(_) => return Ok(()),
                    _ => continue,
                }
            }
        }
    }
}

/// Seal one event once per paired device.
///
/// Per-device sealing is the cost of authenticated boxes: there is no single
/// ciphertext every device can read. At one runner and a handful of devices that
/// is a rounding error, and it buys per-device revocation — unpair a phone and
/// it stops receiving, with no key rotation.
fn seal_for_devices(
    state: &Arc<AppState>,
    identity: &Arc<Identity>,
    config: &RelayConfig,
    event: &ServerEvent,
) -> Vec<Envelope> {
    let Ok(devices) = state.store.list_devices() else {
        return Vec::new();
    };

    devices
        .iter()
        .filter_map(|device| {
            let recipient = forge_crypto::PublicKey::parse(&device.pubkey).ok()?;
            identity
                .seal_json(&config.channel, RUNNER_SENDER_ID, &recipient, event)
                .ok()
        })
        .collect()
}

/// Open an incoming envelope and run the command inside it.
///
/// Returns a sealed direct reply when the command produced one.
async fn handle_envelope(
    state: &Arc<AppState>,
    identity: &Arc<Identity>,
    config: &RelayConfig,
    envelope: Envelope,
) -> Option<Envelope> {
    // The envelope names its sender; that is a *hint*, not a credential. It
    // selects which public key to verify against, and verification is what
    // actually decides whether this is a paired device.
    let Ok(Some(device)) = state.store.get_device(&envelope.sender_id) else {
        return None;
    };
    let Ok(sender_key) = forge_crypto::PublicKey::parse(&device.pubkey) else {
        return None;
    };

    let command: Command = match identity.open_json(&sender_key, &envelope) {
        Ok(command) => command,
        Err(_) => {
            // Either a forgery or a device whose key rotated. Either way there
            // is nothing to do and nothing worth telling the sender — a decrypt
            // oracle is a real attack surface.
            eprintln!(
                "relay link: rejected an unverifiable envelope from {}",
                envelope.sender_id
            );
            return None;
        }
    };

    let via = match device.kind {
        forge_core::types::DeviceKind::Watch => DecidedVia::Watch,
        forge_core::types::DeviceKind::Phone => DecidedVia::Phone,
        forge_core::types::DeviceKind::Web => DecidedVia::Web,
    };

    match commands::execute(state, command, via).await {
        // A snapshot is a query, so its answer is addressed rather than
        // broadcast. Everything else changes state and reaches devices as the
        // events that change produces.
        Ok(commands::Outcome::Snapshot(fleet)) => identity
            .seal_json(&config.channel, RUNNER_SENDER_ID, &sender_key, &fleet)
            .ok(),
        Ok(commands::Outcome::SessionSnapshot(detail)) => identity
            .seal_json(&config.channel, RUNNER_SENDER_ID, &sender_key, &detail)
            .ok(),
        Ok(_) => None,
        // A refusal has to travel back. Over loopback the client sees an HTTP
        // status; here a rejected instruction would otherwise just evaporate,
        // and "I tapped it and nothing happened" is the worst failure a remote
        // control surface can have. The reply is addressed to the sender, so a
        // watch's refusal is not broadcast to every paired device.
        Err(err) => {
            eprintln!("relay link: command from {} failed: {err}", device.id);
            identity
                .seal_json(
                    &config.channel,
                    RUNNER_SENDER_ID,
                    &sender_key,
                    &CommandRejected::new(err.to_string()),
                )
                .ok()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use forge_core::store::SqliteStore;
    use forge_core::types::{
        Agent, Approval, Device, DeviceKind, Repo, Risk, Session, SessionStatus, TaskStatus,
    };

    const NOW: i64 = 1_785_369_600_000;

    fn fixture() -> (Arc<AppState>, Arc<Identity>, RelayConfig) {
        let state = AppState::with_gateway(SqliteStore::open_in_memory().unwrap(), |_| None);
        state
            .store
            .upsert_repo(&Repo {
                id: "r1".into(),
                machine_id: state.machine_id.clone(),
                path: "/srv/payments-api".into(),
                name: "payments-api".into(),
                budget_usd: None,
            })
            .unwrap();
        state
            .store
            .upsert_session(&Session {
                id: "s1".into(),
                repo_id: "r1".into(),
                agent: Agent::ClaudeCode,
                tmux_target: None,
                status: SessionStatus::Running,
                plan_id: None,
                budget_usd: None,
                spent_usd: 0.0,
                started_at: NOW,
                ended_at: None,
                agent_session_id: None,
            })
            .unwrap();

        let identity = Arc::new(Identity::generate());
        let config = RelayConfig {
            url: "ws://localhost:1".into(),
            channel: "chan".into(),
        };
        (state, identity, config)
    }

    fn approval(state: &Arc<AppState>, id: &str, risk: Risk) {
        state
            .store
            .create_approval(&Approval {
                id: id.into(),
                session_id: "s1".into(),
                tool: "Bash".into(),
                payload: "git push --force".into(),
                risk,
                decision: None,
                decided_via: None,
                requested_at: NOW,
                decided_at: None,
            })
            .unwrap();
    }

    fn pair(state: &Arc<AppState>, id: &str, kind: DeviceKind) -> Identity {
        let device_identity = Identity::generate();
        state
            .store
            .upsert_device(&Device {
                id: id.into(),
                kind,
                pubkey: device_identity.public_key().to_string(),
                push_token: None,
                paired_at: 0,
            })
            .unwrap();
        device_identity
    }

    #[test]
    fn an_event_is_sealed_once_per_paired_device() {
        let (state, identity, config) = fixture();
        let phone = pair(&state, "phone", DeviceKind::Phone);
        let watch = pair(&state, "watch", DeviceKind::Watch);

        let event = ServerEvent::SessionUpsert {
            session_id: "s1".into(),
        };
        let envelopes = seal_for_devices(&state, &identity, &config, &event);
        assert_eq!(envelopes.len(), 2);

        // Each device can open its own copy.
        let opened: Vec<ServerEvent> = envelopes
            .iter()
            .filter_map(|envelope| {
                phone
                    .open_json(identity.public_key(), envelope)
                    .or_else(|_| watch.open_json(identity.public_key(), envelope))
                    .ok()
            })
            .collect();
        assert_eq!(opened.len(), 2);
    }

    #[test]
    fn nothing_is_sealed_when_no_device_is_paired() {
        let (state, identity, config) = fixture();
        let event = ServerEvent::SessionUpsert {
            session_id: "s1".into(),
        };
        assert!(seal_for_devices(&state, &identity, &config, &event).is_empty());
    }

    #[test]
    fn a_device_with_a_corrupt_key_is_skipped_not_fatal() {
        let (state, identity, config) = fixture();
        pair(&state, "good", DeviceKind::Phone);
        state
            .store
            .upsert_device(&Device {
                id: "broken".into(),
                kind: DeviceKind::Phone,
                pubkey: "not-a-key".into(),
                push_token: None,
                paired_at: 0,
            })
            .unwrap();

        let event = ServerEvent::SessionUpsert {
            session_id: "s1".into(),
        };
        // One good device still gets its copy.
        assert_eq!(
            seal_for_devices(&state, &identity, &config, &event).len(),
            1
        );
    }

    #[tokio::test]
    async fn an_envelope_from_an_unpaired_sender_is_ignored() {
        let (state, identity, config) = fixture();
        let attacker = Identity::generate();

        let forged = attacker
            .seal_json(
                &config.channel,
                "phone",
                identity.public_key(),
                &Command::Decide {
                    approval_id: "a1".into(),
                    decision: forge_core::types::Decision::Approved,
                },
            )
            .unwrap();

        // No `phone` device exists, so there is no key to verify against.
        handle_envelope(&state, &identity, &config, forged).await;
        // Nothing happened; the absent approval was never touched.
        assert_eq!(state.store.get_approval("a1").unwrap(), None);
    }

    #[tokio::test]
    async fn an_envelope_a_paired_device_did_not_seal_is_rejected() {
        let (state, identity, config) = fixture();
        let _phone = pair(&state, "phone", DeviceKind::Phone);
        let attacker = Identity::generate();

        // The attacker claims to be the paired phone. The runner verifies
        // against the phone's real key, so it fails.
        let forged = attacker
            .seal_json(
                &config.channel,
                "phone",
                identity.public_key(),
                &Command::Instruct {
                    session_id: "s1".into(),
                    text: "do something".into(),
                },
            )
            .unwrap();

        handle_envelope(&state, &identity, &config, forged).await;
        assert!(state.output_tail("s1", 10).is_empty());
    }

    #[tokio::test]
    async fn a_snapshot_request_gets_an_addressed_reply() {
        let (state, identity, config) = fixture();
        let phone = pair(&state, "phone", DeviceKind::Phone);

        let request = phone
            .seal_json(
                &config.channel,
                "phone",
                identity.public_key(),
                &Command::Snapshot,
            )
            .unwrap();

        let reply = handle_envelope(&state, &identity, &config, request)
            .await
            .expect("a snapshot must be answered");

        // Sealed to the asking device, readable by it, and carrying a fleet.
        let fleet: serde_json::Value = phone.open_json(identity.public_key(), &reply).unwrap();
        assert!(fleet.get("sessions").is_some());
    }

    #[tokio::test]
    async fn a_state_changing_command_produces_no_direct_reply() {
        let (state, identity, config) = fixture();
        let phone = pair(&state, "phone", DeviceKind::Phone);
        approval(&state, "a1", forge_core::types::Risk::Low);

        let request = phone
            .seal_json(
                &config.channel,
                "phone",
                identity.public_key(),
                &Command::Decide {
                    approval_id: "a1".into(),
                    decision: forge_core::types::Decision::Approved,
                },
            )
            .unwrap();

        // It worked, so the client hears about it as the event the change
        // produced — not as a second, redundant answer on the same socket.
        assert!(
            handle_envelope(&state, &identity, &config, request)
                .await
                .is_none()
        );
        assert!(
            state
                .store
                .get_approval("a1")
                .unwrap()
                .is_some_and(|a| a.decision.is_some())
        );
    }

    #[tokio::test]
    async fn a_refusal_travels_back_to_the_device_that_asked() {
        let (state, identity, config) = fixture();
        let watch = pair(&state, "watch", DeviceKind::Watch);
        // Destructive, so D3 refuses it from a watch.
        approval(&state, "a1", forge_core::types::Risk::Destructive);

        let request = watch
            .seal_json(
                &config.channel,
                "watch",
                identity.public_key(),
                &Command::Decide {
                    approval_id: "a1".into(),
                    decision: forge_core::types::Decision::Approved,
                },
            )
            .unwrap();

        let reply = handle_envelope(&state, &identity, &config, request)
            .await
            .expect("a refusal must be reported, not swallowed");

        let error: serde_json::Value = watch.open_json(identity.public_key(), &reply).unwrap();
        assert_eq!(error["type"], "command_error");
        assert!(
            error["message"]
                .as_str()
                .is_some_and(|m| m.contains("phone")),
            "the message should say what to do instead: {error}"
        );
        // And the approval really is untouched.
        assert!(
            state
                .store
                .get_approval("a1")
                .unwrap()
                .is_some_and(|a| a.decision.is_none())
        );
    }

    #[tokio::test]
    async fn a_refusal_is_addressed_only_to_the_asker() {
        let (state, identity, config) = fixture();
        let watch = pair(&state, "watch", DeviceKind::Watch);
        let phone = pair(&state, "phone", DeviceKind::Phone);
        approval(&state, "a1", forge_core::types::Risk::Destructive);

        let request = watch
            .seal_json(
                &config.channel,
                "watch",
                identity.public_key(),
                &Command::Decide {
                    approval_id: "a1".into(),
                    decision: forge_core::types::Decision::Approved,
                },
            )
            .unwrap();

        let reply = handle_envelope(&state, &identity, &config, request)
            .await
            .unwrap();

        // The phone shares the channel and sees the ciphertext go past. It must
        // not be able to read another device's refusal.
        assert!(
            phone
                .open_json::<serde_json::Value>(identity.public_key(), &reply)
                .is_err()
        );
    }

    #[test]
    fn only_events_worth_interrupting_someone_for_ask_for_a_wake_up() {
        // The bar is "would you want your phone to buzz for this?". An approval
        // blocks the agent until somebody answers; a budget alert is money
        // leaving. Everything else is something to find when you look.
        assert!(deserves_a_wake_up(&ServerEvent::ApprovalRequest {
            approval: Approval {
                id: "a1".into(),
                session_id: "s1".into(),
                tool: "Bash".into(),
                payload: "x".into(),
                risk: Risk::Low,
                decision: None,
                decided_via: None,
                requested_at: NOW,
                decided_at: None,
            },
        }));
        assert!(deserves_a_wake_up(&ServerEvent::BudgetAlert {
            session_id: "s1".into(),
            pct: 0.8,
            hard_stop: false,
        }));
        // The strongest case of the three: an approval stalls one tool call, an
        // unreviewed change set stalls a whole task that is already paid for.
        assert!(deserves_a_wake_up(&task_event(TaskStatus::AwaitingReview)));
    }

    fn task_event(status: TaskStatus) -> ServerEvent {
        ServerEvent::TaskUpsert {
            task_id: "t1".into(),
            session_id: "s1".into(),
            status,
            summary: "3 files, +42 −17".into(),
        }
    }

    #[test]
    fn a_task_only_buzzes_when_it_is_actually_waiting_on_you() {
        // A task row changes state several times on its way to a review. Buzzing
        // on `running` and again on `applied` would train somebody to ignore the
        // one buzz that meant something.
        for quiet in [
            TaskStatus::Running,
            TaskStatus::Applied,
            TaskStatus::Rejected,
            TaskStatus::NoChanges,
            TaskStatus::Failed,
        ] {
            assert!(
                !deserves_a_wake_up(&task_event(quiet)),
                "{quiet} should not wake a phone"
            );
        }
    }

    #[test]
    fn a_chatty_agent_does_not_buzz_anyones_phone() {
        // This is the whole reason the decision lives in the runner rather than
        // the relay: an agent printing build output publishes constantly, and
        // the relay cannot tell those apart from an approval.
        assert!(!deserves_a_wake_up(&ServerEvent::OutputChunk {
            session_id: "s1".into(),
            line: crate::state::OutputLine {
                seq: 1,
                text: "compiling…".into(),
                at_ms: NOW,
            },
        }));
        assert!(!deserves_a_wake_up(&ServerEvent::SessionUpsert {
            session_id: "s1".into(),
        }));
        // You decided it; you know.
        assert!(!deserves_a_wake_up(&ServerEvent::ApprovalDecision {
            approval_id: "a1".into(),
            session_id: "s1".into(),
            decision: forge_core::types::Decision::Approved,
        }));
    }

    #[test]
    fn backoff_is_capped() {
        let mut backoff = MIN_BACKOFF;
        for _ in 0..20 {
            backoff = (backoff * 2).min(MAX_BACKOFF);
        }
        assert_eq!(backoff, MAX_BACKOFF);
    }
}
