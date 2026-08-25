/**
 * The four HTTP cloud adapters, driven entirely through a mocked `fetch`.
 *
 * There is no tenant, and there will not be one before this code has to be
 * right, so every request/response pair here is written from the documented API
 * envelopes: Azure Monitor's `{tables}`, GitHub's bare alert arrays plus a Link
 * header, ARM's `{value, nextLink}`, and Cost Management's
 * `{properties:{columns,rows,nextLink}}`. What the tests assert is what the
 * adapter does WITH those envelopes — which is where the work and the risk are.
 */
import { describe, expect, it } from "vitest";
import { AzureLogAnalyticsBackend } from "../src/tools/cloud/log-analytics.js";
import { LiveGithubSecurityBackend } from "../src/tools/cloud/github-security.js";
import { AzureDefenderPostureBackend } from "../src/tools/cloud/defender-posture.js";
import {
  AzureCostSeriesBackend,
  budgetPerDay,
  daysInMonthOf,
  normalizeUsageDate,
} from "../src/tools/cloud/cost-series.js";
import { TokenProvider, SCOPES } from "../src/tools/auth.js";
import { AdapterError } from "../src/tools/errors.js";
import { MockFetch, noSleep } from "./helpers/mock-fetch.js";
import { rejection } from "./helpers/rejection.js";

const WORKSPACE = "11111111-2222-3333-4444-555555555555";
const SUBSCRIPTION = "00000000-1111-2222-3333-444444444444";

function tokens(): TokenProvider {
  return new TokenProvider({
    async getToken(scope) {
      return {
        token: `fake-token-for-${String(scope)}`,
        expiresOnTimestamp: Date.now() + 3_600_000,
      };
    },
  });
}

/* ------------------------------------------------------------------ */
/* query_log_analytics                                                 */
/* ------------------------------------------------------------------ */

const LA_BODY = {
  tables: [
    {
      name: "PrimaryResult",
      columns: [
        { name: "TimeGenerated", type: "datetime" },
        { name: "AppRoleName", type: "string" },
        { name: "DurationMs", type: "real" },
      ],
      rows: [["2026-08-21T14:02:11.503Z", "mls-launch-ops", 42.7]],
    },
  ],
};

function logAnalytics(mock: MockFetch): AzureLogAnalyticsBackend {
  return new AzureLogAnalyticsBackend({
    workspaceId: WORKSPACE,
    tokens: tokens(),
    fetchImpl: mock.fetch,
    sleep: noSleep,
  });
}

describe("query_log_analytics — Azure Monitor query API", () => {
  it("POSTs the documented URL and body, with the Log Analytics scope's token", async () => {
    const mock = new MockFetch().on(/loganalytics/, { status: 200, body: LA_BODY });
    const result = await logAnalytics(mock).query("AppRequests | take 5", "P1D");

    const call = mock.calls[0]!;
    expect(call.method).toBe("POST");
    expect(call.url).toBe(`https://api.loganalytics.io/v1/workspaces/${WORKSPACE}/query`);
    expect(call.body).toEqual({ query: "AppRequests | take 5", timespan: "P1D" });
    expect(call.headers["authorization"]).toBe(`Bearer fake-token-for-${SCOPES.logAnalytics}`);
    expect(result.tables[0]?.name).toBe("PrimaryResult");
  });

  it("passes the response envelope through untouched — the shape IS the contract", async () => {
    const mock = new MockFetch().on(/loganalytics/, { status: 200, body: LA_BODY });
    expect(await logAnalytics(mock).query("AppRequests")).toEqual({ tables: LA_BODY.tables });
  });

  it("omits timespan when the caller gave none", async () => {
    const mock = new MockFetch().on(/loganalytics/, { status: 200, body: LA_BODY });
    await logAnalytics(mock).query("AppRequests");
    expect(mock.calls[0]?.body).toEqual({ query: "AppRequests" });
  });

  it("aligns the server's own deadline with ours via Prefer: wait", async () => {
    const mock = new MockFetch().on(/loganalytics/, { status: 200, body: LA_BODY });
    await logAnalytics(mock).query("AppRequests");
    expect(mock.calls[0]?.headers["prefer"]).toMatch(/^wait=\d+$/);
  });

  it("refuses a 200 PartialError rather than passing off partial rows as complete", async () => {
    // The single most dangerous response this API produces: HTTP 200, some
    // rows, and an error saying the rest are missing.
    const mock = new MockFetch().on(/loganalytics/, {
      status: 200,
      body: { ...LA_BODY, error: { code: "PartialError", message: "one shard failed" } },
    });
    const failure = await rejection<AdapterError>(logAnalytics(mock).query("AppRequests"));
    expect(failure).toBeInstanceOf(AdapterError);
    expect(failure.message).toContain("PartialError");
    expect(failure.message).toContain("not a complete answer");
  });

  it("maps a 204 empty workspace to an empty table list, not an error", async () => {
    const mock = new MockFetch().on(/loganalytics/, { status: 204 });
    expect(await logAnalytics(mock).query("AppRequests")).toEqual({ tables: [] });
  });

  it("surfaces a KQL syntax error as bad_request with the parser's own text", async () => {
    const mock = new MockFetch().on(/loganalytics/, {
      status: 400,
      body: {
        error: {
          code: "BadArgumentError",
          message: "The request had some invalid properties",
          innererror: { code: "SYN0002", message: "Query could not be parsed at 'summarise'" },
        },
      },
    });
    const failure = await rejection<AdapterError>(
      logAnalytics(mock).query("AppRequests | summarise count()"),
    );
    expect(failure.kind).toBe("bad_request");
    expect(failure.message).toContain("summarise");
  });

  it("retries a 429 and then succeeds", async () => {
    const mock = new MockFetch().on(
      /loganalytics/,
      { status: 429, headers: { "retry-after": "1" } },
      { status: 200, body: LA_BODY },
    );
    expect((await logAnalytics(mock).query("AppRequests")).tables).toHaveLength(1);
    expect(mock.calls).toHaveLength(2);
  });

  it("rejects an empty query without calling the API", async () => {
    const mock = new MockFetch();
    await expect(logAnalytics(mock).query("  ")).rejects.toThrow(/non-empty/);
    expect(mock.calls).toHaveLength(0);
  });
});

/* ------------------------------------------------------------------ */
/* get_github_security                                                 */
/* ------------------------------------------------------------------ */

const DEPENDABOT = [
  { number: 1, state: "open", dependency: { package: { name: "json5" } } },
  { number: 2, state: "open", dependency: { package: { name: "minimist" } } },
];
const CODE_SCANNING = [{ number: 12, state: "open", rule: { id: "js/sql-injection" } }];

function github(mock: MockFetch): LiveGithubSecurityBackend {
  return new LiveGithubSecurityBackend({
    repo: "paulcfuqua/azure-devsecops",
    token: "ghp_0123456789abcdefghijABCDEFGHIJ",
    fetchImpl: mock.fetch,
    sleep: noSleep,
  });
}

describe("get_github_security — GitHub Advanced Security REST", () => {
  it("assembles the two-key envelope from the two endpoints", async () => {
    const mock = new MockFetch()
      .on(/dependabot\/alerts/, { status: 200, body: DEPENDABOT })
      .on(/code-scanning\/alerts/, { status: 200, body: CODE_SCANNING });
    const result = await github(mock).getAlerts("all");
    expect(result).toEqual({
      dependabot_alerts: DEPENDABOT,
      code_scanning_alerts: CODE_SCANNING,
    });
  });

  it("sends the token, the API version and the documented Accept header", async () => {
    const mock = new MockFetch()
      .on(/dependabot/, { status: 200, body: DEPENDABOT })
      .on(/code-scanning/, { status: 200, body: CODE_SCANNING });
    await github(mock).getAlerts("all");
    const call = mock.calls[0]!;
    expect(call.headers["authorization"]).toBe("Bearer ghp_0123456789abcdefghijABCDEFGHIJ");
    expect(call.headers["accept"]).toBe("application/vnd.github+json");
    expect(call.headers["x-github-api-version"]).toBe("2022-11-28");
    expect(call.url).toContain("state=open");
    expect(call.url).toContain("per_page=100");
  });

  it("fetches only the requested family and leaves the other empty", async () => {
    const mock = new MockFetch()
      .on(/dependabot/, { status: 200, body: DEPENDABOT })
      .on(/code-scanning/, { status: 200, body: CODE_SCANNING });

    const onlyDependabot = await github(mock).getAlerts("dependabot");
    expect(onlyDependabot.dependabot_alerts).toHaveLength(2);
    expect(onlyDependabot.code_scanning_alerts).toEqual([]);
    expect(mock.callsMatching(/code-scanning/)).toHaveLength(0);

    const onlyCodeScanning = await github(mock).getAlerts("code_scanning");
    expect(onlyCodeScanning.dependabot_alerts).toEqual([]);
    expect(onlyCodeScanning.code_scanning_alerts).toHaveLength(1);
  });

  it("follows Link rel=next across pages", async () => {
    const mock = new MockFetch()
      .on((url) => url.includes("dependabot") && !url.includes("page=2"), {
        status: 200,
        body: [DEPENDABOT[0]],
        headers: {
          link: '<https://api.github.com/repos/paulcfuqua/azure-devsecops/dependabot/alerts?page=2>; rel="next"',
        },
      })
      .on((url) => url.includes("dependabot") && url.includes("page=2"), {
        status: 200,
        body: [DEPENDABOT[1]],
      })
      .on(/code-scanning/, { status: 200, body: CODE_SCANNING });

    const result = await github(mock).getAlerts("all");
    expect(result.dependabot_alerts).toHaveLength(2);
    expect(mock.callsMatching(/dependabot/)).toHaveLength(2);
  });

  it("treats a 404 'no analysis found' as zero alerts, not as a failed call", async () => {
    // CodeQL has never run on this repo. The Dependabot half must still answer.
    const mock = new MockFetch()
      .on(/dependabot/, { status: 200, body: DEPENDABOT })
      .on(/code-scanning/, { status: 404, body: { message: "no analysis found" } });
    const result = await github(mock).getAlerts("all");
    expect(result.dependabot_alerts).toHaveLength(2);
    expect(result.code_scanning_alerts).toEqual([]);
  });

  it("propagates a 403 — a disabled feature or a scopeless token is a real fault", async () => {
    const mock = new MockFetch()
      .on(/dependabot/, { status: 200, body: DEPENDABOT })
      .on(/code-scanning/, {
        status: 403,
        body: { message: "Advanced Security must be enabled for this repository" },
      });
    const failure = await rejection<AdapterError>(github(mock).getAlerts("all"));
    expect(failure).toBeInstanceOf(AdapterError);
    expect(failure.kind).toBe("auth");
  });

  it("retries a 429 secondary-rate-limit response", async () => {
    const mock = new MockFetch()
      .on(
        /dependabot/,
        { status: 429, headers: { "retry-after": "1" } },
        { status: 200, body: DEPENDABOT },
      )
      .on(/code-scanning/, { status: 200, body: CODE_SCANNING });
    const result = await github(mock).getAlerts("all");
    expect(result.dependabot_alerts).toHaveLength(2);
    expect(mock.callsMatching(/dependabot/)).toHaveLength(2);
  });

  it("refuses a malformed repo at construction, before any call", () => {
    expect(() => new LiveGithubSecurityBackend({ repo: "not-a-repo", token: "x" })).toThrow(
      /owner\/repo/,
    );
  });

  it("refuses an empty token with a message that says where it comes from", async () => {
    const mock = new MockFetch().on(/./, { status: 200, body: [] });
    const backend = new LiveGithubSecurityBackend({
      repo: "a/b",
      token: "",
      fetchImpl: mock.fetch,
    });
    await expect(backend.getAlerts("dependabot")).rejects.toThrow(/GITHUB_TOKEN/);
    expect(mock.calls).toHaveLength(0);
  });
});

/* ------------------------------------------------------------------ */
/* get_defender_posture                                                */
/* ------------------------------------------------------------------ */

const SCORE = {
  id: `/subscriptions/${SUBSCRIPTION}/providers/Microsoft.Security/secureScores/ascScore`,
  name: "ascScore",
  type: "Microsoft.Security/secureScores",
  properties: {
    displayName: "ASC score",
    score: { max: 58, current: 43.15, percentage: 0.7439 },
    weight: 178,
  },
};
const CONTROL = (name: string): Record<string, unknown> => ({
  id: `${SCORE.id}/secureScoreControls/${name}`,
  name,
  type: "Microsoft.Security/secureScores/secureScoreControls",
  properties: {
    displayName: name,
    score: { max: 10, current: 10, percentage: 1 },
    healthyResourceCount: 6,
    unhealthyResourceCount: 0,
    weight: 6,
  },
});

function defender(mock: MockFetch): AzureDefenderPostureBackend {
  return new AzureDefenderPostureBackend({
    subscriptionId: SUBSCRIPTION,
    tokens: tokens(),
    fetchImpl: mock.fetch,
    sleep: noSleep,
  });
}

describe("get_defender_posture — Defender for Cloud via ARM", () => {
  it("addresses ascScore by name and returns the fixture's envelope", async () => {
    const mock = new MockFetch()
      .on((url) => url.includes("ascScore") && !url.includes("secureScoreControls"), {
        status: 200,
        body: SCORE,
      })
      .on(/secureScoreControls/, { status: 200, body: { value: [CONTROL("EnableMFA")] } });

    const result = await defender(mock).getPosture();
    expect(result.secure_score).toEqual(SCORE);
    expect(result.controls.value).toHaveLength(1);

    const scoreCall = mock.calls.find((c) => !c.url.includes("secureScoreControls"))!;
    expect(scoreCall.url).toContain(
      `/subscriptions/${SUBSCRIPTION}/providers/Microsoft.Security/secureScores/ascScore`,
    );
    expect(scoreCall.url).toContain("api-version=2020-01-01");
    expect(scoreCall.headers["authorization"]).toBe(`Bearer fake-token-for-${SCOPES.arm}`);
  });

  it("follows nextLink across control pages", async () => {
    const mock = new MockFetch()
      .on((url) => url.includes("ascScore") && !url.includes("secureScoreControls"), {
        status: 200,
        body: SCORE,
      })
      .on((url) => url.includes("secureScoreControls") && !url.includes("skipToken"), {
        status: 200,
        body: {
          value: [CONTROL("EnableMFA")],
          nextLink: "https://management.azure.com/next?skipToken=2",
        },
      })
      .on((url) => url.includes("skipToken"), {
        status: 200,
        body: { value: [CONTROL("ApplySystemUpdates"), CONTROL("EnableEncryptionAtRest")] },
      });

    const result = await defender(mock).getPosture();
    expect(result.controls.value.map((c) => c.name)).toEqual([
      "EnableMFA",
      "ApplySystemUpdates",
      "EnableEncryptionAtRest",
    ]);
  });

  it("retries a 429 on either call", async () => {
    const mock = new MockFetch()
      .on(
        (url) => url.includes("ascScore") && !url.includes("secureScoreControls"),
        { status: 429, headers: { "retry-after": "1" } },
        { status: 200, body: SCORE },
      )
      .on(/secureScoreControls/, { status: 200, body: { value: [CONTROL("EnableMFA")] } });
    await expect(defender(mock).getPosture()).resolves.toBeDefined();
  });

  it("maps a 403 to auth so the message names a permissions problem", async () => {
    const mock = new MockFetch().on(/ascScore/, {
      status: 403,
      body: { error: { code: "AuthorizationFailed", message: "no" } },
    });
    const failure = await rejection<AdapterError>(defender(mock).getPosture());
    expect(failure.kind).toBe("auth");
    expect(failure.retryable).toBe(false);
  });

  it("refuses an empty subscription id at construction", () => {
    expect(() => new AzureDefenderPostureBackend({ subscriptionId: "", tokens: tokens() })).toThrow(
      /AZURE_SUBSCRIPTION_ID/,
    );
  });
});

/* ------------------------------------------------------------------ */
/* get_cost_series                                                     */
/* ------------------------------------------------------------------ */

const COST_COLUMNS = [
  { name: "Cost", type: "Number" },
  { name: "UsageDate", type: "Number" },
  { name: "TagValue", type: "String" },
  { name: "Currency", type: "String" },
];

function costSeries(mock: MockFetch): AzureCostSeriesBackend {
  return new AzureCostSeriesBackend({
    scope: `/subscriptions/${SUBSCRIPTION}`,
    tokens: tokens(),
    fetchImpl: mock.fetch,
    sleep: noSleep,
    today: () => new Date("2026-06-21T00:00:00Z"),
  });
}

describe("get_cost_series — Azure Cost Management", () => {
  it("projects the API's rows into the contract's [date, cost_center, amount, budget]", async () => {
    const mock = new MockFetch()
      .on(/CostManagement/, {
        status: 200,
        body: {
          id: "/subscriptions/x/query",
          name: "q",
          properties: {
            columns: COST_COLUMNS,
            rows: [
              [1234.5, 20260101, "Propulsion", "USD"],
              [99.25, 20260102, "Propulsion", "USD"],
            ],
          },
        },
      })
      .on(/Consumption\/budgets/, { status: 200, body: { value: [] } });

    const result = await costSeries(mock).getSeries({ cost_center: "Propulsion" });
    expect(result.type).toBe("Microsoft.CostManagement/query");
    expect(result.properties.columns.map((c) => c.name)).toEqual([
      "date",
      "cost_center",
      "amount_usd",
      "budget_usd",
    ]);
    expect(result.properties.rows).toEqual([
      ["2026-01-01", "Propulsion", 1234.5, 0],
      ["2026-01-02", "Propulsion", 99.25, 0],
    ]);
  });

  it("asks for a Daily ActualCost query grouped by the costCenter tag", async () => {
    const mock = new MockFetch()
      .on(/CostManagement/, {
        status: 200,
        body: { properties: { columns: COST_COLUMNS, rows: [] } },
      })
      .on(/budgets/, { status: 200, body: { value: [] } });
    await costSeries(mock).getSeries({ start_date: "2026-01-01", end_date: "2026-01-31" });

    const call = mock.callsMatching(/CostManagement/)[0]!;
    expect(call.method).toBe("POST");
    expect(call.body.type).toBe("ActualCost");
    expect(call.body.dataset.granularity).toBe("Daily");
    expect(call.body.dataset.grouping).toEqual([{ type: "TagKey", name: "costCenter" }]);
    expect(call.body.timePeriod.from).toBe("2026-01-01T00:00:00Z");
    expect(call.body.timePeriod.to).toBe("2026-01-31T23:59:59Z");
  });

  it("pushes a cost_center filter into the query instead of filtering locally", async () => {
    const mock = new MockFetch()
      .on(/CostManagement/, {
        status: 200,
        body: { properties: { columns: COST_COLUMNS, rows: [] } },
      })
      .on(/budgets/, { status: 200, body: { value: [] } });
    await costSeries(mock).getSeries({ cost_center: "Avionics" });
    expect(mock.callsMatching(/CostManagement/)[0]!.body.dataset.filter).toEqual({
      tags: { name: "costCenter", operator: "In", values: ["Avionics"] },
    });
  });

  it("maps columns by NAME, so an extra API column cannot shift the reading", async () => {
    const shuffled = [
      { name: "ResourceGroup", type: "String" },
      { name: "UsageDate", type: "Number" },
      { name: "Cost", type: "Number" },
      { name: "TagValue", type: "String" },
    ];
    const mock = new MockFetch()
      .on(/CostManagement/, {
        status: 200,
        body: {
          properties: { columns: shuffled, rows: [["mls-rg-apps", 20260101, 42.0, "Facilities"]] },
        },
      })
      .on(/budgets/, { status: 200, body: { value: [] } });
    const result = await costSeries(mock).getSeries({});
    expect(result.properties.rows).toEqual([["2026-01-01", "Facilities", 42, 0]]);
  });

  it("sums API rows that differ only in a column the contract does not carry", async () => {
    const mock = new MockFetch()
      .on(/CostManagement/, {
        status: 200,
        body: {
          properties: {
            columns: COST_COLUMNS,
            rows: [
              [10, 20260101, "Propulsion", "USD"],
              [5, 20260101, "Propulsion", "EUR"],
            ],
          },
        },
      })
      .on(/budgets/, { status: 200, body: { value: [] } });
    const result = await costSeries(mock).getSeries({});
    // One row per date per cost center, as the description promises.
    expect(result.properties.rows).toEqual([["2026-01-01", "Propulsion", 15, 0]]);
  });

  it("orders by date then cost center, ascending", async () => {
    const mock = new MockFetch()
      .on(/CostManagement/, {
        status: 200,
        body: {
          properties: {
            columns: COST_COLUMNS,
            rows: [
              [3, 20260102, "Avionics", "USD"],
              [1, 20260101, "Propulsion", "USD"],
              [2, 20260101, "Avionics", "USD"],
            ],
          },
        },
      })
      .on(/budgets/, { status: 200, body: { value: [] } });
    const result = await costSeries(mock).getSeries({});
    expect(result.properties.rows.map((r) => [r[0], r[1]])).toEqual([
      ["2026-01-01", "Avionics"],
      ["2026-01-01", "Propulsion"],
      ["2026-01-02", "Avionics"],
    ]);
  });

  it("follows properties.nextLink, re-POSTing the same body", async () => {
    const mock = new MockFetch()
      .on((url) => url.includes("CostManagement") && !url.includes("continuation"), {
        status: 200,
        body: {
          properties: {
            columns: COST_COLUMNS,
            rows: [[1, 20260101, "Propulsion", "USD"]],
            nextLink: "https://management.azure.com/query?continuation=abc",
          },
        },
      })
      .on((url) => url.includes("continuation"), {
        status: 200,
        body: { properties: { columns: COST_COLUMNS, rows: [[2, 20260102, "Propulsion", "USD"]] } },
      })
      .on(/budgets/, { status: 200, body: { value: [] } });

    const result = await costSeries(mock).getSeries({});
    expect(result.properties.rows).toHaveLength(2);
    const pages = mock.calls.filter((c) => c.method === "POST");
    expect(pages).toHaveLength(2);
    // The continuation POST carries the identical body — that is how this API pages.
    expect(pages[1]!.body).toEqual(pages[0]!.body);
  });

  it("caps at 500 rows like the local adapter does", async () => {
    const rows = Array.from({ length: 600 }, (_, i) => [i, 20260101 + i, "Propulsion", "USD"]);
    const mock = new MockFetch()
      .on(/CostManagement/, { status: 200, body: { properties: { columns: COST_COLUMNS, rows } } })
      .on(/budgets/, { status: 200, body: { value: [] } });
    const result = await costSeries(mock).getSeries({});
    expect(result.properties.rows).toHaveLength(500);
  });

  it("joins a per-day budget derived from Microsoft.Consumption/budgets", async () => {
    const mock = new MockFetch()
      .on(/CostManagement/, {
        status: 200,
        body: {
          properties: {
            columns: COST_COLUMNS,
            rows: [
              [10, 20260101, "Propulsion", "USD"],
              [10, 20260201, "Propulsion", "USD"],
            ],
          },
        },
      })
      .on(/budgets/, {
        status: 200,
        body: {
          value: [
            {
              name: "propulsion-monthly",
              properties: {
                category: "Cost",
                amount: 3100,
                timeGrain: "Monthly",
                filter: { tags: { name: "costCenter", operator: "In", values: ["Propulsion"] } },
              },
            },
          ],
        },
      });
    const result = await costSeries(mock).getSeries({});
    // 3100 / 31 days in January = 100; 3100 / 28 days in February = 110.71.
    expect(result.properties.rows[0]![3]).toBe(100);
    expect(result.properties.rows[1]![3]).toBeCloseTo(110.71, 2);
  });

  it("degrades to budget 0 when budgets cannot be read, keeping the shape intact", async () => {
    const mock = new MockFetch()
      .on(/CostManagement/, {
        status: 200,
        body: {
          properties: { columns: COST_COLUMNS, rows: [[10, 20260101, "Propulsion", "USD"]] },
        },
      })
      .on(/budgets/, { status: 403, body: { error: { message: "no permission" } } });
    const result = await costSeries(mock).getSeries({});
    // A missing budget must not become a missing column.
    expect(result.properties.rows).toEqual([["2026-01-01", "Propulsion", 10, 0]]);
  });

  it("defaults the window to the last year ending today when no dates are given", async () => {
    const mock = new MockFetch()
      .on(/CostManagement/, {
        status: 200,
        body: { properties: { columns: COST_COLUMNS, rows: [] } },
      })
      .on(/budgets/, { status: 200, body: { value: [] } });
    await costSeries(mock).getSeries({});
    const body = mock.callsMatching(/CostManagement/)[0]!.body;
    expect(body.timePeriod.to).toBe("2026-06-21T23:59:59Z");
    expect(body.timePeriod.from).toBe("2025-06-21T00:00:00Z");
  });

  it("rejects a non-ISO date without calling the API", async () => {
    const mock = new MockFetch();
    await expect(costSeries(mock).getSeries({ start_date: "January 2026" })).rejects.toThrow(
      /ISO date/,
    );
    await expect(
      costSeries(mock).getSeries({ start_date: "2026-02-01", end_date: "2026-01-01" }),
    ).rejects.toThrow(/after end_date/);
    expect(mock.calls).toHaveLength(0);
  });

  it("retries a 429 from Cost Management, which throttles aggressively", async () => {
    const mock = new MockFetch()
      .on(
        /CostManagement/,
        { status: 429, headers: { "retry-after": "1" } },
        { status: 200, body: { properties: { columns: COST_COLUMNS, rows: [] } } },
      )
      .on(/budgets/, { status: 200, body: { value: [] } });
    await expect(costSeries(mock).getSeries({})).resolves.toBeDefined();
    expect(mock.callsMatching(/CostManagement/)).toHaveLength(2);
  });

  it("explains itself when the API returns columns it cannot map", async () => {
    const mock = new MockFetch()
      .on(/CostManagement/, {
        status: 200,
        body: { properties: { columns: [{ name: "Mystery", type: "String" }], rows: [["x"]] } },
      })
      .on(/budgets/, { status: 200, body: { value: [] } });
    await expect(costSeries(mock).getSeries({})).rejects.toThrow(/columns this adapter cannot map/);
  });

  it("refuses a scope that is not an ARM path", () => {
    expect(() => new AzureCostSeriesBackend({ scope: "my-subscription", tokens: tokens() })).toThrow(
      /starting with/,
    );
  });
});

describe("cost-series pure helpers", () => {
  it("normalizeUsageDate handles the API's integer dates and ISO strings alike", () => {
    expect(normalizeUsageDate(20260131)).toBe("2026-01-31");
    expect(normalizeUsageDate("2026-01-31")).toBe("2026-01-31");
    expect(normalizeUsageDate("2026-01-31T00:00:00")).toBe("2026-01-31");
  });

  it("daysInMonthOf gets February right, including the leap year", () => {
    expect(daysInMonthOf("2026-01-15")).toBe(31);
    expect(daysInMonthOf("2026-02-15")).toBe(28);
    expect(daysInMonthOf("2024-02-15")).toBe(29);
  });

  it("budgetPerDay prorates by time grain rather than by a flat 30 days", () => {
    const monthly = { costCenter: "propulsion", amount: 3100, timeGrain: "Monthly" };
    expect(budgetPerDay(monthly, "2026-01-01")).toBe(100);
    expect(budgetPerDay({ ...monthly, timeGrain: "Annually" }, "2026-01-01")).toBeCloseTo(8.49, 2);
  });
});

describe("token reuse across adapters", () => {
  it("acquires one token per scope, not one per call", async () => {
    let acquisitions = 0;
    const provider = new TokenProvider({
      async getToken() {
        acquisitions += 1;
        return { token: "t", expiresOnTimestamp: Date.now() + 3_600_000 };
      },
    });
    const mock = new MockFetch()
      .on((url) => url.includes("ascScore") && !url.includes("secureScoreControls"), {
        status: 200,
        body: SCORE,
      })
      .on(/secureScoreControls/, { status: 200, body: { value: [] } });
    const backend = new AzureDefenderPostureBackend({
      subscriptionId: SUBSCRIPTION,
      tokens: provider,
      fetchImpl: mock.fetch,
      sleep: noSleep,
    });
    await backend.getPosture();
    await backend.getPosture();
    expect(acquisitions).toBe(1);
  });

  it("turns a credential failure into an auth error that names the likely cause", async () => {
    const provider = new TokenProvider({
      async getToken() {
        throw new Error("ManagedIdentityCredential: no identity endpoint found");
      },
    });
    const backend = new AzureDefenderPostureBackend({
      subscriptionId: SUBSCRIPTION,
      tokens: provider,
      fetchImpl: new MockFetch().fetch,
    });
    const failure = await rejection<AdapterError>(backend.getPosture());
    expect(failure.kind).toBe("auth");
    expect(failure.message).toMatch(/managed identity/i);
  });
});
