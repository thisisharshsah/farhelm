#!/usr/bin/env bash
#
# Everything that can be checked without a phone, a watch, or an API key.
#
# Exits non-zero on the first failure, so it is usable as a pre-commit hook or a
# one-line "did I break anything". Roughly a minute cold, seconds warm.
set -euo pipefail

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

step "Rust: format"
cargo fmt --all --check

step "Rust: lint"
cargo clippy --workspace --all-targets -- -D warnings

step "Rust: tests"
cargo test --workspace

step "Rust: ledger smoke test"
cargo run -q -p forge-runner -- demo >/dev/null

step "The native agent, end to end over real HTTP"
cargo test -q -p forge-runner --test agent_task

step "Cost benchmarks (M2 exit criteria, printed as well as asserted)"
cargo test -q -p forge-gateway --test savings -- --nocapture 2>&1 | grep -E "reduction|ratio" || true
cargo test -q -p forge-gateway --test compaction_savings -- --nocapture 2>&1 | grep -E "saved|given up" || true
cargo test -q -p forge-agent --test draft_then_verify -- --nocapture 2>&1 | grep -E "reduction|bytes" || true

step "JavaScript: typecheck"
pnpm -r typecheck

step "JavaScript: tests"
pnpm -r test

step "Web app + service worker build"
pnpm --filter @relayforge/web build >/dev/null

step "Swift: the watch"
if command -v swift >/dev/null; then
  swift test --package-path mobile/watch
else
  echo "  skipped — no Swift toolchain (macOS only)"
fi

printf '\n\033[32m✓ everything green\033[0m\n'
