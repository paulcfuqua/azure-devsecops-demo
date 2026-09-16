/**
 * `query_aws_lakehouse_sql` registration (Task 7).
 *
 * The signature defect this file exists to catch: `buildToolDefinitions` is
 * called from exactly ONE live place, the `ToolRegistry` constructor
 * (src/tools/index.ts). A tool added to `ALLOWED_TOOL_NAMES` and
 * `buildToolDefinitions` but never threaded through `Backends` and
 * `ToolRegistry` passes every test that only calls `buildToolDefinitions`
 * directly, and is never once served to a real agent. The last test below
 * is the one that catches that — it goes through `ToolRegistry`, not the
 * builder function, on both a configured and an unconfigured backend set.
 */
import { describe, it, expect } from "vitest";
import {
  ALLOWED_TOOL_NAMES,
  buildToolDefinitions,
  isAllowedTool,
  ToolRegistry,
} from "../src/tools/index.js";
import { createLocalBackends, type Backends, type LakehouseSqlBackend } from "../src/tools/backends.js";

/** A minimal stand-in for AthenaLakehouseSqlBackend — no AWS SDK, no network. */
function stubAwsBackend(): LakehouseSqlBackend {
  return {
    dialect: "trino",
    async query(_sql: string) {
      return { columns: ["n"], rows: [[1]], rowCount: 1, truncated: false };
    },
  };
}

describe("AWS lakehouse tool registration", () => {
  it("is on the allowlist", () => {
    expect(ALLOWED_TOOL_NAMES).toContain("query_aws_lakehouse_sql");
    expect(isAllowedTool("query_aws_lakehouse_sql")).toBe(true);
  });

  it("the allowlist is now seven names, not six", () => {
    // A literal count here is exactly the trap F145 describes for a list
    // feeding two checks — but THIS file is the one place that count is
    // supposed to be pinned, precisely so a future eighth tool has to touch
    // this assertion too.
    expect(ALLOWED_TOOL_NAMES).toHaveLength(7);
  });

  it("appears only when AWS is configured", () => {
    const withAws = buildToolDefinitions("tsql", "lakehouse-ledger", { aws: true }).map(
      (t) => t.name,
    );
    const without = buildToolDefinitions("tsql", "lakehouse-ledger", { aws: false }).map(
      (t) => t.name,
    );
    expect(withAws).toContain("query_aws_lakehouse_sql");
    expect(without).not.toContain("query_aws_lakehouse_sql");
    expect(without).toContain("query_lakehouse_sql");
  });

  it("defaults to absent when opts is omitted entirely", () => {
    const names = buildToolDefinitions("sqlite").map((t) => t.name);
    expect(names).not.toContain("query_aws_lakehouse_sql");
    expect(names).toHaveLength(6);
  });

  // The two tools must not describe the same dialect. If they do, one is
  // advertising idioms that are wrong for the engine it will hit -- the exact
  // latent break sql-dialect.ts was written to prevent.
  it("describes Trino for AWS and T-SQL for Fabric", () => {
    const tools = buildToolDefinitions("tsql", "lakehouse-ledger", { aws: true });
    const fabric = tools.find((t) => t.name === "query_lakehouse_sql")!.description!;
    const aws = tools.find((t) => t.name === "query_aws_lakehouse_sql")!.description!;
    expect(aws).toContain("day_of_week");
    expect(fabric).toContain("DATEPART");
    expect(aws).not.toContain("DATEPART");
  });

  // The AWS tool is ALWAYS Trino, regardless of which dialect the Meridian
  // lakehouse tool is currently speaking.
  it("describes Trino for AWS even when the Meridian tool is sqlite", () => {
    const tools = buildToolDefinitions("sqlite", "lakehouse-ledger", { aws: true });
    const aws = tools.find((t) => t.name === "query_aws_lakehouse_sql")!.description!;
    expect(aws).toContain("day_of_week");
    expect(aws).not.toContain("strftime(");
  });

  // The two datasets describe different organisations; the description must
  // say so, not just carry a different name.
  it("names the dataset as real launch-provider data, distinct from Meridian's own", () => {
    const aws = buildToolDefinitions("sqlite", "lakehouse-ledger", { aws: true }).find(
      (t) => t.name === "query_aws_lakehouse_sql",
    )!.description!;
    expect(aws).toMatch(/REAL launch-provider data/);
    expect(aws).toMatch(/query_lakehouse_sql/);
  });

  // tools/list order is agent-facing surface, as the costSeriesTool splice
  // comment in index.ts says. Pin the new tool's position deliberately.
  it("places the AWS tool immediately after the Fabric one", () => {
    const names = buildToolDefinitions("tsql", "lakehouse-ledger", { aws: true }).map(
      (t) => t.name,
    );
    expect(names[0]).toBe("query_lakehouse_sql");
    expect(names[1]).toBe("query_aws_lakehouse_sql");
  });

  it("get_cost_series keeps its position when AWS is also present", () => {
    const names = buildToolDefinitions("tsql", "azure-cost-management", { aws: true }).map(
      (t) => t.name,
    );
    expect(names).toContain("get_cost_series");
    expect(names.indexOf("get_cost_series")).toBe(names.indexOf("query_compliance") - 1);
  });

  describe("production wiring: ToolRegistry, not just buildToolDefinitions", () => {
    it("advertises the tool when the backend set carries an AWS backend", () => {
      const backendsWithAws: Backends = { ...createLocalBackends(), awsLakehouseSql: stubAwsBackend() };
      const registry = new ToolRegistry(backendsWithAws);
      expect(registry.definitions.map((t) => t.name)).toContain("query_aws_lakehouse_sql");
    });

    it("does not advertise the tool for the plain local backend set", () => {
      const registry = new ToolRegistry(createLocalBackends());
      expect(registry.definitions.map((t) => t.name)).not.toContain("query_aws_lakehouse_sql");
    });

    it("executes against the configured AWS backend", async () => {
      const backendsWithAws: Backends = { ...createLocalBackends(), awsLakehouseSql: stubAwsBackend() };
      const registry = new ToolRegistry(backendsWithAws);
      const result = (await registry.execute("query_aws_lakehouse_sql", {
        sql: "SELECT 1 AS n",
      })) as { rows: unknown[][] };
      expect(result.rows).toEqual([[1]]);
    });

    it("throws clearly if the name arrives with no AWS backend behind it", async () => {
      const registry = new ToolRegistry(createLocalBackends());
      // Bypass the allowlist gate the MCP server would normally apply first —
      // this is the "second line of defense" the class doc comment describes.
      await expect(registry.execute("query_aws_lakehouse_sql", { sql: "SELECT 1" })).rejects.toThrow(
        /no AWS lakehouse backend is configured/,
      );
    });
  });
});
