import type { Spec } from "@mls/spec-renderer";
import { buildDevSpec, buildOpsSpec, buildSecSpec } from "./specs";
import type {
  CodeScanningAlert,
  CostDailyRow,
  DataProvider,
  DependabotAlert,
  LogAnalyticsResult,
  SecureScoreControlsResponse,
  SecureScoreResponse,
  TelemetrySummaryRow,
  WorkflowRunsFeed,
} from "./types";

/**
 * Live-API provider — the L7/L9 wiring target.
 *
 * Contract: the control-tower backend proxies each upstream feed and returns
 * its payload unmodified in the shape documented in `types.ts`:
 *
 *   GET {baseUrl}/feeds/workflow-runs          -> GitHub Actions runs API
 *   GET {baseUrl}/feeds/code-scanning-alerts   -> GitHub code scanning API
 *   GET {baseUrl}/feeds/dependabot-alerts      -> GitHub Dependabot alerts API
 *   GET {baseUrl}/feeds/secure-score           -> Defender secure score API
 *   GET {baseUrl}/feeds/secure-score-controls  -> Defender secure score controls API
 *   GET {baseUrl}/feeds/app-requests           -> Log Analytics query API result
 *   GET {baseUrl}/tables/cost_daily            -> lakehouse cost export rows
 *   GET {baseUrl}/tables/telemetry_summary     -> lakehouse telemetry rows
 *
 * Because the local fixtures mirror the same interfaces, the spec builders
 * are shared verbatim with `LocalProvider`; wiring L7/L9 means deploying the
 * backend and selecting this provider, with no UI changes.
 */
export class ApiProvider implements DataProvider {
  readonly source: string;

  constructor(private readonly baseUrl: string = "/api") {
    this.source = `live feeds (${this.baseUrl})`;
  }

  private async get<T>(path: string): Promise<T> {
    const res = await fetch(`${this.baseUrl}/${path}`);
    if (!res.ok) {
      // PREFER THE SERVER'S OWN EXPLANATION over anything guessed here.
      //
      // data-api answers a failure with a typed envelope - {error:{code,message}} -
      // and its message is written at the point that actually knows what is wrong.
      // A 503 on the GitHub feeds says "The GitHub feeds require a repository token
      // ... MLS_GITHUB_TOKEN is empty on this instance", which names the fix. The
      // text this replaced said "the live feeds come online at L7/L9; before tenant
      // activation run the app in LOCAL_DATA mode" - advice that was true before the
      // tenant existed and misleading afterwards, because by the time anyone reads it
      // L7 IS deployed and they are being told to wait for something that already
      // happened, in an app that has no LOCAL_DATA build published.
      let detail = "";
      try {
        const body: unknown = await res.json();
        const message = (body as { error?: { message?: unknown } })?.error?.message;
        if (typeof message === "string" && message.length > 0) detail = ` ${message}`;
      } catch {
        // A non-JSON body means the proxy answered rather than data-api - the status
        // code is then the whole of what is known, and inventing a cause would be worse
        // than saying nothing.
      }
      throw new Error(`API ${this.baseUrl}/${path} responded ${res.status}.${detail}`);
    }
    return (await res.json()) as T;
  }

  async getDevSpec(): Promise<Spec> {
    const [runs, appRequests] = await Promise.all([
      this.get<WorkflowRunsFeed>("feeds/workflow-runs"),
      this.get<LogAnalyticsResult>("feeds/app-requests"),
    ]);
    return buildDevSpec(runs, appRequests);
  }

  async getSecSpec(): Promise<Spec> {
    const [codeAlerts, depAlerts, secureScore, controls] = await Promise.all([
      this.get<CodeScanningAlert[]>("feeds/code-scanning-alerts"),
      this.get<DependabotAlert[]>("feeds/dependabot-alerts"),
      this.get<SecureScoreResponse>("feeds/secure-score"),
      this.get<SecureScoreControlsResponse>("feeds/secure-score-controls"),
    ]);
    return buildSecSpec(codeAlerts, depAlerts, secureScore, controls);
  }

  async getOpsSpec(): Promise<Spec> {
    const [cost, telemetry] = await Promise.all([
      this.get<CostDailyRow[]>("tables/cost_daily"),
      this.get<TelemetrySummaryRow[]>("tables/telemetry_summary"),
    ]);
    return buildOpsSpec(cost, telemetry);
  }
}
