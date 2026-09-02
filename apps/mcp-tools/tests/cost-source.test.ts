/**
 * F138 — the tool description told the agent to answer a cloud-cost question
 * from a fictional business ledger, and the agent did exactly that.
 *
 * Asked "how much have we spent to date in our tenant subscription", the Ask
 * tab replied "$23,561,191.14999999 USD, based on the full history in the
 * cost_daily dataset". The real subscription had consumed about $1.40.
 *
 * The agent was not misbehaving. Its contract said so:
 *
 *   get_cost_series     "Fetch the daily Azure spend series … The five cost
 *                        centers are 'Propulsion', 'Avionics' … for
 *                        whole-history aggregates query the cost_daily table
 *                        with query_lakehouse_sql instead."
 *   query_lakehouse_sql "Use this for … daily cloud spend …"
 *
 * Every one of those clauses is false in cloud mode: `cost_daily` is Meridian's
 * synthetic business ledger, cost centres in cloud mode are costCenter TAG
 * values, and the substitution the description recommends is exactly the wrong
 * answer. This is the `strftime` defect again (see sql-dialect.test.ts) - a
 * description written for one backend and shipped with another - so it gets the
 * same fix: build it from what the active backend declares.
 *
 * These tests are about the agent-facing TEXT, because the text is the contract.
 */
import { describe, expect, it } from "vitest";
import { buildToolDefinitions, ToolRegistry } from "../src/tools/index.js";
import { createLocalBackends } from "../src/tools/backends.js";

function tool(name: string, costSource: "lakehouse-ledger" | "azure-cost-management") {
  const found = buildToolDefinitions("sqlite", costSource).find((t) => t.name === name);
  if (!found) throw new Error(`no such tool: ${name}`);
  return found;
}

const cloudCost = () => tool("get_cost_series", "azure-cost-management").description ?? "";
const localCost = () => tool("get_cost_series", "lakehouse-ledger").description ?? "";

describe("get_cost_series describes the bill it actually reads (F138)", () => {
  it("names the real Azure bill when the cloud backend is behind it", () => {
    expect(cloudCost()).toMatch(/Cost Management/);
    expect(cloudCost()).toMatch(/costCenter tag/);
  });

  it("does NOT claim to read Azure when it is reading the synthetic ledger", () => {
    // The old text promised "the daily Azure spend series" in both modes. In
    // local mode that sentence is simply untrue, and it is the sentence an
    // orchestrator reasons over.
    expect(localCost()).toMatch(/SYNTHETIC|synthetic/);
    expect(localCost()).not.toMatch(/Fetch REAL daily Azure consumption/);
  });

  it("never names the fictional cost centres while reading Azure", () => {
    // 'Propulsion' and 'Avionics' are Meridian's imaginary departments. In
    // cloud mode the cost centres are whatever costCenter tag values the
    // resource groups carry, and advertising a fixed list invites a filter
    // that silently matches nothing.
    expect(cloudCost()).not.toMatch(/Propulsion/);
    expect(localCost()).toMatch(/Propulsion/);
  });

  it("forbids the substitution instead of recommending it", () => {
    // The single clause that caused F138: "for whole-history aggregates query
    // the cost_daily table with query_lakehouse_sql instead."
    expect(cloudCost()).not.toMatch(/query the cost_daily table/);
    expect(cloudCost()).toMatch(/NEVER substitute the lakehouse `cost_daily` table/);
  });

  it("says what to do when the tool is unavailable, because that was the trigger", () => {
    // Cost Management throttles per principal and a retry deepens the window,
    // so being unable to answer is a NORMAL state for this tool, not an
    // exceptional one. An honest "I could not retrieve it" is the answer; a
    // number from a different dataset wearing the question's words is not.
    expect(cloudCost()).toMatch(/rate-limited/);
    expect(cloudCost()).toMatch(/could not retrieve/);
  });

  it("the cost_center argument description matches the backend too", () => {
    const cloudArg = JSON.stringify(tool("get_cost_series", "azure-cost-management").inputSchema);
    const localArg = JSON.stringify(tool("get_cost_series", "lakehouse-ledger").inputSchema);
    expect(cloudArg).toMatch(/costCenter tag value/);
    expect(localArg).toMatch(/Range Operations/);
  });
});

describe("query_lakehouse_sql stops calling the business ledger cloud spend (F138)", () => {
  const description = (): string =>
    buildToolDefinitions("sqlite").find((t) => t.name === "query_lakehouse_sql")?.description ?? "";

  it("no longer advertises itself for cloud spend", () => {
    expect(description()).not.toMatch(/daily cloud spend/);
  });

  it("says explicitly that cost_daily is not a cloud bill", () => {
    expect(description()).toMatch(/NOT a cloud bill/);
    expect(description()).toMatch(/must never be used to answer a question about Azure/);
  });

  it("labels cost_daily in the schema listing, where an orchestrator reads column names", () => {
    // The schema block is the part a model actually copies from when writing
    // SQL. A table named `cost_daily` sitting in a list beside `launches` reads
    // as "the cost table" unless the listing says otherwise.
    expect(description()).toMatch(/BUSINESS ledger, not cloud spend/);
  });
});

describe("the registry describes the backend it was constructed with", () => {
  it("takes the cost source from the active backend, not a default", () => {
    // The bug class is a description that is correct in the mode the tests run
    // in and wrong in the mode that ships. Assert the wiring, not just the text.
    const registry = new ToolRegistry(createLocalBackends());
    const description =
      registry.definitions.find((t) => t.name === "get_cost_series")?.description ?? "";
    expect(description).toBe(localCost());
    expect(description).not.toBe(cloudCost());
  });

  it("still exposes exactly six tools in both cost modes", () => {
    for (const source of ["lakehouse-ledger", "azure-cost-management"] as const) {
      const names = buildToolDefinitions("sqlite", source).map((t) => t.name);
      expect(names).toHaveLength(6);
      expect(new Set(names).size).toBe(6);
      // Order is agent-facing surface; get_cost_series keeps the position it
      // held before it became backend-aware.
      expect(names[0]).toBe("query_lakehouse_sql");
      expect(names[4]).toBe("get_cost_series");
    }
  });
});
