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

/* --------------------------------------------------- intra-line differences */

/**
 * The part of a changed line that actually changed.
 *
 * A line diff tells you *that* a line was replaced. It does not tell you a
 * variable was renamed rather than the logic rewritten, and on a long line
 * those look identical — the reviewer re-reads both sides and compares by eye,
 * which is exactly the work a reviewer is worst at and most likely to skip.
 *
 * # Prefix and suffix, not a full LCS
 *
 * Trimming the common head and tail off a token sequence catches the
 * overwhelming majority of real edits — a renamed identifier, a changed
 * argument, an added condition — in linear time and with no configuration.
 *
 * A full longest-common-subsequence would mark less, but it also finds matches
 * that are real to the algorithm and meaningless to a person: single brackets
 * and commas scattered across a rewritten line, each one splitting a highlight
 * into confetti. Marking a slightly wider span is the better failure: it
 * over-reports the change region rather than under-reporting it, and no
 * reviewer is misled about *where* to look.
 */
export interface Segment {
  text: string;
  /** True when this run differs between the two sides. */
  changed: boolean;
}

/**
 * Split on word boundaries, keeping every character.
 *
 * Identifiers stay whole so a rename highlights as one span rather than the
 * three letters that happen to differ. Whitespace is its own token so that
 * re-indentation does not smear into the code beside it.
 */
function tokenize(text: string): string[] {
  return text.match(/[A-Za-z0-9_$]+|\s+|[^A-Za-z0-9_$\s]/g) ?? [];
}

/**
 * Below this share of tokens in common, the two lines are treated as unrelated
 * and no highlighting is offered.
 *
 * Two lines that merely occupy the same position in a hunk are not necessarily
 * versions of each other. Highlighting them as though they were produces a
 * confident, wrong story about an edit that never happened — worse than the
 * plain line diff, which at least claims nothing.
 */
const RELATED_ENOUGH = 0.25;

export function intraline(
  before: string,
  after: string,
): { before: Segment[]; after: Segment[] } | null {
  if (before === after) return null;

  const a = tokenize(before);
  const b = tokenize(after);

  let head = 0;
  while (head < a.length && head < b.length && a[head] === b[head]) head++;

  let tail = 0;
  while (
    tail < a.length - head &&
    tail < b.length - head &&
    a[a.length - 1 - tail] === b[b.length - 1 - tail]
  ) {
    tail++;
  }

  // Weighed by characters rather than token count: ten shared brackets are not
  // the same evidence of kinship as one shared long identifier.
  const size = (tokens: string[]) => tokens.join("").length;
  const shared =
    size(a.slice(0, head)) + size(a.slice(a.length - tail)) || 0;
  const longest = Math.max(before.length, after.length);
  if (longest === 0 || shared / longest < RELATED_ENOUGH) return null;

  const build = (tokens: string[]): Segment[] => {
    const middle = tokens.slice(head, tokens.length - tail).join("");
    const segments: Segment[] = [];
    const prefix = tokens.slice(0, head).join("");
    const suffix = tokens.slice(tokens.length - tail).join("");
    if (prefix) segments.push({ text: prefix, changed: false });
    if (middle) segments.push({ text: middle, changed: true });
    if (suffix) segments.push({ text: suffix, changed: false });
    return segments;
  };

  return { before: build(a), after: build(b) };
}

/**
 * Pair each removed line with the added line that replaced it.
 *
 * A hunk is a flat list, so a replacement arrives as a run of removals followed
 * by a run of additions. Pairing them by position within those runs is what
 * makes intra-line highlighting possible at all; an unequal run length simply
 * leaves the extra lines unpaired, which is the honest reading of "two lines
 * became three".
 */
export function pairedLines(lines: NumberedLine[]): Map<number, number> {
  const pairs = new Map<number, number>();
  let index = 0;

  while (index < lines.length) {
    if (lines[index]?.tag !== "remove") {
      index++;
      continue;
    }
    const removeStart = index;
    while (lines[index]?.tag === "remove") index++;
    const addStart = index;
    while (lines[index]?.tag === "add") index++;

    const removes = addStart - removeStart;
    const adds = index - addStart;
    for (let offset = 0; offset < Math.min(removes, adds); offset++) {
      pairs.set(removeStart + offset, addStart + offset);
    }
  }
  return pairs;
}
