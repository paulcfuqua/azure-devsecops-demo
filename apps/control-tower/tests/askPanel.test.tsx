import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { FluentProvider, webLightTheme } from "@fluentui/react-components";
import { describe, expect, it, vi } from "vitest";
import { AdaptiveCardView } from "../src/AdaptiveCardView";
import { App } from "../src/App";
import { AskPanel } from "../src/AskPanel";
import { OfflineAgentProvider } from "../src/agent/providers";
import type {
  AdaptiveCard,
  AgentConnection,
  AgentProvider,
  DirectLineActivity,
} from "../src/agent/types";
import { LocalProvider } from "../src/providers/LocalProvider";
import { stubLoader } from "./sampleData";
import type { JSX } from "react";

function withTheme(node: React.ReactNode): JSX.Element {
  return <FluentProvider theme={webLightTheme}>{node}</FluentProvider>;
}

/** An in-memory AgentConnection: no Direct Line, no transport, no timers. */
function stubConnection(): AgentConnection & {
  emit(activity: DirectLineActivity): void;
  sent: string[];
} {
  const listeners = new Set<(a: DirectLineActivity) => void>();
  const sent: string[] = [];
  return {
    conversationId: "conv-test",
    sent,
    emit(activity) {
      for (const listener of listeners) listener(activity);
    },
    async send(text) {
      sent.push(text);
    },
    onActivity(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    onError() {
      return () => {};
    },
    close() {
      listeners.clear();
    },
  };
}

function stubProvider(connection: AgentConnection): AgentProvider {
  return {
    source: "Copilot Studio agent via Direct Line (stub)",
    available: true,
    connect: () => Promise.resolve(connection),
  };
}

const POSTURE_CARD: AdaptiveCard = {
  type: "AdaptiveCard",
  version: "1.5",
  body: [
    { type: "TextBlock", text: "Launch readiness", weight: "Bolder", size: "Large" },
    {
      type: "FactSet",
      facts: [
        { title: "Open alerts", value: "11" },
        { title: "Secure score", value: "71.6%" },
      ],
    },
    {
      type: "ColumnSet",
      columns: [{ items: [{ type: "TextBlock", text: "Aurora-7" }] }],
    },
  ],
  actions: [
    { type: "Action.OpenUrl", title: "Open runbook", url: "https://example.invalid/runbook" },
    { type: "Action.Submit", title: "Show the cost breakdown", data: "cost breakdown" },
  ],
};

describe("Ask tab — offline state (local mode)", () => {
  it("explains that Copilot Studio is cloud-only and never fakes an answer", () => {
    render(
      withTheme(
        <AskPanel
          provider={
            new OfflineAgentProvider(
              "No VITE_DIRECTLINE_TOKEN_URL is configured, so there is no Direct Line channel to talk to.",
            )
          }
        />,
      ),
    );

    expect(screen.getByTestId("ask-offline")).toBeTruthy();
    expect(screen.getByText(/Ask is offline in local mode/)).toBeTruthy();
    expect(screen.getByText(/cloud-only/)).toBeTruthy();
    // Named twice on purpose: once in the provider's reason, once in the
    // remediation hint.
    expect(screen.getAllByText(/VITE_DIRECTLINE_TOKEN_URL/).length).toBeGreaterThan(0);
    expect(screen.getByText(/no mock agent, no canned reply/)).toBeTruthy();

    // Offline means offline: no composer to type into, nothing to submit.
    expect(screen.queryByRole("button", { name: "Ask" })).toBeNull();
    expect(screen.queryByLabelText("Ask the agent")).toBeNull();
  });

  it("surfaces the leaked-build-variable reason verbatim", () => {
    render(
      withTheme(
        <AskPanel
          provider={
            new OfflineAgentProvider(
              "The build variable `VITE_DIRECTLINE_SECRET` looks like secret material.",
            )
          }
        />,
      ),
    );
    expect(screen.getByText(/VITE_DIRECTLINE_SECRET/)).toBeTruthy();
  });
});

describe("Ask tab — connected", () => {
  it("renders agent text and Adaptive Cards, and sends what the operator types", async () => {
    const connection = stubConnection();
    render(withTheme(<AskPanel provider={stubProvider(connection)} />));

    await waitFor(() => expect(screen.getByTestId("ask-ready")).toBeTruthy());

    connection.emit({
      type: "message",
      id: "agent-1",
      from: { id: "mls-agent", role: "bot" },
      text: "Here is the launch posture.",
      attachments: [
        { contentType: "application/vnd.microsoft.card.adaptive", content: POSTURE_CARD },
      ],
    });

    await waitFor(() => expect(screen.getByText("Here is the launch posture.")).toBeTruthy());
    expect(screen.getByTestId("adaptive-card")).toBeTruthy();
    expect(screen.getByText("Launch readiness")).toBeTruthy();
    expect(screen.getByText("Open alerts")).toBeTruthy();

    const input = screen.getByLabelText("Ask the agent");
    fireEvent.change(input, { target: { value: "what is our cost variance?" } });
    fireEvent.click(screen.getByRole("button", { name: "Ask" }));

    await waitFor(() => expect(connection.sent).toEqual(["what is our cost variance?"]));
    expect(screen.getByText("what is our cost variance?")).toBeTruthy();
  });

  it("turns an Adaptive Card Submit action into the next message", async () => {
    const connection = stubConnection();
    render(withTheme(<AskPanel provider={stubProvider(connection)} />));
    await waitFor(() => expect(screen.getByTestId("ask-ready")).toBeTruthy());

    connection.emit({
      type: "message",
      id: "agent-2",
      from: { id: "mls-agent" },
      attachments: [
        { contentType: "application/vnd.microsoft.card.adaptive", content: POSTURE_CARD },
      ],
    });

    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Show the cost breakdown" })).toBeTruthy(),
    );
    fireEvent.click(screen.getByRole("button", { name: "Show the cost breakdown" }));
    await waitFor(() => expect(connection.sent).toEqual(["cost breakdown"]));
  });

  it("reports a failed connection inside the tab rather than crashing", async () => {
    const provider: AgentProvider = {
      source: "Direct Line (stub)",
      available: true,
      connect: () => Promise.reject(new Error("token endpoint responded 503")),
    };
    render(withTheme(<AskPanel provider={provider} />));
    await waitFor(() => expect(screen.getByText(/token endpoint responded 503/)).toBeTruthy());
    expect(screen.getByText("Agent unavailable")).toBeTruthy();
  });
});

describe("AdaptiveCardView", () => {
  it("reports elements outside the rendered subset instead of dropping them", () => {
    render(
      withTheme(
        <AdaptiveCardView
          card={{
            type: "AdaptiveCard",
            body: [
              { type: "TextBlock", text: "known" },
              { type: "Media", sources: [] },
            ],
          }}
        />,
      ),
    );
    expect(screen.getByText("known")).toBeTruthy();
    const unsupported = screen.getByTestId("adaptive-card-unsupported");
    expect(unsupported.textContent).toContain("Media");
  });

  it("renders Action.OpenUrl as a link, not a button that posts back", () => {
    render(withTheme(<AdaptiveCardView card={POSTURE_CARD} />));
    const link = screen.getByRole("link", { name: "Open runbook" });
    expect(link.getAttribute("href")).toBe("https://example.invalid/runbook");
    expect(link.getAttribute("rel")).toContain("noopener");
  });

  // The pinned profile is 1.5 + Action.Submit: Web Chat does not support
  // Action.Execute and Teams caps at 1.5, so a card using it would render here
  // and nowhere else. Reporting it is the point.
  it("reports Action.Execute as out-of-profile rather than rendering it", () => {
    render(
      withTheme(
        <AdaptiveCardView
          card={{
            type: "AdaptiveCard",
            version: "1.6",
            body: [],
            actions: [{ type: "Action.Execute", title: "Run the flow", verb: "run" }],
          }}
        />,
      ),
    );
    expect(screen.queryByRole("button", { name: "Run the flow" })).toBeNull();
    expect(screen.getByTestId("adaptive-card-unsupported").textContent).toContain(
      "Action.Execute",
    );
  });
});

describe("App shell with the fourth tab", () => {
  it("renders Dev/Sec/Ops/Ask and shows the offline Ask panel on selection", async () => {
    render(
      <App
        provider={new LocalProvider(stubLoader())}
        agent={new OfflineAgentProvider("No VITE_DIRECTLINE_TOKEN_URL is configured.")}
      />,
    );

    for (const name of ["Dev", "Sec", "Ops", "Ask"]) {
      expect(screen.getByRole("tab", { name })).toBeTruthy();
    }

    // Dev still resolves its spec from the data provider.
    await waitFor(() => expect(screen.getByText("Delivery health")).toBeTruthy());

    fireEvent.click(screen.getByRole("tab", { name: "Ask" }));
    await waitFor(() => expect(screen.getByTestId("ask-offline")).toBeTruthy());

    // The other tabs are untouched by the Ask tab being offline.
    fireEvent.click(screen.getByRole("tab", { name: "Ops" }));
    await waitFor(() => expect(screen.queryByTestId("ask-offline")).toBeNull());
  });

  it("defaults the Ask tab to offline when the shell gets no agent provider", async () => {
    const connect = vi.fn();
    render(<App provider={new LocalProvider(stubLoader())} />);
    fireEvent.click(screen.getByRole("tab", { name: "Ask" }));
    await waitFor(() => expect(screen.getByTestId("ask-offline")).toBeTruthy());
    expect(connect).not.toHaveBeenCalled();
  });
});
