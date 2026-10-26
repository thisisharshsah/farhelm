# 0001: File capabilities and managed command lifetimes

Status: accepted and implemented, October 23, 2026.

## Context

Farhelm's native agent edits a Git worktree and proposes a reviewed change. That
isolates the original checkout from ordinary file edits, but does not isolate
host execution. The prior file tools canonicalized complete paths before using
ambient filesystem calls; a missing leaf beneath a directory symlink bypassed
containment. Agent commands also collected unbounded output and a timed-out
future did not ensure termination of the shell's descendants.

Gateway prechecks could execute repository code before the command supervisor,
and missing programs were counted as passing checks. The desktop HTTP frontend
depended on the checkout's working directory despite already embedding assets.

## Decision

- Keep the existing Rust crate boundaries and add one focused library,
  `farhelm-process`, shared by agent commands and trusted gateway checks.
- Use maintained `cap-std` and `cap-fs-ext` primitives for descriptor-relative,
  no-follow file access. Reject every symlink in file-tool paths, including
  internal symlinks. Read/validate the opened handle and bound reads even if the
  file grows. Nonblocking opens prevent a replaced FIFO from hanging a file tool.
- Use `process-wrap` for Unix groups and Windows Job Objects. Drain stdout/stderr
  concurrently under one retained-byte budget, with deadline/cancellation cleanup
  and explicit cleanup errors. Keep output truncation visible.
- Disable automatic prechecks by default. Only explicit trusted-environment
  gateway configuration can enable them; ordinary agent tests use `run` and its
  existing supervisor policy. Read first-step conventions/context from the task
  checkout rather than uncommitted files in the original repository.
- Keep the existing `passed` report field for compatibility and add a defaulted
  `skipped` flag. A skipped or unexecuted check cannot make `all_green()` true.
- Return the gateway's augmented instruction to agent callers so tool-turn
  history preserves verification diagnostics/corrections byte-for-byte, keeping
  earlier prompt prefixes stable on the next call.
- Serve Tauri's compiled assets from the existing loopback HTTP origin. Keep
  API routing, MIME handling and missing-asset behavior explicit.

## Consequences and limits

These primitives improve file access and process lifecycle management; they do
not authorize untrusted hosted execution. Hard links, mounts and hostile
same-host directory mutation are not fully isolated by directory capabilities.
Opened capabilities survive renames. Shell commands can access host resources,
and hostile Unix programs can deliberately escape a process group. Hosted
customer code still requires scoped principals, credentials and a separately
tested isolation boundary.

Internal symlink paths now fail deliberately. File-tool paths/traversal are capped
at 128 components. Listings honor bounded local `.gitignore`/`.ignore` files and
in-root `.git/info/exclude`; native tasks snapshot those excludes from normal
source repositories. They do not follow external Git metadata pointers or read
ambient global exclusions. Source repositories that are themselves linked
worktrees need a future trusted metadata policy adapter for their common excludes.
Command capture retains a bounded prefix across both pipes;
users may need narrower commands to inspect omitted diagnostics.

Default precheck savings are no longer claimed by the daemon. Embeddings can
opt in through `GatewayConfig::pregate_enabled` after establishing trust; no new
daemon CLI flag is provided. This does not make a model's opinion equivalent to
a passing test suite.

Desktop assets now change when the desktop executable is rebuilt. CI must build
the real web app before compiling/testing desktop behavior. The HTTP regression
uses actual embedded assets from an unrelated working directory; native GUI,
installers and signed release bundles require separate validation.

## Verification and follow-up

Regression coverage includes missing-leaf symlink traversal, replacement races,
FIFO handling, ignored paths, bounded logs, child-process cancellation/deadlines,
truthful verification states, committed-checkout context and embedded frontend
HTTP/API behavior. CI adds macOS/Windows process tests alongside the existing
Linux workspace checks.

Next architectural work is provider-neutral routing and real local-model
conformance. Shared hosted execution remains gated on authorization and sandbox
work. Dependency upgrades must preserve the declared Rust MSRV or explicitly
change it with validation.
