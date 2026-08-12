//! Subscriptions, and Stripe as the one implementation of them.
//!
//! Two things are separated here on purpose:
//!
//! - **Deciding what a webhook means** — [`interpret`] and
//!   [`verify_signature`] — is pure. No network, no clock beyond a passed-in
//!   `now_ms`. That is what makes the billing state machine testable without a
//!   Stripe account, which matters because billing bugs are discovered by users
//!   and paid for in refunds.
//! - **Talking to Stripe** — [`Stripe`] — is a thin form-encoded client. No SDK:
//!   this uses four endpoints, and an SDK would be a large dependency plus its
//!   own opinion about async runtimes.
//!
//! # When Stripe is not configured
//!
//! [`Billing::Disabled`] is a first-class state, not a degraded one. Every
//! organisation is on [`Plan::Free`], the upgrade buttons say so, and nothing
//! anywhere has to check for a null client. A self-hosted deployment is expected
//! to run this way forever.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::plan::{Plan, SubscriptionStatus};

/// Where Stripe's REST API lives. Overridable so tests can point at a stub.
const STRIPE_API: &str = "https://api.stripe.com";

#[derive(Debug)]
pub enum BillingError {
    /// Billing is not configured on this deployment.
    Disabled,
    /// The signature on a webhook did not verify, or its timestamp was outside
    /// the tolerance.
    BadSignature,
    /// Stripe answered, but not with what was asked for.
    Upstream(String),
    /// No price is configured for the plan the user asked for.
    NoSuchPrice(Plan),
}

impl std::fmt::Display for BillingError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BillingError::Disabled => f.write_str("billing is not configured on this deployment"),
            BillingError::BadSignature => f.write_str("webhook signature did not verify"),
            BillingError::Upstream(what) => write!(f, "payment provider: {what}"),
            BillingError::NoSuchPrice(plan) => {
                write!(f, "no price is configured for the {plan} plan")
            }
        }
    }
}

impl std::error::Error for BillingError {}

/// How the deployment is configured to take money, if at all.
pub enum Billing {
    Disabled,
    Stripe(Box<Stripe>),
}

impl Billing {
    /// Read the environment. Absent keys mean [`Billing::Disabled`] — an
    /// explicit, supported configuration rather than a misconfiguration.
    pub fn from_env() -> Self {
        let Ok(secret_key) = std::env::var("STRIPE_SECRET_KEY") else {
            return Billing::Disabled;
        };
        let webhook_secret = std::env::var("STRIPE_WEBHOOK_SECRET").unwrap_or_default();

        let mut prices = HashMap::new();
        if let Ok(price) = std::env::var("STRIPE_PRICE_PRO") {
            prices.insert(Plan::Pro, price);
        }
        if let Ok(price) = std::env::var("STRIPE_PRICE_TEAM") {
            prices.insert(Plan::Team, price);
        }

        Billing::Stripe(Box::new(Stripe {
            secret_key,
            webhook_secret,
            prices,
            api_base: std::env::var("STRIPE_API_BASE").unwrap_or_else(|_| STRIPE_API.to_owned()),
            http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(15))
                .build()
                .unwrap_or_default(),
        }))
    }

    pub fn is_enabled(&self) -> bool {
        matches!(self, Billing::Stripe(_))
    }

    /// The plans a user can actually buy here. Free is always available and is
    /// never in this list.
    pub fn purchasable(&self) -> Vec<Plan> {
        match self {
            Billing::Disabled => Vec::new(),
            Billing::Stripe(stripe) => Plan::ALL
                .iter()
                .copied()
                .filter(|plan| stripe.prices.contains_key(plan))
                .collect(),
        }
    }

    fn stripe(&self) -> Result<&Stripe, BillingError> {
        match self {
            Billing::Disabled => Err(BillingError::Disabled),
            Billing::Stripe(stripe) => Ok(stripe),
        }
    }

    /// A hosted checkout page for `plan`, scoped to one organisation.
    pub async fn checkout_url(
        &self,
        plan: Plan,
        org_id: &str,
        customer_id: Option<&str>,
        email: &str,
        success_url: &str,
        cancel_url: &str,
    ) -> Result<String, BillingError> {
        self.stripe()?
            .checkout(plan, org_id, customer_id, email, success_url, cancel_url)
            .await
    }

    /// Stripe's own page for changing a card, cancelling, or downloading
    /// invoices. Deliberately not reimplemented: card handling that never
    /// touches this server is card handling that cannot leak from it.
    pub async fn portal_url(
        &self,
        customer_id: &str,
        return_url: &str,
    ) -> Result<String, BillingError> {
        self.stripe()?.portal(customer_id, return_url).await
    }

    /// Verify a webhook and say what it means, or `None` for an event this
    /// system does not care about.
    pub fn handle_webhook(
        &self,
        payload: &[u8],
        signature_header: &str,
        now_ms: i64,
    ) -> Result<Option<SubscriptionChange>, BillingError> {
        let stripe = self.stripe()?;
        verify_signature(payload, signature_header, &stripe.webhook_secret, now_ms)?;
        let event: serde_json::Value = serde_json::from_slice(payload)
            .map_err(|err| BillingError::Upstream(err.to_string()))?;
        Ok(interpret(&event, &stripe.prices))
    }
}

/// What a webhook told us to do, in this system's own terms.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SubscriptionChange {
    /// From `client_reference_id` or subscription metadata. The link back to a
    /// tenant, and the reason both are set when checkout is created.
    pub org_id: Option<String>,
    pub customer_id: Option<String>,
    pub subscription_id: Option<String>,
    pub plan: Plan,
    pub status: SubscriptionStatus,
    /// Unix ms.
    pub current_period_end: Option<i64>,
    pub cancel_at_period_end: bool,
}

/// A webhook older than this is refused, so a captured request cannot be
/// replayed later. Stripe's own recommendation.
const WEBHOOK_TOLERANCE_MS: i64 = 5 * 60 * 1_000;

/// Check the `Stripe-Signature` header against the raw body.
///
/// The body must be the **exact bytes received** — deserialising and
/// re-serialising changes key order and whitespace and breaks the signature,
/// which is why the handler takes `Bytes` rather than `Json`.
pub fn verify_signature(
    payload: &[u8],
    header: &str,
    secret: &str,
    now_ms: i64,
) -> Result<(), BillingError> {
    use hmac::{Hmac, Mac};
    use sha2::Sha256;

    if secret.is_empty() {
        return Err(BillingError::BadSignature);
    }

    let mut timestamp: Option<i64> = None;
    let mut signatures: Vec<&str> = Vec::new();
    for part in header.split(',') {
        let Some((key, value)) = part.trim().split_once('=') else {
            continue;
        };
        match key {
            "t" => timestamp = value.parse().ok(),
            "v1" => signatures.push(value),
            _ => {}
        }
    }

    let Some(timestamp) = timestamp else {
        return Err(BillingError::BadSignature);
    };
    if (now_ms - timestamp * 1_000).abs() > WEBHOOK_TOLERANCE_MS {
        return Err(BillingError::BadSignature);
    }

    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes())
        .map_err(|_| BillingError::BadSignature)?;
    mac.update(timestamp.to_string().as_bytes());
    mac.update(b".");
    mac.update(payload);
    let expected = hex(&mac.finalize().into_bytes());

    // Constant-time over the whole list: an early return on the first match
    // would leak which signature matched, and `==` on a String is not constant
    // time to begin with.
    let matched = signatures.iter().fold(false, |found, candidate| {
        found | constant_time_eq(candidate, &expected)
    });

    if matched {
        Ok(())
    } else {
        Err(BillingError::BadSignature)
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn constant_time_eq(left: &str, right: &str) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.bytes()
        .zip(right.bytes())
        .fold(0u8, |acc, (a, b)| acc | (a ^ b))
        == 0
}

/// Turn a Stripe event into a [`SubscriptionChange`], or `None`.
///
/// Only four event types matter. Everything else — invoices, payment intents,
/// charges — is Stripe's business, and reacting to it here would mean two
/// sources of truth for what plan someone is on.
pub fn interpret(
    event: &serde_json::Value,
    prices: &HashMap<Plan, String>,
) -> Option<SubscriptionChange> {
    let kind = event.get("type")?.as_str()?;
    let object = event.get("data")?.get("object")?;

    match kind {
        // The user finished paying. `client_reference_id` is the org, set when
        // the session was created — the only point in the flow where this
        // server knows both sides.
        "checkout.session.completed" => Some(SubscriptionChange {
            org_id: object
                .get("client_reference_id")
                .and_then(|value| value.as_str())
                .map(str::to_owned),
            customer_id: string_or_id(object.get("customer")),
            subscription_id: string_or_id(object.get("subscription")),
            // The session does not carry the price, so the plan is confirmed by
            // the `customer.subscription.*` event that follows within seconds.
            // Until then, treat it as the cheapest paid plan rather than
            // guessing high and giving away Team.
            plan: prices.keys().copied().min().unwrap_or(Plan::Pro),
            status: SubscriptionStatus::Active,
            current_period_end: None,
            cancel_at_period_end: false,
        }),

        "customer.subscription.created" | "customer.subscription.updated" => {
            Some(SubscriptionChange {
                org_id: object
                    .get("metadata")
                    .and_then(|meta| meta.get("org_id"))
                    .and_then(|value| value.as_str())
                    .map(str::to_owned),
                customer_id: string_or_id(object.get("customer")),
                subscription_id: object
                    .get("id")
                    .and_then(|value| value.as_str())
                    .map(str::to_owned),
                plan: plan_of(object, prices).unwrap_or(Plan::Free),
                status: status_of(object.get("status").and_then(|value| value.as_str())),
                current_period_end: object
                    .get("current_period_end")
                    .and_then(|value| value.as_i64())
                    .map(|seconds| seconds * 1_000),
                cancel_at_period_end: object
                    .get("cancel_at_period_end")
                    .and_then(|value| value.as_bool())
                    .unwrap_or(false),
            })
        }

        "customer.subscription.deleted" => Some(SubscriptionChange {
            org_id: object
                .get("metadata")
                .and_then(|meta| meta.get("org_id"))
                .and_then(|value| value.as_str())
                .map(str::to_owned),
            customer_id: string_or_id(object.get("customer")),
            subscription_id: object
                .get("id")
                .and_then(|value| value.as_str())
                .map(str::to_owned),
            plan: Plan::Free,
            status: SubscriptionStatus::Canceled,
            current_period_end: None,
            cancel_at_period_end: false,
        }),

        _ => None,
    }
}

/// Stripe sends related objects either as an id or, when expanded, as an object
/// with one. Accept both rather than depending on expansion settings.
fn string_or_id(value: Option<&serde_json::Value>) -> Option<String> {
    let value = value?;
    value
        .as_str()
        .map(str::to_owned)
        .or_else(|| value.get("id")?.as_str().map(str::to_owned))
}

fn plan_of(subscription: &serde_json::Value, prices: &HashMap<Plan, String>) -> Option<Plan> {
    let price_id = subscription
        .get("items")?
        .get("data")?
        .as_array()?
        .first()?
        .get("price")?
        .get("id")?
        .as_str()?;

    prices
        .iter()
        .find(|(_, configured)| configured.as_str() == price_id)
        .map(|(plan, _)| *plan)
}

/// Stripe's dozen statuses, collapsed to the three this system acts on.
///
/// `trialing` counts as active — a trial that does not work is not a trial.
/// `unpaid` counts as cancelled: past_due is the grace period, unpaid is what
/// Stripe says after the grace period has run out.
fn status_of(status: Option<&str>) -> SubscriptionStatus {
    match status {
        Some("active") | Some("trialing") => SubscriptionStatus::Active,
        Some("past_due") | Some("incomplete") => SubscriptionStatus::PastDue,
        _ => SubscriptionStatus::Canceled,
    }
}

/* --------------------------------------------------------------- the client */

pub struct Stripe {
    secret_key: String,
    webhook_secret: String,
    prices: HashMap<Plan, String>,
    api_base: String,
    http: reqwest::Client,
}

impl std::fmt::Debug for Stripe {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Stripe")
            .field("api_base", &self.api_base)
            .field("plans", &self.prices.keys().collect::<Vec<_>>())
            .field("secret_key", &"<redacted>")
            .finish()
    }
}

impl Stripe {
    async fn checkout(
        &self,
        plan: Plan,
        org_id: &str,
        customer_id: Option<&str>,
        email: &str,
        success_url: &str,
        cancel_url: &str,
    ) -> Result<String, BillingError> {
        let price = self
            .prices
            .get(&plan)
            .ok_or(BillingError::NoSuchPrice(plan))?;

        let mut form: Vec<(String, String)> = vec![
            ("mode".into(), "subscription".into()),
            ("line_items[0][price]".into(), price.clone()),
            ("line_items[0][quantity]".into(), "1".into()),
            ("success_url".into(), success_url.into()),
            ("cancel_url".into(), cancel_url.into()),
            // Both, deliberately: `client_reference_id` comes back on the
            // checkout event, the metadata comes back on every subscription
            // event afterwards. Setting only one leaves a webhook that cannot
            // find its tenant.
            ("client_reference_id".into(), org_id.into()),
            ("subscription_data[metadata][org_id]".into(), org_id.into()),
            ("allow_promotion_codes".into(), "true".into()),
        ];

        match customer_id {
            Some(customer) => form.push(("customer".into(), customer.into())),
            None => form.push(("customer_email".into(), email.into())),
        }

        self.post("/v1/checkout/sessions", &form).await
    }

    async fn portal(&self, customer_id: &str, return_url: &str) -> Result<String, BillingError> {
        let form = vec![
            ("customer".to_owned(), customer_id.to_owned()),
            ("return_url".to_owned(), return_url.to_owned()),
        ];
        self.post("/v1/billing_portal/sessions", &form).await
    }

    /// Every call this makes returns an object with a `url`, so the shared part
    /// is the whole request.
    async fn post(&self, path: &str, form: &[(String, String)]) -> Result<String, BillingError> {
        let response = self
            .http
            .post(format!("{}{path}", self.api_base))
            .bearer_auth(&self.secret_key)
            .form(form)
            .send()
            .await
            .map_err(|err| BillingError::Upstream(err.to_string()))?;

        let status = response.status();
        let body: serde_json::Value = response
            .json()
            .await
            .map_err(|err| BillingError::Upstream(err.to_string()))?;

        if !status.is_success() {
            let message = body
                .get("error")
                .and_then(|error| error.get("message"))
                .and_then(|message| message.as_str())
                .unwrap_or("request failed");
            return Err(BillingError::Upstream(message.to_owned()));
        }

        body.get("url")
            .and_then(|url| url.as_str())
            .map(str::to_owned)
            .ok_or_else(|| BillingError::Upstream("no url in response".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_785_369_600_000;

    fn prices() -> HashMap<Plan, String> {
        HashMap::from([
            (Plan::Pro, "price_pro".to_owned()),
            (Plan::Team, "price_team".to_owned()),
        ])
    }

    fn signed(payload: &[u8], secret: &str, timestamp: i64) -> String {
        use hmac::{Hmac, Mac};
        use sha2::Sha256;
        let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).unwrap();
        mac.update(timestamp.to_string().as_bytes());
        mac.update(b".");
        mac.update(payload);
        format!("t={timestamp},v1={}", hex(&mac.finalize().into_bytes()))
    }

    #[test]
    fn a_correctly_signed_webhook_verifies() {
        let payload = br#"{"type":"ping"}"#;
        let header = signed(payload, "whsec_test", NOW / 1_000);
        assert!(verify_signature(payload, &header, "whsec_test", NOW).is_ok());
    }

    #[test]
    fn a_webhook_signed_with_the_wrong_secret_is_refused() {
        let payload = br#"{"type":"ping"}"#;
        let header = signed(payload, "whsec_attacker", NOW / 1_000);
        assert!(matches!(
            verify_signature(payload, &header, "whsec_test", NOW),
            Err(BillingError::BadSignature)
        ));
    }

    #[test]
    fn a_tampered_body_is_refused() {
        // The attack this stops: rewrite the plan to Team on the way in.
        let payload = br#"{"type":"customer.subscription.updated"}"#;
        let header = signed(payload, "whsec_test", NOW / 1_000);
        assert!(matches!(
            verify_signature(br#"{"type":"tampered"}"#, &header, "whsec_test", NOW),
            Err(BillingError::BadSignature)
        ));
    }

    #[test]
    fn a_replayed_webhook_is_refused_once_it_is_stale() {
        let payload = br#"{"type":"ping"}"#;
        let header = signed(payload, "whsec_test", NOW / 1_000);
        assert!(
            verify_signature(
                payload,
                &header,
                "whsec_test",
                NOW + WEBHOOK_TOLERANCE_MS + 1_000
            )
            .is_err()
        );
    }

    #[test]
    fn a_webhook_is_refused_when_no_secret_is_configured() {
        // The dangerous default: an empty secret must not mean "skip the check".
        let payload = br#"{"type":"ping"}"#;
        let header = signed(payload, "", NOW / 1_000);
        assert!(matches!(
            verify_signature(payload, &header, "", NOW),
            Err(BillingError::BadSignature)
        ));
    }

    #[test]
    fn a_malformed_signature_header_is_refused() {
        for header in ["", "nonsense", "t=abc,v1=def", "v1=deadbeef"] {
            assert!(
                verify_signature(b"{}", header, "whsec_test", NOW).is_err(),
                "accepted {header:?}"
            );
        }
    }

    #[test]
    fn a_subscription_update_names_the_plan_from_its_price() {
        let event = serde_json::json!({
            "type": "customer.subscription.updated",
            "data": {"object": {
                "id": "sub_1",
                "customer": "cus_1",
                "status": "active",
                "cancel_at_period_end": false,
                "current_period_end": 1_800_000_000i64,
                "metadata": {"org_id": "org_1"},
                "items": {"data": [{"price": {"id": "price_team"}}]}
            }}
        });

        let change = interpret(&event, &prices()).unwrap();
        assert_eq!(change.plan, Plan::Team);
        assert_eq!(change.org_id.as_deref(), Some("org_1"));
        assert_eq!(change.customer_id.as_deref(), Some("cus_1"));
        assert_eq!(change.status, SubscriptionStatus::Active);
        assert_eq!(change.current_period_end, Some(1_800_000_000_000));
    }

    #[test]
    fn a_price_this_deployment_does_not_know_falls_back_to_free() {
        // Somebody's Stripe dashboard has a price we were never told about.
        // Serving Team limits for it would be giving away the product.
        let event = serde_json::json!({
            "type": "customer.subscription.updated",
            "data": {"object": {
                "id": "sub_1", "customer": "cus_1", "status": "active",
                "metadata": {"org_id": "org_1"},
                "items": {"data": [{"price": {"id": "price_unknown"}}]}
            }}
        });
        assert_eq!(interpret(&event, &prices()).unwrap().plan, Plan::Free);
    }

    #[test]
    fn a_trial_counts_as_active() {
        assert_eq!(status_of(Some("trialing")), SubscriptionStatus::Active);
        assert_eq!(status_of(Some("past_due")), SubscriptionStatus::PastDue);
        assert_eq!(status_of(Some("unpaid")), SubscriptionStatus::Canceled);
        assert_eq!(status_of(None), SubscriptionStatus::Canceled);
    }

    #[test]
    fn a_deletion_drops_to_free_and_cancels() {
        let event = serde_json::json!({
            "type": "customer.subscription.deleted",
            "data": {"object": {
                "id": "sub_1", "customer": "cus_1",
                "metadata": {"org_id": "org_1"}
            }}
        });

        let change = interpret(&event, &prices()).unwrap();
        assert_eq!(change.plan, Plan::Free);
        assert_eq!(change.status, SubscriptionStatus::Canceled);
    }

    #[test]
    fn checkout_completion_links_the_org_and_the_customer() {
        let event = serde_json::json!({
            "type": "checkout.session.completed",
            "data": {"object": {
                "client_reference_id": "org_1",
                "customer": "cus_1",
                "subscription": "sub_1"
            }}
        });

        let change = interpret(&event, &prices()).unwrap();
        assert_eq!(change.org_id.as_deref(), Some("org_1"));
        assert_eq!(change.customer_id.as_deref(), Some("cus_1"));
        assert_eq!(change.subscription_id.as_deref(), Some("sub_1"));
        // Conservative until the subscription event confirms the price.
        assert_eq!(change.plan, Plan::Pro);
    }

    #[test]
    fn an_expanded_customer_object_is_read_the_same_as_an_id() {
        let event = serde_json::json!({
            "type": "checkout.session.completed",
            "data": {"object": {
                "client_reference_id": "org_1",
                "customer": {"id": "cus_1", "email": "harsh@example.com"}
            }}
        });
        assert_eq!(
            interpret(&event, &prices()).unwrap().customer_id.as_deref(),
            Some("cus_1")
        );
    }

    #[test]
    fn events_this_system_does_not_act_on_are_ignored() {
        for kind in [
            "invoice.paid",
            "payment_intent.succeeded",
            "charge.refunded",
        ] {
            let event = serde_json::json!({"type": kind, "data": {"object": {}}});
            assert!(
                interpret(&event, &prices()).is_none(),
                "{kind} was acted on"
            );
        }
    }

    #[test]
    fn a_malformed_event_is_ignored_rather_than_panicking() {
        for event in [
            serde_json::json!({}),
            serde_json::json!({"type": "customer.subscription.updated"}),
            serde_json::json!({"type": "customer.subscription.updated", "data": {}}),
        ] {
            assert!(interpret(&event, &prices()).is_none());
        }
    }

    #[test]
    fn billing_off_is_a_supported_configuration() {
        let billing = Billing::Disabled;
        assert!(!billing.is_enabled());
        assert!(billing.purchasable().is_empty());
        assert!(matches!(
            billing.handle_webhook(b"{}", "t=1,v1=x", NOW),
            Err(BillingError::Disabled)
        ));
    }
}
