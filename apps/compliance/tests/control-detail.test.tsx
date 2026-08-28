import { render, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { ControlDetail } from "../src/ControlDetail";
import { cloneState, fixtureCatalog, fixtureState } from "./fixtures";

// The task-11 brief's own test sketch ("GET /v1.0/identity/conditionalAccess",
// "enabledForReportingButNotEnforced", a control named "3.5.3") is the
// design spec's illustrative example, not the real committed artifact --
// 3.5.3 is NOT_ASSESSED with no evidence today, and no control anywhere in
// the real artifact has a machine-collected criterion/command (every
// record takes the authored path; see state-latest.json's own
// notes.supportingEvidence). These tests use a real GAP control (3.1.1,
// asserted, real statusBasis/assessment/recommendation) for the "judge the
// raw evidence" and "recommendation" scenarios, and cloneState() -- same
// precedent as tests/app.test.tsx's XSS test -- for the http(s) link guard,
// since the real artifact has zero http(s) URLs in it anywhere (every
// reference is a repo-relative path).

describe("ControlDetail", () => {
  it("shows the control's actual status basis (the raw claim), so a reader can judge the mapping rather than trust it", () => {
    render(<ControlDetail control="3.1.1" state={fixtureState} catalog={fixtureCatalog} />);
    const control = fixtureState.controls.find((c) => c.control === "3.1.1")!;
    expect(control.statusBasis.length).toBeGreaterThan(0); // sanity
    const basis = control.statusBasis[0]!;

    // Scoped to the actual Status basis section's own record container, not
    // to text anywhere on the page: `basis.detail` happens to be byte-
    // identical to the control's own top-level `observed` summary for every
    // authored control, and that summary renders on its own line regardless
    // of whether the Status basis section exists at all -- a reviewer found
    // an earlier version of this test stayed green even with the entire
    // Status basis section deleted, because it only checked that the text
    // appeared *somewhere*. Scoping into `status-basis-record` means
    // deleting that section removes the element this test queries for,
    // which fails the query outright rather than silently passing.
    const basisRecords = screen.getAllByTestId("status-basis-record");
    expect(basisRecords.length).toBe(control.statusBasis.length);
    const firstRecord = basisRecords[0]!;
    expect(within(firstRecord).getByText(basis.kind)).toBeInTheDocument();
    expect(within(firstRecord).getByText(basis.detail)).toBeInTheDocument();
    expect(within(firstRecord).getByText(new RegExp(`source: ${basis.source}`))).toBeInTheDocument();
  });

  it("shows the recommendation for a gap", () => {
    render(<ControlDetail control="3.1.1" state={fixtureState} catalog={fixtureCatalog} />);
    expect(screen.getByTestId("recommendation")).not.toBeEmptyDOMElement();
    const control = fixtureState.controls.find((c) => c.control === "3.1.1")!;
    expect(screen.getByTestId("recommendation")).toHaveTextContent(
      control.assessment!.recommendation,
    );
  });

  it("links an http(s) evidence artifact to a real link", () => {
    const mutated = cloneState();
    const target = mutated.controls.find((c) => c.control === "3.1.1")!;
    target.statusBasis[0]!.artifact = "https://example.test/reports/L03-2026-08-26.md";

    render(<ControlDetail control="3.1.1" state={mutated} catalog={fixtureCatalog} />);
    const link = screen.getByRole("link", { name: /L03/ });
    expect(link).toHaveAttribute("href", "https://example.test/reports/L03-2026-08-26.md");
  });

  it("never turns a repo-relative reference into a clickable link (the real, common case)", () => {
    render(<ControlDetail control="3.1.1" state={fixtureState} catalog={fixtureCatalog} />);
    const control = fixtureState.controls.find((c) => c.control === "3.1.1")!;
    const relativeRef = control.assessment!.references[0]!;
    expect(relativeRef).not.toMatch(/^https?:\/\//); // sanity: real refs are repo-relative
    expect(screen.getByText(relativeRef)).toBeInTheDocument();
    expect(screen.queryByRole("link", { name: relativeRef })).toBeNull();
  });

  it("refuses a javascript: URI masquerading as an evidence artifact", () => {
    const mutated = cloneState();
    const target = mutated.controls.find((c) => c.control === "3.1.1")!;
    target.statusBasis[0]!.artifact = "javascript:alert(1)";

    render(<ControlDetail control="3.1.1" state={mutated} catalog={fixtureCatalog} />);
    expect(screen.queryByRole("link")).toBeNull();
    expect(screen.getByText("javascript:alert(1)")).toBeInTheDocument();
  });

  it("does not list a duplicatesStatusBasis record as independent evidence (3.13.16, real data)", () => {
    render(<ControlDetail control="3.13.16" state={fixtureState} catalog={fixtureCatalog} />);
    const control = fixtureState.controls.find((c) => c.control === "3.13.16")!;
    const duplicate = control.supportingEvidence.find((e) => e.duplicatesStatusBasis === true)!;
    expect(duplicate).toBeDefined(); // sanity: 3.13.16 really does carry one
    const independent = control.supportingEvidence.filter((e) => !e.duplicatesStatusBasis);
    expect(independent.length).toBeGreaterThan(0); // sanity: and real, non-duplicate evidence too

    // The duplicate's own observed text (the manual transcription) is not
    // shown as its own evidence record...
    expect(screen.queryByText(duplicate.observed)).toBeNull();
    // ...while the independent repo-static records ARE shown.
    for (const record of independent) {
      expect(screen.getByText(record.observed)).toBeInTheDocument();
    }
    // The suppression is visible, not silent: a merge note says how many.
    expect(screen.getByTestId("merged-duplicate-note")).toHaveTextContent("1");
  });

  it("does not list a duplicatesStatusBasis record as independent evidence even from the (today, always empty) evidence array", () => {
    // The emitter only ever sets duplicatesStatusBasis on supportingEvidence
    // records today, so this scenario cannot occur in the real artifact --
    // but types.ts states the rule unconditionally on the shared
    // EvidenceRecord type, and ControlDetail.tsx now filters both arrays
    // rather than relying on that emitter invariant holding forever.
    const mutated = cloneState();
    const target = mutated.controls.find((c) => c.control === "3.1.1")!;
    // Isolated to just this scenario: 3.1.1 also carries a real, pre-existing
    // duplicatesStatusBasis record in supportingEvidence (see the earlier
    // test), which would otherwise add its own count to the merge note.
    target.supportingEvidence = [];
    target.evidence = [
      {
        source: "manual",
        criterion: null,
        status: "fail",
        observed: "SYNTHETIC duplicate evidence record for this test only.",
        artifact: null,
        collectedAt: null,
        participatedInStatus: true,
        duplicatesStatusBasis: true,
      },
    ];

    render(<ControlDetail control="3.1.1" state={mutated} catalog={fixtureCatalog} />);
    expect(
      screen.queryByText("SYNTHETIC duplicate evidence record for this test only."),
    ).toBeNull();
    expect(screen.getByTestId("merged-duplicate-note")).toHaveTextContent("1");
  });

  it("never renders CP-9's authored status on requirement 3.8.9's own detail view", () => {
    const cp9 = fixtureState.outOfCatalogControls.find((c) => c.control === "CP-9")!;
    const own = fixtureState.controls.find((c) => c.control === "3.8.9")!;
    expect(cp9.status).not.toBe(own.status); // sanity: they really do differ (PARTIAL vs NOT_ASSESSED)

    render(<ControlDetail control="3.8.9" state={fixtureState} catalog={fixtureCatalog} />);
    const panel = screen.getByTestId("control-detail");
    // 3.8.9's own status badge shows its own (real) status, never CP-9's --
    // the Framework mappings section below is allowed to name "CP-9" as an
    // orientation label (the same mapping Board.tsx's frameworkLabel uses),
    // just never attach CP-9's authored status or assertion text to it.
    expect(within(panel).getByTestId("status")).toHaveTextContent(own.status);
    expect(panel.textContent).not.toContain(cp9.observed);
    expect(panel.textContent).not.toContain(cp9.status); // "PARTIAL" never appears; own status is NOT_ASSESSED
  });

  it("renders CP-9 itself as an out-of-catalog record, distinct from any catalog control's detail view", () => {
    render(<ControlDetail control="CP-9" state={fixtureState} catalog={fixtureCatalog} />);
    const cp9 = fixtureState.outOfCatalogControls.find((c) => c.control === "CP-9")!;
    const panel = screen.getByTestId("control-detail-out-of-catalog");
    expect(within(panel).getByTestId("status")).toHaveTextContent(cp9.status);
    expect(panel.textContent).toContain("3.8.9"); // orientation only, named as such in the banner text
  });

  it("renders a control's authored text as text, never as markup", () => {
    const mutated = cloneState();
    const target = mutated.controls.find((c) => c.control === "3.1.1")!;
    target.observed = "Uses <b>bold</b> and <script>alert(1)</script> in the raw text.";

    const { container } = render(<ControlDetail control="3.1.1" state={mutated} catalog={fixtureCatalog} />);
    expect(screen.getByText(/<b>bold<\/b> and <script>alert\(1\)<\/script>/)).toBeInTheDocument();
    expect(container.querySelector("script")).toBeNull();
    expect(container.querySelector("b")).toBeNull();
  });
});
