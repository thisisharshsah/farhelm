//! Seat channels over a real WebSocket, on a relay gated by a control plane.
//!
//! What Companion relies on: its Mac and its iPhone app meet on a `c1-`
//! channel with nothing but the seat from their pairing, on a relay that turns
//! away everyone without a token, and someone who only knows the channel's
//! name gets a readable refusal rather than a seat.

use std::net::SocketAddr;

use farhelm_crypto::Envelope;
use farhelm_crypto::token::TokenSigner;
use farhelm_relay::auth::{SEAT_HEADER, seat_channel};
use futures_util::{SinkExt as _, StreamExt as _};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;

/// A seat as Companion makes one: 32 random bytes, base64url.
const SEAT: &str = "bZRSbJ7BIZBDW7LOkali4wTB-Ph68L9pVn3dyTs5QoE";

/// The real router, gated, on an ephemeral port in this process.
async fn start_gated_relay() -> SocketAddr {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let state = farhelm_relay::RelayState::gated(
        None,
        farhelm_relay::DEFAULT_PUSH_SUBJECT.to_owned(),
        TokenSigner::generate().verifier(),
    );
    let router = farhelm_relay::router(state);
    tokio::spawn(async move {
        let _ = axum::serve(listener, router).await;
    });
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

/// Opens `channel` with `seat` in its header, or the HTTP status it was refused with.
async fn join(addr: SocketAddr, channel: &str, seat: Option<&str>) -> Result<Socket, u16> {
    let mut request = format!("ws://{addr}/v1/channel/{channel}")
        .into_client_request()
        .unwrap();
    if let Some(seat) = seat {
        request
            .headers_mut()
            .insert(SEAT_HEADER, seat.parse().unwrap());
    }
    match tokio_tungstenite::connect_async(request).await {
        Ok((socket, _)) => Ok(socket),
        Err(tokio_tungstenite::tungstenite::Error::Http(response)) => {
            Err(response.status().as_u16())
        }
        Err(other) => panic!("unexpected failure: {other}"),
    }
}

fn envelope(channel: &str, sender: &str) -> Envelope {
    Envelope {
        channel: channel.to_owned(),
        sender_id: sender.to_owned(),
        nonce: "AAECAwQFBgcICQoL".to_owned(),
        ciphertext: "c2VhbGVkIGVsc2V3aGVyZQ".to_owned(),
    }
}

#[tokio::test]
async fn two_holders_of_a_seat_meet_on_a_gated_relay() {
    let addr = start_gated_relay().await;
    let channel = seat_channel(SEAT);

    let mut mac = join(addr, &channel, Some(SEAT))
        .await
        .expect("the Mac sits");
    let mut phone = join(addr, &channel, Some(SEAT))
        .await
        .expect("the phone sits");

    let sent = envelope(&channel, "phone-1");
    phone
        .send(Message::Text(serde_json::to_string(&sent).unwrap().into()))
        .await
        .unwrap();

    let received = loop {
        let message = tokio::time::timeout(std::time::Duration::from_secs(5), mac.next())
            .await
            .expect("timed out waiting for the envelope")
            .expect("socket closed")
            .expect("websocket error");
        if let Message::Text(text) = message {
            break serde_json::from_str::<Envelope>(&text).unwrap();
        }
    };
    assert_eq!(received.sender_id, "phone-1");
    assert_eq!(received.ciphertext, sent.ciphertext);
}

#[tokio::test]
async fn knowing_the_name_is_not_enough() {
    let addr = start_gated_relay().await;
    let channel = seat_channel(SEAT);

    assert_eq!(join(addr, &channel, None).await.err(), Some(401));
    let other = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    assert_eq!(join(addr, &channel, Some(other)).await.err(), Some(401));
}

#[tokio::test]
async fn a_seat_opens_only_its_own_channel() {
    let addr = start_gated_relay().await;
    let elsewhere = seat_channel("ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ");
    assert_eq!(join(addr, &elsewhere, Some(SEAT)).await.err(), Some(401));
    // Nor does it stand in for a token on the control plane's channels.
    assert_eq!(join(addr, "forge-abc", Some(SEAT)).await.err(), Some(401));
}
