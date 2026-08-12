//! The two kinds of secret this service holds, and why they are hashed
//! differently.
//!
//! - **Passwords** are low-entropy and chosen by humans, so they get Argon2id
//!   with a memory cost that makes offline guessing expensive.
//! - **Bearer tokens** — enrolment keys, refresh tokens — are 256 bits from the
//!   OS CSPRNG. There is nothing to guess, so the only requirement is that a
//!   database dump does not yield usable credentials, and that lookup is a
//!   single indexed query. SHA-256 gives both; Argon2 here would mean a
//!   400ms hash on every API call to no benefit.
//!
//! Getting that backwards in either direction is a real bug, which is why they
//! are two clearly named functions rather than one `hash()`.

use argon2::password_hash::{PasswordHash, PasswordHasher as _, PasswordVerifier as _, SaltString};
use argon2::{Algorithm, Argon2, Params, Version};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use rand_core::RngCore as _;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SecretError {
    /// The password did not meet [`MIN_PASSWORD_LEN`].
    TooShort,
    /// A stored hash could not be parsed. Corruption, or a hash written by a
    /// different algorithm — either way, not a login.
    Unusable,
}

impl std::fmt::Display for SecretError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SecretError::TooShort => {
                write!(f, "password must be at least {MIN_PASSWORD_LEN} characters")
            }
            SecretError::Unusable => f.write_str("stored credential is unusable"),
        }
    }
}

impl std::error::Error for SecretError {}

/// Length, not composition rules. Character-class requirements measurably push
/// people towards `Password1!`; length is the thing that actually helps.
pub const MIN_PASSWORD_LEN: usize = 10;

/// Argon2id, tuned for a server that also does other things.
///
/// 19 MiB / t=2 / p=1 is the OWASP second-choice profile — chosen over the
/// 46 MiB one because this is expected to run on a small VPS alongside the
/// relay, and a login that swaps is a login that times out.
fn argon2() -> Argon2<'static> {
    let params = Params::new(19 * 1024, 2, 1, None).expect("static Argon2 params are valid");
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
}

/// Hash a password for storage. The output is a PHC string, so it carries its
/// own parameters and a future re-tune does not invalidate existing hashes.
pub fn hash_password(password: &str) -> Result<String, SecretError> {
    if password.chars().count() < MIN_PASSWORD_LEN {
        return Err(SecretError::TooShort);
    }
    let salt = SaltString::generate(&mut rand_core::OsRng);
    Ok(argon2()
        .hash_password(password.as_bytes(), &salt)
        .map_err(|_| SecretError::Unusable)?
        .to_string())
}

/// Check a password against a stored hash.
///
/// Returns `false` for a wrong password and `Err` only when the *stored* value
/// is broken, so a corrupt row cannot be mistaken for a successful login.
pub fn verify_password(password: &str, stored: &str) -> Result<bool, SecretError> {
    let parsed = PasswordHash::new(stored).map_err(|_| SecretError::Unusable)?;
    Ok(argon2()
        .verify_password(password.as_bytes(), &parsed)
        .is_ok())
}

/// 256 bits from the OS CSPRNG, base64url.
pub fn random_secret() -> String {
    let mut bytes = [0u8; 32];
    rand_core::OsRng.fill_bytes(&mut bytes);
    B64.encode(bytes)
}

/// The prefix every enrolment key carries, so one found in a log or a paste is
/// recognisable as a RelayForge credential and can be revoked.
pub const ENROLLMENT_KEY_PREFIX: &str = "frg_";

/// Mint an enrolment key. Returned once, in plaintext; only [`hash_token`] of it
/// is ever stored.
pub fn new_enrollment_key() -> String {
    format!("{ENROLLMENT_KEY_PREFIX}{}", random_secret())
}

/// How much of a key is shown in a list. Enough to tell two apart, far short of
/// enough to use.
pub const DISPLAYED_PREFIX_LEN: usize = 12;

pub fn displayed_prefix(token: &str) -> String {
    token.chars().take(DISPLAYED_PREFIX_LEN).collect()
}

/// Hash a high-entropy bearer token for storage and lookup.
pub fn hash_token(token: &str) -> String {
    use sha2::{Digest as _, Sha256};
    B64.encode(Sha256::digest(token.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_password_verifies_against_its_own_hash() {
        let stored = hash_password("correct horse battery").unwrap();
        assert!(verify_password("correct horse battery", &stored).unwrap());
        assert!(!verify_password("correct horse batteries", &stored).unwrap());
    }

    #[test]
    fn the_same_password_hashes_differently_every_time() {
        // Salted. Two accounts with the same password must not be visibly the
        // same account in a database dump.
        let first = hash_password("correct horse battery").unwrap();
        let second = hash_password("correct horse battery").unwrap();
        assert_ne!(first, second);
    }

    #[test]
    fn a_hash_never_contains_the_password() {
        let stored = hash_password("hunter2-hunter2").unwrap();
        assert!(!stored.contains("hunter2"));
    }

    #[test]
    fn a_stored_hash_declares_argon2id() {
        // The PHC string carries its parameters, which is what lets the cost be
        // raised later without locking anyone out.
        let stored = hash_password("correct horse battery").unwrap();
        assert!(stored.starts_with("$argon2id$"));
    }

    #[test]
    fn a_short_password_is_refused_before_it_is_hashed() {
        assert_eq!(hash_password("short").unwrap_err(), SecretError::TooShort);
        // Exactly at the boundary is allowed.
        assert!(hash_password(&"a".repeat(MIN_PASSWORD_LEN)).is_ok());
    }

    #[test]
    fn a_corrupt_stored_hash_is_an_error_not_a_silent_pass() {
        assert_eq!(
            verify_password("anything", "not-a-phc-string"),
            Err(SecretError::Unusable)
        );
        assert_eq!(verify_password("anything", ""), Err(SecretError::Unusable));
    }

    #[test]
    fn secrets_do_not_repeat() {
        let secrets: std::collections::HashSet<String> =
            (0..256).map(|_| random_secret()).collect();
        assert_eq!(secrets.len(), 256);
    }

    #[test]
    fn an_enrollment_key_is_recognisable_and_long() {
        let key = new_enrollment_key();
        assert!(key.starts_with(ENROLLMENT_KEY_PREFIX));
        // 32 bytes → 43 base64url characters, plus the prefix.
        assert!(key.len() >= ENROLLMENT_KEY_PREFIX.len() + 43);
    }

    #[test]
    fn a_displayed_prefix_cannot_be_used_as_a_key() {
        let key = new_enrollment_key();
        let shown = displayed_prefix(&key);
        assert!(key.starts_with(&shown));
        assert_ne!(hash_token(&shown), hash_token(&key));
        assert!(shown.len() < key.len() / 2);
    }

    #[test]
    fn token_hashing_is_deterministic_so_lookup_is_one_query() {
        let key = new_enrollment_key();
        assert_eq!(hash_token(&key), hash_token(&key));
        assert_ne!(hash_token(&key), hash_token(&new_enrollment_key()));
        assert!(!hash_token(&key).contains(&key));
    }
}
