/**
 * `get_github_security` — CLOUD adapter: the GitHub Advanced Security REST API.
 *
 *   GET /repos/{owner}/{repo}/dependabot/alerts?state=open&per_page=100
 *   GET /repos/{owner}/{repo}/code-scanning/alerts?state=open&per_page=100
 *
 * Both endpoints return a bare JSON array of alert objects and paginate with an
 * RFC 8288 `Link: <…>; rel="next"` header. The adapter walks those pages and
 * assembles `{ dependabot_alerts, code_scanning_alerts }` — the same two-key
 * envelope the committed fixture carries, with the **alert items passed through
 * verbatim**. The tool description names fields inside those items
 * (`dependency.package.name`, `security_advisory.cve_id`, `rule.id`,
 * `most_recent_instance.location`), so re-projecting them would silently break
 * every question that reads one.
 *
 * Auth: a token from the environment (`GITHUB_TOKEN` / `MLS_GITHUB_TOKEN`),
 * needing the `security_events` scope (or `public_repo` for a public repo's
 * code-scanning alerts). GitHub has no managed-identity story — this is the one
 * upstream in the set that cannot use one — so the platform injects the token
 * and this process reads it once and never logs it.
 *
 * ── The one place this adapter is opinionated ────────────────────────────────
 * `GET /code-scanning/alerts` answers **404 `no analysis found`** on a repo where
 * CodeQL has never run. That is not an error the agent can act on, and it must
 * not blank out the Dependabot half of an `alert_type: "all"` call, so a 404 on
 * a family becomes an empty list for that family. A **403** is different — the
 * feature is disabled or the token lacks the scope, which is a real
 * configuration failure a human must fix — and propagates.
 */
import { AdapterError, isAdapterError } from "../errors.js";
import { HttpClient, pageByLinkHeader, type FetchLike, type RetryPolicy } from "../http.js";
import { githubAuthHeader } from "../auth.js";
import type { GithubSecurityBackend, GithubSecurityResult } from "../backends.js";

export const DEFAULT_GITHUB_API = "https://api.github.com";

/** Page size and the total-item ceiling per family — a tool result, not an export. */
export const GITHUB_PAGE_SIZE = 100;
export const GITHUB_MAX_ALERTS = 500;

export interface LiveGithubSecurityOptions {
  /** "owner/repo". */
  repo: string;
  /** Token from the environment. Never persisted, never logged. */
  token: string;
  apiBaseUrl?: string;
  fetchImpl?: FetchLike;
  retry?: Partial<RetryPolicy>;
  sleep?: (ms: number) => Promise<void>;
  /**
   * Alert states to fetch. Default `open`, matching the description's "open
   * right now"; the committed fixture also carries a `dismissed` code-scanning
   * alert, so `all` is available for parity checks and history questions.
   */
  state?: "open" | "all";
}

export class LiveGithubSecurityBackend implements GithubSecurityBackend {
  readonly repo: string;
  private readonly token: string;
  private readonly apiBaseUrl: string;
  private readonly http: HttpClient;
  private readonly state: "open" | "all";

  constructor(options: LiveGithubSecurityOptions) {
    if (!/^[^/\s]+\/[^/\s]+$/.test(options.repo ?? "")) {
      throw new AdapterError(
        "config",
        `get_github_security needs MLS_GITHUB_REPO in "owner/repo" form (got ${JSON.stringify(options.repo)})`,
        { service: "github" },
      );
    }
    this.repo = options.repo;
    this.token = options.token;
    this.apiBaseUrl = (options.apiBaseUrl ?? DEFAULT_GITHUB_API).replace(/\/+$/, "");
    this.state = options.state ?? "open";
    this.http = new HttpClient({
      service: "github",
      ...(options.fetchImpl ? { fetchImpl: options.fetchImpl } : {}),
      ...(options.retry ? { retry: options.retry } : {}),
      ...(options.sleep ? { sleep: options.sleep } : {}),
    });
  }

  async getAlerts(
    alertType: "dependabot" | "code_scanning" | "all",
  ): Promise<GithubSecurityResult> {
    // Both families in parallel when both are wanted: two independent upstreams,
    // and the agent is waiting.
    const [dependabot, codeScanning] = await Promise.all([
      alertType === "code_scanning" ? Promise.resolve([]) : this.fetchFamily("dependabot"),
      alertType === "dependabot" ? Promise.resolve([]) : this.fetchFamily("code-scanning"),
    ]);
    return { dependabot_alerts: dependabot, code_scanning_alerts: codeScanning };
  }

  private async fetchFamily(
    family: "dependabot" | "code-scanning",
  ): Promise<Array<Record<string, unknown>>> {
    const params = new URLSearchParams({
      per_page: String(GITHUB_PAGE_SIZE),
      ...(this.state === "open" ? { state: "open" } : {}),
    });
    const url = `${this.apiBaseUrl}/repos/${this.repo}/${family}/alerts?${params.toString()}`;
    try {
      return await pageByLinkHeader<Record<string, unknown>>(
        this.http,
        { url, headers: githubAuthHeader(this.token) },
        GITHUB_MAX_ALERTS,
      );
    } catch (err) {
      // "no analysis found" / feature never run => genuinely zero alerts.
      if (isAdapterError(err) && err.status === 404) return [];
      throw err;
    }
  }
}
