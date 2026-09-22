/**
 * What the agent is TOLD exists, which is a different thing from what exists.
 *
 * Asked "what day did Bertram Kingsleigh start working for MLS", the deployed agent replied
 * "I'm sorry, I'm not sure how to help with that. Can you try rephrasing?" — Copilot Studio's
 * FALLBACK topic, not a refusal. No tool call was attempted, because nothing in the tool's
 * description mentioned a person table. The roster had been seeded, protected and verified,
 * and remained invisible to the only thing that was supposed to query it.
 *
 * A capability that exists in the data and not in the tool description does not exist to the
 * agent. These tests assert the description carries the governed views — and, just as
 * deliberately, that it does NOT carry the tables beneath them.
 */
import { describe, expect, it } from "vitest";

import { buildToolDefinitions } from "../src/tools/index.js";

function lakehouseDescription(): string {
  const tools = buildToolDefinitions("tsql");
  const tool = tools.find((t) => t.name === "query_lakehouse_sql");
  if (!tool) throw new Error("query_lakehouse_sql is not registered");
  return `${tool.description ?? ""} ${JSON.stringify(tool.inputSchema ?? {})}`;
}

describe("the schema advertised to the agent", () => {
  it("names the governed views, so the agent can compose a query against them", () => {
    const d = lakehouseDescription();
    expect(d).toContain("v_hr_roster");
    expect(d).toContain("v_defect_reports");
  });

  it("names the roster columns a question would actually ask about", () => {
    const d = lakehouseDescription();
    for (const column of ["display_name", "start_date", "department", "tenure_years"]) {
      expect(d, `roster column ${column} is not advertised`).toContain(column);
    }
  });

  // THE POINT OF THE DESIGN. The agent is not told the base tables exist, so the only HR
  // shape it can build a query against is the one with no compensation in it. The control
  // works by CONSTRUCTION rather than by refusal - an agent that does not know a column
  // exists cannot be argued into selecting it.
  it("does NOT advertise the restricted columns", () => {
    const d = lakehouseDescription();
    for (const column of ["salary_usd", "bonus_target_pct", "performance_band"]) {
      expect(d, `${column} must never appear in what the agent is told`).not.toContain(column);
    }
  });

  it("does NOT advertise the base tables the views protect", () => {
    const d = lakehouseDescription();
    // Whole-identifier checks: "v_hr_roster" contains "hr_roster" as a substring, and the
    // view is exactly what we DO want advertised.
    expect(/\bhr_roster\b/.test(d), "dbo.hr_roster must not be advertised").toBe(false);
    expect(/\bdefect_reports\b/.test(d), "dbo.defect_reports must not be advertised").toBe(false);
  });

  it("still advertises the ten open tables, so this change removed nothing", () => {
    const d = lakehouseDescription();
    for (const table of [
      "launches", "scrubs", "vehicles", "pads", "telemetry_summary",
      "parts", "suppliers", "work_orders", "cost_daily", "findings_history",
    ]) {
      expect(d, `open table ${table} disappeared from the description`).toContain(table);
    }
  });
});
