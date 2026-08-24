import type { Spec } from "@mls/spec-renderer";

/**
 * The launch-ops data contract — the L7 wiring boundary.
 *
 * A provider turns raw rows into ready-to-render `@mls/spec-renderer` specs;
 * the React components stay dumb and only ever see a `Spec`. Two
 * implementations exist:
 *
 * - `LocalJsonProvider` — LOCAL_DATA mode (Phase P default in dev): fetches
 *   the deterministic generator output served from `data/generated/`.
 * - `ApiProvider` — live mode: fetches the same row shapes from the
 *   launch-ops backend once L6/L7 provision Azure SQL + the lakehouse.
 *
 * Both share the pure spec builders in `specs.ts`, so swapping providers at
 * L7 changes only where rows come from — never what the UI renders.
 */
export interface DataProvider {
  /** Human-readable data origin, surfaced in the app footer. */
  readonly source: string;
  /** Launch schedule view: recent-launch table + milestone timeline. */
  getScheduleSpec(): Promise<Spec>;
  /** Outcome mix + weekday distribution (the Saturday launch-window bias). */
  getOutcomesSpec(): Promise<Spec>;
  /** Scrub analysis: monthly scrub trend + headline stats. */
  getScrubAnalysisSpec(): Promise<Spec>;
  /** Vehicle and pad reference tables. */
  getReferenceSpec(): Promise<Spec>;
}

/** Loads one table's JSON by name (e.g. "launches"). Injectable for tests. */
export type JsonLoader = (table: string) => Promise<unknown>;

/*
 * Row shapes below mirror the Track A generator output in `data/generated/`
 * (which is also what the L5 lakehouse / L6 SQL tables are seeded from).
 * Fields the generators intentionally dirty are typed defensively.
 */

export interface LaunchRow {
  launch_id: string;
  mission_name: string;
  vehicle_id: string;
  pad_id: string;
  customer: string | null;
  orbit: string | null;
  planned_date: string;
  actual_date: string | null;
  outcome: string;
  payload_mass_kg: number | null;
  weather_delay_min: number | null;
  scrub_count: number;
  booster_recovery: string | null;
  insurance_value_musd: number | null;
}

export interface ScrubRow {
  scrub_id: string;
  launch_id: string;
  scrub_date: string;
  category: string;
  reason: string | null;
  called_at_t_minus_s: number | null;
  recycle_hours: number | null;
}

export interface VehicleRow {
  vehicle_id: string;
  name: string;
  vehicle_class: string | null;
  fleet_group: string | null;
  stages: number | null;
  reusable: boolean | null;
  leo_capacity_kg: number | null;
  gto_capacity_kg: number | null;
  height_m: number | null;
  first_flight_year: number | null;
  last_flight_year: number | null;
  status: string | null;
}

export interface PadRow {
  pad_id: string;
  name: string;
  site: string | null;
  country: string | null;
  latitude: number | null;
  longitude: number | null;
  first_used_year: number | null;
  status: string | null;
}
