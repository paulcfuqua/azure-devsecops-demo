/**
 * Runtime configuration.
 *
 * There is no LLM here and therefore no model, no API key and no prompt: this
 * process is an MCP server. The Copilot Studio agent owns all orchestration
 * (amendment 2026-08-24). The knobs are the listen port, which adapter set the
 * five tools run against, and — on the cloud set — where each upstream lives.
 *
 * ── Tenant activation is CONFIGURATION, not development ──────────────────────
 * `MLS_TOOL_BACKENDS=cloud` used to throw "not wired yet". It is now real: the
 * five cloud adapters are implemented, and turning them on is a matter of
 * setting the environment variables below. What this function still does is
 * **fail fast at boot with the complete list of what is missing**, rather than
 * letting the server start and produce five different runtime errors the first
 * time an agent asks a question on stage.
 *
 * ── No stored credentials (hard rule 5) ──────────────────────────────────────
 * Nothing here reads a password, a client secret or a connection string for
 * Azure. Every Azure upstream authenticates with the container app's managed
 * identity through `DefaultAzureCredential`; `AZURE_CLIENT_ID` merely SELECTS a
 * user-assigned identity, it is not a credential. The one bearer token in the
 * system is GitHub's, which has no managed-identity equivalent; it is injected
 * by the platform from Key Vault, held in memory, and never logged.
 */
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadInboundAuth, type InboundAuth } from "./auth-gate.js";

const here = path.dirname(fileURLToPath(import.meta.url));
/**
 * Package root. This module sits one level below it in both layouts —
 * `src/config.ts` (tsx/vitest) and `dist/config.js` (built image).
 */
export const packageRoot = path.resolve(here, "..");

/** Repo root: apps/mcp-tools -> repo. */
export const repoRoot = path.resolve(packageRoot, "..", "..");

/** Directory holding Track A's generated CSVs (gitignored; `python -m generators build`). */
export const generatedDataDir =
  process.env.MLS_DATA_DIR ?? path.join(repoRoot, "data", "generated");

/** Directory holding committed local fixtures for the non-SQL tools. */
export const fixturesDir = path.join(packageRoot, "fixtures");

/**
 * Task 8's committed compliance state artifact — the file query_compliance
 * answers from, baked into the image next to `fixtures/` (see Dockerfile).
 * Same path in every backend mode: query_compliance has no cloud/local split,
 * it always reads this bundled, read-only, offline artifact.
 */
export const complianceStatePath =
  process.env.MLS_COMPLIANCE_STATE_PATH ??
  path.join(repoRoot, "compliance", "state", "state-latest.json");

/**
 * Which adapter set the tools execute against.
 *   local — sql.js over data/generated + committed fixtures (Phase P, laptop).
 *   cloud — Fabric SQL analytics endpoint / Log Analytics / GitHub / Defender /
 *           Cost Management, all via managed identity (L5-L8, the tenant).
 */
export type BackendMode = "local" | "cloud";

/** Everything the cloud adapter set needs, resolved and validated. */
export interface CloudConfig {
  /** Fabric SQL analytics endpoint FQDN, e.g. `<guid>.datawarehouse.fabric.microsoft.com`. */
  fabricSqlEndpoint: string;
  /** The lakehouse (or warehouse) item name used as the initial catalog. */
  fabricDatabase: string;
  /** Log Analytics workspace GUID (customerId), not the ARM resource id. */
  logAnalyticsWorkspaceId: string;
  /** Optional override of the Log Analytics data-plane host. */
  logAnalyticsEndpoint: string | undefined;
  /** "owner/repo" for the GitHub Advanced Security reads. */
  githubRepo: string;
  /** GitHub token from the environment. Never logged, never persisted. */
  githubToken: string;
  /** Subscription whose Defender secure score is reported. */
  subscriptionId: string;
  /** Cost Management scope; defaults to the subscription. */
  costScope: string;
  /** Tag key carrying the cost center (CLAUDE.md mandates `costCenter`). */
  costCenterTag: string;
  /** Optional override of the ARM host (sovereign clouds, test doubles). */
  armEndpoint: string | undefined;
  /** User-assigned managed identity client id, when the app has more than one. */
  azureClientId: string | undefined;
}

export interface McpToolsConfig {
  port: number;
  backendMode: BackendMode;
  /** Present only when backendMode === "cloud". */
  cloud?: CloudConfig;
  /**
   * Who may call this server. Required in EVERY mode, not just cloud — the
   * container app's ingress is external by design regardless of backendMode,
   * so an unauthenticated endpoint exposes tenant reads and bills the
   * subscription on every call (F2: enforcement used to key off backendMode
   * and that was the defect). See auth-gate.ts.
   */
  inboundAuth: InboundAuth;
}

/** Env var -> what it is for, used to build the fail-fast message. */
const REQUIRED_CLOUD_VARS: Array<[string, string]> = [
  ["MLS_FABRIC_SQL_ENDPOINT", "Fabric SQL analytics endpoint FQDN for query_lakehouse_sql"],
  ["MLS_FABRIC_DATABASE", "Fabric lakehouse/warehouse name (initial catalog)"],
  ["MLS_LOG_ANALYTICS_WORKSPACE_ID", "Log Analytics workspace GUID for query_log_analytics"],
  ["MLS_GITHUB_REPO", 'GitHub repository as "owner/repo" for get_github_security'],
  ["GITHUB_TOKEN", "GitHub token with security_events scope (or MLS_GITHUB_TOKEN)"],
  ["AZURE_SUBSCRIPTION_ID", "subscription for get_defender_posture and get_cost_series"],
];

function firstNonEmpty(env: NodeJS.ProcessEnv, ...names: string[]): string | undefined {
  for (const name of names) {
    const value = env[name];
    if (typeof value === "string" && value.trim().length > 0) return value.trim();
  }
  return undefined;
}

/**
 * Resolve and validate the cloud settings, or throw one error naming every
 * missing variable at once — a boot that fails six times in a row while someone
 * adds one variable per attempt is a worse experience than a single list.
 */
export function loadCloudConfig(env: NodeJS.ProcessEnv): CloudConfig {
  const githubToken = firstNonEmpty(env, "GITHUB_TOKEN", "MLS_GITHUB_TOKEN");
  const resolved: Record<string, string | undefined> = {
    MLS_FABRIC_SQL_ENDPOINT: firstNonEmpty(env, "MLS_FABRIC_SQL_ENDPOINT"),
    MLS_FABRIC_DATABASE: firstNonEmpty(env, "MLS_FABRIC_DATABASE"),
    MLS_LOG_ANALYTICS_WORKSPACE_ID: firstNonEmpty(env, "MLS_LOG_ANALYTICS_WORKSPACE_ID"),
    MLS_GITHUB_REPO: firstNonEmpty(env, "MLS_GITHUB_REPO"),
    GITHUB_TOKEN: githubToken,
    AZURE_SUBSCRIPTION_ID: firstNonEmpty(env, "AZURE_SUBSCRIPTION_ID"),
  };

  const missing = REQUIRED_CLOUD_VARS.filter(([name]) => resolved[name] === undefined);
  if (missing.length > 0) {
    throw new Error(
      `MLS_TOOL_BACKENDS="cloud" is missing ${missing.length} required setting` +
        `${missing.length === 1 ? "" : "s"}:\n` +
        missing.map(([name, purpose]) => `  - ${name}: ${purpose}`).join("\n") +
        `\nEvery Azure upstream authenticates with the container app's managed identity ` +
        `(set AZURE_CLIENT_ID to select a user-assigned one); no Azure secret is read from ` +
        `the environment.`,
    );
  }

  const subscriptionId = resolved.AZURE_SUBSCRIPTION_ID as string;
  return {
    fabricSqlEndpoint: resolved.MLS_FABRIC_SQL_ENDPOINT as string,
    fabricDatabase: resolved.MLS_FABRIC_DATABASE as string,
    logAnalyticsWorkspaceId: resolved.MLS_LOG_ANALYTICS_WORKSPACE_ID as string,
    logAnalyticsEndpoint: firstNonEmpty(env, "MLS_LOG_ANALYTICS_ENDPOINT"),
    githubRepo: resolved.MLS_GITHUB_REPO as string,
    githubToken: githubToken as string,
    subscriptionId,
    costScope: firstNonEmpty(env, "MLS_COST_SCOPE") ?? `/subscriptions/${subscriptionId}`,
    costCenterTag: firstNonEmpty(env, "MLS_COST_CENTER_TAG") ?? "costCenter",
    armEndpoint: firstNonEmpty(env, "MLS_ARM_ENDPOINT"),
    azureClientId: firstNonEmpty(env, "AZURE_CLIENT_ID"),
  };
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): McpToolsConfig {
  const requested = env.MLS_TOOL_BACKENDS ?? "local";
  if (requested !== "local" && requested !== "cloud") {
    throw new Error(
      `MLS_TOOL_BACKENDS must be "local" or "cloud" (got: ${JSON.stringify(requested)})`,
    );
  }
  const port = env.PORT ? Number(env.PORT) : 8080;
  if (requested === "cloud") {
    // Order matters. loadCloudConfig reports EVERY missing upstream setting in one
    // message; running the auth gate first would pre-empt that with a single
    // unrelated error and reintroduce exactly the one-variable-per-attempt boot
    // loop this module exists to avoid. Auth is checked immediately after, and
    // gets its own message because it is a different kind of problem.
    const cloud = loadCloudConfig(env);
    return { port, backendMode: "cloud", cloud, inboundAuth: loadInboundAuth(env, "cloud") };
  }
  return { port, backendMode: "local", inboundAuth: loadInboundAuth(env, "local") };
}
