/**
 * CLOUD backends — the demo path.
 *
 * Tables: Azure SQL for the operational seven, the Fabric lakehouse SQL
 * analytics endpoint for the analytical three (see `TABLE_STORE`). One
 * `SqlClient` per store, both authenticating with the same managed identity.
 *
 * Feeds: the live GitHub Actions / code scanning / Dependabot APIs, the
 * Defender for Cloud secure-score ARM APIs, and the Log Analytics query API.
 * Each upstream response is *projected* onto the contract in `contract/feeds.ts`
 * rather than proxied — see the header of that file for why (PII, and pinning
 * the schema).
 *
 * Every network detail that could identify a credential — token, connection
 * string, response body — stays inside `ApiError.detail`, which is logged
 * redacted and never serialized to a caller.
 */
import type { FeedName, TableName, TableStore } from "../contract/allowlist.js";
import { TABLE_STORE } from "../contract/allowlist.js";
import type {
  CodeScanningAlert,
  DependabotAlert,
  FeedPayload,
  LogAnalyticsResult,
  SecureScoreControlsResponse,
  SecureScoreResponse,
  WorkflowRun,
  WorkflowRunsFeed,
} from "../contract/feeds.js";
import { normalizeRows } from "../contract/normalize.js";
import type { CloudConfig } from "../config.js";
import { ApiError } from "../errors.js";
import { SCOPE_ARM, SCOPE_LOG_ANALYTICS, type TokenProvider } from "./azureAuth.js";
import { fetchJson, type FetchLike } from "./http.js";
import type { SqlClient } from "./sql.js";
import type { BackendKind, FeedsBackend, TableResult, TablesBackend } from "./types.js";

/* ------------------------------------------------------------------ */
/* tables                                                              */
/* ------------------------------------------------------------------ */

export class CloudTablesBackend implements TablesBackend {
  readonly kind: BackendKind = "cloud";

  constructor(private readonly clients: Record<TableStore, SqlClient>) {}

  async getTable(table: TableName, limit: number): Promise<TableResult> {
    const client = this.clients[TABLE_STORE[table]];
    // Ask for one more row than the cap: that is how truncation is *detected*
    // rather than assumed, without a second COUNT(*) round trip.
    const raw = await client.select(table, limit + 1);
    const truncated = raw.length > limit;
    return {
      rows: normalizeRows(table, truncated ? raw.slice(0, limit) : raw),
      truncated,
    };
  }
}

/* ------------------------------------------------------------------ */
/* feeds                                                               */
/* ------------------------------------------------------------------ */

/** Upper bound on items in any feed response, independent of upstream paging. */
export const MAX_FEED_ITEMS = 500;

/**
 * The Dev tab reads `PrimaryResult` with these four columns; the KQL is a
 * constant here because it is part of the contract, not a knob. `bin()` at one
 * day matches the daily series the chart draws.
 */
export const APP_REQUESTS_KQL = [
  "AppRequests",
  "| summarize RequestCount = count(), FailedCount = countif(Success == false)",
  "    by bin(TimeGenerated, 1d), AppRoleName",
  "| project TimeGenerated, AppRoleName, RequestCount, FailedCount",
  "| order by TimeGenerated asc, AppRoleName asc",
].join("\n");

export interface CloudFeedsDeps {
  readonly config: CloudConfig;
  readonly tokens: TokenProvider;
  readonly fetchImpl?: FetchLike;
}

export class CloudFeedsBackend implements FeedsBackend {
  readonly kind: BackendKind = "cloud";

  constructor(private readonly deps: CloudFeedsDeps) {}

  getFeed(name: FeedName): Promise<FeedPayload> {
    switch (name) {
      case "workflow-runs":
        return this.workflowRuns();
      case "code-scanning-alerts":
        return this.codeScanningAlerts();
      case "dependabot-alerts":
        return this.dependabotAlerts();
      case "secure-score":
        return this.secureScore();
      case "secure-score-controls":
        return this.secureScoreControls();
      case "app-requests":
        return this.appRequests();
    }
  }

  /* --- GitHub ---------------------------------------------------- */

  private githubHeaders(): Record<string, string> {
    const token = this.deps.config.githubToken;
    if (!token) {
      // Fail closed and say what is missing, without naming a secret value.
      throw ApiError.notConfigured(
        "The GitHub feeds require a repository token (injected as a Container Apps " +
          "secret reference from Key Vault, resolved by this app's managed identity). " +
          "MLS_GITHUB_TOKEN is empty on this instance",
      );
    }
    return {
      authorization: `Bearer ${token}`,
      accept: "application/vnd.github+json",
      "x-github-api-version": "2022-11-28",
      "user-agent": "mls-data-api",
    };
  }

  private github<T>(path: string): Promise<T> {
    const headers = this.githubHeaders();
    return fetchJson<T>({
      url: `${this.deps.config.githubApiBase}${path}`,
      headers,
      timeoutMs: this.deps.config.upstreamTimeoutMs,
      label: "GitHub",
      ...(this.deps.fetchImpl ? { fetchImpl: this.deps.fetchImpl } : {}),
    });
  }

  private async workflowRuns(): Promise<WorkflowRunsFeed> {
    const raw = await this.github<unknown>(
      `/repos/${this.deps.config.githubRepo}/actions/runs?per_page=100`,
    );
    return projectWorkflowRuns(raw);
  }

  private async codeScanningAlerts(): Promise<CodeScanningAlert[]> {
    const raw = await this.github<unknown>(
      `/repos/${this.deps.config.githubRepo}/code-scanning/alerts?state=open&per_page=100`,
    );
    return projectCodeScanningAlerts(raw);
  }

  private async dependabotAlerts(): Promise<DependabotAlert[]> {
    const raw = await this.github<unknown>(
      `/repos/${this.deps.config.githubRepo}/dependabot/alerts?state=open&per_page=100`,
    );
    return projectDependabotAlerts(raw);
  }

  /* --- Defender for Cloud (ARM) ---------------------------------- */

  private async arm<T>(path: string): Promise<T> {
    const token = await this.deps.tokens.getToken(SCOPE_ARM);
    return fetchJson<T>({
      url: `${this.deps.config.armBase}${path}`,
      headers: { authorization: `Bearer ${token}` },
      timeoutMs: this.deps.config.upstreamTimeoutMs,
      label: "Defender for Cloud",
      ...(this.deps.fetchImpl ? { fetchImpl: this.deps.fetchImpl } : {}),
    });
  }

  private async secureScore(): Promise<SecureScoreResponse> {
    const raw = await this.arm<unknown>(
      `/subscriptions/${this.deps.config.defenderSubscriptionId}` +
        "/providers/Microsoft.Security/secureScores?api-version=2020-01-01",
    );
    return projectSecureScore(raw);
  }

  private async secureScoreControls(): Promise<SecureScoreControlsResponse> {
    const raw = await this.arm<unknown>(
      `/subscriptions/${this.deps.config.defenderSubscriptionId}` +
        "/providers/Microsoft.Security/secureScores/ascScore/secureScoreControls" +
        "?api-version=2020-01-01&$expand=definition",
    );
    return projectSecureScoreControls(raw);
  }

  /* --- Log Analytics --------------------------------------------- */

  private async appRequests(): Promise<LogAnalyticsResult> {
    const token = await this.deps.tokens.getToken(SCOPE_LOG_ANALYTICS);
    const raw = await fetchJson<unknown>({
      url: `${this.deps.config.logAnalyticsBase}/v1/workspaces/${this.deps.config.logAnalyticsWorkspaceId}/query`,
      method: "POST",
      headers: { authorization: `Bearer ${token}` },
      body: {
        query: APP_REQUESTS_KQL,
        timespan: this.deps.config.logAnalyticsTimespan,
      },
      timeoutMs: this.deps.config.upstreamTimeoutMs,
      label: "Log Analytics",
      ...(this.deps.fetchImpl ? { fetchImpl: this.deps.fetchImpl } : {}),
    });
    return projectLogAnalytics(raw);
  }
}

/* ------------------------------------------------------------------ */
/* projections — pure, exported, unit-tested against recorded payloads */
/* ------------------------------------------------------------------ */

function obj(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function arr(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function str(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value : fallback;
}

function optionalStr(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function num(value: unknown, fallback = 0): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return fallback;
}

export function projectWorkflowRuns(raw: unknown): WorkflowRunsFeed {
  const source = obj(raw);
  const runs = arr(source.workflow_runs)
    .slice(0, MAX_FEED_ITEMS)
    .map((entry): WorkflowRun => {
      const run = obj(entry);
      return {
        id: num(run.id),
        name: str(run.name),
        head_branch: str(run.head_branch),
        event: str(run.event),
        status: str(run.status),
        conclusion: optionalStr(run.conclusion),
        run_started_at: str(run.run_started_at),
        updated_at: str(run.updated_at),
      };
    });
  return { total_count: num(source.total_count, runs.length), workflow_runs: runs };
}

export function projectCodeScanningAlerts(raw: unknown): CodeScanningAlert[] {
  return arr(raw)
    .slice(0, MAX_FEED_ITEMS)
    .map((entry): CodeScanningAlert => {
      const alert = obj(entry);
      const rule = obj(alert.rule);
      const severityLevel = optionalStr(rule.security_severity_level);
      const path = optionalStr(obj(obj(alert.most_recent_instance).location).path);
      return {
        number: num(alert.number),
        state: str(alert.state),
        created_at: str(alert.created_at),
        rule: {
          id: str(rule.id),
          severity: str(rule.severity),
          ...(severityLevel === null ? {} : { security_severity_level: severityLevel }),
          description: str(rule.description),
        },
        tool: { name: str(obj(alert.tool).name) },
        ...(path === null
          ? {}
          : { most_recent_instance: { location: { path } } }),
      };
    });
}

export function projectDependabotAlerts(raw: unknown): DependabotAlert[] {
  return arr(raw)
    .slice(0, MAX_FEED_ITEMS)
    .map((entry): DependabotAlert => {
      const alert = obj(entry);
      const pkg = obj(obj(alert.dependency).package);
      const advisory = obj(alert.security_advisory);
      return {
        number: num(alert.number),
        state: str(alert.state),
        created_at: str(alert.created_at),
        dependency: {
          package: { ecosystem: str(pkg.ecosystem), name: str(pkg.name) },
        },
        security_advisory: {
          ghsa_id: str(advisory.ghsa_id),
          cve_id: optionalStr(advisory.cve_id),
          severity: str(advisory.severity),
          summary: str(advisory.summary),
        },
      };
    });
}

export function projectSecureScore(raw: unknown): SecureScoreResponse {
  return {
    value: arr(obj(raw).value)
      .slice(0, MAX_FEED_ITEMS)
      .map((entry) => {
        const item = obj(entry);
        const properties = obj(item.properties);
        const score = obj(properties.score);
        return {
          id: str(item.id),
          name: str(item.name),
          type: str(item.type),
          properties: {
            displayName: str(properties.displayName),
            score: {
              max: num(score.max),
              current: num(score.current),
              percentage: num(score.percentage),
            },
          },
        };
      }),
  };
}

export function projectSecureScoreControls(raw: unknown): SecureScoreControlsResponse {
  return {
    value: arr(obj(raw).value)
      .slice(0, MAX_FEED_ITEMS)
      .map((entry) => {
        const item = obj(entry);
        const properties = obj(item.properties);
        const score = obj(properties.score);
        return {
          name: str(item.name),
          type: str(item.type),
          properties: {
            displayName: str(properties.displayName),
            healthyResourceCount: num(properties.healthyResourceCount),
            unhealthyResourceCount: num(properties.unhealthyResourceCount),
            score: {
              max: num(score.max),
              current: num(score.current),
              percentage: num(score.percentage),
            },
          },
        };
      }),
  };
}

export function projectLogAnalytics(raw: unknown): LogAnalyticsResult {
  return {
    tables: arr(obj(raw).tables).map((entry) => {
      const table = obj(entry);
      return {
        name: str(table.name),
        columns: arr(table.columns).map((column) => {
          const col = obj(column);
          return { name: str(col.name), type: str(col.type) };
        }),
        rows: arr(table.rows)
          .slice(0, MAX_FEED_ITEMS)
          .map((row) =>
            arr(row).map((cell) => {
              if (cell === null || cell === undefined) return null;
              if (
                typeof cell === "string" ||
                typeof cell === "number" ||
                typeof cell === "boolean"
              ) {
                return cell;
              }
              // Nested dynamic() values are not part of the contract's cell type.
              return JSON.stringify(cell);
            }),
          ),
      };
    }),
  };
}
