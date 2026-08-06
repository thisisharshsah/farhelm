//! Protocol version and capability negotiation.
//!
//! # Status: understood, not yet required, not yet acted on
//!
//! The runner accepts a [`Hello`] if one arrives and records what the device
//! said it can handle. **No client sends one, and nothing reads what is
//! recorded** — that is step one of three, and it is deliberately inert.
//!
//! Before this, the protocol version was "whatever both sides happened to be
//! compiled from". A device one release behind discovered that by receiving a
//! `ServerEvent` variant it could not parse, in the field, silently — `serde`
//! rejects the frame and the phone simply stops updating.
//!
//! # Why versioning is needed before it is used
//!
//! The wire is already versionable in one direction by accident: every
//! `ServerEvent` and `Command` is externally tagged, so an unknown `type` is a
//! clean parse failure rather than a misread. That is enough for *rejecting* the
//! future, not for *negotiating* with it — the runner cannot tell whether a
//! device would understand a new event before it sends one, so no event can
//! ever be added without breaking old clients.
//!
//! [`Capability`] is what makes that decidable. A device announces what it can
//! handle; the runner sends the richer form only to devices that said yes, and
//! the older form to everyone else.
//!
//! # The migration
//!
//! Three steps. Each is safe only because the one before it shipped, and doing
//! them out of order is the mistake this module exists to make visible.
//!
//! 1. **Done.** The runner accepts a `Hello` if one arrives and records the
//!    sender's capabilities, defaulting to [`Capability::BASELINE`] when none
//!    does. No client sends one, so nothing changes — which is the point: a
//!    runner in the field must understand the frame *before* any client emits
//!    it.
//! 2. **Next, and a client change.** Clients start sending a `Hello` on
//!    connect. A runner older than step one ignores a frame it cannot parse, so
//!    this is safe against every deployed version.
//! 3. **Only once (2) has been out long enough.** A capability may finally gate
//!    something — a new event sent to devices that announced support and
//!    withheld from those that did not. Doing this before (2) has propagated
//!    silently degrades every device that has not upgraded, because they are
//!    indistinguishable from devices that cannot cope.
//!
//! The capabilities are held per *connection*, not per device row. A device that
//! reconnects from an older build must not keep the capabilities its previous
//! connection announced.

use serde::{Deserialize, Serialize};

/// The wire contract this build speaks.
///
/// Bumped when a change is not backward compatible — a removed field, a renamed
/// variant, a changed meaning. Additive changes get a [`Capability`] instead,
/// because they do not require anyone to upgrade.
pub const PROTOCOL_VERSION: ProtocolVersion = ProtocolVersion { major: 1, minor: 0 };

/// A two-part protocol version.
///
/// `major` is the compatibility boundary: two peers whose majors differ cannot
/// usefully talk. `minor` advances with additive change and is informational —
/// what a peer can actually do is [`Hello::capabilities`], because a build can
/// be new and still have a capability compiled out.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct ProtocolVersion {
    pub major: u16,
    pub minor: u16,
}

impl ProtocolVersion {
    /// Whether a peer at this version can talk to one at `other`.
    ///
    /// Major equality only. A newer minor may send things an older one skips,
    /// which is exactly what [`Capability`] is for.
    pub fn is_compatible_with(self, other: Self) -> bool {
        self.major == other.major
    }
}

impl std::fmt::Display for ProtocolVersion {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}", self.major, self.minor)
    }
}

/// Something a peer can do that is not implied by [`ProtocolVersion::major`].
///
/// Unknown strings are kept rather than rejected: a runner talking to a newer
/// device must be able to round-trip a capability it has never heard of without
/// treating the device as broken.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Capability(pub String);

impl Capability {
    /// What every client understands as of [`PROTOCOL_VERSION`]. A peer that
    /// sends no [`Hello`] is assumed to have exactly this and nothing more.
    pub const BASELINE: &'static [&'static str] =
        &["approval", "instruct", "output", "plan_control", "snapshot"];

    /// Reviewing a native agent task's diff — the `task_*` commands and the
    /// `task_upsert` event. Named because the watch has no screen for it.
    pub const TASK_REVIEW: &'static str = "task_review";

    /// The cost dashboard: `dashboard_snapshot` and its reply.
    pub const DASHBOARD: &'static str = "dashboard";

    pub fn new(name: impl Into<String>) -> Self {
        Self(name.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for Capability {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// The first frame a peer would send on a new link.
///
/// Not yet sent by anything — see the module docs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Hello {
    pub protocol: ProtocolVersion,
    /// What this peer can handle beyond [`Capability::BASELINE`].
    ///
    /// `#[serde(default)]` so a peer that sends `{"protocol": ...}` and nothing
    /// else is read as baseline-only rather than as a parse error.
    #[serde(default)]
    pub capabilities: Vec<Capability>,
    /// Free-form build identifier, for logs and support. Never matched on —
    /// behaviour keys off `capabilities`, so that a fork or a rebuild is not
    /// accidentally treated as a different client.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
}

impl Hello {
    /// This build's own hello.
    pub fn current(capabilities: &[&str]) -> Self {
        Self {
            protocol: PROTOCOL_VERSION,
            capabilities: capabilities
                .iter()
                .map(|name| Capability::new(*name))
                .collect(),
            agent: None,
        }
    }

    pub fn supports(&self, capability: &str) -> bool {
        Capability::BASELINE.contains(&capability)
            || self
                .capabilities
                .iter()
                .any(|held| held.as_str() == capability)
    }
}

impl Default for Hello {
    /// What a peer that sent no hello is assumed to be: current major, baseline
    /// capabilities only.
    fn default() -> Self {
        Self {
            protocol: PROTOCOL_VERSION,
            capabilities: Vec::new(),
            agent: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_peer_that_sent_no_hello_has_the_baseline_and_nothing_else() {
        let assumed = Hello::default();
        assert!(assumed.supports("approval"));
        assert!(assumed.supports("instruct"));
        // The two things a v1.0 watch genuinely cannot do.
        assert!(!assumed.supports(Capability::TASK_REVIEW));
        assert!(!assumed.supports(Capability::DASHBOARD));
    }

    #[test]
    fn capabilities_add_to_the_baseline_rather_than_replacing_it() {
        let phone = Hello::current(&[Capability::TASK_REVIEW, Capability::DASHBOARD]);
        assert!(phone.supports(Capability::TASK_REVIEW));
        assert!(phone.supports(Capability::DASHBOARD));
        // Still has everything a baseline peer has.
        for baseline in Capability::BASELINE {
            assert!(phone.supports(baseline));
        }
    }

    #[test]
    fn only_the_major_decides_compatibility() {
        let v1 = ProtocolVersion { major: 1, minor: 0 };
        let v1_9 = ProtocolVersion { major: 1, minor: 9 };
        let v2 = ProtocolVersion { major: 2, minor: 0 };

        assert!(v1.is_compatible_with(v1_9));
        assert!(v1_9.is_compatible_with(v1));
        assert!(!v1.is_compatible_with(v2));
    }

    #[test]
    fn an_unknown_capability_round_trips_rather_than_failing() {
        // A runner talking to a newer device must not treat a capability it has
        // never heard of as a broken client.
        let json = r#"{"protocol":{"major":1,"minor":4},"capabilities":["teleport"]}"#;
        let hello: Hello = serde_json::from_str(json).unwrap();
        assert!(hello.supports("teleport"));
        assert_eq!(serde_json::to_string(&hello).unwrap(), json);
    }

    #[test]
    fn a_hello_without_capabilities_parses_as_baseline() {
        let hello: Hello = serde_json::from_str(r#"{"protocol":{"major":1,"minor":0}}"#).unwrap();
        assert!(hello.capabilities.is_empty());
        assert!(hello.supports("snapshot"));
    }

    #[test]
    fn the_wire_form_is_stable() {
        let hello = Hello {
            protocol: ProtocolVersion { major: 1, minor: 0 },
            capabilities: vec![Capability::new(Capability::TASK_REVIEW)],
            agent: Some("relayforge-desktop/0.1.0".into()),
        };
        assert_eq!(
            serde_json::to_value(&hello).unwrap(),
            serde_json::json!({
                "protocol": {"major": 1, "minor": 0},
                "capabilities": ["task_review"],
                "agent": "relayforge-desktop/0.1.0",
            })
        );
    }
}
