/**
 * Backend adapters — one interface per tool, with:
 *   - LOCAL adapters (Phase P): real SQL over sql.js for the lakehouse,
 *     cost_daily-backed cost series, and committed fixtures (shaped like the
 *     real APIs) for Log Analytics / GitHub Security / Defender.
 *   - Cloud adapters: typed stubs, implemented at L8 when the tenant exists
 *     (Fabric SQL analytics endpoint, Azure Monitor Log Analytics, GitHub
 *     Security REST API, Microsoft Defender for Cloud, Azure Cost Management).
 *
 * Fixture/result shapes are documented per interface so the L8 wiring swaps
 * adapters without touching the tool loop.
 */
import fs from "node:fs";
import path from "node:path";
import { fixturesDir } from "../config.js";
import {
  queryLakehouse,
  type LakehouseQueryResult,
} from "../data/lakehouse.js";

function readFixture(name: string): unknown {
  const p = path.join(fixturesDir, name);
  return JSON.parse(fs.readFileSync(p, "utf-8"));
}

/* ------------------------------------------------------------------ */
/* query_lakehouse_sql                                                 */
/* ------------------------------------------------------------------ */

export interface LakehouseSqlBackend {
  /** Execute one read-only SQL statement; returns columns + capped rows. */
  query(sql: string): Promise<LakehouseQueryResult>;
}

/** LOCAL: sql.js (SQLite wasm) over data/generated/*.csv — real SQL execution. */
export class LocalLakehouseSqlBackend implements LakehouseSqlBackend {
  query(sql: string): Promise<LakehouseQueryResult> {
    return queryLakehouse(sql);
  }
}

/** L8: Fabric lakehouse SQL analytics endpoint (TDS). Implemented at L8. */
export class FabricLakehouseSqlBackend implements LakehouseSqlBackend {
  constructor(
    /** e.g. mls-fab-demo workspace SQL endpoint FQDN */
    readonly sqlEndpoint: string,
    /** lakehouse database name */
    readonly database: string,
  ) {}
  query(_sql: string): Promise<LakehouseQueryResult> {
    return Promise.reject(
      new Error("FabricLakehouseSqlBackend is implemented at L8 (needs the tenant)"),
    );
  }
}

/* ------------------------------------------------------------------ */
/* query_log_analytics                                                 */
/* ------------------------------------------------------------------ */

/**
 * Shape: the Azure Monitor Log Analytics query API response
 * (POST https://api.loganalytics.io/v1/workspaces/{id}/query):
 * { tables: [{ name, columns: [{ name, type }], rows: [[...]] }] }.
 */
export interface LogAnalyticsResult {
  tables: Array<{
    name: string;
    columns: Array<{ name: string; type: string }>;
    rows: unknown[][];
  }>;
}

export interface LogAnalyticsBackend {
  query(kql: string, timespan?: string): Promise<LogAnalyticsResult>;
}

/** LOCAL: committed fixture shaped like the real API (KQL is recorded, not executed). */
export class FixtureLogAnalyticsBackend implements LogAnalyticsBackend {
  async query(_kql: string, _timespan?: string): Promise<LogAnalyticsResult> {
    return readFixture("log-analytics.json") as LogAnalyticsResult;
  }
}

/** L8: Azure Monitor Log Analytics workspace (mls LAW). Implemented at L8. */
export class AzureLogAnalyticsBackend implements LogAnalyticsBackend {
  constructor(readonly workspaceId: string) {}
  query(_kql: string, _timespan?: string): Promise<LogAnalyticsResult> {
    return Promise.reject(
      new Error("AzureLogAnalyticsBackend is implemented at L8 (needs the tenant)"),
    );
  }
}

/* ------------------------------------------------------------------ */
/* get_github_security                                                 */
/* ------------------------------------------------------------------ */

/**
 * Shape: GitHub REST security endpoints —
 * dependabot_alerts:    GET /repos/{owner}/{repo}/dependabot/alerts items
 * code_scanning_alerts: GET /repos/{owner}/{repo}/code-scanning/alerts items
 */
export interface GithubSecurityResult {
  dependabot_alerts: Array<Record<string, unknown>>;
  code_scanning_alerts: Array<Record<string, unknown>>;
}

export interface GithubSecurityBackend {
  getAlerts(alertType: "dependabot" | "code_scanning" | "all"): Promise<GithubSecurityResult>;
}

/** LOCAL: committed fixture shaped like the GitHub REST API responses. */
export class FixtureGithubSecurityBackend implements GithubSecurityBackend {
  async getAlerts(
    alertType: "dependabot" | "code_scanning" | "all",
  ): Promise<GithubSecurityResult> {
    const all = readFixture("github-security.json") as GithubSecurityResult;
    return {
      dependabot_alerts: alertType === "code_scanning" ? [] : all.dependabot_alerts,
      code_scanning_alerts: alertType === "dependabot" ? [] : all.code_scanning_alerts,
    };
  }
}

/** L9 wiring: live GitHub Security REST API for paulcfuqua/azure-devsecops. Implemented at L8/L9. */
export class LiveGithubSecurityBackend implements GithubSecurityBackend {
  constructor(readonly repo: string) {}
  getAlerts(): Promise<GithubSecurityResult> {
    return Promise.reject(
      new Error("LiveGithubSecurityBackend is implemented at L8/L9 (needs repo token wiring)"),
    );
  }
}

/* ------------------------------------------------------------------ */
/* get_defender_posture                                                */
/* ------------------------------------------------------------------ */

/**
 * Shape: Microsoft Defender for Cloud —
 * secure_score: Microsoft.Security/secureScores ("ascScore") resource,
 * controls:     Microsoft.Security/secureScores/secureScoreControls list.
 */
export interface DefenderPostureResult {
  secure_score: Record<string, unknown>;
  controls: { value: Array<Record<string, unknown>> };
}

export interface DefenderPostureBackend {
  getPosture(): Promise<DefenderPostureResult>;
}

/** LOCAL: committed fixture shaped like the ARM secureScores API. */
export class FixtureDefenderPostureBackend implements DefenderPostureBackend {
  async getPosture(): Promise<DefenderPostureResult> {
    return readFixture("defender-posture.json") as DefenderPostureResult;
  }
}

/** L8/L9: Microsoft Defender for Cloud ARM API. Implemented at L8. */
export class AzureDefenderPostureBackend implements DefenderPostureBackend {
  constructor(readonly subscriptionId: string) {}
  getPosture(): Promise<DefenderPostureResult> {
    return Promise.reject(
      new Error("AzureDefenderPostureBackend is implemented at L8 (needs the tenant)"),
    );
  }
}

/* ------------------------------------------------------------------ */
/* get_cost_series                                                     */
/* ------------------------------------------------------------------ */

/**
 * Shape: Azure Cost Management query response
 * (POST .../providers/Microsoft.CostManagement/query):
 * { id, name, type, properties: { columns: [{ name, type }], rows } }.
 * Locally the rows come from Track A's cost_daily table.
 */
export interface CostSeriesResult {
  id: string;
  name: string;
  type: "Microsoft.CostManagement/query";
  properties: {
    columns: Array<{ name: string; type: string }>;
    rows: Array<[string, string, number, number]>; // [date, cost_center, amount_usd, budget_usd]
  };
}

export interface CostSeriesParams {
  start_date?: string;
  end_date?: string;
  cost_center?: string;
}

export interface CostSeriesBackend {
  getSeries(params: CostSeriesParams): Promise<CostSeriesResult>;
}

/** LOCAL: reads cost_daily from the generated lakehouse data (real filtering). */
export class LocalCostSeriesBackend implements CostSeriesBackend {
  async getSeries(params: CostSeriesParams): Promise<CostSeriesResult> {
    const clauses: string[] = [];
    const esc = (v: string) => v.replaceAll("'", "''");
    if (params.start_date) clauses.push(`date >= '${esc(params.start_date)}'`);
    if (params.end_date) clauses.push(`date <= '${esc(params.end_date)}'`);
    if (params.cost_center) clauses.push(`cost_center = '${esc(params.cost_center)}'`);
    const where = clauses.length > 0 ? ` WHERE ${clauses.join(" AND ")}` : "";
    const result = await queryLakehouse(
      `SELECT date, cost_center, SUM(amount_usd) AS amount_usd, SUM(budget_usd) AS budget_usd
       FROM cost_daily${where}
       GROUP BY date, cost_center
       ORDER BY date, cost_center`,
    );
    return {
      id: "local/cost_daily",
      name: "cost_daily",
      type: "Microsoft.CostManagement/query",
      properties: {
        columns: [
          { name: "date", type: "String" },
          { name: "cost_center", type: "String" },
          { name: "amount_usd", type: "Number" },
          { name: "budget_usd", type: "Number" },
        ],
        rows: result.rows as Array<[string, string, number, number]>,
      },
    };
  }
}

/** L8: Azure Cost Management query API over the demo subscription. Implemented at L8. */
export class AzureCostSeriesBackend implements CostSeriesBackend {
  constructor(readonly scope: string) {}
  getSeries(_params: CostSeriesParams): Promise<CostSeriesResult> {
    return Promise.reject(
      new Error("AzureCostSeriesBackend is implemented at L8 (needs the tenant)"),
    );
  }
}

/** The full backend set the tool registry runs against. */
export interface Backends {
  lakehouseSql: LakehouseSqlBackend;
  logAnalytics: LogAnalyticsBackend;
  githubSecurity: GithubSecurityBackend;
  defenderPosture: DefenderPostureBackend;
  costSeries: CostSeriesBackend;
}

/** Phase P default: all-local backends. */
export function createLocalBackends(): Backends {
  return {
    lakehouseSql: new LocalLakehouseSqlBackend(),
    logAnalytics: new FixtureLogAnalyticsBackend(),
    githubSecurity: new FixtureGithubSecurityBackend(),
    defenderPosture: new FixtureDefenderPostureBackend(),
    costSeries: new LocalCostSeriesBackend(),
  };
}
