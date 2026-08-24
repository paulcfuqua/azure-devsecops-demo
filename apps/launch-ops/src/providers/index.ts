import { ApiProvider } from "./ApiProvider";
import { LocalJsonProvider } from "./LocalJsonProvider";
import type { DataProvider } from "./types";

export { ApiProvider } from "./ApiProvider";
export { fetchLocalJson, LocalJsonProvider } from "./LocalJsonProvider";
export * from "./specs";
export type * from "./types";

export type DataMode = "local" | "api";

interface ModeEnv {
  DEV?: boolean;
  VITE_DATA_MODE?: string;
  VITE_LOCAL_DATA?: string;
}

/**
 * LOCAL_DATA mode selection:
 * - `VITE_DATA_MODE=local|api` wins outright;
 * - `LOCAL_DATA=1` (mapped to `VITE_LOCAL_DATA` in vite.config.ts) forces
 *   local mode, including in production builds (`vite preview` rehearsals);
 * - otherwise dev serves local generated data and production builds expect
 *   the live API (wired at L7).
 */
export function resolveDataMode(env: ModeEnv = import.meta.env): DataMode {
  if (env.VITE_DATA_MODE === "local" || env.VITE_DATA_MODE === "api") {
    return env.VITE_DATA_MODE;
  }
  if (env.VITE_LOCAL_DATA === "1") return "local";
  return env.DEV ? "local" : "api";
}

export function createDataProvider(mode: DataMode = resolveDataMode()): DataProvider {
  return mode === "local" ? new LocalJsonProvider() : new ApiProvider();
}
