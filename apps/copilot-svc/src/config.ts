/**
 * Runtime configuration.
 *
 * Mode selection (hard rule: mock is the default path — the service never fails
 * just because no API key is present):
 *   - MOCK_LLM=1            -> mock driver, always (CI / local tests).
 *   - ANTHROPIC_API_KEY set -> live driver (Anthropic API).
 *   - neither               -> mock driver.
 *
 * The model id is read from committed config (config/copilot.json), never
 * hardcoded inline — see L08 playbook failure mode 4 (pin the model so
 * upgrades are deliberate PRs). COPILOT_MODEL overrides at runtime.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
/**
 * Package root. This module sits one level below it in both layouts —
 * `src/config.ts` (tsx/vitest) and `dist/config.js` (built image).
 */
export const packageRoot = path.resolve(here, "..");

/** Repo root: apps/copilot-svc -> repo. */
export const repoRoot = path.resolve(packageRoot, "..", "..");

/** Directory holding Track A's generated CSVs (gitignored; `python -m generators build`). */
export const generatedDataDir =
  process.env.MLS_DATA_DIR ?? path.join(repoRoot, "data", "generated");

/** Directory holding committed local fixtures for the non-SQL tools. */
export const fixturesDir = path.join(packageRoot, "fixtures");

interface CopilotFileConfig {
  model: string;
  maxTokens: number;
  maxToolRounds: number;
  thinking: { type: string };
}

function loadFileConfig(): CopilotFileConfig {
  const p = path.join(packageRoot, "config", "copilot.json");
  const raw = JSON.parse(fs.readFileSync(p, "utf-8")) as Partial<CopilotFileConfig>;
  if (typeof raw.model !== "string" || raw.model.length === 0) {
    throw new Error(`config/copilot.json must pin a "model" id (got: ${JSON.stringify(raw.model)})`);
  }
  return {
    model: raw.model,
    maxTokens: raw.maxTokens ?? 16000,
    maxToolRounds: raw.maxToolRounds ?? 8,
    thinking: raw.thinking ?? { type: "adaptive" },
  };
}

export interface CopilotConfig extends CopilotFileConfig {
  port: number;
  /** "mock" | "live" — see module docstring for selection rules. */
  llmMode: "mock" | "live";
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): CopilotConfig {
  const file = loadFileConfig();
  const mock = env.MOCK_LLM === "1" || !env.ANTHROPIC_API_KEY;
  return {
    ...file,
    model: env.COPILOT_MODEL ?? file.model,
    port: env.PORT ? Number(env.PORT) : 8080,
    llmMode: mock ? "mock" : "live",
  };
}
