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
  dependency: { package: { ecosystem: string; name: string } };
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

/** Any feed payload, as served. */
export type FeedPayload =
  | WorkflowRunsFeed
  | CodeScanningAlert[]
  | DependabotAlert[]
  | SecureScoreResponse
  | SecureScoreControlsResponse
  | LogAnalyticsResult;
