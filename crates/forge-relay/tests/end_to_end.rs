//! The §6 security claim, as a test.
//!
//! > a compromised relay learns session *existence*, not content
//!
//! This drives a real relay over a real WebSocket and checks both halves: that
//! the runner and phone can talk, and that everything the relay could possibly
//! have logged is unreadable to it.

use std::net::SocketAddr;

use forge_crypto::{Envelope, Identity};
use futures_util::{SinkExt as _, StreamExt as _};
use serde::{Deserialize, Serialize};
use tokio_tungstenite::tungstenite::Message;

/// The kind of payload that actually crosses the relay.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct ApprovalRequest {
    approval_id: String,
    tool: String,
    payload: String,
    risk: String,
}

/// Serve the real router on an ephemeral port, in this process.
///
/// Using `forge_relay::router` rather than spawning the binary means the test
/// exercises exactly what ships, and leaves no process behind when it ends.
async fn start_relay() -> SocketAddr {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let router = forge_relay::router(forge_relay::RelayState::new());

    tokio::spawn(async move {
        let _ = axum::serve(listener, router).await;
    });

    // Wait for the listener to answer rather than sleeping a fixed amount.
    for _ in 0..100 {
        if tokio::net::TcpStream::connect(addr).await.is_ok() {
            return addr;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    panic!("relay did not come up on {addr}");
}

type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect(addr: SocketAddr, channel: &str) -> Socket {
    let (socket, _) = tokio_tungstenite::connect_async(format!("ws://{addr}/v1/channel/{channel}"))
        .await
        .expect("relay should accept the connection");
    socket
}

async fn send(socket: &mut Socket, envelope: &Envelope) {
    socket
        .send(Message::Text(
            serde_json::to_string(envelope).unwrap().into(),
        ))
        .await
        .unwrap();
}

async fn recv(socket: &mut Socket) -> Envelope {
    loop {
        let message = tokio::time::timeout(std::time::Duration::from_secs(5), socket.next())
            .await
            .expect("timed out waiting for an envelope")
            .expect("socket closed")
            .expect("websocket error");

        if let Message::Text(text) = message {
            return serde_json::from_str(&text).expect("relay forwarded a non-envelope");
        }
    }
}

#[tokio::test]
async fn an_approval_round_trips_through_the_relay_without_it_reading_anything() {
    let addr = start_relay().await;

    // Pairing has already happened: each side knows the other's public key.
    let runner = Identity::generate();
    let phone = Identity::generate();
    let channel = "runner-hetzner-1";

    let mut runner_socket = connect(addr, channel).await;
    let mut phone_socket = connect(addr, channel).await;

    // The runner asks for approval of something recognisably sensitive.
    let request = ApprovalRequest {
        approval_id: "a-42".into(),
        tool: "Bash".into(),
        payload: "git push --force origin main".into(),
        risk: "destructive".into(),
    };
    let sealed = runner
        .seal_json(channel, "runner", phone.public_key(), &request)
        .unwrap();
    send(&mut runner_socket, &sealed).await;

    // The phone receives it and can read it.
    let received = recv(&mut phone_socket).await;
    let decoded: ApprovalRequest = phone.open_json(runner.public_key(), &received).unwrap();
    assert_eq!(decoded, request);

    // Everything the relay handled, as text it could have logged or stored.
    let relay_view = serde_json::to_string(&received).unwrap();
    for secret in ["git push", "--force", "origin main", "destructive", "a-42"] {
        assert!(
            !relay_view.contains(secret),
            "the relay could read {secret:?} from {relay_view}"
        );
    }

    // The phone answers, sealed with *its* key, and the runner can read it.
    let reply = phone
        .seal_json(channel, "phone", runner.public_key(), &"denied")
        .unwrap();
    send(&mut phone_socket, &reply).await;

    let back = recv(&mut runner_socket).await;
    let decision: String = runner.open_json(phone.public_key(), &back).unwrap();
    assert_eq!(decision, "denied");
}

#[tokio::test]
async fn a_relay_operator_replaying_an_envelope_cannot_forge_a_decision() {
    let addr = start_relay().await;

    let runner = Identity::generate();
    let phone = Identity::generate();
    let attacker = Identity::generate();
    let channel = "runner-hetzner-2";

    let mut runner_socket = connect(addr, channel).await;
    let mut attacker_socket = connect(addr, channel).await;

    // The attacker controls the relay, so it can join any channel and send
    // anything. It knows the runner's public key — that travels in the QR.
    let forged = attacker
        .seal_json(channel, "phone", runner.public_key(), &"approved")
        .unwrap();
    send(&mut attacker_socket, &forged).await;

    let received = recv(&mut runner_socket).await;

    // It arrives — the relay will carry anything. It does not authenticate:
    // the runner verifies against the *paired phone's* key and the forgery fails.
    assert!(
        runner
            .open_json::<String>(phone.public_key(), &received)
            .is_err(),
        "a forged decision was accepted"
    );
}

#[tokio::test]
async fn a_connection_cannot_publish_into_a_channel_it_did_not_join() {
    let addr = start_relay().await;

    let runner = Identity::generate();
    let phone = Identity::generate();

    let mut victim = connect(addr, "victim-channel").await;
    let mut outsider = connect(addr, "outsider-channel").await;

    // The envelope claims a channel the sender never joined.
    let mut cross_posted = runner
        .seal(
            "victim-channel",
            "runner",
            phone.public_key(),
            b"should not arrive",
        )
        .unwrap();
    cross_posted.channel = "victim-channel".into();
    send(&mut outsider, &cross_posted).await;

    // Nothing reaches the victim's channel.
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(300), victim.next())
            .await
            .is_err(),
        "an envelope crossed into a channel its sender had not joined"
    );
}

#[tokio::test]
async fn the_relay_keeps_nothing_after_everyone_leaves() {
    let addr = start_relay().await;
    let runner = Identity::generate();
    let phone = Identity::generate();

    {
        let mut a = connect(addr, "ephemeral").await;
        let mut b = connect(addr, "ephemeral").await;
        let envelope = runner
            .seal("ephemeral", "runner", phone.public_key(), b"transient")
            .unwrap();
        send(&mut a, &envelope).await;
        recv(&mut b).await;
    }

    // Both connections dropped. Give the relay a moment to notice, then confirm
    // it is holding no channels — there is no history for anyone to demand.
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    let health: serde_json::Value = reqwest_get(addr, "/v1/health").await;
    assert_eq!(health["channels"], 0, "the relay retained a channel");
}

/// Minimal GET, so the relay's dev-dependencies stay to a websocket client.
async fn reqwest_get(addr: SocketAddr, path: &str) -> serde_json::Value {
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

    let mut stream = tokio::net::TcpStream::connect(addr).await.unwrap();
    stream
        .write_all(
            format!("GET {path} HTTP/1.1\r\nHost: {addr}\r\nConnection: close\r\n\r\n").as_bytes(),
        )
        .await
        .unwrap();

    let mut response = String::new();
    stream.read_to_string(&mut response).await.unwrap();
    let body = response.split("\r\n\r\n").nth(1).unwrap_or("{}");
    serde_json::from_str(body.trim()).unwrap_or(serde_json::json!({}))
}
