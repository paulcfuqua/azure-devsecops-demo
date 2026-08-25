/**
 * The served row contract for `GET /tables/:table`.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * SIX OF THESE INTERFACES ARE COPIES, NOT ORIGINALS.
 *
 * `LaunchRow`, `ScrubRow`, `VehicleRow` and `PadRow` are copied **verbatim**
 * from `apps/launch-ops/src/providers/types.ts`; `CostDailyRow` and
 * `TelemetrySummaryRow` are copied **verbatim** from
 * `apps/control-tower/src/providers/types.ts`. Those two files are the
 * authority — the frontends' `ApiProvider` casts this service's JSON straight
 * to them, so any divergence is a silent production bug that typechecks on
 * both sides.
 *
 * `tests/contract-parity.test.ts` re-extracts the interface bodies from both
 * provider files at test time and fails on any drift, in either direction.
 * If that test fails: change the copy here, never the frontend.
 *
 * The remaining four (`PartRow`, `SupplierRow`, `WorkOrderRow`,
 * `FindingHistoryRow`) have no `ApiProvider` counterpart today — no frontend
 * view consumes them yet — so this file is their authority. They are served
 * because the master plan's table set is ten, and because the MCP tools and
 * the Fabric data agent read the same ten.
 * ─────────────────────────────────────────────────────────────────────────────
 */

/* --- copied verbatim from apps/launch-ops/src/providers/types.ts --------- */

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

/* --- copied verbatim from apps/control-tower/src/providers/types.ts ------ */

export interface CostDailyRow {
  cost_id: string;
  date: string;
  cost_center: string;
  amount_usd: number;
  budget_usd: number;
  currency: string;
}

export interface TelemetrySummaryRow {
  telemetry_id: string;
  launch_id: string;
  max_q_kpa: number | null;
  max_accel_g: number | null;
  meco_time_s: number | null;
  peak_thrust_kn: number | null;
  max_altitude_km: number | null;
  anomaly_count: number;
  telemetry_coverage_pct: number | null;
  data_dropout_s: number | null;
}

/* --- defined here: no ApiProvider consumes these (yet) ------------------- */

export interface PartRow {
  part_id: string;
  part_number: string;
  name: string;
  category: string;
  supplier_id: string;
  unit_cost_usd: number;
  lead_time_days: number;
  qty_on_hand: number;
  min_stock: number;
  criticality: number;
  material: string | null;
}

export interface SupplierRow {
  supplier_id: string;
  name: string;
  country: string;
  certification: string;
  avg_lead_time_days: number;
  on_time_pct: number;
  quality_rating: number;
  active: boolean;
}

export interface WorkOrderRow {
  work_order_id: string;
  part_id: string;
  vehicle_id: string;
  launch_id: string | null;
  opened_date: string;
  closed_date: string | null;
  status: string;
  disposition: string | null;
  priority: string;
  labor_hours: number;
  technician: string;
}

export interface FindingHistoryRow {
  finding_id: string;
  source: string;
  severity: string;
  title: string;
  component: string;
  cve_id: string | null;
  opened_date: string;
  closed_date: string | null;
  status: string;
  assignee: string;
  sla_days: number;
}

/** One row of any allowlisted table, as served. */
export type TableRow =
  | LaunchRow
  | ScrubRow
  | VehicleRow
  | PadRow
  | CostDailyRow
  | TelemetrySummaryRow
  | PartRow
  | SupplierRow
  | WorkOrderRow
  | FindingHistoryRow;
