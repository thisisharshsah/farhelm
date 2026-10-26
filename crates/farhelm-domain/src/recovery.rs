//! Task lease evaluation and crash-recovery decision rules (ADR 0004).
//!
//! When a runner process restarts or supervises background tasks, it must
//! deterministically decide whether an in-flight task can be safely resumed from
//! a step checkpoint, whether it is still owned by an active worker lease, or
//! whether it must be flagged as interrupted for human review.
//!
//! Pure functions: time and task steps are passed as explicit arguments.

use serde::{Deserialize, Serialize};

/// An active or expired worker lease on an agent task.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskLease {
    /// Identifier of the runner or worker claiming execution.
    pub holder: String,
    /// Unix millisecond timestamp when the lease ceases to be valid.
    pub expires_at_ms: i64,
    /// Monotonically increasing fencing generation to prevent stale writes.
    pub fencing_token: u64,
}

impl TaskLease {
    pub fn new(holder: impl Into<String>, expires_at_ms: i64, fencing_token: u64) -> Self {
        Self {
            holder: holder.into(),
            expires_at_ms,
            fencing_token,
        }
    }

    /// Whether this lease has expired relative to the current timestamp.
    pub fn is_expired(&self, now_ms: i64) -> bool {
        now_ms >= self.expires_at_ms
    }

    /// Whether a claimant with a specific fencing generation can renew this lease.
    pub fn can_renew(&self, claimant: &str, generation: u64, now_ms: i64) -> bool {
        self.holder == claimant && generation == self.fencing_token && !self.is_expired(now_ms)
    }
}

/// A checkpoint recorded in the step ledger.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StepCheckpoint {
    pub ordinal: u32,
    pub stage: StepStage,
    pub commit_sha: Option<String>,
    pub is_idempotent: bool,
}

/// Execution stage of a task step.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum StepStage {
    ModelCall,
    ToolCall,
    ToolResult,
    Verify,
}

/// The deterministic action a runner should take when reconciling a task after restart.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecoveryAction {
    /// Another live worker holds an unexpired lease. Do not interfere.
    LockedByPeer { holder: String, expires_at_ms: i64 },
    /// Safe to resume from the latest checkpoint commit.
    ResumeFromCheckpoint {
        step_ordinal: u32,
        commit_sha: String,
    },
    /// Task has an expired lease or crash but lacks a safe checkpoint to resume.
    NeedsAttention { reason: String },
}

/// Evaluate an in-flight task on startup to determine safe recovery action.
pub fn evaluate_recovery(
    lease: Option<&TaskLease>,
    checkpoints: &[StepCheckpoint],
    now_ms: i64,
) -> RecoveryAction {
    // 1. Check if an active, unexpired lease is held by another worker
    if let Some(l) = lease
        && !l.is_expired(now_ms)
    {
        return RecoveryAction::LockedByPeer {
            holder: l.holder.clone(),
            expires_at_ms: l.expires_at_ms,
        };
    }

    // A prior commit cannot establish the outcome of a later interrupted
    // action. In particular, resuming from it could repeat a non-idempotent
    // command whose external effect already happened before the crash.
    let latest_checkpoint = checkpoints.iter().max_by_key(|c| c.ordinal);
    if let Some(cp) = latest_checkpoint
        && cp.is_idempotent
        && let Some(commit_sha) = cp.commit_sha.as_ref().filter(|sha| !sha.trim().is_empty())
    {
        RecoveryAction::ResumeFromCheckpoint {
            step_ordinal: cp.ordinal,
            commit_sha: commit_sha.clone(),
        }
    } else {
        RecoveryAction::NeedsAttention {
            reason: if checkpoints.is_empty() {
                "No step checkpoints recorded prior to interruption".into()
            } else {
                "Interrupted during a non-idempotent or uncommitted step".into()
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_700_000_000_000;

    #[test]
    fn lease_expiration_and_renewal_rules() {
        let lease = TaskLease::new("runner-1", NOW + 30_000, 1);
        assert!(!lease.is_expired(NOW));
        assert!(lease.is_expired(NOW + 30_000));
        assert!(lease.is_expired(NOW + 30_001));

        // Renewal with correct credentials succeeds
        assert!(lease.can_renew("runner-1", 1, NOW));

        // Renewal with mismatched holder fails
        assert!(!lease.can_renew("runner-2", 1, NOW));

        // Renewal with stale generation fails
        assert!(!lease.can_renew("runner-1", 0, NOW));

        // Renewal after expiration fails
        assert!(!lease.can_renew("runner-1", 1, NOW + 30_000));
    }

    #[test]
    fn active_peer_lease_prevents_split_brain_recovery() {
        let lease = TaskLease::new("runner-a", NOW + 15_000, 2);
        let action = evaluate_recovery(Some(&lease), &[], NOW);

        assert_eq!(
            action,
            RecoveryAction::LockedByPeer {
                holder: "runner-a".into(),
                expires_at_ms: NOW + 15_000,
            }
        );
    }

    #[test]
    fn interrupted_later_action_blocks_an_earlier_checkpoint() {
        let lease = TaskLease::new("runner-a", NOW - 5_000, 1);
        let checkpoints = vec![
            StepCheckpoint {
                ordinal: 1,
                stage: StepStage::ToolCall,
                commit_sha: Some("sha_step_1".into()),
                is_idempotent: true,
            },
            StepCheckpoint {
                ordinal: 2,
                stage: StepStage::ToolResult,
                commit_sha: Some("sha_step_2".into()),
                is_idempotent: true,
            },
            // Step 3 was non-idempotent or had no commit
            StepCheckpoint {
                ordinal: 3,
                stage: StepStage::ToolCall,
                commit_sha: None,
                is_idempotent: false,
            },
        ];

        let action = evaluate_recovery(Some(&lease), &checkpoints, NOW);

        assert!(matches!(action, RecoveryAction::NeedsAttention { .. }));
    }

    #[test]
    fn latest_committed_idempotent_step_can_resume_regardless_of_input_order() {
        let checkpoints = vec![
            StepCheckpoint {
                ordinal: 2,
                stage: StepStage::ToolResult,
                commit_sha: Some("sha_step_2".into()),
                is_idempotent: true,
            },
            StepCheckpoint {
                ordinal: 1,
                stage: StepStage::ToolCall,
                commit_sha: None,
                is_idempotent: false,
            },
        ];

        assert_eq!(
            evaluate_recovery(None, &checkpoints, NOW),
            RecoveryAction::ResumeFromCheckpoint {
                step_ordinal: 2,
                commit_sha: "sha_step_2".into(),
            }
        );
    }

    #[test]
    fn blank_commit_or_uncommitted_latest_step_needs_attention() {
        for commit_sha in [None, Some(String::new()), Some("  ".into())] {
            let checkpoints = vec![
                StepCheckpoint {
                    ordinal: 1,
                    stage: StepStage::Verify,
                    commit_sha: Some("sha_step_1".into()),
                    is_idempotent: true,
                },
                StepCheckpoint {
                    ordinal: 2,
                    stage: StepStage::ToolCall,
                    commit_sha,
                    is_idempotent: true,
                },
            ];
            assert!(matches!(
                evaluate_recovery(None, &checkpoints, NOW),
                RecoveryAction::NeedsAttention { .. }
            ));
        }
    }

    #[test]
    fn flags_needs_attention_when_no_safe_checkpoints_exist() {
        let lease = TaskLease::new("runner-a", NOW - 1_000, 1);
        let checkpoints = vec![StepCheckpoint {
            ordinal: 1,
            stage: StepStage::ToolCall,
            commit_sha: None,
            is_idempotent: false,
        }];

        let action = evaluate_recovery(Some(&lease), &checkpoints, NOW);

        match action {
            RecoveryAction::NeedsAttention { reason } => {
                assert!(reason.contains("non-idempotent or uncommitted"));
            }
            other => panic!("expected NeedsAttention, got {other:?}"),
        }
    }
}
