/**
 * Palette ranking.
 *
 * The list is only as good as its first row: nobody reads past it before
 * pressing Enter. So these pin down the ordering rules rather than the fact
 * that matching happens at all.
 */

import { describe, expect, it } from "vitest";
import { rank, type Action } from "./Palette";

const action = (label: string, hint?: string): Action => ({
  id: label,
  label,
  hint,
  group: "g",
  icon: "fleet",
  run: () => {},
});

const labels = (query: string, actions: Action[]) =>
  rank(query, actions).map((a) => a.label);

describe("ranking", () => {
  it("matches a subsequence, the way an editor finds a file", () => {
    expect(labels("bgt", [action("Plan and billing budget")])).toEqual([
      "Plan and billing budget",
    ]);
  });

  it("prefers a word start over the middle of a word", () => {
    // Both contain "co". Only one begins a word with it.
    const out = labels("co", [action("Disconnect machine"), action("Cost report")]);
    expect(out[0]).toBe("Cost report");
  });

  it("prefers a tight run over scattered letters", () => {
    const out = labels("task", [
      action("The apple sank quietly"), // t..a..s..k spread out
      action("Tasks"),
    ]);
    expect(out[0]).toBe("Tasks");
  });

  it("prefers the shorter of two equally good labels", () => {
    const out = labels("fleet", [
      action("Fleet overview for the whole workspace"),
      action("Fleet"),
    ]);
    expect(out[0]).toBe("Fleet");
  });

  it("searches the hint, since a repo name is what people remember", () => {
    const out = labels("laptop", [action("forge", "laptop"), action("other", "server")]);
    expect(out).toEqual(["forge"]);
  });

  it("drops anything missing a character", () => {
    expect(labels("zzz", [action("Fleet"), action("Tasks")])).toEqual([]);
  });

  it("leaves the order alone when nothing is typed", () => {
    const all = [action("Fleet"), action("Tasks"), action("Workspace")];
    expect(labels("  ", all)).toEqual(["Fleet", "Tasks", "Workspace"]);
  });
});
