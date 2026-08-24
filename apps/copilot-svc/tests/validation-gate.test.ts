/**
 * The spec-validation gate (V8.1 check b): specs are validated against the
 * renderer schema BEFORE return; an invalid spec gets exactly one repair
 * round; a still-invalid repair yields a structured error, never an invalid
 * spec.
 */
import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.js";
import { MockLlmDriver } from "../src/llm/mock.js";
import {
  ALWAYS_INVALID_QUESTION,
  BROKEN_SPEC,
  INVALID_THEN_VALID_QUESTION,
} from "../src/llm/plans.js";
import { runAsk } from "../src/loop.js";
import { createLocalBackends } from "../src/tools/backends.js";
import { ToolRegistry } from "../src/tools/index.js";
import { tryParseSpecJson, validateSpec } from "../src/validation.js";

const config = { ...loadConfig(), llmMode: "mock" as const };
const deps = () => ({
  config,
  registry: new ToolRegistry(createLocalBackends()),
  driver: new MockLlmDriver(),
});

describe("validateSpec (schema gate)", () => {
  it("accepts a valid renderer spec", () => {
    const r = validateSpec({
      version: "1",
      layout: "grid",
      components: [
        { type: "statCard", title: "Launches", value: 1200 },
        { type: "barChart", title: "By day", data: [{ x: "Sat", y: 309 }] },
      ],
    });
    expect(r.ok).toBe(true);
    expect(r.errors).toEqual([]);
  });

  it("rejects the broken spec with JSON-Pointer error paths", () => {
    const r = validateSpec(BROKEN_SPEC);
    expect(r.ok).toBe(false);
    expect(r.errors.length).toBeGreaterThan(0);
    const paths = r.errors.map((e) => e.path).join(" ");
    expect(paths).toContain("/layout");
  });

  it("rejects non-objects and junk", () => {
    expect(validateSpec(null).ok).toBe(false);
    expect(validateSpec("<div>hi</div>").ok).toBe(false);
    expect(validateSpec({ version: "2", layout: "stack", components: [] }).ok).toBe(false);
  });

  it("tryParseSpecJson handles bare JSON, fenced JSON, and junk", () => {
    expect(tryParseSpecJson('{"a":1}')).toEqual({ ok: true, value: { a: 1 } });
    expect(tryParseSpecJson('```json\n{"a":1}\n```')).toEqual({ ok: true, value: { a: 1 } });
    expect(tryParseSpecJson("not json").ok).toBe(false);
    expect(tryParseSpecJson("").ok).toBe(false);
  });
});

describe("repair round and error path", () => {
  it("invalid first answer -> one repair round -> valid spec returned", async () => {
    const result = await runAsk(INVALID_THEN_VALID_QUESTION, deps());
    expect(result.ok).toBe(true);
    if (result.ok) {
      // The repaired spec is schema-valid and built from the real tool result.
      expect(validateSpec(result.spec).ok).toBe(true);
      expect(JSON.stringify(result.spec)).toContain("1200");
    }
  });

  it("invalid answer + invalid repair -> structured error, never an invalid spec", async () => {
    const result = await runAsk(ALWAYS_INVALID_QUESTION, deps());
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error).toBe("invalid_spec");
      expect(result.validationErrors?.length).toBeGreaterThan(0);
    }
  });
});
