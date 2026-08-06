//! WebPush delivery, against a push service that records what it was sent.
//!
//! `webpush.rs` checks the *bytes* against RFC 8291's worked example. This
//! checks the things a known-answer test cannot: that a real HTTP request goes
//! out with the headers push services require, that the VAPID token is scoped to
//! the endpoint it was sent to, that one dead device does not stop the others,
//! and that a 410 makes the relay forget rather than retry forever.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use axum::Router;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::routing::post;
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use forge_relay::push::{PushRegistry, Subscription};
use forge_relay::webpush::VapidKey;
use forge_relay::{RelayState, router};

/// One request a push service received.
#[derive(Debug, Clone)]
struct Received {
    path: String,
    authorization: String,
    content_encoding: String,
    ttl: String,
    urgency: String,
    body: Vec<u8>,
}

#[derive(Default)]
struct Recorder {
    received: Mutex<Vec<Received>>,
    /// Paths that answer 410 Gone, as a real service does for a dropped device.
    gone: Mutex<Vec<String>>,
}

/// A stand-in for FCM/APNs: records the request, or reports the device gone.
async fn push_endpoint(
    Path(id): Path<String>,
    State(recorder): State<Arc<Recorder>>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> StatusCode {
    let header = |name: &str| {
        headers
            .get(name)
            .and_then(|value| value.to_str().ok())
            .unwrap_or_default()
            .to_owned()
    };

    recorder.received.lock().unwrap().push(Received {
        path: id.clone(),
        authorization: header("authorization"),
        content_encoding: header("content-encoding"),
        ttl: header("ttl"),
        urgency: header("urgency"),
        body: body.to_vec(),
    });

    if recorder.gone.lock().unwrap().contains(&id) {
        return StatusCode::GONE;
    }
    StatusCode::CREATED
}

async fn spawn_push_service(recorder: Arc<Recorder>) -> SocketAddr {
    let app = Router::new()
        .route("/push/{id}", post(push_endpoint))
        .with_state(recorder);
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    addr
}

/// A device's subscription, with real P-256 material so encryption is exercised
/// rather than short-circuited.
fn device(endpoint: String) -> Subscription {
    use p256::elliptic_curve::sec1::ToEncodedPoint as _;

    let secret = p256::SecretKey::random(&mut rand_core::OsRng);
    let mut auth = [0u8; 16];
    rand_core::RngCore::fill_bytes(&mut rand_core::OsRng, &mut auth);

    Subscription {
        endpoint,
        p256dh: B64.encode(secret.public_key().to_encoded_point(false).as_bytes()),
        auth: B64.encode(auth),
    }
}

#[tokio::test]
async fn a_wake_up_reaches_the_push_service_in_the_shape_it_expects() {
    let recorder = Arc::new(Recorder::default());
    let addr = spawn_push_service(Arc::clone(&recorder)).await;

    let state = RelayState::with_push(
        Some(VapidKey::generate()),
        "mailto:ops@example.com".to_owned(),
    );
    state
        .push
        .subscribe("chan", device(format!("http://{addr}/push/device-one")));

    let woken = state.push.notify("chan", state.delivery().as_ref()).await;
    assert_eq!(woken, 1);

    let received = recorder.received.lock().unwrap().clone();
    assert_eq!(received.len(), 1);
    let request = &received[0];

    // The headers every push service requires. Getting any of these wrong is an
    // opaque 400 or 401 from a third party, which is the worst kind to debug.
    assert_eq!(
        request.path, "device-one",
        "reached the endpoint it was given"
    );
    assert_eq!(request.content_encoding, "aes128gcm");
    assert_eq!(request.urgency, "high");
    assert!(request.authorization.starts_with("vapid t="));
    assert!(request.authorization.contains(", k="));
    assert!(
        request.ttl.parse::<u32>().is_ok_and(|ttl| ttl > 0),
        "a TTL of 0 means \"deliver now or never\", which defeats waking a sleeping phone"
    );
}

#[tokio::test]
async fn the_body_is_a_well_formed_aes128gcm_record_carrying_nothing() {
    let recorder = Arc::new(Recorder::default());
    let addr = spawn_push_service(Arc::clone(&recorder)).await;

    let state = RelayState::with_push(Some(VapidKey::generate()), "mailto:a@b.c".to_owned());
    state
        .push
        .subscribe("chan", device(format!("http://{addr}/push/one")));
    state.push.notify("chan", state.delivery().as_ref()).await;

    let body = recorder.received.lock().unwrap()[0].body.clone();

    // RFC 8188 header: salt(16) ‖ rs(4) ‖ idlen(1) ‖ keyid ‖ ciphertext.
    assert_eq!(body.len(), 16 + 4 + 1 + 65 + 1 + 16);
    assert_eq!(body[20], 65, "key id length");
    assert_eq!(body[21], 0x04, "the key id is an uncompressed P-256 point");

    // Nothing legible crosses. The relay cannot read what triggered the push, so
    // there is nothing it could truthfully say even if it wanted to.
    let text = String::from_utf8_lossy(&body);
    for word in ["approval", "session", "chan", "push", "force"] {
        assert!(!text.contains(word), "the payload leaked {word:?}");
    }
}

#[tokio::test]
async fn the_vapid_token_is_scoped_to_the_service_it_was_sent_to() {
    let recorder = Arc::new(Recorder::default());
    let addr = spawn_push_service(Arc::clone(&recorder)).await;

    let state = RelayState::with_push(Some(VapidKey::generate()), "mailto:a@b.c".to_owned());
    state
        .push
        .subscribe("chan", device(format!("http://{addr}/push/device-one")));
    state.push.notify("chan", state.delivery().as_ref()).await;

    let authorization = recorder.received.lock().unwrap()[0].authorization.clone();
    let claims_b64 = authorization
        .strip_prefix("vapid t=")
        .unwrap()
        .split('.')
        .nth(1)
        .unwrap();
    let claims: serde_json::Value =
        serde_json::from_slice(&B64.decode(claims_b64).unwrap()).unwrap();

    assert_eq!(claims["aud"], format!("http://{addr}"));
    // The path names the device; a token that carried it would hand the push
    // service a signed statement about which device this is.
    assert!(!claims["aud"].as_str().unwrap().contains("device-one"));
}

#[tokio::test]
async fn a_device_that_is_gone_is_forgotten_and_the_others_still_get_woken() {
    let recorder = Arc::new(Recorder::default());
    recorder.gone.lock().unwrap().push("dead".to_owned());
    let addr = spawn_push_service(Arc::clone(&recorder)).await;

    let state = RelayState::with_push(Some(VapidKey::generate()), "mailto:a@b.c".to_owned());
    state
        .push
        .subscribe("chan", device(format!("http://{addr}/push/dead")));
    state
        .push
        .subscribe("chan", device(format!("http://{addr}/push/alive")));

    let woken = state.push.notify("chan", state.delivery().as_ref()).await;

    // The live device was reached even though the dead one was tried first.
    assert_eq!(woken, 1);
    let paths: Vec<String> = recorder
        .received
        .lock()
        .unwrap()
        .iter()
        .map(|r| r.path.clone())
        .collect();
    assert_eq!(paths, ["dead", "alive"]);
    // And the dead one will never be tried again.
    assert_eq!(state.push.subscriber_count("chan"), 1);
}

#[tokio::test]
async fn an_unreachable_push_service_does_not_take_the_relay_down() {
    // Port 1 on loopback refuses instantly. A push service being down is a
    // Tuesday; it must not become a relay outage.
    let state = RelayState::with_push(Some(VapidKey::generate()), "mailto:a@b.c".to_owned());
    state
        .push
        .subscribe("chan", device("http://127.0.0.1:1/push/x".to_owned()));

    assert_eq!(
        state.push.notify("chan", state.delivery().as_ref()).await,
        0
    );
    // Unreachable is not gone: the device may simply be behind a blip.
    assert_eq!(state.push.subscriber_count("chan"), 1);
}

#[tokio::test]
async fn the_trigger_endpoint_wakes_a_channel() {
    let recorder = Arc::new(Recorder::default());
    let addr = spawn_push_service(Arc::clone(&recorder)).await;

    let state = RelayState::with_push(Some(VapidKey::generate()), "mailto:a@b.c".to_owned());
    state
        .push
        .subscribe("chan", device(format!("http://{addr}/push/one")));

    let relay = spawn_relay(router(Arc::clone(&state))).await;
    let response = reqwest::Client::new()
        .post(format!("http://{relay}/v1/push/chan"))
        .send()
        .await
        .unwrap();

    assert!(response.status().is_success());
    assert_eq!(
        response.json::<serde_json::Value>().await.unwrap()["woken"],
        1
    );
    assert_eq!(recorder.received.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn the_vapid_public_key_is_advertised_so_a_browser_can_subscribe() {
    let key = VapidKey::generate();
    let expected = key.public_key_base64url();
    let state = RelayState::with_push(Some(key), "mailto:a@b.c".to_owned());

    let relay = spawn_relay(router(state)).await;
    let body: serde_json::Value = reqwest::get(format!("http://{relay}/v1/push/vapid"))
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    assert_eq!(body["publicKey"], expected);
    // 65 bytes uncompressed is the only form `pushManager.subscribe` accepts.
    assert_eq!(
        B64.decode(body["publicKey"].as_str().unwrap())
            .unwrap()
            .len(),
        65
    );
}

#[tokio::test]
async fn a_relay_without_push_says_so_rather_than_pretending() {
    let relay = spawn_relay(router(RelayState::new())).await;
    let response = reqwest::get(format!("http://{relay}/v1/push/vapid"))
        .await
        .unwrap();

    assert_eq!(response.status(), reqwest::StatusCode::SERVICE_UNAVAILABLE);
    let body: serde_json::Value = response.json().await.unwrap();
    assert!(
        body["error"].as_str().unwrap().contains("--vapid-key"),
        "the error should say how to fix it: {body}"
    );
}

#[tokio::test]
async fn a_burst_of_traffic_is_one_push_not_twenty() {
    let recorder = Arc::new(Recorder::default());
    let addr = spawn_push_service(Arc::clone(&recorder)).await;

    let state = RelayState::with_push(Some(VapidKey::generate()), "mailto:a@b.c".to_owned());
    state
        .push
        .subscribe("chan", device(format!("http://{addr}/push/one")));

    // An agent emitting output chunks must not become a notification storm.
    for _ in 0..20 {
        state.push.notify("chan", state.delivery().as_ref()).await;
    }
    assert_eq!(recorder.received.lock().unwrap().len(), 1);
}

async fn spawn_relay(app: Router) -> SocketAddr {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    addr
}

/// Unused directly, but keeps the import honest if the registry type changes.
const _: fn() -> PushRegistry = PushRegistry::new;
