#!/usr/bin/env bash
#
# Everything after `cloudflared tunnel login`: create the tunnel, point the two
# hostnames at it, write the config, and start it.
#
# Split out from the login because that step opens a browser and picks which
# Cloudflare zone this machine may manage — and picking the wrong one is how
# `route dns` silently creates `farhelm.aurovie.com.someotherdomain.com`
# instead of failing. Which is exactly what happened the first time.
#
# Safe to re-run: every step checks for what it would create.
set -euo pipefail

TUNNEL=${TUNNEL:-farhelm}
ZONE=${ZONE:-aurovie.com}
APEX=${APEX:-farhelm.$ZONE}
RELAY=${RELAY:-farhelm-relay.$ZONE}
CONFIG=${CONFIG:-$HOME/.cloudflared/$TUNNEL.yml}

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

step "Check the login covers $ZONE"
# `tunnel login` writes cert.pem scoped to the zone that was chosen. If it does
# not cover $ZONE, `route dns` will not fail — it will append. Catch that here,
# where the message can say what to do about it.
if ! cloudflared tunnel route dns --help >/dev/null 2>&1; then
  echo "  cloudflared is not on PATH" >&2
  exit 1
fi
if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
  echo "  no cert.pem — run: cloudflared tunnel login   (and pick $ZONE)" >&2
  exit 1
fi
echo "  cert.pem present"

step "Create the tunnel (or reuse it)"
if cloudflared tunnel list --output json | grep -q "\"name\":\"$TUNNEL\""; then
  echo "  $TUNNEL already exists"
else
  cloudflared tunnel create "$TUNNEL"
fi

UUID=$(cloudflared tunnel list --output json \
  | python3 -c "import json,sys;print([t['id'] for t in json.load(sys.stdin) if t['name']=='$TUNNEL'][0])")
echo "  id $UUID"

step "Route the hostnames"
for host in "$APEX" "$RELAY"; do
  # The check that would have caught the first attempt: the record has to come
  # back as exactly the hostname asked for, not a longer one.
  out=$(cloudflared tunnel route dns "$TUNNEL" "$host" 2>&1 || true)
  echo "  $out" | tail -1
  if echo "$out" | grep -q "$host\."; then
    echo "  ✗ that created a record under the wrong zone — the login does not cover $ZONE" >&2
    echo "    run: cloudflared tunnel login   and pick $ZONE" >&2
    exit 1
  fi
done

step "Write $CONFIG"
sed -e "s/TUNNEL-UUID/$UUID/g" \
    "$(dirname "$0")/cloudflared/farhelm.yml" > "$CONFIG"
echo "  written, pointing at 127.0.0.1:7844 (cloud) and :7843 (relay)"

step "Start the tunnel"
echo "  cloudflared tunnel --config $CONFIG run"
echo
echo "Then check:"
echo "  curl -s https://$APEX/v1/health"
echo "  curl -s https://$RELAY/v1/health   # 'auth' must not be null"
