import { expect, it } from "vitest";
import { parseMarkdown } from "./Markdown";

it("splits a reply into the blocks models use", () => {
  const blocks = parseMarkdown("**Goal:**\nAdd a picker.\n\n## Steps\n\n1. **UI** add it\n   to the composer\n2. Send it\n\n- one\n- two\n\n```rust\nlet x = 1;\n```\n");
  expect(blocks.map((block) => block.kind)).toEqual(["paragraph", "heading", "list", "list", "code"]);
  expect(blocks[2]).toEqual({ kind: "list", ordered: true, start: 1, items: ["**UI** add it\nto the composer", "Send it"] });
  expect(parseMarkdown("2. second\n3. third")[0]).toMatchObject({ kind: "list", ordered: true, start: 2 });
  expect(blocks[4]).toEqual({ kind: "code", lang: "rust", text: "let x = 1;" });
});

it("keeps text outside the subset as it is", () => {
  expect(parseMarkdown("<script>alert(1)</script> and | a | table |")).toEqual([
    { kind: "paragraph", text: "<script>alert(1)</script> and | a | table |" },
  ]);
});
