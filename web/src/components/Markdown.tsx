/**
 * Model replies as readable text.
 *
 * Replies arrive as Markdown. This renders the subset models actually use
 * (headings, paragraphs, bullet and numbered lists, bold, italic, inline code,
 * fenced code blocks) to React elements, never to HTML, so nothing in a reply
 * can inject markup. Anything outside the subset stays as its source text.
 */

import { Fragment, type ReactNode } from "react";

type Block =
  | { kind: "heading"; level: number; text: string }
  | { kind: "paragraph"; text: string }
  | { kind: "list"; ordered: boolean; start: number; items: string[] }
  | { kind: "code"; lang: string; text: string };

function blocks(source: string): Block[] {
  const out: Block[] = [];
  const lines = source.replace(/\r\n?/g, "\n").split("\n");
  let i = 0;
  while (i < lines.length) {
    const line = lines[i]!;
    if (line.trim() === "") { i += 1; continue; }
    const fence = /^\s*```\s*([\w+-]*)\s*$/.exec(line);
    if (fence) {
      const code: string[] = [];
      i += 1;
      while (i < lines.length && !/^\s*```\s*$/.test(lines[i]!)) { code.push(lines[i]!); i += 1; }
      i += 1;
      out.push({ kind: "code", lang: fence[1] ?? "", text: code.join("\n") });
      continue;
    }
    const heading = /^(#{1,4})\s+(.*)$/.exec(line);
    if (heading) {
      out.push({ kind: "heading", level: heading[1]!.length, text: heading[2]!.trim() });
      i += 1;
      continue;
    }
    const bullet = /^\s*[-*+]\s+/;
    const number = /^\s*\d+[.)]\s+/;
    if (bullet.test(line) || number.test(line)) {
      const ordered = number.test(line);
      const marker = ordered ? number : bullet;
      // A list a model writes around a code block or a nested bullet comes
      // in pieces; keeping its own numbers means "2." still reads as 2.
      const start = ordered ? Number.parseInt(line, 10) || 1 : 1;
      const items: string[] = [];
      while (i < lines.length && marker.test(lines[i]!)) {
        let item = lines[i]!.replace(marker, "");
        i += 1;
        // Continuation lines, indented, belong to the item above.
        while (i < lines.length && /^\s{2,}\S/.test(lines[i]!) && !marker.test(lines[i]!)) {
          item += `\n${lines[i]!.trim()}`;
          i += 1;
        }
        items.push(item);
      }
      out.push({ kind: "list", ordered, start, items });
      continue;
    }
    const text: string[] = [line];
    i += 1;
    while (i < lines.length && lines[i]!.trim() !== "" && !/^\s*```/.test(lines[i]!)
      && !/^#{1,4}\s/.test(lines[i]!) && !bullet.test(lines[i]!) && !number.test(lines[i]!)) {
      text.push(lines[i]!);
      i += 1;
    }
    out.push({ kind: "paragraph", text: text.join("\n") });
  }
  return out;
}

/** Bold, italic and inline code within a line; everything else verbatim. */
function inline(text: string): ReactNode[] {
  const parts: ReactNode[] = [];
  const pattern = /(`[^`\n]+`|\*\*[^*\n]+\*\*|\*[^*\n]+\*|__[^_\n]+__|_[^_\n]+_)/g;
  let last = 0;
  let key = 0;
  for (const match of text.matchAll(pattern)) {
    const start = match.index ?? 0;
    if (start > last) parts.push(text.slice(last, start));
    const token = match[0];
    if (token.startsWith("`")) parts.push(<code key={key++}>{token.slice(1, -1)}</code>);
    else if (token.startsWith("**") || token.startsWith("__")) parts.push(<strong key={key++}>{inline(token.slice(2, -2))}</strong>);
    else parts.push(<em key={key++}>{inline(token.slice(1, -1))}</em>);
    last = start + token.length;
  }
  if (last < text.length) parts.push(text.slice(last));
  return parts;
}

function lineBreaks(text: string): ReactNode[] {
  return text.split("\n").flatMap((line, index) => (index === 0 ? inline(line) : [<br key={`br-${index}`} />, ...inline(line)]));
}

export function Markdown({ text, className }: { text: string; className?: string }) {
  return (
    <div className={className ? `markdown ${className}` : "markdown"}>
      {blocks(text).map((block, index) => {
        switch (block.kind) {
          case "heading": {
            const Tag = (`h${Math.min(block.level + 2, 6)}`) as "h3" | "h4" | "h5" | "h6";
            return <Tag key={index}>{inline(block.text)}</Tag>;
          }
          case "code":
            return <pre key={index} data-lang={block.lang || undefined}><code>{block.text}</code></pre>;
          case "list": {
            const items = block.items.map((item, i) => <li key={i}>{lineBreaks(item)}</li>);
            return block.ordered ? <ol key={index} start={block.start}>{items}</ol> : <ul key={index}>{items}</ul>;
          }
          default:
            return <p key={index}>{lineBreaks(block.text)}</p>;
        }
      })}
    </div>
  );
}

/** For tests: the parsed shape of a reply. */
export const parseMarkdown = blocks;
export { inline as inlineMarkdown, Fragment as MarkdownFragment };
