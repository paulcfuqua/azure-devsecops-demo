import { validateSpec } from "@mls/spec-renderer";
import { afterEach, describe, expect, it, vi } from "vitest";
import { resolveDataMode } from "../src/providers";
import { ApiProvider } from "../src/providers/ApiProvider";
import { localFixtures, LocalProvider } from "../src/providers/LocalProvider";
import { buildDevSpec, buildOpsSpec, buildSecSpec } from "../src/providers/specs";
import { sampleCostRows, sampleTelemetryRows, stubLoader } from "./sampleData";

describe("buildDevSpec (Dev pillar)", () => {
  const spec = buildDevSpec(localFixtures.workflowRuns, localFixtures.appRequests);

  it("produces a valid renderer spec", () => {
    const result = validateSpec(spec);
    expect(result.errors).toEqual([]);
    expect(result.ok).toBe(true);
  });

  it("computes CI success rate and workflow counts from the runs feed", () => {
    const kpi = spec.components.find((c) => c.type === "kpiRow");
    if (kpi?.type !== "kpiRow") throw new Error("no kpiRow");
    // 16 completed runs, 2 with conclusion "failure" -> 87.5%.
    expect(kpi.items.find((i) => i.label === "CI success rate")?.value).toBe(87.5);
    expect(kpi.items.find((i) => i.label === "Active workflows")?.value).toBe(4);

    const byWorkflow = spec.components.find(
      (c) => c.type === "barChart" && c.title === "Runs by workflow",
    );
    if (byWorkflow?.type !== "barChart") throw new Error("no workflow barChart");
    expect(byWorkflow.data.reduce((sum, p) => sum + p.y, 0)).toBe(16);
  });

  it("turns the Log Analytics result into a daily success-rate series", () => {
    const line = spec.components.find((c) => c.type === "lineChart");
    if (line?.type !== "lineChart") throw new Error("no lineChart");
    // 14 days of rows, two app roles each -> one pooled point per day.
    expect(line.data).toHaveLength(14);
    // Day buckets are anchored at noon UTC so the chart's local-time axis
    // labels the right day in every timezone.
    expect(line.data[0]?.x).toBe("2026-08-08T12:00:00Z");
    for (const point of line.data) {
      expect(point.y).toBeGreaterThan(90);
      expect(point.y).toBeLessThanOrEqual(100);
    }
    // 2026-08-13 is the seeded bad day: lowest success rate in the window.
    const worst = line.data.reduce((a, b) => (b.y < a.y ? b : a));
    expect(worst.x).toBe("2026-08-13T12:00:00Z");
  });

  it("tolerates an empty Log Analytics result", () => {
    const empty = buildDevSpec(localFixtures.workflowRuns, { tables: [] });
    expect(validateSpec(empty).ok).toBe(true);
    expect(empty.components.some((c) => c.type === "lineChart")).toBe(false);
  });
});

describe("buildSecSpec (Sec pillar)", () => {
  const spec = buildSecSpec(
    localFixtures.codeScanningAlerts,
    localFixtures.dependabotAlerts,
    localFixtures.secureScore,
    localFixtures.secureScoreControls,
  );

  it("produces a valid renderer spec", () => {
    const result = validateSpec(spec);
    expect(result.errors).toEqual([]);
    expect(result.ok).toBe(true);
  });

  it("counts only open alerts and reads the Defender secure score", () => {
    const kpi = spec.components.find((c) => c.type === "kpiRow");
    if (kpi?.type !== "kpiRow") throw new Error("no kpiRow");
    expect(kpi.items.find((i) => i.label === "Open code scanning alerts")?.value).toBe(6);
    expect(kpi.items.find((i) => i.label === "Open dependency alerts")?.value).toBe(5);
    expect(kpi.items.find((i) => i.label === "Critical (open)")?.value).toBe(2);
    expect(kpi.items.find((i) => i.label === "Defender secure score")?.value).toBe(71.6);
  });

  it("normalizes Dependabot 'moderate' onto the medium severity bucket", () => {
    const bySeverity = spec.components.find(
      (c) => c.type === "barChart" && c.title === "Open alerts by severity",
    );
    if (bySeverity?.type !== "barChart") throw new Error("no severity barChart");
    expect(bySeverity.data).toEqual([
      { x: "Critical", y: 2 },
      { x: "High", y: 2 },
      { x: "Medium", y: 4 },
      { x: "Low", y: 3 },
    ]);
    // 11 open alerts across both feeds, severity buckets sum to the same total.
    expect(bySeverity.data.reduce((sum, p) => sum + p.y, 0)).toBe(11);
  });

  it("lists open alerts from both feeds, highest severity first", () => {
    const table = spec.components.find((c) => c.type === "dataTable");
    if (table?.type !== "dataTable") throw new Error("no dataTable");
    expect(table.rows).toHaveLength(11);
    expect(table.rows[0]?.severity).toBe("Critical");
    expect(table.rows[table.rows.length - 1]?.severity).toBe("Low");
    const sources = new Set(table.rows.map((r) => r.source));
    expect(sources.has("CodeQL")).toBe(true);
    expect(sources.has("Dependabot")).toBe(true);
  });
});

describe("buildOpsSpec (Ops pillar)", () => {
  const spec = buildOpsSpec(sampleCostRows, sampleTelemetryRows);

  it("produces a valid renderer spec", () => {
    const result = validateSpec(spec);
    expect(result.errors).toEqual([]);
    expect(result.ok).toBe(true);
  });

  it("aggregates cost by month and by cost center", () => {
    const line = spec.components.find((c) => c.type === "lineChart");
    if (line?.type !== "lineChart") throw new Error("no lineChart");
    expect(line.data).toEqual([
      { x: "2025-01-01T12:00:00Z", y: 15 },
      { x: "2025-02-01T12:00:00Z", y: 15 },
    ]);

    const donut = spec.components.find((c) => c.type === "donutChart");
    if (donut?.type !== "donutChart") throw new Error("no donutChart");
    expect(donut.data).toEqual([
      { label: "Propulsion", value: 20 },
      { label: "Avionics", value: 6 },
      { label: "Cloud & IT", value: 4 },
    ]);
  });

  it("computes budget variance and telemetry stats, ignoring null metrics", () => {
    const kpi = spec.components.find((c) => c.type === "kpiRow");
    if (kpi?.type !== "kpiRow") throw new Error("no kpiRow");
    // 30,000 spent against 28,000 budgeted -> +7.1%.
    expect(kpi.items.find((i) => i.label === "Budget variance")?.value).toBe(7.1);
    expect(kpi.items.find((i) => i.label === "Budget variance")?.trend).toBe("up");
    // Coverage averages the two non-null rows: (100 + 96) / 2.
    expect(kpi.items.find((i) => i.label === "Avg telemetry coverage")?.value).toBe(98);
    expect(kpi.items.find((i) => i.label === "Flight anomalies")?.value).toBe(3);

    const anomalies = spec.components.find(
      (c) => c.type === "statCard" && c.title === "Launches with anomalies",
    );
    if (anomalies?.type !== "statCard") throw new Error("no anomaly statCard");
    expect(anomalies.value).toBe(2);
  });
});

describe("LocalProvider (local mode)", () => {
  it("builds valid specs for all three pillars", async () => {
    const provider = new LocalProvider(stubLoader());
    const specs = await Promise.all([
      provider.getDevSpec(),
      provider.getSecSpec(),
      provider.getOpsSpec(),
    ]);
    for (const spec of specs) {
      expect(validateSpec(spec).ok).toBe(true);
    }
  });

  it("serves Dev and Sec from committed fixtures without touching the loader", async () => {
    const loader = vi.fn(stubLoader());
    const provider = new LocalProvider(loader);
    await provider.getDevSpec();
    await provider.getSecSpec();
    expect(loader).not.toHaveBeenCalled();
    await provider.getOpsSpec();
    expect(loader.mock.calls.map(([t]) => t).sort()).toEqual([
      "cost_daily",
      "telemetry_summary",
    ]);
  });

  it("rejects non-array generated payloads with a clear error", async () => {
    const provider = new LocalProvider(() => Promise.resolve({ not: "rows" }));
    await expect(provider.getOpsSpec()).rejects.toThrow(/array of rows/);
  });
});

describe("ApiProvider (L7/L9 wiring contract)", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("fetches the documented feed paths and builds the same valid specs", async () => {
    const payloads: Record<string, unknown> = {
      "feeds/workflow-runs": localFixtures.workflowRuns,
      "feeds/app-requests": localFixtures.appRequests,
      "feeds/code-scanning-alerts": localFixtures.codeScanningAlerts,
      "feeds/dependabot-alerts": localFixtures.dependabotAlerts,
      "feeds/secure-score": localFixtures.secureScore,
      "feeds/secure-score-controls": localFixtures.secureScoreControls,
      "tables/cost_daily": sampleCostRows,
      "tables/telemetry_summary": sampleTelemetryRows,
    };
    const fetchMock = vi.fn(async (url: string) => {
      const path = url.replace(/^\/api\//, "");
      return new Response(JSON.stringify(payloads[path] ?? null), { status: 200 });
    });
    vi.stubGlobal("fetch", fetchMock);

    const provider = new ApiProvider("/api");
    expect(validateSpec(await provider.getDevSpec()).ok).toBe(true);
    expect(validateSpec(await provider.getSecSpec()).ok).toBe(true);
    expect(validateSpec(await provider.getOpsSpec()).ok).toBe(true);
    expect(fetchMock.mock.calls.map(([u]) => u).sort()).toEqual([
      "/api/feeds/app-requests",
      "/api/feeds/code-scanning-alerts",
      "/api/feeds/dependabot-alerts",
      "/api/feeds/secure-score",
      "/api/feeds/secure-score-controls",
      "/api/feeds/workflow-runs",
      "/api/tables/cost_daily",
      "/api/tables/telemetry_summary",
    ]);
  });

  // This used to assert the message mentioned LOCAL_DATA, pinning advice that was true
  // before the tenant existed and misleading afterwards: by the time anyone reads it L7
  // IS deployed, and there is no LOCAL_DATA build published for them to switch to. A
  // test asserting the CURRENT message rather than a USEFUL one turns stale guidance
  // into a contract - and this one would have blocked its own fix.
  it("names the status and the endpoint when a feed refuses", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("not here", { status: 404 })),
    );
    const provider = new ApiProvider();
    await expect(provider.getSecSpec()).rejects.toThrow(/responded 404/);
    await expect(provider.getSecSpec()).rejects.toThrow(/\/api\/feeds\//);
  });

  it("surfaces data-api's own explanation when it sends one", async () => {
    // The 503 that actually blanks the Dev and Sec tabs carries a typed envelope whose
    // message names the fix. Repeating that text here would only re-pin a string; what
    // this asserts is that whatever the server explains REACHES THE USER, because the
    // alternative - a client-side guess - is how the LOCAL_DATA advice survived so long.
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({
              error: { code: "backend_not_configured", message: "MLS_GITHUB_TOKEN is empty on this instance" },
            }),
            { status: 503, headers: { "content-type": "application/json" } },
          ),
      ),
    );
    const provider = new ApiProvider();
    await expect(provider.getSecSpec()).rejects.toThrow(/MLS_GITHUB_TOKEN is empty on this instance/);
  });

  it("still reports the status when the body is not the typed envelope", async () => {
    // A non-JSON body means the proxy answered, not data-api. Inventing a cause there
    // would be worse than saying nothing, so the status must still get through.
    vi.stubGlobal("fetch", vi.fn(async () => new Response("<html>502 Bad Gateway</html>", { status: 502 })));
    const provider = new ApiProvider();
    await expect(provider.getSecSpec()).rejects.toThrow(/responded 502/);
  });
});

describe("resolveDataMode", () => {
  it("defaults to local in dev, api in production", () => {
    expect(resolveDataMode({ DEV: true })).toBe("local");
    expect(resolveDataMode({ DEV: false })).toBe("api");
  });

  it("honours VITE_DATA_MODE and LOCAL_DATA=1", () => {
    expect(resolveDataMode({ DEV: true, VITE_DATA_MODE: "api" })).toBe("api");
    expect(resolveDataMode({ DEV: false, VITE_DATA_MODE: "local" })).toBe("local");
    expect(resolveDataMode({ DEV: false, VITE_LOCAL_DATA: "1" })).toBe("local");
  });
});

// ---------------------------------------------------------------------------
// F116 - a feed that did not answer must cost its own panels and nothing else,
// and must never be rendered as a number.
//
// Both halves were observed live on 2026-09-01. Three GitHub feeds answered 503
// for want of a token and the Dev tab rendered NOTHING, discarding the
// app-requests payload it was already holding. And with the token wired, the
// Defender feed answered `200 {"value":[]}` and the dashboard displayed
// "Defender secure score 0.0%" - the most alarming figure the panel can show,
// produced by having no figure at all.
// ---------------------------------------------------------------------------
describe("F116: partial data renders, absence is never zero", () => {
  const kpiOf = (spec: ReturnType<typeof buildSecSpec>, label: string) => {
    const kpi = spec.components.find((c) => c.type === "kpiRow");
    if (kpi?.type !== "kpiRow") throw new Error("no kpiRow");
    return kpi.items.find((i) => i.label === label)?.value;
  };

  it("renders an EMPTY Defender response as 'not reported', not 0 - the live case", () => {
    // This exact payload is what the estate returns today.
    const spec = buildSecSpec(
      localFixtures.codeScanningAlerts,
      localFixtures.dependabotAlerts,
      { value: [] },
      { value: [] },
    );
    expect(kpiOf(spec, "Defender secure score")).toBe("not reported");
    expect(kpiOf(spec, "Defender secure score")).not.toBe(0);
    expect(validateSpec(spec).ok).toBe(true);
  });

  it("renders absent GitHub alert feeds as 'not reported', never as zero alerts", () => {
    // "Open code scanning alerts: 0" is the most reassuring thing this dashboard
    // can say. Saying it because the endpoint refused is the failure the
    // absence-vs-denial agreement exists to stop.
    const spec = buildSecSpec(null, null, localFixtures.secureScore, localFixtures.secureScoreControls);
    expect(kpiOf(spec, "Open code scanning alerts")).toBe("not reported");
    expect(kpiOf(spec, "Open dependency alerts")).toBe("not reported");
    expect(kpiOf(spec, "Critical (open)")).toBe("not reported");
    expect(validateSpec(spec).ok).toBe(true);
  });

  it("still reports real alert counts when the feeds DO answer", () => {
    // The guard above must not become a blanket 'not reported'.
    const spec = buildSecSpec(
      localFixtures.codeScanningAlerts,
      localFixtures.dependabotAlerts,
      localFixtures.secureScore,
      localFixtures.secureScoreControls,
    );
    expect(typeof kpiOf(spec, "Open code scanning alerts")).toBe("number");
    expect(typeof kpiOf(spec, "Defender secure score")).toBe("number");
  });

  it("keeps the panels a surviving feed can build when its sibling fails", () => {
    // The Dev tab holds app-requests; losing workflow-runs must not discard it.
    const spec = buildDevSpec(null, localFixtures.appRequests, [
      { feed: "feeds/workflow-runs", reason: "responded 503. MLS_GITHUB_TOKEN is empty on this instance" },
    ]);
    const types = spec.components.map((c) => c.type);
    expect(types).toContain("lineChart"); // built from app-requests, survived
    expect(types).not.toContain("kpiRow"); // needs workflow-runs, correctly absent
    expect(validateSpec(spec).ok).toBe(true);
  });

  it("names the missing feed AND the server's reason in the notice", () => {
    const spec = buildDevSpec(null, localFixtures.appRequests, [
      { feed: "feeds/workflow-runs", reason: "responded 503. MLS_GITHUB_TOKEN is empty on this instance" },
    ]);
    const notice = spec.components.find((c) => c.type === "markdownBlock");
    if (notice?.type !== "markdownBlock") throw new Error("no outage notice");
    expect(notice.markdown).toContain("feeds/workflow-runs");
    // The reason is the actionable half - a notice saying only "unavailable"
    // starts an investigation the server already finished.
    expect(notice.markdown).toContain("MLS_GITHUB_TOKEN is empty on this instance");
  });

  it("emits no notice at all when every feed answered", () => {
    const spec = buildOpsSpec(sampleCostRows, sampleTelemetryRows);
    expect(spec.components.find((c) => c.type === "markdownBlock")).toBeUndefined();
  });

  it("renders absent lakehouse tables as 'not reported' rather than 0 spend", () => {
    const spec = buildOpsSpec(null, null, [
      { feed: "tables/cost_daily", reason: "responded 502." },
      { feed: "tables/telemetry_summary", reason: "responded 502." },
    ]);
    const kpi = spec.components.find((c) => c.type === "kpiRow");
    if (kpi?.type !== "kpiRow") throw new Error("no kpiRow");
    expect(kpi.items.find((i) => i.label === "Program spend (all time)")?.value).toBe("not reported");
    expect(kpi.items.find((i) => i.label === "Flight anomalies")?.value).toBe("not reported");
    expect(validateSpec(spec).ok).toBe(true);
  });
});

describe("F116: ApiProvider degrades per feed", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("renders the Ops tab when only one of the two tables fails", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) =>
        url.includes("telemetry_summary")
          ? new Response(JSON.stringify({ error: { code: "upstream_unavailable", message: "the lakehouse refused" } }), {
              status: 502,
              headers: { "content-type": "application/json" },
            })
          : new Response(JSON.stringify(sampleCostRows), {
              status: 200,
              headers: { "content-type": "application/json" },
            }),
      ),
    );
    const spec = await new ApiProvider().getOpsSpec();
    const notice = spec.components.find((c) => c.type === "markdownBlock");
    if (notice?.type !== "markdownBlock") throw new Error("expected an outage notice");
    expect(notice.markdown).toContain("tables/telemetry_summary");
    expect(notice.markdown).toContain("the lakehouse refused");
    // The cost data survived and is rendered, which is the whole point.
    expect(spec.components.some((c) => c.type === "donutChart" || c.type === "lineChart")).toBe(true);
  });

  it("throws when EVERY feed fails, rather than showing a page of 'not reported'", async () => {
    // A tab holding no data has nothing to be partial about; the app's error
    // panel is a better answer than a grid of empty tiles.
    vi.stubGlobal("fetch", vi.fn(async () => new Response("nope", { status: 502 })));
    await expect(new ApiProvider().getOpsSpec()).rejects.toThrow(/responded 502/);
  });
});
