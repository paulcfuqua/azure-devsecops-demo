import type { Spec } from "@mls/spec-renderer";
import { buildDevSpec, buildOpsSpec, buildSecSpec, type FeedOutage } from "./specs";
import type {
  AzureCostFeed,
  CodeScanningAlert,
  DataProvider,
  DependabotAlert,
  LogAnalyticsResult,
  SecureScoreControlsResponse,
  SecureScoreResponse,
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
      const error = new Error(`API ${this.baseUrl}/${path} responded ${res.status}.${detail}`);
      // The notice already names the feed, so carry the reason separately rather
      // than repeating the path inside it.
      (error as Error & { reason?: string }).reason =
        `responded ${res.status}.${detail}`.trim();
      throw error;
    }
    return (await res.json()) as T;
  }

  /**
   * One feed's outcome: its value, or the reason it did not answer.
   *
   * THE POINT OF THIS (F116). These methods used `Promise.all`, which rejects on
   * the first failure and discards every sibling that had already resolved. With
   * the three GitHub feeds answering 503 for want of a token, the Dev tab threw
   * away the app-requests payload it was holding and rendered nothing at all -
   * five of eight routes were serving real data and the page showed none of it.
   */
  private async settle<T>(
    feed: string,
    work: Promise<T>,
  ): Promise<{ value: T | null; outage: FeedOutage | null; error: unknown }> {
    try {
      return { value: await work, outage: null, error: null };
    } catch (err) {
      const reason =
        (err as { reason?: string }).reason ??
        (err instanceof Error ? err.message : String(err));
      return { value: null, outage: { feed, reason }, error: err };
    }
  }

  /**
   * Partial data renders; no data throws.
   *
   * The distinction is deliberate. A tab holding SOME data should show it and
   * name what is missing. A tab holding NONE has nothing to be partial about,
   * and a page of "not reported" tiles would be a worse answer than the error
   * panel the app already knows how to display - so total failure keeps the old
   * behaviour and surfaces the first reason.
   */
  private static resolve(
    results: readonly { outage: FeedOutage | null; error: unknown }[],
  ): FeedOutage[] {
    const failed = results.filter((r) => r.outage !== null);
    if (failed.length === results.length) {
      // RETHROW THE ORIGINAL, rather than composing a summary from it. The first
      // error already carries the full path, the status and the server's own
      // explanation; anything rebuilt here is strictly less than that, and the
      // app's error panel is the only place a user will see it.
      throw failed[0]?.error instanceof Error
        ? failed[0].error
        : new Error(String(failed[0]?.error ?? "every feed failed"));
    }
    return failed.map((r) => r.outage as FeedOutage);
  }

  async getDevSpec(): Promise<Spec> {
    const [runs, appRequests] = await Promise.all([
      this.settle("feeds/workflow-runs", this.get<WorkflowRunsFeed>("feeds/workflow-runs")),
      this.settle("feeds/app-requests", this.get<LogAnalyticsResult>("feeds/app-requests")),
    ]);
    const outages = ApiProvider.resolve([runs, appRequests]);
    return buildDevSpec(runs.value, appRequests.value, outages);
  }

  async getSecSpec(): Promise<Spec> {
    const [codeAlerts, depAlerts, secureScore, controls] = await Promise.all([
      this.settle("feeds/code-scanning-alerts", this.get<CodeScanningAlert[]>("feeds/code-scanning-alerts")),
      this.settle("feeds/dependabot-alerts", this.get<DependabotAlert[]>("feeds/dependabot-alerts")),
      this.settle("feeds/secure-score", this.get<SecureScoreResponse>("feeds/secure-score")),
      this.settle("feeds/secure-score-controls", this.get<SecureScoreControlsResponse>("feeds/secure-score-controls")),
    ]);
    const outages = ApiProvider.resolve([codeAlerts, depAlerts, secureScore, controls]);
    return buildSecSpec(codeAlerts.value, depAlerts.value, secureScore.value, controls.value, outages);
  }

  async getOpsSpec(): Promise<Spec> {
    // ONE FEED, AND IT IS NOT THE LAKEHOUSE (F117). This read tables/cost_daily
    // and tables/telemetry_summary - the generator's synthetic launch-programme
    // budget and its flight telemetry. Both are fictional, and rendering them on
    // a tab called Ops invited the reader to think they were seeing what the
    // platform costs and how it behaves.
    const [cost] = await Promise.all([
      this.settle("feeds/azure-cost", this.get<AzureCostFeed>("feeds/azure-cost")),
    ]);
    const outages = ApiProvider.resolve([cost]);
    return buildOpsSpec(cost.value, outages);
  }
}
