/**
 * The allowlists — the only two places a caller-supplied string is turned into
 * anything at all.
 *
 * `GET /tables/:table` and `GET /feeds/:name` take a path segment from the
 * open internet. That segment is matched against these frozen tuples and
 * **discarded**: what flows onward is the matched literal, and every SQL
 * object name, column list and upstream URL is looked up from a constant keyed
 * by that literal. No caller string is ever concatenated into SQL, a URL path,
 * or a file path. That is the whole design; guardrail rule 3 is structural
 * here, not a validation step someone can forget to call.
 */

/* ------------------------------------------------------------------ */
/* tables                                                              */
/* ------------------------------------------------------------------ */

/** The ten Track A generator tables, in generator order. */
export const TABLE_NAMES = [
  "launches",
  "scrubs",
  "vehicles",
  "pads",
  "parts",
  "suppliers",
  "work_orders",
  "telemetry_summary",
  "cost_daily",
  "findings_history",
] as const;

export type TableName = (typeof TABLE_NAMES)[number];

const TABLE_SET: ReadonlySet<string> = new Set(TABLE_NAMES);

export function isAllowedTable(name: string): name is TableName {
  return TABLE_SET.has(name);
}

/**
 * Where each table lives once the tenant exists.
 *
 *   sql       — Azure SQL serverless, the operational/CRUD store (L6). These
 *               are the tables launch-ops treats as records of fact.
 *   lakehouse — the Fabric lakehouse SQL analytics endpoint (L5). These are
 *               the rollups and exports: telemetry, cost, findings history.
 *
 * L7's brief is literally "SQL-backed CRUD + lakehouse-backed analytics
 * views", and this constant is that sentence made executable.
 */
export type TableStore = "sql" | "lakehouse";

export const TABLE_STORE: Record<TableName, TableStore> = {
  launches: "sql",
  scrubs: "sql",
  vehicles: "sql",
  pads: "sql",
  parts: "sql",
  suppliers: "sql",
  work_orders: "sql",
  telemetry_summary: "lakehouse",
  cost_daily: "lakehouse",
  findings_history: "lakehouse",
};

/* ------------------------------------------------------------------ */
/* field specs                                                         */
/* ------------------------------------------------------------------ */

export type FieldType = "string" | "number" | "boolean";

export interface FieldSpec {
  /** Column name — identical in the generator JSON, the T-SQL DDL and the wire. */
  readonly name: string;
  readonly type: FieldType;
  /** True when the frontend row type declares `| null` for this field. */
  readonly nullable: boolean;
  /**
   * True for `date`-typed columns. A TDS driver hands these back as JS `Date`;
   * the contract is an ISO `YYYY-MM-DD` string, so the cloud adapter narrows
   * them. The local adapter never sees a Date — JSON has no date type.
   */
  readonly date?: boolean;
}

function f(
  name: string,
  type: FieldType,
  nullable = false,
  date = false,
): FieldSpec {
  return date ? { name, type, nullable, date } : { name, type, nullable };
}

/**
 * Per-table field spec. Nullability mirrors the frontend row types where one
 * exists (they are the authority and are deliberately defensive about fields
 * the generators dirty), and the generator output otherwise.
 *
 * This drives three things at once: the served column list, the runtime shape
 * assertion in the tests, and the SQL projection. One source, so they cannot
 * disagree.
 */
export const TABLE_FIELDS: Record<TableName, readonly FieldSpec[]> = {
  launches: [
    f("launch_id", "string"),
    f("mission_name", "string"),
    f("vehicle_id", "string"),
    f("pad_id", "string"),
    f("customer", "string", true),
    f("orbit", "string", true),
    f("planned_date", "string", false, true),
    f("actual_date", "string", true, true),
    f("outcome", "string"),
    f("payload_mass_kg", "number", true),
    f("weather_delay_min", "number", true),
    f("scrub_count", "number"),
    f("booster_recovery", "string", true),
    f("insurance_value_musd", "number", true),
  ],
  scrubs: [
    f("scrub_id", "string"),
    f("launch_id", "string"),
    f("scrub_date", "string", false, true),
    f("category", "string"),
    f("reason", "string", true),
    f("called_at_t_minus_s", "number", true),
    f("recycle_hours", "number", true),
  ],
  vehicles: [
    f("vehicle_id", "string"),
    f("name", "string"),
    f("vehicle_class", "string", true),
    f("fleet_group", "string", true),
    f("stages", "number", true),
    f("reusable", "boolean", true),
    f("leo_capacity_kg", "number", true),
    f("gto_capacity_kg", "number", true),
    f("height_m", "number", true),
    f("first_flight_year", "number", true),
    f("last_flight_year", "number", true),
    f("status", "string", true),
  ],
  pads: [
    f("pad_id", "string"),
    f("name", "string"),
    f("site", "string", true),
    f("country", "string", true),
    f("latitude", "number", true),
    f("longitude", "number", true),
    f("first_used_year", "number", true),
    f("status", "string", true),
  ],
  parts: [
    f("part_id", "string"),
    f("part_number", "string"),
    f("name", "string"),
    f("category", "string"),
    f("supplier_id", "string"),
    f("unit_cost_usd", "number"),
    f("lead_time_days", "number"),
    f("qty_on_hand", "number"),
    f("min_stock", "number"),
    f("criticality", "number"),
    f("material", "string", true),
  ],
  suppliers: [
    f("supplier_id", "string"),
    f("name", "string"),
    f("country", "string"),
    f("certification", "string"),
    f("avg_lead_time_days", "number"),
    f("on_time_pct", "number"),
    f("quality_rating", "number"),
    f("active", "boolean"),
  ],
  work_orders: [
    f("work_order_id", "string"),
    f("part_id", "string"),
    f("vehicle_id", "string"),
    f("launch_id", "string", true),
    f("opened_date", "string", false, true),
    f("closed_date", "string", true, true),
    f("status", "string"),
    f("disposition", "string", true),
    f("priority", "string"),
    f("labor_hours", "number"),
    f("technician", "string"),
  ],
  telemetry_summary: [
    f("telemetry_id", "string"),
    f("launch_id", "string"),
    f("max_q_kpa", "number", true),
    f("max_accel_g", "number", true),
    f("meco_time_s", "number", true),
    f("peak_thrust_kn", "number", true),
    f("max_altitude_km", "number", true),
    f("anomaly_count", "number"),
    f("telemetry_coverage_pct", "number", true),
    f("data_dropout_s", "number", true),
  ],
  cost_daily: [
    f("cost_id", "string"),
    f("date", "string", false, true),
    f("cost_center", "string"),
    f("amount_usd", "number"),
    f("budget_usd", "number"),
    f("currency", "string"),
  ],
  findings_history: [
    f("finding_id", "string"),
    f("source", "string"),
    f("severity", "string"),
    f("title", "string"),
    f("component", "string"),
    f("cve_id", "string", true),
    f("opened_date", "string", false, true),
    f("closed_date", "string", true, true),
    f("status", "string"),
    f("assignee", "string"),
    f("sla_days", "number"),
  ],
};

/**
 * Stable ordering key per table, so a capped response is the *same* capped
 * response every time (and matches the generator's own file order). Primary
 * key everywhere — the generators emit ascending-PK files.
 */
export const TABLE_ORDER_BY: Record<TableName, string> = {
  launches: "launch_id",
  scrubs: "scrub_id",
  vehicles: "vehicle_id",
  pads: "pad_id",
  parts: "part_id",
  suppliers: "supplier_id",
  work_orders: "work_order_id",
  telemetry_summary: "telemetry_id",
  cost_daily: "cost_id",
  findings_history: "finding_id",
};

/* ------------------------------------------------------------------ */
/* feeds                                                               */
/* ------------------------------------------------------------------ */

/** The six feeds the control tower's ApiProvider fetches, in tab order. */
export const FEED_NAMES = [
  "workflow-runs",
  "app-requests",
  "code-scanning-alerts",
  "dependabot-alerts",
  "secure-score",
  "secure-score-controls",
] as const;

export type FeedName = (typeof FEED_NAMES)[number];

const FEED_SET: ReadonlySet<string> = new Set(FEED_NAMES);

export function isAllowedFeed(name: string): name is FeedName {
  return FEED_SET.has(name);
}

/** Which upstream each feed proxies — reported on /healthz, used for spans. */
export type FeedUpstream = "github" | "defender" | "log-analytics";

export const FEED_UPSTREAM: Record<FeedName, FeedUpstream> = {
  "workflow-runs": "github",
  "code-scanning-alerts": "github",
  "dependabot-alerts": "github",
  "secure-score": "defender",
  "secure-score-controls": "defender",
  "app-requests": "log-analytics",
};

/** Committed local fixture backing each feed in LOCAL mode. */
export const FEED_FIXTURE: Record<FeedName, string> = {
  "workflow-runs": "github-workflow-runs.json",
  "code-scanning-alerts": "github-code-scanning-alerts.json",
  "dependabot-alerts": "github-dependabot-alerts.json",
  "secure-score": "defender-secure-score.json",
  "secure-score-controls": "defender-secure-score-controls.json",
  "app-requests": "log-analytics-app-requests.json",
};

/** Feeds whose payload is a bare JSON array (the rest are objects). */
export const FEED_IS_ARRAY: Record<FeedName, boolean> = {
  "workflow-runs": false,
  "code-scanning-alerts": true,
  "dependabot-alerts": true,
  "secure-score": false,
  "secure-score-controls": false,
  "app-requests": false,
};
