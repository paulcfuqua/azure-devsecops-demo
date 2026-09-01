// Sample Ops input in the exact shape data-api's azure-cost feed serves.
//
// It replaced sampleCostRows / sampleTelemetryRows, which described the
// FICTIONAL launch company - a synthetic programme budget and flight telemetry.
// The Ops tab is about what the estate costs to RUN (F117), so its sample is
// Azure services and resource groups, with the small real-looking amounts a
// demo estate actually bills.
//
// Deliberately tiny and hand-checkable: the tests assert on totals and ordering
// derived from these numbers, so they must be countable by eye.

import type { AzureCostFeed } from "../src/providers/types";

export const sampleAzureCost: AzureCostFeed = {
  asOf: "2026-09-01T12:00:00.000Z",
  stale: false,
  currency: "USD",
  timeframe: "MonthToDate",
  // 6 + 3 + 1 = 10 exactly, so a wrong total is obvious in a failure message.
  total: 10,
  byService: [
    { name: "Azure Container Apps", cost: 6 },
    { name: "Azure SQL Database", cost: 3 },
    { name: "Log Analytics", cost: 1 },
  ],
  byResourceGroup: [
    { name: "mls-rg-apps", cost: 6 },
    { name: "mls-rg-data", cost: 3 },
    { name: "mls-rg-platform", cost: 1 },
  ],
  daily: [
    { date: "2026-08-30", cost: 4 },
    { date: "2026-08-31", cost: 6 },
  ],
};

export function stubLoader(): (table: string) => Promise<unknown> {
  // The Ops tab no longer loads generated tables (F117), so this resolves
  // nothing by design. It is kept because LocalProvider still accepts a loader
  // and the app smoke tests construct it with one.
  const tables: Record<string, unknown> = {};
  return (table: string) => {
    if (table in tables) return Promise.resolve(tables[table]);
    return Promise.reject(new Error(`stubLoader: no sample table ${table}`));
  };
}
