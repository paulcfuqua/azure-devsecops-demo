import { validateSpec } from "@mls/spec-renderer";
import { afterEach, describe, expect, it, vi } from "vitest";
import { resolveDataMode } from "../src/providers";
import { ApiProvider } from "../src/providers/ApiProvider";
import { localFixtures, LocalProvider } from "../src/providers/LocalProvider";
import { donutWithRemainder, buildDevSpec, buildOpsSpec, buildSecSpec } from "../src/providers/specs";
import { sampleAzureCost, stubLoader } from "./sampleData";

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

  it("counts DISTINCT findings, reports instances separately, and splits the seeds", () => {
    // The live board read "88 open alerts". Those 88 are 30 distinct rules - the
    // container scan raises the same base-image CVE once per image, so three
    // images treble every finding. And one of the two open criticals was a CVE
    // deliberately seeded in apps/vuln-lab for L9's negative test. A fixture
    // counted as posture, and real work overstated threefold (F154).
    const kpi = spec.components.find((c) => c.type === "kpiRow");
    if (kpi?.type !== "kpiRow") throw new Error("no kpiRow");
    expect(kpi.items.find((i) => i.label === "Open findings (distinct)")?.value).toBe(10);
    expect(kpi.items.find((i) => i.label === "Alert instances")?.value).toBe(10);
    expect(kpi.items.find((i) => i.label === "Seeded for the demo")?.value).toBe(1);
    expect(kpi.items.find((i) => i.label === "Critical (open)")?.value).toBe(2);
    expect(kpi.items.find((i) => i.label === "Defender secure score")?.value).toBe(71.6);
  });

  it("excludes seeded alerts from the severity counts, and says how many it excluded", () => {
    // THE ASSERTION THAT MATTERS. The fixture's only HIGH dependency alert is the
    // seeded one, so High must fall from 2 to 1. If this ever reads 2 again, the
    // board is reporting a deliberate fixture as exposure.
    const chart = spec.components.find(
      (c) => c.type === "barChart" && c.title === "Open findings by severity",
    );
    if (chart?.type !== "barChart") throw new Error("no severity barChart");
    expect(chart.data.find((p) => p.x === "High")?.y).toBe(1);
    expect(chart.description).toContain("1 deliberately seeded");
  });

  it("colours severity semantically - High is never green", () => {
    // Without an explicit colour the chart library assigns from a categorical
    // palette by index, and the live board rendered Critical blue, HIGH GREEN,
    // Medium and Low pink. Green is the one colour that reads as "fine", on the
    // second-most serious bar on the page.
    const chart = spec.components.find(
      (c) => c.type === "barChart" && c.title === "Open findings by severity",
    );
    if (chart?.type !== "barChart") throw new Error("no severity barChart");
    for (const point of chart.data) {
      expect(point.color, `${String(point.x)} has no explicit colour`).toMatch(/^#[0-9a-f]{6}$/i);
    }
    // Ranked, so a reader can order them without reading the labels.
    const colorOf = (x: string): string | undefined => chart.data.find((p) => p.x === x)?.color;
    expect(colorOf("Critical")).not.toBe(colorOf("High"));
    expect(colorOf("High")).not.toBe(colorOf("Medium"));
    expect(colorOf("Medium")).not.toBe(colorOf("Low"));
  });

  it("normalizes Dependabot 'moderate' onto the medium severity bucket", () => {
    const bySeverity = spec.components.find(
      (c) => c.type === "barChart" && c.title === "Open findings by severity",
    );
    if (bySeverity?.type !== "barChart") throw new Error("no severity barChart");
    expect(bySeverity.data.map((p) => ({ x: p.x, y: p.y }))).toEqual([
      { x: "Critical", y: 2 },
      { x: "High", y: 1 },
      { x: "Medium", y: 4 },
      { x: "Low", y: 3 },
    ]);
    // 10 distinct findings once the seeded alert is split out; the buckets still
    // sum to the whole, so nothing is lost between the KPI and the chart.
    expect(bySeverity.data.reduce((sum, p) => sum + p.y, 0)).toBe(10);
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

describe("buildOpsSpec (Ops pillar) - what the ESTATE costs to run", () => {
  const spec = buildOpsSpec(sampleAzureCost);

  it("produces a valid renderer spec", () => {
    const result = validateSpec(spec);
    expect(result.errors).toEqual([]);
    expect(result.ok).toBe(true);
  });

  it("reports the real total, its currency and its window", () => {
    const kpi = spec.components.find((c) => c.type === "kpiRow");
    if (kpi?.type !== "kpiRow") throw new Error("no kpiRow");
    const total = kpi.items.find((i) => i.label === "Total run cost");
    expect(total?.value).toBe(10); // 6 + 3 + 1
    expect(total?.unit).toBe("USD");
    // The window belongs on the tab: "$10" means nothing without "month to date".
    expect(kpi.description).toContain("MonthToDate");
  });

  it("names the largest line item rather than making the reader find it", () => {
    const kpi = spec.components.find((c) => c.type === "kpiRow");
    if (kpi?.type !== "kpiRow") throw new Error("no kpiRow");
    const largest = kpi.items.find((i) => i.label.startsWith("Largest"));
    expect(largest?.label).toContain("Azure Container Apps");
    expect(largest?.value).toBe(6);
  });

  it("splits spend by Azure service, highest first - not by fictional cost centre", () => {
    const donut = spec.components.find((c) => c.type === "donutChart");
    if (donut?.type !== "donutChart") throw new Error("no donutChart");
    expect(donut.data).toEqual([
      { label: "Azure Container Apps", value: 6 },
      { label: "Azure SQL Database", value: 3 },
      { label: "Log Analytics", value: 1 },
    ]);
    // The whole point of F117: no launch-programme cost centre may appear here.
    const labels = donut.data.map((d) => d.label).join(" ");
    expect(labels).not.toMatch(/Propulsion|Avionics|Range Operations/);
  });

  it("splits spend by resource group, which is what teardown deletes", () => {
    const bar = spec.components.find(
      (c) => c.type === "barChart" && c.title === "Cost by resource group",
    );
    if (bar?.type !== "barChart") throw new Error("no resource-group barChart");
    expect(bar.data).toEqual([
      { x: "mls-rg-apps", y: 6 },
      { x: "mls-rg-data", y: 3 },
      { x: "mls-rg-platform", y: 1 },
    ]);
  });

  it("charts daily cost anchored at noon UTC so the label does not slide a day", () => {
    const line = spec.components.find((c) => c.type === "lineChart");
    if (line?.type !== "lineChart") throw new Error("no lineChart");
    expect(line.data).toEqual([
      { x: "2026-08-30T12:00:00Z", y: 4 },
      { x: "2026-08-31T12:00:00Z", y: 6 },
    ]);
  });

  it("says so when the figures are RETAINED rather than current", () => {
    // data-api caches because Cost Management throttles hard, and may serve a
    // cached answer when the upstream refuses. A retained figure presented as a
    // current one is the same defect as an empty list presented as a zero.
    const stale = buildOpsSpec({ ...sampleAzureCost, stale: true });
    const kpi = stale.components.find((c) => c.type === "kpiRow");
    if (kpi?.type !== "kpiRow") throw new Error("no kpiRow");
    expect(kpi.description).toContain("RETAINED");
    // ...and does NOT say so when they are fresh.
    const fresh = spec.components.find((c) => c.type === "kpiRow");
    if (fresh?.type !== "kpiRow") throw new Error("no kpiRow");
    expect(fresh.description).not.toContain("RETAINED");
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
    // Ops is fixture-backed too since F117: it reads the azure-cost feed, not
    // the generator's cost_daily / telemetry_summary tables.
    await provider.getOpsSpec();
    expect(loader).not.toHaveBeenCalled();
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
      "feeds/azure-cost": sampleAzureCost,
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
      "/api/feeds/azure-cost",
      "/api/feeds/code-scanning-alerts",
      "/api/feeds/dependabot-alerts",
      "/api/feeds/secure-score",
      "/api/feeds/secure-score-controls",
      "/api/feeds/workflow-runs",
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
    expect(kpiOf(spec, "Open findings (distinct)")).toBe("not reported");
    expect(kpiOf(spec, "Alert instances")).toBe("not reported");
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
    expect(typeof kpiOf(spec, "Open findings (distinct)")).toBe("number");
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
    const spec = buildOpsSpec(sampleAzureCost);
    expect(spec.components.find((c) => c.type === "markdownBlock")).toBeUndefined();
  });

  it("renders an absent cost feed as 'not reported' rather than a run cost of 0", () => {
    // "Total run cost: $0" is a claim a reader would act on. It must never be
    // produced by having no figure at all.
    const spec = buildOpsSpec(null, [
      { feed: "feeds/azure-cost", reason: "responded 502." },
    ]);
    const kpi = spec.components.find((c) => c.type === "kpiRow");
    if (kpi?.type !== "kpiRow") throw new Error("no kpiRow");
    expect(kpi.items.find((i) => i.label === "Total run cost")?.value).toBe("not reported");
    expect(validateSpec(spec).ok).toBe(true);
  });
});

describe("F116: ApiProvider degrades per feed", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("renders the Dev tab when only one of its two feeds fails", async () => {
    // The Ops tab reads a single feed since F117, so the multi-feed degradation
    // case lives on Dev, which fetches workflow-runs AND app-requests. This is
    // the exact live shape: the GitHub feed 503s and app-requests answers.
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) =>
        url.includes("workflow-runs")
          ? new Response(
              JSON.stringify({
                error: {
                  code: "backend_not_configured",
                  message: "MLS_GITHUB_TOKEN is empty on this instance",
                },
              }),
              { status: 503, headers: { "content-type": "application/json" } },
            )
          : new Response(JSON.stringify(localFixtures.appRequests), {
              status: 200,
              headers: { "content-type": "application/json" },
            }),
      ),
    );
    const spec = await new ApiProvider().getDevSpec();
    const notice = spec.components.find((c) => c.type === "markdownBlock");
    if (notice?.type !== "markdownBlock") throw new Error("expected an outage notice");
    expect(notice.markdown).toContain("feeds/workflow-runs");
    expect(notice.markdown).toContain("MLS_GITHUB_TOKEN is empty on this instance");
    // The app-requests data survived and is rendered, which is the whole point.
    expect(spec.components.some((c) => c.type === "lineChart")).toBe(true);
  });

  it("throws when EVERY feed fails, rather than showing a page of 'not reported'", async () => {
    // A tab holding no data has nothing to be partial about; the app's error
    // panel is a better answer than a grid of empty tiles.
    vi.stubGlobal("fetch", vi.fn(async () => new Response("nope", { status: 502 })));
    await expect(new ApiProvider().getDevSpec()).rejects.toThrow(/responded 502/);
  });
});


describe("donutWithRemainder (F156)", () => {
  const money = (x: number): number => Math.round(x * 100) / 100;
  const services = Array.from({ length: 12 }, (_, i) => ({
    name: `svc-${i}`,
    cost: 12 - i,
  }));

  it("keeps every dollar, so the ring reconciles with the total beside it", () => {
    // The defect: the donut charted the top 8 and DROPPED the tail, so the ring
    // totalled less than the KPI directly above it. A cost chart that does not
    // add up is worse than no chart.
    const total = services.reduce((sum, s) => sum + s.cost, 0);
    const slices = donutWithRemainder(services, 8, money);
    expect(slices.reduce((sum, s) => sum + s.value, 0)).toBe(total);
  });

  it("says how many services it grouped rather than hiding them", () => {
    const slices = donutWithRemainder(services, 8, money);
    expect(slices).toHaveLength(9);
    expect(slices[8]?.label).toBe("Other (4 services)");
  });

  it("adds no remainder slice when nothing was dropped", () => {
    const few = services.slice(0, 3);
    const slices = donutWithRemainder(few, 8, money);
    expect(slices).toHaveLength(3);
    expect(slices.some((s) => s.label.startsWith("Other"))).toBe(false);
  });

  it("keeps a cent-sized service visible in the total - a newly enabled Defender plan", () => {
    // The case that prompted this: five Defender plans were just enabled. Each
    // bills a trivial amount next to the database, so each would have fallen off
    // the top 8 and out of the ring entirely.
    const withTiny = [...services, { name: "Microsoft Defender for Cloud", cost: 0.02 }];
    const total = withTiny.reduce((sum, s) => sum + s.cost, 0);
    const slices = donutWithRemainder(withTiny, 8, money);
    expect(slices.reduce((sum, s) => sum + s.value, 0)).toBeCloseTo(total, 2);
  });
});
