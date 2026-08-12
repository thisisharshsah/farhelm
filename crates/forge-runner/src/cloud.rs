//! The runner's link to the control plane.
//!
//! This is what replaces pairing. The old flow needed a human on the runner's
//! network: run `forge-runner pair`, read a QR, paste a JSON blob into each
//! device. This one needs an enrolment key in a config file, once:
//!
//! ```text
//!   forge-runner serve --cloud https://farhelm.aurovie.com --cloud-key frg_…
//! ```
//!
//! …and the machine appears in the fleet of whichever workspace that key belongs
//! to. Devices learn its public key from an authenticated API call rather than
//! from a photograph of a screen.
//!
//! # What this link does *not* carry
//!
//! No session, no approval, no diff, no repository path. It carries an
//! enrolment, a heartbeat, and two tokens. Everything a device actually reads
//! still travels sealed to that device's key, over the relay, exactly as before
//! — the control plane is a directory, not a middlebox.
//!
//! # Trust on first use
//!
//! Enrolling with a key you already used pins this machine's public key. If the
//! same *name* enrols later with a **different** key — a reinstall, or somebody
//! standing in front of the machine — the control plane parks it and refuses to
//! hand devices a channel token until an admin confirms. The runner keeps
//! working on its old channel in the meantime and says so at startup, because
//! failing silently here would be indistinguishable from a network problem.

use std::sync::{Arc, RwLock};
use std::time::Duration;

use serde::Deserialize;

use forge_app::store::prelude::*;
use forge_app::time::now_ms;

/// How often the runner checks in.
///
/// Well under the fifteen-minute channel-token lifetime, so a reconnect always
/// has a valid token to hand, and under the ninety seconds after which the fleet
/// renders a machine as offline.
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);

/// Backoff when the control plane is unreachable. The runner keeps working
/// throughout — losing the control plane costs you *new* connections, not the
/// agent that is mid-task.
const MIN_BACKOFF: Duration = Duration::from_secs(5);
const MAX_BACKOFF: Duration = Duration::from_secs(300);

#[derive(Debug, Clone)]
pub struct CloudConfig {
    /// `https://farhelm.aurovie.com`, no trailing slash required.
    pub base_url: String,
    /// `frg_…`, from the web app. Used once at enrolment and then not needed.
    pub enrollment_key: String,
    /// What this machine is called in the fleet.
    pub name: String,
    pub version: String,
}

impl CloudConfig {
    fn url(&self, path: &str) -> String {
        format!("{}{path}", self.base_url.trim_end_matches('/'))
    }
}

/// What enrolment established, and what the heartbeat keeps fresh.
///
/// Behind an `RwLock` because the relay link reads the channel token every time
/// it reconnects, on a different task from the one refreshing it.
#[derive(Debug, Default)]
pub struct CloudSession {
    /// Where the control plane is. Held here so anything with a session can
    /// reach it without also being handed the config.
    pub base_url: String,
    pub runner_id: String,
    pub org_id: String,
    pub channel: String,
    pub relay_url: String,
    /// Presented to the relay on connect. Fifteen minutes.
    pub channel_token: String,
    /// Presented to the control plane. A day.
    pub runner_token: String,
    /// True while this machine's identity is waiting on a human.
    pub key_change_pending: bool,
}

pub type SharedSession = Arc<RwLock<CloudSession>>;

#[derive(Debug, Deserialize)]
struct EnrollResponse {
    runner_id: String,
    org_id: String,
    channel: String,
    relay_url: String,
    runner_token: String,
    key_change_pending: bool,
}

#[derive(Debug, Deserialize)]
struct HeartbeatResponse {
    channel: String,
    relay_url: String,
    channel_token: String,
    runner_token: String,
    plan: String,
    key_change_pending: bool,
    #[serde(default)]
    devices: Vec<DeviceKey>,
}

#[derive(Debug, Deserialize)]
struct DeviceKey {
    id: String,
    kind: String,
    public_key: String,
}

#[derive(Debug)]
pub enum CloudError {
    Unreachable(String),
    /// The control plane answered, and the answer was no.
    Refused(String),
}

impl std::fmt::Display for CloudError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CloudError::Unreachable(why) => write!(f, "could not reach the control plane: {why}"),
            CloudError::Refused(why) => f.write_str(why),
        }
    }
}

impl std::error::Error for CloudError {}

/// How long to keep trying to enrol at startup before carrying on without it.
///
/// Exists because of a launchd race: the control plane and the runner are
/// started at the same instant with no ordering between them, so the very first
/// enrolment attempt reliably lost. A single attempt turned a two-second
/// startup race into a runner that stayed on loopback until someone noticed —
/// and `KeepAlive` could not fix it, because the process was alive and healthy,
/// just not enrolled.
const ENROLL_DEADLINE: Duration = Duration::from_secs(120);

/// Enrol, retrying while the control plane is still coming up.
///
/// Only *unreachable* is retried. A refusal — a revoked key, a machine removed
/// from the workspace — is an answer, and retrying an answer just delays
/// telling the operator what is wrong.
pub async fn enroll_with_retry(
    config: &CloudConfig,
    public_key: &str,
) -> Result<CloudSession, CloudError> {
    let deadline = tokio::time::Instant::now() + ENROLL_DEADLINE;
    let mut backoff = Duration::from_secs(2);
    let mut attempts = 0u32;

    loop {
        attempts += 1;
        match enroll(config, public_key).await {
            Ok(session) => {
                if attempts > 1 {
                    println!("  cloud      enrolled after {attempts} attempts");
                }
                return Ok(session);
            }
            Err(CloudError::Refused(why)) => return Err(CloudError::Refused(why)),
            Err(err) => {
                if tokio::time::Instant::now() + backoff >= deadline {
                    return Err(err);
                }
                if attempts == 1 {
                    println!("  cloud      not reachable yet, retrying — {err}");
                }
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(Duration::from_secs(15));
            }
        }
    }
}

/// Enrol this machine, or recognise it as already enrolled.
///
/// Called once at startup and awaited, because everything downstream — which
/// channel to publish on, which relay to dial — is decided by the answer. A
/// runner that could not enrol does not silently fall back to a channel nobody
/// is listening to; it says so and serves loopback only.
pub async fn enroll(config: &CloudConfig, public_key: &str) -> Result<CloudSession, CloudError> {
    let response = reqwest::Client::new()
        .post(config.url("/v1/runners/enroll"))
        .bearer_auth(&config.enrollment_key)
        .json(&serde_json::json!({
            "name": config.name,
            "public_key": public_key,
            "version": config.version,
        }))
        .timeout(Duration::from_secs(20))
        .send()
        .await
        .map_err(|err| CloudError::Unreachable(err.to_string()))?;

    let status = response.status();
    let body: serde_json::Value = response
        .json()
        .await
        .map_err(|err| CloudError::Unreachable(err.to_string()))?;

    if !status.is_success() {
        return Err(CloudError::Refused(
            body.get("error")
                .and_then(|error| error.as_str())
                .unwrap_or("enrolment was refused")
                .to_owned(),
        ));
    }

    let enrolled: EnrollResponse =
        serde_json::from_value(body).map_err(|err| CloudError::Unreachable(err.to_string()))?;

    Ok(CloudSession {
        base_url: config.base_url.clone(),
        runner_id: enrolled.runner_id,
        org_id: enrolled.org_id,
        channel: enrolled.channel,
        relay_url: enrolled.relay_url,
        // Enrolment does not mint one — the first heartbeat does, immediately.
        channel_token: String::new(),
        runner_token: enrolled.runner_token,
        key_change_pending: enrolled.key_change_pending,
    })
}

/// Fetch the control plane's verifying key.
///
/// The same call `forge-relay --auth-from` makes, and for the same reason: a
/// resource server needs the public half to check tokens, and copying a base64
/// string between two machines by hand is the step an operator gets wrong.
pub async fn fetch_verifier(
    base_url: &str,
) -> Result<forge_crypto::token::TokenVerifier, CloudError> {
    let url = format!("{}/v1/auth/public-key", base_url.trim_end_matches('/'));
    let body: serde_json::Value = reqwest::Client::new()
        .get(&url)
        .timeout(Duration::from_secs(10))
        .send()
        .await
        .map_err(|err| CloudError::Unreachable(err.to_string()))?
        .json()
        .await
        .map_err(|err| CloudError::Unreachable(err.to_string()))?;

    let key = body
        .get("key")
        .and_then(|key| key.as_str())
        .ok_or_else(|| CloudError::Refused("the control plane returned no key".into()))?;

    forge_crypto::token::TokenVerifier::from_public_base64(key)
        .map_err(|err| CloudError::Refused(err.to_string()))
}

/// Keep checking in, forever.
///
/// Three things happen on every beat, and each is the reason for one of them:
/// the fleet learns this machine is alive, the channel token is refreshed before
/// the current one expires, and the local device list is reconciled to the
/// organisation's — which is how a phone removed in the web app stops receiving.
pub fn spawn_heartbeat<S>(store: Arc<S>, config: CloudConfig, session: SharedSession)
where
    S: DeviceStore + Send + Sync + 'static,
{
    tokio::spawn(async move {
        let client = reqwest::Client::new();
        let mut backoff = MIN_BACKOFF;
        let mut last_plan = String::new();

        loop {
            let token = {
                let held = session.read().expect("cloud session poisoned");
                held.runner_token.clone()
            };

            match beat(&client, &config, &token).await {
                Ok(beat) => {
                    backoff = MIN_BACKOFF;

                    if beat.plan != last_plan {
                        println!("cloud link: plan is {}", beat.plan);
                        last_plan = beat.plan.clone();
                    }
                    if beat.key_change_pending {
                        eprintln!(
                            "cloud link: this machine's identity does not match the one on \
                             file — devices cannot connect until an admin confirms it in the \
                             web app"
                        );
                    }

                    reconcile_devices(store.as_ref(), &beat.devices);

                    let mut held = session.write().expect("cloud session poisoned");
                    held.channel = beat.channel;
                    held.relay_url = beat.relay_url;
                    held.channel_token = beat.channel_token;
                    held.runner_token = beat.runner_token;
                    held.key_change_pending = beat.key_change_pending;
                }
                Err(err) => {
                    eprintln!("cloud link: {err}; retrying in {}s", backoff.as_secs());
                    tokio::time::sleep(backoff).await;
                    backoff = (backoff * 2).min(MAX_BACKOFF);
                    continue;
                }
            }

            tokio::time::sleep(HEARTBEAT_INTERVAL).await;
        }
    });
}

/// Re-read the organisation's device list right now.
///
/// The heartbeat already does this every thirty seconds, which is fine for
/// *revocation* — a removed phone stops being sealed to within half a minute.
/// It is not fine for *arrival*: a device that just signed in is unknown to this
/// runner until the next beat, so its very first request is dropped and the user
/// is told the runner cannot be reached. That is the worst possible first
/// impression, and it happens on every fresh sign-in.
///
/// So the relay link calls this the moment it sees a sender it does not
/// recognise, turning a thirty-second dead window into one round trip.
pub async fn refresh_devices<S: DeviceStore>(session: &SharedSession, store: &S) -> bool {
    let (base_url, token) = {
        let held = match session.read() {
            Ok(held) => held,
            Err(_) => return false,
        };
        (held.base_url.clone(), held.runner_token.clone())
    };
    if base_url.is_empty() || token.is_empty() {
        return false;
    }

    let config = CloudConfig {
        base_url,
        enrollment_key: String::new(),
        name: String::new(),
        version: env!("CARGO_PKG_VERSION").to_owned(),
    };

    match beat(&reqwest::Client::new(), &config, &token).await {
        Ok(beat) => {
            reconcile_devices(store, &beat.devices);
            true
        }
        Err(err) => {
            eprintln!("cloud link: could not refresh the device list: {err}");
            false
        }
    }
}

async fn beat(
    client: &reqwest::Client,
    config: &CloudConfig,
    runner_token: &str,
) -> Result<HeartbeatResponse, CloudError> {
    let response = client
        .post(config.url("/v1/runners/heartbeat"))
        .bearer_auth(runner_token)
        .json(&serde_json::json!({ "version": config.version }))
        .timeout(Duration::from_secs(15))
        .send()
        .await
        .map_err(|err| CloudError::Unreachable(err.to_string()))?;

    if !response.status().is_success() {
        let status = response.status();
        let body: serde_json::Value = response.json().await.unwrap_or_default();
        let message = body
            .get("error")
            .and_then(|error| error.as_str())
            .unwrap_or("heartbeat refused")
            .to_owned();
        // A 404 means the runner row is gone: somebody removed this machine in
        // the web app. Worth naming, because it is a decision rather than a
        // fault, and the fix is to enrol again.
        if status == reqwest::StatusCode::NOT_FOUND {
            return Err(CloudError::Refused(format!(
                "{message} — this machine was removed from the workspace"
            )));
        }
        return Err(CloudError::Refused(message));
    }

    response
        .json()
        .await
        .map_err(|err| CloudError::Unreachable(err.to_string()))
}

/// Make the local device table match the organisation's.
///
/// Additive *and* subtractive. Only adding would mean a revoked phone kept
/// receiving sealed events forever, which is the whole failure this reconcile
/// exists to prevent.
fn reconcile_devices<S: DeviceStore + ?Sized>(store: &S, devices: &[DeviceKey]) {
    let Ok(local) = store.list_devices() else {
        return;
    };

    let now = now_ms();
    for device in devices {
        let Ok(kind) = device.kind.parse() else {
            continue;
        };
        let existing = local.iter().find(|held| held.id == device.id);
        let _ = store.upsert_device(&forge_proto::types::Device {
            id: device.id.clone(),
            kind,
            pubkey: device.public_key.clone(),
            // Push tokens are the runner's own business; `upsert_device`
            // coalesces `None` so this does not wipe one.
            push_token: None,
            paired_at: existing.map(|held| held.paired_at).unwrap_or(now),
        });
    }

    for held in &local {
        if !devices.iter().any(|device| device.id == held.id) {
            let _ = store.remove_device(&held.id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use forge_proto::types::{Device, DeviceKind};
    use forge_sqlite::SqliteStore;

    fn key(id: &str, public_key: &str) -> DeviceKey {
        DeviceKey {
            id: id.to_owned(),
            kind: "phone".to_owned(),
            public_key: public_key.to_owned(),
        }
    }

    #[test]
    fn a_url_survives_a_trailing_slash() {
        let config = CloudConfig {
            base_url: "https://farhelm.aurovie.com/".into(),
            enrollment_key: "frg_x".into(),
            name: "mac".into(),
            version: "0.1.0".into(),
        };
        assert_eq!(
            config.url("/v1/runners/heartbeat"),
            "https://farhelm.aurovie.com/v1/runners/heartbeat"
        );
    }

    #[test]
    fn reconciling_adds_devices_the_workspace_knows_about() {
        let store = SqliteStore::open_in_memory().unwrap();
        reconcile_devices(&store, &[key("dev_1", "pk-1"), key("dev_2", "pk-2")]);

        let held = store.list_devices().unwrap();
        assert_eq!(held.len(), 2);
        assert_eq!(held[0].pubkey, "pk-1");
    }

    #[test]
    fn reconciling_removes_a_device_that_was_revoked() {
        // The failure this exists to prevent: a phone removed in the web app
        // that keeps receiving sealed events because nobody told the runner.
        let store = SqliteStore::open_in_memory().unwrap();
        store
            .upsert_device(&Device {
                id: "dev_gone".into(),
                kind: DeviceKind::Phone,
                pubkey: "pk-gone".into(),
                push_token: None,
                paired_at: 1,
            })
            .unwrap();

        reconcile_devices(&store, &[key("dev_1", "pk-1")]);

        let held = store.list_devices().unwrap();
        assert_eq!(held.len(), 1);
        assert_eq!(held[0].id, "dev_1");
    }

    #[test]
    fn reconciling_keeps_a_devices_push_token_and_pairing_time() {
        let store = SqliteStore::open_in_memory().unwrap();
        store
            .upsert_device(&Device {
                id: "dev_1".into(),
                kind: DeviceKind::Phone,
                pubkey: "pk-1".into(),
                push_token: Some("token".into()),
                paired_at: 1_234,
            })
            .unwrap();

        reconcile_devices(&store, &[key("dev_1", "pk-1")]);

        let held = &store.list_devices().unwrap()[0];
        assert_eq!(held.push_token.as_deref(), Some("token"));
        assert_eq!(held.paired_at, 1_234, "re-dated an existing device");
    }

    #[test]
    fn a_rotated_device_key_is_taken_up() {
        let store = SqliteStore::open_in_memory().unwrap();
        reconcile_devices(&store, &[key("dev_1", "pk-old")]);
        reconcile_devices(&store, &[key("dev_1", "pk-new")]);

        assert_eq!(store.list_devices().unwrap()[0].pubkey, "pk-new");
    }

    #[test]
    fn an_empty_workspace_clears_the_local_list() {
        // Not a no-op: "nobody is allowed to talk to this runner" is a valid
        // and important answer, and treating it as "no update" would make
        // revoking the last device do nothing.
        let store = SqliteStore::open_in_memory().unwrap();
        reconcile_devices(&store, &[key("dev_1", "pk-1")]);
        reconcile_devices(&store, &[]);

        assert!(store.list_devices().unwrap().is_empty());
    }

    #[test]
    fn a_device_of_an_unknown_kind_is_skipped_not_fatal() {
        // A newer control plane may know a device kind this build does not.
        let store = SqliteStore::open_in_memory().unwrap();
        reconcile_devices(
            &store,
            &[
                DeviceKey {
                    id: "dev_future".into(),
                    kind: "glasses".into(),
                    public_key: "pk".into(),
                },
                key("dev_1", "pk-1"),
            ],
        );

        let held = store.list_devices().unwrap();
        assert_eq!(held.len(), 1);
        assert_eq!(held[0].id, "dev_1");
    }
}
