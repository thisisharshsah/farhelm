/**
 * Diff line numbering.
 *
 * The failure this guards against is silent by nature: a diff with wrong line
 * numbers looks exactly like a diff with right ones, and a reviewer approving a
 * change to "line 41" has no way to tell it is really line 248.
 */

import { describe, expect, it } from "vitest";
import {
  changeMark,
  changeSummary,
  hunkHeader,
  intraline,
  numberedLines,
  pairedLines,
  type NumberedLine,
  type Segment,
} from "./diff.ts";
import type { ChangeSet, Hunk } from "./api.ts";

const hunk = (
  overrides: Partial<Hunk> & Pick<Hunk, "lines">,
): Hunk => ({
  old_start: 1,
  old_len: overrides.lines.filter((line) => line.tag !== "add").length,
  new_start: 1,
  new_len: overrides.lines.filter((line) => line.tag !== "remove").length,
  ...overrides,
});

describe("numbering a hunk", () => {
  it("gives context lines a number on both sides", () => {
    const numbered = numberedLines(
      hunk({
        lines: [
          { tag: "context", text: "one" },
          { tag: "context", text: "two" },
        ],
      }),
    );

    expect(numbered.map((line) => [line.oldNo, line.newNo])).toEqual([
      [1, 1],
      [2, 2],
    ]);
  });

  it("leaves an addition unnumbered on the left", () => {
    const [line] = numberedLines(hunk({ lines: [{ tag: "add", text: "new" }] }));
    expect(line!.oldNo).toBeNull();
    expect(line!.newNo).toBe(1);
  });

  it("leaves a removal unnumbered on the right", () => {
    const [line] = numberedLines(
      hunk({ lines: [{ tag: "remove", text: "gone" }] }),
    );
    expect(line!.oldNo).toBe(1);
    expect(line!.newNo).toBeNull();
  });

  it("keeps the two sides in step across a replacement", () => {
    // The classic case: one line swapped for another. After it, both sides must
    // be back on the same number.
    const numbered = numberedLines(
      hunk({
        lines: [
          { tag: "context", text: "a" },
          { tag: "remove", text: "old" },
          { tag: "add", text: "new" },
          { tag: "context", text: "b" },
        ],
      }),
    );

    expect(numbered.map((line) => [line.oldNo, line.newNo])).toEqual([
      [1, 1],
      [2, null],
      [null, 2],
      [3, 3],
    ]);
  });

  it("drifts the sides apart when lines are only added", () => {
    const numbered = numberedLines(
      hunk({
        lines: [
          { tag: "context", text: "a" },
          { tag: "add", text: "x" },
          { tag: "add", text: "y" },
          { tag: "context", text: "b" },
        ],
      }),
    );

    // The last context line is line 2 before and line 4 after — which is the
    // whole reason both numbers are shown.
    expect(numbered.at(-1)).toMatchObject({ oldNo: 2, newNo: 4 });
  });

  it("starts from the hunk header rather than from one", () => {
    const numbered = numberedLines(
      hunk({
        old_start: 248,
        new_start: 251,
        lines: [{ tag: "context", text: "deep in the file" }],
      }),
    );
    expect(numbered[0]).toMatchObject({ oldNo: 248, newNo: 251 });
  });

  it("numbers each hunk independently", () => {
    const first = numberedLines(
      hunk({ old_start: 10, new_start: 10, lines: [{ tag: "context", text: "a" }] }),
    );
    const second = numberedLines(
      hunk({ old_start: 80, new_start: 81, lines: [{ tag: "context", text: "b" }] }),
    );

    expect(first[0]!.oldNo).toBe(10);
    expect(second[0]!.oldNo).toBe(80);
  });

  it("renders the header the runner would have written", () => {
    expect(
      hunkHeader({
        old_start: 248,
        old_len: 8,
        new_start: 251,
        new_len: 9,
        lines: [],
      }),
    ).toBe("@@ -248,8 +251,9 @@");
  });
});

describe("summarising a change set", () => {
  const changes: ChangeSet = {
    files: [
      {
        path: "a.rs",
        kind: "modified",
        added: 40,
        removed: 17,
        hunks: [],
        binary: false,
      },
      {
        path: "b.rs",
        kind: "added",
        added: 2,
        removed: 0,
        hunks: [],
        binary: false,
      },
    ],
  };

  it("totals files and lines", () => {
    expect(changeSummary(changes)).toBe("2 files, +42 −17");
  });

  it("does not pluralise a single file", () => {
    expect(changeSummary({ files: [changes.files[0]!] })).toBe(
      "1 file, +40 −17",
    );
  });

  it("handles an empty change set without saying NaN", () => {
    expect(changeSummary({ files: [] })).toBe("0 files, +0 −0");
  });

  it("marks each kind with a glyph, so colour is never the only signal", () => {
    expect(changeMark("added")).toBe("+");
    expect(changeMark("deleted")).toBe("−");
    expect(changeMark("modified")).toBe("~");
  });
});

/**
 * Intra-line highlighting.
 *
 * The risk here is not missing a change — it is inventing one. Two lines that
 * merely sit in the same position get highlighted as though one became the
 * other, telling a confident and wrong story about an edit. These pin the
 * boundary between "related enough to compare" and "leave it alone".
 */
describe("what changed inside a line", () => {
  const changed = (segments: Segment[]) =>
    segments.filter((s) => s.changed).map((s) => s.text);

  it("marks a renamed identifier and nothing else", () => {
    const out = intraline("const total = price * qty;", "const sum = price * qty;")!;
    expect(changed(out.before)).toEqual(["total"]);
    expect(changed(out.after)).toEqual(["sum"]);
  });

  it("keeps an identifier whole rather than marking the letters that differ", () => {
    const out = intraline("callFoo(x)", "callBar(x)")!;
    // Not "Foo"→"Bar" with "call" split off the front by character.
    expect(out.before.map((s) => s.text).join("")).toBe("callFoo(x)");
    expect(changed(out.before)).toEqual(["callFoo"]);
  });

  it("marks an inserted argument without touching the rest", () => {
    const out = intraline("open(path)", "open(path, mode)")!;
    expect(changed(out.before)).toEqual([]);
    expect(changed(out.after)).toEqual([", mode"]);
  });

  it("reports nothing for two unrelated lines", () => {
    expect(intraline("return cachedValue;", "logger.warn('nope');")).toBeNull();
  });

  it("reports nothing when the lines are identical", () => {
    expect(intraline("same()", "same()")).toBeNull();
  });

  it("never loses a character", () => {
    const before = "  if (a && b) { run(); }";
    const after = "  if (a || b) { run(x); }";
    const out = intraline(before, after)!;
    expect(out.before.map((s) => s.text).join("")).toBe(before);
    expect(out.after.map((s) => s.text).join("")).toBe(after);
  });

  it("treats indentation as its own token", () => {
    const out = intraline("    return x;", "        return x;")!;
    expect(changed(out.before)).toEqual(["    "]);
    expect(changed(out.after)).toEqual(["        "]);
  });
});

describe("pairing removals with their replacements", () => {
  const line = (tag: "add" | "remove" | "context", text: string) =>
    ({ tag, text, oldNo: null, newNo: null }) as NumberedLine;

  it("pairs a run of removals with the run that follows it", () => {
    const pairs = pairedLines([
      line("context", "a"),
      line("remove", "b"),
      line("remove", "c"),
      line("add", "B"),
      line("add", "C"),
    ]);
    expect([...pairs]).toEqual([
      [1, 3],
      [2, 4],
    ]);
  });

  it("leaves the extra line unpaired when two lines became three", () => {
    const pairs = pairedLines([
      line("remove", "b"),
      line("add", "B"),
      line("add", "extra"),
    ]);
    expect([...pairs]).toEqual([[0, 1]]);
  });

  it("pairs nothing across an intervening context line", () => {
    const pairs = pairedLines([
      line("remove", "b"),
      line("context", "keep"),
      line("add", "B"),
    ]);
    expect(pairs.size).toBe(0);
  });

  it("pairs nothing for a pure addition", () => {
    expect(pairedLines([line("add", "new"), line("add", "also")]).size).toBe(0);
  });
});
