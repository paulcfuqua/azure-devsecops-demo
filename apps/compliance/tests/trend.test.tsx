import { render, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { Trend } from "../src/Trend";
import { cloneState, fixtureState } from "./fixtures";
import type { ComplianceState } from "../src/types";

// The task-12 brief's own test sketch (`history={[stateAug20, stateAug26]}`)
// posits two dated snapshots; the real repo has collected exactly one so
// far (compliance/state/ has one dated file plus its state-latest.json
// copy -- see main.tsx). Both scenarios matter and are tested here: the
// real, single-collection artifact (must render honestly, not as an empty
// chart or an error), and a synthetic two-point history (cloneState() on
// two dates, mirroring tests/app.test.tsx's precedent) for the regression-
// naming behaviour the real data can't exercise yet.

function withCollectedAt(date: string): ComplianceState {
  const snapshot = cloneState();
  snapshot.collectedAt = `${date}T12:00:00Z`;
  return snapshot;
}

describe("Trend — single real collection", () => {
  it("renders honestly with one point: not an empty chart, not an error", () => {
    render(<Trend history={[fixtureState]} />);
    expect(screen.getByTestId("trend-single-point")).toHaveTextContent(/one collection/i);
    expect(screen.getByTestId("trend-single-point")).toHaveTextContent(/no trend yet/i);
    // A real "trend-chart" (a comparison across >=2 points) is not faked
    // for a single point.
    expect(screen.queryByTestId("trend-chart")).toBeNull();
  });

  it("renders honestly with zero collections too", () => {
    render(<Trend history={[]} />);
    expect(screen.getByTestId("trend-empty")).toBeInTheDocument();
    expect(screen.queryByTestId("trend-chart")).toBeNull();
  });

  it("never renders a percentage or bare provenance total", () => {
    const { container } = render(<Trend history={[fixtureState]} />);
    expect(container.textContent ?? "").not.toMatch(/%/);
    expect((container.textContent ?? "").toLowerCase()).not.toContain("machine-verified:");
  });
});

/** Two dated snapshots with a manufactured regression: 3.3.1 is PARTIAL in
 * the real fixture today, so the newer copy is forced to GAP (worse) to
 * exercise the "names the date a control regressed" behaviour the real,
 * single-collection artifact cannot exercise on its own.
 *
 * `summary.byStatus`/`byProvenanceAndStatus` are updated alongside
 * `controls[].status` so the fixture stays internally consistent -- a
 * reviewer found the original version of this fixture mutated only the
 * control, leaving `summary` (a separately-maintained field on the same
 * object) stale, which would have silently plotted identical counts for
 * both dates had Trend.tsx trusted `summary` instead of recomputing from
 * `controls` directly (see Trend.tsx's `tallyByStatus`). Both are fixed
 * here: Trend.tsx no longer trusts `summary` for its table, and this
 * fixture no longer produces an inconsistent `ComplianceState` regardless. */
function twoPointHistory(): [ComplianceState, ComplianceState] {
  const older = withCollectedAt("2026-08-20");
  const newer = withCollectedAt("2026-08-26");
  const target = newer.controls.find((c) => c.control === "3.3.1")!;
  if (target.status !== "PARTIAL" || target.provenance !== "asserted") {
    throw new Error(
      "fixture assumption changed: 3.3.1 is no longer PARTIAL/asserted in the real artifact",
    );
  }
  target.status = "GAP";
  newer.summary.byStatus.PARTIAL -= 1;
  newer.summary.byStatus.GAP += 1;
  newer.summary.byProvenanceAndStatus.asserted.PARTIAL -= 1;
  newer.summary.byProvenanceAndStatus.asserted.GAP += 1;
  return [older, newer];
}

describe("Trend — synthetic two-point history", () => {
  it("plots status counts across committed state artifacts, and the two dates actually differ", () => {
    const [older, newer] = twoPointHistory();
    render(<Trend history={[older, newer]} />);
    const chart = screen.getByTestId("trend-chart");
    expect(chart).toBeInTheDocument();

    // Scoped to each date's own row, not just "the chart contains some
    // numbers somewhere" -- a chart that plotted the same (stale) counts
    // for both dates despite the regression below would pass a looser
    // assertion. Column order is STATUS_KEYS: COMPLIANT, PARTIAL, GAP, ...
    const olderRow = within(chart).getByText(older.collectedAt).closest("tr")!;
    const newerRow = within(chart).getByText(newer.collectedAt).closest("tr")!;
    const olderCells = within(olderRow)
      .getAllByRole("cell")
      .map((cell) => Number(cell.textContent));
    const newerCells = within(newerRow)
      .getAllByRole("cell")
      .map((cell) => Number(cell.textContent));
    expect(olderCells).not.toEqual(newerCells);
    expect(olderCells[1]).toBe(newerCells[1]! + 1); // PARTIAL: one higher before the regression
    expect(olderCells[2]).toBe(newerCells[2]! - 1); // GAP: one lower before the regression
  });

  it("names the date a control regressed", () => {
    const [older, newer] = twoPointHistory();
    render(<Trend history={[older, newer]} />);
    expect(screen.getByText(/3\.3\.1.*2026-08-26/)).toBeInTheDocument();
    expect(screen.getByText(/regressed/i)).toBeInTheDocument();
  });

  it("counts only, never a percentage or ratio, across the whole trend view", () => {
    const [older, newer] = twoPointHistory();
    const { container } = render(<Trend history={[older, newer]} />);
    const text = container.textContent ?? "";
    expect(text).not.toMatch(/%/);
    expect(text).not.toMatch(/\d+\s*\/\s*\d+/);
  });

  it("accepts history in either order (sorts by collectedAt itself)", () => {
    const [older, newer] = twoPointHistory();
    render(<Trend history={[newer, older]} />);
    expect(screen.getByText(/3\.3\.1.*2026-08-26/)).toBeInTheDocument();
  });
});
