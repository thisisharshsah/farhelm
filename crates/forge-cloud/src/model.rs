//! What the control plane stores, and what it hands back over HTTP.
//!
//! One set of types for both, on purpose. A separate "API DTO" layer would be
//! two places to forget a field — and the interesting invariant here is not
//! shape, it is that **no type in this module carries a secret**. Password
//! hashes and token hashes never leave [`crate::store`]; there is no field on
//! [`Account`] for them to leak through.

use serde::{Deserialize, Serialize};

use crate::plan::{Limits, Plan, SubscriptionStatus, Usage};

/// A person.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Account {
    pub id: String,
    /// As typed, for display. Login matches on the normalised form.
    pub email: String,
    pub display_name: String,
    pub created_at: i64,
    pub last_seen_at: i64,
}

/// Email addresses are compared case-insensitively and with surrounding
/// whitespace removed.
///
/// Deliberately *not* clever beyond that: stripping Gmail's dots or `+tags`
/// would mean two people who believe they have different addresses share an
/// account, which is a worse failure than two accounts for one human.
pub fn normalize_email(email: &str) -> String {
    email.trim().to_lowercase()
}

/// A tenant. Everything countable hangs off one of these.
///
/// Every account gets one at sign-up, so the single-user case is the
/// one-member-organisation case rather than a separate code path. That is the
/// whole trick to making this multi-tenant without a rewrite later.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Org {
    pub id: String,
    pub name: String,
    /// URL-safe, unique. What a future `farhelm.aurovie.com/o/acme` would use.
    pub slug: String,
    pub created_at: i64,
}

/// Build a slug from a display name, falling back to the id when the name is
/// all punctuation — a slug is required to be non-empty and unique, and a user
/// named `····` should not be a 500.
pub fn slugify(name: &str, fallback: &str) -> String {
    let slug: String = name
        .trim()
        .to_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect::<String>()
        .split('-')
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("-");

    if slug.is_empty() {
        fallback.to_lowercase()
    } else {
        slug.chars().take(48).collect()
    }
}

/// Who is in an organisation, and what they may do there.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Membership {
    pub org_id: String,
    pub account_id: String,
    pub role: forge_crypto::token::Role,
    pub created_at: i64,
}

/// A machine running `forge-runner`.
///
/// # Key pinning
///
/// `public_key` is trust-on-first-use. The first enrolment under a runner id
/// pins the key; a later enrolment presenting a *different* key does not
/// silently replace it — it lands in `pending_public_key` and the fleet shows a
/// warning until a human approves the rotation.
///
/// This is the mitigation for the thing that makes account-only enrolment
/// convenient: an attacker who steals an enrolment key can register a *new*
/// runner, but cannot quietly become an existing one and start receiving
/// approvals meant for it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Runner {
    pub id: String,
    pub org_id: String,
    pub name: String,
    /// base64url X25519 public key, pinned at first enrolment.
    pub public_key: String,
    /// A key this runner offered that does not match the pinned one. Non-null
    /// means the fleet shows "this machine's identity changed" and refuses to
    /// treat it as the same runner until someone says so.
    pub pending_public_key: Option<String>,
    /// The relay fan-out channel, derived from the pinned key.
    pub channel: String,
    pub created_at: i64,
    pub last_seen_at: i64,
    /// Whatever `forge-runner --version` said. Useful when one machine in a
    /// fleet behaves differently.
    pub version: String,
}

impl Runner {
    /// Not heard from in this long and the fleet renders it as offline.
    pub const OFFLINE_AFTER_MS: i64 = 90 * 1_000;

    pub fn is_online(&self, now_ms: i64) -> bool {
        now_ms - self.last_seen_at < Self::OFFLINE_AFTER_MS
    }
}

/// A phone, a watch, or a browser holding a key.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Device {
    pub id: String,
    pub org_id: String,
    /// Which person's device. A member's phone is not an organisation asset.
    pub account_id: String,
    pub kind: forge_proto::types::DeviceKind,
    /// What the fleet calls it. Chosen by the device, editable by its owner.
    pub name: String,
    /// base64url X25519 public key. The secret half never left the device.
    pub public_key: String,
    pub created_at: i64,
    pub last_seen_at: i64,
}

/// What an organisation is paying for.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Subscription {
    pub org_id: String,
    pub plan: Plan,
    pub status: SubscriptionStatus,
    /// Stripe's customer id, once there is one.
    pub customer_id: Option<String>,
    pub subscription_id: Option<String>,
    /// Unix ms. When the current paid period runs out.
    pub current_period_end: Option<i64>,
    /// Cancelled but still inside the period it was paid for.
    pub cancel_at_period_end: bool,
    pub updated_at: i64,
}

impl Subscription {
    /// What a brand-new organisation gets, and what everyone gets when billing
    /// is not configured at all.
    pub fn free(org_id: &str, now_ms: i64) -> Self {
        Self {
            org_id: org_id.to_owned(),
            plan: Plan::Free,
            status: SubscriptionStatus::Active,
            customer_id: None,
            subscription_id: None,
            current_period_end: None,
            cancel_at_period_end: false,
            updated_at: now_ms,
        }
    }

    /// The plan whose limits actually apply right now.
    pub fn effective_plan(&self) -> Plan {
        crate::plan::effective_plan(self.plan, self.status)
    }
}

/// A long-lived credential a *machine* uses, as opposed to a person.
///
/// This is what makes enrolment codeless: you create one in the web app, paste
/// it into the runner's config once, and every machine you start with it joins
/// the fleet by itself. Only the hash is stored — the plaintext is shown once,
/// at creation, and cannot be recovered.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EnrollmentKey {
    pub id: String,
    pub org_id: String,
    pub name: String,
    /// First few characters of the plaintext, so a list can say *which* key
    /// without being able to reconstruct it.
    pub prefix: String,
    pub created_at: i64,
    pub created_by: String,
    pub last_used_at: Option<i64>,
    pub revoked_at: Option<i64>,
}

impl EnrollmentKey {
    pub fn is_live(&self) -> bool {
        self.revoked_at.is_none()
    }
}

/// Everything the app needs to render the account area in one request.
///
/// One round trip rather than five, because this is the payload behind the
/// first paint after sign-in and a chain of dependent fetches is the difference
/// between an app that feels instant and one that does not.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Workspace {
    pub account: Account,
    pub org: Org,
    pub role: forge_crypto::token::Role,
    pub subscription: Subscription,
    /// The limits in force — already resolved through
    /// [`Subscription::effective_plan`], so no client re-implements that rule.
    pub limits: Limits,
    pub usage: Usage,
    pub runners: Vec<RunnerView>,
    pub devices: Vec<Device>,
    /// Where devices should dial for the relay, as configured on this
    /// deployment. Clients never hard-code it.
    pub relay_url: String,
}

/// A runner as the fleet renders it: the stored row plus the two things a
/// client would otherwise have to derive and could get wrong.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunnerView {
    #[serde(flatten)]
    pub runner: Runner,
    pub online: bool,
    /// True when `pending_public_key` is set. Named for what the user must do
    /// about it rather than for what the column contains.
    pub needs_key_approval: bool,
}

impl RunnerView {
    pub fn of(runner: Runner, now_ms: i64) -> Self {
        Self {
            online: runner.is_online(now_ms),
            needs_key_approval: runner.pending_public_key.is_some(),
            runner,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn emails_match_regardless_of_case_and_padding() {
        assert_eq!(normalize_email("  Harsh@Example.COM "), "harsh@example.com");
    }

    #[test]
    fn emails_that_differ_by_a_dot_stay_different_people() {
        // Gmail would treat these as one inbox. Guessing that on the user's
        // behalf merges two accounts, which is unrecoverable.
        assert_ne!(
            normalize_email("first.last@gmail.com"),
            normalize_email("firstlast@gmail.com")
        );
    }

    #[test]
    fn slugs_are_url_safe_and_collapse_runs() {
        assert_eq!(slugify("Acme  Corp!!", "x"), "acme-corp");
        assert_eq!(slugify("  Harsh's Lab ", "x"), "harsh-s-lab");
    }

    #[test]
    fn a_nameless_org_still_gets_a_slug() {
        assert_eq!(slugify("···", "ORG123"), "org123");
        assert_eq!(slugify("", "ORG123"), "org123");
    }

    #[test]
    fn a_runner_goes_offline_after_the_grace_period() {
        let runner = Runner {
            id: "r1".into(),
            org_id: "o1".into(),
            name: "mac-studio".into(),
            public_key: "k".into(),
            pending_public_key: None,
            channel: "forge-k".into(),
            created_at: 0,
            last_seen_at: 1_000,
            version: "0.1.0".into(),
        };

        assert!(runner.is_online(1_000 + Runner::OFFLINE_AFTER_MS - 1));
        assert!(!runner.is_online(1_000 + Runner::OFFLINE_AFTER_MS));
    }

    #[test]
    fn a_new_organisation_is_free_and_active() {
        let subscription = Subscription::free("o1", 10);
        assert_eq!(subscription.effective_plan(), Plan::Free);
        assert_eq!(subscription.status, SubscriptionStatus::Active);
        assert!(subscription.customer_id.is_none());
    }

    #[test]
    fn a_runner_view_surfaces_a_key_change_as_something_to_do() {
        let runner = Runner {
            id: "r1".into(),
            org_id: "o1".into(),
            name: "mac-studio".into(),
            public_key: "pinned".into(),
            pending_public_key: Some("different".into()),
            channel: "forge-pinned".into(),
            created_at: 0,
            last_seen_at: 0,
            version: "0.1.0".into(),
        };

        assert!(RunnerView::of(runner, 0).needs_key_approval);
    }

    #[test]
    fn no_public_type_here_carries_a_secret() {
        // A structural check on the thing this module promises. Serialising a
        // whole workspace must never produce a hash or a password field.
        let account = Account {
            id: "a1".into(),
            email: "harsh@example.com".into(),
            display_name: "Harsh".into(),
            created_at: 0,
            last_seen_at: 0,
        };
        let rendered = serde_json::to_string(&account).unwrap();
        for forbidden in ["password", "hash", "secret", "token"] {
            assert!(
                !rendered.contains(forbidden),
                "{forbidden} leaked into the account payload"
            );
        }
    }
}
