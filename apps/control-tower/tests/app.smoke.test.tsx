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
});
