/**
 * Runtime configuration — all of it from the environment, none of it secret.
 *
 * The one value that is credential-shaped is `MLS_GITHUB_TOKEN`, and it is read
 * here only as a value the platform injected (a Container Apps secret reference
 * resolved from Key Vault by the app's managed identity). Nothing in this repo
 * or in CI ever holds it, it is never logged, and it is optional: without it
 * the three GitHub feeds fail closed with a typed error and /healthz says so.
 * Everything else that authenticates does so with @azure/identity — hard rule 5.
 */
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));

/** Package root. This module sits one level below it in both layouts. */
export const packageRoot = path.resolve(here, "..");

/** Repo root: apps/data-api -> repo. */
export const repoRoot = path.resolve(packageRoot, "..", "..");

/**
 * Which adapter set serves the routes.
 *   local — data/generated JSON + committed fixtures. A test harness: it is
 *           what the vitest suite runs against and what a developer without a
 *           tenant sees. It is not the product.
 *   cloud — Azure SQL (operational tables), the Fabric lakehouse SQL analytics
 *           endpoint (analytical tables) and the live GitHub / Defender /
 *           Log Analytics APIs (feeds). This is the demo path.
 */
export type BackendMode = "local" | "cloud";

export interface CloudConfig {
  /** Azure SQL logical server FQDN, e.g. mls-ops-demo-sql.database.windows.net. */
  readonly sqlServer: string;
  readonly sqlDatabase: string;
  /** Fabric workspace SQL analytics endpoint FQDN. */
  readonly fabricEndpoint: string;
  /** Lakehouse name exposed as a database on that endpoint, e.g. mls_operations. */
  readonly fabricDatabase: string;
  /** owner/repo the three GitHub feeds read. */
  readonly githubRepo: string;
  readonly githubApiBase: string;
  /** Injected by the platform from Key Vault; absent = GitHub feeds fail closed. */
  readonly githubToken: string | undefined;
  /** Subscription the Defender secure score is read for. */
  readonly defenderSubscriptionId: string;
  /**
   * Billing scope for the azure-cost feed. Separate from the Defender
   * subscription rather than reusing it: Defender posture is always read at a
   * subscription, but cost is legitimately read at a billing account or
   * management group, and an estate that later bills across two subscriptions
   * should not have to redefine what "the Defender subscription" means to move
   * its cost query. Defaults to the Defender subscription so nothing has to be
   * set twice today.
   */
  readonly costSubscriptionId: string;
  /** Window the cost query asks for, a Cost Management timeframe name. */
  readonly costTimeframe: string;
  /** How long an answered cost query is retained before re-asking. */
  readonly costCacheSeconds: number;
  readonly armBase: string;
  /** Log Analytics workspace *customer id* (GUID), not the ARM resource id. */
  readonly logAnalyticsWorkspaceId: string;
  readonly logAnalyticsBase: string;
  /** Timespan for the app-requests query, ISO-8601 duration. */
  readonly logAnalyticsTimespan: string;
  /** User-assigned managed identity client id, when one is assigned. */
  readonly managedIdentityClientId: string | undefined;
  /** Per-call upstream timeout, milliseconds. */
  readonly upstreamTimeoutMs: number;
}

export interface TelemetryConfig {
  /** Azure Monitor / App Insights connection string. Absent = OTel no-ops. */
  readonly connectionString: string | undefined;
  readonly serviceName: string;
  readonly serviceVersion: string;
  /** Head sampling ratio, 0..1. */
  readonly sampleRatio: number;
  /**
   * User-assigned managed identity client id (F4, Task 8). Set, it selects
   * the identity granted 'Monitoring Metrics Publisher' on the App Insights
   * component (infra/bicep/apps/main.bicep's dataApiAppInsightsGrant), which
   * the exporter needs now that platform/main.bicep sets
   * `disableLocalAuth: true` there. Absent (a laptop with no managed
   * identity), the exporter presents no credential at all — see
   * telemetry/otel.ts's `startTelemetry` for why that is the right default
   * rather than falling through to an ambient `az login` session.
   */
  readonly managedIdentityClientId: string | undefined;
}

export interface DataApiConfig {
  readonly port: number;
  readonly backendMode: BackendMode;
  /**
   * Path prefix the two data routes are mounted under, normalised to either
   * "" or "/something" with no trailing slash.
   *
   * Both frontends' `ApiProvider` defaults to `baseUrl = "/api"`, so in a
   * same-origin deployment the browser asks for `/api/tables/launches`. If a
   * reverse proxy forwards `/api/*` to this service *without* stripping the
   * prefix — the default for `proxy_pass` without a trailing slash — this is
   * what makes the request land. `/healthz` is always at the root, because
   * that is where the platform's probe looks.
   */
  readonly routePrefix: string;
  /** Exact origins allowed to call this API cross-site. Empty = same-origin only. */
  readonly allowedOrigins: readonly string[];
  /** Hard ceiling on rows returned by /tables/:table, whatever the caller asks. */
  readonly maxRows: number;
  readonly tableCacheSeconds: number;
  readonly feedCacheSeconds: number;
  readonly generatedDataDir: string;
  readonly fixturesDir: string;
  /**
   * Build marker echoed on /healthz so L7's V7.1 can bind "endpoint is up" to
   * "endpoint serves the audited build".
   */
  readonly build: string;
  readonly telemetry: TelemetryConfig;
  /** Present only in cloud mode. */
  readonly cloud: CloudConfig | undefined;
}

const GUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

const DEFAULT_MAX_ROWS = 10_000;
const DEFAULT_TABLE_CACHE_SECONDS = 60;
const DEFAULT_FEED_CACHE_SECONDS = 30;
const DEFAULT_UPSTREAM_TIMEOUT_MS = 20_000;

function str(env: NodeJS.ProcessEnv, key: string): string | undefined {
  const raw = env[key];
  if (raw === undefined) return undefined;
  const trimmed = raw.trim();
  return trimmed === "" ? undefined : trimmed;
}

function int(
  env: NodeJS.ProcessEnv,
  key: string,
  fallback: number,
  min: number,
  max: number,
): number {
  const raw = str(env, key);
  if (raw === undefined) return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new Error(
      `${key} must be an integer between ${min} and ${max} (got: ${JSON.stringify(raw)})`,
    );
  }
  return value;
}

function ratio(env: NodeJS.ProcessEnv, key: string, fallback: number): number {
  const raw = str(env, key);
  if (raw === undefined) return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < 0 || value > 1) {
    throw new Error(`${key} must be a number between 0 and 1 (got: ${JSON.stringify(raw)})`);
  }
  return value;
}

/**
 * CORS origins. Exact-match only — no wildcards, no suffix matching, no
 * regex. The two app origins are known at deploy time (they are the container
 * apps' FQDNs), so anything looser is a gift to an attacker for no benefit.
 */
function parseOrigins(env: NodeJS.ProcessEnv): string[] {
  const raw = str(env, "MLS_ALLOWED_ORIGINS");
  if (raw === undefined) return [];
  const origins: string[] = [];
  for (const piece of raw.split(",")) {
    const candidate = piece.trim().replace(/\/+$/, "");
    if (candidate === "") continue;
    if (candidate === "*") {
      throw new Error(
        'MLS_ALLOWED_ORIGINS must list exact origins; "*" is refused. ' +
          "This API is reachable from the internet and answers with tenant data.",
      );
    }
    let parsed: URL;
    try {
      parsed = new URL(candidate);
    } catch {
      throw new Error(
        `MLS_ALLOWED_ORIGINS entry is not an absolute origin: ${JSON.stringify(piece)}`,
      );
    }
    if (parsed.protocol !== "https:" && parsed.hostname !== "localhost") {
      throw new Error(
        `MLS_ALLOWED_ORIGINS entry must be https (or a localhost dev origin): ${JSON.stringify(piece)}`,
      );
    }
    origins.push(parsed.origin);
  }
  return [...new Set(origins)];
}

/** "" | "/api" | "/api/v1" — never with a trailing slash, never with a wildcard. */
function parseRoutePrefix(env: NodeJS.ProcessEnv): string {
  const raw = str(env, "MLS_ROUTE_PREFIX");
  if (raw === undefined) return "";
  const trimmed = raw.replace(/\/+$/, "");
  if (trimmed === "") return "";
  if (!/^(?:\/[A-Za-z0-9_-]+)+$/.test(trimmed)) {
    throw new Error(
      `MLS_ROUTE_PREFIX must look like "/api" (leading slash, no trailing slash, no parameters); got ${JSON.stringify(raw)}`,
    );
  }
  return trimmed;
}

function loadCloud(env: NodeJS.ProcessEnv): CloudConfig {
  const required = {
    MLS_SQL_SERVER: str(env, "MLS_SQL_SERVER"),
    MLS_SQL_DATABASE: str(env, "MLS_SQL_DATABASE"),
    MLS_FABRIC_SQL_ENDPOINT: str(env, "MLS_FABRIC_SQL_ENDPOINT"),
    MLS_FABRIC_DATABASE: str(env, "MLS_FABRIC_DATABASE"),
    MLS_GITHUB_REPO: str(env, "MLS_GITHUB_REPO"),
    MLS_DEFENDER_SUBSCRIPTION_ID: str(env, "MLS_DEFENDER_SUBSCRIPTION_ID"),
    MLS_LOG_ANALYTICS_WORKSPACE_ID: str(env, "MLS_LOG_ANALYTICS_WORKSPACE_ID"),
  };
  const missing = Object.entries(required)
    .filter(([, value]) => value === undefined)
    .map(([key]) => key);
  if (missing.length > 0) {
    // Fail at boot, not at the first request: a container app that answers
    // /healthz but 502s every route is the worst possible demo failure.
    throw new Error(
      `MLS_DATA_BACKENDS="cloud" requires: ${missing.join(", ")}. ` +
        "Set them on the container app (values come from the L5/L6 outputs); none of them is a secret.",
    );
  }

  // These three are interpolated into upstream URL paths, so they are shape
  // checked here rather than trusted. They are configuration, not caller
  // input, but "configuration" includes a mistyped portal paste.
  const repo = required.MLS_GITHUB_REPO as string;
  if (!/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/.test(repo)) {
    throw new Error('MLS_GITHUB_REPO must be "owner/repo".');
  }
  const subscriptionId = required.MLS_DEFENDER_SUBSCRIPTION_ID as string;
  if (!GUID.test(subscriptionId)) {
    throw new Error("MLS_DEFENDER_SUBSCRIPTION_ID must be a GUID.");
  }
  const costSubscriptionId = str(env, "MLS_COST_SUBSCRIPTION_ID") ?? subscriptionId;
  if (!GUID.test(costSubscriptionId)) {
    throw new Error("MLS_COST_SUBSCRIPTION_ID must be a GUID.");
  }
  const workspaceId = required.MLS_LOG_ANALYTICS_WORKSPACE_ID as string;
  if (!GUID.test(workspaceId)) {
    throw new Error(
      "MLS_LOG_ANALYTICS_WORKSPACE_ID must be the workspace *customer id* GUID, not the ARM resource id.",
    );
  }
  if (!/^P(?:\d+D|T\d+H)$/.test(str(env, "MLS_LOG_ANALYTICS_TIMESPAN") ?? "P14D")) {
    throw new Error(
      'MLS_LOG_ANALYTICS_TIMESPAN must be an ISO-8601 duration like "P14D" or "PT12H".',
    );
  }

  return {
    sqlServer: required.MLS_SQL_SERVER as string,
    sqlDatabase: required.MLS_SQL_DATABASE as string,
    fabricEndpoint: required.MLS_FABRIC_SQL_ENDPOINT as string,
    fabricDatabase: required.MLS_FABRIC_DATABASE as string,
    githubRepo: repo,
    githubApiBase: str(env, "MLS_GITHUB_API_BASE") ?? "https://api.github.com",
    githubToken: str(env, "MLS_GITHUB_TOKEN"),
    defenderSubscriptionId: subscriptionId,
    costSubscriptionId: costSubscriptionId,
    costTimeframe: str(env, "MLS_COST_TIMEFRAME") ?? "MonthToDate",
    // AN HOUR, AND THE NUMBER IS THE POINT. Cost Management's query API is
    // aggressively throttled - four consecutive calls while this was written
    // returned 429 - and cost figures move once a day, so asking more often
    // buys nothing and risks the whole feed. See CloudFeedsBackend.azureCost.
    costCacheSeconds: int(env, "MLS_COST_CACHE_SECONDS", 3600, 60, 86_400),
    armBase: str(env, "MLS_ARM_BASE") ?? "https://management.azure.com",
    logAnalyticsWorkspaceId: workspaceId,
    logAnalyticsBase: str(env, "MLS_LOG_ANALYTICS_BASE") ?? "https://api.loganalytics.io",
    logAnalyticsTimespan: str(env, "MLS_LOG_ANALYTICS_TIMESPAN") ?? "P14D",
    managedIdentityClientId: str(env, "MLS_MANAGED_IDENTITY_CLIENT_ID"),
    upstreamTimeoutMs: int(
      env,
      "MLS_UPSTREAM_TIMEOUT_MS",
      DEFAULT_UPSTREAM_TIMEOUT_MS,
      1_000,
      120_000,
    ),
  };
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): DataApiConfig {
  const requested = str(env, "MLS_DATA_BACKENDS") ?? "local";
  if (requested !== "local" && requested !== "cloud") {
    throw new Error(
      `MLS_DATA_BACKENDS must be "local" or "cloud" (got: ${JSON.stringify(requested)})`,
    );
  }

  return {
    port: int(env, "PORT", 8080, 1, 65_535),
    backendMode: requested,
    routePrefix: parseRoutePrefix(env),
    allowedOrigins: parseOrigins(env),
    maxRows: int(env, "MLS_MAX_ROWS", DEFAULT_MAX_ROWS, 1, 1_000_000),
    tableCacheSeconds: int(
      env,
      "MLS_TABLE_CACHE_SECONDS",
      DEFAULT_TABLE_CACHE_SECONDS,
      0,
      86_400,
    ),
    feedCacheSeconds: int(
      env,
      "MLS_FEED_CACHE_SECONDS",
      DEFAULT_FEED_CACHE_SECONDS,
      0,
      86_400,
    ),
    generatedDataDir:
      str(env, "MLS_DATA_DIR") ?? path.join(repoRoot, "data", "generated"),
    fixturesDir: str(env, "MLS_FIXTURES_DIR") ?? path.join(packageRoot, "fixtures"),
    build:
      str(env, "MLS_IMAGE_DIGEST") ??
      str(env, "CONTAINER_APP_REVISION") ??
      "unknown",
    telemetry: {
      connectionString: str(env, "APPLICATIONINSIGHTS_CONNECTION_STRING"),
      serviceName: str(env, "OTEL_SERVICE_NAME") ?? "data-api",
      serviceVersion: str(env, "MLS_SERVICE_VERSION") ?? "0.1.0",
      sampleRatio: ratio(env, "MLS_OTEL_SAMPLE_RATIO", 1),
      // Same AZURE_CLIENT_ID the container's DefaultAzureCredential binds to
      // everywhere else (see app.ts) — not MLS_MANAGED_IDENTITY_CLIENT_ID,
      // which is cloud-mode-only and unset in local mode even though
      // AZURE_CLIENT_ID is always present on the deployed container.
      managedIdentityClientId: str(env, "AZURE_CLIENT_ID"),
    },
    cloud: requested === "cloud" ? loadCloud(env) : undefined,
  };
}
