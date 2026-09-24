/**
 * Split an agent message into renderable segments.
 *
 * Why this exists: the Ask tab rendered agent text through a single `<Text block>`, and
 * HTML collapses newlines. A generative answer that comes back as a markdown pipe table or
 * a fenced ASCII table therefore arrived as one run-on paragraph - observed on the deployed
 * agent, not hypothesised.
 *
 * The agent does not choose one format. Measured across live Direct Line turns on
 * 2026-09-24, the same class of question returned: an Adaptive Card (the intended path,
 * lifted out by `extractCardsFromText`), a markdown pipe table, a fenced ``` ```text ```
 * ASCII table, and plain prose. Cards are handled upstream; this module's job is to make
 * the other three legible instead of mangled.
 *
 * Deliberately NOT a markdown renderer. It recognises exactly the two shapes that need a
 * monospace box to be readable at all - fenced blocks and pipe tables - and leaves
 * everything else as prose. No dependency, and nothing here produces HTML: the caller
 * renders text nodes, so there is no injection surface to reason about.
 */

export type Segment =
  | { kind: "prose"; text: string }
  /** Monospace, whitespace-preserved. `lang` is the fence info string when there was one. */
  | { kind: "pre"; text: string; lang?: string };

/** A line belonging to a markdown pipe table: `| a | b |`, or a `|---|---|` rule. */
function isTableLine(line: string): boolean {
  const t = line.trim();
  if (!t.startsWith("|")) return false;
  // A single "|" is not a table; require a second delimiter or some content.
  return t.length > 1;
}

/**
 * A pipe table needs at least a header and a delimiter row to be a table rather than a
 * sentence that happens to start with a pipe.
 */
function isTableBlock(lines: string[]): boolean {
  if (lines.length < 2) return false;
  return /^\s*\|[\s:|-]*-{2,}[\s:|-]*\|?\s*$/.test(lines[1] ?? "");
}

/** Split prose that contains pipe tables into alternating prose / pre segments. */
function splitTables(text: string): Segment[] {
  const lines = text.split("\n");
  const out: Segment[] = [];
  let buffer: string[] = [];
  let i = 0;

  const flushProse = (): void => {
    if (buffer.length === 0) return;
    const joined = buffer.join("\n");
    if (joined.trim().length > 0) out.push({ kind: "prose", text: joined.replace(/^\n+|\n+$/g, "") });
    buffer = [];
  };

  while (i < lines.length) {
    if (isTableLine(lines[i] ?? "")) {
      // Collect the whole contiguous run of table-ish lines.
      const start = i;
      const run: string[] = [];
      while (i < lines.length && isTableLine(lines[i] ?? "")) {
        run.push(lines[i] ?? "");
        i += 1;
      }
      if (isTableBlock(run)) {
        flushProse();
        out.push({ kind: "pre", text: run.join("\n") });
      } else {
        // Not actually a table - give the lines back to the prose buffer.
        for (let k = start; k < i; k += 1) buffer.push(lines[k] ?? "");
      }
      continue;
    }
    buffer.push(lines[i] ?? "");
    i += 1;
  }
  flushProse();
  return out;
}

/**
 * Split `text` into prose and preformatted segments.
 *
 * An EMPTY fenced block is dropped. That is not a cosmetic choice: when the agent emits an
 * Adaptive Card it writes the card JSON inside a ```json fence, `extractCardsFromText`
 * lifts the JSON out to render it as a card, and what it leaves behind is an empty fence.
 * Rendering that would show an empty grey box under every successful card.
 */
export function splitMessageSegments(text: string): Segment[] {
  if (text.trim().length === 0) return [];

  const out: Segment[] = [];
  // ```lang\n ... \n``` - non-greedy body, tolerant of a missing closing fence.
  //
  // The tail alternative is `(?![\s\S])` - true end of input - and NOT `$`. Under the `m`
  // flag `$` matches end of LINE, so it closed the block at the first blank line and split
  // one fenced table into several segments. Caught by the interior-blank-line test.
  const fence = /^[ \t]*```([^\n`]*)\n([\s\S]*?)(?:^[ \t]*```[ \t]*$|(?![\s\S]))/gm;
  let last = 0;
  let m: RegExpExecArray | null;

  while ((m = fence.exec(text)) !== null) {
    const before = text.slice(last, m.index);
    if (before.trim().length > 0) out.push(...splitTables(before));

    const lang = (m[1] ?? "").trim();
    const body = (m[2] ?? "").replace(/\n+$/, "");
    if (body.trim().length > 0) {
      out.push(lang.length > 0 ? { kind: "pre", text: body, lang } : { kind: "pre", text: body });
    }
    last = fence.lastIndex;
    // A zero-length match cannot advance the cursor; guard against an infinite loop.
    if (m[0].length === 0) break;
  }

  const rest = text.slice(last);
  if (rest.trim().length > 0) out.push(...splitTables(rest));
  return out;
}
