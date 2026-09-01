import { validateSpec } from "@mls/spec-renderer";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiProvider } from "../src/providers/ApiProvider";
import { LocalJsonProvider } from "../src/providers/LocalJsonProvider";
import { resolveDataMode } from "../src/providers";
import {
  buildOutcomesSpec,
  buildReferenceSpec,
  buildScheduleSpec,
  buildScrubAnalysisSpec,
} from "../src/providers/specs";
import {
  sampleLaunches,
  samplePads,
  sampleScrubs,
  sampleVehicles,
  stubLoader,
} from "./sampleRows";

describe("spec builders produce valid renderer specs", () => {
  it("buildScheduleSpec: dataTable + timeline, valid per validateSpec", () => {
    const spec = buildScheduleSpec(sampleLaunches, sampleVehicles, samplePads);
    const result = validateSpec(spec);
    expect(result.errors).toEqual([]);
    expect(result.ok).toBe(true);
    const types = spec.components.map((c) => c.type);
    expect(types).toContain("dataTable");
    expect(types).toContain("timeline");
  });

  it("buildScheduleSpec: maps vehicle/pad ids to names and keeps null cells", () => {
    const spec = buildScheduleSpec(sampleLaunches, sampleVehicles, samplePads);
    const table = spec.components.find((c) => c.type === "dataTable");
    if (table?.type !== "dataTable") throw new Error("no dataTable");
    const first = table.rows[0];
    expect(first?.vehicle).toBe("Falcon 9 Block 5");
    expect(first?.pad).toBe("SLC-40");
    // LNH-0006 (upcoming, most recent planned date after sort? -> present with nulls)
    const upcoming = table.rows.find((r) => r.mission === "M-LNH-0006");
    expect(upcoming?.actual).toBeNull();
    expect(upcoming?.customer).toBeNull();
  });

  it("buildOutcomesSpec: valid, and Saturday dominates the weekday chart", () => {
    const spec = buildOutcomesSpec(sampleLaunches);
    const result = validateSpec(spec);
    expect(result.errors).toEqual([]);
    expect(result.ok).toBe(true);

    const weekday = spec.components.find(
      (c) => c.type === "barChart" && c.title === "Launches by weekday",
    );
    if (weekday?.type !== "barChart") throw new Error("no weekday barChart");
    expect(weekday.data).toHaveLength(7);
    const max = weekday.data.reduce((a, b) => (b.y > a.y ? b : a));
    expect(max.x).toBe("Saturday");
    // Saturday strictly dominates every other day, mirroring the generator bias.
    for (const point of weekday.data) {
      if (point.x !== "Saturday") expect(point.y).toBeLessThan(max.y);
    }
  });

  it("buildOutcomesSpec: outcome counts and success rate are correct", () => {
    const spec = buildOutcomesSpec(sampleLaunches);
    const outcomes = spec.components.find(
      (c) => c.type === "barChart" && c.title === "Launch outcomes",
    );
    if (outcomes?.type !== "barChart") throw new Error("no outcomes barChart");
    expect(outcomes.data).toEqual([
      { x: "Success", y: 4 },
      { x: "Partial Failure", y: 1 },
      { x: "Failure", y: 1 },
    ]);
    const kpi = spec.components.find((c) => c.type === "kpiRow");
    if (kpi?.type !== "kpiRow") throw new Error("no kpiRow");
    const rate = kpi.items.find((i) => i.label === "Success rate");
    expect(rate?.value).toBeCloseTo(66.7, 1);
  });

  it("buildScrubAnalysisSpec: statCards + monthly lineChart, valid", () => {
    const spec = buildScrubAnalysisSpec(sampleScrubs);
    const result = validateSpec(spec);
    expect(result.errors).toEqual([]);
    expect(result.ok).toBe(true);
    const types = spec.components.map((c) => c.type);
    expect(types.filter((t) => t === "statCard")).toHaveLength(3);
    const line = spec.components.find((c) => c.type === "lineChart");
    if (line?.type !== "lineChart") throw new Error("no lineChart");
    // Month buckets are anchored at noon UTC so the chart's local-time axis
    // labels the right day in every timezone.
    expect(line.data).toEqual([
      { x: "2025-01-01T12:00:00Z", y: 2 },
      { x: "2025-02-01T12:00:00Z", y: 1 },
    ]);
    // Average recycle hours ignores the null row: (29 + 24) / 2.
    const recycle = spec.components.find(
      (c) => c.type === "statCard" && c.title === "Avg recycle time",
    );
    if (recycle?.type !== "statCard") throw new Error("no recycle statCard");
    expect(recycle.value).toBe(26.5);
  });

  it("buildReferenceSpec: two dataTables, valid", () => {
    const spec = buildReferenceSpec(sampleVehicles, samplePads);
    const result = validateSpec(spec);
    expect(result.errors).toEqual([]);
    expect(result.ok).toBe(true);
    const tables = spec.components.filter((c) => c.type === "dataTable");
    expect(tables).toHaveLength(2);
  });
});

describe("LocalJsonProvider (LOCAL_DATA mode)", () => {
  it("builds valid specs for all four views from loader-supplied rows", async () => {
    const provider = new LocalJsonProvider(stubLoader());
    const specs = await Promise.all([
      provider.getScheduleSpec(),
      provider.getOutcomesSpec(),
      provider.getScrubAnalysisSpec(),
      provider.getReferenceSpec(),
    ]);
    for (const spec of specs) {
      expect(validateSpec(spec).ok).toBe(true);
    }
  });

  it("caches table loads across views", async () => {
    const loader = vi.fn(stubLoader());
    const provider = new LocalJsonProvider(loader);
    await provider.getScheduleSpec();
    await provider.getOutcomesSpec(); // launches again — must come from cache
    expect(loader.mock.calls.filter(([t]) => t === "launches")).toHaveLength(1);
  });

  it("rejects non-array table payloads with a clear error", async () => {
    const provider = new LocalJsonProvider(() => Promise.resolve({ not: "rows" }));
    await expect(provider.getOutcomesSpec()).rejects.toThrow(/array of rows/);
  });
});

describe("ApiProvider (L7 wiring contract)", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("fetches {baseUrl}/tables/<table> and builds the same valid specs", async () => {
    const tables: Record<string, unknown> = {
      launches: sampleLaunches,
      vehicles: sampleVehicles,
      pads: samplePads,
    };
    const fetchMock = vi.fn(async (url: string) => {
      const table = /\/api\/tables\/(\w+)$/.exec(url)?.[1] ?? "";
      return new Response(JSON.stringify(tables[table] ?? null), { status: 200 });
    });
    vi.stubGlobal("fetch", fetchMock);

    const provider = new ApiProvider("/api");
    const spec = await provider.getScheduleSpec();
    expect(validateSpec(spec).ok).toBe(true);
    const urls = fetchMock.mock.calls.map(([u]) => u).sort();
    expect(urls).toEqual(["/api/tables/launches", "/api/tables/pads", "/api/tables/vehicles"]);
  });

  it("names the status and the endpoint when the API refuses", async () => {
    // This used to assert the message mentioned LOCAL_DATA, pinning advice that was true
    // before the tenant existed and misleading afterwards: by the time a user sees this,
    // L7 IS deployed, and "run the app in LOCAL_DATA mode" sends them to wait for
    // something that already happened. A test asserting the CURRENT message rather than a
    // USEFUL one turns stale guidance into a contract.
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("not here", { status: 404 })),
    );
    const provider = new ApiProvider();
    await expect(provider.getOutcomesSpec()).rejects.toThrow(/responded 404/);
    await expect(provider.getOutcomesSpec()).rejects.toThrow(/\/api\/tables\//);
  });

  it("explains a 502 as a data-store refusal, not a missing backend", async () => {
    // The failure a user actually hits. 502/503 means data-api is RUNNING and its store
    // refused it - the SQL contained-database user (F109/F112), or Fabric's
    // managed-identity limitation for the three lakehouse tables (F101). Saying "check
    // the backend is deployed" here would send someone to look at a healthy container.
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("bad gateway", { status: 502 })),
    );
    const provider = new ApiProvider();
    await expect(provider.getOutcomesSpec()).rejects.toThrow(/data store refused/);
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
