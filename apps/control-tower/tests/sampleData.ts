// Sample Ops-feed rows in the exact shape the Track A generators emit
// (data/generated/cost_daily.json, telemetry_summary.json). Small on purpose:
// provider tests assert on the specs built from these, not on the full dataset.
// Dev/Sec inputs come from the committed fixtures in src/fixtures/.

import type { CostDailyRow, TelemetrySummaryRow } from "../src/providers/types";

export const sampleCostRows: CostDailyRow[] = [
  {
    cost_id: "CST-00001",
    date: "2025-01-05",
    cost_center: "Propulsion",
    amount_usd: 9000,
    budget_usd: 8000,
    currency: "USD",
  },
  {
    cost_id: "CST-00002",
    date: "2025-01-06",
    cost_center: "Avionics",
    amount_usd: 6000,
    budget_usd: 6000,
    currency: "USD",
  },
  {
    cost_id: "CST-00003",
    date: "2025-02-04",
    cost_center: "Propulsion",
    amount_usd: 11000,
    budget_usd: 8000,
    currency: "USD",
  },
  {
    cost_id: "CST-00004",
    date: "2025-02-05",
    cost_center: "Cloud & IT",
    amount_usd: 4000,
    budget_usd: 6000,
    currency: "USD",
  },
];

export const sampleTelemetryRows: TelemetrySummaryRow[] = [
  {
    telemetry_id: "TLM-0001",
    launch_id: "LNH-0001",
    max_q_kpa: 24.4,
    max_accel_g: 6.21,
    meco_time_s: 153.1,
    peak_thrust_kn: 243.1,
    max_altitude_km: 552.0,
    anomaly_count: 0,
    telemetry_coverage_pct: 100,
    data_dropout_s: 2.0,
  },
  {
    telemetry_id: "TLM-0002",
    launch_id: "LNH-0002",
    max_q_kpa: 31.8,
    max_accel_g: 5.44,
    meco_time_s: 161.7,
    peak_thrust_kn: 251.9,
    max_altitude_km: 498.0,
    anomaly_count: 2,
    telemetry_coverage_pct: 96,
    data_dropout_s: 6.0,
  },
  {
    telemetry_id: "TLM-0003",
    launch_id: "LNH-0003",
    max_q_kpa: 28.1,
    max_accel_g: 5.9,
    meco_time_s: 158.4,
    peak_thrust_kn: 247.5,
    max_altitude_km: 511.0,
    anomaly_count: 1,
    // generator messiness: nullable numerics are ignored by the averages
    telemetry_coverage_pct: null,
    data_dropout_s: null,
  },
];

/** In-memory JsonLoader stub covering the generated tables the Ops tab reads. */
export function stubLoader(): (table: string) => Promise<unknown> {
  const tables: Record<string, unknown> = {
    cost_daily: sampleCostRows,
    telemetry_summary: sampleTelemetryRows,
  };
  return (table: string) => {
    if (table in tables) return Promise.resolve(tables[table]);
    return Promise.reject(new Error(`stubLoader: no sample table ${table}`));
  };
}
