#!/usr/bin/env bash
#
# Keep the live web app in step with this checkout while you work.
#
#   ./deploy/live-web.sh          watch, rebuild on every change, swap it live
#   ./deploy/live-web.sh --once   one build and swap, then exit
#
# The control plane on this machine serves `web/dist` straight from the repo
# (`farhelm cloud --app-dir web/dist`), so whatever is in that directory is
# what https://farhelm.aurovie.com serves. Building into it directly would put
# the site down for the length of every build, and leave it empty after a
# failed one. So each build goes to a staging directory, and is swapped in
# only when the typecheck, the app build and the service worker build all
# passed. A broken edit leaves the live site exactly as it was.
#
# The service worker is network-first, so a visitor gets the new build on
# their next load; nothing here needs to invalidate a cache.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LIVE_URL="${LIVE_URL:-https://farhelm.aurovie.com}"
STAGE="web/.dist-next"
INSTALLED_WEB="${INSTALLED_WEB:-$HOME/.farhelm/web}"
WATCH=(web/src web/public web/index.html packages/client-core/src)

GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; OFF=$'\033[0m'
log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$1"; }

# Modification time, size and path of every watched file. Polled rather than
# using fswatch, which is not installed by default on macOS.
fingerprint() {
  find "${WATCH[@]}" -type f -not -name '.DS_Store' -exec stat -f '%m %z %N' {} + 2>/dev/null \
    | sort | shasum | cut -d' ' -f1
}

build_and_swap() {
  rm -rf "$STAGE"
  log "building…"
  local out
  if ! out="$(cd web && npx tsc -b 2>&1 \
      && npx vite build --outDir .dist-next --emptyOutDir 2>&1 \
      && npx vite build --config vite.sw.config.ts --outDir .dist-next 2>&1)"; then
    printf '%s\n' "$out" | grep -E 'error|Error' | head -12
    log "${RED}✗ build failed; the live site is unchanged${OFF}"
    rm -rf "$STAGE"
    return 1
  fi

  # Two renames, so the window without a `web/dist` is a few microseconds
  # rather than the length of a copy.
  rm -rf web/.dist-old
  [[ -d web/dist ]] && mv web/dist web/.dist-old
  mv "$STAGE" web/dist
  rm -rf web/.dist-old

  # The installed runner serves its own copy (`~/.farhelm/web`) at
  # http://127.0.0.1:7842, which otherwise stays at whatever build the last
  # install left there. Swapped the same way, so a local tab never loads half a
  # build.
  if [[ -d "$INSTALLED_WEB" ]]; then
    rm -rf "$INSTALLED_WEB.next" "$INSTALLED_WEB.old"
    cp -R web/dist "$INSTALLED_WEB.next"
    mv "$INSTALLED_WEB" "$INSTALLED_WEB.old"
    mv "$INSTALLED_WEB.next" "$INSTALLED_WEB"
    rm -rf "$INSTALLED_WEB.old"
  fi

  local built served
  built="$(grep -oE 'assets/index-[A-Za-z0-9_-]+\.js' web/dist/index.html | head -1)"
  # Retried: the tunnel's edge drops a request now and then for a few seconds,
  # and one miss is not evidence that the swap did not take.
  for _ in 1 2 3 4 5; do
    served="$(curl -s -m 10 "$LIVE_URL/" | grep -oE 'assets/index-[A-Za-z0-9_-]+\.js' | head -1 || true)"
    [[ "$served" == "$built" ]] && break
    sleep 3
  done
  if [[ -n "$built" && "$served" == "$built" ]]; then
    log "${GREEN}✓ live${OFF} ${DIM}$LIVE_URL serving $built${OFF}"
  else
    log "${RED}✗ built $built but $LIVE_URL serves ${served:-nothing}${OFF}. Is farhelm cloud running with --app-dir web/dist?"
    return 1
  fi
}

if [[ "${1:-}" == "--once" ]]; then
  build_and_swap
  exit $?
fi

log "watching ${WATCH[*]} ${DIM}(ctrl-c to stop)${OFF}"
last="$(fingerprint)"
build_and_swap || true
while true; do
  sleep 2
  now="$(fingerprint)"
  [[ "$now" == "$last" ]] && continue
  # Wait for a burst of saves to settle, so a multi-file edit is one build.
  while sleep 1.5; do
    settled="$(fingerprint)"
    [[ "$settled" == "$now" ]] && break
    now="$settled"
  done
  last="$now"
  build_and_swap || true
done
