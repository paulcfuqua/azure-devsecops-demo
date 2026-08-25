/**
 * Backend adapters — one interface per tool, with two complete implementations:
 *
 *   - LOCAL (Phase P): real SQL over sql.js for the lakehouse, cost_daily-backed
 *     cost series, and committed fixtures (shaped like the real APIs) for Log
 *     Analytics / GitHub Security / Defender.
 *   - CLOUD (L5-L8): the Fabric lakehouse SQL analytics endpoint, Azure Monitor
 *     Log Analytics, the GitHub Security REST API, Defender for Cloud via ARM,
 *     and Azure Cost Management. Implementations live in ./cloud/ and are
 *     re-exported here so the import path callers use never changed.
 *
 * ── The contract that binds them ─────────────────────────────────────────────
 * **A cloud adapter returns byte-identical response SHAPES to its local
 * counterpart.** The agent's orchestrator reasons over those shapes, the tool
 * descriptions document them field by field, and the eval's fact walker walks
 * them — so a shape change is a breaking change to the agent, not a refactor.
 * `tests/shape-parity.test.ts` asserts this from one shared shape function, so
 * drift in either direction fails a test rather than a demo.
 *
 * The ONE thing that legitimately differs between the two sets is the SQL
 * dialect `query_lakehouse_sql` speaks (SQLite vs T-SQL), and it differs
 * visibly: each backend declares its `dialect` and the tool description is
 * generated from it. See src/tools/sql-dialect.ts for why that is a property of
 * the backend rather than a translation layer.
 */
import fs from "node:fs";
import path from "node:path";
import { fixturesDir } from "../config.js";
import { queryLakehouse, type LakehouseQueryResult } from "../data/lakehouse.js";
import type { SqlDialect } from "./sql-dialect.js";

function readFixture(name: string): unknown {
  const p = path.join(fixturesDir, name);
  return JSON.parse(fs.readFileSync(p, "utf-8"));
}

/* ------------------------------------------------------------------ */
/* query_lakehouse_sql                                                 */
/* ------------------------------------------------------------------ */

export interface LakehouseSqlBackend {
  /**
   * Which SQL dialect this backend accepts. Read by the tool registry to build
   * the agent-facing description, so the idioms advertised always match the
   * engine that will run the query.
   */
  readonly dialect: SqlDialect;
  /** Execute one read-only SQL statement; returns columns + capped rows. */
  query(sql: string): Promise<LakehouseQueryResult>;
}

/** LOCAL: sql.js (SQLite wasm) over data/generated/*.csv — real SQL execution. */
export class LocalLakehouseSqlBackend implements LakehouseSqlBackend {
  readonly dialect: SqlDialect = "sqlite";
  query(sql: string): Promise<LakehouseQueryResult> {
    return queryLakehouse(sql);
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

/* ------------------------------------------------------------------ */
/* Cloud adapters — implementations live in ./cloud/                   */
/* ------------------------------------------------------------------ */

export {
  FabricLakehouseSqlBackend,
  type TdsExecutor,
  type TdsQueryResult,
} from "./cloud/fabric-sql.js";
export { AzureLogAnalyticsBackend } from "./cloud/log-analytics.js";
export { LiveGithubSecurityBackend } from "./cloud/github-security.js";
export { AzureDefenderPostureBackend } from "./cloud/defender-posture.js";
export { AzureCostSeriesBackend } from "./cloud/cost-series.js";

/* ------------------------------------------------------------------ */
/* Backend sets                                                        */
/* ------------------------------------------------------------------ */

/** The full backend set the MCP tool registry runs against. */
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
