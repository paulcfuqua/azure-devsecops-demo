import { render, screen } from "@testing-library/react";
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
 * single-collection artifact cannot exercise on its own. */
function twoPointHistory(): [ComplianceState, ComplianceState] {
  const older = withCollectedAt("2026-08-20");
  const newer = withCollectedAt("2026-08-26");
  const target = newer.controls.find((c) => c.control === "3.3.1")!;
  if (target.status !== "PARTIAL") {
    throw new Error("fixture assumption changed: 3.3.1 is no longer PARTIAL in the real artifact");
  }
  target.status = "GAP";
  return [older, newer];
}

describe("Trend — synthetic two-point history", () => {
  it("plots status counts across committed state artifacts", () => {
    const [older, newer] = twoPointHistory();
    render(<Trend history={[older, newer]} />);
    expect(screen.getByTestId("trend-chart")).toBeInTheDocument();
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
