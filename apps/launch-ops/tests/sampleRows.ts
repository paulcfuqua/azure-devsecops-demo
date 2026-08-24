// Hand-written sample rows in the exact shape the Track A generators emit
// (data/generated/*.json). Small on purpose: provider tests assert on the
// specs built from these, not on the full generated dataset.

import type { LaunchRow, PadRow, ScrubRow, VehicleRow } from "../src/providers/types";

function launch(overrides: Partial<LaunchRow> & Pick<LaunchRow, "launch_id">): LaunchRow {
  return {
    mission_name: `M-${overrides.launch_id}`,
    vehicle_id: "VEH-001",
    pad_id: "PAD-01",
    customer: "Tidewater Remote Sensing",
    orbit: "SSO",
    planned_date: "2025-01-04",
    actual_date: "2025-01-04",
    outcome: "success",
    payload_mass_kg: 1200.5,
    weather_delay_min: 0,
    scrub_count: 0,
    booster_recovery: "droneship",
    insurance_value_musd: 120.0,
    ...overrides,
  };
}

// Weekday reference for 2025: Jan 4 = Saturday, Jan 6 = Monday, Jan 8 =
// Wednesday. Saturday deliberately dominates, mirroring the generator bias.
export const sampleLaunches: LaunchRow[] = [
  launch({ launch_id: "LNH-0001", planned_date: "2025-01-04", actual_date: "2025-01-04" }),
  launch({ launch_id: "LNH-0002", planned_date: "2025-01-11", actual_date: "2025-01-11" }),
  launch({ launch_id: "LNH-0003", planned_date: "2025-01-18", actual_date: "2025-01-18" }),
  launch({
    launch_id: "LNH-0004",
    planned_date: "2025-01-25",
    actual_date: "2025-01-25",
    outcome: "failure",
    scrub_count: 2,
  }),
  launch({
    launch_id: "LNH-0005",
    planned_date: "2025-01-06",
    actual_date: "2025-01-06",
    outcome: "partial_failure",
  }),
  launch({
    launch_id: "LNH-0006",
    planned_date: "2025-01-08",
    actual_date: null, // upcoming: no actual date yet
    customer: null, // generator messiness: nullable strings
    payload_mass_kg: null,
  }),
];

export const sampleScrubs: ScrubRow[] = [
  {
    scrub_id: "SCR-0001",
    launch_id: "LNH-0004",
    scrub_date: "2025-01-23",
    category: "weather",
    reason: "Upper-level winds out of limits",
    called_at_t_minus_s: 120,
    recycle_hours: 29.0,
  },
  {
    scrub_id: "SCR-0002",
    launch_id: "LNH-0004",
    scrub_date: "2025-01-24",
    category: "weather",
    reason: "Anvil cloud rule",
    called_at_t_minus_s: 600,
    recycle_hours: 24.0,
  },
  {
    scrub_id: "SCR-0003",
    launch_id: "LNH-0002",
    scrub_date: "2025-02-10",
    category: "technical",
    reason: "LOX loading anomaly",
    called_at_t_minus_s: 45,
    recycle_hours: null, // generator messiness: nullable numerics
  },
];

export const sampleVehicles: VehicleRow[] = [
  {
    vehicle_id: "VEH-001",
    name: "Falcon 9 Block 5",
    vehicle_class: "medium",
    fleet_group: "MLS Medium Fleet",
    stages: 2,
    reusable: true,
    leo_capacity_kg: 22800,
    gto_capacity_kg: 8300,
    height_m: 70.0,
    first_flight_year: 2018,
    last_flight_year: null,
    status: "active",
  },
  {
    vehicle_id: "VEH-002",
    name: "Electron",
    vehicle_class: "small",
    fleet_group: "MLS Small Fleet",
    stages: 2,
    reusable: false,
    leo_capacity_kg: 300,
    gto_capacity_kg: null,
    height_m: 18.0,
    first_flight_year: 2017,
    last_flight_year: null,
    status: "active",
  },
];

export const samplePads: PadRow[] = [
  {
    pad_id: "PAD-01",
    name: "SLC-40",
    site: "Cape Canaveral Space Force Station",
    country: "USA",
    latitude: 28.562,
    longitude: -80.5772,
    first_used_year: 1965,
    status: "active",
  },
  {
    pad_id: "PAD-02",
    name: "LC-1A",
    site: "Mahia Peninsula",
    country: "New Zealand",
    latitude: -39.2615,
    longitude: 177.8646,
    first_used_year: 2017,
    status: "active",
  },
];

/** In-memory JsonLoader stub covering every table the providers request. */
export function stubLoader(): (table: string) => Promise<unknown> {
  const tables: Record<string, unknown> = {
    launches: sampleLaunches,
    scrubs: sampleScrubs,
    vehicles: sampleVehicles,
    pads: samplePads,
  };
  return (table: string) => {
    if (table in tables) return Promise.resolve(tables[table]);
    return Promise.reject(new Error(`stubLoader: no sample table ${table}`));
  };
}
