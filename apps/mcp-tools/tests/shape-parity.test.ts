/**
 * SHAPE PARITY — the test that makes swapping backends safe.
 *
 * The five tool descriptions document their response shapes field by field, the
 * Copilot Studio agent reasons over those shapes, and the eval's fact walker
 * walks them. So "the cloud adapter returns the same shape as the local one" is
 * not a nicety — it is the whole basis on which L8 can be a configuration change
 * rather than a rewrite, and the only thing standing between "we switched the
 * env var" and "every answer on stage is wrong".
 *
 * Every assertion below goes through ONE function, `describeShape` in
 * ./helpers/shape.ts. Drift on either side — a cloud adapter that forgets
 * `truncated`, a local adapter that gains a field, a rename on one side only —
 * fails here, whichever side moved.
 *
 * The cloud adapters are fed mocked HTTP built FROM THE COMMITTED FIXTURES, so
 * this is a genuine round trip: fixture -> "the real API said this" -> adapter
 * -> shape, compared against fixture -> local adapter -> shape.
 */
import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { fixturesDir } from "../src/config.js";
import {
  FixtureDefenderPostureBackend,
  FixtureGithubSecurityBackend,
  FixtureLogAnalyticsBackend,
  LocalCostSeriesBackend,
  LocalLakehouseSqlBackend,
} from "../src/tools/backends.js";
import { AzureLogAnalyticsBackend } from "../src/tools/cloud/log-analytics.js";
import { LiveGithubSecurityBackend } from "../src/tools/cloud/github-security.js";
import { AzureDefenderPostureBackend } from "../src/tools/cloud/defender-posture.js";
import { AzureCostSeriesBackend } from "../src/tools/cloud/cost-series.js";
import { FabricLakehouseSqlBackend, type TdsExecutor } from "../src/tools/cloud/fabric-sql.js";
import { TokenProvider } from "../src/tools/auth.js";
import { countRows } from "../src/tools/index.js";
import { MockFetch, noSleep } from "./helpers/mock-fetch.js";
import { ABSENT, describeShape, mergeShapes } from "./helpers/shape.js";

const readFixture = (name: string): any =>
  JSON.parse(fs.readFileSync(path.join(fixturesDir, name), "utf-8"));

const tokens = (): TokenProvider =>
  new TokenProvider({
    async getToken() {
      return { token: "fake", expiresOnTimestamp: Date.now() + 3_600_000 };
    },
  });

/**
 * The single parity assertion. Everything in this file calls it; nothing in this
 * file compares shapes any other way.
 */
function expectSameShape(tool: string, local: unknown, cloud: unknown): void {
  expect(describeShape(cloud), `${tool}: cloud response shape differs from local`).toEqual(
    describeShape(local),
  );
  // Row counting is part of the contract too — the telemetry layer and the
  // agent both index into the same places.
  expect(countRows(tool, cloud), `${tool}: countRows disagrees across backends`).toEqual(
    countRows(tool, local),
  );
}

describe("describeShape itself", () => {
  it("reduces values to structure, so different data with the same shape matches", () => {
    expect(describeShape({ a: 1, b: "x" })).toEqual(describeShape({ a: 99, b: "y" }));
    expect(describeShape({ a: 1 })).not.toEqual(describeShape({ a: "1" }));
  });

  it("ignores $-prefixed fixture provenance keys", () => {
    expect(describeShape({ $comment: "a fixture", tables: [] })).toEqual(
      describeShape({ tables: [] }),
    );
  });

  it("merges array elements rather than sampling element 0", () => {
    // A code-scanning list where only some alerts carry dismissed_reason has one
    // shape; sampling the first element would let a real difference hide behind
    // an ordering.
    const merged = describeShape([{ a: 1 }, { a: 1, b: 2 }]);
    expect(merged).toEqual({ "[]": { a: "number", b: { "?": "number" } } });
  });

  it("keeps 'always present' and 'sometimes present' distinguishable", () => {
    // Otherwise a cloud adapter that always emits a field the local one only
    // sometimes emits would compare equal.
    expect(describeShape([{ a: 1 }, { a: 1, b: 2 }])).not.toEqual(
      describeShape([{ a: 1, b: 2 }, { a: 1, b: 2 }]),
    );
    expect(mergeShapes(ABSENT, "number")).toEqual({ "?": "number" });
  });

  it("unions differing primitives deterministically, whichever side is first", () => {
    expect(mergeShapes("string", "null")).toEqual(mergeShapes("null", "string"));
  });

  it("catches a missing field, a renamed field and a retyped field", () => {
    const reference = describeShape({ rows: [[1]], rowCount: 1, truncated: false });
    expect(describeShape({ rows: [[1]], rowCount: 1 })).not.toEqual(reference);
    expect(describeShape({ rows: [[1]], rowCount: 1, isTruncated: false })).not.toEqual(reference);
    expect(describeShape({ rows: [[1]], rowCount: "1", truncated: false })).not.toEqual(reference);
  });
});

describe("query_lakehouse_sql — sql.js vs Fabric SQL analytics endpoint", () => {
  it("returns the same {columns, rows, rowCount, truncated} shape from both", async () => {
    const sql =
      "SELECT cost_center, SUM(amount_usd) AS total_usd FROM cost_daily GROUP BY cost_center";
    const local = await new LocalLakehouseSqlBackend().query(sql);

    // The Fabric adapter, fed a TDS result carrying the same column types.
    const executor: TdsExecutor = {
      async execute(batch) {
        if (batch.includes("@@DATEFIRST")) {
          return { columns: ["datefirst", "seed_date_weekday"], rows: [[7, 7]] };
        }
        return {
          columns: ["cost_center", "total_usd"],
          rows: local.rows.map((row) => [...row]),
        };
      },
      async close() {},
    };
    const cloud = await new FabricLakehouseSqlBackend({
      sqlEndpoint: "abc.datawarehouse.fabric.microsoft.com",
      database: "mls_operations",
      tokens: tokens(),
      executor,
    }).query("SELECT cost_center, SUM(amount_usd) AS total_usd FROM cost_daily GROUP BY cost_center");

    expectSameShape("query_lakehouse_sql", local, cloud);
    expect(cloud.rowCount).toBe(local.rowCount);
    expect(cloud.truncated).toBe(local.truncated);
  });

  it("agrees on the shape of an empty result set", async () => {
    const local = await new LocalLakehouseSqlBackend().query(
      "SELECT launch_id FROM launches WHERE launch_id = 'nope'",
    );
    const executor: TdsExecutor = {
      async execute(batch) {
        if (batch.includes("@@DATEFIRST")) {
          return { columns: ["datefirst", "seed_date_weekday"], rows: [[7, 7]] };
        }
        return { columns: ["launch_id"], rows: [] };
      },
      async close() {},
    };
    const cloud = await new FabricLakehouseSqlBackend({
      sqlEndpoint: "abc.datawarehouse.fabric.microsoft.com",
      database: "mls_operations",
      tokens: tokens(),
      executor,
    }).query("SELECT launch_id FROM launches WHERE launch_id = 'nope'");
    expectSameShape("query_lakehouse_sql", local, cloud);
  });
});

describe("query_log_analytics — fixture vs Azure Monitor", () => {
  it("returns the same { tables: [{ name, columns, rows }] } shape from both", async () => {
    const fixture = readFixture("log-analytics.json");
    const local = await new FixtureLogAnalyticsBackend().query("AppRequests | take 5");

    // The real API's envelope is exactly the fixture, minus the $comment.
    const mock = new MockFetch().on(/loganalytics/, {
      status: 200,
      body: { tables: fixture.tables },
    });
    const cloud = await new AzureLogAnalyticsBackend({
      workspaceId: "11111111-2222-3333-4444-555555555555",
      tokens: tokens(),
      fetchImpl: mock.fetch,
      sleep: noSleep,
    }).query("AppRequests | take 5");

    expectSameShape("query_log_analytics", local, cloud);
    // Not just structurally equal — the pass-through is literal.
    expect(cloud.tables).toEqual(local.tables);
  });
});

describe("get_github_security — fixture vs GitHub REST", () => {
  it("returns the same two-key envelope, with items passed through verbatim", async () => {
    const fixture = readFixture("github-security.json");
    const local = await new FixtureGithubSecurityBackend().getAlerts("all");

    // GitHub returns a bare array per endpoint; the adapter is what builds the
    // envelope, so this is the assertion that it builds the right one.
    const mock = new MockFetch()
      .on(/dependabot\/alerts/, { status: 200, body: fixture.dependabot_alerts })
      .on(/code-scanning\/alerts/, { status: 200, body: fixture.code_scanning_alerts });
    const cloud = await new LiveGithubSecurityBackend({
      repo: "paulcfuqua/azure-devsecops-demo",
      token: "ghp_0123456789abcdefghijABCDEFGHIJ",
      fetchImpl: mock.fetch,
      sleep: noSleep,
    }).getAlerts("all");

    expectSameShape("get_github_security", local, cloud);
    expect(cloud).toEqual(local);
  });

  it("keeps the shape when a family is filtered out on either backend", async () => {
    const fixture = readFixture("github-security.json");
    const local = await new FixtureGithubSecurityBackend().getAlerts("dependabot");
    const mock = new MockFetch().on(/dependabot\/alerts/, {
      status: 200,
      body: fixture.dependabot_alerts,
    });
    const cloud = await new LiveGithubSecurityBackend({
      repo: "paulcfuqua/azure-devsecops-demo",
      token: "ghp_0123456789abcdefghijABCDEFGHIJ",
      fetchImpl: mock.fetch,
      sleep: noSleep,
    }).getAlerts("dependabot");
    expectSameShape("get_github_security", local, cloud);
  });
});

describe("get_defender_posture — fixture vs ARM secureScores", () => {
  it("returns the same { secure_score, controls: { value } } shape from both", async () => {
    const fixture = readFixture("defender-posture.json");
    const local = await new FixtureDefenderPostureBackend().getPosture();

    const mock = new MockFetch()
      .on((url) => url.includes("ascScore") && !url.includes("secureScoreControls"), {
        status: 200,
        body: fixture.secure_score,
      })
      .on(/secureScoreControls/, { status: 200, body: { value: fixture.controls.value } });
    const cloud = await new AzureDefenderPostureBackend({
      subscriptionId: "00000000-1111-2222-3333-444444444444",
      tokens: tokens(),
      fetchImpl: mock.fetch,
      sleep: noSleep,
    }).getPosture();

    expectSameShape("get_defender_posture", local, cloud);
    expect(cloud.secure_score).toEqual(local.secure_score);
    expect(cloud.controls.value).toEqual(local.controls.value);
  });
});

describe("get_cost_series — cost_daily vs Cost Management", () => {
  it("returns the same Cost Management envelope and row tuple from both", async () => {
    const local = await new LocalCostSeriesBackend().getSeries({ cost_center: "Propulsion" });

    // Rebuild the same series as the API would have returned it: integer dates,
    // a Cost column, a TagValue column, no budget anywhere.
    const mock = new MockFetch()
      .on(/CostManagement/, {
        status: 200,
        body: {
          id: "/subscriptions/x/providers/Microsoft.CostManagement/query",
          name: "query",
          properties: {
            columns: [
              { name: "Cost", type: "Number" },
              { name: "UsageDate", type: "Number" },
              { name: "TagValue", type: "String" },
              { name: "Currency", type: "String" },
            ],
            rows: local.properties.rows.map(([date, center, amount]) => [
              amount,
              Number(String(date).replaceAll("-", "")),
              center,
              "USD",
            ]),
          },
        },
      })
      .on(/budgets/, { status: 200, body: { value: [] } });

    const cloud = await new AzureCostSeriesBackend({
      scope: "/subscriptions/00000000-1111-2222-3333-444444444444",
      tokens: tokens(),
      fetchImpl: mock.fetch,
      sleep: noSleep,
    }).getSeries({ cost_center: "Propulsion" });

    expectSameShape("get_cost_series", local, cloud);
    // The advertised column names must survive the reshape, not just the types.
    expect(cloud.properties.columns).toEqual(local.properties.columns);
    expect(cloud.type).toBe(local.type);
    // Row 0 carries the same date and cost center; only budget differs (the API
    // has none, and no budget was configured in this mock).
    expect(cloud.properties.rows[0]?.[0]).toBe(local.properties.rows[0]?.[0]);
    expect(cloud.properties.rows[0]?.[1]).toBe(local.properties.rows[0]?.[1]);
  });
});
