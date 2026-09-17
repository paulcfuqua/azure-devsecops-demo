import { render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { App } from "../src/App";
import { LocalProvider } from "../src/providers/LocalProvider";
import { stubLoader } from "./sampleData";

describe("App smoke render (local mode)", () => {
  it("renders the shell, Dev/Sec/Ops tabs, and the Dev pillar from provider specs", async () => {
    render(<App provider={new LocalProvider(stubLoader())} />);

    // Shell + tabs are visible immediately.
    expect(screen.getByText(/Meridian Launch Systems — Control Tower/)).toBeTruthy();
    expect(screen.getByRole("tab", { name: "Dev" })).toBeTruthy();
    expect(screen.getByRole("tab", { name: "Sec" })).toBeTruthy();
    expect(screen.getByRole("tab", { name: "Ops" })).toBeTruthy();

    // Default pillar resolves its spec and renders the Dev panel components.
    await waitFor(() => {
      expect(screen.getByText("Delivery health")).toBeTruthy();
    });
    expect(screen.getByText("Runs by workflow")).toBeTruthy();
    expect(screen.getByText("Recent workflow runs")).toBeTruthy();
    expect(screen.getByText(/Data source: local fixtures/)).toBeTruthy();
  });

  // The footer used to read "Synthetic data — Meridian Launch Systems is fictional",
  // and once the Ask tab could reach the AWS lakehouse that was half false: the agent
  // correctly splits its answers into Meridian's synthetic operations data and REAL
  // public launch-industry data, and the footer contradicted it in the same viewport.
  //
  // Asserted in both directions on purpose. A test that only checks the new words
  // passes on a footer that says both things, which is the state being fixed.
  it("says Meridian's data is synthetic WITHOUT claiming every source is", async () => {
    render(<App provider={new LocalProvider(stubLoader())} />);

    const footer = await screen.findByText(/Meridian Launch Systems is fictional/);
    const text = footer.textContent ?? "";

    expect(text).toMatch(/operations data synthetic/);
    expect(text).toMatch(/real public launch-industry data/);
    // The blanket claim, and nothing that reads as it.
    expect(text).not.toMatch(/Synthetic data —/);
  });
});
