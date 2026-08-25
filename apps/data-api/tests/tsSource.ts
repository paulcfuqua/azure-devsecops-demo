/**
 * A very small TypeScript source reader, used only by the parity test.
 *
 * The parity test's job is to notice when someone edits a frontend's row type
 * and forgets that a service in another package copies it. Comparing *source*
 * beats comparing behaviour here: a renamed field, a widened union or a new
 * column shows up immediately, whereas a runtime check only catches the
 * subset of drift that happens to be represented in the current seed data.
 *
 * Deliberately not the TypeScript compiler API: pulling the whole frontend
 * program in would need `@mls/spec-renderer` built first (its `types.ts`
 * imports `Spec`), which would make this test depend on another package's
 * build. Reading the file is enough — it is the thing that drifts.
 */

/** Strip comments while respecting string and template literals. */
export function stripComments(source: string): string {
  let out = "";
  let index = 0;
  while (index < source.length) {
    const char = source[index] as string;
    const next = source[index + 1];

    if (char === "/" && next === "/") {
      while (index < source.length && source[index] !== "\n") index += 1;
      continue;
    }
    if (char === "/" && next === "*") {
      index += 2;
      while (index < source.length && !(source[index] === "*" && source[index + 1] === "/")) {
        index += 1;
      }
      index += 2;
      continue;
    }
    if (char === '"' || char === "'" || char === "`") {
      const quote = char;
      out += char;
      index += 1;
      while (index < source.length) {
        const inner = source[index] as string;
        out += inner;
        index += 1;
        if (inner === "\\") {
          out += source[index] ?? "";
          index += 1;
          continue;
        }
        if (inner === quote) break;
      }
      continue;
    }

    out += char;
    index += 1;
  }
  return out;
}

/**
 * Canonical form of a type body: whitespace is meaningless in TypeScript, so
 * collapse it, and drop optional trailing separators. Field order is kept —
 * it is part of the JSON this service emits.
 */
export function canonicalize(body: string): string {
  return body
    .replace(/\s+/g, " ")
    .replace(/\s*([{}();:,<>|&[\]?])\s*/g, "$1")
    .replace(/;+/g, ";")
    .replace(/;\}/g, "}")
    .trim();
}

/** name -> canonicalized body, for every `export interface` in the source. */
export function extractInterfaces(source: string): Map<string, string> {
  const clean = stripComments(source);
  const found = new Map<string, string>();
  const declaration = /export\s+interface\s+([A-Za-z0-9_]+)\s*\{/g;

  let match: RegExpExecArray | null;
  while ((match = declaration.exec(clean)) !== null) {
    const name = match[1] as string;
    const bodyStart = declaration.lastIndex - 1;
    const bodyEnd = matchBrace(clean, bodyStart);
    if (bodyEnd === -1) continue;
    found.set(name, canonicalize(clean.slice(bodyStart, bodyEnd + 1)));
  }
  return found;
}

function matchBrace(source: string, openIndex: number): number {
  let depth = 0;
  for (let index = openIndex; index < source.length; index += 1) {
    const char = source[index];
    if (char === "{") depth += 1;
    else if (char === "}") {
      depth -= 1;
      if (depth === 0) return index;
    }
  }
  return -1;
}

export interface DeclaredField {
  readonly name: string;
  readonly optional: boolean;
  /** Canonical type text, e.g. `string`, `string|null`, `{a:number}`. */
  readonly type: string;
}

/**
 * Split a canonicalized interface body into its top-level members, ignoring
 * separators nested inside object/array/generic type literals.
 */
export function topLevelFields(canonicalBody: string): DeclaredField[] {
  const inner = canonicalBody.replace(/^\{/, "").replace(/\}$/, "");
  const members: string[] = [];
  let depth = 0;
  let current = "";
  for (const char of inner) {
    if (char === "{" || char === "<" || char === "[" || char === "(") depth += 1;
    if (char === "}" || char === ">" || char === "]" || char === ")") depth -= 1;
    if (char === ";" && depth === 0) {
      if (current.trim() !== "") members.push(current);
      current = "";
      continue;
    }
    current += char;
  }
  if (current.trim() !== "") members.push(current);

  return members.map((member) => {
    const separator = member.indexOf(":");
    const rawName = member.slice(0, separator);
    return {
      name: rawName.replace(/\?$/, ""),
      optional: rawName.endsWith("?"),
      type: member.slice(separator + 1),
    };
  });
}

/**
 * Every path the launch-ops ApiProvider fetches, derived from its calls to
 * `this.rows<T>("table")`. Returns the path relative to `baseUrl`.
 */
export function extractLaunchOpsPaths(source: string): Array<{ type: string; path: string }> {
  const clean = stripComments(source);
  const call = /this\.rows<\s*([A-Za-z0-9_]+)\s*>\(\s*"([^"]+)"\s*\)/g;
  const paths: Array<{ type: string; path: string }> = [];
  let match: RegExpExecArray | null;
  while ((match = call.exec(clean)) !== null) {
    paths.push({ type: match[1] as string, path: `tables/${match[2] as string}` });
  }
  return paths;
}

/**
 * Every path the control-tower ApiProvider fetches, derived from its calls to
 * `this.get<T>("feeds/...")` / `this.get<T>("tables/...")`.
 */
export function extractControlTowerPaths(source: string): Array<{ type: string; path: string }> {
  const clean = stripComments(source);
  const call = /this\.get<\s*([A-Za-z0-9_]+(?:\[\])?)\s*>\(\s*"([^"]+)"\s*\)/g;
  const paths: Array<{ type: string; path: string }> = [];
  let match: RegExpExecArray | null;
  while ((match = call.exec(clean)) !== null) {
    paths.push({ type: match[1] as string, path: match[2] as string });
  }
  return paths;
}
