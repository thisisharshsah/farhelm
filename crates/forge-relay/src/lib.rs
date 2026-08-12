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

pub mod auth;
pub mod hub;
pub mod push;
pub mod webpush;

use std::sync::Arc;
use std::time::Duration;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use forge_crypto::Envelope;
use forge_crypto::token::TokenVerifier;

use crate::auth::{Pass, RateLimiter};
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

/// How often the relay pings an otherwise silent connection.
///
/// Comfortably under Cloudflare's ~100-second idle cut, and under
/// [`IDLE_TIMEOUT`] — the pong counts as inbound traffic, so a peer that is
/// alive but quiet is no longer indistinguishable from one that has gone away.
const KEEPALIVE: Duration = Duration::from_secs(30);

pub struct RelayState {
    pub hub: Hub,
    pub push: PushRegistry,
    /// The control plane's public key, when this relay is gated. `None` keeps
    /// the original behaviour: anyone who knows a channel id may join it.
    ///
    /// Verifying only — this process cannot mint a token, which is why a
    /// compromised relay cannot grant itself access to anything.
    pub auth: Option<TokenVerifier>,
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
        Self::build(vapid, push_subject, None)
    }

    /// A relay that only admits tokens signed by the control plane whose public
    /// key this is.
    pub fn gated(vapid: Option<VapidKey>, push_subject: String, auth: TokenVerifier) -> Arc<Self> {
        Self::build(vapid, push_subject, Some(auth))
    }

    fn build(
        vapid: Option<VapidKey>,
        push_subject: String,
        auth: Option<TokenVerifier>,
    ) -> Arc<Self> {
        Arc::new(Self {
            hub: Hub::new(),
            push: PushRegistry::new(),
            auth,
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
        // Which key this relay trusts, so an operator can tell "the control
        // plane rotated" from "the client is broken" without a debugger. The
        // key id is a hash of a public key; publishing it reveals nothing.
        "auth": state.auth.as_ref().map(|verifier| verifier.key_id()),
    }))
}

/// Clients that cannot set headers put the token here.
///
/// The browser `WebSocket` constructor takes a URL and nothing else — no
/// headers, no body. A query parameter is the only place a token can go, which
/// is why these tokens live fifteen minutes: a URL ends up in more logs than a
/// header does, and the mitigation for that is that a captured one expires
/// before it is useful.
#[derive(Debug, serde::Deserialize)]
pub struct ChannelQuery {
    #[serde(default)]
    pub token: Option<String>,
}

/// The gate, in the shape the JSON handlers want it.
///
/// Shared with [`push`] so a channel's socket and its wake-up button cannot
/// drift apart on who may use them.
pub(crate) fn admit_to(
    state: &RelayState,
    token: Option<&str>,
    channel: &str,
) -> Result<Pass, (StatusCode, Json<serde_json::Value>)> {
    auth::admit(state.auth.as_ref(), token, channel, now_ms()).map_err(|denied| {
        (
            StatusCode::UNAUTHORIZED,
            Json(serde_json::json!({ "error": denied.message() })),
        )
    })
}

/// Unix milliseconds. The relay's only use of the clock.
fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or_default()
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
///
/// The token is checked **before** the upgrade, so a refusal is an HTTP status a
/// client can read. Refusing after the upgrade would close the socket with no
/// explanation, and every client would render it as "reconnecting…" forever.
async fn channel(
    ws: WebSocketUpgrade,
    Path(channel): Path<String>,
    Query(query): Query<ChannelQuery>,
    State(state): State<Arc<RelayState>>,
) -> Response {
    let pass = match auth::admit(
        state.auth.as_ref(),
        query.token.as_deref(),
        &channel,
        now_ms(),
    ) {
        Ok(pass) => pass,
        Err(denied) => {
            return (
                StatusCode::UNAUTHORIZED,
                Json(serde_json::json!({ "error": denied.message() })),
            )
                .into_response();
        }
    };

    ws.on_upgrade(move |socket| pump(socket, channel, pass, state))
        .into_response()
}

async fn pump(mut socket: WebSocket, channel: String, pass: Pass, state: Arc<RelayState>) {
    let mut membership = state.hub.join(&channel);
    let connection_id = membership.connection_id;
    let mut limiter = RateLimiter::new(pass.messages_per_minute);

    // Keepalive. Every proxy between here and a phone has an idle timeout, and
    // Cloudflare's is about a hundred seconds — well under the two minutes a
    // quiet fleet routinely goes without saying anything. Without this the
    // connection is cut roughly every two minutes, the runner reconnects, and
    // any request in flight during the gap dies as "the runner did not answer".
    //
    // A WebSocket Ping rather than an application message, because the peer
    // answers it in the protocol layer: browsers pong automatically, so this
    // costs no client code and works for clients that cannot send pings at all.
    let mut keepalive = tokio::time::interval(KEEPALIVE);
    keepalive.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    // `interval` fires immediately; the first tick would ping a socket that has
    // only just opened.
    keepalive.tick().await;

    loop {
        tokio::select! {
            _ = keepalive.tick() => {
                if socket.send(Message::Ping(Vec::new().into())).await.is_err() {
                    break;
                }
            }

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
                        // Over the ceiling: dropped, not disconnected. A burst
                        // is usually an agent looping, and tearing the socket
                        // down would take the *approval* offline too — the one
                        // message the human is waiting for.
                        if !limiter.allow(std::time::Instant::now()) {
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
