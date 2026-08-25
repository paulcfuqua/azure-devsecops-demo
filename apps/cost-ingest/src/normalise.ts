// =============================================================================
// Cost Management export -> `cost_daily` rows.
//
// This module is where the real-world messiness lives, so it is worth being
// explicit about what "messy" means here. None of the following is hypothetical:
//
// 1. THE COLUMN SET VARIES BY EXPORT VERSION. An EA/legacy actual-cost export
//    writes `UsageDate` + `PreTaxCost`; an MCA export writes `date` +
//    `costInBillingCurrency`; a FOCUS-format export writes `ChargePeriodStart` +
//    `BilledCost`. Header case and spacing vary too. So columns are resolved
//    through an ordered alias table against case- and space-insensitive keys,
//    and the FIRST alias present wins — order encodes preference (a USD column
//    beats a billing-currency column, because the target column is amount_usd).
//
// 2. DATES ARRIVE IN THREE SHAPES. ISO (`2026-08-15`), US (`08/15/2026`), and a
//    bare integer (`20260815`) which older exports use for `UsageDate`. All three
//    normalise to ISO; anything else is a rejected row, not a guess.
//
// 3. AMOUNTS ARRIVE AS STRINGS. With thousands separators, currency symbols,
//    scientific notation from very small meters (`1.2345E-05`), parentheses for
//    negatives (refunds and credits are real), and occasionally a blank. Number()
//    alone gets several of these wrong — `Number("1,234.5")` is NaN and
//    `Number("")` is 0, which would silently invent a zero-cost row.
//
// 4. THE GRAIN IS WRONG. An export row is one resource × one meter × one day.
//    `cost_daily` is one cost centre × one day. So rows are SUMMED into the
//    target grain; that aggregation is the normalisation, not a nicety.
//
// 5. THE MONTH IS RE-EXPORTED EVERY DAY. A daily MonthToDate export contains
//    the whole month so far, restated. That is handled downstream in ingest.ts
//    by replacing the whole month partition — see the note there.
//
// COST CENTRE RESOLUTION. The demo's L2 policy makes `costCenter` a required tag
// and inherits it onto resources, so the tag is the primary source. Two
// fallbacks exist because policy inheritance is not instantaneous and some
// resource types cannot be tagged at all: an explicit resource-group map, then a
// configured catch-all. An unresolvable row is NOT dropped — it lands in the
// catch-all centre, because a cost that vanishes from the dashboard is worse
// than a cost filed under "Unallocated".
// =============================================================================

import type { CsvRecord, CsvTable } from "./csv.ts";
import { compareCostDaily, makeCostId, type CostDailyRow } from "./costDaily.ts";

/** Thrown when the file is not a Cost Management export at all. */
export class CostExportFormatError extends Error {
  readonly headers: readonly string[];

  constructor(message: string, headers: readonly string[]) {
    super(message);
    this.name = "CostExportFormatError";
    this.headers = headers;
  }
}

export type NormaliseConfig = {
  /** Daily budget per cost centre, USD. Missing centre -> budget_usd null. */
  readonly costCenterBudgets?: Readonly<Record<string, number>>;
  /** Resource-group name (lower-cased) -> cost centre, for untaggable rows. */
  readonly resourceGroupCostCenters?: Readonly<Record<string, string>>;
  /** Where rows with no resolvable cost centre land. */
  readonly fallbackCostCenter?: string;
  /** Currency assumed when the export carries no currency column. */
  readonly defaultCurrency?: string;
};

export type RejectedRow = {
  readonly reason: string;
  readonly record: CsvRecord;
};

export type NormaliseResult = {
  readonly rows: readonly CostDailyRow[];
  readonly rejected: readonly RejectedRow[];
  /** Which header each logical field resolved to — logged, and worth logging. */
  readonly resolvedColumns: Readonly<Record<string, string | null>>;
};

// --- column aliases (ordered: first match wins) ------------------------------

const DATE_ALIASES = [
  "usagedate",
  "date",
  "usagedatetime",
  "chargeperiodstart",
  "servicedate",
] as const;

// Ordered by preference. A USD-denominated column is preferred over a
// billing-currency one because the target column is literally `amount_usd`.
const AMOUNT_ALIASES = [
  "costinusd",
  "pretaxcostinusd",
  "cost",
  "costinbillingcurrency",
  "pretaxcost",
  "billedcost",
  "effectivecost",
  "paygcostinbillingcurrency",
] as const;

const CURRENCY_ALIASES = [
  "billingcurrency",
  "billingcurrencycode",
  "currency",
  "currencycode",
  "pricingcurrency",
] as const;

const TAGS_ALIASES = ["tags", "tag"] as const;

const RESOURCE_GROUP_ALIASES = [
  "resourcegroup",
  "resourcegroupname",
  "resourcegroupid",
] as const;

/** Header names compare case-insensitively with spaces and underscores gone. */
function canonical(header: string): string {
  return header.toLowerCase().replace(/[\s_-]+/g, "");
}

/** Resolves the first alias present in the header row, or null. */
export function resolveColumn(
  headers: readonly string[],
  aliases: readonly string[],
): string | null {
  const byCanonical = new Map<string, string>();
  for (const header of headers) {
    const key = canonical(header);
    if (!byCanonical.has(key)) byCanonical.set(key, header);
  }
  for (const alias of aliases) {
    const found = byCanonical.get(alias);
    if (found !== undefined) return found;
  }
  return null;
}

// --- scalar coercion ---------------------------------------------------------

const ISO_DATE = /^(\d{4})-(\d{2})-(\d{2})/;
const US_DATE = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/;
const COMPACT_DATE = /^(\d{4})(\d{2})(\d{2})$/;

function isRealDate(year: number, month: number, day: number): boolean {
  if (month < 1 || month > 12 || day < 1 || day > 31) return false;
  const probe = new Date(Date.UTC(year, month - 1, day));
  return (
    probe.getUTCFullYear() === year &&
    probe.getUTCMonth() === month - 1 &&
    probe.getUTCDate() === day
  );
}

function pad(value: number, width: number): string {
  return String(value).padStart(width, "0");
}

/**
 * ISO / US / compact-integer date text -> `YYYY-MM-DD`, or null when the value
 * is not a date this Function is willing to guess at.
 */
export function parseExportDate(value: string | undefined): string | null {
  const text = (value ?? "").trim();
  if (text === "") return null;

  const iso = ISO_DATE.exec(text);
  if (iso) {
    const [, y, m, d] = iso;
    return isRealDate(Number(y), Number(m), Number(d)) ? `${y}-${m}-${d}` : null;
  }

  const us = US_DATE.exec(text);
  if (us) {
    const [, m, d, y] = us;
    return isRealDate(Number(y), Number(m), Number(d))
      ? `${y}-${pad(Number(m), 2)}-${pad(Number(d), 2)}`
      : null;
  }

  const compact = COMPACT_DATE.exec(text);
  if (compact) {
    const [, y, m, d] = compact;
    return isRealDate(Number(y), Number(m), Number(d)) ? `${y}-${m}-${d}` : null;
  }

  return null;
}

/**
 * Amount text -> number, or null.
 *
 * Handles thousands separators, a leading currency symbol, scientific notation
 * and accounting-style parenthesised negatives. Returns null — never 0 — for a
 * blank or unparseable value, so a broken cell cannot masquerade as free usage.
 */
export function parseAmount(value: string | undefined): number | null {
  let text = (value ?? "").trim();
  if (text === "") return null;

  let negative = false;
  if (/^\(.*\)$/.test(text)) {
    negative = true;
    text = text.slice(1, -1).trim();
  }

  // Strip a leading currency symbol/code and any thousands separators. Commas
  // are separators here, not decimal points: Cost Management writes invariant
  // culture regardless of the tenant's locale.
  text = text.replace(/^[^\d+\-.]+/, "").replace(/,/g, "");
  if (text.startsWith("-")) {
    negative = !negative;
    text = text.slice(1);
  }
  if (text.startsWith("+")) text = text.slice(1);

  if (!/^\d*\.?\d+(?:[eE][+-]?\d+)?$/.test(text)) return null;

  const parsed = Number(text);
  if (!Number.isFinite(parsed)) return null;
  return negative ? -parsed : parsed;
}

/**
 * Extracts tags from the export's `Tags` cell, whose format is version-dependent.
 * Seen in the wild, all three handled:
 *
 *   {"costCenter":"Propulsion","env":"demo"}   (JSON object)
 *   "costCenter": "Propulsion","env": "demo"   (object with the braces stripped)
 *   costCenter:Propulsion;env:demo             (legacy unquoted pairs)
 */
export function parseTags(value: string | undefined): Record<string, string> {
  const text = (value ?? "").trim();
  if (text === "") return {};

  const asJson = text.startsWith("{") ? text : `{${text}}`;
  try {
    const parsed: unknown = JSON.parse(asJson);
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      const out: Record<string, string> = {};
      for (const [key, raw] of Object.entries(parsed as Record<string, unknown>)) {
        out[key.trim()] = raw === null || raw === undefined ? "" : String(raw).trim();
      }
      return out;
    }
  } catch {
    // Fall through to the legacy pair scan below.
  }

  const out: Record<string, string> = {};
  const pairs = text.startsWith("{") && text.endsWith("}") ? text.slice(1, -1) : text;
  for (const pair of pairs.split(/[;,]/)) {
    const separator = pair.indexOf(":");
    if (separator <= 0) continue;
    const key = pair.slice(0, separator).trim().replace(/^"|"$/g, "");
    const raw = pair.slice(separator + 1).trim().replace(/^"|"$/g, "");
    if (key !== "") out[key] = raw;
  }
  return out;
}

/** Tag lookup is case-insensitive: `costCenter`, `CostCenter` and `costcenter`. */
function tagValue(tags: Record<string, string>, name: string): string | undefined {
  const want = name.toLowerCase();
  for (const [key, value] of Object.entries(tags)) {
    if (key.toLowerCase() === want && value.trim() !== "") return value.trim();
  }
  return undefined;
}

// --- normalisation -----------------------------------------------------------

/**
 * Turns a parsed export into `cost_daily` rows at the (date, cost_center) grain.
 *
 * Throws CostExportFormatError only when the file cannot be a cost export at
 * all — no recognisable date or amount column. Everything else degrades: bad
 * rows are rejected individually and reported, because one poisoned meter row
 * must not cost the estate a whole day of cost history.
 */
export function normaliseExport(table: CsvTable, config: NormaliseConfig = {}): NormaliseResult {
  const dateColumn = resolveColumn(table.headers, DATE_ALIASES);
  const amountColumn = resolveColumn(table.headers, AMOUNT_ALIASES);
  const currencyColumn = resolveColumn(table.headers, CURRENCY_ALIASES);
  const tagsColumn = resolveColumn(table.headers, TAGS_ALIASES);
  const groupColumn = resolveColumn(table.headers, RESOURCE_GROUP_ALIASES);

  const resolvedColumns = {
    date: dateColumn,
    amount: amountColumn,
    currency: currencyColumn,
    tags: tagsColumn,
    resourceGroup: groupColumn,
  };

  if (dateColumn === null || amountColumn === null) {
    const missing = [
      dateColumn === null ? `date (any of: ${DATE_ALIASES.join(", ")})` : null,
      amountColumn === null ? `amount (any of: ${AMOUNT_ALIASES.join(", ")})` : null,
    ].filter((entry): entry is string => entry !== null);
    throw new CostExportFormatError(
      `Not a recognisable Cost Management export: no ${missing.join(" and no ")}. ` +
        `Headers seen: ${table.headers.length > 0 ? table.headers.join(", ") : "(none)"}.`,
      table.headers,
    );
  }

  const fallbackCostCenter = config.fallbackCostCenter ?? "Unallocated";
  const defaultCurrency = config.defaultCurrency ?? "USD";
  const budgets = config.costCenterBudgets ?? {};
  const groupMap = config.resourceGroupCostCenters ?? {};

  const rejected: RejectedRow[] = [];
  // Accumulate at the target grain. Keyed by `${date} ${costCenter}`.
  const totals = new Map<
    string,
    { date: string; costCenter: string; amount: number; currency: string }
  >();

  for (const record of table.records) {
    const date = parseExportDate(record[dateColumn]);
    if (date === null) {
      rejected.push({ reason: `unparseable date in column '${dateColumn}'`, record });
      continue;
    }

    const amount = parseAmount(record[amountColumn]);
    if (amount === null) {
      rejected.push({ reason: `unparseable amount in column '${amountColumn}'`, record });
      continue;
    }

    const tags = tagsColumn ? parseTags(record[tagsColumn]) : {};
    const group = groupColumn ? (record[groupColumn] ?? "").trim().toLowerCase() : "";
    const costCenter =
      tagValue(tags, "costCenter") ?? groupMap[group] ?? fallbackCostCenter;

    const currency =
      (currencyColumn ? (record[currencyColumn] ?? "").trim().toUpperCase() : "") ||
      defaultCurrency;

    const key = `${date} ${costCenter}`;
    const existing = totals.get(key);
    if (existing) {
      existing.amount += amount;
      // A mixed-currency day is a real (if rare) condition. Keep the first code
      // and let the reconciliation show up as a currency mismatch downstream
      // rather than silently averaging two denominations.
      continue;
    }
    totals.set(key, { date, costCenter, amount, currency });
  }

  const rows = [...totals.values()]
    .map((entry): CostDailyRow => {
      const budget = budgets[entry.costCenter];
      return {
        cost_id: makeCostId(entry.date, entry.costCenter),
        date: entry.date,
        cost_center: entry.costCenter,
        // Round once, at the end: rounding each meter row first would drift.
        amount_usd: Math.round((entry.amount + Number.EPSILON) * 100) / 100,
        budget_usd: typeof budget === "number" && Number.isFinite(budget) ? budget : null,
        currency: entry.currency,
      };
    })
    .sort(compareCostDaily);

  return { rows, rejected, resolvedColumns };
}
