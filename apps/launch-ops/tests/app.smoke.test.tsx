import { render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { App } from "../src/App";
import { LocalJsonProvider } from "../src/providers/LocalJsonProvider";
import { stubLoader } from "./sampleRows";

describe("App smoke render (LOCAL_DATA mode)", () => {
  it("renders the shell, tabs, and the schedule view from provider specs", async () => {
    render(<App provider={new LocalJsonProvider(stubLoader())} />);

    // Shell + tabs are visible immediately.
    expect(screen.getByText(/Meridian Launch Systems — Launch Ops/)).toBeTruthy();
    expect(screen.getByRole("tab", { name: "Schedule" })).toBeTruthy();
    expect(screen.getByRole("tab", { name: "Outcomes" })).toBeTruthy();
    expect(screen.getByRole("tab", { name: "Scrub analysis" })).toBeTruthy();
    expect(screen.getByRole("tab", { name: "Fleet & pads" })).toBeTruthy();

    // Default view resolves its spec and renders the schedule table + timeline.
    await waitFor(() => {
      expect(screen.getByText("Launch schedule")).toBeTruthy();
    });
    expect(screen.getByText("Recent launch milestones")).toBeTruthy();
    expect(screen.getByText(/Data source: local JSON/)).toBeTruthy();
  });
});
