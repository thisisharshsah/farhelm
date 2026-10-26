//! Pure role and resource-grant checks for future scoped authorization (ADR 0005).
//!
//! Evaluates whether an authenticated principal holds the requisite capability
//! to perform an action against a specific repository, project, or task.
//!
//! Pure functions: all state and identities are passed as explicit arguments.
//! This module is not connected to request authentication or a process sandbox.

use farhelm_proto::types::Risk;
use serde::{Deserialize, Serialize};
use std::fmt;

/// Role of a user within a workspace or organization.
///
/// Ordered by capability: `role >= MemberRole::Admin` allows clean tier checks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemberRole {
    /// Read-only access to repositories and execution history.
    Viewer,
    /// Standard developer access: can edit, run commands, and review change sets.
    Member,
    /// Administrative control: can manage project settings and repositories.
    Admin,
    /// Full ownership including workspace billing and member roles.
    Owner,
}

/// Identity facts supplied by a trusted authentication boundary.
///
/// Request JSON must never be allowed to assert these facts or `System` status.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Principal {
    /// An authenticated team member.
    User {
        user_id: String,
        org_id: String,
        role: MemberRole,
    },
    /// A paired device acting on behalf of a user.
    Device {
        device_id: String,
        user_id: String,
        role: MemberRole,
    },
    /// An authorized external MCP connector or agent tool.
    Connector {
        connector_id: String,
        authorized_by_user_id: String,
    },
    /// Internal daemon / supervisor system worker.
    System,
}

/// A fine-grained authorization capability required to perform an action.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum ActionCapability {
    /// Read files and context within a specific repository.
    ReadRepo { repo_id: String },
    /// Create worktrees and propose edits on a specific repository.
    EditRepo { repo_id: String },
    /// Execute commands in a designated checkout under an explicit host policy.
    ExecuteCommand { repo_id: String, risk: Risk },
    /// Review, apply, or revert a change set.
    ReviewChangeSet { task_id: String },
    /// Manage project settings and model policies.
    AdminProject { project_id: String },
}

/// Reason an action authorization check was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthError {
    /// Principal role is insufficient for this operation.
    InsufficientRole {
        required: MemberRole,
        actual: MemberRole,
    },
    /// Principal does not hold the explicit granted scope for this resource.
    ScopeNotGranted,
    /// Read-only principals cannot execute mutations or commands.
    ReadOnlyForbidden,
}

impl fmt::Display for AuthError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AuthError::InsufficientRole { required, actual } => {
                write!(
                    f,
                    "insufficient role: requires {required:?}, but caller is {actual:?}"
                )
            }
            AuthError::ScopeNotGranted => {
                write!(f, "principal lacks granted capability for this resource")
            }
            AuthError::ReadOnlyForbidden => {
                write!(f, "operation forbidden: principal has read-only privileges")
            }
        }
    }
}

impl std::error::Error for AuthError {}

/// Require an explicit resource grant and enforce the principal's role ceiling.
///
/// The caller must resolve grants from trusted state and bind them to this
/// verified principal and tenant, including expiry, delegation and revocation.
/// A role alone conveys no repository/project access. Capabilities match exactly;
/// an execution grant does not implicitly grant a different risk or action.
pub fn authorize(
    principal: &Principal,
    required: &ActionCapability,
    granted_scopes: &[ActionCapability],
) -> Result<(), AuthError> {
    if !matches!(principal, Principal::System) && !granted_scopes.contains(required) {
        return Err(AuthError::ScopeNotGranted);
    }
    match principal {
        Principal::System => Ok(()),

        Principal::User { role, .. } | Principal::Device { role, .. } => match required {
            ActionCapability::ReadRepo { .. } => Ok(()),
            ActionCapability::EditRepo { .. } | ActionCapability::ReviewChangeSet { .. } => {
                if *role < MemberRole::Member {
                    Err(AuthError::ReadOnlyForbidden)
                } else {
                    Ok(())
                }
            }
            ActionCapability::ExecuteCommand { risk, .. } => {
                if *role < MemberRole::Member {
                    Err(AuthError::ReadOnlyForbidden)
                } else if *risk == Risk::Destructive && *role < MemberRole::Admin {
                    Err(AuthError::InsufficientRole {
                        required: MemberRole::Admin,
                        actual: *role,
                    })
                } else {
                    Ok(())
                }
            }
            ActionCapability::AdminProject { .. } => {
                if *role < MemberRole::Admin {
                    Err(AuthError::InsufficientRole {
                        required: MemberRole::Admin,
                        actual: *role,
                    })
                } else {
                    Ok(())
                }
            }
        },

        Principal::Connector { .. } => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn user(role: MemberRole) -> Principal {
        Principal::User {
            user_id: "u1".into(),
            org_id: "org1".into(),
            role,
        }
    }

    fn with_grant(principal: &Principal, required: &ActionCapability) -> Result<(), AuthError> {
        authorize(principal, required, std::slice::from_ref(required))
    }

    #[test]
    fn system_principal_is_unconditionally_authorized() {
        assert_eq!(
            authorize(
                &Principal::System,
                &ActionCapability::AdminProject {
                    project_id: "p1".into()
                },
                &[],
            ),
            Ok(())
        );
    }

    #[test]
    fn no_role_including_owner_implies_resource_access() {
        let required = ActionCapability::ReadRepo {
            repo_id: "private-repo".into(),
        };
        let unrelated = ActionCapability::ReadRepo {
            repo_id: "other-repo".into(),
        };
        for role in [
            MemberRole::Viewer,
            MemberRole::Member,
            MemberRole::Admin,
            MemberRole::Owner,
        ] {
            assert_eq!(
                authorize(&user(role), &required, &[]),
                Err(AuthError::ScopeNotGranted)
            );
            assert_eq!(
                authorize(&user(role), &required, std::slice::from_ref(&unrelated)),
                Err(AuthError::ScopeNotGranted)
            );
        }
    }

    #[test]
    fn viewer_resource_grant_cannot_exceed_the_role_ceiling() {
        let viewer = user(MemberRole::Viewer);
        assert_eq!(
            with_grant(
                &viewer,
                &ActionCapability::ReadRepo {
                    repo_id: "r1".into()
                }
            ),
            Ok(())
        );
        for required in [
            ActionCapability::EditRepo {
                repo_id: "r1".into(),
            },
            ActionCapability::ExecuteCommand {
                repo_id: "r1".into(),
                risk: Risk::Low,
            },
            ActionCapability::ReviewChangeSet {
                task_id: "t1".into(),
            },
        ] {
            assert_eq!(
                with_grant(&viewer, &required),
                Err(AuthError::ReadOnlyForbidden)
            );
        }
    }

    #[test]
    fn destructive_execution_requires_both_resource_grant_and_admin_role() {
        let destructive = ActionCapability::ExecuteCommand {
            repo_id: "r1".into(),
            risk: Risk::Destructive,
        };
        let medium = ActionCapability::ExecuteCommand {
            repo_id: "r1".into(),
            risk: Risk::Medium,
        };
        let member = user(MemberRole::Member);
        assert_eq!(with_grant(&member, &medium), Ok(()));
        assert_eq!(
            with_grant(&member, &destructive),
            Err(AuthError::InsufficientRole {
                required: MemberRole::Admin,
                actual: MemberRole::Member
            })
        );
        assert_eq!(with_grant(&user(MemberRole::Admin), &destructive), Ok(()));
        assert_eq!(
            authorize(&user(MemberRole::Admin), &destructive, &[medium]),
            Err(AuthError::ScopeNotGranted)
        );
    }

    #[test]
    fn project_administration_requires_an_exact_project_grant() {
        let required = ActionCapability::AdminProject {
            project_id: "p1".into(),
        };
        let other = ActionCapability::AdminProject {
            project_id: "p2".into(),
        };
        assert_eq!(
            with_grant(&user(MemberRole::Member), &required),
            Err(AuthError::InsufficientRole {
                required: MemberRole::Admin,
                actual: MemberRole::Member
            })
        );
        assert_eq!(with_grant(&user(MemberRole::Admin), &required), Ok(()));
        assert_eq!(
            authorize(&user(MemberRole::Owner), &required, &[other]),
            Err(AuthError::ScopeNotGranted)
        );
    }

    #[test]
    fn devices_and_connectors_also_require_resource_specific_grants() {
        let device = Principal::Device {
            device_id: "d1".into(),
            user_id: "u1".into(),
            role: MemberRole::Member,
        };
        let connector = Principal::Connector {
            connector_id: "c1".into(),
            authorized_by_user_id: "u1".into(),
        };
        let read = ActionCapability::ReadRepo {
            repo_id: "r1".into(),
        };
        let edit = ActionCapability::EditRepo {
            repo_id: "r1".into(),
        };
        for principal in [&device, &connector] {
            assert_eq!(
                authorize(principal, &read, &[]),
                Err(AuthError::ScopeNotGranted)
            );
            assert_eq!(with_grant(principal, &read), Ok(()));
            assert_eq!(
                authorize(principal, &edit, std::slice::from_ref(&read)),
                Err(AuthError::ScopeNotGranted)
            );
        }
    }
}
