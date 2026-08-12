//! Who may join a channel, and how fast they may talk.
//!
//! The relay used to answer both questions with "anyone, as fast as they like",
//! and said so in a comment: *the channel id gets you a seat, not a key*. That
//! is still true of **confidentiality** — everything on a channel is sealed to a
//! device key this process has never seen, and that has not changed. What it was
//! not true of is everything else:
//!
//! - A channel id, once photographed out of a QR code, was a permanent seat.
//!   Unpairing a device removed a row on the runner; it did not stop the ex-
//!   device from sitting on the fan-out watching *when* approvals happen and how
//!   big they are.
//! - There was no way to stop one tenant flooding the relay for everyone else.
//!
//! Both are fixed by verifying a short-lived token from the control plane. The
//! relay still holds no database and still cannot read a byte of content: it
//! checks a signature, compares one string, and counts.
//!
//! # Staying open is a supported configuration
//!
//! Without `--auth-key` the relay behaves exactly as it always did. A
//! single-user deployment on a home network has nobody to authorise and nothing
//! to meter, and forcing a control plane on it would make the simple case worse.

use std::time::{Duration, Instant};

use forge_crypto::token::{Audience, Claims, TokenVerifier};

/// Why a connection was refused. The text reaches the client, so it says what to
/// do rather than what went wrong internally.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Denied {
    /// No token at all, on a relay that requires one.
    Missing,
    /// Present but not valid: bad signature, expired, wrong audience.
    Invalid(String),
    /// Valid, but for a different channel. The interesting attack: take a token
    /// legitimately issued for your own runner and point it at somebody else's.
    WrongChannel,
}

impl Denied {
    pub fn message(&self) -> String {
        match self {
            Denied::Missing => "this relay requires a token — sign in and reconnect".to_owned(),
            Denied::Invalid(why) => why.clone(),
            Denied::WrongChannel => "that token is not for this channel".to_owned(),
        }
    }
}

/// What a verified connection is allowed to do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pass {
    /// Who, for the rate limiter and for logs. A device id or a runner id —
    /// never an account, because two phones on one account should be metered
    /// separately.
    pub subject: String,
    pub messages_per_minute: u32,
}

impl Pass {
    /// What an unauthenticated relay hands every connection.
    ///
    /// The rate ceiling still applies: a relay with no control plane is usually
    /// a home deployment, and a runaway agent looping on `session_upsert` is a
    /// bug worth surviving whether or not anyone is paying.
    pub fn open() -> Self {
        Self {
            subject: "anonymous".to_owned(),
            messages_per_minute: DEFAULT_RATE,
        }
    }
}

/// Applied when a relay runs without a control plane, and when a token somehow
/// carries no rate. Generous — this is a runaway guard, not a product tier.
pub const DEFAULT_RATE: u32 = 6_000;

/// Check a presented token against the channel being joined.
pub fn admit(
    verifier: Option<&TokenVerifier>,
    token: Option<&str>,
    channel: &str,
    now_ms: i64,
) -> Result<Pass, Denied> {
    let Some(verifier) = verifier else {
        return Ok(Pass::open());
    };
    let Some(token) = token.map(str::trim).filter(|token| !token.is_empty()) else {
        return Err(Denied::Missing);
    };

    let claims: Claims = verifier
        .verify(token, Audience::Relay, now_ms)
        .map_err(|err| Denied::Invalid(err.to_string()))?;

    // A relay token that named no channel would be a token for every channel.
    // Refused structurally rather than defaulted.
    if claims.chan.as_deref() != Some(channel) {
        return Err(Denied::WrongChannel);
    }

    Ok(Pass {
        subject: claims.sub,
        messages_per_minute: claims.rate.unwrap_or(DEFAULT_RATE),
    })
}

/// A sliding-window counter, one per connection.
///
/// Not a token bucket: a bucket lets a client bank an hour of silence and then
/// spend it in one burst, which is the exact shape of the flood this is here to
/// stop. A window caps the burst too.
#[derive(Debug)]
pub struct RateLimiter {
    limit: u32,
    window: Duration,
    /// Timestamps within the current window, oldest first.
    seen: std::collections::VecDeque<Instant>,
}

impl RateLimiter {
    pub fn new(messages_per_minute: u32) -> Self {
        Self {
            limit: messages_per_minute.max(1),
            window: Duration::from_secs(60),
            seen: std::collections::VecDeque::new(),
        }
    }

    /// Record one message. `false` means it should be dropped.
    pub fn allow(&mut self, now: Instant) -> bool {
        while let Some(oldest) = self.seen.front() {
            if now.duration_since(*oldest) >= self.window {
                self.seen.pop_front();
            } else {
                break;
            }
        }

        if self.seen.len() as u32 >= self.limit {
            return false;
        }
        self.seen.push_back(now);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use forge_crypto::token::{Role, TokenSigner};

    const NOW: i64 = 1_785_369_600_000;

    fn token(signer: &TokenSigner, channel: &str, rate: Option<u32>) -> String {
        signer
            .mint(&Claims {
                sub: "dev_1".into(),
                aud: Audience::Relay,
                org: "org_1".into(),
                role: Role::Member,
                chan: Some(channel.to_owned()),
                plan: Some("pro".into()),
                rate,
                iat: NOW,
                exp: NOW + 60_000,
            })
            .unwrap()
    }

    #[test]
    fn a_relay_without_a_key_admits_everyone() {
        // The single-user deployment, unchanged.
        let pass = admit(None, None, "forge-abc", NOW).unwrap();
        assert_eq!(pass.subject, "anonymous");
        assert_eq!(pass.messages_per_minute, DEFAULT_RATE);
    }

    #[test]
    fn a_valid_token_admits_and_carries_its_rate() {
        let signer = TokenSigner::generate();
        let verifier = signer.verifier();
        let pass = admit(
            Some(&verifier),
            Some(&token(&signer, "forge-abc", Some(1_200))),
            "forge-abc",
            NOW,
        )
        .unwrap();

        assert_eq!(pass.subject, "dev_1");
        assert_eq!(pass.messages_per_minute, 1_200);
    }

    #[test]
    fn a_token_for_another_channel_is_refused() {
        // The attack worth naming: a legitimate token, aimed somewhere else.
        let signer = TokenSigner::generate();
        let verifier = signer.verifier();
        assert_eq!(
            admit(
                Some(&verifier),
                Some(&token(&signer, "forge-mine", None)),
                "forge-yours",
                NOW
            ),
            Err(Denied::WrongChannel)
        );
    }

    #[test]
    fn no_token_on_a_gated_relay_is_refused() {
        let verifier = TokenSigner::generate().verifier();
        assert_eq!(
            admit(Some(&verifier), None, "forge-abc", NOW),
            Err(Denied::Missing)
        );
        assert_eq!(
            admit(Some(&verifier), Some("   "), "forge-abc", NOW),
            Err(Denied::Missing)
        );
    }

    #[test]
    fn a_token_from_another_control_plane_is_refused() {
        let ours = TokenSigner::generate();
        let theirs = TokenSigner::generate();
        assert!(matches!(
            admit(
                Some(&ours.verifier()),
                Some(&token(&theirs, "forge-abc", None)),
                "forge-abc",
                NOW
            ),
            Err(Denied::Invalid(_))
        ));
    }

    #[test]
    fn an_expired_token_is_refused_which_is_how_revocation_works() {
        // Deleting a device in the web app tells the relay nothing. It stops
        // working because the token runs out and the next one is refused.
        let signer = TokenSigner::generate();
        let verifier = signer.verifier();
        assert!(matches!(
            admit(
                Some(&verifier),
                Some(&token(&signer, "forge-abc", None)),
                "forge-abc",
                NOW + 10 * 60_000
            ),
            Err(Denied::Invalid(_))
        ));
    }

    #[test]
    fn an_api_token_cannot_be_replayed_at_the_relay() {
        let signer = TokenSigner::generate();
        let api = signer
            .mint(&Claims {
                sub: "acc_1".into(),
                aud: Audience::Api,
                org: "org_1".into(),
                role: Role::Owner,
                chan: Some("forge-abc".into()),
                plan: None,
                rate: None,
                iat: NOW,
                exp: NOW + 60_000,
            })
            .unwrap();

        assert!(matches!(
            admit(Some(&signer.verifier()), Some(&api), "forge-abc", NOW),
            Err(Denied::Invalid(_))
        ));
    }

    #[test]
    fn the_rate_limiter_caps_a_burst() {
        let mut limiter = RateLimiter::new(3);
        let now = Instant::now();
        assert!(limiter.allow(now));
        assert!(limiter.allow(now));
        assert!(limiter.allow(now));
        assert!(!limiter.allow(now));
    }

    #[test]
    fn the_window_slides_rather_than_resetting() {
        // The reason this is not a bucket: silence must not bank credit.
        let mut limiter = RateLimiter::new(2);
        let start = Instant::now();
        assert!(limiter.allow(start));
        assert!(limiter.allow(start + Duration::from_secs(30)));
        assert!(!limiter.allow(start + Duration::from_secs(31)));

        // The first message ages out at t=60, freeing exactly one slot.
        assert!(limiter.allow(start + Duration::from_secs(61)));
        assert!(!limiter.allow(start + Duration::from_secs(62)));
    }

    #[test]
    fn a_zero_rate_still_lets_one_message_through() {
        // A misconfigured plan must not produce a connection that is silently
        // mute — that is indistinguishable from the relay being broken.
        let mut limiter = RateLimiter::new(0);
        assert!(limiter.allow(Instant::now()));
    }
}
