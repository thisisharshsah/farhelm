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

step "forge-domain stays pure"
# The rules are the part of the system worth being certain about, and certainty
# comes from being able to test them without arranging a world first. Nothing in
# forge-domain may read a clock, open a file, await, or reach the network.
#
# This is a grep because there is no cargo flag for it. forge-core once claimed
# the same property in its own doc header while depending directly on rusqlite,
# which is how a claim nobody checks ends up false.
if grep -rnE '(^|[^a-z_])(std::fs|std::io|std::net|std::process|tokio|reqwest|rusqlite|SystemTime|Instant::now)' \
     crates/forge-domain/src --include='*.rs' | grep -v '^\S*:[0-9]*://'; then
  echo "  forge-domain must stay free of I/O, async and the clock — see the hits above"
  exit 1
fi
echo "  no I/O, async, clock or network"

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

step "The wire contract, read by both languages"
# forge-proto writes a fixture from its own types; client-core's wire.test.ts
# asserts every field its hand-written interfaces declare is actually in it. The
# Rust half alone cannot catch a rename, because it renames both sides at once.
cargo test -q -p forge-proto --test wire_fixture

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
