//! Plans and what they entitle you to.
//!
//! Pure, in the same sense `forge-domain` is pure: no clock, no I/O, no async.
//! An entitlement question is a total function of (plan, current counts), which
//! is what makes it testable without arranging an account first — and what makes
//! it safe to answer in three different places (the API, the runner enrolment
//! path, the billing webhook) without them drifting.
//!
//! # Why limits live here and not in the database
//!
//! A limit in a row is a limit somebody can edit by hand at 3am and forget.
//! A limit in code is in the diff, in the tests, and in the release notes.
//! What *is* in the database is which plan an organisation is on, which is the
//! only part that legitimately changes per tenant.

use serde::{Deserialize, Serialize};

/// The subscription tiers. Adding one is a variant plus a row in [`LIMITS`];
/// a test below fails if you add the variant and forget the row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum Plan {
    /// What you get without paying, and what every organisation starts on —
    /// including when billing is not configured at all.
    #[serde(rename = "free")]
    Free,
    /// The solo developer with more than one machine.
    #[serde(rename = "pro")]
    Pro,
    /// Several people supervising a shared fleet.
    #[serde(rename = "team")]
    Team,
}

impl Plan {
    pub const ALL: &'static [Plan] = &[Plan::Free, Plan::Pro, Plan::Team];

    pub const fn as_str(self) -> &'static str {
        match self {
            Plan::Free => "free",
            Plan::Pro => "pro",
            Plan::Team => "team",
        }
    }

    pub const fn display_name(self) -> &'static str {
        match self {
            Plan::Free => "Free",
            Plan::Pro => "Pro",
            Plan::Team => "Team",
        }
    }

    /// Monthly price in cents. Display only — what is actually charged is
    /// whatever the Stripe price says, and the webhook is the source of truth
    /// for which plan is live.
    pub const fn monthly_cents(self) -> u32 {
        match self {
            Plan::Free => 0,
            Plan::Pro => 900,
            Plan::Team => 2900,
        }
    }

    pub const fn limits(self) -> Limits {
        match self {
            Plan::Free => LIMITS[0].1,
            Plan::Pro => LIMITS[1].1,
            Plan::Team => LIMITS[2].1,
        }
    }
}

impl std::str::FromStr for Plan {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "free" => Ok(Plan::Free),
            "pro" => Ok(Plan::Pro),
            "team" => Ok(Plan::Team),
            _ => Err(()),
        }
    }
}

impl std::fmt::Display for Plan {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Everything a plan caps.
///
/// `u32::MAX` is the encoding of "no limit". A sentinel rather than an
/// `Option<u32>` because every comparison below would otherwise need a match,
/// and a forgotten `None` arm reads as *unlimited* — the wrong direction to fail.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Limits {
    /// Machines that may be enrolled.
    pub runners: u32,
    /// Phones, watches and browsers that may hold keys.
    pub devices: u32,
    /// People in the organisation, the owner included.
    pub members: u32,
    /// Envelopes per minute per relay connection. The relay reads this out of
    /// the token claim, so it needs no database to enforce it.
    pub relay_messages_per_minute: u32,
    /// Days of cost history the dashboard will render.
    pub history_days: u32,
    /// Whether the organisation may use the gateway's batch queue, which trades
    /// latency for a 50% discount and only makes sense for paid tiers.
    pub batch_queue: bool,
    /// Whether approval decisions are written to an exportable audit log.
    pub audit_log: bool,
}

pub const UNLIMITED: u32 = u32::MAX;

/// The table. Ordered to match [`Plan::ALL`]; the test at the bottom enforces
/// that, because [`Plan::limits`] indexes into it.
pub const LIMITS: &[(Plan, Limits)] = &[
    (
        Plan::Free,
        Limits {
            runners: 1,
            devices: 2,
            members: 1,
            relay_messages_per_minute: 120,
            history_days: 7,
            batch_queue: false,
            audit_log: false,
        },
    ),
    (
        Plan::Pro,
        Limits {
            runners: 5,
            devices: 10,
            members: 1,
            relay_messages_per_minute: 1_200,
            history_days: 90,
            batch_queue: true,
            audit_log: false,
        },
    ),
    (
        Plan::Team,
        Limits {
            runners: 25,
            devices: UNLIMITED,
            members: 25,
            relay_messages_per_minute: 6_000,
            history_days: 365,
            batch_queue: true,
            audit_log: true,
        },
    ),
];

/// What an organisation is using right now. Counted, never estimated.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Usage {
    pub runners: u32,
    pub devices: u32,
    pub members: u32,
}

/// Something a plan does not allow, phrased the way the user should read it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LimitExceeded {
    pub resource: &'static str,
    pub limit: u32,
    pub plan: Plan,
    /// The cheapest plan that would allow it, if there is one.
    pub upgrade_to: Option<Plan>,
}

impl std::fmt::Display for LimitExceeded {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "the {} plan allows {} {}",
            self.plan.display_name(),
            self.limit,
            self.resource
        )?;
        if let Some(plan) = self.upgrade_to {
            write!(f, " — {} allows more", plan.display_name())?;
        }
        Ok(())
    }
}

/// Which countable thing is being added.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Resource {
    Runner,
    Device,
    Member,
}

impl Resource {
    const fn name(self) -> &'static str {
        match self {
            Resource::Runner => "runners",
            Resource::Device => "devices",
            Resource::Member => "members",
        }
    }

    const fn limit_of(self, limits: Limits) -> u32 {
        match self {
            Resource::Runner => limits.runners,
            Resource::Device => limits.devices,
            Resource::Member => limits.members,
        }
    }

    const fn count_in(self, usage: Usage) -> u32 {
        match self {
            Resource::Runner => usage.runners,
            Resource::Device => usage.devices,
            Resource::Member => usage.members,
        }
    }
}

/// May this organisation add one more of `resource`?
///
/// Called before the insert, not after — a limit checked afterwards is a limit
/// that has already been exceeded once.
pub fn may_add(plan: Plan, usage: Usage, resource: Resource) -> Result<(), LimitExceeded> {
    let limit = resource.limit_of(plan.limits());
    if resource.count_in(usage) < limit {
        return Ok(());
    }
    Err(LimitExceeded {
        resource: resource.name(),
        limit,
        plan,
        upgrade_to: cheapest_plan_allowing(resource, resource.count_in(usage) + 1, plan),
    })
}

/// The cheapest plan strictly better than `current` that would fit `wanted`.
fn cheapest_plan_allowing(resource: Resource, wanted: u32, current: Plan) -> Option<Plan> {
    Plan::ALL
        .iter()
        .copied()
        .filter(|plan| *plan > current)
        .find(|plan| resource.limit_of(plan.limits()) >= wanted)
}

/// The state a subscription is in, as far as access is concerned.
///
/// Deliberately coarse. Stripe has a dozen statuses; what this system needs to
/// know is whether to serve the paid limits, and whether to nag.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SubscriptionStatus {
    /// Paid and current, or free — either way, serve the plan.
    #[serde(rename = "active")]
    Active,
    /// Payment failed but the grace period has not run out. Paid limits still
    /// apply: cutting off a developer's approval queue over a declined card is
    /// how you turn a billing problem into an outage.
    #[serde(rename = "past_due")]
    PastDue,
    /// Ended. Falls back to [`Plan::Free`] limits.
    #[serde(rename = "canceled")]
    Canceled,
}

impl SubscriptionStatus {
    pub const fn as_str(self) -> &'static str {
        match self {
            SubscriptionStatus::Active => "active",
            SubscriptionStatus::PastDue => "past_due",
            SubscriptionStatus::Canceled => "canceled",
        }
    }

    /// Whether the paid plan's limits apply, as opposed to falling back to free.
    pub const fn entitles(self) -> bool {
        matches!(
            self,
            SubscriptionStatus::Active | SubscriptionStatus::PastDue
        )
    }
}

impl std::str::FromStr for SubscriptionStatus {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "active" => Ok(SubscriptionStatus::Active),
            "past_due" => Ok(SubscriptionStatus::PastDue),
            "canceled" => Ok(SubscriptionStatus::Canceled),
            _ => Err(()),
        }
    }
}

/// The plan whose limits actually apply, which is not always the plan you pay
/// for: a cancelled Team subscription is a Free organisation with Team-sized
/// data in it.
pub fn effective_plan(plan: Plan, status: SubscriptionStatus) -> Plan {
    if status.entitles() { plan } else { Plan::Free }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_plan_has_a_limits_row_in_the_right_slot() {
        // `Plan::limits` indexes into LIMITS, so a reordering would silently
        // hand Free the Team limits.
        assert_eq!(LIMITS.len(), Plan::ALL.len());
        for (index, plan) in Plan::ALL.iter().enumerate() {
            assert_eq!(LIMITS[index].0, *plan, "LIMITS is out of order at {index}");
            assert_eq!(plan.limits(), LIMITS[index].1);
        }
    }

    #[test]
    fn plans_are_ordered_and_get_strictly_more_generous() {
        for pair in Plan::ALL.windows(2) {
            let (lower, higher) = (pair[0], pair[1]);
            assert!(lower < higher);
            assert!(higher.limits().runners >= lower.limits().runners);
            assert!(higher.limits().devices >= lower.limits().devices);
            assert!(higher.limits().members >= lower.limits().members);
            assert!(higher.monthly_cents() > lower.monthly_cents());
        }
    }

    #[test]
    fn the_free_plan_fits_one_developer_with_one_machine() {
        // The shape of the thing this was built for: a laptop, a phone, a
        // browser. If this ever stops being true the free tier is broken.
        let usage = Usage {
            runners: 0,
            devices: 0,
            members: 1,
        };
        assert!(may_add(Plan::Free, usage, Resource::Runner).is_ok());
        assert!(may_add(Plan::Free, usage, Resource::Device).is_ok());
        assert!(
            may_add(
                Plan::Free,
                Usage {
                    devices: 1,
                    ..usage
                },
                Resource::Device
            )
            .is_ok()
        );
    }

    #[test]
    fn a_second_runner_on_free_is_refused_and_names_the_upgrade() {
        let usage = Usage {
            runners: 1,
            ..Usage::default()
        };
        let refused = may_add(Plan::Free, usage, Resource::Runner).unwrap_err();

        assert_eq!(refused.resource, "runners");
        assert_eq!(refused.limit, 1);
        assert_eq!(refused.upgrade_to, Some(Plan::Pro));
        assert!(refused.to_string().contains("Pro"));
    }

    #[test]
    fn a_second_member_needs_team_not_pro() {
        // Pro is a solo plan. Somebody adding a colleague should be told Team,
        // not sold Pro and then find it did not help.
        let usage = Usage {
            members: 1,
            ..Usage::default()
        };
        assert_eq!(
            may_add(Plan::Pro, usage, Resource::Member)
                .unwrap_err()
                .upgrade_to,
            Some(Plan::Team)
        );
    }

    #[test]
    fn unlimited_really_is_unlimited() {
        let usage = Usage {
            devices: 10_000,
            ..Usage::default()
        };
        assert!(may_add(Plan::Team, usage, Resource::Device).is_ok());
    }

    #[test]
    fn the_top_plan_offers_no_upgrade() {
        let usage = Usage {
            runners: Plan::Team.limits().runners,
            ..Usage::default()
        };
        assert_eq!(
            may_add(Plan::Team, usage, Resource::Runner)
                .unwrap_err()
                .upgrade_to,
            None
        );
    }

    #[test]
    fn a_failed_payment_does_not_take_the_fleet_away() {
        // The reason this rule exists: an approval queue that stops answering
        // because a card expired is a production incident, not a billing nudge.
        assert_eq!(
            effective_plan(Plan::Team, SubscriptionStatus::PastDue),
            Plan::Team
        );
        assert_eq!(
            effective_plan(Plan::Team, SubscriptionStatus::Canceled),
            Plan::Free
        );
    }

    #[test]
    fn plan_names_round_trip_through_their_stored_form() {
        for plan in Plan::ALL {
            assert_eq!(plan.as_str().parse::<Plan>(), Ok(*plan));
        }
        assert!("enterprise".parse::<Plan>().is_err());
    }

    #[test]
    fn subscription_statuses_round_trip() {
        for status in [
            SubscriptionStatus::Active,
            SubscriptionStatus::PastDue,
            SubscriptionStatus::Canceled,
        ] {
            assert_eq!(status.as_str().parse(), Ok(status));
        }
    }
}
