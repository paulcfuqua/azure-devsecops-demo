/**
 * The CLOUD path, fully mocked.
 *
 * There is no tenant, and Phase Q's rule is zero cloud calls — so every socket
 * here is a test double: an injected `mssql` driver, an injected `fetch`, an
 * injected token provider. What is being tested is the part that will be wrong
 * on tenant day if it is wrong now: the statement that reaches TDS, the URL and
 * headers that reach each upstream, and — most of all — that a TDS row
 * (`Date`, `bit`, decimal-as-string) and a live API payload land in exactly the
 * shape the frontends already parse.
 *
 * A guard at the end of the file asserts that the global `fetch` was never
 * called during any of it.
 */
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import {
  APP_REQUESTS_KQL,
  CloudFeedsBackend,
  CloudTablesBackend,
  MAX_FEED_ITEMS,
  projectCodeScanningAlerts,
  projectDependabotAlerts,
  projectLogAnalytics,
  projectSecureScore,
  projectSecureScoreControls,
  projectWorkflowRuns,
} from "../src/backends/cloud.js";
import { AzureTokenProvider, SCOPE_SQL, type TokenProvider } from "../src/backends/azureAuth.js";
import { fetchJson, type FetchLike } from "../src/backends/http.js";
import { MssqlClient, type SqlClient } from "../src/backends/sql.js";
import { createBackends } from "../src/backends/index.js";
import { loadConfig, type CloudConfig } from "../src/config.js";
import { TABLE_FIELDS } from "../src/contract/allowlist.js";
import { ApiError } from "../src/errors.js";

/* ------------------------------------------------------------------ */
/* no-network guard                                                    */
/* ------------------------------------------------------------------ */

const realFetch = globalThis.fetch;
const fetchSpy = vi.fn(() => {
  throw new Error("a test made a live network call");
});

beforeAll(() => {
  globalThis.fetch = fetchSpy as unknown as typeof fetch;
});

afterAll(() => {
  globalThis.fetch = realFetch;
});

/* ------------------------------------------------------------------ */
/* doubles                                                             */
/* ------------------------------------------------------------------ */

const CLOUD_ENV = {
  MLS_DATA_BACKENDS: "cloud",
  MLS_SQL_SERVER: "mls-ops-demo-sql.database.windows.net",
  MLS_SQL_DATABASE: "mls_ops",
  MLS_FABRIC_SQL_ENDPOINT: "abc123.datawarehouse.fabric.microsoft.com",
  MLS_FABRIC_DATABASE: "mls_operations",
  MLS_GITHUB_REPO: "paulcfuqua/azure-devsecops",
  MLS_GITHUB_TOKEN: "ghp_testtokentesttokentesttoken0123",
  MLS_DEFENDER_SUBSCRIPTION_ID: "11111111-2222-3333-4444-555555555555",
  MLS_LOG_ANALYTICS_WORKSPACE_ID: "66666666-7777-8888-9999-000000000000",
};

function cloudConfig(overrides: Record<string, string> = {}): CloudConfig {
  const config = loadConfig({ ...CLOUD_ENV, ...overrides } as NodeJS.ProcessEnv);
  return config.cloud as CloudConfig;
}

const stubTokens: TokenProvider = {
  getToken: async (scope: string) => `token-for-${scope}`,
};

interface RecordedCall {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: string | undefined;
}

function recordingFetch(
  responder: (url: string) => { status?: number; body: unknown; headers?: Record<string, string> },
): { impl: FetchLike; calls: RecordedCall[] } {
  const calls: RecordedCall[] = [];
  const impl: FetchLike = async (url, init) => {
    calls.push({
      url,
      method: init?.method ?? "GET",
      headers: init?.headers ?? {},
      body: init?.body,
    });
    const { status = 200, body, headers = {} } = responder(url);
    return {
      ok: status >= 200 && status < 300,
      status,
      headers: { get: (name: string) => headers[name.toLowerCase()] ?? null },
      text: async () => JSON.stringify(body),
    };
  };
  return { impl, calls };
}

/* ------------------------------------------------------------------ */
/* token provider                                                      */
/* ------------------------------------------------------------------ */

describe("AzureTokenProvider", () => {
  it("caches a token until shortly before it expires", async () => {
    const getToken = vi.fn(async () => ({
      token: "abc",
      expiresOnTimestamp: Date.now() + 60 * 60 * 1000,
    }));
    const provider = new AzureTokenProvider({ getToken });

    expect(await provider.getToken(SCOPE_SQL)).toBe("abc");
    expect(await provider.getToken(SCOPE_SQL)).toBe("abc");
    expect(getToken).toHaveBeenCalledTimes(1);
  });

  it("re-mints a token that is inside the refresh skew", async () => {
    const getToken = vi.fn(async () => ({
      token: "abc",
      // Expires in one minute — inside the five-minute skew, so never cached.
      expiresOnTimestamp: Date.now() + 60 * 1000,
    }));
    const provider = new AzureTokenProvider({ getToken });
    await provider.getToken(SCOPE_SQL);
    await provider.getToken(SCOPE_SQL);
    expect(getToken).toHaveBeenCalledTimes(2);
  });

  it("keeps one token per scope", async () => {
    const getToken = vi.fn(async (scope: string) => ({
      token: `t:${scope}`,
      expiresOnTimestamp: Date.now() + 3_600_000,
    }));
    const provider = new AzureTokenProvider({
      getToken: getToken as unknown as TokenProvider["getToken"],
    } as never);
    expect(await provider.getToken("scope-a")).toBe("t:scope-a");
    expect(await provider.getToken("scope-b")).toBe("t:scope-b");
    expect(getToken).toHaveBeenCalledTimes(2);
  });

  it("collapses a concurrent stampede into one token request", async () => {
    let resolve: ((value: { token: string; expiresOnTimestamp: number }) => void) | undefined;
    const getToken = vi.fn(
      () =>
        new Promise<{ token: string; expiresOnTimestamp: number }>((r) => {
          resolve = r;
        }),
    );
    const provider = new AzureTokenProvider({ getToken });

    const all = Promise.all([
      provider.getToken(SCOPE_SQL),
      provider.getToken(SCOPE_SQL),
      provider.getToken(SCOPE_SQL),
    ]);
    resolve?.({ token: "one", expiresOnTimestamp: Date.now() + 3_600_000 });
    expect(await all).toEqual(["one", "one", "one"]);
    expect(getToken).toHaveBeenCalledTimes(1);
  });

  it("turns a credential failure into a typed 502 without the SDK message", async () => {
    const provider = new AzureTokenProvider({
      getToken: () => Promise.reject(new Error("IMDS said: Bearer eyJhbGciOiJIUzI1NiJ9xxxxxxxxxxxx")),
    });
    const error = await provider.getToken(SCOPE_SQL).catch((err: unknown) => err as ApiError);
    expect(error).toBeInstanceOf(ApiError);
    expect((error as ApiError).status).toBe(502);
    expect((error as ApiError).message).not.toContain("eyJ");
  });

  it("treats a null token result as an upstream failure", async () => {
    const provider = new AzureTokenProvider({ getToken: async () => null });
    await expect(provider.getToken(SCOPE_SQL)).rejects.toMatchObject({
      code: "upstream_unavailable",
    });
  });
});

/* ------------------------------------------------------------------ */
/* SQL client                                                          */
/* ------------------------------------------------------------------ */

interface FakePool {
  config: Record<string, unknown>;
  statements: string[];
  inputs: Array<[string, unknown]>;
  closed: number;
}

function fakeDriver(
  recordset: Record<string, unknown>[],
  options: { failQuery?: boolean } = {},
): { load: () => Promise<never>; pools: FakePool[] } {
  const pools: FakePool[] = [];
  const load = async () => {
    return {
      ConnectionPool: class {
        readonly state: FakePool;
        constructor(config: Record<string, unknown>) {
          this.state = { config, statements: [], inputs: [], closed: 0 };
          pools.push(this.state);
        }
        async connect() {
          return this;
        }
        async close() {
          this.state.closed += 1;
        }
        on() {
          return this;
        }
        request() {
          const state = this.state;
          const request = {
            input(name: string, value: unknown) {
              state.inputs.push([name, value]);
              return request;
            },
            async query(statement: string) {
              state.statements.push(statement);
              if (options.failQuery) throw new Error("TDS: connection reset");
              return { recordset };
            },
          };
          return request;
        }
      },
    } as never;
  };
  return { load, pools };
}

const SQL_ENDPOINT = {
  store: "sql" as const,
  server: "mls-ops-demo-sql.database.windows.net",
  database: "mls_ops",
  timeoutMs: 20_000,
};

describe("MssqlClient", () => {
  it("connects with an Entra access token and no password", async () => {
    const driver = fakeDriver([]);
    const client = new MssqlClient(SQL_ENDPOINT, stubTokens, driver.load);
    await client.select("pads", 10);

    const config = driver.pools[0]?.config as Record<string, unknown>;
    expect(config.server).toBe(SQL_ENDPOINT.server);
    expect(config.database).toBe("mls_ops");
    expect(config.authentication).toEqual({
      type: "azure-active-directory-access-token",
      options: { token: `token-for-${SCOPE_SQL}` },
    });
    // Nothing resembling a stored credential in the connection configuration.
    const serialised = JSON.stringify(config);
    expect(serialised).not.toMatch(/"user"|"password"|connectionString/i);
    expect((config.options as Record<string, unknown>).encrypt).toBe(true);
    expect((config.options as Record<string, unknown>).trustServerCertificate).toBe(false);
  });

  it("sends the fixed projection with the cap as a parameter", async () => {
    const driver = fakeDriver([]);
    const client = new MssqlClient(SQL_ENDPOINT, stubTokens, driver.load);
    await client.select("launches", 250);

    const pool = driver.pools[0] as FakePool;
    expect(pool.inputs).toEqual([["limit", 250]]);
    const statement = pool.statements[0] as string;
    expect(statement).toContain("SELECT TOP (@limit)");
    expect(statement).toContain("FROM [dbo].[launches]");
    expect(statement).not.toContain("250");
  });

  it("reuses one pool across queries", async () => {
    const driver = fakeDriver([]);
    const client = new MssqlClient(SQL_ENDPOINT, stubTokens, driver.load);
    await client.select("pads", 10);
    await client.select("vehicles", 10);
    expect(driver.pools).toHaveLength(1);
  });

  it("turns a query failure into a typed 502 and drops the pool", async () => {
    const driver = fakeDriver([], { failQuery: true });
    const client = new MssqlClient(SQL_ENDPOINT, stubTokens, driver.load);

    await expect(client.select("pads", 10)).rejects.toMatchObject({
      code: "upstream_unavailable",
      status: 502,
    });
    // Next call must not inherit the poisoned pool.
    await client.select("pads", 10).catch(() => undefined);
    expect(driver.pools.length).toBeGreaterThan(1);
  });

  it("names the lakehouse rather than Azure SQL in a lakehouse failure", async () => {
    const driver = fakeDriver([], { failQuery: true });
    const client = new MssqlClient(
      { ...SQL_ENDPOINT, store: "lakehouse", server: "abc.fabric.microsoft.com" },
      stubTokens,
      driver.load,
    );
    await expect(client.select("cost_daily", 10)).rejects.toThrow(/Fabric lakehouse/);
  });
});

/* ------------------------------------------------------------------ */
/* cloud tables                                                        */
/* ------------------------------------------------------------------ */

/** One `launches` row as a TDS driver would hand it back. */
const TDS_LAUNCH_ROW = {
  launch_id: "LNH-0001",
  mission_name: "TRS-001",
  vehicle_id: "VEH-012",
  pad_id: "PAD-10",
  customer: "Tidewater Remote Sensing",
  orbit: "SSO",
  planned_date: new Date("2022-07-25T00:00:00.000Z"),
  actual_date: new Date("2022-07-30T00:00:00.000Z"),
  outcome: "success",
  payload_mass_kg: "1138.3", // decimal often arrives as a string
  weather_delay_min: 180,
  scrub_count: 1,
  booster_recovery: "expended",
  insurance_value_musd: null,
};

const TDS_VEHICLE_ROW = {
  vehicle_id: "VEH-001",
  name: "Falcon 9 Block 5",
  vehicle_class: "medium",
  fleet_group: "MLS Medium Fleet",
  stages: 2,
  reusable: 1, // bit
  leo_capacity_kg: 22_800,
  gto_capacity_kg: 8_300,
  height_m: 70,
  first_flight_year: 2018,
  last_flight_year: null,
  status: "active",
};

function fakeSqlClient(rows: Record<string, unknown>[]): SqlClient & { limits: number[] } {
  const limits: number[] = [];
  return {
    limits,
    select: async (_table, limit) => {
      limits.push(limit);
      return rows;
    },
    close: async () => undefined,
  };
}

describe("CloudTablesBackend", () => {
  it("normalises a TDS row into exactly the contract's JSON", async () => {
    const sql = fakeSqlClient([TDS_LAUNCH_ROW]);
    const backend = new CloudTablesBackend({ sql, lakehouse: fakeSqlClient([]) });

    const result = await backend.getTable("launches", 100);
    expect(result.rows).toEqual([
      {
        launch_id: "LNH-0001",
        mission_name: "TRS-001",
        vehicle_id: "VEH-012",
        pad_id: "PAD-10",
        customer: "Tidewater Remote Sensing",
        orbit: "SSO",
        // Date -> ISO calendar date, matching the generator's JSON exactly.
        planned_date: "2022-07-25",
        actual_date: "2022-07-30",
        outcome: "success",
        // decimal-as-string -> number
        payload_mass_kg: 1138.3,
        weather_delay_min: 180,
        scrub_count: 1,
        booster_recovery: "expended",
        insurance_value_musd: null,
      },
    ]);
  });

  it("normalises a bit column to a real boolean", async () => {
    const backend = new CloudTablesBackend({
      sql: fakeSqlClient([TDS_VEHICLE_ROW]),
      lakehouse: fakeSqlClient([]),
    });
    const result = await backend.getTable("vehicles", 100);
    expect((result.rows[0] as { reusable: unknown }).reusable).toBe(true);
  });

  it("drops a column the contract does not declare", async () => {
    const backend = new CloudTablesBackend({
      sql: fakeSqlClient([{ ...TDS_LAUNCH_ROW, secret_internal_note: "do not ship" }]),
      lakehouse: fakeSqlClient([]),
    });
    const result = await backend.getTable("launches", 100);
    expect(Object.keys(result.rows[0] as object)).toEqual(
      TABLE_FIELDS.launches.map((field) => field.name),
    );
  });

  it("rejects a row missing a non-nullable column rather than serving undefined", async () => {
    const broken = { ...TDS_LAUNCH_ROW } as Record<string, unknown>;
    delete broken.outcome;
    const backend = new CloudTablesBackend({
      sql: fakeSqlClient([broken]),
      lakehouse: fakeSqlClient([]),
    });
    await expect(backend.getTable("launches", 100)).rejects.toThrow(/launches\.outcome/);
  });

  it("asks for one row beyond the cap so truncation is measured, not guessed", async () => {
    const rows = Array.from({ length: 4 }, (_, index) => ({
      ...TDS_LAUNCH_ROW,
      launch_id: `LNH-000${index}`,
    }));
    const sql = fakeSqlClient(rows);
    const backend = new CloudTablesBackend({ sql, lakehouse: fakeSqlClient([]) });

    const result = await backend.getTable("launches", 3);
    expect(sql.limits).toEqual([4]);
    expect(result.rows).toHaveLength(3);
    expect(result.truncated).toBe(true);
  });

  it("routes analytical tables to the lakehouse client and operational ones to SQL", async () => {
    const sql = fakeSqlClient([TDS_LAUNCH_ROW]);
    const lakehouse = fakeSqlClient([
      {
        cost_id: "CST-00001",
        date: new Date("2024-01-01T00:00:00.000Z"),
        cost_center: "Propulsion",
        amount_usd: 9435.57,
        budget_usd: 8610,
        currency: "USD",
      },
    ]);
    const backend = new CloudTablesBackend({ sql, lakehouse });

    await backend.getTable("launches", 10);
    expect(sql.limits).toHaveLength(1);
    expect(lakehouse.limits).toHaveLength(0);

    const cost = await backend.getTable("cost_daily", 10);
    expect(lakehouse.limits).toHaveLength(1);
    expect(cost.rows[0]).toEqual({
      cost_id: "CST-00001",
      date: "2024-01-01",
      cost_center: "Propulsion",
      amount_usd: 9435.57,
      budget_usd: 8610,
      currency: "USD",
    });
  });
});

/* ------------------------------------------------------------------ */
/* cloud feeds                                                         */
/* ------------------------------------------------------------------ */

const GITHUB_RUNS_PAYLOAD = {
  total_count: 2,
  workflow_runs: [
    {
      id: 17_000_001,
      name: "app-data-api-ci",
      head_branch: "main",
      event: "push",
      status: "completed",
      conclusion: "success",
      run_started_at: "2026-08-21T09:00:00Z",
      updated_at: "2026-08-21T09:06:12Z",
      // The fields a proxy must not forward:
      actor: { login: "a-real-person", avatar_url: "https://…", id: 42 },
      triggering_actor: { login: "a-real-person" },
      head_commit: { author: { email: "someone@example.com" } },
    },
    {
      id: 17_000_002,
      name: "codeql",
      head_branch: "main",
      event: "schedule",
      status: "in_progress",
      conclusion: null,
      run_started_at: "2026-08-21T10:00:00Z",
      updated_at: "2026-08-21T10:01:00Z",
    },
  ],
};

describe("CloudFeedsBackend", () => {
  it("fetches workflow runs from the configured repo and strips actor identity", async () => {
    const { impl, calls } = recordingFetch(() => ({ body: GITHUB_RUNS_PAYLOAD }));
    const backend = new CloudFeedsBackend({
      config: cloudConfig(),
      tokens: stubTokens,
      fetchImpl: impl,
    });

    const feed = await backend.getFeed("workflow-runs");
    expect(calls[0]?.url).toBe(
      "https://api.github.com/repos/paulcfuqua/azure-devsecops/actions/runs?per_page=100",
    );
    expect(calls[0]?.headers.authorization).toBe(`Bearer ${CLOUD_ENV.MLS_GITHUB_TOKEN}`);
    expect(calls[0]?.headers["x-github-api-version"]).toBe("2022-11-28");

    // Hard rule 4: no real person's identity reaches a browser.
    const serialised = JSON.stringify(feed);
    expect(serialised).not.toContain("a-real-person");
    expect(serialised).not.toContain("someone@example.com");
    expect(serialised).not.toContain("avatar_url");

    expect(feed).toEqual({
      total_count: 2,
      workflow_runs: [
        {
          id: 17_000_001,
          name: "app-data-api-ci",
          head_branch: "main",
          event: "push",
          status: "completed",
          conclusion: "success",
          run_started_at: "2026-08-21T09:00:00Z",
          updated_at: "2026-08-21T09:06:12Z",
        },
        {
          id: 17_000_002,
          name: "codeql",
          head_branch: "main",
          event: "schedule",
          status: "in_progress",
          conclusion: null,
          run_started_at: "2026-08-21T10:00:00Z",
          updated_at: "2026-08-21T10:01:00Z",
        },
      ],
    });
  });

  it("requests open alerts from both GitHub security endpoints", async () => {
    const { impl, calls } = recordingFetch(() => ({ body: [] }));
    const backend = new CloudFeedsBackend({
      config: cloudConfig(),
      tokens: stubTokens,
      fetchImpl: impl,
    });
    await backend.getFeed("code-scanning-alerts");
    await backend.getFeed("dependabot-alerts");
    expect(calls.map((call) => call.url)).toEqual([
      "https://api.github.com/repos/paulcfuqua/azure-devsecops/code-scanning/alerts?state=open&per_page=100",
      "https://api.github.com/repos/paulcfuqua/azure-devsecops/dependabot/alerts?state=open&per_page=100",
    ]);
  });

  it("fails closed, and makes no request, when no GitHub token is injected", async () => {
    const { impl, calls } = recordingFetch(() => ({ body: [] }));
    const backend = new CloudFeedsBackend({
      config: cloudConfig({ MLS_GITHUB_TOKEN: "" }),
      tokens: stubTokens,
      fetchImpl: impl,
    });
    await expect(backend.getFeed("workflow-runs")).rejects.toMatchObject({
      code: "backend_not_configured",
      status: 503,
    });
    expect(calls).toHaveLength(0);
  });

  it("reads the Defender secure score and its controls from ARM", async () => {
    const { impl, calls } = recordingFetch((url) => ({
      body: url.includes("secureScoreControls")
        ? {
            value: [
              {
                name: "control-1",
                type: "Microsoft.Security/secureScores/secureScoreControls",
                properties: {
                  displayName: "Enable MFA",
                  healthyResourceCount: 4,
                  unhealthyResourceCount: 1,
                  score: { max: 10, current: 8, percentage: 0.8 },
                },
              },
            ],
          }
        : {
            value: [
              {
                id: "/subscriptions/x/providers/Microsoft.Security/secureScores/ascScore",
                name: "ascScore",
                type: "Microsoft.Security/secureScores",
                properties: {
                  displayName: "ASC score",
                  score: { max: 58, current: 41, percentage: 0.7069 },
                },
              },
            ],
          },
    }));
    const backend = new CloudFeedsBackend({
      config: cloudConfig(),
      tokens: stubTokens,
      fetchImpl: impl,
    });

    const score = await backend.getFeed("secure-score");
    const controls = await backend.getFeed("secure-score-controls");

    expect(calls[0]?.url).toBe(
      `https://management.azure.com/subscriptions/${CLOUD_ENV.MLS_DEFENDER_SUBSCRIPTION_ID}` +
        "/providers/Microsoft.Security/secureScores?api-version=2020-01-01",
    );
    expect(calls[0]?.headers.authorization).toBe(
      "Bearer token-for-https://management.azure.com/.default",
    );
    expect(calls[1]?.url).toContain("/secureScores/ascScore/secureScoreControls");
    expect((score as { value: unknown[] }).value).toHaveLength(1);
    expect((controls as { value: unknown[] }).value).toHaveLength(1);
  });

  it("queries Log Analytics with the fixed KQL and the configured timespan", async () => {
    const { impl, calls } = recordingFetch(() => ({
      body: {
        tables: [
          {
            name: "PrimaryResult",
            columns: [
              { name: "TimeGenerated", type: "datetime" },
              { name: "AppRoleName", type: "string" },
              { name: "RequestCount", type: "long" },
              { name: "FailedCount", type: "long" },
            ],
            rows: [["2026-08-21T00:00:00Z", "launch-ops", 1200, 3]],
          },
        ],
      },
    }));
    const backend = new CloudFeedsBackend({
      config: cloudConfig(),
      tokens: stubTokens,
      fetchImpl: impl,
    });

    const result = await backend.getFeed("app-requests");
    const call = calls[0] as RecordedCall;
    expect(call.method).toBe("POST");
    expect(call.url).toBe(
      `https://api.loganalytics.io/v1/workspaces/${CLOUD_ENV.MLS_LOG_ANALYTICS_WORKSPACE_ID}/query`,
    );
    expect(call.headers.authorization).toBe(
      "Bearer token-for-https://api.loganalytics.io/.default",
    );
    const body = JSON.parse(call.body as string) as { query: string; timespan: string };
    expect(body.query).toBe(APP_REQUESTS_KQL);
    expect(body.timespan).toBe("P14D");
    // The Dev tab's three required columns survive the projection.
    expect((result as { tables: Array<{ name: string }> }).tables[0]?.name).toBe(
      "PrimaryResult",
    );
  });

  it("maps an upstream 500 to a typed 502 that names the upstream only", async () => {
    const { impl } = recordingFetch(() => ({
      status: 500,
      body: { error: { message: `failing request to ${CLOUD_ENV.MLS_GITHUB_TOKEN}` } },
    }));
    const backend = new CloudFeedsBackend({
      config: cloudConfig(),
      tokens: stubTokens,
      fetchImpl: impl,
    });
    const error = (await backend
      .getFeed("workflow-runs")
      .catch((err: unknown) => err)) as ApiError;
    expect(error.status).toBe(502);
    expect(error.message).toContain("GitHub");
    expect(error.message).not.toContain(CLOUD_ENV.MLS_GITHUB_TOKEN);
  });
});

/* ------------------------------------------------------------------ */
/* http helper                                                         */
/* ------------------------------------------------------------------ */

describe("fetchJson", () => {
  it("retries a 429 and honours Retry-After", async () => {
    let attempt = 0;
    const sleeps: number[] = [];
    const impl: FetchLike = async () => {
      attempt += 1;
      if (attempt === 1) {
        return {
          ok: false,
          status: 429,
          headers: { get: (name: string) => (name === "retry-after" ? "2" : null) },
          text: async () => "rate limited",
        };
      }
      return {
        ok: true,
        status: 200,
        headers: { get: () => null },
        text: async () => JSON.stringify({ ok: true }),
      };
    };

    const result = await fetchJson<{ ok: boolean }>({
      url: "https://example.invalid/x",
      timeoutMs: 1_000,
      label: "GitHub",
      fetchImpl: impl,
      sleep: async (ms) => {
        sleeps.push(ms);
      },
    });
    expect(result).toEqual({ ok: true });
    expect(sleeps).toEqual([2_000]);
  });

  it("caps a hostile Retry-After rather than sleeping for an hour", async () => {
    const sleeps: number[] = [];
    let attempt = 0;
    const impl: FetchLike = async () => {
      attempt += 1;
      return attempt === 1
        ? {
            ok: false,
            status: 503,
            headers: { get: () => "3600" },
            text: async () => "",
          }
        : { ok: true, status: 200, headers: { get: () => null }, text: async () => "{}" };
    };
    await fetchJson({
      url: "https://example.invalid/x",
      timeoutMs: 1_000,
      label: "ARM",
      fetchImpl: impl,
      sleep: async (ms) => {
        sleeps.push(ms);
      },
    });
    expect(sleeps).toEqual([5_000]);
  });

  it("does not retry a 404", async () => {
    let attempts = 0;
    const impl: FetchLike = async () => {
      attempts += 1;
      return { ok: false, status: 404, headers: { get: () => null }, text: async () => "" };
    };
    await expect(
      fetchJson({
        url: "https://example.invalid/x",
        timeoutMs: 1_000,
        label: "GitHub",
        fetchImpl: impl,
        sleep: async () => undefined,
      }),
    ).rejects.toMatchObject({ code: "upstream_unavailable" });
    expect(attempts).toBe(1);
  });

  it("gives up after the retry budget", async () => {
    let attempts = 0;
    const impl: FetchLike = async () => {
      attempts += 1;
      return { ok: false, status: 503, headers: { get: () => null }, text: async () => "" };
    };
    await expect(
      fetchJson({
        url: "https://example.invalid/x",
        timeoutMs: 1_000,
        label: "ARM",
        fetchImpl: impl,
        sleep: async () => undefined,
      }),
    ).rejects.toMatchObject({ status: 502 });
    expect(attempts).toBe(3);
  });

  it("treats an unparseable body as an upstream failure", async () => {
    const impl: FetchLike = async () => ({
      ok: true,
      status: 200,
      headers: { get: () => null },
      text: async () => "<html>gateway</html>",
    });
    await expect(
      fetchJson({
        url: "https://example.invalid/x",
        timeoutMs: 1_000,
        label: "Log Analytics",
        fetchImpl: impl,
      }),
    ).rejects.toMatchObject({ code: "upstream_unavailable" });
  });
});

/* ------------------------------------------------------------------ */
/* projections                                                         */
/* ------------------------------------------------------------------ */

describe("projections are defensive about upstream shape", () => {
  it("survives a payload with everything missing", () => {
    expect(projectWorkflowRuns({})).toEqual({ total_count: 0, workflow_runs: [] });
    expect(projectCodeScanningAlerts(null)).toEqual([]);
    expect(projectDependabotAlerts("nonsense")).toEqual([]);
    expect(projectSecureScore(undefined)).toEqual({ value: [] });
    expect(projectSecureScoreControls({ value: "no" })).toEqual({ value: [] });
    expect(projectLogAnalytics({})).toEqual({ tables: [] });
  });

  it("omits security_severity_level when the upstream omits it", () => {
    const [alert] = projectCodeScanningAlerts([
      { number: 1, state: "open", created_at: "x", rule: { id: "r", severity: "warning", description: "d" }, tool: { name: "CodeQL" } },
    ]);
    expect(alert && "security_severity_level" in alert.rule).toBe(false);
  });

  it("keeps security_severity_level when the upstream provides it", () => {
    const [alert] = projectCodeScanningAlerts([
      {
        number: 1,
        state: "open",
        created_at: "x",
        rule: { id: "r", severity: "error", security_severity_level: "high", description: "d" },
        tool: { name: "CodeQL" },
        most_recent_instance: { location: { path: "src/a.ts" } },
      },
    ]);
    expect(alert?.rule.security_severity_level).toBe("high");
    expect(alert?.most_recent_instance?.location?.path).toBe("src/a.ts");
  });

  it("caps every feed at the item limit", () => {
    const many = Array.from({ length: MAX_FEED_ITEMS + 50 }, (_, index) => ({ number: index }));
    expect(projectCodeScanningAlerts(many)).toHaveLength(MAX_FEED_ITEMS);
    expect(projectDependabotAlerts(many)).toHaveLength(MAX_FEED_ITEMS);
    expect(
      projectWorkflowRuns({ workflow_runs: many }).workflow_runs,
    ).toHaveLength(MAX_FEED_ITEMS);
    expect(
      projectLogAnalytics({ tables: [{ name: "PrimaryResult", columns: [], rows: many.map(() => [1]) }] })
        .tables[0]?.rows,
    ).toHaveLength(MAX_FEED_ITEMS);
  });

  it("flattens a dynamic() cell rather than emitting an object", () => {
    const result = projectLogAnalytics({
      tables: [{ name: "PrimaryResult", columns: [], rows: [[{ nested: true }, null, 3]] }],
    });
    expect(result.tables[0]?.rows[0]).toEqual(['{"nested":true}', null, 3]);
  });
});

/* ------------------------------------------------------------------ */
/* selection                                                           */
/* ------------------------------------------------------------------ */

describe("backend selection", () => {
  it("builds the cloud set from cloud configuration", () => {
    const config = loadConfig(CLOUD_ENV as NodeJS.ProcessEnv);
    const backends = createBackends(config);
    expect(backends.kind).toBe("cloud");
    expect(backends.describe()).toMatchObject({
      sql: "mls-ops-demo-sql.database.windows.net/mls_ops",
      lakehouse: "abc123.datawarehouse.fabric.microsoft.com/mls_operations",
      github: "paulcfuqua/azure-devsecops",
      githubAuth: "token present",
    });
    // No identifiers that should not be published on a health endpoint.
    const described = JSON.stringify(backends.describe());
    expect(described).not.toContain(CLOUD_ENV.MLS_DEFENDER_SUBSCRIPTION_ID);
    expect(described).not.toContain(CLOUD_ENV.MLS_LOG_ANALYTICS_WORKSPACE_ID);
    expect(described).not.toContain(CLOUD_ENV.MLS_GITHUB_TOKEN);
  });

  it("flags a missing GitHub token on the health endpoint", () => {
    const config = loadConfig({ ...CLOUD_ENV, MLS_GITHUB_TOKEN: "" } as NodeJS.ProcessEnv);
    expect(createBackends(config).describe().githubAuth).toMatch(/MISSING/);
  });

  it.each([
    ["MLS_SQL_SERVER", "MLS_SQL_SERVER"],
    ["MLS_FABRIC_SQL_ENDPOINT", "MLS_FABRIC_SQL_ENDPOINT"],
    ["MLS_LOG_ANALYTICS_WORKSPACE_ID", "MLS_LOG_ANALYTICS_WORKSPACE_ID"],
  ])("refuses to boot in cloud mode without %s", (_label, key) => {
    const env = { ...CLOUD_ENV } as Record<string, string>;
    delete env[key];
    expect(() => loadConfig(env as NodeJS.ProcessEnv)).toThrow(new RegExp(key));
  });

  it("rejects a non-GUID subscription or workspace id", () => {
    expect(() =>
      loadConfig({ ...CLOUD_ENV, MLS_DEFENDER_SUBSCRIPTION_ID: "not-a-guid" } as NodeJS.ProcessEnv),
    ).toThrow(/GUID/);
    expect(() =>
      loadConfig({
        ...CLOUD_ENV,
        MLS_LOG_ANALYTICS_WORKSPACE_ID:
          "/subscriptions/x/resourceGroups/y/providers/Microsoft.OperationalInsights/workspaces/z",
      } as NodeJS.ProcessEnv),
    ).toThrow(/customer id/);
  });

  it("rejects a repo that is not owner/repo", () => {
    expect(() =>
      loadConfig({ ...CLOUD_ENV, MLS_GITHUB_REPO: "https://github.com/o/r" } as NodeJS.ProcessEnv),
    ).toThrow(/owner\/repo/);
  });

  it("made no live network call anywhere in this file", () => {
    expect(fetchSpy).not.toHaveBeenCalled();
  });
});
