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
          // The old text said "the live backend comes online at L7", which was true before
          // the tenant existed and is misleading now: L7 IS deployed when a user sees this,
          // so it sends them to wait for something that already happened. A 502 here means
          // data-api is running and its store is refusing it - almost always the SQL
          // contained-database user (F109) or, for the three lakehouse-backed tables, the
          // managed-identity limitation on Fabric's TDS endpoint (F101).
          (res.status === 502 || res.status === 503
            ? "data-api is running but its data store refused the connection. Check the container log for 'Login failed for user' - the app identity needs a contained-database user in Azure SQL (F109), or, for telemetry/cost/findings tables, an identity Fabric's SQL endpoint accepts (F101)."
            : "Check that data-api is deployed and reachable from this app's /api proxy."),
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
