import { describe, expect, it } from "vitest";
import { validateSpec } from "../src/index";
import { fixtureNames, loadFixture } from "./fixtures";

describe("golden fixtures", () => {
  const validNames = fixtureNames("valid");
  const invalidNames = fixtureNames("invalid");

  it("has one valid fixture per component type (9) and 3 invalid fixtures", () => {
    expect(validNames).toHaveLength(9);
    expect(invalidNames).toHaveLength(3);
  });

  it.each(validNames)("%s validates", (name) => {
    const result = validateSpec(loadFixture(name));
    expect(result.errors).toEqual([]);
    expect(result.ok).toBe(true);
  });

  it.each(invalidNames)("%s fails validation", (name) => {
    const result = validateSpec(loadFixture(name));
    expect(result.ok).toBe(false);
    expect(result.errors.length).toBeGreaterThan(0);
  });

  it("invalid-wrong-enum reports the bad layout enum at /layout", () => {
    const result = validateSpec(loadFixture("invalid-wrong-enum.json"));
    expect(result.ok).toBe(false);
    expect(result.errors.some((e) => e.path === "/layout")).toBe(true);
  });

  it("invalid-missing-required reports the missing barChart title at /components/0", () => {
    const result = validateSpec(loadFixture("invalid-missing-required.json"));
    expect(result.ok).toBe(false);
    expect(
      result.errors.some(
        (e) => e.path === "/components/0" && /title/.test(e.message),
      ),
    ).toBe(true);
  });

  it("invalid-bad-data-shape reports the x/y points inside donutChart data", () => {
    const result = validateSpec(loadFixture("invalid-bad-data-shape.json"));
    expect(result.ok).toBe(false);
    expect(
      result.errors.some((e) => e.path.startsWith("/components/0/data/0")),
    ).toBe(true);
  });
});

describe("validateSpec robustness", () => {
  it.each([
    ["null", null],
    ["undefined", undefined],
    ["a string", "barChart"],
    ["a number", 42],
    ["an array", []],
    ["an empty object", {}],
  ])("rejects %s without throwing", (_label, input) => {
    const result = validateSpec(input);
    expect(result.ok).toBe(false);
    expect(result.errors.length).toBeGreaterThan(0);
  });

  it("rejects an unknown component type", () => {
    const result = validateSpec({
      version: "1",
      layout: "stack",
      components: [{ type: "pieChart3d", title: "Nope", data: [] }],
    });
    expect(result.ok).toBe(false);
    expect(result.errors.some((e) => e.path.startsWith("/components/0"))).toBe(
      true,
    );
  });

  it("rejects extra top-level properties", () => {
    const result = validateSpec({
      version: "1",
      layout: "stack",
      components: [{ type: "statCard", title: "T", value: 1 }],
      theme: "dark",
    });
    expect(result.ok).toBe(false);
  });
});
