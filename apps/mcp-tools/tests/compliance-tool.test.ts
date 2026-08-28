/**
 * query_compliance — the tool where the honesty rules are most dangerous to
 * get wrong: a board makes a reader do the work of misreading it, but a
 * conversational tool will happily state a falsehood in a sentence.
 *
 * Fixtures are the REAL committed artifact (compliance/state/state-latest.json,
 * read via the same `complianceStatePath` production code resolves), never a
 * hand-rolled stand-in — mirroring apps/compliance/tests/fixtures.ts, which
 * gives the same reason: a hand-authored double could drift from the real
 * shape, which is exactly the kind of thing this platform exists to catch.
 * It is read with `fs`, not a static `import`, because apps/mcp-tools'
 * tsconfig pins `rootDir` to the package — a compile-time import reaching
 * three directories up would fail `npm run typecheck` with TS6059.
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { complianceStatePath } from "../src/config.js";
import {
  ComplianceStateBackend,
  createLocalBackends,
  loadComplianceState,
  queryComplianceState,
  type ComplianceState,
} from "../src/tools/backends.js";
import { ToolRegistry } from "../src/tools/index.js";
import { rejection } from "./helpers/rejection.js";

const fixtureState = JSON.parse(fs.readFileSync(complianceStatePath, "utf-8")) as ComplianceState;

function tempStatePath(): string {
  return path.join(fs.mkdtempSync(path.join(os.tmpdir(), "mls-compliance-test-")), "state.json");
}

/** A control this run's real register asserts GAP for (asserted provenance). */
const GAP_CONTROL = "3.1.1";
/** A control this run's real register asserts CLOSED for -> derived PARTIAL. */
const PARTIAL_CONTROL = "3.1.3";
/** A control nothing has ever touched (none provenance, no assessment file). */
const UNASSESSED_CONTROL = "3.1.4";
/** 3.8.9 is the ONLY 800-171 requirement CP-9 orients to, and today it is
 * itself untouched (NOT_ASSESSED / none) while CP-9 is PARTIAL / asserted --
 * the sharpest possible case for hazard 4. */
const REQUIREMENT_CP9_ORIENTS_TO = "3.8.9";

describe("query_compliance via the tool registry", () => {
  const registry = new ToolRegistry(createLocalBackends());

  it("returns a single control with its evidence and recommendation", async () => {
    const r: any = await registry.execute("query_compliance", { control: GAP_CONTROL });
    const fixtureRow = fixtureState.controls.find((c) => c.control === GAP_CONTROL)!;
    expect(r.controls).toHaveLength(1);
    expect(r.controls[0].status).toBe(fixtureRow.status);
    expect(r.controls[0].provenance).toBe(fixtureRow.provenance);
    expect(r.controls[0].recommendation).toBeTruthy();
  });

  it("filters by status across the whole catalog", async () => {
    const r: any = await registry.execute("query_compliance", { status: "GAP" });
    expect(r.controls.length).toBeGreaterThan(0);
    expect(r.controls.every((c: any) => c.status === "GAP")).toBe(true);
    // Matches the artifact's own count exactly -- not a subset, not a superset.
    expect(r.controls.length).toBe(fixtureState.summary.byStatus.GAP);
  });

  it("agrees with the board for every one of the 110 controls (parity)", async () => {
    // One source of truth: if the tool and the board ever disagree, one of
    // them is lying. Walks the whole real catalog, not a sample.
    for (const c of fixtureState.controls) {
      const r: any = await registry.execute("query_compliance", { control: c.control });
      expect(r.controls).toHaveLength(1);
      expect(r.controls[0].status).toBe(c.status);
      expect(r.controls[0].provenance).toBe(c.provenance);
      expect(r.controls[0].observed).toBe(c.observed);
    }
  });

  it("never invents a recommendation for a control with no assessment", async () => {
    const r: any = await registry.execute("query_compliance", { control: UNASSESSED_CONTROL });
    const fixtureRow = fixtureState.controls.find((c) => c.control === UNASSESSED_CONTROL)!;
    expect(fixtureRow.assessment).toBeNull();
    expect(r.controls[0].recommendation).toBeNull();
  });

  it("passes an authored recommendation through verbatim, never paraphrased", async () => {
    const r: any = await registry.execute("query_compliance", { control: PARTIAL_CONTROL });
    const fixtureRow = fixtureState.controls.find((c) => c.control === PARTIAL_CONTROL)!;
    expect(r.controls[0].recommendation).toBe(fixtureRow.assessment!.recommendation);
  });
});

describe("hazard 1 — no blended percentage, score or ratio, ever", () => {
  const registry = new ToolRegistry(createLocalBackends());

  it("no key anywhere in a query_compliance answer is percent/ratio/score-shaped", async () => {
    const r = await registry.execute("query_compliance", {});
    const badKeys: string[] = [];
    (function walk(node: unknown, keyPath: string): void {
      if (Array.isArray(node)) {
        node.forEach((v, i) => walk(v, `${keyPath}[${i}]`));
        return;
      }
      if (node && typeof node === "object") {
        for (const [key, value] of Object.entries(node)) {
          if (/percent|ratio|\bscore\b/i.test(key)) badKeys.push(`${keyPath}.${key}`);
          walk(value, `${keyPath}.${key}`);
        }
      }
    })(r, "$");
    expect(badKeys).toEqual([]);
  });

  it("the serialized answer never contains a literal '%' character", async () => {
    // The real artifact contains no '%' anywhere (compliance/README.md and the
    // emitter's own tests enforce this at the source); a computed figure like
    // "13.6%" would be the first place one could sneak back in.
    const r = await registry.execute("query_compliance", {});
    expect(JSON.stringify(r)).not.toContain("%");
  });

  it("asking for a percentage still gets only counts back: the summary carries no computed figure", async () => {
    const r: any = await registry.execute("query_compliance", {});
    expect(typeof r.summary.byStatus.COMPLIANT).toBe("number");
    expect(typeof r.summary.totalRequirements).toBe("number");
    // The tool's own notes explain the refusal so the agent can say why,
    // rather than trying to compute one itself from the counts.
    expect(r.notes.join(" ")).toMatch(/no percentage/i);
  });
});

describe("hazard 2 — never report a bare provenance total", () => {
  it("the summary carries byProvenanceAndStatus and its own caveat about reading it", () => {
    const result = queryComplianceState(fixtureState, {});
    expect(result.summary.byProvenanceAndStatus).toBeDefined();
    expect(result.summary.byProvenanceAndStatus["machine-verified"]).toBeDefined();
    expect(result.notes.join(" ")).toMatch(/byProvenanceAndStatus/);
    expect(result.notes.join(" ")).toMatch(/does not mean passing|verified.and.passing/i);
  });

  it("only COMPLIANT means verified-and-passing, in this run's real data", () => {
    // Today's real artifact has zero COMPLIANT controls (nothing has been
    // deployed) -- this asserts the invariant, not today's particular count.
    const result = queryComplianceState(fixtureState, {});
    for (const c of result.controls) {
      if (c.provenance === "machine-verified" && c.status !== "COMPLIANT") {
        // machine-verified + not COMPLIANT must mean INCONCLUSIVE (a skipped
        // or failed criterion), never silently read as "verified and passing".
        expect(c.status === "INCONCLUSIVE" || c.status === "GAP").toBe(true);
      }
    }
  });
});

describe("hazard 3 — CLOSED in the register is not COMPLIANT", () => {
  it("every control the register asserts CLOSED for renders PARTIAL, never COMPLIANT", () => {
    const result = queryComplianceState(fixtureState, {});
    const closedAssertions = result.controls.filter((c) => c.registerStatus === "CLOSED");
    expect(closedAssertions.length).toBeGreaterThan(0);
    for (const c of closedAssertions) {
      expect(c.status).toBe("PARTIAL");
      expect(c.status).not.toBe("COMPLIANT");
    }
  });

  it("registerStatus (the raw authored word) is exposed distinctly from the derived status", () => {
    const result = queryComplianceState(fixtureState, { control: PARTIAL_CONTROL });
    expect(result.controls[0]!.registerStatus).toBe("CLOSED");
    expect(result.controls[0]!.status).toBe("PARTIAL");
  });
});

describe("hazard 4 — outOfCatalogControls never answers for an 800-171 requirement", () => {
  it("a query about 3.8.9 never returns CP-9's status", () => {
    const cp9 = fixtureState.outOfCatalogControls.find((c) => c.control === "CP-9")!;
    expect(cp9.status).toBe("PARTIAL"); // sanity: CP-9 really is asserted CLOSED->PARTIAL
    expect(cp9.requirementsMappingToThisControl).toContain(REQUIREMENT_CP9_ORIENTS_TO);

    const result = queryComplianceState(fixtureState, { control: REQUIREMENT_CP9_ORIENTS_TO });
    expect(result.controls).toHaveLength(1);
    expect(result.controls[0]!.control).toBe(REQUIREMENT_CP9_ORIENTS_TO);
    // 3.8.9 itself is untouched -- CP-9's PARTIAL must not have leaked onto it.
    expect(result.controls[0]!.status).toBe("NOT_ASSESSED");
    expect(result.controls[0]!.provenance).toBe("none");
    expect(result.outOfCatalogControls).toHaveLength(0);
  });

  it("querying CP-9 by its own id returns it only in outOfCatalogControls, never in controls", () => {
    const result = queryComplianceState(fixtureState, { control: "CP-9" });
    expect(result.controls).toHaveLength(0);
    expect(result.outOfCatalogControls).toHaveLength(1);
    expect(result.outOfCatalogControls[0]!.control).toBe("CP-9");
    expect(result.outOfCatalogControls[0]!.mappingIsOrientationOnly).toBe(true);
    expect(result.outOfCatalogControls[0]!.statusMayBeRenderedOnMappedRequirements).toBe(false);
  });

  it("the four out-of-catalog ids never appear inside the 110-requirement controls array", () => {
    const result = queryComplianceState(fixtureState, {});
    const catalogIds = new Set(result.controls.map((c) => c.control));
    for (const id of ["CM-6", "CP-9", "IR-4", "SI-4"]) {
      expect(catalogIds.has(id)).toBe(false);
    }
  });
});

describe("hazard 5 — duplicatesStatusBasis records are not counted as evidence", () => {
  it("a manual-collector transcription is dropped from supportingEvidence", () => {
    const fixtureRow = fixtureState.controls.find((c) => c.control === GAP_CONTROL)!;
    const rawDuplicate = fixtureRow.supportingEvidence.find((e) => e.duplicatesStatusBasis === true);
    expect(rawDuplicate).toBeDefined(); // sanity: the fixture really has one to filter

    const result = queryComplianceState(fixtureState, { control: GAP_CONTROL });
    const answer = result.controls[0]!;
    expect(answer.supportingEvidence.some((e) => e.duplicatesStatusBasis === true)).toBe(false);
    expect(answer.evidence.some((e) => e.duplicatesStatusBasis === true)).toBe(false);
    expect(answer.duplicateAssertionsOmitted).toBeGreaterThan(0);
  });

  it("independent (non-duplicate) collected evidence is kept, not thrown out with it", () => {
    // 3.3.1 carries a repo-static record (independent) alongside the manual
    // duplicate -- proves the filter removes only the duplicate, not everything.
    const control = "3.3.1";
    const fixtureRow = fixtureState.controls.find((c) => c.control === control)!;
    expect(fixtureRow.supportingEvidence.some((e) => e.source === "repo-static")).toBe(true);
    expect(fixtureRow.supportingEvidence.some((e) => e.duplicatesStatusBasis === true)).toBe(true);

    const result = queryComplianceState(fixtureState, { control });
    const answer = result.controls[0]!;
    expect(answer.supportingEvidence.some((e) => e.source === "repo-static")).toBe(true);
    expect(answer.supportingEvidence.every((e) => e.duplicatesStatusBasis !== true)).toBe(true);
  });
});

describe("hazard 6 — a missing or malformed artifact never returns an empty-but-confident answer", () => {
  it("a missing artifact file throws, rather than answering with no controls", async () => {
    const backend = new ComplianceStateBackend(path.join(os.tmpdir(), "does-not-exist-mls", "state.json"));
    const error: any = await rejection(backend.query({}));
    expect(error.name).toBe("AdapterError");
    expect(error.kind).toBe("not_found");
    expect(error.message).toMatch(/not found/i);
  });

  it("malformed JSON throws, rather than answering with no controls", async () => {
    const badPath = tempStatePath();
    fs.writeFileSync(badPath, "{ this is not valid json");
    const backend = new ComplianceStateBackend(badPath);
    const error: any = await rejection(backend.query({}));
    expect(error.name).toBe("AdapterError");
    expect(error.message).toMatch(/not valid JSON/i);
  });

  it("valid JSON that is not shaped like a state artifact throws, rather than answering", async () => {
    const badPath = tempStatePath();
    fs.writeFileSync(badPath, JSON.stringify({ hello: "world" }));
    const backend = new ComplianceStateBackend(badPath);
    const error: any = await rejection(backend.query({}));
    expect(error.name).toBe("AdapterError");
    expect(error.message).toMatch(/missing required fields/i);
  });

  it("propagates through the MCP tool registry as a rejection, never a silent empty success", async () => {
    const backends = createLocalBackends();
    backends.compliance = new ComplianceStateBackend(
      path.join(os.tmpdir(), "does-not-exist-mls-2", "state.json"),
    );
    const registry = new ToolRegistry(backends);
    await expect(registry.execute("query_compliance", {})).rejects.toThrow(/not found/i);
  });

  it("loadComplianceState throws the same way in isolation", () => {
    expect(() => loadComplianceState("/definitely/not/a/real/path.json")).toThrow(/not found/i);
  });
});

describe("the 95-unassessed figure is present in any summary answer", () => {
  const cases: Array<[string, import("../src/tools/backends.js").ComplianceQueryParams]> = [
    ["no filter", {}],
    ["control filter", { control: GAP_CONTROL }],
    ["family filter", { family: "3.1" }],
    ["status filter", { status: "GAP" }],
    ["out-of-catalog framework filter", { framework: "nist-800-53r5" }],
    ["a control filter that matches nothing", { control: "9.9.9" }],
  ];

  it.each(cases)("summary.byStatus.NOT_ASSESSED is 95 for: %s", (_label, params) => {
    const result = queryComplianceState(fixtureState, params);
    expect(result.summary.byStatus.NOT_ASSESSED).toBe(95);
    expect(result.summary.totalRequirements).toBe(110);
  });
});

describe("filtering", () => {
  it("family narrows to the 110-catalog controls in that family only", () => {
    const result = queryComplianceState(fixtureState, { family: "3.1" });
    expect(result.controls.length).toBeGreaterThan(0);
    expect(result.controls.every((c) => c.family === "3.1")).toBe(true);
  });

  it("framework nist-800-171r2 returns only catalog controls, never out-of-catalog ones", () => {
    const result = queryComplianceState(fixtureState, { framework: "nist-800-171r2" });
    expect(result.controls.length).toBe(110);
    expect(result.outOfCatalogControls).toHaveLength(0);
  });

  it("framework nist-800-53r5 returns exactly the four out-of-catalog records, never catalog ones", () => {
    const result = queryComplianceState(fixtureState, { framework: "nist-800-53r5" });
    expect(result.controls).toHaveLength(0);
    expect(result.outOfCatalogControls).toHaveLength(4);
    expect(result.outOfCatalogControls.map((c) => c.control).sort()).toEqual([
      "CM-6",
      "CP-9",
      "IR-4",
      "SI-4",
    ]);
  });

  it("an unmatched control returns empty arrays, not an error (absence of a match is honest too)", () => {
    const result = queryComplianceState(fixtureState, { control: "9.9.9" });
    expect(result.controls).toHaveLength(0);
    expect(result.outOfCatalogControls).toHaveLength(0);
    expect(result.matchCount).toBe(0);
  });

  it("control matching is case-insensitive", () => {
    const result = queryComplianceState(fixtureState, { control: "cp-9" });
    expect(result.outOfCatalogControls).toHaveLength(1);
    expect(result.outOfCatalogControls[0]!.control).toBe("CP-9");
  });
});
