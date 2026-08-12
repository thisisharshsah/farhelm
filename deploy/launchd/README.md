# Running it on macOS, across reboots

Four `launchd` jobs. Everything lives under `~/.relayforge/`, so no `sudo` is
needed and nothing depends on the repository still being checked out where it is
today.

| Job | What it runs | Port |
|---|---|---|
| `com.relayforge.cloud` | control plane: accounts, plans, the PWA, the fleet connector | 7844 |
| `com.relayforge.relay` | ciphertext fan-out, gated by the control plane's key | 7843 |
| `com.relayforge.runner` | the daemon, plus this machine's own connector | 7852 |
| `com.relayforge.tunnel` | `cloudflared`, mapping all three to public hostnames | — |

## Install

```sh
mkdir -p ~/.relayforge/{bin,logs}
cargo build --release -p forge-cloud -p forge-relay -p forge-runner
cp target/release/{forge-cloud,forge-relay,forge-runner} ~/.relayforge/bin/
pnpm --filter @relayforge/web build && cp -r web/dist ~/.relayforge/web

cp deploy/launchd/plist/*.plist ~/Library/LaunchAgents/
for j in cloud relay runner tunnel; do
  launchctl load ~/Library/LaunchAgents/com.relayforge.$j.plist
done
```

Then create `~/.relayforge/runner.env`, **mode 0600**:

```sh
cat > ~/.relayforge/runner.env <<'ENV'
FORGE_CLOUD_URL=https://farhelm.aurovie.com
FORGE_CLOUD_KEY=frg_…
FORGE_MCP_URL=https://farhelm-mac.aurovie.com
ENV
chmod 600 ~/.relayforge/runner.env
```

The enrolment key is a credential, which is why it is in that file and not in
the plist: `~/Library/LaunchAgents` is not a secret store. The runner job is
`/bin/sh -c` for exactly one reason — to source it, which `launchd` cannot do.

## Two things that will bite you

### `runner.key` is this machine's identity — never lose it

The runner's key file *is* what the control plane pins at first enrolment.
Start the runner with a different one and it enrols as a stranger under the same
hostname: the fleet shows **"this machine's identity changed"**, devices are
refused a channel token, and an admin has to confirm it by hand.

So it lives at `~/.relayforge/runner.key`, mode 0600, and it belongs in whatever
you back up. Running the daemon from a scratch directory works right up until
the directory is cleaned, at which point the machine silently becomes a
different machine.

### `launchd` has no dependency ordering

All four start at the same instant. The relay and the runner both need the
control plane's verifying key at startup, and at boot they reliably ask before
it is listening.

The relay handles this by exiting, so `KeepAlive` restarts it. The runner does
**not** exit — it falls back to loopback-only and keeps running — so `KeepAlive`
cannot help, and a single failed attempt would leave it healthy but unenrolled
until somebody noticed. That is why enrolment retries with backoff for two
minutes (`ENROLL_DEADLINE` in `crates/forge-runner/src/cloud.rs`). A *refusal* —
a revoked key, a machine removed from the workspace — is not retried, because
that is an answer rather than a race.

## Check it

```sh
launchctl list | grep relayforge          # PID, last exit status, label
tail -f ~/.relayforge/logs/runner.log
```

The runner's banner should show the **same** identity every time:

```
cloud      enrolled as run_… in org_…
identity   EQFBp4_IT1b4WRx2Y2BLZEHn3XFEjs5qIfhTMfMLyms (…/runner.key)
connector  https://farhelm-mac.aurovie.com/mcp  (org org_…)
relay link: connected to wss://farhelm-relay.aurovie.com/…
```

And the relay's should say `auth on`, never `auth OPEN` — `OPEN` means it could
not reach the control plane and started ungated, which is the one failure here
that is invisible from outside.

Verify a restart survives without waiting for a reboot:

```sh
pkill -9 -f 'forge-cloud|forge-relay|forge-runner|cloudflared'
sleep 30 && launchctl list | grep relayforge   # new PIDs
curl -s https://farhelm.aurovie.com/v1/health
```

## Update, stop, remove

```sh
# after a rebuild
cp target/release/forge-runner ~/.relayforge/bin/
launchctl kickstart -k gui/$(id -u)/com.relayforge.runner

# stop one, or all
launchctl unload ~/Library/LaunchAgents/com.relayforge.runner.plist

# remove entirely
for j in cloud relay runner tunnel; do
  launchctl unload ~/Library/LaunchAgents/com.relayforge.$j.plist
  rm ~/Library/LaunchAgents/com.relayforge.$j.plist
done
```

## Back up

| File | Losing it means |
|---|---|
| `~/.relayforge/forge-cloud.key` | everyone signed out; the relay refuses every token until reconfigured |
| `~/.relayforge/forge-cloud.db` | every account, workspace and machine gone |
| `~/.relayforge/runner.key` | this machine re-enrols as a stranger and needs confirming |
| `~/.relayforge/vapid.key` | every existing push subscription silently stops waking its device |
