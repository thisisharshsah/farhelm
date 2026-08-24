/**
 * Turning a session's output tail into something a person reads.
 *
 * This lives here rather than in a screen because both clients render the same
 * conversation and had drifted into rendering it differently: the web app
 * grouped lines into turns while the phone showed a flat run of monospace, so
 * the device this product exists for had the worse transcript of the two. The
 * README's rule — everything that is not a screen is shared — is what stops
 * that happening again.
 *
 * What stays in the screens is layout. What is here is the reading of the tail:
 * who spoke, when, and what the text actually says once the wire markers are
 * taken back off.
 */

import type { OutputLine } from "./api.ts";

/**
 * How the runner tags an instruction in the tail.
 *
 * A presentation detail of the tail rather than a wire field, so unpicking it
 * stays on this side rather than becoming a thing three clients have to agree
 * about.
 */
export const INSTRUCTION_MARKER = "\u203a";

/**
 * How much of one agent turn to show before folding it.
 *
 * A build log is thousands of lines and arrives as a single turn. Rendered
 * whole it buries the conversation it is part of — you scroll past a test suite
 * to find the sentence that says what happened, and on a phone you scroll past
 * it twice. The tail is the part that says how it ended, so the tail is what
 * stays.
 */
export const FOLD_AFTER = 14;

export type Turn = { kind: "instruction" | "agent"; lines: OutputLine[] };

/** `14:32`, in the reader's own locale and timezone. */
export function clockOf(at?: number): string {
  if (!at) return "";
  return new Date(at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}


/**
 * The text as a person should read it.
 *
 * `›` is how the runner marks an instruction in the tail, and it is what
 * `turnsOf` groups on — so by the time a line is rendered the marker has
 * already done its whole job. It was still being printed, which put a stray
 * glyph in front of every message you had typed. Grouping consumed it; the
 * display should not repeat it.
 */
export function displayText(text: string): string {
  return text.startsWith(INSTRUCTION_MARKER) ? text.slice(INSTRUCTION_MARKER.length).trimStart() : text;
}


/**
 * A name for the thing on the other side of the conversation.
 *
 * Not taken from the wire: `SessionView` carries the agent's *id*, and the
 * display names live in `farhelm_domain::agent::AGENTS`. Adding a name field
 * would mean a wire change across three clients for a label, so the closed set
 * is spelled here — with a fallback that still reads properly for an agent this
 * build has not heard of, which is what keeps a new entry in the registry from
 * rendering as an empty header.
 */
export function agentName(id: string): string {
  const known: Record<string, string> = {
    "claude-code": "Claude Code",
    farhelm: "Farhelm",
    codex: "Codex",
    opencode: "OpenCode",
    aider: "Aider",
    gemini: "Gemini",
    cursor: "Cursor",
    shell: "Shell",
  };
  if (known[id]) return known[id];

  const titled = id
    .split(/[-_]/)
    .filter(Boolean)
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join(" ");

  // An id of only separators titles to nothing, and an empty turn header reads
  // as a rendering fault rather than as an unfamiliar agent. Fall back to the
  // raw id: unhelpful is recoverable, blank is alarming.
  return titled || id;
}


/**
 * Group consecutive lines by who produced them.
 *
 * The tail was one flat run of monospace where the only thing separating your
 * instruction from a thousand lines of build output was its colour. Reading it
 * back on a phone meant hunting for what you had asked. Grouping lets a turn be
 * spaced and labelled once rather than per line, which is what makes it scan as
 * a conversation rather than a log.
 *
 * The prefix below is how the runner marks an instruction in the tail. That is
 * a presentation detail, so unpicking it stays here rather than becoming a wire
 * field three clients would have to agree about.
 */
export function turnsOf(lines: OutputLine[]): Turn[] {
  const turns: Turn[] = [];
  for (const line of lines) {
    const kind = line.text.startsWith(INSTRUCTION_MARKER) ? "instruction" : "agent";
    const last = turns[turns.length - 1];
    if (last && last.kind === kind) last.lines.push(line);
    else turns.push({ kind, lines: [line] });
  }
  return turns;
}
