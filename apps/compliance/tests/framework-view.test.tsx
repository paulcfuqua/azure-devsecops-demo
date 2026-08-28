import { fireEvent, render, screen } from "@testing-library/react";
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
