import type { Spec } from "@mls/spec-renderer";
import {
  buildOutcomesSpec,
  buildReferenceSpec,
  buildScheduleSpec,
  buildScrubAnalysisSpec,
} from "./specs";
import type {
  DataProvider,
  JsonLoader,
  LaunchRow,
  PadRow,
  ScrubRow,
  VehicleRow,
} from "./types";

/**
 * LOCAL_DATA mode provider (Phase P default in dev). Reads the deterministic
 * Track A generator output — `data/generated/*.json`, served by the app's
 * vite middleware under `/local-data/` — and builds renderer specs from it.
 */
export class LocalJsonProvider implements DataProvider {
  readonly source = "local JSON (data/generated, seed 20260822)";

  private readonly cache = new Map<string, Promise<unknown>>();

  constructor(private readonly loader: JsonLoader = fetchLocalJson) {}

  private table<T>(name: string): Promise<T[]> {
    let pending = this.cache.get(name);
    if (!pending) {
      pending = this.loader(name).then((json) => {
        if (!Array.isArray(json)) {
          throw new Error(`Expected ${name}.json to contain an array of rows.`);
        }
        return json;
      });
      // Drop failed loads so a retry (e.g. after running the generators) works.
      pending.catch(() => this.cache.delete(name));
      this.cache.set(name, pending);
    }
    return pending as Promise<T[]>;
  }

  async getScheduleSpec(): Promise<Spec> {
    const [launches, vehicles, pads] = await Promise.all([
      this.table<LaunchRow>("launches"),
      this.table<VehicleRow>("vehicles"),
      this.table<PadRow>("pads"),
    ]);
    return buildScheduleSpec(launches, vehicles, pads);
  }

  async getOutcomesSpec(): Promise<Spec> {
    return buildOutcomesSpec(await this.table<LaunchRow>("launches"));
  }

  async getScrubAnalysisSpec(): Promise<Spec> {
    return buildScrubAnalysisSpec(await this.table<ScrubRow>("scrubs"));
  }

  async getReferenceSpec(): Promise<Spec> {
    const [vehicles, pads] = await Promise.all([
      this.table<VehicleRow>("vehicles"),
      this.table<PadRow>("pads"),
    ]);
    return buildReferenceSpec(vehicles, pads);
  }
}

/** Default loader: fetch a generated table from the vite local-data middleware. */
export async function fetchLocalJson(table: string): Promise<unknown> {
  const res = await fetch(`/local-data/${table}.json`);
  if (!res.ok) {
    throw new Error(
      `Local data ${table}.json is unavailable (HTTP ${res.status}). ` +
        "Generate it with `python -m generators build` from the data/ directory, then reload.",
    );
  }
  return res.json();
}
