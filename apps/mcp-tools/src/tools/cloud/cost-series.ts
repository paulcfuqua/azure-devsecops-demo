/**
 * `get_cost_series` — CLOUD adapter: the Azure Cost Management query API.
 *
 *   POST {scope}/providers/Microsoft.CostManagement/query?api-version=2023-03-01
 *
 * This is the adapter that does the most work, because the API's answer and the
 * tool's contract are not the same thing:
 *
 *   API gives  : rows keyed by whatever grouping was asked for, a `UsageDate`
 *                as the integer 20260131, a `Cost` column, a `Currency` column,
 *                and NO budget at all — budgets live in a different provider.
 *   Tool owes  : `properties.rows` = [date (ISO YYYY-MM-DD), cost_center,
 *                amount_usd, budget_usd], one row per date per cost center,
 *                ordered by date — because that is what the description
 *                promises and what the local `cost_daily` adapter returns.
 *
 * So the adapter: groups by the `costCenter` tag (the tag CLAUDE.md already
 * mandates on every resource group), converts `20260131` to `2026-01-31`, sums
 * duplicate (date, cost_center) pairs that differ only in a column the contract
 * does not carry, joins a per-day budget derived from
 * `Microsoft.Consumption/budgets`, sorts, and caps at 500 rows.
 *
 * Auth: managed identity, scope `https://management.azure.com/.default`. The
 * identity needs `Cost Management Reader` on the scope (and `Reader` for the
 * budgets read).
 *
 * Pagination: `properties.nextLink`. The query API's nextLink is followed with
 * the SAME POST body, which is why it does not use the shared `pageByNextLink`
 * helper (that one is for ARM's GET-style `{value, nextLink}` lists).
 */
import { AdapterError } from "../errors.js";
import {
  HttpClient,
  MAX_PAGES,
  type FetchLike,
  type HttpJsonResponse,
  type RetryPolicy,
} from "../http.js";
import { SCOPES, type TokenProvider } from "../auth.js";
import { MAX_RESULT_ROWS } from "../sql-dialect.js";
import type { CostSeriesBackend, CostSeriesParams, CostSeriesResult } from "../backends.js";

export const DEFAULT_ARM_ENDPOINT = "https://management.azure.com";
export const COST_QUERY_API_VERSION = "2023-03-01";
export const BUDGETS_API_VERSION = "2023-05-01";
/** The tag every MLS resource group carries (CLAUDE.md § Naming and tagging). */
export const DEFAULT_COST_CENTER_TAG = "costCenter";
/** Widest window requested when the caller gives no dates. Daily granularity. */
export const DEFAULT_LOOKBACK_DAYS = 365;

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

/** One page of the Cost Management query response. */
export interface CostQueryEnvelope {
  id?: string;
  name?: string;
  properties?: {
    nextLink?: string | null;
    columns?: Array<{ name: string; type: string }>;
    rows?: unknown[][];
  };
}
type CostQueryPage = HttpJsonResponse<CostQueryEnvelope>;

export interface AzureCostSeriesOptions {
  /**
   * Cost Management scope, e.g. `/subscriptions/{id}` or
   * `/subscriptions/{id}/resourceGroups/mls-rg-apps`.
   */
  scope: string;
  tokens: TokenProvider;
  armEndpoint?: string;
  /** Tag key carrying the cost center. */
  costCenterTag?: string;
  fetchImpl?: FetchLike;
  retry?: Partial<RetryPolicy>;
  sleep?: (ms: number) => Promise<void>;
  /** Injected by tests so "no end_date" is deterministic. */
  today?: () => Date;
}

/** `20260131` | `"2026-01-31T00:00:00"` | `"2026-01-31"` -> `"2026-01-31"`. */
export function normalizeUsageDate(value: unknown): string {
  if (typeof value === "number" && Number.isInteger(value) && value >= 10_000_101) {
    const s = String(value);
    return `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}`;
  }
  const text = String(value ?? "");
  if (ISO_DATE.test(text)) return text;
  const parsed = Date.parse(text);
  if (!Number.isNaN(parsed)) return new Date(parsed).toISOString().slice(0, 10);
  return text;
}

/** Days in the calendar month containing an ISO date — used to prorate a monthly budget. */
export function daysInMonthOf(isoDate: string): number {
  const year = Number(isoDate.slice(0, 4));
  const month = Number(isoDate.slice(5, 7));
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

interface BudgetRecord {
  /** Lower-cased cost-center value this budget applies to, or undefined for "all". */
  costCenter: string | undefined;
  amount: number;
  timeGrain: string;
}

/**
 * A budget's per-day allowance for a given date. Cost Management budgets are
 * stated per time grain, and the tool's contract is per day, so a Monthly budget
 * is divided by the days in *that* month (not by 30 — February would be wrong by
 * 7%, and this number is compared against real spend on stage).
 */
export function budgetPerDay(budget: BudgetRecord, isoDate: string): number {
  switch (budget.timeGrain.toLowerCase()) {
    case "monthly":
      return budget.amount / daysInMonthOf(isoDate);
    case "quarterly":
      return budget.amount / 91.25;
    case "annually":
    case "annual":
      return budget.amount / 365;
    default:
      return budget.amount;
  }
}

export class AzureCostSeriesBackend implements CostSeriesBackend {
  readonly scope: string;
  private readonly armEndpoint: string;
  private readonly costCenterTag: string;
  private readonly tokens: TokenProvider;
  private readonly http: HttpClient;
  private readonly today: () => Date;

  constructor(options: AzureCostSeriesOptions) {
    if (!options.scope || !options.scope.startsWith("/")) {
      throw new AdapterError(
        "config",
        `get_cost_series needs a Cost Management scope starting with "/" ` +
          `(e.g. /subscriptions/<id>); got ${JSON.stringify(options.scope)}`,
        { service: "cost-management" },
      );
    }
    this.scope = options.scope.replace(/\/+$/, "");
    this.armEndpoint = (options.armEndpoint ?? DEFAULT_ARM_ENDPOINT).replace(/\/+$/, "");
    this.costCenterTag = options.costCenterTag ?? DEFAULT_COST_CENTER_TAG;
    this.tokens = options.tokens;
    this.today = options.today ?? (() => new Date());
    this.http = new HttpClient({
      service: "cost-management",
      ...(options.fetchImpl ? { fetchImpl: options.fetchImpl } : {}),
      ...(options.retry ? { retry: options.retry } : {}),
      ...(options.sleep ? { sleep: options.sleep } : {}),
    });
  }

  async getSeries(params: CostSeriesParams): Promise<CostSeriesResult> {
    const { from, to } = this.resolveWindow(params);
    const headers = await this.tokens.authHeader(SCOPES.arm);

    const body: Record<string, unknown> = {
      type: "ActualCost",
      timeframe: "Custom",
      timePeriod: { from: `${from}T00:00:00Z`, to: `${to}T23:59:59Z` },
      dataset: {
        granularity: "Daily",
        aggregation: { totalCost: { name: "Cost", function: "Sum" } },
        grouping: [{ type: "TagKey", name: this.costCenterTag }],
        ...(params.cost_center
          ? {
              filter: {
                tags: {
                  name: this.costCenterTag,
                  operator: "In",
                  values: [params.cost_center],
                },
              },
            }
          : {}),
      },
    };

    const queryUrl =
      `${this.armEndpoint}${this.scope}/providers/Microsoft.CostManagement/query` +
      `?api-version=${COST_QUERY_API_VERSION}`;

    // The query API pages with properties.nextLink, re-POSTing the SAME body —
    // which is why this does not use the shared pageByNextLink helper (that one
    // re-issues a GET).
    let url: string | undefined = queryUrl;
    let envelope: { id?: string; name?: string } = {};
    let columns: Array<{ name: string; type: string }> = [];
    const rawRows: unknown[][] = [];
    for (let page = 0; page < MAX_PAGES && url !== undefined; page += 1) {
      const pageUrl: string = url;
      const response: CostQueryPage = await this.http.requestJson<CostQueryEnvelope>({
        url: pageUrl,
        method: "POST",
        headers,
        body,
      });
      if (page === 0) {
        envelope = {
          ...(response.body.id ? { id: response.body.id } : {}),
          ...(response.body.name ? { name: response.body.name } : {}),
        };
      }
      columns = response.body.properties?.columns ?? columns;
      rawRows.push(...(response.body.properties?.rows ?? []));
      const next: string | null | undefined = response.body.properties?.nextLink;
      url = next ? next : undefined;
      // Aggregation collapses rows, so stop only well past the cap.
      if (rawRows.length >= MAX_RESULT_ROWS * MAX_PAGES) break;
    }

    const budgets = await this.fetchBudgets(headers);
    const rows = this.project(columns, rawRows, budgets);

    return {
      id: envelope.id ?? `${this.scope}/providers/Microsoft.CostManagement/query`,
      name: envelope.name ?? "query",
      type: "Microsoft.CostManagement/query",
      properties: {
        // The contract's four columns, not the API's — the description names
        // these, and an agent that read it is entitled to find them.
        columns: [
          { name: "date", type: "String" },
          { name: "cost_center", type: "String" },
          { name: "amount_usd", type: "Number" },
          { name: "budget_usd", type: "Number" },
        ],
        rows,
      },
    };
  }

  /** Inclusive ISO window; defaults to the last DEFAULT_LOOKBACK_DAYS ending today. */
  private resolveWindow(params: CostSeriesParams): { from: string; to: string } {
    for (const [key, value] of Object.entries({
      start_date: params.start_date,
      end_date: params.end_date,
    })) {
      if (value !== undefined && !ISO_DATE.test(String(value))) {
        throw new AdapterError(
          "bad_request",
          `get_cost_series ${key} must be an ISO date like 2026-01-31 (got ${JSON.stringify(value)})`,
          { service: "cost-management" },
        );
      }
    }
    const to = params.end_date ?? this.today().toISOString().slice(0, 10);
    const from =
      params.start_date ??
      new Date(Date.parse(`${to}T00:00:00Z`) - DEFAULT_LOOKBACK_DAYS * 86_400_000)
        .toISOString()
        .slice(0, 10);
    if (from > to) {
      throw new AdapterError(
        "bad_request",
        `get_cost_series start_date (${from}) is after end_date (${to})`,
        { service: "cost-management" },
      );
    }
    return { from, to };
  }

  /**
   * Column-name lookup rather than positional indexing: the query API's column
   * order varies with the grouping and the api-version, and a positional read
   * would put the currency in the amount field the day Microsoft adds a column.
   */
  private project(
    columns: Array<{ name: string; type: string }>,
    rawRows: unknown[][],
    budgets: BudgetRecord[],
  ): Array<[string, string, number, number]> {
    const indexOf = (...candidates: string[]): number =>
      columns.findIndex((c) => candidates.some((n) => n.toLowerCase() === c.name?.toLowerCase()));

    const costIndex = indexOf("Cost", "CostUSD", "PreTaxCost", "PreTaxCostUSD");
    const dateIndex = indexOf("UsageDate", "Date", "BillingMonth");
    // Tag grouping surfaces either as a TagValue column or as a column named
    // after the tag key, depending on api-version. Accept both.
    const centerIndex = indexOf("TagValue", this.costCenterTag);

    if (costIndex < 0 || dateIndex < 0) {
      throw new AdapterError(
        "upstream",
        `Cost Management returned columns this adapter cannot map ` +
          `(${columns.map((c) => c.name).join(", ") || "none"}). Expected a Cost column and a ` +
          `UsageDate column from a Daily ActualCost query.`,
        { service: "cost-management" },
      );
    }

    // Sum duplicates: two API rows can differ only in a column the contract
    // does not carry (Currency, ResourceGroup) and must not become two rows here.
    const totals = new Map<string, { date: string; center: string; amount: number }>();
    for (const row of rawRows) {
      const date = normalizeUsageDate(row[dateIndex]);
      const center = centerIndex >= 0 ? String(row[centerIndex] ?? "") : "";
      const amount = Number(row[costIndex] ?? 0);
      const key = `${date} ${center}`;
      const existing = totals.get(key);
      if (existing) existing.amount += amount;
      else totals.set(key, { date, center, amount });
    }

    const ordered = [...totals.values()].sort(
      (a, b) => a.date.localeCompare(b.date) || a.center.localeCompare(b.center),
    );

    return ordered.slice(0, MAX_RESULT_ROWS).map((entry) => {
      const budget = budgets.find(
        (b) => b.costCenter === undefined || b.costCenter === entry.center.toLowerCase(),
      );
      const budgetUsd = budget ? Number(budgetPerDay(budget, entry.date).toFixed(2)) : 0;
      return [
        entry.date,
        entry.center,
        Number(entry.amount.toFixed(2)),
        budgetUsd,
      ] as [string, string, number, number];
    });
  }

  /**
   * Budgets are a different provider and a soft dependency: a scope with no
   * budgets, or an identity without permission to read them, yields
   * `budget_usd: 0` rather than failing the whole cost question. The contract's
   * shape is preserved either way — a missing budget must not become a missing
   * column.
   */
  private async fetchBudgets(headers: Record<string, string>): Promise<BudgetRecord[]> {
    try {
      const response = await this.http.requestJson<{
        value?: Array<{
          name?: string;
          properties?: {
            category?: string;
            amount?: number;
            timeGrain?: string;
            filter?: {
              tags?: { name?: string; operator?: string; values?: string[] };
              and?: Array<{ tags?: { name?: string; values?: string[] } }>;
            };
          };
        }>;
      }>({
        url:
          `${this.armEndpoint}${this.scope}/providers/Microsoft.Consumption/budgets` +
          `?api-version=${BUDGETS_API_VERSION}`,
        headers,
      });

      const records: BudgetRecord[] = [];
      for (const budget of response.body.value ?? []) {
        const properties = budget.properties ?? {};
        if (properties.category && properties.category.toLowerCase() !== "cost") continue;
        if (typeof properties.amount !== "number") continue;
        const tagFilter =
          properties.filter?.tags ??
          properties.filter?.and?.map((clause) => clause.tags).find((t) => t?.name);
        const tagValue =
          tagFilter?.name?.toLowerCase() === this.costCenterTag.toLowerCase()
            ? tagFilter?.values?.[0]
            : undefined;
        records.push({
          costCenter: (tagValue ?? budget.name)?.toLowerCase(),
          amount: properties.amount,
          timeGrain: properties.timeGrain ?? "Monthly",
        });
      }
      // A budget with no cost-center tag applies to everything; try the specific
      // ones first so a scoped budget wins over the catch-all.
      return records.sort((a, b) => Number(a.costCenter === undefined) - Number(b.costCenter === undefined));
    } catch {
      return [];
    }
  }
}
