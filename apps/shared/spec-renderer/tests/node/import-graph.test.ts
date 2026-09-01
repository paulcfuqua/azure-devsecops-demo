/**
 * Import-graph guard for the `./validate` entry (P-5).
 *
 * The whole point of `src/validate-entry.ts` is that nothing in its import
 * graph touches the DOM. This test walks that graph statically and fails the
 * build the moment a React / Fluent / component import sneaks in — including
 * transitively, which is how the original breakage happened.
 *
 * Runs in the `node` vitest project (no jsdom).
 */
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import { describe, expect, it } from "vitest";

const pkgRoot = process.cwd();

/** Anything that drags a browser runtime in at module scope. */
const UI_SPECIFIER = /^(react|react-dom)(\/|$)|@fluentui\/|^tabster$|^keyborg$/;

const SPECIFIER_PATTERNS = [
  // `import x from "y"`, `import { a } from "y"`, `import type {...} from "y"`,
  // and `export ... from "y"` re-exports.
  /\bfrom\s*["']([^"']+)["']/g,
  // Side-effect imports: `import "y";`
  /^[ \t]*import\s+["']([^"']+)["']/gm,
  // Dynamic imports and CJS requires.
  /\bimport\s*\(\s*["']([^"']+)["']\s*\)/g,
  /\brequire\s*\(\s*["']([^"']+)["']\s*\)/g,
];

function specifiersOf(file: string): string[] {
  const source = readFileSync(file, "utf-8");
  const found: string[] = [];
  for (const pattern of SPECIFIER_PATTERNS) {
    pattern.lastIndex = 0;
    let match: RegExpExecArray | null;
    while ((match = pattern.exec(source)) !== null) {
      const spec = match[1];
      if (spec) found.push(spec);
    }
  }
  return found;
}

// ".js" is last, and it is here for ONE file: src/validate.generated.js, which is
// genuinely JavaScript rather than a TypeScript source compiled to it (F111 - the
// schema is precompiled at build time because ajv.compile() needs 'unsafe-eval',
// which the dashboards' CSP forbids). Every other ".js" specifier in this package is
// the ESM convention for a ".ts" source and is stripped before the lookup, so putting
// ".js" after ".ts" keeps that behaviour unchanged.
const CANDIDATES = ["", ".ts", ".tsx", ".json", "/index.ts", "/index.tsx", ".js"];

function resolveRelative(spec: string, fromFile: string): string | undefined {
  // Strip the ESM ".js"/".jsx" extension convention back to source.
  const base = resolve(dirname(fromFile), spec.replace(/\.jsx?$/, ""));
  for (const suffix of CANDIDATES) {
    const candidate = base + suffix;
    if (existsSync(candidate) && statSync(candidate).isFile()) return candidate;
  }
  return undefined;
}

interface Graph {
  /** Package-relative source files reachable from the entry, sorted. */
  files: string[];
  /** Bare (node_modules) specifiers reachable from the entry, sorted. */
  bare: string[];
}

function walk(entry: string): Graph {
  const seen = new Set<string>();
  const bare = new Set<string>();
  const queue = [resolve(pkgRoot, entry)];

  while (queue.length > 0) {
    const file = queue.shift();
    if (!file || seen.has(file)) continue;
    seen.add(file);
    if (file.endsWith(".json")) continue; // data, not code

    for (const spec of specifiersOf(file)) {
      if (spec.startsWith(".") || spec.startsWith("/")) {
        const target = resolveRelative(spec, file);
        if (!target) throw new Error(`unresolved relative import "${spec}" in ${file}`);
        queue.push(target);
      } else {
        bare.add(spec);
      }
    }
  }

  return {
    files: [...seen].map((f) => relative(pkgRoot, f).split(sep).join("/")).sort(),
    bare: [...bare].sort(),
  };
}

describe("src/validate-entry.ts import graph is UI-free", () => {
  const graph = walk("src/validate-entry.ts");

  it("reaches only the schema, the validator, and the type mirror", () => {
    expect(graph.files).toEqual([
      "spec.schema.json",
      "src/types.ts",
      "src/validate-entry.ts",
      // The schema, precompiled to a standalone validator at build time. It is in the
      // graph deliberately: the point of this test is that the validate entry pulls in
      // nothing but the contract, and the generated validator IS the contract, in
      // executable form (F111).
      "src/validate.generated.js",
      "src/validate.ts",
    ]);
  });

  it("has ajv as its only external dependency, and no longer its compiler", () => {
    // This used to read ["ajv", "ajv/dist/2020.js"] - the Ajv COMPILER, which builds a
    // validator by generating JavaScript and evaluating it. That needs 'unsafe-eval',
    // which the dashboards' CSP forbids, so every spec failed validation in the browser
    // however valid it was (F111).
    //
    // The schema is now compiled at build time, and what remains at runtime is a small
    // string-length helper the generated code calls. The narrowing is the point: the
    // package went from shipping a code generator to shipping a function.
    expect(graph.bare).toEqual(["ajv", "ajv/dist/runtime/ucs2length.js"]);
  });

  it("contains no React, Fluent, tabster, or keyborg import anywhere", () => {
    const offenders = graph.bare.filter((spec) => UI_SPECIFIER.test(spec));
    expect(offenders).toEqual([]);
  });

  it("pulls in no file from src/components/ and no .tsx file", () => {
    expect(graph.files.filter((f) => f.startsWith("src/components/"))).toEqual([]);
    expect(graph.files.filter((f) => f.endsWith(".tsx"))).toEqual([]);
  });
});

describe("the scanner actually detects UI imports (control)", () => {
  const rootGraph = walk("src/index.ts");

  it("finds React and Fluent in the root entry's graph", () => {
    expect(rootGraph.bare.filter((spec) => UI_SPECIFIER.test(spec)).length).toBeGreaterThan(0);
    expect(rootGraph.bare).toContain("@fluentui/react-components");
  });

  it("reaches the .tsx component files from the root entry", () => {
    expect(rootGraph.files.some((f) => f.startsWith("src/components/"))).toBe(true);
  });

  it("shares src/validate.ts with the validate entry (one implementation)", () => {
    expect(rootGraph.files).toContain("src/validate.ts");
  });
});

describe("built dist/validate bundles are UI-free", () => {
  const bundles = ["dist/validate.js", "dist/validate.cjs"]
    .map((p) => join(pkgRoot, p))
    .filter((p) => existsSync(p));

  it.skipIf(bundles.length === 0)("import/require no react or @fluentui module", () => {
    for (const bundle of bundles) {
      const source = readFileSync(bundle, "utf-8");
      for (const pattern of SPECIFIER_PATTERNS) {
        pattern.lastIndex = 0;
        let match: RegExpExecArray | null;
        while ((match = pattern.exec(source)) !== null) {
          const spec = match[1] ?? "";
          expect.soft(UI_SPECIFIER.test(spec), `${bundle} imports ${spec}`).toBe(false);
        }
      }
    }
  });
});
