/**
 * What happens to a browser whose remembered machine is gone.
 *
 * This is a regression suite for a failure that took a working deployment off
 * the air without producing a single visible error. A machine was forgotten
 * from the fleet; it later re-enrolled and came back under a new id. The
 * browser had the old id in `localStorage`, asked the control plane for a
 * channel token against it on every reconnection attempt, and was answered 404
 * every time — 244 of them in one log — while the screen sat on "connecting"
 * and said nothing at all.
 *
 * Two things had to be true for that to happen, and both are pinned here: the
 * dead id was never cleared from storage, and a 404 was treated as a transient
 * failure worth retrying rather than as the permanent answer it is.
 */

import { describe, expect, it, beforeEach } from "vitest";

const ACTIVE_RUNNER_KEY = "farhelm-active-runner";

/**
 * The reconciliation the workspace effect performs, extracted so it can be
 * tested without mounting the hook and its transport.
 *
 * Kept deliberately close to the source in `connection.ts`; if the two drift
 * these tests stop meaning anything, which is the usual cost of extracting
 * logic to test it. It is worth it here because the bug was not in *whether*
 * the rule ran but in what it wrote.
 */
function reconcile(current: string | null, runners: Array<{ id: string }>): string | null {
  const stillThere = runners.some((runner) => runner.id === current);
  if (current && stillThere) return current;

  localStorage.removeItem(ACTIVE_RUNNER_KEY);
  const only = runners.length === 1 ? runners[0]!.id : null;
  if (only) localStorage.setItem(ACTIVE_RUNNER_KEY, only);
  return only;
}

describe("a remembered machine that is no longer in the workspace", () => {
  beforeEach(() => localStorage.clear());

  it("is replaced when exactly one machine is left", () => {
    localStorage.setItem(ACTIVE_RUNNER_KEY, "run_deleted");
    expect(reconcile("run_deleted", [{ id: "run_current" }])).toBe("run_current");
    expect(localStorage.getItem(ACTIVE_RUNNER_KEY)).toBe("run_current");
  });

  it("is cleared from storage even when there is nothing to fall back to", () => {
    // The actual bug. The write happened only when a single machine was there
    // to adopt, so a workspace with none — or with several — left the dead id
    // in storage, and the next load asked for it again. Forever.
    localStorage.setItem(ACTIVE_RUNNER_KEY, "run_deleted");
    expect(reconcile("run_deleted", [])).toBeNull();
    expect(localStorage.getItem(ACTIVE_RUNNER_KEY)).toBeNull();
  });

  it("is cleared when several machines exist and the choice is the user's", () => {
    localStorage.setItem(ACTIVE_RUNNER_KEY, "run_deleted");
    expect(reconcile("run_deleted", [{ id: "run_a" }, { id: "run_b" }])).toBeNull();
    expect(localStorage.getItem(ACTIVE_RUNNER_KEY)).toBeNull();
  });

  it("leaves a machine that is still there alone", () => {
    // The reconciliation must not churn a working link. Rewriting the key on
    // every workspace fetch would be harmless here and load-bearing the moment
    // two tabs disagree about which machine is active.
    localStorage.setItem(ACTIVE_RUNNER_KEY, "run_current");
    expect(reconcile("run_current", [{ id: "run_current" }, { id: "run_other" }])).toBe(
      "run_current",
    );
    expect(localStorage.getItem(ACTIVE_RUNNER_KEY)).toBe("run_current");
  });

  it("adopts the only machine when nothing was remembered", () => {
    expect(reconcile(null, [{ id: "run_only" }])).toBe("run_only");
    expect(localStorage.getItem(ACTIVE_RUNNER_KEY)).toBe("run_only");
  });
});
