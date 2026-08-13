#!/usr/bin/env bash
#
# Build what changed, install it, restart it, and prove it came back.
#
# This exists because the alternative was a five-command sequence typed from
# memory every time — build, copy, kickstart, sleep, curl — and the failure mode
# was not typing it wrong. It was typing four fifths of it: copying the binary
# and forgetting the restart, so the old process kept serving while the new
# binary sat on disk, and the next twenty minutes went into debugging a change
# that was never running.
#
#   ./deploy/redeploy.sh            everything
#   ./deploy/redeploy.sh web        just the app
#   ./deploy/redeploy.sh runner     just the daemon
#
# Verification is not optional and not a flag. A deploy script that exits 0
# without checking is a script that reports success for a service that crashed
# on startup.

set -euo pipefail

HOME_DIR="${FORGE_HOME:-$HOME/.relayforge}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BOLD=$'\033[1m'; GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; OFF=$'\033[0m'
step() { printf '%s▸ %s%s\n' "$BOLD" "$1" "$OFF"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$OFF" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$OFF" "$1"; }

what="${1:-all}"
case "$what" in
  all|web|cloud|relay|runner) ;;
  *) echo "usage: $0 [all|web|cloud|relay|runner]" >&2; exit 2 ;;
esac

wants() { [[ "$what" == "all" || "$what" == "$1" ]]; }

# ---------------------------------------------------------------- build

crates=()
wants cloud  && crates+=(-p forge-cloud)
wants relay  && crates+=(-p forge-relay)
wants runner && crates+=(-p forge-runner)

if ((${#crates[@]})); then
  step "Building"
  cargo build --release "${crates[@]}"
  mkdir -p "$HOME_DIR/bin"
  for name in forge-cloud forge-relay forge-runner; do
    case "$name" in
      forge-cloud)  wants cloud  || continue ;;
      forge-relay)  wants relay  || continue ;;
      forge-runner) wants runner || continue ;;
    esac
    # Installed to a temporary name and moved into place: `cp` onto a running
    # binary can fail with ETXTBSY, and a half-copied binary is worse than an
    # old one.
    cp "target/release/$name" "$HOME_DIR/bin/.$name.new"
    mv "$HOME_DIR/bin/.$name.new" "$HOME_DIR/bin/$name"
    ok "$name"
  done
fi

if wants web; then
  step "Building the app"
  pnpm --filter @relayforge/web build >/dev/null
  mkdir -p "$HOME_DIR/web"
  # Deleted first, so a renamed asset does not leave its predecessor behind to
  # be served to anybody holding an old index.html.
  rm -rf "${HOME_DIR:?}/web"/*
  cp -R web/dist/. "$HOME_DIR/web/"
  ok "web/dist → $HOME_DIR/web"
fi

# --------------------------------------------------------------- restart

step "Restarting"
for job in cloud relay runner tunnel; do
  case "$what" in
    all) ;;
    web)    [[ "$job" == cloud ]] || continue ;;   # the control plane serves it
    *)      [[ "$job" == "$what" ]] || continue ;;
  esac
  launchctl kickstart -k "gui/$(id -u)/com.relayforge.$job" >/dev/null 2>&1 \
    && ok "com.relayforge.$job" \
    || bad "com.relayforge.$job did not restart — is it loaded? (launchctl list | grep relayforge)"
done

# ------------------------------------------------------------------ prove

step "Checking"

# Restarting the tunnel drops every connection through it, so the public
# hostnames answer 502 for a few seconds. Retried rather than slept through:
# a fixed sleep is either too short on a slow morning or wasted every other time.
check() {
  local name="$1" url="$2" want="$3" code=""
  for _ in $(seq 1 20); do
    code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$url" || true)"
    [[ "$code" == "$want" ]] && { ok "$name $code"; return 0; }
    sleep 1
  done
  bad "$name $code (wanted $want)  $url"
  return 1
}

failed=0
check "control plane " https://farhelm.aurovie.com/v1/health        200 || failed=1
check "web app       " https://farhelm.aurovie.com/                 200 || failed=1
check "relay         " https://farhelm-relay.aurovie.com/v1/health  200 || failed=1
check "runner        " http://127.0.0.1:7852/v1/health              200 || failed=1
# 401 is the correct answer from an MCP endpoint with no token. A 200 here would
# mean the connector had stopped asking who is calling.
check "connector     " https://farhelm-mac.aurovie.com/mcp          405 || failed=1

# The one thing a status code cannot tell you: the relay refuses to start
# ungated, and a relay serving with `auth OPEN` lets anyone who learns a channel
# id join it.
if grep -aq "auth       on" "$HOME_DIR/logs/relay.log" 2>/dev/null; then
  ok "relay gating   on"
else
  bad "relay is not gated — check $HOME_DIR/logs/relay.log for 'auth OPEN'"
  failed=1
fi

# Served, but from which build? The answer to "why is my change not showing up"
# more often than anything else.
if wants web; then
  built_asset="$(basename "$(ls -t web/dist/assets/*.js | head -1)")"
  served_asset="$(curl -s -m 10 https://farhelm.aurovie.com/ \
    | grep -oE 'assets/index-[A-Za-z0-9_-]+\.js' | head -1 || true)"
  if [[ "$served_asset" == "assets/$built_asset" ]]; then
    ok "serving $built_asset"
  else
    bad "serving ${served_asset:-nothing}, built $built_asset"
    failed=1
  fi
fi

echo
if ((failed)); then
  printf '%s✗ something is not up%s  %slogs: %s/logs%s\n' "$RED" "$OFF" "$DIM" "$HOME_DIR" "$OFF"
  exit 1
fi
printf '%s✓ deployed%s\n' "$GREEN" "$OFF"
