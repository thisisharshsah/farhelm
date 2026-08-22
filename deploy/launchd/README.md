# Running it on macOS, across reboots

Four `launchd` jobs. Everything lives under `~/.farhelm/`, so no `sudo` is
needed and nothing depends on the repository still being checked out where it is
today.

| Job | What it runs | Port |
|---|---|---|
| `com.farhelm.cloud` | control plane: accounts, plans, the PWA, the fleet connector | 7844 |
| `com.farhelm.relay` | ciphertext fan-out, gated by the control plane's key | 7843 |
| `com.farhelm.runner` | the daemon, plus this machine's own connector | 7852 |
| `com.farhelm.tunnel` | `cloudflared`, mapping all three to public hostnames | — |

## Install

```sh
mkdir -p ~/.farhelm/{bin,logs}
cargo build --release -p farhelm-cloud -p farhelm-relay -p farhelm-runner
cp target/release/{farhelm-cloud,farhelm-relay,farhelm-runner} ~/.farhelm/bin/
pnpm --filter @farhelm/web build && cp -r web/dist ~/.farhelm/web

cp deploy/launchd/plist/*.plist ~/Library/LaunchAgents/
for j in cloud relay runner tunnel; do
  launchctl load ~/Library/LaunchAgents/com.farhelm.$j.plist
done
```

Then create `~/.farhelm/runner.env`, **mode 0600**:

```sh
cat > ~/.farhelm/runner.env <<'ENV'
FORGE_CLOUD_URL=https://farhelm.aurovie.com
FORGE_CLOUD_KEY=frg_…
FORGE_MCP_URL=https://farhelm-mac.aurovie.com
ENV
chmod 600 ~/.farhelm/runner.env
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

So it lives at `~/.farhelm/runner.key`, mode 0600, and it belongs in whatever
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
minutes (`ENROLL_DEADLINE` in `crates/farhelm-runner/src/cloud.rs`). A *refusal* —
a revoked key, a machine removed from the workspace — is not retried, because
that is an answer rather than a race.

## Check it

```sh
launchctl list | grep farhelm          # PID, last exit status, label
tail -f ~/.farhelm/logs/runner.log
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
pkill -9 -f 'farhelm-cloud|farhelm-relay|farhelm-runner|cloudflared'
sleep 30 && launchctl list | grep farhelm   # new PIDs
curl -s https://farhelm.aurovie.com/v1/health
```

## Update, stop, remove

```sh
# after a rebuild
cp target/release/farhelm ~/.farhelm/bin/
launchctl kickstart -k gui/$(id -u)/com.farhelm.runner

# stop one, or all
launchctl unload ~/Library/LaunchAgents/com.farhelm.runner.plist

# remove entirely
for j in cloud relay runner tunnel; do
  launchctl unload ~/Library/LaunchAgents/com.farhelm.$j.plist
  rm ~/Library/LaunchAgents/com.farhelm.$j.plist
done
```

## Back up

| File | Losing it means |
|---|---|
| `~/.farhelm/farhelm-cloud.key` | everyone signed out; the relay refuses every token until reconfigured |
| `~/.farhelm/farhelm-cloud.db` | every account, workspace and machine gone |
| `~/.farhelm/runner.key` | this machine re-enrols as a stranger and needs confirming |
| `~/.farhelm/vapid.key` | every existing push subscription silently stops waking its device |
