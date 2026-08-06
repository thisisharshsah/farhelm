/**
 * The Rust wire contract, read by the TypeScript that claims to mirror it.
 *
 * `api.ts` declares these interfaces **by hand**. Nothing generates them, and
 * until this file nothing checked them, so a renamed field in Rust arrived here
 * as `undefined`: no error on either side, just a screen that quietly stopped
 * showing a number. That is the failure this exists to catch, and it is the same
 * reason `crypto.test.ts` opens a fixture Rust sealed.
 *
 * The fixture is generated from the Rust types
 * (`crates/forge-proto/tests/wire_fixture.rs`, run with `-- --ignored`). Rust
 * checks the committed copy still matches what its types produce; this file
 * checks that everything TypeScript expects is actually in it.
 *
 * ## Why the key lists
 *
 * TypeScript types are erased at runtime, so a test cannot ask an interface what
 * its fields are. Each list below is tied to its interface by a compile-time
 * assertion — `Exhaustive<...>` fails to compile if the list omits a key the
 * interface declares. So the list cannot drift from the type, and the runtime
 * check then proves the Rust side still sends every one of them.
 *
 * That gives the pairing teeth in both directions:
 *   - a field TypeScript reads but Rust stopped sending → runtime failure here
 *   - a field added to the interface but never listed    → compile failure here
 *
 * A field Rust adds that TypeScript ignores is deliberately *not* a failure:
 * that is how the wire is allowed to grow without breaking a shipped phone.
 */

import { describe, expect, it } from "vitest";

import fixture from "../../../crates/forge-proto/tests/fixtures/wire.json";
import type {
  ApprovalView,
  BudgetView,
  DashboardView,
  FleetView,
  OutputLine,
  PlanProgress,
  SessionDetail,
  SessionView,
  TaskDetail,
  TaskView,
} from "./api.ts";

/**
 * Compiles only when `Listed` covers every key of `T`.
 *
 * `Exclude` leaves the keys the list forgot; requiring that to be `never` turns
 * "you added a field and did not list it" into a type error at this line.
 */
type Exhaustive<T, Listed extends keyof T> = [Exclude<keyof T, Listed>] extends [
  never,
]
  ? true
  : { error: "a key of this interface is missing from the list below"; missing: Exclude<keyof T, Listed> };

const BUDGET_KEYS = ["cap_usd", "spent_usd", "pct", "state"] as const;

const PLAN_PROGRESS_KEYS = [
  "settled",
  "total",
  "current_ordinal",
  "current_title",
] as const;

const SESSION_KEYS = [
  "id",
  "repo_name",
  "machine_name",
  "agent",
  "status",
  "is_live",
  "plan",
  "budget",
  "started_at",
  "ended_at",
  "awaiting_approval_id",
] as const;

const APPROVAL_KEYS = [
  "id",
  "session_id",
  "tool",
  "payload",
  "risk",
  "decision",
  "decided_via",
  "requested_at",
  "decided_at",
  "repo_name",
  "allows_watch_decision",
  "budget",
] as const;

const OUTPUT_KEYS = ["seq", "text", "at_ms"] as const;

const FLEET_KEYS = [
  "sessions",
  "pending_approvals",
  "tasks_awaiting_review",
  "today_usd",
  "cache_hit_ratio",
] as const;

/**
 * The compile-time half, collected so the assertions are *used* — an unread
 * `const` trips `noUnusedLocals`, and a check nobody reads is a check that gets
 * deleted. Each entry is `true` only if its list above covers every key of the
 * interface; otherwise this array stops type-checking and names the key that
 * was forgotten.
 */
const LISTS_ARE_COMPLETE: [
  Exhaustive<BudgetView, (typeof BUDGET_KEYS)[number]>,
  Exhaustive<PlanProgress, (typeof PLAN_PROGRESS_KEYS)[number]>,
  Exhaustive<SessionView, (typeof SESSION_KEYS)[number]>,
  Exhaustive<ApprovalView, (typeof APPROVAL_KEYS)[number]>,
  Exhaustive<OutputLine, (typeof OUTPUT_KEYS)[number]>,
  Exhaustive<FleetView, (typeof FLEET_KEYS)[number]>,
] = [true, true, true, true, true, true];

/**
 * First element, or a failure naming what was empty.
 *
 * `noUncheckedIndexedAccess` types `array[0]` as possibly undefined, which is
 * right: a fixture that stopped carrying any sessions should fail here saying
 * so, rather than at a property access three lines later.
 */
function first<T>(items: readonly T[], what: string): T {
  const head = items[0];
  if (head === undefined) {
    throw new Error(`the fixture carries no ${what}`);
  }
  return head;
}

/** Asserts every listed key is present on the object Rust produced. */
function hasEveryKey(
  actual: Record<string, unknown>,
  expected: readonly string[],
  what: string,
): void {
  const missing = expected.filter((key) => !(key in actual));
  expect(
    missing,
    `${what}: the Rust fixture is missing ${missing.join(", ")} — either the ` +
      `field was renamed or removed on the Rust side, or api.ts is describing ` +
      `a shape that no longer exists`,
  ).toEqual([]);
}

describe("the read models Rust sends", () => {
  const fleet = fixture.fleet_view as unknown as FleetView;

  it("lists every key of every interface it checks", () => {
    // Forces `LISTS_ARE_COMPLETE` to be read. The real assertion is the type
    // annotation on it, which fails to compile if a list is short.
    expect(LISTS_ARE_COMPLETE).toEqual([true, true, true, true, true, true]);
  });

  it("carries every field FleetView declares", () => {
    hasEveryKey(fleet as never, FLEET_KEYS, "FleetView");
  });

  it("carries every field SessionView declares", () => {
    const session = first(fleet.sessions, "sessions");
    hasEveryKey(session as never, SESSION_KEYS, "SessionView");
    hasEveryKey(session.budget as never, BUDGET_KEYS, "BudgetView");
    hasEveryKey(session.plan as never, PLAN_PROGRESS_KEYS, "PlanProgress");
  });

  it("carries every field ApprovalView declares, flattened", () => {
    // The Approval is `#[serde(flatten)]`ed into the view, so its own fields sit
    // at the top level rather than under an `approval` key. Losing that flatten
    // would be invisible to a Rust-only test.
    const approval = first(fleet.pending_approvals, "pending approvals");
    hasEveryKey(approval as never, APPROVAL_KEYS, "ApprovalView");
  });

  it("carries every field SessionDetail declares", () => {
    const detail = fixture.session_detail as unknown as SessionDetail;
    // SessionDetail flattens a SessionView, so those keys are top-level too.
    hasEveryKey(detail as never, SESSION_KEYS, "SessionDetail (flattened session)");
    for (const key of ["steps", "output", "pending_approval"]) {
      expect(detail, `SessionDetail is missing ${key}`).toHaveProperty(key);
    }
    hasEveryKey(first(detail.output, "output lines") as never, OUTPUT_KEYS, "OutputLine");
  });

  it("carries the diff a review screen renders", () => {
    const detail = fixture.task_detail as unknown as TaskDetail;
    for (const key of ["changes", "patch", "output"]) {
      expect(detail, `TaskDetail is missing ${key}`).toHaveProperty(key);
    }
    const file = first(detail.changes.files, "changed files");
    for (const key of ["path", "kind", "added", "removed", "hunks", "binary"]) {
      expect(file, `FileDiff is missing ${key}`).toHaveProperty(key);
    }
    const line = first(first(file.hunks, "hunks").lines, "diff lines");
    expect(line).toHaveProperty("tag");
    expect(line).toHaveProperty("text");
  });

  it("carries the dashboard's numbers", () => {
    const dashboard = fixture.dashboard_view as unknown as DashboardView;
    for (const key of [
      "session_id",
      "repo_name",
      "calls",
      "total_usd",
      "cache_hit_ratio",
      "by_tier",
      "avoided_calls",
      "spend_series",
      "budget",
    ]) {
      expect(dashboard, `DashboardView is missing ${key}`).toHaveProperty(key);
    }
  });

  it("carries the task fields a list and a card render", () => {
    const task = first(
      fixture.fleet_view.tasks_awaiting_review,
      "tasks awaiting review",
    ) as unknown as TaskView;
    for (const key of [
      "id",
      "status",
      "change_summary",
      "verify_grade",
      "repo_path",
      "review_note",
    ]) {
      expect(task, `TaskView is missing ${key}`).toHaveProperty(key);
    }
  });
});

describe("the events and commands", () => {
  /**
   * The tags a client switches on. `command_error` is in this list even though
   * no ServerEvent variant produces it: it arrives on the same socket, and a
   * client that does not handle it shows nothing when a command is refused —
   * which is the worst failure a remote control surface can have.
   */
  it("uses the tags the clients switch on", () => {
    const tags = fixture.events.map((event) => event.type);
    expect(tags).toEqual([
      "session_upsert",
      "output_chunk",
      "approval_request",
      "approval_decision",
      "budget_alert",
      "task_upsert",
    ]);
    expect(fixture.command_error.type).toBe("command_error");
    expect(tags).not.toContain("command_error");
  });

  it("flattens an output chunk's line to the top level", () => {
    // `seq`/`text`/`at_ms` sit beside `session_id`, not under a `line` key. The
    // Swift client depends on that and cannot be checked from here any other way.
    const chunk = fixture.events.find((event) => event.type === "output_chunk");
    expect(chunk).toBeDefined();
    hasEveryKey(chunk as never, OUTPUT_KEYS, "output_chunk");
    expect(chunk).not.toHaveProperty("line");
  });

  it("names every command the clients can send", () => {
    expect(fixture.commands.map((command) => command.type)).toEqual([
      "decide",
      "instruct",
      "plan_control",
      "session_snapshot",
      "dashboard_snapshot",
      "review_task",
      "task_snapshot",
      "task_list",
      "revert_task",
      "snapshot",
    ]);
  });

  it("spells the enums the way api.ts spells them", () => {
    // The storage form and the JSON form are the same string by construction in
    // Rust (`text_enum!`). This is the check that api.ts's union types agree —
    // `claude-code` was once `claude_code` over the wire, and the API could not
    // parse the agent id its own endpoint advertised.
    const session = first(fixture.fleet_view.sessions, "sessions");
    expect(session.agent).toBe("claude-code");
    expect(session.status).toBe("awaiting_approval");
    expect(session.budget.state).toBe("warn");

    const approval = first(fixture.fleet_view.pending_approvals, "approvals");
    expect(approval.risk).toBe("destructive");
    expect(approval.decision).toBe("denied");
    expect(approval.decided_via).toBe("phone");

    expect(
      first(fixture.fleet_view.tasks_awaiting_review, "tasks").status,
    ).toBe("awaiting_review");
  });
});
