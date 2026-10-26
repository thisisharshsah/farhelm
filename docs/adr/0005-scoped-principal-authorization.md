# 0005: Scoped Principal Authorization and Capability Sandboxing

**Status**: Pure principal/grant/role checks implemented; request authentication and enforcement integration pending. Updated October 24, 2026.  
**Consulted**: [AGENTS.md](../../AGENTS.md), [Engineering Stack](../engineering-stack.md), [Platform Review](../platform-review-2026-10-22.md), [ADR 0001](0001-local-execution-boundaries.md)

---

## Context

Finding 8 in [Platform Review](../platform-review-2026-10-22.md) highlights a critical trust-boundary gap:
- Cloud roles, device pairing and transport credentials exist, but there is no common project/repository-scoped execution principal carried through all runner command paths (`crates/farhelm-runner/src/commands.rs`). `DecidedVia` identifies an approval surface and is not a resource authorization decision.
- A shared-runner deployment needs verified repository scope on every route, including HTTP, relay, MCP and background work. Existing authentication must be assessed per surface; a connection alone must not imply authority over every registered repository.
- In a team workspace where multiple developers share a host or runner pool, execution privileges must be strictly scoped to the user, project, and repository.

---

## Decision

Introduce an explicit principal and resource permission model across HTTP, relay, MCP and background tasks. `farhelm-domain::auth` now defines `Principal`, `MemberRole`, `ActionCapability` and a pure `authorize` helper. Every non-system principal requires an exact resource grant as well as the role ceiling where applicable. The caller must bind grants to verified identity/tenant state and enforce expiry, delegation and revocation. Request middleware, grant resolution, audit columns and cross-surface enforcement remain a shared-hosting release gate; these helpers are not a complete authorization layer or a sandbox.

### 1. Proposed Principal Identity (future wire contract)

Every execution context should carry a principal derived from verified credentials. The following is an illustrative target contract; the initial domain types are not a `farhelm-proto/src/auth.rs` wire authority. Untrusted request JSON must not be allowed to assert its own identity or `System` status:

```rust
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Principal {
    /// An authenticated team member.
    User {
        user_id: String,
        org_id: String,
        role: MemberRole, // Owner, Admin, Member, ReadOnly
    },
    /// A paired mobile device or watch.
    Device {
        device_id: String,
        user_id: String,
    },
    /// An authorized MCP connector (e.g., Claude Code, Cursor integration).
    Connector {
        connector_id: String,
        authorized_by_user_id: String,
        scopes: Vec<String>,
    },
    /// Internal daemon / supervisor system worker.
    System,
}
```

### 2. Scoped Capabilities

Permissions should be resource scoped. The sketch below describes authorization permissions, which are distinct from the existing protocol feature-negotiation `hello::Capability`; avoid silently reusing that name or meaning:

```rust
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Capability {
    /// Read files and context within a specific repository.
    ReadRepo { repo_id: String },
    /// Create worktrees and propose edits on a specific repository.
    EditRepo { repo_id: String },
    /// Execute commands in a designated checkout under an explicit host policy.
    ExecuteCommand { 
        repo_id: String, 
        risk_tier: Risk,
        command_pattern: Option<String> 
    },
    /// Review, apply, or revert a change set.
    ReviewChangeSet { task_id: String },
    /// Manage project settings and model policies.
    AdminProject { project_id: String },
}
```

### 3. Unified Authorization Pipeline

The target requires all execution requests (`POST /v1/commands`, relay commands, MCP tool calls) to pass through a single validation stage; this pipeline is not integrated yet:

```text
[ Incoming Request ]
         │
         ▼
[ Extract Authenticated Principal ]
         │
         ▼
[ Resolve Resource Scope: (Workspace, Project, Repository) ]
         │
         ▼
[ Verify Principal Holds Required Capability ]
   ├── Denied ──> Returns 403 Forbidden with machine-readable auth code
   └── Granted ──> Applies execution policy and dispatches
```

### 4. Repository Allowlists & Path Capabilities

- No-follow `cap-std` capabilities constrain the application's file tools, as established in [ADR 0001](0001-local-execution-boundaries.md). They do not confine subprocesses. Process groups/job objects manage lifetime and capture; Git worktrees and CWD do not prevent commands from accessing the runner user's other files or network.
- Project repository registration and file traversal checks are planned policy inputs. Executing untrusted hosted code additionally needs a tested sandbox/VM boundary, bounded compute/storage/network and scoped credentials. Do not expand the loopback API or execution privilege to bypass a missing boundary.
- Resolve and authorize the requested resource after authentication on every execution surface. Test stale grants, cross-project paths, connector delegation, revocation and context changes; a proposed token type is not evidence these checks exist.

---

## Consequences and Limits

- **Security Posture**: Implementing and testing scoped authorization addresses one shared-runner release gate. Hosted process isolation remains a separate gate, and neither is satisfied by this document.
- **Auditability**: Proposed additive audit fields record the verified principal and resource scope alongside `decided_via`. Define retention/redaction and migration behavior; these columns are not already implemented.
- **Relay Compatibility**: Preserve the existing paired-device authenticated encryption (`crypto_box`, X25519 + XSalsa20-Poly1305) and ES256/P-256 control-plane token validation. X25519 is a key-agreement primitive, not a digital-signature key; there is no assumed Ed25519 or Noise layer. New grants need a reviewed binding to verified identities, expiry, audience, resource scope and revocation.

---

## Verification and Follow-Up

- Implement `Principal` and `Capability` types in `crates/farhelm-proto`.
- Add capability checking middleware to `crates/farhelm-runner/src/commands.rs` and `api.rs`.
- Write unit and integration tests verifying cross-project access denials.
