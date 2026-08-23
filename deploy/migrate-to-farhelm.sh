#!/usr/bin/env bash
#
# Move a deployment from the old names to the new ones, once.
#
#   ./deploy/migrate-to-farhelm.sh --dry-run    say what it would do
#   ./deploy/migrate-to-farhelm.sh              do it
#
# What changed, and therefore what this moves:
#
#   ~/.relayforge                  →  ~/.farhelm
#   bin/{forge-cloud,forge-relay,forge-runner}  →  bin/farhelm  (one binary)
#   com.relayforge.{cloud,relay,runner,tunnel}  →  com.farhelm.*
#
# The daemon reads the old *file* names by itself — forge.db, forge.key,
# forge.cloud.json and the rest keep working wherever they lie, and are left
# alone here. What it cannot do by itself is notice that its own launchd job
# points at a binary that is no longer built under that name, which is the one
# thing this script exists for.
#
# Three properties worth knowing before running it:
#
#   Nothing is deleted. The old directory becomes a symlink to the new one, so
#   anything still pointing at `~/.relayforge` — a shell alias, a checked-in
#   path, a plist this script did not find — keeps working rather than failing
#   at the least convenient moment. The old plists are moved aside, not removed.
#
#   It is idempotent. Re-running it after a partial failure finishes the job
#   rather than doubling it.
#
#   It verifies before it claims. A migration that swaps a service and exits 0
#   without checking is how you find out at the next reboot.
#
set -euo pipefail

OLD_HOME="$HOME/.relayforge"
NEW_HOME="$HOME/.farhelm"
AGENTS="$HOME/Library/LaunchAgents"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BOLD=$'\033[1m'; GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; OFF=$'\033[0m'
step() { printf '\n%s▸ %s%s\n' "$BOLD" "$1" "$OFF"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$OFF" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$OFF" "$1"; }
note() { printf '  %s·%s %s\n' "$DIM" "$OFF" "$1"; }

DRY=no
[ "${1:-}" = "--dry-run" ] && DRY=yes
run() {
  if [ "$DRY" = yes ]; then printf '  %swould:%s %s\n' "$DIM" "$OFF" "$*"; else "$@"; fi
}

[ "$DRY" = yes ] && printf '\n%sDry run — nothing will be changed.%s\n' "$BOLD" "$OFF"

# ------------------------------------------------------------------ build ---
#
# Before anything is stopped. A migration that takes the services down and
# *then* discovers the build is broken has turned a rename into an outage.

step "Building the one binary"
if [ "$DRY" = yes ]; then
  note "cargo build --release -p farhelm-runner"
else
  ( cd "$ROOT" && cargo build --release -p farhelm-runner )
  [ -x "$ROOT/target/release/farhelm" ] || { bad "target/release/farhelm was not produced"; exit 1; }
  ok "target/release/farhelm"
fi

# ------------------------------------------------------------------- move ---

step "The state directory"
if [ -L "$OLD_HOME" ]; then
  ok "already migrated — $OLD_HOME is a link to $(readlink "$OLD_HOME")"
elif [ -d "$NEW_HOME" ] && [ -d "$OLD_HOME" ]; then
  bad "both $OLD_HOME and $NEW_HOME exist and neither is a link."
  echo "     Merge them by hand — refusing to guess which one is live."
  exit 1
elif [ -d "$OLD_HOME" ]; then
  run mv "$OLD_HOME" "$NEW_HOME"
  # The link is the whole reason this is safe to run on a live machine: every
  # absolute path anybody ever wrote down still resolves.
  run ln -s "$NEW_HOME" "$OLD_HOME"
  ok "$OLD_HOME → $NEW_HOME  (old path kept as a link)"
else
  run mkdir -p "$NEW_HOME/bin" "$NEW_HOME/logs"
  ok "created $NEW_HOME"
fi

step "The binary"
run mkdir -p "$NEW_HOME/bin"
if [ "$DRY" = no ]; then
  cp "$ROOT/target/release/farhelm" "$NEW_HOME/bin/.farhelm.new"
  mv "$NEW_HOME/bin/.farhelm.new" "$NEW_HOME/bin/farhelm"
fi
ok "$NEW_HOME/bin/farhelm"
note "the three old binaries are left in place; delete them once this is proven"

# ---------------------------------------------------------------- services ---
#
# Generated from the checked-in templates with this machine's home substituted,
# rather than edited in place: the templates are what the next machine gets, and
# a migration that only fixed this one would leave them wrong for everybody.

step "Launch agents"
migrated_any=no
for job in cloud relay runner tunnel; do
  old_label="com.relayforge.$job"
  new_label="com.farhelm.$job"
  old_plist="$AGENTS/$old_label.plist"
  target="$AGENTS/$new_label.plist"

  [ -f "$old_plist" ] || { note "$new_label — nothing to migrate from, skipped"; continue; }

  # Derived from the job that is *running*, never regenerated from the
  # checked-in template.
  #
  # The first version of this script wrote the template out instead, and that
  # is not a stylistic difference — a template is what the next machine should
  # get, and it drifts from what this one actually has. On the deployment this
  # was written for it drifted twice: the template named a `cloudflared` at a
  # path that does not exist here, so the tunnel died with a config error and
  # every public hostname answered 530; and it named the post-rename database,
  # which SQLite obligingly created empty, so the control plane came up with no
  # accounts in it and told this machine its own enrolment key was invalid.
  #
  # Neither failed loudly. Both looked like the migration having broken the
  # system rather than having pointed it somewhere new. So the only things
  # changed here are the three that genuinely have to change — the label, the
  # binary, and the home directory — and every other value is carried across
  # exactly as it was found.
  if [ "$DRY" = no ]; then
    sed -e "s|$old_label|$new_label|g" \
        -e "s|$OLD_HOME|$NEW_HOME|g" \
        -e "s|$NEW_HOME/bin/forge-runner|$NEW_HOME/bin/farhelm|g" \
        -e "s|$NEW_HOME/bin/forge-cloud|$NEW_HOME/bin/farhelm</string>\n\t\t<string>cloud|g" \
        -e "s|$NEW_HOME/bin/forge-relay|$NEW_HOME/bin/farhelm</string>\n\t\t<string>relay|g" \
        "$old_plist" > "$target"
    plutil -lint "$target" >/dev/null || { bad "$target is not valid — left unloaded"; continue; }
  else
    note "$new_label — rewritten from $old_plist, keeping its own paths"
  fi

  # Unload the old job before loading the new one: both bind the same port, and
  # two of them running means the second fails and the first keeps serving the
  # old build, which looks exactly like the migration having done nothing.
  if launchctl list 2>/dev/null | grep -q "$old_label"; then
    run launchctl unload "$AGENTS/$old_label.plist" 2>/dev/null || true
    run mv "$AGENTS/$old_label.plist" "$AGENTS/$old_label.plist.migrated"
    migrated_any=yes
  fi

  run launchctl unload "$target" 2>/dev/null || true
  run launchctl load -w "$target"
  ok "$new_label"
done

[ "$migrated_any" = no ] && note "no old jobs were loaded — nothing to take over from"

# ------------------------------------------------------------------ prove ---

if [ "$DRY" = yes ]; then
  printf '\n%sDry run complete. Nothing was changed.%s\n\n' "$BOLD" "$OFF"
  exit 0
fi

step "Checking"
check() {
  local name="$1" url="$2" code=""
  for _ in $(seq 1 20); do
    code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$url" || true)"
    [ "$code" = "200" ] && { ok "$name"; return 0; }
    sleep 1
  done
  bad "$name — $code from $url"
  return 1
}

failed=0
check "runner        " http://127.0.0.1:7852/v1/health             || failed=1
check "control plane " https://farhelm.aurovie.com/v1/health       || failed=1
check "relay         " https://farhelm-relay.aurovie.com/v1/health || failed=1

echo
if [ "$failed" = 0 ]; then
  printf '%s✓ migrated, and everything answered.%s\n\n' "$GREEN" "$OFF"
  echo "  The old plists are beside the new ones as *.plist.migrated, and"
  echo "  $OLD_HOME still resolves. Remove both once you are satisfied:"
  echo "    rm $AGENTS/com.relayforge.*.plist.migrated"
  echo "    rm $NEW_HOME/bin/forge-{cloud,relay,runner}"
  echo
else
  printf '%s✗ something did not come back.%s\n\n' "$RED" "$OFF"
  echo "  To go back: the old plists are at $AGENTS/com.relayforge.*.plist.migrated"
  echo "    for f in $AGENTS/com.relayforge.*.plist.migrated; do mv \"\$f\" \"\${f%.migrated}\"; done"
  echo "    launchctl unload $AGENTS/com.farhelm.*.plist"
  echo "    launchctl load -w $AGENTS/com.relayforge.*.plist"
  echo "  Nothing was deleted, so this restores what was running."
  exit 1
fi
