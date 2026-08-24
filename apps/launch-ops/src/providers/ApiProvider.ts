import type { Spec } from "@mls/spec-renderer";
import {
  buildOutcomesSpec,
  buildReferenceSpec,
  buildScheduleSpec,
  buildScrubAnalysisSpec,
} from "./specs";
import type {
  DataProvider,
  LaunchRow,
  PadRow,
  ScrubRow,
  VehicleRow,
} from "./types";

/**
 * Live-API provider — the L7 wiring target.
 *
 * Contract: the launch-ops backend (Azure SQL for CRUD tables, the L5
 * lakehouse for analytics) serves `GET {baseUrl}/tables/<table>` returning a
 * JSON array with exactly the row shape documented in `types.ts` — the same
 * shape the Track A generators emit, because those generators seed the cloud
 * tables. The spec builders are therefore shared verbatim with
 * `LocalJsonProvider`; wiring L7 means deploying the backend and selecting
 * this provider, with no UI changes.
 */
export class ApiProvider implements DataProvider {
  readonly source: string;

  constructor(private readonly baseUrl: string = "/api") {
    this.source = `live API (${this.baseUrl})`;
  }

  private async rows<T>(table: string): Promise<T[]> {
    const res = await fetch(`${this.baseUrl}/tables/${table}`);
    if (!res.ok) {
      throw new Error(
        `API ${this.baseUrl}/tables/${table} responded ${res.status}. ` +
          "The live backend comes online at L7; before tenant activation run the app in LOCAL_DATA mode.",
      );
    }
    const json: unknown = await res.json();
    if (!Array.isArray(json)) {
      throw new Error(`API table ${table} did not return a JSON array of rows.`);
    }
    return json as T[];
  }

  async getScheduleSpec(): Promise<Spec> {
    const [launches, vehicles, pads] = await Promise.all([
      this.rows<LaunchRow>("launches"),
      this.rows<VehicleRow>("vehicles"),
      this.rows<PadRow>("pads"),
    ]);
    return buildScheduleSpec(launches, vehicles, pads);
  }

  async getOutcomesSpec(): Promise<Spec> {
    return buildOutcomesSpec(await this.rows<LaunchRow>("launches"));
  }

  async getScrubAnalysisSpec(): Promise<Spec> {
    return buildScrubAnalysisSpec(await this.rows<ScrubRow>("scrubs"));
  }

  async getReferenceSpec(): Promise<Spec> {
    const [vehicles, pads] = await Promise.all([
      this.rows<VehicleRow>("vehicles"),
      this.rows<PadRow>("pads"),
    ]);
    return buildReferenceSpec(vehicles, pads);
  }
}
