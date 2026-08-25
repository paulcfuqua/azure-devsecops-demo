/**
 * Golden-question eval set (L8 functional contract, master plan §L8).
 *
 * WHAT THIS TESTS NOW. Before the 2026-08-24 amendment these ten questions were
 * put to an in-process LLM loop. The LLM has moved into Microsoft Copilot Studio
 * and is no longer part of this package, so this suite tests what this package
 * actually owns: that **the answer to every golden question is reachable
 * through the MCP tool surface**. Each question carries the tool call that
 * answers it; `npm run eval` issues that call against a real MCP server over
 * Streamable HTTP and checks the returned data carries the expected facts.
 *
 * Whether the deployed *agent* chooses the right tool and renders the right
 * Adaptive Card is a different measurement, made at L8 by `npm run eval:agent`
 * over Direct Line against the same ten questions.
 *
 * Expectations are computed from data/generated at eval time by running
 * independent SQL in-process — deliberately phrased differently from the SQL in
 * the tool call, so a pass means two formulations agree across two paths, and
 * never that the harness compared a value with itself.
 *
 * The single documented hardcode is Saturday = 309 launches — the generator's
 * seeded weekday bias (seed 20260822), pinned by Track A's distribution test
 * and named in the master plan.
 */
import { queryLakehouse } from "../src/data/lakehouse.js";
import type { AllowedToolName } from "../src/tools/index.js";

export interface ExpectedFact {
  /** Value that must appear somewhere in the tool result. */
  value: string | number;
  /** Compare numbers with this absolute tolerance (default exact). */
  tolerance?: number;
}

export interface ToolCall {
  tool: AllowedToolName;
  arguments: Record<string, unknown>;
}

export interface GoldenQuestion {
  id: string;
  question: string;
  /** The MCP tool call that answers the question. */
  call: ToolCall;
  /** Compute the expected facts from the lakehouse (independent SQL). */
  expected: () => Promise<ExpectedFact[]>;
  /**
   * Where the facts must appear in the tool result.
   *   "payload"   — anywhere (the query answers the question directly).
   *   "first-row" — in row 0 (ranking questions: "most", "highest", "lowest").
   *                 Anywhere-matching would pass on a ranked list merely
   *                 *containing* the winner, which proves nothing about rank.
   */
  factScope: "payload" | "first-row";
}

async function scalar(sql: string): Promise<string | number> {
  const r = await queryLakehouse(sql);
  const v = r.rows[0]?.[0];
  if (v === undefined || v === null) throw new Error(`expectation SQL returned no value: ${sql}`);
  return v as string | number;
}

/** Documented pin: the generator's Saturday launch bias (master plan §L8). */
export const SATURDAY_LAUNCH_COUNT = 309;

const WEEKDAY_SQL = `SELECT CASE strftime('%w', actual_date)
     WHEN '0' THEN 'Sunday' WHEN '1' THEN 'Monday' WHEN '2' THEN 'Tuesday'
     WHEN '3' THEN 'Wednesday' WHEN '4' THEN 'Thursday' WHEN '5' THEN 'Friday'
     ELSE 'Saturday' END AS weekday, COUNT(*) AS launches
   FROM launches GROUP BY weekday ORDER BY launches DESC, weekday ASC`;

export const goldenQuestions: GoldenQuestion[] = [
  {
    id: "day-of-week",
    factScope: "first-row",
    question: "Which day of the week has the most launches?",
    call: { tool: "query_lakehouse_sql", arguments: { sql: WEEKDAY_SQL } },
    expected: async () => {
      const top = await queryLakehouse(
        `SELECT strftime('%w', actual_date) AS dow, COUNT(*) AS n
         FROM launches GROUP BY dow ORDER BY n DESC, dow ASC LIMIT 1`,
      );
      const dow = String(top.rows[0]?.[0]);
      const count = Number(top.rows[0]?.[1]);
      if (dow !== "6" || count !== SATURDAY_LAUNCH_COUNT) {
        throw new Error(
          `seed drift: expected Saturday (dow 6) = ${SATURDAY_LAUNCH_COUNT}, ` +
            `lakehouse says dow ${dow} = ${count}`,
        );
      }
      return [{ value: "Saturday" }, { value: SATURDAY_LAUNCH_COUNT }];
    },
  },
  {
    id: "total-launches",
    factScope: "payload",
    question: "How many launches are in the lakehouse?",
    call: {
      tool: "query_lakehouse_sql",
      arguments: { sql: "SELECT COUNT(*) AS total_launches FROM launches" },
    },
    expected: async () => [{ value: await scalar("SELECT COUNT(launch_id) FROM launches") }],
  },
  {
    id: "success-rate",
    factScope: "payload",
    question: "What is the overall launch success rate?",
    call: {
      tool: "query_lakehouse_sql",
      arguments: {
        sql:
          "SELECT ROUND(100.0 * SUM(CASE WHEN outcome = 'success' THEN 1 ELSE 0 END) / COUNT(*), 1)" +
          " AS success_rate_pct FROM launches",
      },
    },
    expected: async () => [
      {
        value: await scalar(
          "SELECT ROUND(100.0 * SUM(outcome = 'success') / COUNT(*), 1) FROM launches",
        ),
        tolerance: 0.05,
      },
    ],
  },
  {
    id: "busiest-vehicle",
    factScope: "first-row",
    question: "Which vehicle has flown the most launches?",
    call: {
      tool: "query_lakehouse_sql",
      arguments: {
        sql:
          "SELECT v.name, COUNT(*) AS flights FROM launches l JOIN vehicles v" +
          " ON v.vehicle_id = l.vehicle_id GROUP BY v.name ORDER BY flights DESC, v.name ASC LIMIT 5",
      },
    },
    expected: async () => [
      {
        value: await scalar(
          "SELECT name FROM vehicles WHERE vehicle_id = (SELECT vehicle_id FROM launches GROUP BY vehicle_id ORDER BY COUNT(*) DESC LIMIT 1)",
        ),
      },
    ],
  },
  {
    id: "busiest-pad",
    factScope: "first-row",
    question: "Which pad hosted the most launches?",
    call: {
      tool: "query_lakehouse_sql",
      arguments: {
        sql:
          "SELECT p.name, COUNT(*) AS launches FROM launches l JOIN pads p" +
          " ON p.pad_id = l.pad_id GROUP BY p.name ORDER BY launches DESC, p.name ASC LIMIT 5",
      },
    },
    expected: async () => [
      {
        value: await scalar(
          "SELECT name FROM pads WHERE pad_id = (SELECT pad_id FROM launches GROUP BY pad_id ORDER BY COUNT(*) DESC LIMIT 1)",
        ),
      },
    ],
  },
  {
    id: "scrub-category",
    factScope: "first-row",
    question: "What is the most common scrub category?",
    call: {
      tool: "query_lakehouse_sql",
      arguments: {
        sql:
          "SELECT category, COUNT(*) AS scrubs FROM scrubs GROUP BY category" +
          " ORDER BY scrubs DESC, category ASC",
      },
    },
    expected: async () => [
      {
        value: await scalar(
          "SELECT category FROM scrubs GROUP BY category ORDER BY COUNT(scrub_id) DESC, category ASC LIMIT 1",
        ),
      },
    ],
  },
  {
    id: "scrubbed-launches",
    factScope: "payload",
    question: "How many launches were scrubbed at least once?",
    call: {
      tool: "query_lakehouse_sql",
      arguments: {
        sql: "SELECT COUNT(*) AS scrubbed_launches FROM launches WHERE scrub_count >= 1",
      },
    },
    expected: async () => [
      { value: await scalar("SELECT COUNT(DISTINCT launch_id) FROM scrubs") },
    ],
  },
  {
    id: "top-cost-center",
    factScope: "first-row",
    question: "Which cost center has the highest total spend?",
    call: {
      tool: "query_lakehouse_sql",
      arguments: {
        sql:
          "SELECT cost_center, ROUND(SUM(amount_usd), 2) AS total_usd FROM cost_daily" +
          " GROUP BY cost_center ORDER BY total_usd DESC",
      },
    },
    expected: async () => [
      {
        value: await scalar(
          "SELECT cost_center FROM cost_daily GROUP BY cost_center ORDER BY SUM(amount_usd) DESC, cost_center ASC LIMIT 1",
        ),
      },
    ],
  },
  {
    id: "open-findings",
    factScope: "payload",
    question: "How many security findings are currently open?",
    call: {
      tool: "query_lakehouse_sql",
      arguments: {
        sql:
          "SELECT COUNT(*) AS open_findings FROM findings_history WHERE status = 'open'",
      },
    },
    expected: async () => [
      { value: await scalar("SELECT COUNT(*) FROM findings_history WHERE status = 'open'") },
    ],
  },
  {
    id: "worst-supplier",
    factScope: "first-row",
    question: "Which supplier has the lowest on-time delivery percentage?",
    call: {
      tool: "query_lakehouse_sql",
      arguments: {
        sql:
          "SELECT name, on_time_pct FROM suppliers ORDER BY on_time_pct ASC, name ASC LIMIT 5",
      },
    },
    expected: async () => [
      {
        value: await scalar(
          "SELECT name FROM suppliers WHERE on_time_pct = (SELECT MIN(on_time_pct) FROM suppliers) ORDER BY name ASC LIMIT 1",
        ),
      },
    ],
  },
];

/* ------------------------------------------------------------------ */
/* Fact-checking                                                       */
/* ------------------------------------------------------------------ */

function collectLeaves(node: unknown, strings: string[], numbers: number[]): void {
  if (typeof node === "string") {
    strings.push(node);
    // Also surface numbers embedded in prose ("309 launches", "$1,234.56").
    for (const m of node.matchAll(/-?\d[\d,]*(?:\.\d+)?/g)) {
      const n = Number(m[0].replaceAll(",", ""));
      if (Number.isFinite(n)) numbers.push(n);
    }
    return;
  }
  if (typeof node === "number") {
    numbers.push(node);
    return;
  }
  if (Array.isArray(node)) {
    for (const item of node) collectLeaves(item, strings, numbers);
    return;
  }
  if (typeof node === "object" && node !== null) {
    for (const v of Object.values(node)) collectLeaves(v, strings, numbers);
  }
}

/**
 * Narrow a tool result to the part the facts must appear in. For a ranking
 * question that is row 0 of the result set — the winner the question asked
 * for. Anything without a `rows` array (a fixture-shaped result, or an agent's
 * Adaptive Card at L8) is checked whole.
 */
export function scopePayload(payload: unknown, scope: GoldenQuestion["factScope"]): unknown {
  if (scope !== "first-row") return payload;
  const rows = (payload as { rows?: unknown[] } | null)?.rows;
  if (!Array.isArray(rows)) return payload;
  if (rows.length === 0) return [];
  return rows[0];
}

/**
 * Does a tool result (or, at L8, an agent's Adaptive Card) contain the expected
 * fact anywhere — a cell, a column, a label, a sentence?
 */
export function resultContains(payload: unknown, fact: ExpectedFact): boolean {
  const strings: string[] = [];
  const numbers: number[] = [];
  collectLeaves(payload, strings, numbers);
  if (typeof fact.value === "number") {
    const tol = fact.tolerance ?? 1e-9;
    return numbers.some((n) => Math.abs(n - (fact.value as number)) <= tol);
  }
  const needle = fact.value.toLowerCase();
  return strings.some((s) => s.toLowerCase().includes(needle));
}
