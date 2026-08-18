//! Sign up, enrol a machine, connect a device — over real HTTP and a real
//! WebSocket, against the same routers the binaries serve.
//!
//! This is the test that would have caught every wiring mistake the unit tests
//! cannot: a claim minted with the wrong audience, a channel derived two
//! different ways, a gate that admits when it should refuse. The whole point of
//! replacing pairing is that these three processes agree, and agreement is not
//! something either side can assert alone.

use std::sync::Arc;

use forge_cloud::store::CloudStore;
use forge_cloud::{CloudConfig, CloudState, api, billing::Billing};
use forge_crypto::token::TokenSigner;
use futures_util::StreamExt as _;
use serde_json::{Value, json};

/// A control plane on a real port, with a gated relay pointed at its key.
struct World {
    cloud: String,
    relay_http: String,
    relay_ws: String,
    client: reqwest::Client,
}

async fn spawn() -> World {
    let signer = TokenSigner::generate();
    let verifier = signer.verifier();

    let relay = forge_relay::RelayState::gated(None, "mailto:test@example".into(), verifier);
    let relay_listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let relay_addr = relay_listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(relay_listener, forge_relay::router(relay))
            .await
            .unwrap();
    });

    let cloud_listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let cloud_addr = cloud_listener.local_addr().unwrap();
    let state = Arc::new(CloudState {
        store: CloudStore::open_in_memory().unwrap(),
        signer,
        billing: Billing::Disabled,
        config: CloudConfig {
            relay_url: format!("ws://{relay_addr}"),
            public_url: format!("http://{cloud_addr}"),
        },
    });
    tokio::spawn(async move {
        axum::serve(cloud_listener, api::router(state))
            .await
            .unwrap();
    });

    World {
        cloud: format!("http://{cloud_addr}"),
        relay_http: format!("http://{relay_addr}"),
        relay_ws: format!("ws://{relay_addr}"),
        client: reqwest::Client::new(),
    }
}

impl World {
    async fn post(&self, path: &str, token: Option<&str>, body: Value) -> (u16, Value) {
        let mut request = self
            .client
            .post(format!("{}{path}", self.cloud))
            .json(&body);
        if let Some(token) = token {
            request = request.bearer_auth(token);
        }
        let response = request.send().await.unwrap();
        let status = response.status().as_u16();
        (status, response.json().await.unwrap_or(Value::Null))
    }

    async fn get(&self, path: &str, token: &str) -> (u16, Value) {
        let response = self
            .client
            .get(format!("{}{path}", self.cloud))
            .bearer_auth(token)
            .send()
            .await
            .unwrap();
        let status = response.status().as_u16();
        (status, response.json().await.unwrap_or(Value::Null))
    }

    /// Sign up and return the access token.
    async fn sign_up(&self, email: &str) -> (String, Value) {
        let (status, body) = self
            .post(
                "/v1/auth/signup",
                None,
                json!({
                    "email": email,
                    "password": "correct horse battery",
                    "name": "Harsh",
                }),
            )
            .await;
        assert_eq!(status, 200, "signup failed: {body}");
        (
            body["access_token"].as_str().unwrap().to_owned(),
            body["workspace"].clone(),
        )
    }

    async fn enrollment_key(&self, access: &str) -> String {
        let (status, body) = self
            .post(
                "/v1/enrollment-keys",
                Some(access),
                json!({"name": "laptop"}),
            )
            .await;
        assert_eq!(status, 200, "could not mint an enrolment key: {body}");
        body["token"].as_str().unwrap().to_owned()
    }
}

/// A key of the right shape, without needing a real keypair in every test.
fn public_key() -> String {
    forge_crypto::Identity::generate()
        .public_key()
        .as_str()
        .to_owned()
}

#[tokio::test]
async fn a_machine_and_a_phone_find_each_other_with_no_pairing_code() {
    // The whole replacement for the QR flow, start to finish.
    let world = spawn().await;
    let (access, workspace) = world.sign_up("harsh@example.com").await;
    assert_eq!(workspace["subscription"]["plan"], "free");
    assert_eq!(workspace["runners"].as_array().unwrap().len(), 0);

    // 1. An admin mints one enrolment key, once.
    let key = world.enrollment_key(&access).await;
    assert!(key.starts_with("frg_"));

    // 2. The machine enrols itself. Nobody typed a code on the runner.
    let runner_key = public_key();
    let (status, enrolled) = world
        .post(
            "/v1/runners/enroll",
            Some(&key),
            json!({"name": "mac-studio", "public_key": runner_key, "version": "0.1.0"}),
        )
        .await;
    assert_eq!(status, 200, "enrolment failed: {enrolled}");
    assert_eq!(enrolled["key_change_pending"], false);
    let runner_id = enrolled["runner_id"].as_str().unwrap().to_owned();
    let runner_token = enrolled["runner_token"].as_str().unwrap().to_owned();
    let channel = enrolled["channel"].as_str().unwrap().to_owned();
    assert_eq!(channel, forge_proto::channel_for(&runner_key));

    // 3. The machine heartbeats and gets its seat on the relay.
    let (status, beat) = world
        .post(
            "/v1/runners/heartbeat",
            Some(&runner_token),
            json!({"version": "0.1.0"}),
        )
        .await;
    assert_eq!(status, 200, "heartbeat failed: {beat}");
    let runner_channel_token = beat["channel_token"].as_str().unwrap().to_owned();

    // 4. The phone registers its own key — generated on the phone, as before.
    let device_key = public_key();
    let (status, device) = world
        .post(
            "/v1/devices",
            Some(&access),
            json!({"kind": "phone", "name": "iPhone 15", "public_key": device_key}),
        )
        .await;
    assert_eq!(status, 200, "device registration failed: {device}");
    let device_id = device["id"].as_str().unwrap().to_owned();

    // 5. …and asks for a seat on that machine's channel. This is the step that
    //    used to be "photograph a QR code": the phone learns the runner's public
    //    key from an authenticated call instead.
    let (status, seat) = world
        .post(
            "/v1/channel-token",
            Some(&access),
            json!({"runner_id": runner_id, "device_id": device_id}),
        )
        .await;
    assert_eq!(status, 200, "no channel token: {seat}");
    assert_eq!(seat["runner_public_key"], runner_key);
    assert_eq!(seat["channel"], channel);
    let device_channel_token = seat["token"].as_str().unwrap().to_owned();

    // 6. Both sides get onto the relay with their tokens.
    for token in [&runner_channel_token, &device_channel_token] {
        let url = format!("{}/v1/channel/{channel}?token={token}", world.relay_ws);
        let (socket, _) = tokio_tungstenite::connect_async(&url)
            .await
            .expect("a valid token should be admitted");
        drop(socket);
    }

    // 7. The heartbeat carries the phone's key back to the machine, which is how
    //    the runner knows who to seal events to without ever having been paired.
    let (_, beat) = world
        .post(
            "/v1/runners/heartbeat",
            Some(&runner_token),
            json!({"version": "0.1.0"}),
        )
        .await;
    let devices = beat["devices"].as_array().unwrap();
    assert_eq!(devices.len(), 1);
    assert_eq!(devices[0]["public_key"], device_key);
}

#[tokio::test]
async fn the_relay_refuses_a_connection_with_no_token() {
    let world = spawn().await;
    let url = format!("{}/v1/channel/forge-anything", world.relay_ws);

    // The old behaviour, and the hole this closes: knowing a channel id was a
    // permanent seat on it.
    let result = tokio_tungstenite::connect_async(&url).await;
    assert!(
        result.is_err(),
        "an unauthenticated connection was admitted"
    );
}

#[tokio::test]
async fn a_token_cannot_be_aimed_at_someone_elses_channel() {
    let world = spawn().await;
    let (access, _) = world.sign_up("harsh@example.com").await;
    let key = world.enrollment_key(&access).await;

    let runner_key = public_key();
    let (_, enrolled) = world
        .post(
            "/v1/runners/enroll",
            Some(&key),
            json!({"name": "mac-studio", "public_key": runner_key, "version": "0.1.0"}),
        )
        .await;
    let (_, device) = world
        .post(
            "/v1/devices",
            Some(&access),
            json!({"kind": "phone", "name": "iPhone", "public_key": public_key()}),
        )
        .await;
    let (_, seat) = world
        .post(
            "/v1/channel-token",
            Some(&access),
            json!({
                "runner_id": enrolled["runner_id"],
                "device_id": device["id"],
            }),
        )
        .await;
    let token = seat["token"].as_str().unwrap();

    // A legitimately issued token, pointed somewhere it does not belong.
    let url = format!(
        "{}/v1/channel/forge-somebody-elses-machine?token={token}",
        world.relay_ws
    );
    assert!(tokio_tungstenite::connect_async(&url).await.is_err());
}

#[tokio::test]
async fn one_workspace_cannot_see_or_touch_anothers_machines() {
    // The tenancy boundary, exercised rather than asserted.
    let world = spawn().await;
    let (mine, _) = world.sign_up("harsh@example.com").await;
    let (theirs, _) = world.sign_up("someone@example.com").await;

    let key = world.enrollment_key(&mine).await;
    let (_, enrolled) = world
        .post(
            "/v1/runners/enroll",
            Some(&key),
            json!({"name": "mac-studio", "public_key": public_key(), "version": "0.1.0"}),
        )
        .await;
    let runner_id = enrolled["runner_id"].as_str().unwrap();

    let (status, runners) = world.get("/v1/runners", &theirs).await;
    assert_eq!(status, 200);
    assert!(
        runners.as_array().unwrap().is_empty(),
        "another workspace's machine was listed"
    );

    // Not a 403: whether that id exists elsewhere is not their business.
    let (status, _) = world
        .post(
            &format!("/v1/runners/{runner_id}/approve-key"),
            Some(&theirs),
            json!({}),
        )
        .await;
    assert_eq!(status, 404);
}

#[tokio::test]
async fn the_free_plan_stops_at_one_machine_and_says_what_would_help() {
    let world = spawn().await;
    let (access, _) = world.sign_up("harsh@example.com").await;
    let key = world.enrollment_key(&access).await;

    for name in ["first", "second"] {
        let (status, body) = world
            .post(
                "/v1/runners/enroll",
                Some(&key),
                json!({"name": name, "public_key": public_key(), "version": "0.1.0"}),
            )
            .await;

        if name == "first" {
            assert_eq!(status, 200, "the first machine should enrol: {body}");
        } else {
            assert_eq!(status, 402, "the second machine should need an upgrade");
            assert_eq!(body["upgrade_to"], "pro");
            assert!(body["error"].as_str().unwrap().contains("Free"));
        }
    }
}

#[tokio::test]
async fn a_reinstalled_machine_does_not_silently_become_the_old_one() {
    // Trust on first use. This is the mitigation that makes codeless enrolment
    // safe: a stolen enrolment key can add a machine, but cannot quietly take
    // over one that already has a pinned identity.
    let world = spawn().await;
    let (access, _) = world.sign_up("harsh@example.com").await;
    let key = world.enrollment_key(&access).await;

    let original = public_key();
    let (_, first) = world
        .post(
            "/v1/runners/enroll",
            Some(&key),
            json!({"name": "mac-studio", "public_key": original, "version": "0.1.0"}),
        )
        .await;
    let runner_id = first["runner_id"].as_str().unwrap().to_owned();

    // Same name, different key.
    let (status, second) = world
        .post(
            "/v1/runners/enroll",
            Some(&key),
            json!({"name": "mac-studio", "public_key": public_key(), "version": "0.1.0"}),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(second["key_change_pending"], true);
    // The channel has *not* moved: devices are still talking to the machine
    // whose key was pinned.
    assert_eq!(second["channel"], forge_proto::channel_for(&original));

    // And no device can get a seat until a human confirms.
    let (_, device) = world
        .post(
            "/v1/devices",
            Some(&access),
            json!({"kind": "phone", "name": "iPhone", "public_key": public_key()}),
        )
        .await;
    let (status, refused) = world
        .post(
            "/v1/channel-token",
            Some(&access),
            json!({"runner_id": runner_id, "device_id": device["id"]}),
        )
        .await;
    assert_eq!(status, 403, "handed out a seat on an unconfirmed machine");
    assert!(refused["error"].as_str().unwrap().contains("identity"));

    // The owner confirms, and it works.
    let (status, _) = world
        .post(
            &format!("/v1/runners/{runner_id}/approve-key"),
            Some(&access),
            json!({}),
        )
        .await;
    assert_eq!(status, 200);
    let (status, _) = world
        .post(
            "/v1/channel-token",
            Some(&access),
            json!({"runner_id": runner_id, "device_id": device["id"]}),
        )
        .await;
    assert_eq!(status, 200);
}

#[tokio::test]
async fn removing_a_device_stops_it_getting_another_seat() {
    // Revocation, without telling the relay anything.
    let world = spawn().await;
    let (access, _) = world.sign_up("harsh@example.com").await;
    let key = world.enrollment_key(&access).await;
    let (_, enrolled) = world
        .post(
            "/v1/runners/enroll",
            Some(&key),
            json!({"name": "mac", "public_key": public_key(), "version": "0.1.0"}),
        )
        .await;
    let (_, device) = world
        .post(
            "/v1/devices",
            Some(&access),
            json!({"kind": "phone", "name": "iPhone", "public_key": public_key()}),
        )
        .await;
    let device_id = device["id"].as_str().unwrap().to_owned();

    let seat = json!({"runner_id": enrolled["runner_id"], "device_id": device_id});
    assert_eq!(
        world
            .post("/v1/channel-token", Some(&access), seat.clone())
            .await
            .0,
        200
    );

    let removed = world
        .client
        .delete(format!("{}/v1/devices/{device_id}", world.cloud))
        .bearer_auth(&access)
        .send()
        .await
        .unwrap();
    assert_eq!(removed.status().as_u16(), 204);

    assert_eq!(
        world.post("/v1/channel-token", Some(&access), seat).await.0,
        404,
        "a removed device was still issued a seat"
    );
}

#[tokio::test]
async fn a_relay_wake_up_needs_a_token_too() {
    // Otherwise knowing a channel id is enough to ring somebody's phone every
    // ten seconds indefinitely.
    let world = spawn().await;
    let response = world
        .client
        .post(format!("{}/v1/push/forge-anything", world.relay_http))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status().as_u16(), 401);
}

#[tokio::test]
async fn two_devices_on_one_channel_still_only_hear_ciphertext() {
    // The property that must survive all of this: the control plane hands out
    // addresses, not the ability to read. The relay forwards what it is given
    // and has no key to open it with.
    let world = spawn().await;
    let (access, _) = world.sign_up("harsh@example.com").await;
    let key = world.enrollment_key(&access).await;

    let runner = forge_crypto::Identity::generate();
    let (_, enrolled) = world
        .post(
            "/v1/runners/enroll",
            Some(&key),
            json!({
                "name": "mac",
                "public_key": runner.public_key().as_str(),
                "version": "0.1.0"
            }),
        )
        .await;
    let channel = enrolled["channel"].as_str().unwrap().to_owned();

    let phone = forge_crypto::Identity::generate();
    let (_, device) = world
        .post(
            "/v1/devices",
            Some(&access),
            json!({
                "kind": "phone",
                "name": "iPhone",
                "public_key": phone.public_key().as_str()
            }),
        )
        .await;
    let (_, seat) = world
        .post(
            "/v1/channel-token",
            Some(&access),
            json!({"runner_id": enrolled["runner_id"], "device_id": device["id"]}),
        )
        .await;

    let url = format!(
        "{}/v1/channel/{channel}?token={}",
        world.relay_ws,
        seat["token"].as_str().unwrap()
    );
    let (socket, _) = tokio_tungstenite::connect_async(&url).await.unwrap();
    let (_sink, mut stream) = socket.split();

    // The runner publishes something secret, sealed to the phone.
    let envelope = runner
        .seal(
            &channel,
            "runner",
            &forge_crypto::PublicKey::parse(phone.public_key().as_str()).unwrap(),
            b"rm -rf /very/secret/path",
        )
        .unwrap();

    let (runner_socket, _) = tokio_tungstenite::connect_async(format!(
        "{}/v1/channel/{channel}?token={}",
        world.relay_ws,
        {
            let (_, beat) = world
                .post(
                    "/v1/runners/heartbeat",
                    Some(enrolled["runner_token"].as_str().unwrap()),
                    json!({"version": "0.1.0"}),
                )
                .await;
            beat["channel_token"].as_str().unwrap().to_owned()
        }
    ))
    .await
    .unwrap();

    let (mut runner_sink, _) = runner_socket.split();
    use futures_util::SinkExt as _;
    runner_sink
        .send(tokio_tungstenite::tungstenite::Message::Text(
            serde_json::to_string(&envelope).unwrap().into(),
        ))
        .await
        .unwrap();

    let received = tokio::time::timeout(std::time::Duration::from_secs(5), stream.next())
        .await
        .expect("the relay did not forward the envelope")
        .unwrap()
        .unwrap();

    let text = received.to_text().unwrap();
    assert!(!text.contains("rm -rf"), "the relay forwarded plaintext");
    assert!(!text.contains("secret"));

    // …and the phone, which holds the key, reads it.
    let forwarded: forge_crypto::Envelope = serde_json::from_str(text).unwrap();
    let opened = phone.open(runner.public_key(), &forwarded).unwrap();
    assert_eq!(opened, b"rm -rf /very/secret/path");
}

/* ------------------------------------------------- self-enrolment (device flow) */

/// The whole point of the device flow: a machine joins a workspace without
/// anybody copying a secret onto it.
#[tokio::test]
async fn a_machine_enrols_itself_after_a_human_approves_the_code() {
    let world = spawn().await;
    let (access, _) = world.sign_up("harsh@example.com").await;

    // 1. The machine asks. Unauthenticated — it has no credential yet.
    let (status, issued) = world
        .post(
            "/v1/device/code",
            None,
            json!({ "name": "build-server", "version": "0.1.0" }),
        )
        .await;
    assert_eq!(status, 200, "{issued}");
    let device_code = issued["device_code"].as_str().unwrap().to_owned();
    let user_code = issued["user_code"].as_str().unwrap().to_owned();
    assert!(
        user_code.contains('-'),
        "user code should be legible: {user_code}"
    );
    assert!(
        issued["verification_uri"]
            .as_str()
            .unwrap()
            .ends_with("/#/connect"),
        "{issued}"
    );

    // 2. Polling before anybody answers says so, and releases nothing.
    let (status, answer) = world
        .post(
            "/v1/device/token",
            None,
            json!({ "device_code": device_code }),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(answer["status"], "pending");
    assert!(answer["enrollment_key"].is_null());

    // 3. The signed-in human sees which machine is asking before deciding.
    let (status, pending) = world.get(&format!("/v1/device/{user_code}"), &access).await;
    assert_eq!(status, 200, "{pending}");
    assert_eq!(pending["name"], "build-server");
    assert_eq!(pending["status"], "pending");

    // 4. …and approves it.
    let (status, decided) = world
        .post(
            &format!("/v1/device/{user_code}/approve"),
            Some(&access),
            json!({}),
        )
        .await;
    assert_eq!(status, 200, "{decided}");
    assert_eq!(decided["status"], "approved");

    // 5. The machine collects the credential it was never told.
    let (status, answer) = world
        .post(
            "/v1/device/token",
            None,
            json!({ "device_code": device_code }),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(answer["status"], "approved");
    let key = answer["enrollment_key"].as_str().unwrap().to_owned();
    assert!(key.starts_with("frg_"), "{key}");

    // 6. And that key actually enrols it — the whole flow is worth nothing if
    //    what it hands back is not the credential the enrol route accepts.
    let (status, enrolled) = world
        .post(
            "/v1/runners/enroll",
            Some(&key),
            json!({
                "name": "build-server",
                "public_key": forge_crypto::Identity::generate().public_key().to_string(),
                "version": "0.1.0",
            }),
        )
        .await;
    assert_eq!(status, 200, "{enrolled}");
    assert!(!enrolled["channel"].as_str().unwrap().is_empty());

    // 7. The machine is now in the fleet the web app renders.
    let (status, workspace) = world.get("/v1/workspace", &access).await;
    assert_eq!(status, 200);
    let runners = workspace["runners"].as_array().unwrap();
    assert_eq!(runners.len(), 1);
    assert_eq!(runners[0]["name"], "build-server");
}

#[tokio::test]
async fn a_credential_is_handed_over_exactly_once() {
    // Two polls racing must not both walk away with a usable key.
    let world = spawn().await;
    let (access, _) = world.sign_up("harsh@example.com").await;

    let (_, issued) = world
        .post("/v1/device/code", None, json!({ "name": "laptop" }))
        .await;
    let device_code = issued["device_code"].as_str().unwrap().to_owned();
    let user_code = issued["user_code"].as_str().unwrap().to_owned();
    world
        .post(
            &format!("/v1/device/{user_code}/approve"),
            Some(&access),
            json!({}),
        )
        .await;

    let (_, first) = world
        .post(
            "/v1/device/token",
            None,
            json!({ "device_code": device_code }),
        )
        .await;
    let (_, second) = world
        .post(
            "/v1/device/token",
            None,
            json!({ "device_code": device_code }),
        )
        .await;

    assert_eq!(first["status"], "approved");
    assert!(first["enrollment_key"].as_str().is_some());
    assert_eq!(
        second["status"], "expired",
        "the key was released a second time: {second}"
    );
}

#[tokio::test]
async fn a_refused_machine_is_told_no_rather_than_left_polling() {
    let world = spawn().await;
    let (access, _) = world.sign_up("harsh@example.com").await;

    let (_, issued) = world
        .post("/v1/device/code", None, json!({ "name": "not-mine" }))
        .await;
    let device_code = issued["device_code"].as_str().unwrap().to_owned();
    let user_code = issued["user_code"].as_str().unwrap().to_owned();

    let (status, _) = world
        .post(
            &format!("/v1/device/{user_code}/deny"),
            Some(&access),
            json!({}),
        )
        .await;
    assert_eq!(status, 200);

    let (_, answer) = world
        .post(
            "/v1/device/token",
            None,
            json!({ "device_code": device_code }),
        )
        .await;
    assert_eq!(answer["status"], "denied");
    assert!(answer["enrollment_key"].is_null());
}

#[tokio::test]
async fn a_code_cannot_be_approved_by_somebody_who_is_not_signed_in() {
    let world = spawn().await;
    world.sign_up("harsh@example.com").await;

    let (_, issued) = world
        .post("/v1/device/code", None, json!({ "name": "target" }))
        .await;
    let user_code = issued["user_code"].as_str().unwrap().to_owned();

    let (status, _) = world
        .post(&format!("/v1/device/{user_code}/approve"), None, json!({}))
        .await;
    assert_eq!(status, 401, "an unauthenticated approval must be refused");
}

#[tokio::test]
async fn one_workspace_cannot_approve_a_code_and_have_another_pay_for_it() {
    // The code carries no workspace of its own — it belongs to whoever approves
    // it. What must not happen is a machine landing anywhere but in the
    // approver's fleet.
    let world = spawn().await;
    let (mine, _) = world.sign_up("harsh@example.com").await;
    let (theirs, _) = world.sign_up("someone@example.com").await;

    let (_, issued) = world
        .post("/v1/device/code", None, json!({ "name": "contested" }))
        .await;
    let device_code = issued["device_code"].as_str().unwrap().to_owned();
    let user_code = issued["user_code"].as_str().unwrap().to_owned();

    world
        .post(
            &format!("/v1/device/{user_code}/approve"),
            Some(&theirs),
            json!({}),
        )
        .await;

    let (_, answer) = world
        .post(
            "/v1/device/token",
            None,
            json!({ "device_code": device_code }),
        )
        .await;
    let key = answer["enrollment_key"].as_str().unwrap().to_owned();
    world
        .post(
            "/v1/runners/enroll",
            Some(&key),
            json!({
                "name": "contested",
                "public_key": forge_crypto::Identity::generate().public_key().to_string(),
                "version": "0.1.0",
            }),
        )
        .await;

    // It landed in the approver's fleet, and only there.
    let (_, theirs_workspace) = world.get("/v1/workspace", &theirs).await;
    let (_, my_workspace) = world.get("/v1/workspace", &mine).await;
    assert_eq!(theirs_workspace["runners"].as_array().unwrap().len(), 1);
    assert_eq!(
        my_workspace["runners"].as_array().unwrap().len(),
        0,
        "a machine appeared in a workspace that never approved it"
    );
}

#[tokio::test]
async fn a_device_code_nobody_issued_is_answered_the_same_as_an_expired_one() {
    // Distinguishing them would let somebody probe for live codes.
    let world = spawn().await;
    let (_, answer) = world
        .post(
            "/v1/device/token",
            None,
            json!({ "device_code": "frgd_not-a-real-code" }),
        )
        .await;
    assert_eq!(answer["status"], "expired");
}
