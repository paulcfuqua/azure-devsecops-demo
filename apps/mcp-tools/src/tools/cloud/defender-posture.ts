/**
 * `get_defender_posture` — CLOUD adapter: Microsoft Defender for Cloud via ARM.
 *
 *   GET /subscriptions/{sub}/providers/Microsoft.Security/secureScores/ascScore
 *   GET /subscriptions/{sub}/providers/Microsoft.Security/secureScores/ascScore
 *       /secureScoreControls?$expand=definition
 *
 * `ascScore` is the built-in, subscription-wide secure score initiative — the
 * one the portal shows — and the tool answers "current posture", so it is
 * addressed by name rather than by listing initiatives and guessing.
 *
 * The result is `{ secure_score, controls: { value: [...] } }`: the first
 * response verbatim, and the controls list re-wrapped in its `{ value }`
 * envelope after pagination is resolved. That is exactly the fixture's shape and
 * exactly what the tool description promises down to `properties.score.max`.
 *
 * Auth: managed identity, scope `https://management.azure.com/.default`. The
 * identity needs `Security Reader` (or `Reader`) on the subscription.
 *
 * Pagination: ARM's `{ value, nextLink }`. A subscription with many controls
 * pages at 100-ish; `pageByNextLink` follows `nextLink` verbatim because it
 * already carries the api-version and the continuation token.
 */
import { AdapterError } from "../errors.js";
import { HttpClient, pageByNextLink, type FetchLike, type RetryPolicy } from "../http.js";
import { SCOPES, type TokenProvider } from "../auth.js";
import type { DefenderPostureBackend, DefenderPostureResult } from "../backends.js";

export const DEFAULT_ARM_ENDPOINT = "https://management.azure.com";
/** Pinned: the GA version of Microsoft.Security/secureScores. */
export const SECURE_SCORES_API_VERSION = "2020-01-01";
/** A subscription has tens of controls; this ceiling exists to bound a bug, not a workload. */
export const MAX_CONTROLS = 500;

export interface AzureDefenderPostureOptions {
  subscriptionId: string;
  tokens: TokenProvider;
  armEndpoint?: string;
  fetchImpl?: FetchLike;
  retry?: Partial<RetryPolicy>;
  sleep?: (ms: number) => Promise<void>;
}

export class AzureDefenderPostureBackend implements DefenderPostureBackend {
  readonly subscriptionId: string;
  private readonly armEndpoint: string;
  private readonly tokens: TokenProvider;
  private readonly http: HttpClient;

  constructor(options: AzureDefenderPostureOptions) {
    if (!options.subscriptionId || options.subscriptionId.trim().length === 0) {
      throw new AdapterError(
        "config",
        "get_defender_posture needs AZURE_SUBSCRIPTION_ID to address the secure score",
        { service: "arm" },
      );
    }
    this.subscriptionId = options.subscriptionId.trim();
    this.armEndpoint = (options.armEndpoint ?? DEFAULT_ARM_ENDPOINT).replace(/\/+$/, "");
    this.tokens = options.tokens;
    this.http = new HttpClient({
      service: "arm",
      ...(options.fetchImpl ? { fetchImpl: options.fetchImpl } : {}),
      ...(options.retry ? { retry: options.retry } : {}),
      ...(options.sleep ? { sleep: options.sleep } : {}),
    });
  }

  private get scoreBase(): string {
    return (
      `${this.armEndpoint}/subscriptions/${encodeURIComponent(this.subscriptionId)}` +
      `/providers/Microsoft.Security/secureScores/ascScore`
    );
  }

  async getPosture(): Promise<DefenderPostureResult> {
    const headers = await this.tokens.authHeader(SCOPES.arm);

    // Both calls in parallel: independent reads, and the agent is waiting.
    const [score, controls] = await Promise.all([
      this.http.requestJson<Record<string, unknown>>({
        url: `${this.scoreBase}?api-version=${SECURE_SCORES_API_VERSION}`,
        headers,
      }),
      pageByNextLink<Record<string, unknown>>(
        this.http,
        {
          url:
            `${this.scoreBase}/secureScoreControls` +
            `?api-version=${SECURE_SCORES_API_VERSION}&$expand=definition`,
          headers,
        },
        MAX_CONTROLS,
      ),
    ]);

    return { secure_score: score.body, controls: { value: controls } };
  }
}
