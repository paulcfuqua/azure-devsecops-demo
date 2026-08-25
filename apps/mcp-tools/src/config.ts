/**
 * Runtime configuration.
 *
 * There is no LLM here and therefore no model, no API key and no mode
 * selection: this process is an MCP server. The Copilot Studio agent owns all
 * orchestration (amendment 2026-08-24). The only knobs are the listen port and
 * which adapter set the five tools run against.
 */
import path from "node:path";
import { fileURLToPath } from "node:url";

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
 * Which adapter set the tools execute against.
 *   local — sql.js over data/generated + committed fixtures (Phase P, today).
 *   cloud — Fabric SQL endpoint / Log Analytics / GitHub / Defender / Cost
 *           Management. Typed stubs today; wired at L5-L8 when the tenant exists.
 */
export type BackendMode = "local" | "cloud";

export interface McpToolsConfig {
  port: number;
  backendMode: BackendMode;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): McpToolsConfig {
  const requested = env.MLS_TOOL_BACKENDS ?? "local";
  if (requested !== "local" && requested !== "cloud") {
    throw new Error(
      `MLS_TOOL_BACKENDS must be "local" or "cloud" (got: ${JSON.stringify(requested)})`,
    );
  }
  if (requested === "cloud") {
    // Fail at boot rather than at the first tool call: the cloud adapters in
    // src/tools/backends.ts are typed stubs until L5-L8 supplies the Fabric SQL
    // endpoint, Log Analytics workspace id, repo token and subscription id.
    throw new Error(
      'MLS_TOOL_BACKENDS="cloud" is not wired yet — the cloud adapters in ' +
        "src/tools/backends.ts are typed stubs implemented at L5-L8.",
    );
  }
  return {
    port: env.PORT ? Number(env.PORT) : 8080,
    backendMode: "local",
  };
}
