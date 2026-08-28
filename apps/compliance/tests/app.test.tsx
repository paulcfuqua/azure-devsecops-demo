import { render, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { App } from "../src/App";
import { cloneState, fixtureCatalog, fixtureState } from "./fixtures";

describe("App (real state artifact)", () => {
  it("renders the family summary from a state artifact", () => {
    render(<App state={fixtureState} catalog={fixtureCatalog} />);
    expect(screen.getByText(/Access Control/)).toBeInTheDocument();
  });

  it("renders from the real artifact shape (framework name, families, controls)", () => {
    render(<App state={fixtureState} catalog={fixtureCatalog} />);
    // The header renders the artifact's own frameworkName, not a hardcoded string.
    expect(screen.getByText(new RegExp(fixtureState.frameworkName))).toBeInTheDocument();
    // Every one of the 14 catalog families appears, including ones that are
    // 100% NOT_ASSESSED -- the family list comes from the catalog, not from
    // which families happen to have an assessed control.
    const familyIds = new Set(fixtureCatalog.requirements.map((r) => r.family));
    expect(familyIds.size).toBe(14);
    for (const id of familyIds) {
      expect(screen.getByText(new RegExp(`^${id.replace(".", "\\.")} `))).toBeInTheDocument();
    }
    // A real control id from the artifact is rendered.
    expect(screen.getAllByText(fixtureState.controls[0]!.control).length).toBeGreaterThan(0);
  });

  it("makes the unassessed count impossible to miss", () => {
    render(<App state={fixtureState} catalog={fixtureCatalog} />);
    const notAssessed = fixtureState.summary.byStatus.NOT_ASSESSED;
    expect(notAssessed).toBeGreaterThan(0); // sanity: the real artifact does have unassessed rows
    expect(
      screen.getByText(new RegExp(`${notAssessed} of ${fixtureState.summary.totalRequirements}`)),
    ).toBeInTheDocument();
  });

  it("never displays a blended compliance percentage", () => {
    const { container } = render(<App state={fixtureState} catalog={fixtureCatalog} />);
    expect(container.textContent).not.toMatch(/\d+%\s*compliant/i);
  });

  it("never renders a percentage or a blended ratio anywhere in the UI", () => {
    const { container } = render(<App state={fixtureState} catalog={fixtureCatalog} />);
    const text = container.textContent ?? "";
    // No "%" character at all -- the header's own disclaimer text says the
    // word "percentage" in prose (asserted below), which is fine; a "%"
    // character would mean an actual figure was rendered, which is not.
    expect(text).not.toMatch(/%/);
    // A blended ratio like "12/110" or "12 / 110" would be the same failure
    // mode in a different shape.
    expect(text).not.toMatch(/\d+\s*\/\s*\d+/);
    // The disclaimer itself is present -- this is the one place "percentage"
    // and "score" as words are expected to appear, explaining their absence.
    expect(screen.getByText(/never a blended percentage, score or ratio/i)).toBeInTheDocument();
  });

  it("never renders a bare summary.byProvenance total (only byProvenanceAndStatus)", () => {
    render(<App state={fixtureState} catalog={fixtureCatalog} />);
    // What should exist is the cross-tab: one row per provenance value, with
    // one cell per status (never a single collapsed total cell).
    const table = screen.getByRole("table", { name: /provenance and status/i });
    for (const provenance of ["machine-verified", "asserted", "declared", "none"]) {
      const rowHeader = within(table).getByText(provenance);
      const row = rowHeader.closest("tr");
      expect(row).not.toBeNull();
      expect(within(row!).getAllByRole("cell")).toHaveLength(6); // one per status
    }
    // And directly: a bare total (e.g. "asserted: 15") is the exact trust
    // badge the brief warns about -- "N machine-verified" reads as N
    // verified, crediting a criterion that was only ever inconclusive.
    // Assert each provenance's actual bare count (from the real artifact)
    // is not rendered as its own "label: count" text anywhere.
    for (const [provenance, count] of Object.entries(fixtureState.summary.byProvenance)) {
      expect(screen.queryByText(`${provenance}: ${count}`)).toBeNull();
      expect(screen.queryByText(`${provenance} ${count}`)).toBeNull();
    }
  });

  it("renders a control's observed text as text, not markup", () => {
    const mutated = cloneState();
    const target = mutated.controls[0]!;
    target.observed = "Uses <b>bold</b> and <script>alert(1)</script> in the raw text.";

    const { container } = render(<App state={mutated} catalog={fixtureCatalog} />);

    // The literal markup characters survive as text content...
    expect(
      screen.getByText(/<b>bold<\/b> and <script>alert\(1\)<\/script>/),
    ).toBeInTheDocument();
    // ...and never became real DOM elements.
    expect(container.querySelector("script")).toBeNull();
    expect(container.querySelector("b")).toBeNull();
  });

  it("renders out-of-catalog controls separately, never against a mapped requirement", () => {
    render(<App state={fixtureState} catalog={fixtureCatalog} />);
    const cp9 = fixtureState.outOfCatalogControls.find((c) => c.control === "CP-9");
    expect(cp9).toBeDefined();
    // CP-9's row renders under its own id (anchored: CP-9's own note text
    // also mentions "CP-9" in prose, so an unanchored match finds both)...
    expect(screen.getByText(/^CP-9 \(/)).toBeInTheDocument();
    // ...and 3.8.9 (the requirement CP-9 orients to) still shows its own,
    // independently-derived status -- not CP-9's.
    const mapped = fixtureState.controls.find((c) => c.control === "3.8.9");
    expect(mapped).toBeDefined();
    const mappedRow = screen.getByText("3.8.9").closest("div");
    expect(mappedRow).not.toBeNull();
    expect(mappedRow!.textContent).toContain(mapped!.status);
  });
});
