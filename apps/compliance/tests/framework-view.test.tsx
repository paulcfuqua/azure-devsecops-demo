import { fireEvent, render, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { Board } from "../src/Board";
import { FrameworkSwitcher } from "../src/FrameworkSwitcher";
import { fixtureCatalog, fixtureState } from "./fixtures";

describe("Board framework views (relabel/filter the same 110 records, no second data source)", () => {
  it("relabels the same records under a CMMC view", () => {
    render(<Board state={fixtureState} catalog={fixtureCatalog} framework="cmmc-2.0" />);
    expect(screen.getByTestId("control-3.5.3")).toHaveTextContent("L2-3.5.3");
  });

  it("shows only the 17 L1 practices in the CMMC Level 1 (far-52.204-21) view", () => {
    render(<Board state={fixtureState} catalog={fixtureCatalog} framework="far-52.204-21" />);
    const l1 = fixtureCatalog.requirements.filter((r) => r.mappings["far-52.204-21"]?.length);
    expect(l1).toHaveLength(17); // sanity: matches the real catalog
    expect(screen.getAllByTestId(/^control-/)).toHaveLength(17);
  });

  it("keeps the native nist-800-171r2 view showing all 110 (14 families, every control labelled by its own id)", () => {
    render(<Board state={fixtureState} catalog={fixtureCatalog} framework="nist-800-171r2" />);
    expect(screen.getAllByTestId(/^control-/)).toHaveLength(110);
    expect(screen.getByTestId("control-3.5.3")).toHaveTextContent("3.5.3");
  });

  it("never renders CP-9's authored status on requirement 3.8.9's cell, even under the nist-800-53r5 view where both share the label 'CP-9'", () => {
    const cp9 = fixtureState.outOfCatalogControls.find((c) => c.control === "CP-9")!;
    const own = fixtureState.controls.find((c) => c.control === "3.8.9")!;
    expect(cp9.status).not.toBe(own.status); // sanity: PARTIAL vs NOT_ASSESSED in the real artifact

    render(<Board state={fixtureState} catalog={fixtureCatalog} framework="nist-800-53r5" />);
    const row = screen.getByTestId("control-3.8.9");
    // Relabelled for orientation -- 3.8.9 maps to CP-9 under nist-800-53r5...
    expect(row).toHaveTextContent("CP-9");
    // ...but the status shown is 3.8.9's own, never CP-9's.
    expect(row).toHaveTextContent(own.status);
    expect(row.textContent).not.toContain(cp9.observed);
    expect(row.textContent).not.toContain(cp9.status);

    // CP-9's own record is still rendered, but in the separate
    // out-of-catalog section, never inside this family/requirement row.
    expect(screen.getByTestId("out-of-catalog-CP-9")).toBeInTheDocument();
    expect(screen.queryByTestId("control-CP-9")).toBeNull();
  });

  it("the headline and cross-tab denominators match what's actually visible under a filtered framework", () => {
    // Measured directly from the real artifact: far-52.204-21's 17 CMMC
    // Level 1 practices break down 12 NOT_ASSESSED / 3 PARTIAL / 2 GAP, all
    // 5 non-NOT_ASSESSED rows "asserted" (none machine-verified).
    render(<Board state={fixtureState} catalog={fixtureCatalog} framework="far-52.204-21" />);

    // The headline's "N of M" no longer reads the fixed 110 -- it reads 17,
    // and NOT_ASSESSED among those 17 is 12, not the unfiltered 95.
    expect(screen.getByText(/12 of 17/)).toBeInTheDocument();
    expect(screen.queryByText(/95 of 110/)).toBeNull();

    // The cross-tab's cells sum to 17, not 110: asserted covers the 3
    // PARTIAL + 2 GAP rows, "none" covers the 12 NOT_ASSESSED rows, and
    // every other cell (including machine-verified, entirely) is zero.
    const table = screen.getByRole("table", { name: /provenance and status/i });
    const assertedRow = within(table).getByText("asserted").closest("tr")!;
    const assertedCells = within(assertedRow)
      .getAllByRole("cell")
      .map((cell) => Number(cell.textContent));
    // STATUS_KEYS order: COMPLIANT, PARTIAL, GAP, INCONCLUSIVE, NOT_APPLICABLE, NOT_ASSESSED
    expect(assertedCells).toEqual([0, 3, 2, 0, 0, 0]);
    const noneRow = within(table).getByText("none").closest("tr")!;
    const noneCells = within(noneRow)
      .getAllByRole("cell")
      .map((cell) => Number(cell.textContent));
    expect(noneCells).toEqual([0, 0, 0, 0, 0, 12]);
    const allCellsAcrossTable = within(table)
      .getAllByRole("cell")
      .map((cell) => Number(cell.textContent));
    const total = allCellsAcrossTable.reduce((sum, n) => sum + n, 0);
    expect(total).toBe(17);

    // And the active framework is named explicitly, disambiguating the
    // denominator for anyone who reads the number without the context above
    // (it appears in both the headline and the cross-tab's own intro text).
    expect(screen.getAllByText(/FAR 52\.204-21/).length).toBeGreaterThan(0);
  });

  it("the native nist-800-171r2 view keeps the artifact's own committed summary as its denominator, unrecomputed", () => {
    render(<Board state={fixtureState} catalog={fixtureCatalog} framework="nist-800-171r2" />);
    const { NOT_ASSESSED } = fixtureState.summary.byStatus;
    expect(
      screen.getByText(new RegExp(`${NOT_ASSESSED} of ${fixtureState.summary.totalRequirements}`)),
    ).toBeInTheDocument();
  });

  it("a control with no mapping under a framework is not shown with an empty label -- it is filtered out entirely", () => {
    // 3.5.3 has an empty far-52.204-21 mapping array in the real catalog.
    const requirement = fixtureCatalog.requirements.find((r) => r.id === "3.5.3")!;
    expect(requirement.mappings["far-52.204-21"]).toEqual([]);
    render(<Board state={fixtureState} catalog={fixtureCatalog} framework="far-52.204-21" />);
    expect(screen.queryByTestId("control-3.5.3")).toBeNull();
  });
});

describe("FrameworkSwitcher", () => {
  it("renders a tab for each of the four framework ids", () => {
    render(<FrameworkSwitcher framework="nist-800-171r2" onChange={() => {}} />);
    for (const id of ["nist-800-171r2", "nist-800-53r5", "cmmc-2.0", "far-52.204-21"]) {
      expect(screen.getByTestId(`framework-tab-${id}`)).toBeInTheDocument();
    }
  });

  it("invokes onChange with the selected framework id", () => {
    const selections: string[] = [];
    render(
      <FrameworkSwitcher framework="nist-800-171r2" onChange={(f) => selections.push(f)} />,
    );
    fireEvent.click(screen.getByTestId("framework-tab-cmmc-2.0"));
    expect(selections).toEqual(["cmmc-2.0"]);
  });
});
