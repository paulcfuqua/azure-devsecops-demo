/**
 * Tool registry — EXACTLY five tools are exposed over MCP, and the server
 * refuses any tools/call whose name is not on this allowlist (master plan L8 /
 * audit V8.2). Do not add tools here without a master-plan change.
 *
 * THESE DESCRIPTIONS ARE AGENT-FACING SURFACE AREA. The Copilot Studio agent's
 * orchestrator reads nothing else about these tools: name, description and
 * input JSON Schema are the entire contract it reasons over when deciding which
 * tool to call and with what arguments. Editing a description changes agent
 * behaviour as surely as editing code — treat it as a behavioural change and
 * re-run `npm run eval`.
 */
import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import type { Backends, CostSeriesParams } from "./backends.js";

export const ALLOWED_TOOL_NAMES = [
  "query_lakehouse_sql",
  "query_log_analytics",
  "get_github_security",
  "get_defender_posture",
  "get_cost_series",
] as const;

export type AllowedToolName = (typeof ALLOWED_TOOL_NAMES)[number];

export function isAllowedTool(name: string): name is AllowedToolName {
  return (ALLOWED_TOOL_NAMES as readonly string[]).includes(name);
}

/** MCP tool definitions returned by tools/list. */
export const toolDefinitions: Tool[] = [
  {
    name: "query_lakehouse_sql",
    title: "Query the operations lakehouse (SQL)",
    description:
      "Run one read-only SQL query (SQLite dialect) against the Meridian Launch Systems " +
      "operations lakehouse and return columns and rows. Use this for any question about " +
      "launch history, scrubs, the vehicle fleet, pads, telemetry, parts, suppliers, work " +
      "orders, daily cloud spend or security-finding history — counts, rates, rankings, " +
      "trends and joins across those tables. Schema: " +
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
      "cost_daily(cost_id, date, cost_center, amount_usd, budget_usd, currency); " +
      "findings_history(finding_id, source, severity IN ('critical','high','medium','low'), title, " +
      "component, cve_id, opened_date, closed_date, status IN ('open','resolved','risk_accepted'), " +
      "assignee, sla_days). " +
      "Dates are ISO 'YYYY-MM-DD' text: use strftime('%w', actual_date) for day of week " +
      "(0=Sunday .. 6=Saturday) and strftime('%Y-%m', date) to bucket by month. Exactly one " +
      "SELECT or WITH statement is accepted; INSERT, UPDATE, DELETE and DDL are refused. " +
      "Results are capped at 500 rows, so aggregate in SQL (COUNT, SUM, AVG, GROUP BY) rather " +
      "than fetching raw rows.",
    inputSchema: {
      type: "object",
      properties: {
        sql: {
          type: "string",
          description:
            "A single read-only SELECT or WITH statement in SQLite dialect, e.g. " +
            "\"SELECT COUNT(*) AS n FROM launches WHERE outcome = 'success'\".",
        },
      },
      required: ["sql"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true },
  },
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
    name: "get_cost_series",
    title: "Get daily cloud cost series",
    description:
      "Fetch the daily Azure spend series for the Meridian demo subscription, optionally " +
      "filtered by date range and cost center, in the Azure Cost Management query response " +
      "shape. Use this for questions about cloud spend over time, burn rate, budget " +
      "consumption, or how one cost center compares against its budget. The five cost centers " +
      "are 'Propulsion', 'Avionics', 'Range Operations', 'Facilities' and 'Cloud & IT'. " +
      "Returns { id, name, type, properties: { columns, rows } } where each row is " +
      "[date (ISO YYYY-MM-DD), cost_center, amount_usd, budget_usd], one row per date per cost " +
      "center, ordered by date ascending — sum across rows for a total. At most 500 rows come " +
      "back, so narrow the date range or filter by cost center for long windows; for " +
      "whole-history aggregates query the cost_daily table with query_lakehouse_sql instead. " +
      "Omit every argument for the unfiltered series from its earliest date.",
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
          description:
            "Exact cost-center name filter: Propulsion, Avionics, Range Operations, " +
            "Facilities or Cloud & IT.",
        },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true },
  },
];

// Load-time guard: the definitions and the allowlist must agree.
const _definitionNames: AllowedToolName[] = toolDefinitions.map(
  (t) => t.name as AllowedToolName,
);
if (
  _definitionNames.length !== ALLOWED_TOOL_NAMES.length ||
  _definitionNames.some((n) => !isAllowedTool(n))
) {
  throw new Error("tool definitions out of sync with ALLOWED_TOOL_NAMES");
}

export class ToolRegistry {
  constructor(private readonly backends: Backends) {}

  get definitions(): Tool[] {
    return toolDefinitions;
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
      default:
        throw new Error(`Tool "${name}" is not on the allowlist`);
    }
  }
}
