/**
 * Recorded tool plans for the golden questions (MOCK_LLM mode).
 *
 * Each plan replays what a competent model turn would do: which allowlisted
 * tools to call with which inputs, and how to compose the renderer spec from
 * the REAL tool results (the tools execute for real — sql.js SQL, fixture
 * adapters — so the whole pipeline is exercised without an API key).
 *
 * The special __test_* plans exist for the vitest suites (allowlist
 * enforcement and the validation-gate repair/error paths).
 */
import type { LakehouseQueryResult } from "../data/lakehouse.js";
import type { CostSeriesResult } from "../tools/backends.js";

export interface RecordedToolCall {
  name: string;
  input: Record<string, unknown>;
}

export interface RecordedPlan {
  id: string;
  question: string;
  toolCalls: RecordedToolCall[];
  /** Compose the final renderer spec from executed tool results (in call order). */
  buildSpec: (results: unknown[]) => unknown;
  /** Validation-gate hooks (test plans only). */
  firstSpecInvalid?: boolean;
  alwaysInvalid?: boolean;
}

export function normalizeQuestion(q: string): string {
  return q.toLowerCase().replace(/[^a-z0-9_ ]/g, "").replace(/\s+/g, " ").trim();
}

const WEEKDAY_SQL = `SELECT CASE strftime('%w', actual_date)
  WHEN '0' THEN 'Sunday' WHEN '1' THEN 'Monday' WHEN '2' THEN 'Tuesday'
  WHEN '3' THEN 'Wednesday' WHEN '4' THEN 'Thursday' WHEN '5' THEN 'Friday'
  ELSE 'Saturday' END AS weekday, COUNT(*) AS launches
FROM launches GROUP BY weekday ORDER BY launches DESC, weekday ASC`;

function lakehouse(results: unknown[], index = 0): LakehouseQueryResult {
  const r = results[index] as LakehouseQueryResult | undefined;
  if (!r || !Array.isArray(r.rows)) {
    throw new Error(`recorded plan expected a lakehouse result at index ${index}`);
  }
  return r;
}

/** statCard + barChart composer for "top row wins" questions. */
function topRowSpec(opts: {
  title: string;
  result: LakehouseQueryResult;
  valueLabel: string;
  chartTitle: string;
  unit?: string;
  countNoun?: string;
}): unknown {
  const top = opts.result.rows[0] ?? [];
  const name = String(top[0]);
  const count = Number(top[1]);
  return {
    version: "1",
    layout: "stack",
    components: [
      {
        type: "statCard",
        title: opts.valueLabel,
        value: name,
        description: opts.countNoun
          ? `${count} ${opts.countNoun}`
          : `${count}${opts.unit ?? ""}`,
      },
      {
        type: "barChart",
        title: opts.chartTitle,
        data: opts.result.rows.map((r) => ({ x: String(r[0]), y: Number(r[1]) })),
        ...(opts.unit ? { unit: opts.unit } : {}),
      },
    ],
  };
}

export const goldenPlans: RecordedPlan[] = [
  {
    id: "day-of-week",
    question: "Which day of the week has the most launches?",
    toolCalls: [{ name: "query_lakehouse_sql", input: { sql: WEEKDAY_SQL } }],
    buildSpec: (results) =>
      topRowSpec({
        title: "Launches by weekday",
        result: lakehouse(results),
        valueLabel: "Busiest launch day",
        chartTitle: "Launches by day of week",
        countNoun: "launches",
      }),
  },
  {
    id: "total-launches",
    question: "How many launches are in the lakehouse?",
    toolCalls: [
      { name: "query_lakehouse_sql", input: { sql: "SELECT COUNT(*) AS total FROM launches" } },
    ],
    buildSpec: (results) => ({
      version: "1",
      layout: "stack",
      components: [
        {
          type: "statCard",
          title: "Total launches",
          value: Number(lakehouse(results).rows[0]?.[0]),
          decimals: 0,
        },
      ],
    }),
  },
  {
    id: "success-rate",
    question: "What is the overall launch success rate?",
    toolCalls: [
      {
        name: "query_lakehouse_sql",
        input: {
          sql: "SELECT ROUND(100.0 * SUM(CASE WHEN outcome = 'success' THEN 1 ELSE 0 END) / COUNT(*), 1) AS success_pct FROM launches",
        },
      },
    ],
    buildSpec: (results) => ({
      version: "1",
      layout: "stack",
      components: [
        {
          type: "statCard",
          title: "Launch success rate",
          value: Number(lakehouse(results).rows[0]?.[0]),
          unit: "%",
          decimals: 1,
        },
      ],
    }),
  },
  {
    id: "busiest-vehicle",
    question: "Which vehicle has flown the most launches?",
    toolCalls: [
      {
        name: "query_lakehouse_sql",
        input: {
          sql: "SELECT v.name, COUNT(*) AS n FROM launches l JOIN vehicles v ON v.vehicle_id = l.vehicle_id GROUP BY v.name ORDER BY n DESC, v.name ASC LIMIT 8",
        },
      },
    ],
    buildSpec: (results) =>
      topRowSpec({
        title: "Launches by vehicle",
        result: lakehouse(results),
        valueLabel: "Most-flown vehicle",
        chartTitle: "Launches by vehicle (top 8)",
        countNoun: "launches",
      }),
  },
  {
    id: "busiest-pad",
    question: "Which pad hosted the most launches?",
    toolCalls: [
      {
        name: "query_lakehouse_sql",
        input: {
          sql: "SELECT p.name, COUNT(*) AS n FROM launches l JOIN pads p ON p.pad_id = l.pad_id GROUP BY p.name ORDER BY n DESC, p.name ASC LIMIT 8",
        },
      },
    ],
    buildSpec: (results) =>
      topRowSpec({
        title: "Launches by pad",
        result: lakehouse(results),
        valueLabel: "Busiest pad",
        chartTitle: "Launches by pad (top 8)",
        countNoun: "launches",
      }),
  },
  {
    id: "scrub-category",
    question: "What is the most common scrub category?",
    toolCalls: [
      {
        name: "query_lakehouse_sql",
        input: {
          sql: "SELECT category, COUNT(*) AS n FROM scrubs GROUP BY category ORDER BY n DESC, category ASC",
        },
      },
    ],
    buildSpec: (results) => {
      const r = lakehouse(results);
      const top = r.rows[0] ?? [];
      return {
        version: "1",
        layout: "stack",
        components: [
          {
            type: "statCard",
            title: "Most common scrub category",
            value: String(top[0]),
            description: `${Number(top[1])} scrubs`,
          },
          {
            type: "donutChart",
            title: "Scrubs by category",
            data: r.rows.map((row) => ({ label: String(row[0]), value: Number(row[1]) })),
          },
        ],
      };
    },
  },
  {
    id: "scrubbed-launches",
    question: "How many launches were scrubbed at least once?",
    toolCalls: [
      {
        name: "query_lakehouse_sql",
        input: { sql: "SELECT COUNT(*) AS n FROM launches WHERE scrub_count > 0" },
      },
    ],
    buildSpec: (results) => ({
      version: "1",
      layout: "stack",
      components: [
        {
          type: "statCard",
          title: "Launches scrubbed at least once",
          value: Number(lakehouse(results).rows[0]?.[0]),
          decimals: 0,
        },
      ],
    }),
  },
  {
    id: "top-cost-center",
    question: "Which cost center has the highest total spend?",
    // Exercises the get_cost_series adapter through the pipeline (cost_daily-backed).
    toolCalls: [{ name: "get_cost_series", input: {} }],
    buildSpec: (results) => {
      const series = results[0] as CostSeriesResult;
      const totals = new Map<string, number>();
      for (const [, center, amount] of series.properties.rows) {
        totals.set(center, (totals.get(center) ?? 0) + amount);
      }
      const sorted = [...totals.entries()].sort(
        (a, b) => b[1] - a[1] || a[0].localeCompare(b[0]),
      );
      const [topCenter, topTotal] = sorted[0] ?? ["unknown", 0];
      return {
        version: "1",
        layout: "stack",
        components: [
          {
            type: "statCard",
            title: "Highest-spend cost center",
            value: topCenter,
            description: `$${topTotal.toFixed(2)} total spend`,
          },
          {
            type: "barChart",
            title: "Total spend by cost center",
            data: sorted.map(([label, total]) => ({ x: label, y: Number(total.toFixed(2)) })),
            unit: "$",
          },
        ],
      };
    },
  },
  {
    id: "open-findings",
    question: "How many security findings are currently open?",
    toolCalls: [
      {
        name: "query_lakehouse_sql",
        input: { sql: "SELECT COUNT(*) AS n FROM findings_history WHERE status = 'open'" },
      },
    ],
    buildSpec: (results) => ({
      version: "1",
      layout: "stack",
      components: [
        {
          type: "statCard",
          title: "Open security findings",
          value: Number(lakehouse(results).rows[0]?.[0]),
          decimals: 0,
        },
      ],
    }),
  },
  {
    id: "worst-supplier",
    question: "Which supplier has the lowest on-time delivery percentage?",
    toolCalls: [
      {
        name: "query_lakehouse_sql",
        input: {
          sql: "SELECT name, on_time_pct FROM suppliers ORDER BY on_time_pct ASC, name ASC LIMIT 8",
        },
      },
    ],
    buildSpec: (results) => {
      const r = lakehouse(results);
      const top = r.rows[0] ?? [];
      return {
        version: "1",
        layout: "stack",
        components: [
          {
            type: "statCard",
            title: "Lowest on-time supplier",
            value: String(top[0]),
            description: `${Number(top[1])}% on-time`,
          },
          {
            type: "barChart",
            title: "On-time % (worst 8 suppliers)",
            data: r.rows.map((row) => ({ x: String(row[0]), y: Number(row[1]) })),
            unit: "%",
          },
        ],
      };
    },
  },
];

/* ------------------------------------------------------------------ */
/* Test-only plans (vitest)                                            */
/* ------------------------------------------------------------------ */

export const FORBIDDEN_TOOL_QUESTION = "__test_forbidden_tool__";
export const INVALID_THEN_VALID_QUESTION = "__test_invalid_then_valid__";
export const ALWAYS_INVALID_QUESTION = "__test_always_invalid__";

/** A deliberately schema-invalid spec (bad layout enum + missing title). */
export const BROKEN_SPEC = {
  version: "1",
  layout: "carousel",
  components: [{ type: "statCard", value: 1 }],
};

const VALID_FALLBACK_SPEC = (text: string): unknown => ({
  version: "1",
  layout: "stack",
  components: [{ type: "markdownBlock", markdown: text }],
});

export const testPlans: RecordedPlan[] = [
  {
    id: "forbidden-tool",
    question: FORBIDDEN_TOOL_QUESTION,
    toolCalls: [
      // NOT on the allowlist — the loop must reject this call.
      { name: "delete_everything", input: { target: "prod" } },
      { name: "query_lakehouse_sql", input: { sql: "SELECT COUNT(*) AS n FROM launches" } },
    ],
    buildSpec: (results) => {
      // results[0] is the rejection error payload; results[1] the real count.
      const count = Number(lakehouse(results, 1).rows[0]?.[0]);
      return VALID_FALLBACK_SPEC(
        `Recovered after a rejected tool call; launches = ${count}.`,
      );
    },
  },
  {
    id: "invalid-then-valid",
    question: INVALID_THEN_VALID_QUESTION,
    toolCalls: [
      { name: "query_lakehouse_sql", input: { sql: "SELECT COUNT(*) AS n FROM launches" } },
    ],
    firstSpecInvalid: true,
    buildSpec: (results) =>
      VALID_FALLBACK_SPEC(
        `Repaired spec; launches = ${Number(lakehouse(results).rows[0]?.[0])}.`,
      ),
  },
  {
    id: "always-invalid",
    question: ALWAYS_INVALID_QUESTION,
    toolCalls: [],
    alwaysInvalid: true,
    buildSpec: () => BROKEN_SPEC,
  },
];

export const allPlans: RecordedPlan[] = [...goldenPlans, ...testPlans];

export function findPlan(question: string): RecordedPlan | undefined {
  const norm = normalizeQuestion(question);
  return allPlans.find((p) => normalizeQuestion(p.question) === norm);
}
