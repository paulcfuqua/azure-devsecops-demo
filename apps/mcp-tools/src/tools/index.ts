/**
 * Tool registry — EXACTLY six tools are exposed over MCP, and the server
 * refuses any tools/call whose name is not on this allowlist (master plan L8 /
 * audit V8.2). Do not add tools here without a master-plan change. (Task 14
 * added the sixth, query_compliance, alongside the original five.)
 *
 * THESE DESCRIPTIONS ARE AGENT-FACING SURFACE AREA. The Copilot Studio agent's
 * orchestrator reads nothing else about these tools: name, description and
 * input JSON Schema are the entire contract it reasons over when deciding which
 * tool to call and with what arguments. Editing a description changes agent
 * behaviour as surely as editing code — treat it as a behavioural change and
 * re-run `npm run eval`.
 *
 * ── Why `query_lakehouse_sql`'s description is BUILT, not written ────────────
 * Its SQL idioms depend on which engine is actually behind it. On the local
 * backend that is SQLite; on the cloud backend it is the Fabric SQL analytics
 * endpoint, which speaks T-SQL and has no `strftime` at all. A single hardcoded
 * description is therefore wrong in one of the two modes — and it *was*: the
 * committed text instructed the agent to use `strftime('%w', actual_date)`,
 * which would have failed every date question the moment the tenant came up.
 * So the description is generated from the active backend's declared dialect and
 * `tools/list` always advertises the idioms of the engine the query will hit.
 * See src/tools/sql-dialect.ts for the full reasoning.
 */
import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import type { Backends, ComplianceQueryParams, CostSeriesParams, CostSource } from "./backends.js";
import { DIALECTS, MAX_RESULT_ROWS, type DialectProfile, type SqlDialect } from "./sql-dialect.js";

export const ALLOWED_TOOL_NAMES = [
  "query_lakehouse_sql",
  "query_log_analytics",
  "get_github_security",
  "get_defender_posture",
  "get_cost_series",
  "query_compliance",
] as const;

export type AllowedToolName = (typeof ALLOWED_TOOL_NAMES)[number];

export function isAllowedTool(name: string): name is AllowedToolName {
  return (ALLOWED_TOOL_NAMES as readonly string[]).includes(name);
}

/**
 * The ten Track A tables, column by column. Identical in both dialects — the
 * lakehouse schema is the same data whether it is read from CSVs or from Delta
 * tables behind the SQL analytics endpoint.
 */
const LAKEHOUSE_SCHEMA =
  "launches(launch_id, mission_name, vehicle_id, pad_id, customer, orbit, planned_date, " +
  "actual_date, outcome IN ('success','failure','partial_failure'), payload_mass_kg, " +
  "weather_delay_min, scrub_count, booster_recovery, insurance_value_musd); " +
  "scrubs(scrub_id, launch_id, scrub_date, category IN ('weather','technical','range','payload'), " +
  "reason, called_at_t_minus_s, recycle_hours); " +
  "vehicles(vehicle_id, name, vehicle_class, fleet_group, stages, reusable, leo_capacity_kg, " +
  "gto_capacity_kg, height_m, first_flight_year, last_flight_year, status); " +
  "pads(pad_id, name, site, country, latitude, longitude, first_used_year, status); " +
  "telemetry_summary(telemetry_id, launch_id, max_q_kpa, max_accel_g, meco_time_s, " +
  "peak_thrust_kn, max_altitude_km, anomaly_count, telemetry_coverage_pct, data_dropout_s); " +
  "parts(part_id, part_number, name, category, supplier_id, unit_cost_usd, lead_time_days, " +
  "qty_on_hand, min_stock, criticality, material); " +
  "suppliers(supplier_id, name, country, certification, avg_lead_time_days, on_time_pct, " +
  "quality_rating, active); " +
  "work_orders(work_order_id, part_id, vehicle_id, launch_id, opened_date, closed_date, " +
  "status IN ('open','in_progress','closed'), disposition, priority, labor_hours, technician); " +
  "cost_daily(cost_id, date, cost_center, amount_usd, budget_usd, currency) — the launch " +
  "BUSINESS ledger, not cloud spend; " +
  "findings_history(finding_id, source, severity IN ('critical','high','medium','low'), title, " +
  "component, cve_id, opened_date, closed_date, status IN ('open','resolved','risk_accepted'), " +
  "assignee, sla_days).";

function lakehouseSqlTool(profile: DialectProfile): Tool {
  return {
    name: "query_lakehouse_sql",
    title: "Query the operations lakehouse (SQL)",
    description:
      `Run one read-only SQL query (${profile.displayName}) against the Meridian Launch Systems ` +
      "operations lakehouse and return columns and rows. Use this for any question about " +
      "launch history, scrubs, the vehicle fleet, pads, telemetry, parts, suppliers, work " +
      "orders, the launch business's own cost ledger, or security-finding history — counts, " +
      "rates, rankings, trends and joins across those tables. NOT for what this Azure " +
      "subscription costs: `cost_daily` is Meridian's internal business ledger (cost centres " +
      "and budgets for the launch business, in the millions), it is NOT a cloud bill, and it " +
      "must never be used to answer a question about Azure, tenant or subscription spend — " +
      "get_cost_series is the only tool that reads that. Schema: " +
      LAKEHOUSE_SCHEMA +
      " " +
      profile.idioms +
      " Exactly one SELECT or WITH statement is accepted; INSERT, UPDATE, DELETE and DDL are " +
      `refused. Results are capped at ${MAX_RESULT_ROWS} rows, so aggregate in SQL (COUNT, SUM, ` +
      "AVG, GROUP BY) rather than fetching raw rows.",
    inputSchema: {
      type: "object",
      properties: {
        sql: {
          type: "string",
          description:
            `A single read-only SELECT or WITH statement in ${profile.displayName}, e.g. ` +
            `"${profile.example}".`,
        },
      },
      required: ["sql"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true },
  };
}

/** The four tools whose description does not vary with the backend behind them. */
const STATIC_TOOLS: Tool[] = [
  {
    name: "query_log_analytics",
    title: "Query ops telemetry (KQL)",
    description:
      "Run a KQL query against the Meridian ops Azure Monitor Log Analytics workspace — the " +
      "application requests, traces and container logs of the deployed apps. Use this for " +
      "questions about service health, request latency, error and failure rates, or recent " +
      "runtime behaviour of the platform itself. Do NOT use it for business data: launches, " +
      "spend and security findings live in query_lakehouse_sql. Returns the Azure Monitor " +
      "query API shape { tables: [{ name, columns: [{ name, type }], rows: [[...]] }] }; the " +
      "primary table is named PrimaryResult and carries TimeGenerated (datetime), AppRoleName " +
      "(the app: mls-launch-ops, mls-control-tower, mls-mcp-tools), OperationName, DurationMs " +
      "(real), Success (bool) and ResultCode. Example query: " +
      "AppRequests | where Success == false | summarize failures = count() by AppRoleName.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "KQL query text, e.g. \"AppRequests | summarize avg(DurationMs) by AppRoleName\".",
        },
        timespan: {
          type: "string",
          description:
            "Optional ISO-8601 duration or interval bounding the query window, e.g. P1D " +
            "(last day) or PT4H (last four hours). Defaults to the workspace default.",
        },
      },
      required: ["query"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true },
  },
  {
    name: "get_github_security",
    title: "Get GitHub security alerts",
    description:
      "Fetch the current GitHub Advanced Security alert inventory for the repository behind " +
      "this platform: Dependabot dependency alerts and CodeQL code-scanning alerts, in the " +
      "GitHub REST API alert shapes. Use this for questions about vulnerabilities that are " +
      "open right now in the code or its dependencies — which packages or files are affected, " +
      "CVE/GHSA identifiers, severities, and what has been fixed. Returns " +
      "{ dependabot_alerts: [...], code_scanning_alerts: [...] }: each Dependabot item carries " +
      "number, state, dependency.package.name, dependency.manifest_path, " +
      "security_advisory.cve_id/ghsa_id/summary/severity and security_vulnerability." +
      "first_patched_version; each code-scanning item carries number, state, rule.id/severity, " +
      "tool.name and most_recent_instance.location. For historical or cross-scanner finding " +
      "counts (Trivy, ZAP, Defender included, with open/resolved status over time), query the " +
      "findings_history table with query_lakehouse_sql instead.",
    inputSchema: {
      type: "object",
      properties: {
        alert_type: {
          type: "string",
          enum: ["dependabot", "code_scanning", "all"],
          description:
            "Which alert families to return: dependabot (dependency alerts only), " +
            "code_scanning (CodeQL alerts only), or all. Defaults to all.",
        },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true },
  },
  {
    name: "get_defender_posture",
    title: "Get Defender for Cloud posture",
    description:
      "Fetch the current Microsoft Defender for Cloud security posture of the Meridian Azure " +
      "subscription: the overall secure score plus the per-control breakdown, in the ARM " +
      "Microsoft.Security/secureScores shape. Use this for questions about cloud security " +
      "posture, the secure score against its maximum, or which controls are failing " +
      "and how many resources are unhealthy under each. Takes no arguments and always reports " +
      "current state. Returns { secure_score: { properties: { displayName, score: { max, " +
      "current, percentage }, weight } }, controls: { value: [{ name, properties: { " +
      "displayName, score: { max, current, percentage }, healthyResourceCount, " +
      "unhealthyResourceCount, weight } }] } }. This is posture, not vulnerabilities: for " +
      "code and dependency alerts use get_github_security.",
    inputSchema: {
      type: "object",
      properties: {},
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true },
  },
  {
    name: "query_compliance",
    title: "Query NIST SP 800-171 compliance state",
    description:
      "Answer NIST SP 800-171 compliance questions from the same committed state artifact the " +
      "compliance board renders (compliance/state/state-latest.json) — one source of truth, not " +
      "a second opinion that can drift from the board. Optionally filter by control id (e.g. " +
      '"3.5.3"), family (e.g. "3.1"), framework ("nist-800-171r2" for the 110-requirement ' +
      'catalog, or "nist-800-53r5" for four records — CM-6, CP-9, IR-4, SI-4 ' +
      "— the catalog has no requirement for) or status (COMPLIANT, PARTIAL, GAP, INCONCLUSIVE, " +
      "NOT_APPLICABLE, NOT_ASSESSED). Returns { controls, outOfCatalogControls, summary, notes }: " +
      "controls and outOfCatalogControls are separate arrays that are NEVER merged — an " +
      "outOfCatalogControls record's status must never be reported as the answer for a " +
      "requirement it is mapped to for orientation only (its own requirementsMappingToThisControl " +
      'field says so; e.g. CP-9\'s status is never the answer to a question about 3.8.9, and a ' +
      'query for control "3.8.9" never returns CP-9). summary carries the WHOLE estate\'s counts ' +
      "regardless of any filter above, so a narrow question never hides the wider picture. RULES " +
      "THIS TOOL AND ITS CALLER MUST BOTH FOLLOW WHEN ANSWERING: never compute or state a " +
      "percentage, ratio or score from any of this — this platform deliberately reports counts " +
      "only; if asked for a percentage, say plainly that it is not computed, and why, then give " +
      "the counts from summary instead. Read summary.byProvenanceAndStatus, never a bare " +
      "byProvenance total: 'machine-verified' includes a criterion a machine explicitly declined " +
      "to run, and only status COMPLIANT means verified-and-passing. Each control's registerStatus " +
      'is the raw word a human wrote (e.g. "CLOSED", meaning only "no known open finding") and is ' +
      "never the same claim as its derived status field — CLOSED is rendered PARTIAL here and is " +
      "never COMPLIANT. recommendation is authored text or null — never invent or extrapolate one " +
      "when it is null. Every record describes what the repository declares, not what is " +
      "deployed: nothing in this estate has been deployed.",
    inputSchema: {
      type: "object",
      properties: {
        control: {
          type: "string",
          description:
            'Exact control id, e.g. "3.5.3" (NIST SP 800-171), or an out-of-catalog id assessed ' +
            "only against NIST SP 800-53: CM-6, CP-9, IR-4, SI-4.",
        },
        family: {
          type: "string",
          description:
            'Exact family id, e.g. "3.1" (800-171) or a 800-53 family abbreviation for an ' +
            'out-of-catalog record, e.g. "CP".',
        },
        framework: {
          type: "string",
          enum: ["nist-800-171r2", "nist-800-53r5"],
          description:
            "nist-800-171r2 scopes to the 110-requirement catalog; omitting it returns both, counted separately as matchCount and outOfCatalogMatchCount; " +
            "nist-800-53r5 scopes to the four out-of-catalog records (CM-6, CP-9, IR-4, SI-4).",
        },
        status: {
          type: "string",
          enum: ["COMPLIANT", "PARTIAL", "GAP", "INCONCLUSIVE", "NOT_APPLICABLE", "NOT_ASSESSED"],
          description:
            "One of the six derived statuses. Never the register's own GAP/CLOSED authoring " +
            "vocabulary — CLOSED is rendered PARTIAL here.",
        },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true },
  },
];


/**
 * `get_cost_series`, described for the backend actually behind it (F138).
 *
 * BUILT, NOT WRITTEN, for the same reason `query_lakehouse_sql` is. A single
 * hardcoded description is wrong in one of the two modes, and it was: it
 * promised "the daily Azure spend series", then named the five FICTIONAL cost
 * centres of the lakehouse ledger, then instructed the agent to fall back to
 * `cost_daily` for whole-history aggregates. In cloud mode all three were
 * false. Asked what the tenant had spent to date, the agent did exactly as
 * instructed and answered $23,561,191 - Meridian's imaginary business ledger,
 * wearing the question's words, against a real bill of about $1.40.
 *
 * The defect was never the agent's judgement. It followed its tool contract,
 * and the tool contract was wrong.
 */
function costSeriesTool(source: CostSource): Tool {
  const cloud = source === "azure-cost-management";

  const what = cloud
    ? "Fetch REAL daily Azure consumption for the Meridian demo subscription from the Azure " +
      "Cost Management query API, grouped by the costCenter tag on each resource group. This " +
      "is the actual cloud bill - the only tool that knows what this subscription costs."
    : "Fetch the daily series from Meridian's SYNTHETIC business cost ledger (the cost_daily " +
      "table), not from Azure. This backend is the local development one; it does not know " +
      "what any Azure subscription costs.";

  const centres = cloud
    ? "Cost centres are whatever costCenter tag values the estate's resource groups carry, so " +
      "read them from the rows rather than assuming a fixed list."
    : "The five cost centres are 'Propulsion', 'Avionics', 'Range Operations', 'Facilities' " +
      "and 'Cloud & IT'.";

  // The rule that F138 broke, stated in the direction that matters for THIS
  // backend. An unavailable tool is answered with "I could not retrieve it",
  // never with a different dataset's number.
  const substitution = cloud
    ? "NEVER substitute the lakehouse `cost_daily` table for this tool. That table is " +
      "Meridian's fictional business ledger - cost centres, budgets, figures in the millions " +
      "- and has nothing to do with this subscription, whose lifetime spend is a few dollars. " +
      "If this tool fails or is rate-limited (Cost Management throttles per principal and a " +
      "retry deepens the throttle), say that you could not retrieve the cloud spend and stop. " +
      "A number from a different dataset presented in the question's words is a wrong answer, " +
      "not a fallback."
    : "This is not Azure spend. If asked what an Azure subscription, tenant or resource group " +
      "costs, say that this deployment has no cloud-cost source rather than answering from " +
      "the business ledger.";

  return {
    name: "get_cost_series",
    title: cloud ? "Get daily Azure cloud spend" : "Get daily business cost ledger",
    description:
      `${what} Optionally filtered by date range and cost center, in the Azure Cost ` +
      `Management query response shape. ${centres} Returns ` +
      "{ id, name, type, properties: { columns, rows } } where each row is " +
      "[date (ISO YYYY-MM-DD), cost_center, amount_usd, budget_usd], one row per date per cost " +
      `center, ordered by date ascending — sum across rows for a total. At most ${MAX_RESULT_ROWS} ` +
      "rows come back, so narrow the date range or filter by cost center for long windows. " +
      `Omit every argument for the unfiltered series from its earliest date. ${substitution}`,
    inputSchema: {
      type: "object",
      properties: {
        start_date: {
          type: "string",
          description: "Inclusive lower bound as an ISO date, e.g. 2026-01-01.",
        },
        end_date: {
          type: "string",
          description: "Inclusive upper bound as an ISO date, e.g. 2026-01-31.",
        },
        cost_center: {
          type: "string",
          description: cloud
            ? "Exact costCenter tag value to filter on, as it appears in the returned rows."
            : "Exact cost-center name filter: Propulsion, Avionics, Range Operations, " +
              "Facilities or Cloud & IT.",
        },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true },
  };
}

/**
 * The six MCP tool definitions for a given SQL dialect and cost backend. Order
 * is stable and `query_lakehouse_sql` is first — `tools/list` order is what an
 * orchestrator sees first, and the lakehouse tool answers most questions.
 *
 * `costSource` defaults to the local ledger so existing callers keep the
 * behaviour they had; the live set an agent sees comes from ToolRegistry, which
 * passes what the active backend declares.
 */
export function buildToolDefinitions(
  dialect: SqlDialect,
  costSource: CostSource = "lakehouse-ledger",
): Tool[] {
  const profile = DIALECTS[dialect];
  if (!profile) throw new Error(`unknown SQL dialect: ${dialect}`);
  const tools = [lakehouseSqlTool(profile), ...STATIC_TOOLS];
  // get_cost_series was fifth before it became backend-aware, and tools/list order
  // is agent-facing surface. Restore that position, so this change alters what the
  // description SAYS and nothing else about what the orchestrator sees.
  tools.splice(4, 0, costSeriesTool(costSource));
  return tools;
}

/**
 * The default (local / SQLite) definition set. Kept as a module constant because
 * the tool COUNT is dialect-independent and several callers only want that; the
 * live set an agent sees comes from `ToolRegistry.definitions`.
 */
export const toolDefinitions: Tool[] = buildToolDefinitions("sqlite");

// Load-time guard: the definitions and the allowlist must agree, in every dialect.
for (const dialect of Object.keys(DIALECTS) as SqlDialect[]) {
  const names = buildToolDefinitions(dialect).map((t) => t.name);
  if (names.length !== ALLOWED_TOOL_NAMES.length || names.some((n) => !isAllowedTool(n))) {
    throw new Error(`tool definitions out of sync with ALLOWED_TOOL_NAMES (dialect: ${dialect})`);
  }
}

/**
 * How many rows a tool result carries, for the `mls.tool.row_count` span
 * attribute. Shape-aware because the six tools return five different envelopes;
 * returns undefined where "rows" is not a meaningful concept.
 *
 * SAFETY: this reads only array LENGTHS. No cell value, no column name and no
 * argument ever reaches telemetry through here.
 */
export function countRows(name: string, payload: unknown): number | undefined {
  const p = payload as any;
  switch (name) {
    case "query_lakehouse_sql":
      return Array.isArray(p?.rows) ? p.rows.length : undefined;
    case "query_log_analytics":
      return Array.isArray(p?.tables)
        ? p.tables.reduce(
            (sum: number, t: any) => sum + (Array.isArray(t?.rows) ? t.rows.length : 0),
            0,
          )
        : undefined;
    case "get_github_security":
      return (
        (Array.isArray(p?.dependabot_alerts) ? p.dependabot_alerts.length : 0) +
        (Array.isArray(p?.code_scanning_alerts) ? p.code_scanning_alerts.length : 0)
      );
    case "get_defender_posture":
      return Array.isArray(p?.controls?.value) ? p.controls.value.length : undefined;
    case "get_cost_series":
      return Array.isArray(p?.properties?.rows) ? p.properties.rows.length : undefined;
    case "query_compliance":
      return (
        (Array.isArray(p?.controls) ? p.controls.length : 0) +
        (Array.isArray(p?.outOfCatalogControls) ? p.outOfCatalogControls.length : 0)
      );
    default:
      return undefined;
  }
}

export class ToolRegistry {
  /** The dialect the active lakehouse backend speaks — drives the descriptions. */
  readonly dialect: SqlDialect;
  private readonly cachedDefinitions: Tool[];

  constructor(private readonly backends: Backends) {
    this.dialect = backends.lakehouseSql.dialect;
    this.cachedDefinitions = buildToolDefinitions(this.dialect, backends.costSeries.source);
  }

  /** What `tools/list` returns: six tools, described for the ACTIVE backend. */
  get definitions(): Tool[] {
    return this.cachedDefinitions;
  }

  /**
   * Execute an allowlisted tool. Throws for unknown names (the MCP server
   * checks the allowlist first and never routes disallowed names here — this
   * throw is the second line of defense).
   */
  async execute(name: string, input: unknown): Promise<unknown> {
    const args = (input ?? {}) as Record<string, unknown>;
    switch (name as AllowedToolName) {
      case "query_lakehouse_sql":
        return this.backends.lakehouseSql.query(String(args.sql ?? ""));
      case "query_log_analytics":
        return this.backends.logAnalytics.query(
          String(args.query ?? ""),
          args.timespan === undefined ? undefined : String(args.timespan),
        );
      case "get_github_security": {
        const alertType = (args.alert_type ?? "all") as "dependabot" | "code_scanning" | "all";
        return this.backends.githubSecurity.getAlerts(alertType);
      }
      case "get_defender_posture":
        return this.backends.defenderPosture.getPosture();
      case "get_cost_series":
        return this.backends.costSeries.getSeries(args as CostSeriesParams);
      case "query_compliance":
        return this.backends.compliance.query(args as ComplianceQueryParams);
      default:
        throw new Error(`Tool "${name}" is not on the allowlist`);
    }
  }
}
