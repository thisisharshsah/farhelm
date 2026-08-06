/**
 * What a wake-up says, and which buttons it offers.
 *
 * The one that really matters is `allowsOneTap`. A notification action can be
 * hit from a lock screen without the app ever coming to the front — it is the
 * least deliberate surface in the whole system, less so than the wrist tap D3
 * already refuses. Offering Approve on `rm -rf` there would quietly undo the
 * most important safety property in the product.
 */

import { describe, expect, it } from "vitest";
import type {
  ApprovalView,
  FleetView,
  Risk,
  TaskView,
} from "@relayforge/client-core";
import {
  REFUSAL_TAG,
  allowsOneTap,
  decidedNotification,
  refusalNotification,
  unreachableNotification,
  wakeUpNotification,
} from "./notification";

const budget = { cap_usd: 5, spent_usd: 1, pct: 0.2, state: "ok" as const };

const approval = (over: Partial<ApprovalView> = {}): ApprovalView => ({
  id: "a1",
  session_id: "s1",
  tool: "Bash",
  payload: "pytest tests/billing -x",
  risk: "low",
  decision: null,
  decided_via: null,
  requested_at: 0,
  decided_at: null,
  repo_name: "payments-api",
  allows_watch_decision: true,
  budget,
  ...over,
});

const fleet = (pending: ApprovalView[]): FleetView => ({
  sessions: [],
  pending_approvals: pending,
  tasks_awaiting_review: [],
  today_usd: 0,
  cache_hit_ratio: 0,
});

const task = (over: Partial<TaskView> = {}): TaskView => ({
  id: "t1",
  session_id: "s1",
  repo_id: "r1",
  repo_name: "payments-api",
  repo_path: "/srv/payments-api",
  prompt: "Bound the webhook retry backoff",
  status: "awaiting_review",
  summary: "Capped it at 30s.",
  files_changed: 3,
  lines_added: 42,
  lines_removed: 17,
  change_summary: "3 files, +42 −17",
  steps: 6,
  cost_usd: 0.08,
  error: null,
  review_note: null,
  verify_grade: null,
  verify_notes: null,
  verify_model: null,
  decided_via: null,
  created_at: 0,
  updated_at: 0,
  decided_at: null,
  ...over,
});

const actionsOf = (n: { options: { actions?: { action: string }[] } }) =>
  (n.options.actions ?? []).map((a) => a.action);

describe("who gets a one-tap decision", () => {
  it("allows an ordinary command", () => {
    expect(allowsOneTap(approval({ risk: "low" }))).toBe(true);
    expect(allowsOneTap(approval({ risk: "medium" }))).toBe(true);
  });

  it("refuses a destructive one", () => {
    // Deliberate friction. The runner enforces its own rule too, but a client
    // must not offer a button that should not exist.
    expect(allowsOneTap(approval({ risk: "destructive" }))).toBe(false);
  });

  it("covers every risk level the runner can send", () => {
    // A new risk level defaulting to "one tap is fine" would be a silent
    // widening of the most dangerous path in the product.
    const risks: Risk[] = ["low", "medium", "destructive"];
    for (const risk of risks) {
      expect(allowsOneTap(approval({ risk }))).toBe(risk !== "destructive");
    }
  });
});

describe("a wake-up with an approval waiting", () => {
  it("names the repo and the actual command", () => {
    // The payoff for decrypting on the device: the relay never learned any of
    // this, and the notification still says it.
    const shown = wakeUpNotification({ kind: "fleet", fleet: fleet([approval()]) });
    expect(shown.options.body).toContain("payments-api");
    expect(shown.options.body).toContain("pytest tests/billing -x");
  });

  it("offers Approve and Deny", () => {
    const shown = wakeUpNotification({ kind: "fleet", fleet: fleet([approval()]) });
    expect(actionsOf(shown)).toEqual(["approve", "deny"]);
    expect(shown.options.data).toEqual({ approvalId: "a1" });
  });

  it("stays on screen until it is answered", () => {
    const shown = wakeUpNotification({ kind: "fleet", fleet: fleet([approval()]) });
    expect(shown.options.requireInteraction).toBe(true);
  });

  it("offers no buttons at all for a destructive command", () => {
    const shown = wakeUpNotification({
      kind: "fleet",
      fleet: fleet([approval({ risk: "destructive", payload: "rm -rf ./build" })]),
    });
    expect(actionsOf(shown)).toEqual([]);
    expect(shown.title).toBe("Needs your phone");
    expect(shown.options.body).toContain("rm -rf ./build");
    expect(shown.options.body).toMatch(/open the app/i);
  });

  it("says how many others are waiting", () => {
    const shown = wakeUpNotification({
      kind: "fleet",
      fleet: fleet([approval(), approval({ id: "a2" }), approval({ id: "a3" })]),
    });
    expect(shown.options.body).toContain("+2 more");
    // The buttons still act on the first one, which is the one described.
    expect(shown.options.data).toEqual({ approvalId: "a1" });
  });

  it("does not mention others when there are none", () => {
    const shown = wakeUpNotification({ kind: "fleet", fleet: fleet([approval()]) });
    expect(shown.options.body).not.toContain("more waiting");
  });
});

describe("a wake-up with nothing specific to say", () => {
  it("is quiet when a window is already in front", () => {
    // Interrupting someone about something they are looking at is noise — but
    // a push with no notification is a "silent push" and gets the permission
    // revoked. Quiet, not absent.
    const shown = wakeUpNotification({ kind: "focused" });
    expect(shown.options.silent).toBe(true);
    expect(actionsOf(shown)).toEqual([]);
  });

  it("is vague but honest when unpaired", () => {
    const shown = wakeUpNotification({ kind: "unpaired" });
    expect(shown.options.body).toBe("An agent needs you.");
    expect(actionsOf(shown)).toEqual([]);
  });

  it("is vague but honest when the runner cannot be reached", () => {
    // Better than silence: something is waiting, we just could not read what.
    const shown = wakeUpNotification({ kind: "unreachable" });
    expect(shown.options.body).toBe("An agent needs you.");
    expect(actionsOf(shown)).toEqual([]);
  });

  it("never offers a decision it could not have read", () => {
    for (const kind of ["focused", "unpaired", "unreachable"] as const) {
      const shown = wakeUpNotification({ kind });
      expect(actionsOf(shown)).toEqual([]);
      expect(shown.options.data).toBeUndefined();
    }
  });

  it("says something useful when the approval is already gone", () => {
    // Decided from another device between the push and this connection.
    const shown = wakeUpNotification({ kind: "fleet", fleet: fleet([]) });
    expect(shown.options.body).toBe("Something needs a look.");
    expect(actionsOf(shown)).toEqual([]);
  });
});

describe("after the tap", () => {
  it("shows a refusal that will not disappear before it is read", () => {
    // The notification that prompted the tap is already dismissed. This is the
    // only surface left; if it auto-dismisses, the tap silently did nothing.
    const shown = refusalNotification("destructive commands must be approved from the phone");
    expect(shown.options.requireInteraction).toBe(true);
    expect(shown.options.body).toContain("from the phone");
  });

  it("keeps a refusal separate from the wake-up tag", () => {
    // Sharing a tag would let the next wake-up replace the refusal before the
    // user ever saw why nothing happened.
    expect(refusalNotification("x").options.tag).toBe(REFUSAL_TAG);
    expect(unreachableNotification().options.tag).toBe(REFUSAL_TAG);
    expect(decidedNotification("approve").options.tag).not.toBe(REFUSAL_TAG);
  });

  it("says nothing was decided when the runner was unreachable", () => {
    // The dangerous wording would be anything ambiguous about whether it went
    // through.
    expect(unreachableNotification().options.body).toMatch(/nothing was decided/i);
  });

  it("confirms quietly that the tap landed", () => {
    expect(decidedNotification("approve").title).toBe("Approved");
    expect(decidedNotification("deny").title).toBe("Denied");
    expect(decidedNotification("approve").options.silent).toBe(true);
  });
});

describe("a change set waiting for review", () => {
  const withTask = (tasks: TaskView[]): FleetView => ({
    ...fleet([]),
    tasks_awaiting_review: tasks,
  });

  it("never offers a one-tap decision on a diff", () => {
    // The single most important assertion in this file after `allowsOneTap`.
    // A diff approved from a lock screen is not a diff anybody reviewed, and
    // the whole point of the review screen is that somebody read it.
    const notification = wakeUpNotification({
      kind: "fleet",
      fleet: withTask([task()]),
    });
    expect(actionsOf(notification)).toEqual([]);
  });

  it("names the repo and the size of the change", () => {
    const notification = wakeUpNotification({
      kind: "fleet",
      fleet: withTask([task()]),
    });
    expect(notification.title).toMatch(/change set/i);
    expect(notification.options.body).toContain("payments-api");
    expect(notification.options.body).toContain("3 files, +42 −17");
    expect(notification.options.body).toContain("Bound the webhook retry");
  });

  it("carries the task id so the tap lands on the diff", () => {
    const notification = wakeUpNotification({
      kind: "fleet",
      fleet: withTask([task()]),
    });
    expect(notification.options.data).toEqual({ taskId: "t1" });
  });

  it("counts the others without listing them", () => {
    const notification = wakeUpNotification({
      kind: "fleet",
      fleet: withTask([task(), task({ id: "t2" }), task({ id: "t3" })]),
    });
    expect(notification.options.body).toContain("+2 more");
  });

  it("yields to a pending approval, which is blocking a live agent", () => {
    // A task has already finished and will keep. An approval is holding a
    // process still, so it wins the one notification slot.
    const notification = wakeUpNotification({
      kind: "fleet",
      fleet: { ...fleet([approval()]), tasks_awaiting_review: [task()] },
    });
    expect(notification.title).toBe("Approve?");
  });

  it("still says something generic when neither is present", () => {
    const notification = wakeUpNotification({ kind: "fleet", fleet: fleet([]) });
    expect(notification.options.body).toMatch(/needs a look/i);
  });
});
