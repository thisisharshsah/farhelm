//! Who may join a channel, and how fast they may talk.
//!
//! The relay used to answer both questions with "anyone, as fast as they like",
//! and said so in a comment: *the channel id gets you a seat, not a key*. That
//! is still true of **confidentiality**: everything on a channel is sealed to a
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
//!
//! # Seat channels: no account, still no stranger
//!
//! A channel named `c1-<digest>` is opened by a *seat* rather than a token: a
//! secret sent in the `X-Relay-Seat` header whose SHA-256, base64url, starts
//! with `<digest>`. Companion uses these to reach a Mac from its iPhone app
//! without anyone holding a Farhelm account: the seat is derived from the key
//! in the pairing QR, so only paired devices have it, and the channel name
//! alone (which ends up in logs) opens nothing.
//!
//! The relay checks a hash and learns nothing it can use: the seat is derived
//! separately from the keys that seal the envelopes, so holding it gives a
//! place on the fan-out and no way to read what passes through. Seat channels
//! need their seat on a gated relay and on an open one alike, and a token never
//! opens one: the control plane does not decide who sits on them.

use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use farhelm_crypto::token::{Audience, Claims, TokenVerifier};
use sha2::{Digest as _, Sha256};

/// Names of channels opened by a seat instead of a token.
pub const SEAT_PREFIX: &str = "c1-";

/// The header a seat travels in. A header rather than a query parameter,
/// because a seat does not expire the way a token does, and a URL ends up in
/// more logs than a header.
pub const SEAT_HEADER: &str = "x-relay-seat";

/// Characters of base64url SHA-256 a seat channel's name carries: 132 bits.
const SEAT_DIGEST_LEN: usize = 22;

/// The shortest seat accepted: 32 random bytes in base64url. A short seat
/// could be guessed from its channel's name, which is not a secret.
const SEAT_MIN_LEN: usize = 43;

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
    /// A seat channel, joined without its seat.
    MissingSeat,
    /// A seat that does not open this channel.
    WrongSeat,
}

impl Denied {
    pub fn message(&self) -> String {
        match self {
            Denied::Missing => "this relay requires a token; sign in and reconnect".to_owned(),
            Denied::Invalid(why) => why.clone(),
            Denied::WrongChannel => "that token is not for this channel".to_owned(),
            Denied::MissingSeat => {
                "this channel opens with its seat (the X-Relay-Seat header); pair again".to_owned()
            }
            Denied::WrongSeat => "that seat does not open this channel; pair again".to_owned(),
        }
    }
}

/// What a verified connection is allowed to do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pass {
    /// Who, for the rate limiter and for logs. A device id or a runner id,
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
/// carries no rate. Generous: this is a runaway guard, not a product tier.
pub const DEFAULT_RATE: u32 = 6_000;

/// Check a presented token, or seat, against the channel being joined.
pub fn admit(
    verifier: Option<&TokenVerifier>,
    token: Option<&str>,
    seat: Option<&str>,
    channel: &str,
    now_ms: i64,
) -> Result<Pass, Denied> {
    // Decided by the name alone, before anything else: a seat channel is never
    // opened by a token, and never left open because the relay is.
    if let Some(digest) = channel.strip_prefix(SEAT_PREFIX) {
        return admit_seat(seat, digest);
    }

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

/// The channel a seat opens: `c1-` and the first 22 characters of the
/// base64url SHA-256 of the seat's text.
///
/// The contract with every client that makes seats; Companion's
/// `LinkKey.channel` computes the same, checked against the same fixture.
pub fn seat_channel(seat: &str) -> String {
    let digest = URL_SAFE_NO_PAD.encode(Sha256::digest(seat.as_bytes()));
    format!("{SEAT_PREFIX}{}", &digest[..SEAT_DIGEST_LEN])
}

fn admit_seat(seat: Option<&str>, digest: &str) -> Result<Pass, Denied> {
    let well_formed = digest.len() == SEAT_DIGEST_LEN
        && digest
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_');
    if !well_formed {
        return Err(Denied::Invalid(
            "that is not a seat channel's name".to_owned(),
        ));
    }
    let Some(seat) = seat.map(str::trim).filter(|seat| !seat.is_empty()) else {
        return Err(Denied::MissingSeat);
    };
    if seat.len() < SEAT_MIN_LEN {
        return Err(Denied::Invalid(
            "that seat is too short to be one".to_owned(),
        ));
    }
    // Compared in the open: the name is public and the hash reveals nothing
    // about the seat, so how long the comparison takes tells an attacker
    // nothing either.
    if seat_channel(seat)[SEAT_PREFIX.len()..] != *digest {
        return Err(Denied::WrongSeat);
    }

    Ok(Pass {
        // Metered per channel: everyone on it holds the same seat.
        subject: format!("seat-{}", &digest[..8]),
        messages_per_minute: DEFAULT_RATE,
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
    use farhelm_crypto::token::{Role, TokenSigner};

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
        let pass = admit(None, None, None, "forge-abc", NOW).unwrap();
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
            None,
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
                None,
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
            admit(Some(&verifier), None, None, "forge-abc", NOW),
            Err(Denied::Missing)
        );
        assert_eq!(
            admit(Some(&verifier), Some("   "), None, "forge-abc", NOW),
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
                None,
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
                None,
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
            admit(Some(&signer.verifier()), Some(&api), None, "forge-abc", NOW),
            Err(Denied::Invalid(_))
        ));
    }

    /// The vector Companion's `LinkKey` tests check too: a seat derived from
    /// the key 00 01 02 … 1f, and the channel it opens.
    const FIXTURE_SEAT: &str = "bZRSbJ7BIZBDW7LOkali4wTB-Ph68L9pVn3dyTs5QoE";
    const FIXTURE_CHANNEL: &str = "c1-7YwB0LJANUUwgS1gjVCYMF";

    #[test]
    fn a_seat_names_its_channel_as_the_shared_fixture_says() {
        assert_eq!(seat_channel(FIXTURE_SEAT), FIXTURE_CHANNEL);
    }

    #[test]
    fn a_seat_opens_its_channel_on_a_gated_relay_without_an_account() {
        let verifier = TokenSigner::generate().verifier();
        let pass = admit(
            Some(&verifier),
            None,
            Some(FIXTURE_SEAT),
            FIXTURE_CHANNEL,
            NOW,
        )
        .unwrap();
        assert_eq!(pass.subject, "seat-7YwB0LJA");
        assert_eq!(pass.messages_per_minute, DEFAULT_RATE);
    }

    #[test]
    fn an_open_relay_still_asks_a_seat_channel_for_its_seat() {
        // Otherwise the channel's name, which ends up in logs, would be enough.
        assert_eq!(
            admit(None, None, None, FIXTURE_CHANNEL, NOW),
            Err(Denied::MissingSeat)
        );
        assert!(admit(None, None, Some(FIXTURE_SEAT), FIXTURE_CHANNEL, NOW).is_ok());
    }

    #[test]
    fn another_seat_is_refused() {
        let other = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        assert_eq!(
            admit(None, None, Some(other), FIXTURE_CHANNEL, NOW),
            Err(Denied::WrongSeat)
        );
    }

    #[test]
    fn a_token_never_opens_a_seat_channel() {
        // Even one the control plane signed for exactly this name.
        let signer = TokenSigner::generate();
        let verifier = signer.verifier();
        assert_eq!(
            admit(
                Some(&verifier),
                Some(&token(&signer, FIXTURE_CHANNEL, None)),
                None,
                FIXTURE_CHANNEL,
                NOW
            ),
            Err(Denied::MissingSeat)
        );
    }

    #[test]
    fn a_short_seat_is_refused_even_when_it_matches() {
        // A seat short enough to guess from the channel's name is no seat.
        let short = "abc";
        assert!(matches!(
            admit(None, None, Some(short), &seat_channel(short), NOW),
            Err(Denied::Invalid(_))
        ));
    }

    #[test]
    fn a_malformed_seat_channel_name_is_refused() {
        for name in [
            "c1-",
            "c1-short",
            "c1-7YwB0LJANUUwgS1gjVCYMFx",
            "c1-7YwB0LJANUUwgS1gjVCY.F",
        ] {
            assert!(
                matches!(
                    admit(None, None, Some(FIXTURE_SEAT), name, NOW),
                    Err(Denied::Invalid(_))
                ),
                "{name} should be refused"
            );
        }
        // Not ASCII: refused before anything slices it.
        assert!(matches!(
            admit(None, None, Some(FIXTURE_SEAT), "c1-ééééééééééé", NOW),
            Err(Denied::Invalid(_))
        ));
    }

    #[test]
    fn a_seat_does_not_open_a_token_channel() {
        // The other direction: a seat is no substitute for a token.
        let verifier = TokenSigner::generate().verifier();
        assert_eq!(
            admit(Some(&verifier), None, Some(FIXTURE_SEAT), "forge-abc", NOW),
            Err(Denied::Missing)
        );
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
        // mute; that is indistinguishable from the relay being broken.
        let mut limiter = RateLimiter::new(0);
        assert!(limiter.allow(Instant::now()));
    }
}
