/**
 * Reading a diff, without a DOM.
 *
 * The runner sends hunks with a header and a list of tagged lines. Turning that
 * into something renderable means assigning each line its number on each side,
 * which is the one part of diff rendering that is easy to get quietly wrong:
 *
 *  - An added line has no number on the left, a removed line none on the right.
 *  - Numbering restarts from the hunk header for every hunk. A counter that ran
 *    over the whole file would be confidently wrong about where you are, and
 *    nothing on screen would contradict it.
 *
 * It lives here rather than in a component because both clients render diffs and
 * neither should own this arithmetic.
 */

import type { ChangeSet, DiffLine, FileDiff, Hunk } from "./api.ts";

export interface NumberedLine extends DiffLine {
  /** Line number on the "before" side, or `null` for an addition. */
  oldNo: number | null;
  /** Line number on the "after" side, or `null` for a removal. */
  newNo: number | null;
}

/** Assign both line numbers to every line of a hunk, seeded from its header. */
export function numberedLines(hunk: Hunk): NumberedLine[] {
  let oldNo = hunk.old_start;
  let newNo = hunk.new_start;

  return hunk.lines.map((line) => ({
    ...line,
    oldNo: line.tag === "add" ? null : oldNo++,
    newNo: line.tag === "remove" ? null : newNo++,
  }));
}

/** `@@ -1,3 +1,4 @@` — the header, for anyone who wants to see it. */
export function hunkHeader(hunk: Hunk): string {
  return `@@ -${hunk.old_start},${hunk.old_len} +${hunk.new_start},${hunk.new_len} @@`;
}

/**
 * `3 files, +42 −17`.
 *
 * The runner sends this precomputed on a `TaskView`; this recomputes it from a
 * change set, for the cases where only the change set is in hand.
 */
export function changeSummary(changes: ChangeSet): string {
  const files = changes.files.length;
  const added = changes.files.reduce((total, file) => total + file.added, 0);
  const removed = changes.files.reduce((total, file) => total + file.removed, 0);
  return `${files} file${files === 1 ? "" : "s"}, +${added} −${removed}`;
}

/** The glyph a file's kind is marked with. Never colour alone. */
export function changeMark(kind: FileDiff["kind"]): string {
  switch (kind) {
    case "added":
      return "+";
    case "deleted":
      return "−";
    default:
      return "~";
  }
}
