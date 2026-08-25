// =============================================================================
// The `cost_daily` contract.
//
// The shape is fixed by data/generators/README.md § cost_daily, because the
// lakehouse table is created and first populated by the L5 generator seed and
// this Function has to land in the same table:
//
//   cost_id | date | cost_center | amount_usd | budget_usd | currency
//
// The control tower's cost-over-time visual and the MCP `get_cost_series` tool
// both read that table, so a column added or renamed here is a breaking change
// for two showpieces at once.
//
// ONE DELIBERATE DIVERGENCE FROM THE GENERATOR, and the reason for it.
// The generator mints sequential surrogate ids (`CST-00001`, `CST-00002`, …).
// Ingested rows cannot: a sequence is stateful, and the whole point of this
// Function is that re-processing yesterday's export produces exactly the same
// rows it produced yesterday. So ingested ids are DERIVED from the natural key
// — `CST-<YYYYMMDD>-<COST-CENTER-SLUG>` — which makes the id a function of the
// data and idempotency a property of the format rather than of bookkeeping.
// The two id spaces do not collide: generator ids are `CST-` + 5 digits,
// ingested ids always carry a second hyphen.
// =============================================================================

/** One row of the lakehouse `cost_daily` table. */
export type CostDailyRow = {
  /** Deterministic natural-key id — see the divergence note above. */
  readonly cost_id: string;
  /** ISO `YYYY-MM-DD`, the usage date (not the billing-period start). */
  readonly date: string;
  /** Cost centre, resolved from the `costCenter` tag the L2 policy enforces. */
  readonly cost_center: string;
  /** Summed cost for that (date, cost_center), rounded to cents. */
  readonly amount_usd: number;
  /** Configured daily budget, or null when none is configured. */
  readonly budget_usd: number | null;
  /** ISO 4217 code as billed. `USD` for this demo estate. */
  readonly currency: string;
};

/** Column order for every file this Function writes. Fixed, never sorted. */
export const COST_DAILY_COLUMNS = [
  "cost_id",
  "date",
  "cost_center",
  "amount_usd",
  "budget_usd",
  "currency",
] as const;

/**
 * Slug used inside a derived `cost_id`: upper-case, non-alphanumerics collapsed
 * to single hyphens. `Range Operations` -> `RANGE-OPERATIONS`,
 * `Cloud & IT` -> `CLOUD-IT`.
 */
export function costCenterSlug(costCenter: string): string {
  return costCenter
    .trim()
    .toUpperCase()
    .replace(/[^A-Z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

/** `CST-20260815-RANGE-OPERATIONS` — a pure function of the natural key. */
export function makeCostId(isoDate: string, costCenter: string): string {
  return `CST-${isoDate.replace(/-/g, "")}-${costCenterSlug(costCenter)}`;
}

/** `2026-08-15` -> `2026-08`. The partition (and idempotency) unit. */
export function monthOf(isoDate: string): string {
  return isoDate.slice(0, 7);
}

/**
 * Total ordering for a written partition: date, then cost centre. Deterministic
 * ordering plus deterministic ids is what makes a re-ingest byte-identical.
 */
export function compareCostDaily(a: CostDailyRow, b: CostDailyRow): number {
  if (a.date !== b.date) return a.date < b.date ? -1 : 1;
  if (a.cost_center !== b.cost_center) return a.cost_center < b.cost_center ? -1 : 1;
  return 0;
}
