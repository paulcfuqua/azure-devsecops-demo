import { fireEvent, render, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { Board } from "../src/Board";
import { cloneState, fixtureCatalog, fixtureState } from "./fixtures";

// The task-10 brief's own test sketch names controls (3.5.3 as
// machine-verified, 3.6.1 as asserted) that do not match today's real
// committed artifact: every control in it is either NOT_ASSESSED/none or
// asserted (GAP/PARTIAL) -- there are zero machine-verified rows anywhere
// in compliance/state/state-latest.json (summary.byProvenance["machine-
// verified"] is 0). These tests are adapted to the real artifact's actual
// shape rather than hand-rolling data that could drift from it (see
// tests/fixtures.ts), using cloneState() -- mirroring Task 9's own
// precedent (tests/app.test.tsx's XSS test) -- only for the one scenario
// (a machine-verified row) the real artifact does not currently contain.

describe("Board", () => {
  it("shows all 14 families with per-status counts", () => {
    render(<Board state={fixtureState} catalog={fixtureCatalog} framework="nist-800-171r2" />);
    expect(screen.getAllByTestId("family-card")).toHaveLength(14);
  });

  it("visually distinguishes machine-verified from asserted provenance, not by colour alone", () => {
    const mutated = cloneState();
    const verifiedControl = mutated.controls.find((c) => c.control === "3.5.3")!;
    verifiedControl.provenance = "machine-verified";
    const assertedControl = mutated.controls.find((c) => c.control === "3.1.1")!;
    expect(assertedControl.provenance).toBe("asserted"); // sanity: real data

    render(<Board state={mutated} catalog={fixtureCatalog} framework="nist-800-171r2" />);

    const verifiedBadge = within(screen.getByTestId("control-3.5.3")).getByTestId("provenance");
    const assertedBadge = within(screen.getByTestId("control-3.1.1")).getByTestId("provenance");
    expect(verifiedBadge).toHaveTextContent(/verified/i);
    expect(assertedBadge).toHaveTextContent(/asserted/i);
    // The distinction must not rely on colour alone -- both carry their own
    // accessible label naming the actual provenance value.
    expect(verifiedBadge).toHaveAttribute("aria-label", "provenance: machine-verified");
    expect(assertedBadge).toHaveAttribute("aria-label", "provenance: asserted");
  });

  it("renders NOT_ASSESSED distinctly from GAP -- not just different text, different treatment", () => {
    render(<Board state={fixtureState} catalog={fixtureCatalog} framework="nist-800-171r2" />);
    // 3.5.3 is NOT_ASSESSED and 3.1.1 is GAP in the real artifact.
    const notAssessed = within(screen.getByTestId("control-3.5.3")).getByTestId("status");
    const gap = within(screen.getByTestId("control-3.1.1")).getByTestId("status");
    expect(notAssessed).toHaveTextContent("NOT_ASSESSED");
    expect(gap).toHaveTextContent("GAP");
    // "We have not looked" (NOT_ASSESSED) must not be a shade of "we looked
    // and it failed" (GAP) -- a different colour is applied, which shows up
    // here as a different generated class list.
    expect(notAssessed.className).not.toBe(gap.className);
  });

  it("shows how fresh the evidence is", () => {
    render(<Board state={fixtureState} catalog={fixtureCatalog} framework="nist-800-171r2" />);
    const freshness = screen.getByTestId("collected-at");
    expect(freshness).toBeInTheDocument();
    expect(freshness).toHaveTextContent(fixtureState.collectedAt);
  });

  it("makes the 95-of-110 NOT_ASSESSED figure impossible to miss", () => {
    render(<Board state={fixtureState} catalog={fixtureCatalog} framework="nist-800-171r2" />);
    const { NOT_ASSESSED } = fixtureState.summary.byStatus;
    expect(NOT_ASSESSED).toBeGreaterThan(0); // sanity: today's real artifact does have unassessed rows
    expect(
      screen.getByText(new RegExp(`${NOT_ASSESSED} of ${fixtureState.summary.totalRequirements}`)),
    ).toBeInTheDocument();
  });

  it("never renders a percentage anywhere on the board", () => {
    const { container } = render(
      <Board state={fixtureState} catalog={fixtureCatalog} framework="nist-800-171r2" />,
    );
    expect(container.textContent ?? "").not.toMatch(/%/);
  });

  it("never renders a bare summary.byProvenance total, only the byProvenanceAndStatus cross-tab", () => {
    render(<Board state={fixtureState} catalog={fixtureCatalog} framework="nist-800-171r2" />);
    const table = screen.getByRole("table", { name: /provenance and status/i });
    for (const provenance of ["machine-verified", "asserted", "declared", "none"]) {
      const rowHeader = within(table).getByText(provenance);
      const row = rowHeader.closest("tr");
      expect(row).not.toBeNull();
      expect(within(row!).getAllByRole("cell")).toHaveLength(6); // one per status, never a collapsed total
    }
    for (const [provenance, count] of Object.entries(fixtureState.summary.byProvenance)) {
      expect(screen.queryByText(`${provenance}: ${count}`)).toBeNull();
      expect(screen.queryByText(`${provenance} ${count}`)).toBeNull();
    }
  });

  it("renders out-of-catalog controls on their own, separate rows -- never inside a family card", () => {
    render(<Board state={fixtureState} catalog={fixtureCatalog} framework="nist-800-171r2" />);
    for (const row of fixtureState.outOfCatalogControls) {
      expect(screen.getByTestId(`out-of-catalog-${row.control}`)).toBeInTheDocument();
      // Out-of-catalog testids never collide with the `control-<id>` pattern
      // family cards use -- see framework-view.test.tsx for why that
      // distinction matters under a framework switch.
      expect(screen.queryByTestId(`control-${row.control}`)).toBeNull();
    }
  });

  it("clicking a control row invokes onSelectControl with the control's own id", () => {
    const clicks: string[] = [];
    render(
      <Board
        state={fixtureState}
        catalog={fixtureCatalog}
        framework="nist-800-171r2"
        onSelectControl={(control) => clicks.push(control)}
      />,
    );
    fireEvent.click(screen.getByTestId("control-3.1.1"));
    expect(clicks).toEqual(["3.1.1"]);
  });

  it("clicking an out-of-catalog row also invokes onSelectControl with its own id", () => {
    const clicks: string[] = [];
    render(
      <Board
        state={fixtureState}
        catalog={fixtureCatalog}
        framework="nist-800-171r2"
        onSelectControl={(control) => clicks.push(control)}
      />,
    );
    fireEvent.click(screen.getByTestId("out-of-catalog-CP-9"));
    expect(clicks).toEqual(["CP-9"]);
  });

  it("makes the never-deployed fact impossible to miss, sourced from the verification-suite collector's own limitation", () => {
    const { container } = render(
      <Board state={fixtureState} catalog={fixtureCatalog} framework="nist-800-171r2" />,
    );
    const verificationSuite = fixtureState.collectors.find((c) => c.name === "verification-suite")!;
    expect(verificationSuite.limitation).toMatch(/deployed/i); // sanity: today's real text says so
    const banner = screen.getByTestId("deployment-banner");
    expect(banner).toHaveTextContent(/deployed/i);
    expect(banner).toHaveTextContent(verificationSuite.limitation);
    // The word appears on the rendered board at all -- the reviewer's own
    // check ("grepped the whole rendered board, 'deployed' appears zero
    // times") is the thing this test exists to keep from regressing.
    expect(container.textContent ?? "").toMatch(/deployed/i);
  });

  it("renders every collector's status, record count and limitation -- not just a pointer to JSON", () => {
    render(<Board state={fixtureState} catalog={fixtureCatalog} framework="nist-800-171r2" />);
    for (const collector of fixtureState.collectors) {
      const row = screen.getByTestId(`collector-${collector.name}`);
      expect(row).toHaveTextContent(collector.name);
      expect(row).toHaveTextContent(collector.status);
      expect(row).toHaveTextContent(collector.limitation);
      expect(within(row).getByTestId("collector-status")).toHaveTextContent(collector.status);
    }
    // A healthy run says so, explicitly.
    expect(fixtureState.collectors.every((c) => c.status === "ok")).toBe(true); // sanity
    expect(screen.getByTestId("collector-summary")).toHaveTextContent(/all 5 collectors ran/i);
  });

  it("visibly flags a failed collector -- a half-failed run must not render identically to a healthy one", () => {
    const mutated = cloneState();
    const okBadgeBefore = (() => {
      const { unmount } = render(
        <Board state={fixtureState} catalog={fixtureCatalog} framework="nist-800-171r2" />,
      );
      const el = within(screen.getByTestId("collector-manual")).getByTestId("collector-status");
      const cls = el.className;
      unmount();
      return cls;
    })();

    mutated.collectors[0]!.status = "failed";
    mutated.collectors[0]!.error = "SYNTHETIC: collector threw for this test only.";
    render(<Board state={mutated} catalog={fixtureCatalog} framework="nist-800-171r2" />);

    expect(screen.getByTestId("collector-summary")).toHaveTextContent(
      `1 of ${mutated.collectors.length} collectors failed`,
    );
    const failedRow = screen.getByTestId(`collector-${mutated.collectors[0]!.name}`);
    expect(within(failedRow).getByTestId("collector-error")).toHaveTextContent(
      "SYNTHETIC: collector threw for this test only.",
    );
    // Distinct colour from a healthy collector's badge, not just different text.
    const failedBadge = within(failedRow).getByTestId("collector-status");
    expect(failedBadge.className).not.toBe(okBadgeBefore);
  });

  it("renders assessmentProblems when present", () => {
    const mutated = cloneState();
    mutated.assessmentProblems = [
      { file: "compliance/assessment/broken.json", problem: "SYNTHETIC: invalid JSON for this test." },
    ];
    render(<Board state={mutated} catalog={fixtureCatalog} framework="nist-800-171r2" />);
    const panel = screen.getByTestId("assessment-problems");
    expect(panel).toHaveTextContent("compliance/assessment/broken.json");
    expect(panel).toHaveTextContent("SYNTHETIC: invalid JSON for this test.");
  });

  it("does not render an assessment-problems section when there are none (the real, common case)", () => {
    expect(fixtureState.assessmentProblems).toEqual([]); // sanity
    render(<Board state={fixtureState} catalog={fixtureCatalog} framework="nist-800-171r2" />);
    expect(screen.queryByTestId("assessment-problems")).toBeNull();
  });

  it("renders a control's observed text as text, not markup", () => {
    const mutated = cloneState();
    const target = mutated.controls.find((c) => c.control === "3.1.1")!;
    target.observed = "Uses <b>bold</b> and <script>alert(1)</script> in the raw text.";

    const { container } = render(
      <Board state={mutated} catalog={fixtureCatalog} framework="nist-800-171r2" />,
    );

    expect(
      screen.getByText(/<b>bold<\/b> and <script>alert\(1\)<\/script>/),
    ).toBeInTheDocument();
    expect(container.querySelector("script")).toBeNull();
    expect(container.querySelector("b")).toBeNull();
  });
});
