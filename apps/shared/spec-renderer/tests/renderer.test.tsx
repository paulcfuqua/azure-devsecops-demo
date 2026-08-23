import { FluentProvider, webLightTheme } from "@fluentui/react-components";
import { render, screen, within } from "@testing-library/react";
import type { ReactElement } from "react";
import { afterEach, describe, expect, it } from "vitest";
import { cleanup } from "@testing-library/react";
import { SpecRenderer } from "../src/index";
import { loadFixture } from "./fixtures";

afterEach(cleanup);

function renderSpec(spec: unknown): ReturnType<typeof render> {
  return render(
    (<FluentProvider theme={webLightTheme}>
      <SpecRenderer spec={spec} />
    </FluentProvider>) as ReactElement,
  );
}

describe("SpecRenderer renders every component type", () => {
  const cases: Array<[fixture: string, title: string]> = [
    ["valid-bar-chart.json", "Launches per Vehicle"],
    ["valid-line-chart.json", "Launch Cadence by Month"],
    ["valid-area-chart.json", "Cumulative Payload Mass"],
    ["valid-stat-card.json", "Launch Success Rate"],
    ["valid-kpi-row.json", "Mission Operations KPIs"],
    ["valid-data-table.json", "Recent Launches"],
    ["valid-timeline.json", "MLS-132 Countdown Milestones"],
    ["valid-donut-chart.json", "Scrub Causes"],
    ["valid-markdown-block.json", "Analysis Summary"],
  ];

  it.each(cases)("%s renders without crashing and shows its title", (fixture, title) => {
    renderSpec(loadFixture(fixture));
    expect(screen.getAllByText(title).length).toBeGreaterThan(0);
    expect(screen.queryByTestId("spec-renderer-error")).toBeNull();
  });

  it("statCard shows the formatted value with unit", () => {
    renderSpec(loadFixture("valid-stat-card.json"));
    expect(screen.getByText(/98\.3\s*%/)).toBeTruthy();
  });

  it("kpiRow shows every item label", () => {
    renderSpec(loadFixture("valid-kpi-row.json"));
    for (const label of ["Launches YTD", "Scrub Rate", "Avg Turnaround", "Next Window"]) {
      expect(screen.getByText(label)).toBeTruthy();
    }
  });

  it("dataTable shows column headers and cell values", () => {
    renderSpec(loadFixture("valid-data-table.json"));
    const table = screen.getByRole("table");
    expect(within(table).getByText("Mission")).toBeTruthy();
    expect(within(table).getByText("MLS-131")).toBeTruthy();
    expect(within(table).getByText("Kestrel Heavy")).toBeTruthy();
  });

  it("timeline shows event labels", () => {
    renderSpec(loadFixture("valid-timeline.json"));
    expect(screen.getByText("Static fire complete")).toBeTruthy();
    expect(screen.getByText("Range weather violation")).toBeTruthy();
  });

  it("markdownBlock renders headings, emphasis, and list items as elements", () => {
    renderSpec(loadFixture("valid-markdown-block.json"));
    expect(screen.getByText("Saturday launch bias")).toBeTruthy();
    const bold = screen.getByText("busiest launch day");
    expect(bold.tagName).toBe("STRONG");
    expect(screen.getByText("Weekend range availability is higher")).toBeTruthy();
    const link = screen.getByText("ops handbook");
    expect(link.tagName).toBe("A");
    expect(link.getAttribute("href")).toBe("https://example.com/handbook");
  });

  it("markdownBlock never injects raw HTML", () => {
    const { container } = renderSpec({
      version: "1",
      layout: "stack",
      components: [
        {
          type: "markdownBlock",
          markdown: "Hello <img src=x onerror=alert(1)> **world**",
        },
      ],
    });
    expect(container.querySelector("img")).toBeNull();
    expect(screen.getByText(/<img src=x onerror=alert\(1\)>/)).toBeTruthy();
  });

  it("renders multiple components in one grid spec", () => {
    renderSpec({
      version: "1",
      layout: "grid",
      components: [
        { type: "statCard", title: "Stat A", value: 1 },
        { type: "statCard", title: "Stat B", value: 2 },
        { type: "markdownBlock", title: "Notes", markdown: "Some *notes*." },
      ],
    });
    expect(screen.getByText("Stat A")).toBeTruthy();
    expect(screen.getByText("Stat B")).toBeTruthy();
    expect(screen.getByText("Notes")).toBeTruthy();
  });
});

describe("SpecRenderer error handling", () => {
  it.each([
    "invalid-wrong-enum.json",
    "invalid-missing-required.json",
    "invalid-bad-data-shape.json",
  ])("%s renders the error MessageBar instead of throwing", (fixture) => {
    renderSpec(loadFixture(fixture));
    const bar = screen.getByTestId("spec-renderer-error");
    expect(bar).toBeTruthy();
    expect(bar.textContent).toMatch(/invalid spec/i);
  });

  it("shows error details including the failing path", () => {
    renderSpec(loadFixture("invalid-wrong-enum.json"));
    const bar = screen.getByTestId("spec-renderer-error");
    expect(bar.textContent).toContain("/layout");
  });

  it("handles a completely non-spec input without throwing", () => {
    renderSpec("this is not a spec");
    expect(screen.getByTestId("spec-renderer-error")).toBeTruthy();
  });

  it("handles undefined without throwing", () => {
    renderSpec(undefined);
    expect(screen.getByTestId("spec-renderer-error")).toBeTruthy();
  });
});
