//! What to do about a session that is heading somewhere bad.
//!
//! The budget guard could do exactly one thing: refuse to dispatch, at 100% of
//! the cap. Everything before that point was full speed, and the rung below the
//! cliff — 80%, where the wrist already warns — changed nothing about how the
//! call was served. So the only lever was the one that ends the work, and the
//! cheapest moment to intervene was the one moment nothing happened.
//!
//! This is a ladder instead: **steer, then constrain, then stop.** Each rung is
//! a real change in how the next call is served, and each is reversible by the
//! session doing better.
//!
//! # Three inputs, because a budget is not the only way to go wrong
//!
//! Cost is the symptom people notice, and the slowest. An agent retrying the
//! same failing command forty times has a problem long before it has an
//! expensive one, and a loop is cheapest to catch while it is still cheap. So
//! [`Pressure`] carries what the runner can observe without inspecting content:
//! how much of the cap is gone, how many calls in a row have errored, and how
//! many times the same request has come back unchanged.
//!
//! # Why this is a pure function
//!
//! It reads no clock, opens nothing, and returns a decision rather than
//! performing one. That is what makes the thresholds arguable in a test rather
//! than in production, and it is why the policy lives here and the acting on it
//! lives in the gateway.

/// How hard to pull on a session, in ascending order of interference.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Restraint {
    /// Nothing is wrong. Serve the call as asked.
    None,
    /// Something is going wrong but the session can still get itself out.
    ///
    /// The call is served normally, with a correction attached saying what was
    /// observed. Deliberately the weakest rung: most loops are one bad
    /// assumption, and an agent told "you have run this three times and it has
    /// failed three times" usually stops running it.
    Steer,
    /// Serve it, but cheaply and narrowly.
    ///
    /// Drop to the small tier and skip the expensive stages. A session in
    /// trouble is the worst possible place to be spending frontier rates, and
    /// this is the rung that did not exist: at 80% the old guard warned a wrist
    /// and carried on paying full price until the cliff.
    Constrain,
    /// Refuse to dispatch. What the budget guard has always done, at the point
    /// it has always done it.
    Stop,
}

impl Restraint {
    /// For a ledger row and a dashboard, in the same vocabulary the budget view
    /// already uses.
    pub const fn as_str(self) -> &'static str {
        match self {
            Restraint::None => "none",
            Restraint::Steer => "steer",
            Restraint::Constrain => "constrain",
            Restraint::Stop => "stop",
        }
    }

    /// Whether the call is served at all.
    pub const fn dispatches(self) -> bool {
        !matches!(self, Restraint::Stop)
    }
}

/// What the runner has observed about a session, and nothing else.
///
/// Counters rather than history: the decision has to be cheap enough to make on
/// every call, and anything requiring the transcript would put content into a
/// crate that is not allowed to read one.
#[derive(Debug, Clone, Copy, Default)]
pub struct Pressure {
    /// Fraction of the budget consumed. `None` when uncapped — an unlimited
    /// session is not thereby a session in trouble.
    pub budget: Option<f64>,
    /// Calls that have errored back-to-back. Reset by a success.
    pub consecutive_errors: u32,
    /// How many times the same request has arrived unchanged, in a row.
    ///
    /// One repeat is a retry and healthy. Several is an agent that has stopped
    /// reading the answer.
    pub repeated_calls: u32,
}

/// Errors in a row before saying something. Two is a retry; three is a pattern.
pub const STEER_AFTER_ERRORS: u32 = 3;
/// Errors in a row before also making it cheap. Six is not going to fix itself.
pub const CONSTRAIN_AFTER_ERRORS: u32 = 6;
/// Errors in a row that end the session. Ten identical failures have cost
/// something and produced nothing.
pub const STOP_AFTER_ERRORS: u32 = 10;

/// Identical repeats before saying something.
pub const STEER_AFTER_REPEATS: u32 = 3;
/// Identical repeats before ending it. A loop this tight is not progressing,
/// and the cost of being wrong here is one interrupted session against an
/// unbounded bill.
pub const STOP_AFTER_REPEATS: u32 = 8;

/// The rung this session is on.
///
/// The strongest signal wins. A session that is both looping and out of budget
/// gets stopped, not steered — restraint is a maximum over the inputs, because
/// the whole point is that any one of them is sufficient reason.
pub fn restraint(pressure: &Pressure) -> Restraint {
    let from_budget = match pressure.budget {
        Some(pct) if pct >= crate::budget::EXHAUSTED_AT => Restraint::Stop,
        Some(pct) if pct >= crate::budget::WARNING_AT => Restraint::Constrain,
        _ => Restraint::None,
    };

    let from_errors = match pressure.consecutive_errors {
        n if n >= STOP_AFTER_ERRORS => Restraint::Stop,
        n if n >= CONSTRAIN_AFTER_ERRORS => Restraint::Constrain,
        n if n >= STEER_AFTER_ERRORS => Restraint::Steer,
        _ => Restraint::None,
    };

    let from_repeats = match pressure.repeated_calls {
        n if n >= STOP_AFTER_REPEATS => Restraint::Stop,
        n if n >= STEER_AFTER_REPEATS => Restraint::Steer,
        _ => Restraint::None,
    };

    from_budget.max(from_errors).max(from_repeats)
}

/// What to tell the agent, when the rung is one that says something.
///
/// Written to be read by a model and acted on: it names what was observed and
/// what to do differently, and does not scold. `None` at rungs that speak
/// through their behaviour instead — a stop is not a suggestion, and a
/// constrain that announced itself would invite the agent to argue with it.
pub fn correction(pressure: &Pressure) -> Option<String> {
    match restraint(pressure) {
        Restraint::Steer | Restraint::Constrain => {}
        Restraint::None | Restraint::Stop => return None,
    }

    if pressure.repeated_calls >= STEER_AFTER_REPEATS {
        return Some(format!(
            "You have made this same request {} times without changing it. \
             Whatever you are expecting to be different is not going to be. \
             Try another approach, or say what you are stuck on.",
            pressure.repeated_calls
        ));
    }

    if pressure.consecutive_errors >= STEER_AFTER_ERRORS {
        return Some(format!(
            "The last {} calls all failed. Read the most recent error before \
             trying again — repeating the call is not going to clear it.",
            pressure.consecutive_errors
        ));
    }

    // Budget-only pressure. Worth saying so the agent can prioritise what is
    // left rather than discovering the cap by hitting it.
    pressure.budget.map(|pct| {
        format!(
            "This session has used {:.0}% of its budget and is now being served \
             on the cheap tier. Finish what matters most first.",
            pct * 100.0
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn budget(pct: f64) -> Pressure {
        Pressure {
            budget: Some(pct),
            ..Pressure::default()
        }
    }

    #[test]
    fn a_healthy_session_is_left_alone() {
        assert_eq!(restraint(&Pressure::default()), Restraint::None);
        assert_eq!(restraint(&budget(0.5)), Restraint::None);
        assert!(correction(&budget(0.5)).is_none());
    }

    #[test]
    fn the_warning_threshold_now_changes_something() {
        // The whole point of this module. 80% used to warn a wrist and go on
        // paying frontier rates until the cap; it now drops the tier, which is
        // the cheapest possible intervention at the last moment it can help.
        assert_eq!(restraint(&budget(0.8)), Restraint::Constrain);
        assert_eq!(restraint(&budget(0.95)), Restraint::Constrain);
    }

    #[test]
    fn the_cap_still_stops_exactly_where_it_did() {
        // This ladder must not move the hard stop. A session that has spent its
        // cap has spent its cap, and that was true before this file existed.
        assert_eq!(restraint(&budget(1.0)), Restraint::Stop);
        assert_eq!(restraint(&budget(1.4)), Restraint::Stop);
        assert!(!restraint(&budget(1.0)).dispatches());
    }

    #[test]
    fn an_uncapped_session_is_never_restrained_by_its_budget() {
        let uncapped = Pressure {
            budget: None,
            ..Pressure::default()
        };
        assert_eq!(restraint(&uncapped), Restraint::None);
    }

    #[test]
    fn a_failing_session_is_spoken_to_before_it_is_throttled() {
        let steer = Pressure {
            consecutive_errors: STEER_AFTER_ERRORS,
            ..Pressure::default()
        };
        assert_eq!(restraint(&steer), Restraint::Steer);
        assert!(correction(&steer).unwrap().contains("failed"));

        let constrain = Pressure {
            consecutive_errors: CONSTRAIN_AFTER_ERRORS,
            ..Pressure::default()
        };
        assert_eq!(restraint(&constrain), Restraint::Constrain);
    }

    #[test]
    fn a_tight_loop_is_caught_while_it_is_still_cheap() {
        // The reason errors and repeats are separate inputs. An agent running
        // one failing command forty times has a problem long before it has an
        // expensive one, and cost would notice last.
        let looping = Pressure {
            repeated_calls: STOP_AFTER_REPEATS,
            budget: Some(0.05),
            ..Pressure::default()
        };
        assert_eq!(restraint(&looping), Restraint::Stop);
    }

    #[test]
    fn one_retry_is_not_a_loop() {
        // Retrying is how correct agents recover from a flaky tool. A breaker
        // that trips on the first repeat would break the working case.
        let retried = Pressure {
            repeated_calls: 1,
            consecutive_errors: 1,
            ..Pressure::default()
        };
        assert_eq!(restraint(&retried), Restraint::None);
    }

    #[test]
    fn the_strongest_signal_decides() {
        // Any one input is sufficient reason on its own, so the answer is a
        // maximum. Averaging them would let a healthy budget excuse a loop.
        let both = Pressure {
            budget: Some(0.85),
            repeated_calls: STOP_AFTER_REPEATS,
            consecutive_errors: 0,
        };
        assert_eq!(restraint(&both), Restraint::Stop);
    }

    #[test]
    fn a_stop_does_not_argue_with_the_agent() {
        // A correction at the stop rung would read as a suggestion, and the
        // call is not being served either way.
        let stopped = Pressure {
            consecutive_errors: STOP_AFTER_ERRORS,
            ..Pressure::default()
        };
        assert!(correction(&stopped).is_none());
    }

    #[test]
    fn a_correction_names_what_was_seen_rather_than_scolding() {
        let looping = Pressure {
            repeated_calls: STEER_AFTER_REPEATS,
            ..Pressure::default()
        };
        let said = correction(&looping).unwrap();
        assert!(said.contains(&STEER_AFTER_REPEATS.to_string()));
        assert!(
            said.contains("another approach"),
            "a correction has to say what to do instead: {said}"
        );
    }

    #[test]
    fn the_rungs_are_ordered_so_a_maximum_means_something() {
        assert!(Restraint::None < Restraint::Steer);
        assert!(Restraint::Steer < Restraint::Constrain);
        assert!(Restraint::Constrain < Restraint::Stop);
    }

    #[test]
    fn everything_but_a_stop_still_serves_the_call() {
        assert!(Restraint::None.dispatches());
        assert!(Restraint::Steer.dispatches());
        assert!(Restraint::Constrain.dispatches());
        assert!(!Restraint::Stop.dispatches());
    }
}
