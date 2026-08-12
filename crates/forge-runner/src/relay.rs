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
use forge_proto::commands::DeviceFrame;
use forge_proto::events::CommandRejected;
use forge_proto::hello::Hello;
use futures_util::{SinkExt as _, StreamExt as _};
use tokio::sync::broadcast;
use tokio_tungstenite::tungstenite::Message;

use crate::commands;
use crate::state::{AppState, ServerEvent};
use forge_app::store::prelude::*;
use forge_proto::types::DecidedVia;

/// First reconnect delay; doubles up to [`MAX_BACKOFF`].
const MIN_BACKOFF: Duration = Duration::from_secs(1);
const MAX_BACKOFF: Duration = Duration::from_secs(60);

/// How long to wait for the control plane's first channel token before dialling
/// anyway. Generously more than a heartbeat round trip, far less than a person
/// would notice.
const FIRST_TOKEN_WAIT: Duration = Duration::from_secs(10);

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
            *status == forge_proto::types::TaskStatus::AwaitingReview
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

    // The same token the socket used: a gated relay will not buzz a channel for
    // a caller who cannot prove they belong on it, or knowing a channel id
    // would be enough to ring somebody's phone every ten seconds forever.
    let url = format!("{base}/v1/push/{}{}", config.channel, config.token_query());
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
    /// The control-plane session, when this runner is enrolled.
    ///
    /// Read at *connect* time rather than captured once: the token lives fifteen
    /// minutes and the heartbeat replaces it every thirty seconds, so a link
    /// that reconnects after an hour must pick up the current one. `None` is an
    /// ungated relay, which is still a supported deployment.
    pub session: Option<crate::cloud::SharedSession>,
}

impl RelayConfig {
    /// The query string to append when dialling.
    ///
    /// A query parameter rather than a header because the browser `WebSocket`
    /// constructor takes a URL and nothing else, and the runner has to speak the
    /// same protocol the clients do.
    fn token_query(&self) -> String {
        match self.current_token() {
            Some(token) => format!("?token={token}"),
            None => String::new(),
        }
    }

    /// The channel token right now, or `None` on an ungated deployment or
    /// before the first heartbeat has landed.
    fn current_token(&self) -> Option<String> {
        let session = self.session.as_ref()?;
        let token = session
            .read()
            .map(|held| held.channel_token.clone())
            .unwrap_or_default();
        (!token.is_empty()).then_some(token)
    }

    /// Wait for the first channel token, up to a bound.
    ///
    /// Enrolment does not mint one — the first heartbeat does, a moment later.
    /// Without this the link dialled immediately, was refused 401, and recovered
    /// on its own a second later. Harmless, and still wrong to ship: an
    /// `Unauthorized` in the log on every single start is exactly the kind of
    /// noise that makes a real authorisation failure invisible.
    async fn await_first_token(&self) {
        if self.session.is_none() || self.current_token().is_some() {
            return;
        }
        let deadline = tokio::time::Instant::now() + FIRST_TOKEN_WAIT;
        while tokio::time::Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(100)).await;
            if self.current_token().is_some() {
                return;
            }
        }
        // Fall through and dial anyway. A relay that turns out to be ungated
        // will accept it, and being refused is more useful than a runner that
        // silently never connects because one heartbeat failed.
    }
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
    config.await_first_token().await;

    let base = format!(
        "{}/v1/channel/{}",
        config.url.trim_end_matches('/'),
        config.channel
    );
    let url = format!("{base}{}", config.token_query());

    let (socket, _) = tokio_tungstenite::connect_async(&url)
        .await
        // `base`, not `url`: the token is a credential and this string goes to
        // stderr, and from there to a journal somebody else can read.
        .map_err(|err| format!("could not connect to {base}: {err}"))?;
    println!("relay link: connected to {base}");

    let (mut sink, mut stream) = socket.split();

    // Subscribe *before* announcing, so nothing published during setup is lost.
    let mut events = state.events.subscribe();

    // What each device on this link said it can handle.
    //
    // Per-connection rather than per-device row, because that is what it
    // describes: a device that reconnects from an older build must not be
    // treated as still having the capabilities its previous connection
    // announced. A device absent from this map is assumed
    // `Capability::BASELINE` — which is every client shipped today, since none
    // of them send a `Hello` yet.
    //
    // Nothing reads this yet. See `forge_proto::hello` for why that is the
    // whole of step one.
    let mut capabilities: std::collections::HashMap<String, Hello> =
        std::collections::HashMap::new();

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
                        if let Some(reply) =
                            handle_envelope(state, identity, config, &mut capabilities, envelope).await
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
    capabilities: &mut std::collections::HashMap<String, Hello>,
    envelope: Envelope,
) -> Option<Envelope> {
    // The envelope names its sender; that is a *hint*, not a credential. It
    // selects which public key to verify against, and verification is what
    // actually decides whether this is a paired device.
    // A sender this runner has never heard of is usually not an intruder — it is
    // a device that signed in seconds ago, and the heartbeat that would tell us
    // about it is up to thirty seconds away. Ask the control plane now rather
    // than dropping the request and letting the user watch a spinner fail.
    let mut known = state.store.get_device(&envelope.sender_id);
    if matches!(known, Ok(None))
        && let Some(session) = &config.session
        && crate::cloud::refresh_devices(session, state.store.as_ref()).await
    {
        known = state.store.get_device(&envelope.sender_id);
    }

    let device = match known {
        Ok(Some(device)) => device,
        Ok(None) => {
            // Silence used to be the whole of this branch, and it made an
            // entire class of failure undiagnosable: the device sends, the
            // runner drops, nothing is written down anywhere, and the only
            // symptom is a client saying "the runner did not answer" ten
            // seconds later while the runner looks perfectly healthy.
            //
            // Naming the sender is safe — it is an id the sender just told us,
            // not a secret — and it is the difference between "which device is
            // this" and reading two databases by hand.
            eprintln!(
                "relay link: ignoring a command from {}, which is not a device this runner \
                 knows about. It has: [{}]. If that device was registered recently, the next \
                 heartbeat picks it up.",
                envelope.sender_id,
                state
                    .store
                    .list_devices()
                    .map(|devices| devices
                        .iter()
                        .map(|device| device.id.clone())
                        .collect::<Vec<_>>()
                        .join(", "))
                    .unwrap_or_default()
            );
            return None;
        }
        Err(err) => {
            eprintln!(
                "relay link: could not look up {}: {err}",
                envelope.sender_id
            );
            return None;
        }
    };
    let Ok(sender_key) = forge_crypto::PublicKey::parse(&device.pubkey) else {
        return None;
    };

    let frame: DeviceFrame = match identity.open_json(&sender_key, &envelope) {
        Ok(frame) => frame,
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

    let command = match frame {
        // Announcing what you can handle is not a command and produces no reply:
        // it changes what this runner will send *later*, once anything gates on
        // it. Recorded and acknowledged by silence, which is also what an older
        // runner does with a frame it cannot parse — so a client may start
        // sending one before every runner understands it.
        DeviceFrame::Hello(hello) => {
            if !hello
                .protocol
                .is_compatible_with(forge_proto::PROTOCOL_VERSION)
            {
                eprintln!(
                    "relay link: {} speaks protocol {} and this runner speaks {}; \
                     talking anyway, on the shapes both versions share",
                    device.id,
                    hello.protocol,
                    forge_proto::PROTOCOL_VERSION
                );
            }
            capabilities.insert(device.id.clone(), hello);
            return None;
        }
        DeviceFrame::Command(command) => command,
    };

    let via = match device.kind {
        forge_proto::types::DeviceKind::Watch => DecidedVia::Watch,
        forge_proto::types::DeviceKind::Phone => DecidedVia::Phone,
        forge_proto::types::DeviceKind::Web => DecidedVia::Web,
    };

    // A query's answer is *addressed* to the device that asked, rather than
    // broadcast — nobody else asked for it.
    //
    // Every outcome the caller `await`s has to appear here. It used to be two
    // of them, with `Ok(_) => None` swallowing the rest, so the cost dashboard,
    // the task list and a task's diff each sent a request over the relay and
    // waited ten seconds for a reply that was never sent. The symptom is a
    // screen that says the runner cannot be reached while the runner is
    // connected and perfectly healthy — which is exactly what it looked like.
    //
    // The `Ok(_)` arm is gone deliberately: with it, adding a command and
    // forgetting its reply compiles and fails at runtime. Now it does not
    // compile.
    match commands::execute(state, command, via).await {
        Ok(commands::Outcome::Snapshot(fleet)) => identity
            .seal_json(&config.channel, RUNNER_SENDER_ID, &sender_key, &fleet)
            .ok(),
        Ok(commands::Outcome::SessionSnapshot(detail)) => identity
            .seal_json(&config.channel, RUNNER_SENDER_ID, &sender_key, &detail)
            .ok(),
        Ok(commands::Outcome::DashboardSnapshot(dashboard)) => identity
            .seal_json(&config.channel, RUNNER_SENDER_ID, &sender_key, &dashboard)
            .ok(),
        Ok(commands::Outcome::TaskSnapshot(task)) => identity
            .seal_json(&config.channel, RUNNER_SENDER_ID, &sender_key, &task)
            .ok(),
        Ok(commands::Outcome::TaskList { tasks }) => identity
            .seal_json(
                &config.channel,
                RUNNER_SENDER_ID,
                &sender_key,
                &serde_json::json!({ "tasks": tasks }),
            )
            .ok(),
        Ok(commands::Outcome::SessionChanged(session)) => identity
            .seal_json(&config.channel, RUNNER_SENDER_ID, &sender_key, &session)
            .ok(),
        Ok(commands::Outcome::TaskStarted(task)) => identity
            .seal_json(&config.channel, RUNNER_SENDER_ID, &sender_key, &task)
            .ok(),
        Ok(commands::Outcome::AgentList { agents }) => identity
            .seal_json(
                &config.channel,
                RUNNER_SENDER_ID,
                &sender_key,
                &serde_json::json!({ "agents": agents }),
            )
            .ok(),
        // These three change state, and the change reaches every device as the
        // event it produced. The sender is not waiting on a reply.
        Ok(commands::Outcome::Decided { .. })
        | Ok(commands::Outcome::Instructed { .. })
        | Ok(commands::Outcome::PlanChanged { .. })
        | Ok(commands::Outcome::TaskReviewed { .. }) => None,
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
    use std::collections::HashMap;

    use crate::commands::Command;
    use forge_proto::types::{
        Agent, Approval, Device, DeviceKind, Repo, Risk, Session, SessionStatus, TaskStatus,
    };
    use forge_sqlite::SqliteStore;

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
            session: None,
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
                    decision: forge_proto::types::Decision::Approved,
                },
            )
            .unwrap();

        // No `phone` device exists, so there is no key to verify against.
        handle_envelope(&state, &identity, &config, &mut HashMap::new(), forged).await;
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

        handle_envelope(&state, &identity, &config, &mut HashMap::new(), forged).await;
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

        let reply = handle_envelope(&state, &identity, &config, &mut HashMap::new(), request)
            .await
            .expect("a snapshot must be answered");

        // Sealed to the asking device, readable by it, and carrying a fleet.
        let fleet: serde_json::Value = phone.open_json(identity.public_key(), &reply).unwrap();
        assert!(fleet.get("sessions").is_some());
    }

    /// Every command a client *waits* on must produce an addressed reply.
    ///
    /// This is the regression that made a healthy runner look unreachable: the
    /// reply arm handled `Snapshot` and `SessionSnapshot` and swallowed the rest
    /// under `Ok(_) => None`, so the dashboard, the task list and a task's diff
    /// each waited ten seconds for an answer nobody sent. Enumerated here rather
    /// than asserted one-by-one, so a new query command fails this test until it
    /// is answered.
    #[tokio::test]
    async fn every_query_command_is_answered() {
        let (state, identity, config) = fixture();
        let phone = pair(&state, "phone", DeviceKind::Phone);

        let queries = vec![
            ("snapshot", Command::Snapshot, "sessions"),
            (
                "session_snapshot",
                Command::SessionSnapshot {
                    session_id: "s1".into(),
                },
                "steps",
            ),
            (
                "dashboard_snapshot",
                Command::DashboardSnapshot {
                    session_id: "s1".into(),
                    since_ms: None,
                },
                "by_tier",
            ),
            ("task_list", Command::TaskList, "tasks"),
            ("agent_list", Command::AgentList, "agents"),
        ];

        for (name, command, expected_field) in queries {
            let request = phone
                .seal_json(&config.channel, "phone", identity.public_key(), &command)
                .unwrap();

            let reply = handle_envelope(&state, &identity, &config, &mut HashMap::new(), request)
                .await
                .unwrap_or_else(|| panic!("{name} was never answered"));

            let body: serde_json::Value = phone.open_json(identity.public_key(), &reply).unwrap();
            assert!(
                body.get(expected_field).is_some(),
                "{name} answered without {expected_field}: {body}"
            );
        }
    }

    #[tokio::test]
    async fn a_state_changing_command_produces_no_direct_reply() {
        let (state, identity, config) = fixture();
        let phone = pair(&state, "phone", DeviceKind::Phone);
        approval(&state, "a1", forge_proto::types::Risk::Low);

        let request = phone
            .seal_json(
                &config.channel,
                "phone",
                identity.public_key(),
                &Command::Decide {
                    approval_id: "a1".into(),
                    decision: forge_proto::types::Decision::Approved,
                },
            )
            .unwrap();

        // It worked, so the client hears about it as the event the change
        // produced — not as a second, redundant answer on the same socket.
        assert!(
            handle_envelope(&state, &identity, &config, &mut HashMap::new(), request)
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
        approval(&state, "a1", forge_proto::types::Risk::Destructive);

        let request = watch
            .seal_json(
                &config.channel,
                "watch",
                identity.public_key(),
                &Command::Decide {
                    approval_id: "a1".into(),
                    decision: forge_proto::types::Decision::Approved,
                },
            )
            .unwrap();

        let reply = handle_envelope(&state, &identity, &config, &mut HashMap::new(), request)
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
        approval(&state, "a1", forge_proto::types::Risk::Destructive);

        let request = watch
            .seal_json(
                &config.channel,
                "watch",
                identity.public_key(),
                &Command::Decide {
                    approval_id: "a1".into(),
                    decision: forge_proto::types::Decision::Approved,
                },
            )
            .unwrap();

        let reply = handle_envelope(&state, &identity, &config, &mut HashMap::new(), request)
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

    /* --------------------------------------------- capability handshake */

    #[tokio::test]
    async fn a_hello_is_recorded_rather_than_executed() {
        let (state, identity, config) = fixture();
        let phone = pair(&state, "phone", DeviceKind::Phone);
        let mut capabilities = HashMap::new();

        let sealed = phone
            .seal_json(
                &config.channel,
                "phone",
                identity.public_key(),
                &Hello::current(&[forge_proto::Capability::TASK_REVIEW]),
            )
            .unwrap();

        // No reply: announcing what you can handle is not a request.
        assert!(
            handle_envelope(&state, &identity, &config, &mut capabilities, sealed)
                .await
                .is_none()
        );

        let announced = capabilities.get("phone").expect("the hello was recorded");
        assert!(announced.supports(forge_proto::Capability::TASK_REVIEW));
        assert!(!announced.supports(forge_proto::Capability::DASHBOARD));
    }

    #[tokio::test]
    async fn a_command_still_arrives_as_a_command() {
        // The frame is untagged, so a Command must not be mistaken for a Hello
        // with everything missing. This is the test that would fail if the
        // variant order or the shapes ever made them ambiguous.
        let (state, identity, config) = fixture();
        let phone = pair(&state, "phone", DeviceKind::Phone);
        approval(&state, "a1", Risk::Low);
        let mut capabilities = HashMap::new();

        let sealed = phone
            .seal_json(
                &config.channel,
                "phone",
                identity.public_key(),
                &Command::Decide {
                    approval_id: "a1".into(),
                    decision: forge_proto::types::Decision::Approved,
                },
            )
            .unwrap();

        handle_envelope(&state, &identity, &config, &mut capabilities, sealed).await;

        assert!(
            state
                .store
                .get_approval("a1")
                .unwrap()
                .is_some_and(|a| a.decision.is_some()),
            "the command ran"
        );
        assert!(
            capabilities.is_empty(),
            "a command must not be recorded as a capability announcement"
        );
    }

    #[tokio::test]
    async fn a_device_that_sends_no_hello_is_left_at_the_baseline() {
        // Every client shipped today. Nothing announces capabilities yet, so the
        // absence of an entry has to mean "baseline", not "unknown".
        let (state, identity, config) = fixture();
        let phone = pair(&state, "phone", DeviceKind::Phone);
        let mut capabilities = HashMap::new();

        let sealed = phone
            .seal_json(
                &config.channel,
                "phone",
                identity.public_key(),
                &Command::Snapshot,
            )
            .unwrap();
        handle_envelope(&state, &identity, &config, &mut capabilities, sealed).await;

        let assumed = capabilities.get("phone").cloned().unwrap_or_default();
        for baseline in forge_proto::Capability::BASELINE {
            assert!(assumed.supports(baseline));
        }
        assert!(!assumed.supports(forge_proto::Capability::TASK_REVIEW));
    }

    /// An unpaired sender's hello is dropped with everything else it sends.
    #[tokio::test]
    async fn a_hello_from_a_stranger_is_not_recorded() {
        let (state, identity, config) = fixture();
        let attacker = Identity::generate();
        let mut capabilities = HashMap::new();

        let forged = attacker
            .seal_json(
                &config.channel,
                "phone",
                identity.public_key(),
                &Hello::current(&[forge_proto::Capability::TASK_REVIEW]),
            )
            .unwrap();

        handle_envelope(&state, &identity, &config, &mut capabilities, forged).await;
        assert!(
            capabilities.is_empty(),
            "capabilities must be attributable to a paired device"
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
            decision: forge_proto::types::Decision::Approved,
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
