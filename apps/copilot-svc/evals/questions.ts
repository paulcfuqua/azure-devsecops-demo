/**
 * Golden-question eval set (L8 functional contract, master plan §L8).
 *
 * Expectations are computed from data/generated at eval time by running
 * independent SQL against the same lakehouse — NOT copied from the mock plans
 * (the plans compose specs from live tool results; the eval re-derives the
 * facts separately, mirroring how the Verifier re-executes SQL at V8.1).
 *
 * The single documented hardcode is Saturday = 309 launches — the generator's
 * seeded weekday bias (seed 20260822), pinned by Track A's distribution test
 * and named in the master plan.
 */
import { queryLakehouse } from "../src/data/lakehouse.js";

export interface ExpectedFact {
  /** Value that must appear somewhere in the returned spec. */
  value: string | number;
  /** Compare numbers with this absolute tolerance (default exact). */
  tolerance?: number;
}

export interface GoldenQuestion {
  id: string;
  question: string;
  /** Compute the expected facts from the lakehouse (independent SQL). */
  expected: () => Promise<ExpectedFact[]>;
}

async function scalar(sql: string): Promise<string | number> {
  const r = await queryLakehouse(sql);
  const v = r.rows[0]?.[0];
  if (v === undefined || v === null) throw new Error(`expectation SQL returned no value: ${sql}`);
  return v as string | number;
}

/** Documented pin: the generator's Saturday launch bias (master plan §L8). */
export const SATURDAY_LAUNCH_COUNT = 309;

export const goldenQuestions: GoldenQuestion[] = [
  {
    id: "day-of-week",
    question: "Which day of the week has the most launches?",
    expected: async () => {
      const top = await queryLakehouse(
        `SELECT CASE strftime('%w', actual_date)
           WHEN '0' THEN 'Sunday' WHEN '1' THEN 'Monday' WHEN '2' THEN 'Tuesday'
           WHEN '3' THEN 'Wednesday' WHEN '4' THEN 'Thursday' WHEN '5' THEN 'Friday'
           ELSE 'Saturday' END AS weekday, COUNT(*) AS n
         FROM launches GROUP BY weekday ORDER BY n DESC, weekday ASC LIMIT 1`,
      );
      const day = String(top.rows[0]?.[0]);
      const count = Number(top.rows[0]?.[1]);
      if (day !== "Saturday" || count !== SATURDAY_LAUNCH_COUNT) {
        throw new Error(
          `seed drift: expected Saturday=${SATURDAY_LAUNCH_COUNT}, lakehouse says ${day}=${count}`,
        );
      }
      return [{ value: "Saturday" }, { value: SATURDAY_LAUNCH_COUNT }];
    },
  },
  {
    id: "total-launches",
    question: "How many launches are in the lakehouse?",
    expected: async () => [{ value: await scalar("SELECT COUNT(*) FROM launches") }],
  },
  {
    id: "success-rate",
    question: "What is the overall launch success rate?",
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
    question: "Which vehicle has flown the most launches?",
    expected: async () => [
      {
        value: await scalar(
          "SELECT v.name FROM launches l JOIN vehicles v ON v.vehicle_id = l.vehicle_id GROUP BY v.name ORDER BY COUNT(*) DESC, v.name ASC LIMIT 1",
        ),
      },
    ],
  },
  {
    id: "busiest-pad",
    question: "Which pad hosted the most launches?",
    expected: async () => [
      {
        value: await scalar(
          "SELECT p.name FROM launches l JOIN pads p ON p.pad_id = l.pad_id GROUP BY p.name ORDER BY COUNT(*) DESC, p.name ASC LIMIT 1",
        ),
      },
    ],
  },
  {
    id: "scrub-category",
    question: "What is the most common scrub category?",
    expected: async () => [
      {
        value: await scalar(
          "SELECT category FROM scrubs GROUP BY category ORDER BY COUNT(*) DESC, category ASC LIMIT 1",
        ),
      },
    ],
  },
  {
    id: "scrubbed-launches",
    question: "How many launches were scrubbed at least once?",
    expected: async () => [
      { value: await scalar("SELECT COUNT(*) FROM launches WHERE scrub_count > 0") },
    ],
  },
  {
    id: "top-cost-center",
    question: "Which cost center has the highest total spend?",
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
    question: "How many security findings are currently open?",
    expected: async () => [
      { value: await scalar("SELECT COUNT(*) FROM findings_history WHERE status = 'open'") },
    ],
  },
  {
    id: "worst-supplier",
    question: "Which supplier has the lowest on-time delivery percentage?",
    expected: async () => [
      {
        value: await scalar(
          "SELECT name FROM suppliers ORDER BY on_time_pct ASC, name ASC LIMIT 1",
        ),
      },
    ],
  },
];

/* ------------------------------------------------------------------ */
/* Spec fact-checking                                                  */
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
 * Does the spec contain the expected fact anywhere (component values, chart
 * data, descriptions, markdown)? Robust to both mock and live-model phrasing.
 */
export function specContains(spec: unknown, fact: ExpectedFact): boolean {
  const strings: string[] = [];
  const numbers: number[] = [];
  collectLeaves(spec, strings, numbers);
  if (typeof fact.value === "number") {
    const tol = fact.tolerance ?? 1e-9;
    return numbers.some((n) => Math.abs(n - (fact.value as number)) <= tol);
  }
  const needle = fact.value.toLowerCase();
  return strings.some((s) => s.toLowerCase().includes(needle));
}
