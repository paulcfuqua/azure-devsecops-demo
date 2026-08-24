/**
 * P-5: the `./validate` entry must work with no DOM at all.
 *
 * This file runs in the `node` vitest project — environment "node", no jsdom,
 * no tests/setup.ts polyfills. It exercises the source entry directly, and
 * then spawns a real `node` process that imports the *built*
 * `@mls/spec-renderer/validate` subpath, which is exactly what copilot-svc
 * does at runtime.
 */
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { isSpec, specSchema, validateSpec } from "../../src/validate-entry";
import { loadFixture } from "../fixtures";

describe("validate entry in a DOM-free environment", () => {
  it("has no DOM globals available", () => {
    expect(typeof globalThis.document).toBe("undefined");
    expect(typeof (globalThis as Record<string, unknown>).window).toBe("undefined");
    expect(typeof (globalThis as Record<string, unknown>).HTMLElement).toBe("undefined");
    expect(typeof (globalThis as Record<string, unknown>).Element).toBe("undefined");
  });

  it("accepts a valid golden fixture", () => {
    const result = validateSpec(loadFixture("valid-stat-card.json"));
    expect(result.errors).toEqual([]);
    expect(result.ok).toBe(true);
  });

  it("rejects an invalid golden fixture with JSON-Pointer paths", () => {
    const result = validateSpec(loadFixture("invalid-wrong-enum.json"));
    expect(result.ok).toBe(false);
    expect(result.errors.some((e) => e.path === "/layout")).toBe(true);
  });

  it("exports the isSpec type guard and the raw schema", () => {
    expect(isSpec(loadFixture("valid-bar-chart.json"))).toBe(true);
    expect(isSpec({ version: "2" })).toBe(false);
    expect(specSchema["$schema"]).toBe("https://json-schema.org/draft/2020-12/schema");
    expect(specSchema["title"]).toBe("Spec");
  });
});

const distValidate = join(process.cwd(), "dist", "validate.js");

// The bundle only exists after `npm run build`; skip rather than fail on a
// fresh clone, but assert hard once it is there (the documented flow is
// build-then-test, and `npm run build` at the repo root regenerates dist/).
describe.skipIf(!existsSync(distValidate))(
  "built @mls/spec-renderer/validate subpath in a plain Node process",
  () => {
    it("loads and validates without jsdom, vite, or any DOM shim", () => {
      const script = `
import { isSpec, specSchema, validateSpec } from "@mls/spec-renderer/validate";
const good = {
  version: "1",
  layout: "stack",
  components: [{ type: "statCard", title: "Launches", value: 1200 }],
};
const bad = {
  version: "1",
  layout: "diagonal",
  components: [{ type: "statCard", title: "Launches", value: 1200 }],
};
const badResult = validateSpec(bad);
console.log(
  JSON.stringify({
    domGlobals: ["document", "window", "HTMLElement"].filter((k) => k in globalThis),
    good: validateSpec(good).ok,
    isSpec: isSpec(good),
    bad: badResult.ok,
    badPaths: badResult.errors.map((e) => e.path),
    schemaTitle: specSchema.title,
  }),
);
`;
      const stdout = execFileSync(process.execPath, ["--input-type=module", "-e", script], {
        cwd: process.cwd(),
        encoding: "utf-8",
      });
      const out = JSON.parse(stdout.trim()) as {
        domGlobals: string[];
        good: boolean;
        isSpec: boolean;
        bad: boolean;
        badPaths: string[];
        schemaTitle: string;
      };

      expect(out.domGlobals).toEqual([]);
      expect(out.good).toBe(true);
      expect(out.isSpec).toBe(true);
      expect(out.bad).toBe(false);
      expect(out.badPaths).toContain("/layout");
      expect(out.schemaTitle).toBe("Spec");
    });
  },
);
