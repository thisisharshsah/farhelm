# Deploying to `farhelm.aurovie.com`

One Cloudflare tunnel, two hostnames, three processes. Your runner stays on your
own machine and is never reachable from the internet — it dials *out*.

```text
                    ┌──────────────────── Cloudflare ────────────────────┐
                    │                                                    │
  farhelm.aurovie.com ──▶ forge-cloud   :7844   accounts, plans, the PWA, MCP
  farhelm-relay.aurovie.com ──▶ forge-relay :7843   ciphertext fan-out
  farhelm-mac.aurovie.com   ──▶ forge-runner :7852  this machine's MCP connector
                    │                                                    │
                    └────────────────────────────────────────────────────┘
                                          ▲
                                          │ outbound only
                                   forge-runner (your laptop, your
                                   home server — no inbound port)
```

Nothing in the tunnel can read your code. The relay forwards envelopes sealed to
a device key it has never seen, and the control plane holds accounts and public
keys. Compromising either is an access problem, not a content one — see
`crates/forge-crypto/src/lib.rs`.

## Why a second tunnel

You already run a tunnel (`quantnepal`) with live connections serving
`quantnepal.com` and `aurovie.com`. Nothing here touches it. A separate
`farhelm` tunnel means restarting or reconfiguring one cannot take the other
down, and the two have genuinely different uptime stories.

## Two ways this goes wrong silently

Both of these were hit while bringing this up. Neither produces an error at the
time, which is why they are at the top rather than in a troubleshooting section.

### `route dns` appends instead of failing

`cloudflared tunnel login` writes `cert.pem` scoped to **one zone**. If you then
`route dns` a hostname in a *different* zone, it does not refuse — it treats the
whole thing as a label and creates
`farhelm.aurovie.com.thezoneyouactuallyhave.com`, pointing at whatever tunnel it
felt like. Check the record it printed is exactly the hostname you asked for.

With several zones, keep one cert per zone and name it explicitly:

```sh
cloudflared tunnel --origincert ~/.cloudflared/cert-aurovie.pem create farhelm
```

### `route dns` ignores the tunnel you named

If `~/.cloudflared/config.yml` exists and has a `tunnel:` key, `route dns` points
the record at **that** tunnel, not the one on the command line — silently. On a
machine with an existing tunnel this sends the new hostname to the old service.
Verify with the API, or just check the CNAME target afterwards:

```sh
dig +short farhelm.aurovie.com CNAME     # must be <your-uuid>.cfargotunnel.com
```

### …and one that fails loudly, late

Universal SSL covers `aurovie.com` and `*.aurovie.com` — **one level only**. A
host like `relay.farhelm.aurovie.com` gets no certificate and every client dies
with a TLS handshake failure while the tunnel and origin look perfectly healthy.
That is why the relay is `farhelm-relay.aurovie.com` and not
`relay.farhelm.aurovie.com`. Multi-level wildcards need Advanced Certificate
Manager, which is paid.

## 1. Create the tunnel and its DNS records

These commands create real DNS records on `aurovie.com`. Run them yourself so
you can see exactly what changes:

```sh
cloudflared tunnel --origincert ~/.cloudflared/cert-aurovie.pem create farhelm
cloudflared tunnel --origincert ~/.cloudflared/cert-aurovie.pem \
  route dns farhelm farhelm.aurovie.com
cloudflared tunnel --origincert ~/.cloudflared/cert-aurovie.pem \
  route dns farhelm farhelm-relay.aurovie.com
```

The first prints a UUID and writes `~/.cloudflared/<UUID>.json`. Note the UUID —
step 2 needs it. Then **check both CNAMEs point at that UUID**, per the second
trap above.

## 2. Write the tunnel config

Copy [`cloudflared/farhelm.yml`](cloudflared/farhelm.yml) to
`~/.cloudflared/farhelm.yml` and replace `TUNNEL-UUID` with what step 1 printed:

```sh
sed "s/TUNNEL-UUID/$(cloudflared tunnel list --output json \
      | python3 -c 'import json,sys;print([t["id"] for t in json.load(sys.stdin) if t["name"]=="farhelm"][0])')/" \
    deploy/cloudflared/farhelm.yml > ~/.cloudflared/farhelm.yml
```

Your existing `~/.cloudflared/config.yml` is untouched, and this file is passed
explicitly with `--config`, so the two never collide.

## 3. Build and install

```sh
cargo build --release -p forge-cloud -p forge-relay -p forge-runner
pnpm --filter @relayforge/web build

sudo install -m755 target/release/forge-cloud target/release/forge-relay /usr/local/bin/
sudo mkdir -p /usr/local/share/relayforge
sudo cp -r web/dist /usr/local/share/relayforge/web
sudo mkdir -p /var/lib/relayforge
```

## 4. Configure

```sh
sudo cp deploy/farhelm.env.example /etc/relayforge.env
sudo chmod 600 /etc/relayforge.env      # it holds a Stripe key
sudo $EDITOR /etc/relayforge.env
```

Billing is **off** until `STRIPE_SECRET_KEY` is set, and off is a supported
configuration — every workspace runs on the Free plan's limits. Nothing below
requires a Stripe account.

## 5. Start

The order matters exactly once: the relay needs the control plane's public key,
so the control plane goes first.

```sh
sudo cp deploy/systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now forge-cloud forge-relay cloudflared-farhelm
```

On macOS there is no systemd. Run the three by hand, or use
[`launchd/`](launchd/) — the units there are the same commands.

Confirm:

```sh
curl -s https://farhelm.aurovie.com/v1/health | python3 -m json.tool
curl -s https://farhelm-relay.aurovie.com/v1/health | python3 -m json.tool
```

The relay's `auth` field should show a key id rather than `null`. `null` means
it started without `--auth-from`, and **anyone who learns a channel id can join
it** — see `crates/forge-relay/src/auth.rs`.

## 6. Add a machine

Open `https://farhelm.aurovie.com`, create an account, then
**Workspace → Add a machine → Create key**. On the machine you want to
supervise:

```sh
export FORGE_CLOUD_KEY=frg_…                     # not on the command line —
export FORGE_CLOUD_URL=https://farhelm.aurovie.com   # it ends up in `ps`
forge-runner serve
```

It appears in your fleet within thirty seconds. There is no code to type on
either side, and no network you have to be on.

## What runs where

| Process | Binds | Reachable from the internet | Holds |
|---|---|---|---|
| `forge-cloud` | `127.0.0.1:7844` | via the tunnel | accounts, plans, public keys |
| `forge-relay` | `127.0.0.1:7843` | via the tunnel | nothing across a restart |
| `forge-runner` | `127.0.0.1:7842` | **no** | your repositories, your keys |
| `cloudflared` | — | outbound only | tunnel credentials |

Both server processes bind loopback and are reached *through* the tunnel. That
is not decoration: it means a misconfigured firewall cannot expose them, because
there is nothing listening on a routable address to expose.

## Stripe

Four values, all optional:

| Variable | What it is |
|---|---|
| `STRIPE_SECRET_KEY` | `sk_live_…` or a restricted key with Checkout + Billing Portal |
| `STRIPE_WEBHOOK_SECRET` | `whsec_…`. **Without it every webhook is refused** — an empty secret is not treated as "skip the check" |
| `STRIPE_PRICE_PRO` | the recurring price id for Pro |
| `STRIPE_PRICE_TEAM` | the recurring price id for Team |

Point the webhook at `https://farhelm.aurovie.com/v1/billing/webhook` and
subscribe to `checkout.session.completed`,
`customer.subscription.created/updated/deleted`. Everything else is ignored on
purpose — reacting to invoice events too would mean two sources of truth for
what plan somebody is on.

## Backups

Two files, and losing either has a different consequence:

| File | Losing it means |
|---|---|
| `/var/lib/relayforge/forge-cloud.db` | every account, workspace and machine is gone |
| `/var/lib/relayforge/forge-cloud.key` | everyone is signed out, and the relay refuses every token until reconfigured |

```sh
sqlite3 /var/lib/relayforge/forge-cloud.db ".backup /backup/forge-cloud.db"
cp /var/lib/relayforge/forge-cloud.key /backup/
```

The relay's `vapid.key` is worth keeping too: every browser push subscription is
bound to the public half it saw, so a new key silently stops waking every device
that ever subscribed.

## Connectors (MCP)

Two URLs go in Claude's **Add custom connector** dialog. Leave both Advanced
fields blank in each case — the control plane implements dynamic client
registration, so Claude registers itself and you never paste a client id or
secret.

| URL | What Claude can do with it |
|---|---|
| `https://farhelm.aurovie.com/mcp` | See the fleet: machines, online status, plan and limits |
| `https://farhelm-mac.aurovie.com/mcp` | Supervise *this machine*: sessions, pending approvals, proposed diffs, spend — and start work |

There is **one** authorization server. The machine connector's
`/.well-known/oauth-protected-resource` names `farhelm.aurovie.com` as its
issuer, so you sign in once with the account you already have and both
connectors are authorised by the same grant.

### Which way the arrows point

A connector lets **Claude call your tools**. It does not give this system access
to a model, and it does not route Claude's own reasoning through the cost
gateway — when you chat in the Claude app, inference happens on Anthropic's side
and this server never sees it.

What that buys is still worth having: the conversation runs on a Claude
subscription rather than metered API tokens, and the calls that genuinely need
the API can be made *through* `start_task`, which puts them through the
gateway's eight stages. The thing that actually does "everything through the
system first" is `POST /v1/complete` on the runner — point a tool at that
instead of `api.anthropic.com`.

### Why the fleet connector cannot read your code

The control plane has never held a key that could decrypt a session, and adding
a connector did not change that. If `farhelm.aurovie.com/mcp` could answer
"show me the diff", a compromise there would stop being an access problem and
start being a content one. So the tools that read plaintext live on the machine
that already has it, behind its own URL.

### What a connector may never do

Clear a destructive command. `forge_domain`'s rule bars `DecidedVia::Connector`
from anything classified destructive, enforced at the same executor every other
transport goes through — an agent that could approve its own `rm -rf` would be
an agent supervising itself. Claude can see the command and tell you about it;
clearing it needs a person on the phone or the web app.

Decisions a connector *does* make are recorded as `decided_via: connector`,
never disguised as `web` — "a language model cleared this" is a materially
different answer from "a person did", and that column exists to tell them apart.

### Adding a second machine

Give that runner its own hostname and point it at its loopback port:

```sh
cloudflared tunnel --origincert ~/.cloudflared/cert-aurovie.pem \
  route dns farhelm farhelm-<name>.aurovie.com
# then in ~/.cloudflared/farhelm.yml, map it to that runner's port, and start it with:
FORGE_MCP_URL=https://farhelm-<name>.aurovie.com forge-runner serve …
```

Keep the hostname **first-level** (`farhelm-<name>`, not `<name>.farhelm`) — see
the Universal SSL note at the top of this file.

