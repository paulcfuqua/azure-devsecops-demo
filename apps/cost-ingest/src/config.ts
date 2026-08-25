// =============================================================================
// Application settings -> typed configuration.
//
// Every value here is an app setting placed by L6's Bicep (see
// docs/runbooks/layers/L06.md step 3). NONE of them is a credential: the only
// authentication in this Function is the managed identity, and a managed
// identity has no value to store (CLAUDE.md hard rule 5). If a setting ever
// appears here that looks like a secret, that is the bug.
//
// The env object is a parameter rather than a direct `process.env` read so the
// resolver is testable without mutating global state.
// =============================================================================

import type { IngestConfig } from "./ingest.ts";

export type CostIngestConfig = {
  /** Fabric workspace holding the lakehouse, e.g. `mls-operations`. */
  readonly workspace: string;
  /** Lakehouse name without the `.Lakehouse` suffix, e.g. `mls_operations`. */
  readonly lakehouse: string;
  /** Folder under Files/ that the `cost_daily` Delta table is defined over. */
  readonly basePath: string;
  /** OneLake DFS endpoint; overridable for sovereign clouds. */
  readonly endpoint: string;
  /** Normalisation knobs (budgets, cost-centre fallbacks). */
  readonly ingest: IngestConfig;
};

export class ConfigurationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfigurationError";
  }
}

/**
 * Parses a JSON object setting, tolerating an unset or blank value.
 * A malformed value is a deployment fault and is reported as one — silently
 * falling back to `{}` would mean every cost centre losing its budget with no
 * signal anywhere.
 */
export function parseJsonRecord<T>(
  raw: string | undefined,
  settingName: string,
  coerce: (value: unknown) => T | null,
): Record<string, T> {
  const text = (raw ?? "").trim();
  if (text === "") return {};

  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch (error) {
    throw new ConfigurationError(
      `${settingName} is not valid JSON: ${(error as Error).message}`,
    );
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new ConfigurationError(`${settingName} must be a JSON object of key -> value.`);
  }

  const out: Record<string, T> = {};
  for (const [key, value] of Object.entries(parsed as Record<string, unknown>)) {
    const coerced = coerce(value);
    if (coerced === null) {
      throw new ConfigurationError(
        `${settingName}['${key}'] is not a usable value (got ${JSON.stringify(value)}).`,
      );
    }
    out[key] = coerced;
  }
  return out;
}

/** Reads and validates every setting this Function needs. */
export function readConfig(env: Readonly<Record<string, string | undefined>>): CostIngestConfig {
  const workspace = (env.FABRIC_WORKSPACE ?? "").trim();
  const lakehouse = (env.FABRIC_LAKEHOUSE ?? "").trim();

  const missing = [
    workspace === "" ? "FABRIC_WORKSPACE" : null,
    lakehouse === "" ? "FABRIC_LAKEHOUSE" : null,
  ].filter((name): name is string => name !== null);

  if (missing.length > 0) {
    throw new ConfigurationError(
      `Cost ingestion is not configured: ${missing.join(", ")} must be set on the function app. ` +
        "L6's platform deployment sets these; see docs/runbooks/layers/L06.md.",
    );
  }

  const costCenterBudgets = parseJsonRecord<number>(
    env.COST_CENTER_BUDGETS,
    "COST_CENTER_BUDGETS",
    (value) => {
      const numeric = typeof value === "number" ? value : Number(value);
      return Number.isFinite(numeric) ? numeric : null;
    },
  );

  const resourceGroupCostCenters = parseJsonRecord<string>(
    env.RESOURCE_GROUP_COST_CENTERS,
    "RESOURCE_GROUP_COST_CENTERS",
    (value) => (typeof value === "string" && value.trim() !== "" ? value.trim() : null),
  );

  // Resource-group names are matched case-insensitively; normalise the keys once.
  const groupMap: Record<string, string> = {};
  for (const [group, center] of Object.entries(resourceGroupCostCenters)) {
    groupMap[group.toLowerCase()] = center;
  }

  return {
    workspace,
    lakehouse,
    basePath: (env.LAKEHOUSE_COST_PATH ?? "").trim() || "cost_daily",
    endpoint: (env.ONELAKE_ENDPOINT ?? "").trim() || "https://onelake.dfs.fabric.microsoft.com",
    ingest: {
      costCenterBudgets,
      resourceGroupCostCenters: groupMap,
      fallbackCostCenter: (env.FALLBACK_COST_CENTER ?? "").trim() || "Unallocated",
      defaultCurrency: (env.DEFAULT_CURRENCY ?? "").trim().toUpperCase() || "USD",
    },
  };
}
