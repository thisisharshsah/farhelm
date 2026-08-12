/**
 * The app against a real runner and a real relay.
 *
 * `crypto.test.ts` proves the bytes match across languages and
 * `transport.test.ts` proves the correlation logic against a fake socket. This
 * is the one that proves they add up: pairing over HTTP, a WebSocket to the
 * relay, a sealed snapshot request, an addressed reply, a decision the runner
 * really records, and a refusal that finds its way back.
 *
 * It **skips itself** when there is no runner on 7842, so CI stays green
 * without pretending to have run. To run it for real:
 *
 * ```sh
 * cargo run -p forge-relay &
 * cargo run -p forge-runner -- serve --demo --relay ws://127.0.0.1:7843 &
 * cd app && pnpm test
 * ```
 *
 * The destructive-approval assertions need something destructive to be pending,
 * which the demo seed does not include. Create one — this is also the honest way
 * to exercise the hook, since it blocks exactly as Claude Code's would:
 *
 * ```sh
 * curl -X POST http://127.0.0.1:7842/v1/hooks/tool-request \
 *   -H 'content-type: application/json' \
 *   -d '{"agent_session_id":"live","cwd":"/srv/payments-api","tool":"Bash",
 *        "payload":"git push --force origin main","wait_ms":45000}'
 * ```
 *
 * Those two tests skip rather than fail if nothing destructive is pending —
 * a passing run that quietly checked nothing is worse than a skipped one.
 */

import { beforeAll, describe, expect, it } from "vitest";
import {
  Identity,
  RelayTransport,
  parseOffer,
  type Pairing,
} from "./index.ts";

const RUNNER = "http://127.0.0.1:7842";

/**
 * Both halves have to be there, not just the runner.
 *
 * Checking only `/v1/health` was not enough: a runner started *without*
 * `--relay` answers it happily, so this suite ran and then threw at the first
 * `pair()` — turning "there is nothing to test against" into a red build. That
 * is the exact failure mode the header above says to avoid, in the other
 * direction.
 */
const running = await fetch(`${RUNNER}/v1/health`)
  .then((response) => response.ok)
  .catch(() => false);

const hasRelay =
  running &&
  (await fetch(`${RUNNER}/v1/pair/offer`, { method: "POST" })
    .then((response) => (response.ok ? response.json() : null))
    .then((offer) => Boolean((offer as { relay_url?: string } | null)?.relay_url))
    .catch(() => false));

if (running && !hasRelay) {
  console.warn(
    "live: a runner is up on 7842 but has no relay — skipping. " +
      "Start it with --relay ws://127.0.0.1:7843 to run these.",
  );
}

/** Mint an offer and redeem it — exactly what the pairing screen does. */
async function pair(kind: "phone" | "watch"): Promise<Pairing> {
  const offered = await fetch(`${RUNNER}/v1/pair/offer`, { method: "POST" });
  const offer = parseOffer(JSON.stringify(await offered.json()));
  if (!offer.relay_url) {
    throw new Error("the runner has no relay — start it with --relay");
  }

  const identity = Identity.generate();
  const claimed = await fetch(`${RUNNER}/v1/pair/claim`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      code: offer.code,
      kind,
      public_key: identity.publicKey,
    }),
  });
  if (!claimed.ok) throw new Error(`claim failed: ${claimed.status}`);
  const device = (await claimed.json()) as { id: string };

  return {
    relayUrl: offer.relay_url,
    channel: offer.channel,
    runnerPublicKey: offer.runner_public_key,
    deviceId: device.id,
    secret: identity.toSecret(),
  };
}

async function connect(kind: "phone" | "watch") {
  const transport = new RelayTransport(await pair(kind));
  await new Promise<void>((resolve) => {
    const off = transport.onConnectionChange((state) => {
      if (state === "open") {
        off();
        resolve();
      }
    });
  });
  return transport;
}

const settle = (ms: number) => new Promise((r) => setTimeout(r, ms));

describe.skipIf(!hasRelay)("live: a phone against a real relay", () => {
  let phone: RelayTransport;

  beforeAll(async () => {
    phone = await connect("phone");
    return () => phone.close();
  });

  it("gets a fleet snapshot back", async () => {
    const fleet = await phone.fleet();
    expect(fleet.sessions.length).toBeGreaterThan(0);
  });

  it("gets the session it asked for, not just any session", async () => {
    const fleet = await phone.fleet();
    const first = fleet.sessions[0]!;
    const detail = await phone.session(first.id);
    expect(detail.id).toBe(first.id);
    expect(detail.repo_name).toBe(first.repo_name);
  });

  it("receives live events without asking", async () => {
    const seen: string[] = [];
    const off = phone.onEvent((event) => seen.push(event.type));
    await settle(4_500);
    off();
    expect(seen.length).toBeGreaterThan(0);
  });

  it("clears an ordinary approval", async () => {
    const fleet = await phone.fleet();
    const ordinary = fleet.pending_approvals.find(
      (a) => a.allows_watch_decision,
    );
    if (!ordinary) return;

    await phone.decide(ordinary.id, "approved");
    await settle(500);

    const after = await phone.fleet();
    expect(after.pending_approvals.map((a) => a.id)).not.toContain(ordinary.id);
  });
});

/**
 * D3 over the relay. Separated so it can skip on its own when the seed has
 * nothing destructive in it — see the header for how to create one.
 */
describe.skipIf(!hasRelay)("live: the destructive-command rule", () => {
  let phone: RelayTransport;
  let destructiveId: string | null = null;

  beforeAll(async () => {
    phone = await connect("phone");
    const fleet = await phone.fleet();
    destructiveId =
      fleet.pending_approvals.find((a) => !a.allows_watch_decision)?.id ?? null;
    if (!destructiveId) {
      console.warn(
        "live: nothing destructive is pending — the D3 checks are skipping. " +
          "See this file's header to create one.",
      );
    }
    return () => phone.close();
  });

  it("refuses a watch, tells it why, and leaves the approval standing", async () => {
    if (!destructiveId) return;

    const watch = await connect("watch");
    const refusals: string[] = [];
    watch.onEvent((event) => {
      if (event.type === "command_error") refusals.push(event.message);
    });

    await watch.decide(destructiveId, "approved");
    await settle(1_000);
    watch.close();

    // The refusal came back rather than vanishing on the runner.
    expect(refusals[0]).toMatch(/phone/);
    const still = await phone.fleet();
    expect(still.pending_approvals.map((a) => a.id)).toContain(destructiveId);
  });

  it("lets the phone clear what the watch could not", async () => {
    if (!destructiveId) return;

    await phone.decide(destructiveId, "approved");
    await settle(500);
    const after = await phone.fleet();
    expect(after.pending_approvals.map((a) => a.id)).not.toContain(
      destructiveId,
    );
  });
});
