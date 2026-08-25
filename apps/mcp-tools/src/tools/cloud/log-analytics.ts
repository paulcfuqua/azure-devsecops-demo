/**
 * `query_log_analytics` — CLOUD adapter: the Azure Monitor Log Analytics query
 * API.
 *
 *   POST https://api.loganalytics.io/v1/workspaces/{workspaceId}/query
 *   { "query": "<KQL>", "timespan": "P1D" }
 *   -> { "tables": [ { "name", "columns": [{name,type}], "rows": [[...]] } ] }
 *
 * The response shape IS the tool's contract — the committed fixture is a copy of
 * this envelope — so this adapter passes `tables` through untouched. Reshaping
 * it would be a breaking change to every agent that has read the description.
 *
 * Auth: managed identity, scope `https://api.loganalytics.io/.default`. The
 * identity needs `Log Analytics Reader` on the workspace.
 *
 * Pagination: THERE IS NONE. The query API has no continuation token; it has
 * caps instead (500k records / ~100 MB / 10 minutes). Paging is a KQL concern,
 * so the adapter's job is to bound the request honestly rather than to pretend
 * to page — `Prefer: wait=<seconds>` aligns the *server's* timeout with the
 * client deadline so a slow query fails in our budget rather than in Azure's.
 *
 * Two behaviours worth knowing, both from the documented API and both tested:
 *   - **A partial failure returns HTTP 200** carrying both `tables` and an
 *     `error` object with code `PartialError`. Checking only the status code
 *     would hand the agent a truncated result set as if it were complete.
 *   - **An empty workspace returns 204 No Content** with no body, which becomes
 *     `{ tables: [] }` rather than an error.
 */
import { AdapterError, redact } from "../errors.js";
import { extractUpstreamMessage, HttpClient, type FetchLike, type RetryPolicy } from "../http.js";
import { SCOPES, type TokenProvider } from "../auth.js";
import type { LogAnalyticsBackend, LogAnalyticsResult } from "../backends.js";

/**
 * `api.loganalytics.io` is the long-standing host; `api.loganalytics.azure.com`
 * is its documented successor and both are live. The default matches what the
 * committed fixture documents; override for the newer host or a sovereign cloud.
 */
export const DEFAULT_LOG_ANALYTICS_ENDPOINT = "https://api.loganalytics.io";

export interface AzureLogAnalyticsOptions {
  /** The workspace **GUID** (customerId), not its ARM resource id. */
  workspaceId: string;
  tokens: TokenProvider;
  endpoint?: string;
  fetchImpl?: FetchLike;
  retry?: Partial<RetryPolicy>;
  sleep?: (ms: number) => Promise<void>;
}

export class AzureLogAnalyticsBackend implements LogAnalyticsBackend {
  readonly workspaceId: string;
  private readonly endpoint: string;
  private readonly tokens: TokenProvider;
  private readonly http: HttpClient;
  private readonly serverWaitSeconds: number;

  constructor(options: AzureLogAnalyticsOptions) {
    this.workspaceId = options.workspaceId;
    this.endpoint = (options.endpoint ?? DEFAULT_LOG_ANALYTICS_ENDPOINT).replace(/\/+$/, "");
    this.tokens = options.tokens;
    this.http = new HttpClient({
      service: "log-analytics",
      ...(options.fetchImpl ? { fetchImpl: options.fetchImpl } : {}),
      ...(options.retry ? { retry: options.retry } : {}),
      ...(options.sleep ? { sleep: options.sleep } : {}),
    });
    // Keep the server's own deadline just inside ours so a long query comes back
    // as a clean 504 we can explain, not as a client-side abort with no detail.
    this.serverWaitSeconds = Math.max(
      5,
      Math.floor(((options.retry?.requestTimeoutMs ?? 20_000) - 2_000) / 1000),
    );
  }

  async query(kql: string, timespan?: string): Promise<LogAnalyticsResult> {
    if (typeof kql !== "string" || kql.trim().length === 0) {
      throw new AdapterError("bad_request", "query_log_analytics requires a non-empty 'query' string", {
        service: "log-analytics",
      });
    }

    const body: Record<string, unknown> = { query: kql };
    if (timespan !== undefined && String(timespan).trim().length > 0) {
      body.timespan = String(timespan).trim();
    }

    const response = await this.http.requestJson<{
      tables?: LogAnalyticsResult["tables"];
      error?: { code?: string; message?: string };
    }>({
      url: `${this.endpoint}/v1/workspaces/${encodeURIComponent(this.workspaceId)}/query`,
      method: "POST",
      headers: {
        ...(await this.tokens.authHeader(SCOPES.logAnalytics)),
        prefer: `wait=${this.serverWaitSeconds}`,
      },
      body,
    });

    // 200 + error === PartialError: some shards failed. Surfacing partial rows
    // as complete would let the agent state a wrong total with full confidence.
    if (response.body.error) {
      const detail = redact(extractUpstreamMessage(response.body, ""));
      throw new AdapterError(
        "upstream",
        `Log Analytics returned a partial result (${response.body.error.code ?? "PartialError"}): ` +
          `${detail}. Narrow the timespan or the query and try again — the rows that did come ` +
          `back are not a complete answer.`,
        { service: "log-analytics", status: response.status },
      );
    }

    // 204 No Content on an empty workspace.
    return { tables: response.body.tables ?? [] };
  }
}
