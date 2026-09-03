import type { Spec } from "@mls/spec-renderer";

/**
 * The control-tower data contract — the L7/L9 wiring boundary.
 *
 * A provider turns raw feed payloads into ready-to-render `@mls/spec-renderer`
 * specs for the three Well-Architected posture tabs; the React components stay
 * dumb and only ever see a `Spec`. Two implementations exist:
 *
 * - `LocalProvider` — local mode (Phase P default in dev): Dev + Sec tabs read
 *   committed fixtures in `src/fixtures/` (shaped after the real feeds below);
 *   the Ops tab reads Track A generator output from `data/generated/`.
 * - `ApiProvider` — live mode: the control-tower backend proxies the real
 *   feeds (GitHub Actions/Security APIs, Defender for Cloud secure score,
 *   Log Analytics, and the Cost Management export landed in the lakehouse).
 *
 * Both share the pure spec builders in `specs.ts`, so swapping providers at
 * L7/L9 changes only where payloads come from — never what the UI renders.
 */
export interface DataProvider {
  /** Human-readable data origin, surfaced in the app footer. */
  readonly source: string;
  /** Dev tab — delivery: CI pipeline health + request success rate. */
  getDevSpec(): Promise<Spec>;
  /** Sec tab — security: GitHub Security alerts + Defender secure score. */
  getSecSpec(): Promise<Spec>;
  /** Ops tab — cost & reliability: cost exports + flight telemetry. */
  getOpsSpec(): Promise<Spec>;
}

/** Loads one generated table's JSON by name (e.g. "cost_daily"). Injectable for tests. */
export type JsonLoader = (table: string) => Promise<unknown>;

/*
 * Feed shapes below mirror the real interfaces the master plan wires at
 * L7/L9. Fields the demo does not render are omitted; enum-ish fields are
 * typed as plain strings and normalized in the builders, because live feeds
 * evolve.
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
  /**
   * When the finding was CLOSED, if it has been. Carried so the board can show
   * posture over time rather than a backlog: 323 of this repository's 411 code
   * scanning findings are closed, and a panel that only counts `open` reports
   * the 88 and silently discards the work (F166).
   */
  fixed_at?: string | null;
  dismissed_at?: string | null;
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
     * The only field that distinguishes a DELIBERATELY seeded alert
     * (apps/vuln-lab) from real exposure - one of the two open criticals is a
     * seed (F154). Kept in step with apps/data-api/src/contract/feeds.ts, which
     * is the same shape declared twice; a mismatch here is silent until a field
     * the board reads arrives undefined.
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

/** Cost Management export landed in the lakehouse (Track A generator shape). */
/**
 * WHAT THE ESTATE COSTS TO RUN - the Ops tab's subject (F117).
 *
 * This replaced `CostDailyRow` and `TelemetrySummaryRow`, and the replacement is
 * the point rather than a refactor. Those two described the FICTIONAL launch
 * company: a synthetic programme budget split across Propulsion, Avionics and
 * Range Operations, and flight telemetry with max-Q and MECO times. Rendering
 * them on a tab titled Ops invited a reader to think they were looking at what
 * the platform costs and how it behaves. They were looking at set dressing.
 *
 * Cost Management answers the real question, grouped by what actually incurs the
 * charge - the Azure service and the resource group. Note that fixing the lakehouse
 * table instead would not have been enough: cost-ingest aggregates even genuine
 * Cost Management rows onto a `costCenter` TAG whose demo values are those same
 * fictional business units, so real Azure money still arrives wearing a costume.
 *
 * `asOf` and `stale` are load-bearing, not decoration: the query API is throttled
 * and data-api caches, so a reader must be able to tell a current figure from a
 * retained one.
 */
export interface AzureCostFeed {
  asOf: string;
  stale: boolean;
  currency: string;
  total: number;
  timeframe: string;
  byService: Array<{ name: string; cost: number }>;
  byResourceGroup: Array<{ name: string; cost: number }>;
  daily: Array<{ date: string; cost: number }>;
}

/** Everything the Dev + Sec tabs consume — fixture-backed in local mode. */
export interface FeedBundle {
  workflowRuns: WorkflowRunsFeed;
  appRequests: LogAnalyticsResult;
  codeScanningAlerts: CodeScanningAlert[];
  dependabotAlerts: DependabotAlert[];
  secureScore: SecureScoreResponse;
  secureScoreControls: SecureScoreControlsResponse;
  azureCost: AzureCostFeed;
}
