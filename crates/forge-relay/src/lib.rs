//! RelayForge relay.
//!
//! Deliberately dumb, and that is the security property. It fans encrypted
//! envelopes out to the other members of a channel and triggers push
//! notifications. It holds no keys, stores no messages, and could not read one
//! if it wanted to — see `forge_crypto` for why.
//!
//! Self-hostable in the literal sense: one binary, no database, no state
//! surviving a restart. The worst a compromised relay learns is that *someone*
//! is talking on a channel and roughly how much.
//!
//! Exposed as a library so the end-to-end tests drive the *same* router the
//! binary serves, in-process — no subprocess to leak, and no second
//! implementation to drift.

pub mod hub;
pub mod push;
pub mod webpush;

use std::sync::Arc;
use std::time::Duration;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path, State};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use forge_crypto::Envelope;

use crate::hub::Hub;
use crate::push::{Delivery, PushRegistry};
use crate::webpush::VapidKey;

pub const DEFAULT_PORT: u16 = 7843;

/// Envelopes larger than this are refused. A relay that will forward anything is
/// a free file host; the largest legitimate payload is an output-tail chunk.
const MAX_ENVELOPE_BYTES: usize = 256 * 1024;

/// Closed if a connection sends nothing at all for this long. WebSocket pings
/// keep an idle-but-alive connection open.
const IDLE_TIMEOUT: Duration = Duration::from_secs(120);

pub struct RelayState {
    pub hub: Hub,
    pub push: PushRegistry,
    /// Absent when the relay was started without one. Everything still works;
    /// devices simply are not woken, which is the pre-push behaviour.
    pub vapid: Option<VapidKey>,
    /// Who push services should contact about this relay (RFC 8292 `sub`).
    pub push_subject: String,
    http: reqwest::Client,
}

/// Where push services are told to complain. Overridden by `--push-subject`.
///
/// It has to be *something*: some services reject a VAPID token with no `sub`,
/// and a relay nobody can be contacted about is a relay that gets blocked.
pub const DEFAULT_PUSH_SUBJECT: &str = "https://github.com/relayforge/relayforge";

impl RelayState {
    pub fn new() -> Arc<Self> {
        Self::with_push(None, DEFAULT_PUSH_SUBJECT.to_owned())
    }

    pub fn with_push(vapid: Option<VapidKey>, push_subject: String) -> Arc<Self> {
        Arc::new(Self {
            hub: Hub::new(),
            push: PushRegistry::new(),
            vapid,
            push_subject,
            // One client, so connections to a push service are pooled rather
            // than renegotiating TLS for every wake-up.
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(10))
                .build()
                .unwrap_or_default(),
        })
    }

    /// What [`PushRegistry::notify`] needs, or `None` if push is not configured.
    pub fn delivery(&self) -> Option<Delivery<'_>> {
        self.vapid.as_ref().map(|vapid| Delivery {
            client: &self.http,
            vapid,
            subject: &self.push_subject,
        })
    }
}

pub fn router(state: Arc<RelayState>) -> Router {
    Router::new()
        .route("/v1/channel/{channel}", get(channel))
        .route("/v1/channel/{channel}/stats", get(channel_stats))
        .route("/v1/push/vapid", get(push::vapid_public_key))
        .route("/v1/push/{channel}/subscribe", post(push::subscribe))
        .route("/v1/push/{channel}", post(push::trigger))
        .route("/v1/health", get(health))
        .with_state(state)
}

async fn health(State(state): State<Arc<RelayState>>) -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "ok": true,
        "channels": state.hub.channel_count(),
    }))
}

/// `GET /v1/channel/{channel}/stats` — connection counts for one channel.
///
/// Not a privacy leak: knowing the channel id already lets you join it and see
/// the same traffic (as ciphertext). It exists so an operator can tell "nobody
/// is connected" from "connected but silent" without attaching a debugger.
async fn channel_stats(
    Path(channel): Path<String>,
    State(state): State<Arc<RelayState>>,
) -> Json<serde_json::Value> {
    let stats = state.hub.stats(&channel).unwrap_or_default();
    Json(serde_json::json!({
        "members": stats.members,
        "delivered": stats.delivered,
        "bytes": stats.bytes,
        "push_subscribers": state.push.subscriber_count(&channel),
    }))
}

/// `GET /v1/channel/{channel}` — the WebSocket every party connects to.
async fn channel(
    ws: WebSocketUpgrade,
    Path(channel): Path<String>,
    State(state): State<Arc<RelayState>>,
) -> impl IntoResponse {
    // The relay does not authenticate the connection, and does not need to: the
    // channel id gets you a seat, not a key. Everything said on it is sealed to
    // a specific recipient, so an uninvited listener hears ciphertext.
    ws.on_upgrade(move |socket| pump(socket, channel, state))
}

async fn pump(mut socket: WebSocket, channel: String, state: Arc<RelayState>) {
    let mut membership = state.hub.join(&channel);
    let connection_id = membership.connection_id;

    loop {
        tokio::select! {
            // Outbound: something else on this channel published.
            outgoing = membership.next() => {
                let Some(envelope) = outgoing else { break };
                let Ok(text) = serde_json::to_string(envelope.as_ref()) else { continue };
                if socket.send(Message::Text(text.into())).await.is_err() {
                    break;
                }
            }

            // Inbound: this connection published something.
            incoming = tokio::time::timeout(IDLE_TIMEOUT, socket.recv()) => {
                let Ok(incoming) = incoming else { break };
                let Some(Ok(message)) = incoming else { break };

                match message {
                    Message::Text(text) => {
                        if text.len() > MAX_ENVELOPE_BYTES {
                            continue;
                        }
                        // Parsed only to route it. A malformed envelope is
                        // dropped rather than forwarded — the relay is not a
                        // general-purpose message bus.
                        let Ok(envelope) = serde_json::from_str::<Envelope>(&text) else {
                            continue;
                        };
                        // A connection may only publish to the channel it joined,
                        // so a rewritten `channel` field cannot cross-post.
                        if envelope.channel != channel {
                            continue;
                        }
                        state.hub.publish(connection_id, envelope);
                        // Deliberately no push here. The relay cannot read the
                        // envelope, so it cannot tell an approval from a log
                        // line — and an agent streaming output would buzz every
                        // phone on the channel every ten seconds, forever. The
                        // runner knows what happened and asks for a wake-up
                        // explicitly via `POST /v1/push/{channel}`.
                    }
                    Message::Ping(payload) => {
                        if socket.send(Message::Pong(payload)).await.is_err() {
                            break;
                        }
                    }
                    Message::Close(_) => break,
                    // Binary and Pong are not part of the protocol.
                    _ => continue,
                }
            }
        }
    }

    state.hub.leave(&channel);
}

/// The envelope cap is a compile-time invariant, not a runtime one: a tail chunk
/// is a few KB, so a quarter megabyte is generous — but there has to be a
/// ceiling, or the relay is a free file host.
const _: () = {
    assert!(MAX_ENVELOPE_BYTES >= 64 * 1024);
    assert!(MAX_ENVELOPE_BYTES <= 1024 * 1024);
};
