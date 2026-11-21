//! The push trigger (A2).
//!
//! An agent that stalls waiting for an approval nobody knows about is the
//! problem this whole project exists to fix, so *something* has to wake the
//! phone. The relay is the only always-reachable party, which makes it the
//! trigger point.
//!
//! # What this does
//!
//! Records WebPush subscriptions per channel, rate-limits wake-ups, and delivers
//! them. The wire work (VAPID signing and `aes128gcm` encryption) is in
//! [`crate::webpush`]; this module owns *who* to wake and *how often*.
//!
//! # The payload is empty, on purpose
//!
//! The wake-up is content-free. The relay cannot read the envelope that
//! triggered it, so it has nothing truthful to put in a notification body;
//! putting the approval text there would mean decrypting it somewhere, which is
//! exactly the property §6 promises not to break. The device wakes, connects,
//! decrypts locally, and renders the real card.
//!
//! # A subscription that has gone away is forgotten
//!
//! Push services answer 404 or 410 for a subscription the browser dropped.
//! Retrying one forever is how a relay ends up hammering a dead endpoint every
//! ten seconds for a device that was uninstalled months ago, so a dead endpoint
//! is removed on the spot.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::{Json, extract};
use serde::{Deserialize, Serialize};

use crate::RelayState;
use crate::webpush::{self, PushError, VapidKey};

/// Minimum gap between wake-ups for one channel. A chatty agent emitting output
/// chunks must not become a notification storm; the approval that matters still
/// arrives within this window.
const MIN_INTERVAL: Duration = Duration::from_secs(10);

/// The push services browsers hand out endpoints on; a leading dot means any
/// host under that domain. A subscription anywhere else is refused, or the
/// relay would POST wherever a caller pointed it, from the machine it runs on
/// (security review, H4).
const PUSH_HOSTS: &[&str] = &[
    // Chrome, and the browsers built on it.
    "fcm.googleapis.com",
    // Safari (web.push.apple.com).
    ".push.apple.com",
    // Firefox.
    ".push.services.mozilla.com",
    // Edge on Windows.
    ".notify.windows.com",
];

/// The longest endpoint taken. Real ones are a few hundred characters.
const MAX_ENDPOINT_LEN: usize = 1_024;

/// Devices one channel can have waiting for push: enough for a person's
/// browsers and phones, and a bound on what one wake-up sends.
const MAX_SUBSCRIPTIONS: usize = 20;

/// Whether an endpoint is on a browser push service, over https on the
/// standard port, with nothing in it that could point the request elsewhere.
pub fn acceptable_endpoint(endpoint: &str) -> Result<(), &'static str> {
    if endpoint.len() > MAX_ENDPOINT_LEN {
        return Err("that endpoint is too long");
    }
    let Some(rest) = endpoint.strip_prefix("https://") else {
        return Err("a push endpoint must be https");
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    if authority.contains('@') {
        return Err("that is not a browser push service");
    }
    let host = match authority.rsplit_once(':') {
        Some((host, "443")) => host,
        Some(_) => return Err("a push endpoint must use the standard port"),
        None => authority,
    }
    .to_ascii_lowercase();
    let known = PUSH_HOSTS.iter().any(|allowed| {
        if allowed.starts_with('.') {
            host.ends_with(allowed)
        } else {
            host == *allowed
        }
    });
    if known {
        Ok(())
    } else {
        Err("that is not a browser push service")
    }
}

/// A browser's WebPush subscription, as `PushManager.subscribe()` returns it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Subscription {
    pub endpoint: String,
    /// Client public key for payload encryption (`p256dh`).
    pub p256dh: String,
    /// Client auth secret.
    pub auth: String,
}

#[derive(Default)]
struct ChannelPush {
    subscriptions: Vec<Subscription>,
    last_sent: Option<Instant>,
}

/// Push subscriptions, in memory only.
///
/// Losing them on restart is deliberate: a subscription is cheap to re-register
/// on the client's next connect, and persisting them would give the relay a
/// durable list of who talks to whom, precisely the metadata it is supposed not
/// to accumulate.
pub struct PushRegistry {
    channels: Arc<Mutex<HashMap<String, ChannelPush>>>,
}

impl Default for PushRegistry {
    fn default() -> Self {
        Self::new()
    }
}

impl PushRegistry {
    pub fn new() -> Self {
        Self {
            channels: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Adds a device, or replaces it; false when the channel is full.
    pub fn subscribe(&self, channel: &str, subscription: Subscription) -> bool {
        let mut channels = self.channels.lock().expect("push registry poisoned");
        let entry = channels.entry(channel.to_owned()).or_default();
        // Re-subscribing with the same endpoint replaces rather than duplicates:
        // browsers hand back the same endpoint across reloads.
        if let Some(existing) = entry
            .subscriptions
            .iter_mut()
            .find(|candidate| candidate.endpoint == subscription.endpoint)
        {
            *existing = subscription;
        } else if entry.subscriptions.len() < MAX_SUBSCRIPTIONS {
            entry.subscriptions.push(subscription);
        } else {
            return false;
        }
        true
    }

    pub fn subscriber_count(&self, channel: &str) -> usize {
        self.channels
            .lock()
            .expect("push registry poisoned")
            .get(channel)
            .map(|entry| entry.subscriptions.len())
            .unwrap_or(0)
    }

    /// Drop a subscription the push service says is gone.
    pub fn forget(&self, channel: &str, endpoint: &str) {
        let mut channels = self.channels.lock().expect("push registry poisoned");
        if let Some(entry) = channels.get_mut(channel) {
            entry.subscriptions.retain(|s| s.endpoint != endpoint);
        }
    }

    /// Wake a channel's devices, subject to the rate limit.
    ///
    /// Returns how many were actually pushed to. Delivery needs a VAPID key; a
    /// relay started without one still rate-limits and reports, so the
    /// foregrounded-app path over the WebSocket is unaffected.
    pub async fn notify(&self, channel: &str, delivery: Option<&Delivery<'_>>) -> usize {
        let due = self.due_at(channel, Instant::now());
        let Some(delivery) = delivery else {
            return due.len();
        };

        let mut woken = 0;
        for subscription in due {
            // The payload is empty: the relay has nothing truthful to say.
            match webpush::deliver(
                delivery.client,
                &subscription,
                delivery.vapid,
                delivery.subject,
                b"",
                now_secs(),
            )
            .await
            {
                Ok(()) => woken += 1,
                Err(PushError::Expired) => {
                    self.forget(channel, &subscription.endpoint);
                }
                Err(err) => {
                    // One unreachable device must not stop the others; the app
                    // still works over the WebSocket when it is foregrounded.
                    eprintln!("push: {} failed: {err}", host_of(&subscription.endpoint));
                }
            }
        }
        woken
    }

    /// The subscriptions due a wake-up now, marking the channel as sent.
    ///
    /// Separate from delivery so the rate limit is testable without a clock or a
    /// network, and so the lock is never held across an await.
    pub fn due_at(&self, channel: &str, now: Instant) -> Vec<Subscription> {
        let mut channels = self.channels.lock().expect("push registry poisoned");
        let Some(entry) = channels.get_mut(channel) else {
            return Vec::new();
        };
        if entry.subscriptions.is_empty() {
            return Vec::new();
        }
        if entry
            .last_sent
            .is_some_and(|last| now.duration_since(last) < MIN_INTERVAL)
        {
            return Vec::new();
        }

        entry.last_sent = Some(now);
        entry.subscriptions.clone()
    }
}

/// What delivery needs. Absent when the relay was started without a VAPID key.
pub struct Delivery<'a> {
    pub client: &'a reqwest::Client,
    pub vapid: &'a VapidKey,
    /// A `mailto:` or `https:` URL push services use to reach the operator.
    pub subject: &'a str,
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Just the host, for logs. The path identifies a device and does not belong in
/// a log file on a machine that is meant to know nothing.
fn host_of(endpoint: &str) -> &str {
    endpoint
        .split_once("://")
        .map(|(_, rest)| rest.split('/').next().unwrap_or(rest))
        .unwrap_or(endpoint)
}

/* ------------------------------------------------------------------ handlers */

/// `POST /v1/push/{channel}/subscribe`
pub async fn subscribe(
    Path(channel): Path<String>,
    extract::Query(query): extract::Query<crate::ChannelQuery>,
    State(state): State<Arc<RelayState>>,
    Json(subscription): Json<Subscription>,
) -> (StatusCode, Json<serde_json::Value>) {
    if let Err(denied) = crate::admit_to(&state, query.token.as_deref(), &channel) {
        return denied;
    }
    if subscription.endpoint.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "error": "endpoint is required" })),
        );
    }
    if let Err(problem) = acceptable_endpoint(&subscription.endpoint) {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "error": problem })),
        );
    }

    if !state.push.subscribe(&channel, subscription) {
        return (
            StatusCode::TOO_MANY_REQUESTS,
            Json(serde_json::json!({ "error": "this channel has as many devices as it can take" })),
        );
    }
    (
        StatusCode::OK,
        Json(serde_json::json!({
            "subscribers": state.push.subscriber_count(&channel)
        })),
    )
}

/// `POST /v1/push/{channel}`: wake a channel's devices without publishing.
///
/// Used by the runner when something happens that nobody is connected to see.
pub async fn trigger(
    Path(channel): Path<String>,
    extract::Query(query): extract::Query<crate::ChannelQuery>,
    State(state): State<Arc<RelayState>>,
    _body: Option<extract::Json<serde_json::Value>>,
) -> (StatusCode, Json<serde_json::Value>) {
    // Gated for the same reason the socket is: without it, knowing a channel id
    // is enough to buzz somebody's phone every ten seconds indefinitely.
    if let Err(denied) = crate::admit_to(&state, query.token.as_deref(), &channel) {
        return denied;
    }
    let woken = state.push.notify(&channel, state.delivery().as_ref()).await;
    (StatusCode::OK, Json(serde_json::json!({ "woken": woken })))
}

/// `GET /v1/push/vapid`: the `applicationServerKey` browsers subscribe with.
///
/// Public by definition: a browser cannot subscribe without it, and it
/// authenticates the relay to the push service rather than the other way round.
pub async fn vapid_public_key(
    State(state): State<Arc<RelayState>>,
) -> (StatusCode, Json<serde_json::Value>) {
    match &state.vapid {
        Some(key) => (
            StatusCode::OK,
            Json(serde_json::json!({ "publicKey": key.public_key_base64url() })),
        ),
        None => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(serde_json::json!({
                "error": "this relay has no VAPID key; start it with --vapid-key to enable push"
            })),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_browser_push_services_are_accepted() {
        for endpoint in [
            "https://fcm.googleapis.com/fcm/send/abc",
            "https://web.push.apple.com/QGuQ",
            "https://updates.push.services.mozilla.com/wpush/v2/gAAA",
            "https://wns2-par02p.notify.windows.com/w/?token=x",
            "https://FCM.googleapis.com:443/fcm/send/abc",
        ] {
            assert_eq!(acceptable_endpoint(endpoint), Ok(()), "{endpoint}");
        }
        for endpoint in [
            "http://fcm.googleapis.com/fcm/send/abc",
            "https://127.0.0.1:7844/v1/runners/heartbeat",
            "https://localhost/x",
            "https://[::1]/x",
            "https://fcm.googleapis.com:8443/x",
            "https://fcm.googleapis.com@evil.example/x",
            "https://evil.example/fcm.googleapis.com",
            "https://notpush.apple.com/x",
            "https://push.apple.com.evil.example/x",
        ] {
            assert!(acceptable_endpoint(endpoint).is_err(), "{endpoint}");
        }
        let long = format!("https://fcm.googleapis.com/{}", "a".repeat(1_100));
        assert!(acceptable_endpoint(&long).is_err());
    }

    #[test]
    fn a_channel_takes_so_many_devices_and_a_known_one_again() {
        let registry = PushRegistry::new();
        for n in 0..MAX_SUBSCRIPTIONS {
            assert!(registry.subscribe(
                "chan",
                subscription(&format!("https://fcm.googleapis.com/{n}"))
            ));
        }
        assert!(!registry.subscribe("chan", subscription("https://fcm.googleapis.com/one-more")));
        assert!(registry.subscribe("chan", subscription("https://fcm.googleapis.com/0")));
        assert_eq!(registry.subscriber_count("chan"), MAX_SUBSCRIPTIONS);
    }

    fn subscription(endpoint: &str) -> Subscription {
        Subscription {
            endpoint: endpoint.to_owned(),
            p256dh: "key".to_owned(),
            auth: "auth".to_owned(),
        }
    }

    /// How many devices a wake-up right now would reach.
    fn due(registry: &PushRegistry, channel: &str, at: Instant) -> usize {
        registry.due_at(channel, at).len()
    }

    #[test]
    fn a_channel_with_no_subscribers_wakes_nobody() {
        let registry = PushRegistry::new();
        assert_eq!(due(&registry, "chan", Instant::now()), 0);
    }

    #[test]
    fn subscribing_then_notifying_reaches_the_device() {
        let registry = PushRegistry::new();
        registry.subscribe("chan", subscription("https://push.example/a"));
        assert_eq!(due(&registry, "chan", Instant::now()), 1);
    }

    #[test]
    fn re_subscribing_the_same_endpoint_does_not_duplicate_it() {
        // A browser hands back the same endpoint on every reload; naively
        // pushing would send one notification per page view.
        let registry = PushRegistry::new();
        registry.subscribe("chan", subscription("https://push.example/a"));
        registry.subscribe("chan", subscription("https://push.example/a"));
        assert_eq!(registry.subscriber_count("chan"), 1);
    }

    #[test]
    fn re_subscribing_replaces_the_keys() {
        // A browser can rotate `p256dh`/`auth` for the same endpoint. Keeping
        // the old ones would encrypt to a key the device no longer holds: a
        // push that arrives and cannot be opened.
        let registry = PushRegistry::new();
        registry.subscribe("chan", subscription("https://push.example/a"));
        registry.subscribe(
            "chan",
            Subscription {
                endpoint: "https://push.example/a".into(),
                p256dh: "rotated".into(),
                auth: "rotated".into(),
            },
        );
        assert_eq!(registry.due_at("chan", Instant::now())[0].p256dh, "rotated");
    }

    #[test]
    fn different_endpoints_are_separate_devices() {
        let registry = PushRegistry::new();
        registry.subscribe("chan", subscription("https://push.example/phone"));
        registry.subscribe("chan", subscription("https://push.example/watch"));
        assert_eq!(registry.subscriber_count("chan"), 2);
    }

    #[test]
    fn a_burst_of_activity_produces_one_wake_up() {
        let registry = PushRegistry::new();
        registry.subscribe("chan", subscription("https://push.example/a"));

        let start = Instant::now();
        assert_eq!(due(&registry, "chan", start), 1);
        // An agent emitting output chunks must not become a notification storm.
        assert_eq!(due(&registry, "chan", start + Duration::from_secs(1)), 0);
        assert_eq!(due(&registry, "chan", start + Duration::from_secs(5)), 0);
    }

    #[test]
    fn the_rate_limit_lifts_after_the_interval() {
        let registry = PushRegistry::new();
        registry.subscribe("chan", subscription("https://push.example/a"));

        let start = Instant::now();
        registry.due_at("chan", start);
        assert_eq!(due(&registry, "chan", start + MIN_INTERVAL), 1);
    }

    #[test]
    fn channels_have_independent_rate_limits() {
        let registry = PushRegistry::new();
        registry.subscribe("one", subscription("https://push.example/a"));
        registry.subscribe("two", subscription("https://push.example/b"));

        let now = Instant::now();
        assert_eq!(due(&registry, "one", now), 1);
        // A busy session must not silence a different one.
        assert_eq!(due(&registry, "two", now), 1);
    }

    #[test]
    fn a_device_that_went_away_is_forgotten() {
        // Push services answer 410 for a subscription the browser dropped.
        // Keeping it means hammering a dead endpoint every ten seconds forever.
        let registry = PushRegistry::new();
        registry.subscribe("chan", subscription("https://push.example/gone"));
        registry.subscribe("chan", subscription("https://push.example/live"));

        registry.forget("chan", "https://push.example/gone");
        assert_eq!(registry.subscriber_count("chan"), 1);
        assert_eq!(
            registry.due_at("chan", Instant::now())[0].endpoint,
            "https://push.example/live"
        );
    }

    #[test]
    fn forgetting_something_that_is_not_there_is_harmless() {
        let registry = PushRegistry::new();
        registry.forget("chan", "https://push.example/never-existed");
        assert_eq!(registry.subscriber_count("chan"), 0);
    }

    #[tokio::test]
    async fn without_a_vapid_key_nothing_is_delivered_and_nothing_panics() {
        // A relay started without push still runs. The app works over the
        // WebSocket when it is foregrounded, which is the pre-push behaviour.
        let registry = PushRegistry::new();
        registry.subscribe("chan", subscription("https://push.example/a"));
        assert_eq!(registry.notify("chan", None).await, 1);
    }

    #[test]
    fn only_the_host_reaches_the_log() {
        // The path identifies a device. A relay that logs it has written down
        // exactly the thing it is built not to keep.
        assert_eq!(
            host_of("https://fcm.googleapis.com/fcm/send/secret-device-id"),
            "fcm.googleapis.com"
        );
        assert_eq!(host_of("garbage"), "garbage");
    }

    #[test]
    fn subscriptions_carry_no_channel_content() {
        // The registry holds endpoints and client keys, nothing about what the
        // channel is for, who owns it, or what was said on it.
        let subscription = subscription("https://push.example/a");
        let json = serde_json::to_string(&subscription).unwrap();
        assert!(json.contains("endpoint"));
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&json)
                .unwrap()
                .as_object()
                .unwrap()
                .len(),
            3,
            "the subscription grew a field; check it leaks nothing"
        );
    }
}
