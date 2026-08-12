//! Milestone 3's exit criterion, minus the cellular network.
//!
//! > approve a real agent action from a phone, laptop lid closed, runner on VPS
//!
//! A real relay, a real runner-side link, and a simulated phone that holds its
//! own keypair. The phone never touches the runner's HTTP API — everything goes
//! through the relay as ciphertext, which is the whole point.

use forge_sqlite::SqliteStore;
use std::sync::Arc;
use std::time::Duration;

use forge_app::store::prelude::*;
use forge_crypto::{Envelope, Identity};
use forge_proto::types::{
    Agent, Approval, Decision, Device, DeviceKind, Machine, Repo, Risk, Session, SessionStatus,
};
use futures_util::{SinkExt as _, StreamExt as _};
use tokio_tungstenite::tungstenite::Message;

const NOW: i64 = 1_785_369_600_000;
const CHANNEL: &str = "forge-test-channel";

/// Start a relay on an ephemeral port, in-process.
async fn start_relay() -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let router = forge_relay::router(forge_relay::RelayState::new());
    tokio::spawn(async move {
        let _ = axum::serve(listener, router).await;
    });

    for _ in 0..100 {
        if tokio::net::TcpStream::connect(addr).await.is_ok() {
            return format!("ws://{addr}");
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("relay did not start");
}

/// A store seeded with a session and one pending approval.
fn seeded_store(approval_risk: Risk) -> SqliteStore {
    let store = SqliteStore::open_in_memory().unwrap();
    store
        .upsert_machine(&Machine {
            id: "m1".into(),
            name: "hetzner-1".into(),
            pubkey: String::new(),
            last_seen_at: Some(NOW),
            created_at: NOW,
        })
        .unwrap();
    store
        .upsert_repo(&Repo {
            id: "r1".into(),
            machine_id: "m1".into(),
            path: "/srv/payments-api".into(),
            name: "payments-api".into(),
            budget_usd: None,
        })
        .unwrap();
    store
        .upsert_session(&Session {
            id: "s1".into(),
            repo_id: "r1".into(),
            agent: Agent::ClaudeCode,
            tmux_target: None,
            status: SessionStatus::AwaitingApproval,
            plan_id: None,
            budget_usd: None,
            spent_usd: 0.0,
            started_at: NOW,
            ended_at: None,
            agent_session_id: None,
        })
        .unwrap();
    store
        .create_approval(&Approval {
            id: "a1".into(),
            session_id: "s1".into(),
            tool: "Bash".into(),
            payload: "pytest tests/billing -x".into(),
            risk: approval_risk,
            decision: None,
            decided_via: None,
            requested_at: NOW,
            decided_at: None,
        })
        .unwrap();
    store
}

/// A phone: its own keypair, registered with the runner, talking only to the relay.
struct Phone {
    identity: Identity,
    device_id: String,
    socket: tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
}

impl Phone {
    async fn pair(relay_url: &str, store: &SqliteStore, kind: DeviceKind) -> Self {
        let identity = Identity::generate();
        let device_id = format!("device-{kind}");
        store
            .upsert_device(&Device {
                id: device_id.clone(),
                kind,
                pubkey: identity.public_key().to_string(),
                push_token: None,
                paired_at: NOW,
            })
            .unwrap();

        let (socket, _) =
            tokio_tungstenite::connect_async(format!("{relay_url}/v1/channel/{CHANNEL}"))
                .await
                .unwrap();

        Self {
            identity,
            device_id,
            socket,
        }
    }

    /// Seal a command to the runner and push it through the relay.
    async fn send(&mut self, runner_public: &forge_crypto::PublicKey, command: serde_json::Value) {
        let envelope = self
            .identity
            .seal_json(CHANNEL, &self.device_id, runner_public, &command)
            .unwrap();
        self.socket
            .send(Message::Text(
                serde_json::to_string(&envelope).unwrap().into(),
            ))
            .await
            .unwrap();
    }

    /// Wait for an envelope the runner sealed for this device.
    async fn next_event(&mut self, runner_public: &forge_crypto::PublicKey) -> serde_json::Value {
        loop {
            let message = tokio::time::timeout(Duration::from_secs(5), self.socket.next())
                .await
                .expect("timed out waiting for a runner event")
                .expect("relay closed")
                .expect("websocket error");

            let Message::Text(text) = message else {
                continue;
            };
            let envelope: Envelope = serde_json::from_str(&text).unwrap();
            // Envelopes for *other* devices are on the same channel and simply
            // do not open — which is the isolation working, not an error.
            if let Ok(value) = self.identity.open_json(runner_public, &envelope) {
                return value;
            }
        }
    }
}

/// Wait for a condition, or fail. Polling beats a fixed sleep for a test that
/// crosses a websocket and a database.
async fn eventually(mut check: impl FnMut() -> bool) -> bool {
    for _ in 0..100 {
        if check() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    false
}

#[tokio::test]
async fn a_phone_approves_through_the_relay_and_the_runner_records_it() {
    let relay_url = start_relay().await;
    let store = seeded_store(Risk::Medium);

    // The runner: its own identity, dialling out to the relay.
    let runner_identity = Arc::new(Identity::generate());
    let phone = Phone::pair(&relay_url, &store, DeviceKind::Phone).await;

    let state = forge_runner::test_support::state(store, Arc::clone(&runner_identity));
    forge_runner::relay::spawn(
        Arc::clone(&state),
        Arc::clone(&runner_identity),
        forge_runner::relay::RelayConfig {
            url: relay_url.clone(),
            channel: CHANNEL.into(),
            session: None,
        },
    );

    let mut phone = phone;
    // Give the runner's link time to connect before the phone speaks.
    tokio::time::sleep(Duration::from_millis(300)).await;

    // The phone approves — sealed, over the relay, never touching HTTP.
    phone
        .send(
            runner_identity.public_key(),
            serde_json::json!({ "type": "decide", "approval_id": "a1", "decision": "approved" }),
        )
        .await;

    let store = Arc::clone(&state.store);
    assert!(
        eventually(|| {
            store
                .get_approval("a1")
                .unwrap()
                .is_some_and(|approval| !approval.is_pending())
        })
        .await,
        "the approval was never decided"
    );

    let approval = state.store.get_approval("a1").unwrap().unwrap();
    assert_eq!(approval.decision, Some(Decision::Approved));
    assert_eq!(
        approval.decided_via,
        Some(forge_proto::types::DecidedVia::Phone),
        "the transport must attest which surface decided"
    );
}

#[tokio::test]
async fn a_watch_cannot_clear_a_destructive_command_over_the_relay_either() {
    let relay_url = start_relay().await;
    let store = seeded_store(Risk::Destructive);

    let runner_identity = Arc::new(Identity::generate());
    let mut watch = Phone::pair(&relay_url, &store, DeviceKind::Watch).await;

    let state = forge_runner::test_support::state(store, Arc::clone(&runner_identity));
    forge_runner::relay::spawn(
        Arc::clone(&state),
        Arc::clone(&runner_identity),
        forge_runner::relay::RelayConfig {
            url: relay_url.clone(),
            channel: CHANNEL.into(),
            session: None,
        },
    );
    tokio::time::sleep(Duration::from_millis(300)).await;

    watch
        .send(
            runner_identity.public_key(),
            serde_json::json!({ "type": "decide", "approval_id": "a1", "decision": "approved" }),
        )
        .await;

    // Give it every chance to (wrongly) succeed.
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(
        state
            .store
            .get_approval("a1")
            .unwrap()
            .unwrap()
            .is_pending(),
        "a watch cleared a destructive command over the relay — the D3 guard is \
         not shared between transports"
    );
}

#[tokio::test]
async fn a_runner_event_reaches_the_phone_encrypted() {
    let relay_url = start_relay().await;
    let store = seeded_store(Risk::Low);

    let runner_identity = Arc::new(Identity::generate());
    let mut phone = Phone::pair(&relay_url, &store, DeviceKind::Phone).await;

    let state = forge_runner::test_support::state(store, Arc::clone(&runner_identity));
    forge_runner::relay::spawn(
        Arc::clone(&state),
        Arc::clone(&runner_identity),
        forge_runner::relay::RelayConfig {
            url: relay_url.clone(),
            channel: CHANNEL.into(),
            session: None,
        },
    );
    tokio::time::sleep(Duration::from_millis(300)).await;

    // The agent produces output; the runner publishes it.
    state.push_output("s1", "FAILED test_retry_after_500", NOW);

    let event = phone.next_event(runner_identity.public_key()).await;
    assert_eq!(event["type"], "output_chunk");
    assert_eq!(event["text"], "FAILED test_retry_after_500");
}

#[tokio::test]
async fn an_unpaired_device_on_the_channel_is_ignored() {
    let relay_url = start_relay().await;
    let store = seeded_store(Risk::Low);

    let runner_identity = Arc::new(Identity::generate());
    // Connects to the channel but was never registered with the runner.
    let intruder = Identity::generate();
    let (mut socket, _) =
        tokio_tungstenite::connect_async(format!("{relay_url}/v1/channel/{CHANNEL}"))
            .await
            .unwrap();

    let state = forge_runner::test_support::state(store, Arc::clone(&runner_identity));
    forge_runner::relay::spawn(
        Arc::clone(&state),
        Arc::clone(&runner_identity),
        forge_runner::relay::RelayConfig {
            url: relay_url.clone(),
            channel: CHANNEL.into(),
            session: None,
        },
    );
    tokio::time::sleep(Duration::from_millis(300)).await;

    let envelope = intruder
        .seal_json(
            CHANNEL,
            "device-phone",
            runner_identity.public_key(),
            &serde_json::json!({ "type": "decide", "approval_id": "a1", "decision": "approved" }),
        )
        .unwrap();
    socket
        .send(Message::Text(
            serde_json::to_string(&envelope).unwrap().into(),
        ))
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(
        state
            .store
            .get_approval("a1")
            .unwrap()
            .unwrap()
            .is_pending(),
        "an unpaired device decided an approval"
    );
}
