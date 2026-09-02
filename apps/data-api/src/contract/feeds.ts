/**
 * The served payload contract for `GET /feeds/:name`.
 *
 * Every interface below is copied **verbatim** from
 * `apps/control-tower/src/providers/types.ts`, which is the authority: the
 * control tower's `ApiProvider` casts this service's JSON straight to these
 * types and hands it to the spec builders. `tests/contract-parity.test.ts`
 * re-extracts them from that file and fails on drift.
 *
 * Each is a *subset* of the real upstream payload — that is deliberate on both
 * sides. The cloud adapters project the upstream response down to exactly
 * these fields rather than proxying it whole, for two reasons:
 *
 *   1. GitHub's raw run/alert payloads carry actor logins and profile URLs.
 *      Hard rule 4 (no real person's PII) makes forwarding them wrong even
 *      though the frontend would ignore them.
 *   2. A fixed projection is a contract. A pass-through would let an upstream
 *      schema change reach the browser unannounced.
 */

/** GitHub Actions — GET /repos/{owner}/{repo}/actions/runs (subset). */
export interface WorkflowRunsFeed {
  total_count: number;
  workflow_runs: WorkflowRun[];
}

export interface WorkflowRun {
  id: number;
  name: string;
  head_branch: string;
  event: string;
  status: string;
  conclusion: string | null;
  run_started_at: string;
  updated_at: string;
}

/** GitHub Security — GET /repos/{owner}/{repo}/code-scanning/alerts (subset). */
export interface CodeScanningAlert {
  number: number;
  state: string; // open | dismissed | fixed
  created_at: string;
  rule: {
    id: string;
    severity: string;
    security_severity_level?: string; // low | medium | high | critical
    description: string;
  };
  tool: { name: string };
  most_recent_instance?: { location?: { path?: string } };
}

/** GitHub Security — GET /repos/{owner}/{repo}/dependabot/alerts (subset). */
export interface DependabotAlert {
  number: number;
  state: string; // open | fixed | dismissed | auto_dismissed
  created_at: string;
  dependency: {
    package: { ecosystem: string; name: string };
    /**
     * Which manifest declares the vulnerable package. Carried because it is the
     * only thing that distinguishes an alert DELIBERATELY seeded for the demo
     * (apps/vuln-lab) from one that represents real exposure - and one of the two
     * open criticals is a seed (F154).
     */
    manifest_path: string | null;
  };
  security_advisory: {
    ghsa_id: string;
    cve_id: string | null;
    severity: string; // low | moderate | high | critical (GitHub uses "moderate")
    summary: string;
  };
}

/** Defender for Cloud — GET .../Microsoft.Security/secureScores (subset). */
export interface SecureScoreResponse {
  value: Array<{
    id: string;
    name: string;
    type: string;
    properties: {
      displayName: string;
      score: { max: number; current: number; percentage: number };
    };
  }>;
}

/** Defender for Cloud — GET .../secureScores/ascScore/secureScoreControls (subset). */
export interface SecureScoreControlsResponse {
  value: Array<{
    name: string;
    type: string;
    properties: {
      displayName: string;
      healthyResourceCount: number;
      unhealthyResourceCount: number;
      score: { max: number; current: number; percentage: number };
    };
  }>;
}

/** Log Analytics — POST /v1/workspaces/{id}/query response shape. */
export interface LogAnalyticsResult {
  tables: Array<{
    name: string;
    columns: Array<{ name: string; type: string }>;
    rows: Array<Array<string | number | boolean | null>>;
  }>;
}

/**
 * What the estate COSTS TO RUN, which is a different question from what the
 * fictional launch company spends.
 *
 * The lakehouse `cost_daily` table answers the second question: the generator
 * seeds it with a synthetic launch-programme budget (Propulsion, Avionics,
 * Range Operations), and even once the real Cost Management export lands,
 * cost-ingest aggregates it to a `costCenter` TAG whose demo values are those
 * same fictional business units. Real Azure money arrives wearing a costume.
 *
 * This feed asks Cost Management directly and groups by what actually incurs
 * the charge - the Azure service and the resource group - so the Ops tab can
 * say "Container Apps cost this much" rather than "Propulsion cost this much".
 *
 * `asOf` and `stale` are part of the contract, not decoration: the query API is
 * aggressively throttled (429 on four consecutive calls while this was being
 * written), so the backend caches and may serve a cached answer. A reader must
 * be able to tell a current figure from a retained one.
 */
export interface AzureCostFeed {
  /** ISO-8601 instant the underlying query was answered. */
  asOf: string;
  /** True when the upstream refused and this is a retained earlier answer. */
  stale: boolean;
  /** Billing currency reported by Cost Management, e.g. "USD". */
  currency: string;
  /** Total actual cost over the window, in `currency`. */
  total: number;
  /** The window these figures cover, as Cost Management was asked for it. */
  timeframe: string;
  /** Cost per Azure service - "Azure Container Apps", "Azure SQL Database". */
  byService: Array<{ name: string; cost: number }>;
  /** Cost per resource group - platform / apps / data / ops. */
  byResourceGroup: Array<{ name: string; cost: number }>;
  /** Daily totals across every service, oldest first. */
  daily: Array<{ date: string; cost: number }>;
}

/** Any feed payload, as served. */
export type FeedPayload =
  | WorkflowRunsFeed
  | CodeScanningAlert[]
  | DependabotAlert[]
  | SecureScoreResponse
  | SecureScoreControlsResponse
  | LogAnalyticsResult
  | AzureCostFeed;
