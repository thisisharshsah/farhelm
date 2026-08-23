/**
 * The transcript, as a person reads it.
 *
 * Every case here is something that was actually wrong on screen, not a
 * hypothetical. The marker bug in particular survived a rewrite of this view
 * *and* a commit whose message was about making the tail read as a
 * conversation — because nothing anywhere asserted what a line looks like by
 * the time it reaches the reader.
 */

import { describe, expect, it } from "vitest";
import { agentName, displayText, turnsOf } from "./views";

const line = (seq: number, text: string, at_ms = 1_700_000_000_000) => ({ seq, text, at_ms });

describe("what a line says once it is rendered", () => {
  it("drops the marker that only ever existed to group turns", () => {
    // `›` is how the runner tags an instruction in the tail. It is consumed by
    // `turnsOf`, so by render time it has done its whole job — and was still
    // being printed, putting a stray glyph in front of everything you typed.
    expect(displayText("› fix the failing test")).toBe("fix the failing test");
  });

  it("leaves agent output exactly as it arrived", () => {
    // Output is evidence. Trimming or rewriting it would mean the transcript
    // and the terminal disagree about what happened.
    expect(displayText("  running 42 tests")).toBe("  running 42 tests");
    expect(displayText("error: expected › got ‹")).toBe("error: expected › got ‹");
  });

  it("does not mistake a marker in the middle of a line for a prefix", () => {
    expect(displayText("cargo run -- › out.txt")).toBe("cargo run -- › out.txt");
  });
});

describe("grouping lines into turns", () => {
  it("keeps consecutive lines from one speaker together", () => {
    const turns = turnsOf([
      line(1, "› run the tests"),
      line(2, "compiling"),
      line(3, "42 passed"),
    ]);
    expect(turns.map((turn) => turn.kind)).toEqual(["instruction", "agent"]);
    expect(turns[1]!.lines).toHaveLength(2);
  });

  it("starts a new turn each time the speaker changes back", () => {
    // Two instructions with output between them are three turns, not two —
    // otherwise a reply and the question after it merge into one block.
    const turns = turnsOf([
      line(1, "› first"),
      line(2, "working"),
      line(3, "› second"),
    ]);
    expect(turns.map((turn) => turn.kind)).toEqual(["instruction", "agent", "instruction"]);
  });

  it("has nothing to group when nothing has happened", () => {
    expect(turnsOf([])).toEqual([]);
  });
});

describe("naming the other side of the conversation", () => {
  it("uses the proper name for an agent it knows", () => {
    expect(agentName("claude-code")).toBe("Claude Code");
    expect(agentName("farhelm")).toBe("Farhelm");
  });

  it("still reads properly for an agent this build has not heard of", () => {
    // The names live in the Rust registry, so a new entry there reaches this
    // build before the map does. The fallback is what stops the turn header
    // rendering blank in the meantime.
    expect(agentName("new-agent")).toBe("New Agent");
    expect(agentName("someagent")).toBe("Someagent");
  });

  it("does not produce an empty label from a malformed id", () => {
    // An empty header is worse than a wrong one: it reads as a rendering fault
    // rather than as an unfamiliar agent.
    expect(agentName("--")).toBe("--");
    expect(agentName("a")).toBe("A");
  });
});
