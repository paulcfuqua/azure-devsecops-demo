/**
 * Tool registry — EXACTLY five tools are registered with the model, and the
 * loop rejects any tool call whose name is not on this allowlist (master plan
 * L8 / audit V8.2). Do not add tools here without a master-plan change.
 */
import type Anthropic from "@anthropic-ai/sdk";
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

/** Anthropic tool definitions sent with every request. */
export const toolDefinitions: Anthropic.Tool[] = [
  {
    name: "query_lakehouse_sql",
    description:
      "Execute a single read-only SQL (SQLite dialect) SELECT/WITH statement against the " +
      "Meridian lakehouse. Tables: launches, scrubs, vehicles, pads, telemetry_summary, " +
      "parts, suppliers, work_orders, cost_daily, findings_history. Dates are ISO strings; " +
      "use strftime('%w', d) for day-of-week (0=Sunday..6=Saturday). Results are capped at " +
      "500 rows — aggregate in SQL rather than fetching raw rows.",
    input_schema: {
      type: "object",
      properties: {
        sql: { type: "string", description: "The SELECT/WITH statement to execute." },
      },
      required: ["sql"],
      additionalProperties: false,
    },
  },
  {
    name: "query_log_analytics",
    description:
      "Run a KQL query against the ops Log Analytics workspace (app traces, requests, " +
      "container logs). Returns the Log Analytics API shape: tables[{name, columns, rows}].",
    input_schema: {
      type: "object",
      properties: {
        query: { type: "string", description: "KQL query text." },
        timespan: {
          type: "string",
          description: "Optional ISO-8601 duration or interval, e.g. P1D or PT4H.",
        },
      },
      required: ["query"],
      additionalProperties: false,
    },
  },
  {
    name: "get_github_security",
    description:
      "Fetch current GitHub security alerts for the repo (Dependabot and/or code scanning), " +
      "in the GitHub REST API alert shapes.",
    input_schema: {
      type: "object",
      properties: {
        alert_type: {
          type: "string",
          enum: ["dependabot", "code_scanning", "all"],
          description: "Which alert families to return (default all).",
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_defender_posture",
    description:
      "Fetch the Microsoft Defender for Cloud security posture: the subscription secure " +
      "score and per-control breakdown (ARM secureScores shape).",
    input_schema: {
      type: "object",
      properties: {},
      additionalProperties: false,
    },
  },
  {
    name: "get_cost_series",
    description:
      "Fetch the daily cost series (Azure Cost Management query shape; rows are " +
      "[date, cost_center, amount_usd, budget_usd]), optionally filtered by date range " +
      "and cost center.",
    input_schema: {
      type: "object",
      properties: {
        start_date: { type: "string", description: "Inclusive ISO date lower bound." },
        end_date: { type: "string", description: "Inclusive ISO date upper bound." },
        cost_center: { type: "string", description: "Exact cost-center name filter." },
      },
      additionalProperties: false,
    },
  },
];

// Compile-time guard: the definitions and the allowlist must agree.
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

  get definitions(): Anthropic.Tool[] {
    return toolDefinitions;
  }

  /**
   * Execute an allowlisted tool. Throws for unknown names (the loop checks the
   * allowlist first and never routes disallowed names here — this throw is the
   * second line of defense).
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
