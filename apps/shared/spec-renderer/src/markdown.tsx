import type { ReactNode } from "react";
import { createElement } from "react";

/**
 * Minimal markdown-to-React renderer for the subset the copilot may emit:
 * headings (#-####), paragraphs, unordered/ordered lists, fenced code blocks,
 * inline bold/italic/code, and http(s) links.
 *
 * Everything is rendered as React elements — raw HTML in the input is treated
 * as literal text, never injected, so LLM output cannot XSS the host app.
 */

const INLINE_TOKEN =
  /(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|(_[^_]+_)|(\[[^\]]+\]\(https?:\/\/[^\s)]+\))/;

function renderInline(text: string, keyPrefix: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  let rest = text;
  let i = 0;
  while (rest.length > 0) {
    const match = INLINE_TOKEN.exec(rest);
    if (!match || match.index === undefined) {
      nodes.push(rest);
      break;
    }
    if (match.index > 0) {
      nodes.push(rest.slice(0, match.index));
    }
    const token = match[0];
    const key = `${keyPrefix}-${i++}`;
    if (token.startsWith("`")) {
      nodes.push(<code key={key}>{token.slice(1, -1)}</code>);
    } else if (token.startsWith("**")) {
      nodes.push(<strong key={key}>{token.slice(2, -2)}</strong>);
    } else if (token.startsWith("*") || token.startsWith("_")) {
      nodes.push(<em key={key}>{token.slice(1, -1)}</em>);
    } else {
      const closeBracket = token.indexOf("](");
      const label = token.slice(1, closeBracket);
      const href = token.slice(closeBracket + 2, -1);
      nodes.push(
        <a key={key} href={href} target="_blank" rel="noopener noreferrer">
          {renderInline(label, `${key}-l`)}
        </a>,
      );
    }
    rest = rest.slice(match.index + token.length);
  }
  return nodes;
}

interface Block {
  kind: "heading" | "paragraph" | "ul" | "ol" | "code";
  level?: number;
  lines: string[];
}

function parseBlocks(markdown: string): Block[] {
  const blocks: Block[] = [];
  const lines = markdown.replace(/\r\n/g, "\n").split("\n");
  let current: Block | undefined;
  let inFence = false;

  const flush = (): void => {
    if (current && current.lines.length > 0) {
      blocks.push(current);
    }
    current = undefined;
  };

  for (const line of lines) {
    if (line.trimEnd().startsWith("```")) {
      if (inFence) {
        inFence = false;
        flush();
      } else {
        flush();
        inFence = true;
        current = { kind: "code", lines: [] };
      }
      continue;
    }
    if (inFence) {
      current?.lines.push(line);
      continue;
    }
    const headingMatch = /^(#{1,4})\s+(.*)$/.exec(line);
    if (headingMatch) {
      flush();
      blocks.push({
        kind: "heading",
        level: (headingMatch[1] ?? "#").length,
        lines: [headingMatch[2] ?? ""],
      });
      continue;
    }
    const ulMatch = /^\s*[-*]\s+(.*)$/.exec(line);
    if (ulMatch) {
      if (current?.kind !== "ul") {
        flush();
        current = { kind: "ul", lines: [] };
      }
      current.lines.push(ulMatch[1] ?? "");
      continue;
    }
    const olMatch = /^\s*\d+[.)]\s+(.*)$/.exec(line);
    if (olMatch) {
      if (current?.kind !== "ol") {
        flush();
        current = { kind: "ol", lines: [] };
      }
      current.lines.push(olMatch[1] ?? "");
      continue;
    }
    if (line.trim() === "") {
      flush();
      continue;
    }
    if (current?.kind !== "paragraph") {
      flush();
      current = { kind: "paragraph", lines: [] };
    }
    current.lines.push(line.trim());
  }
  flush();
  return blocks;
}

export function renderMarkdown(markdown: string): ReactNode[] {
  return parseBlocks(markdown).map((block, i) => {
    const key = `md-${i}`;
    switch (block.kind) {
      case "heading": {
        // Map # -> h3 ... #### -> h6 so specs never fight the host page's h1/h2.
        const tag = `h${Math.min((block.level ?? 1) + 2, 6)}`;
        return createElement(tag, { key }, renderInline(block.lines[0] ?? "", key));
      }
      case "code":
        return (
          <pre key={key}>
            <code>{block.lines.join("\n")}</code>
          </pre>
        );
      case "ul":
        return (
          <ul key={key}>
            {block.lines.map((item, j) => (
              <li key={`${key}-${j}`}>{renderInline(item, `${key}-${j}`)}</li>
            ))}
          </ul>
        );
      case "ol":
        return (
          <ol key={key}>
            {block.lines.map((item, j) => (
              <li key={`${key}-${j}`}>{renderInline(item, `${key}-${j}`)}</li>
            ))}
          </ol>
        );
      case "paragraph":
        return <p key={key}>{renderInline(block.lines.join(" "), key)}</p>;
    }
  });
}
