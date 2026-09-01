/**
 * MCP client smoke test — the contract the Copilot Studio agent depends on.
 *
 * Spins the real service in-process on an ephemeral port, connects with the
 * official MCP SDK client over Streamable HTTP (the transport Copilot Studio
 * requires — SSE support was dropped after August 2025), lists the tools and
 * calls them, asserting values that come from Track A's deterministic data
 * (seed 20260822): 1200 launches, Saturday = 309.
 */
import type { AddressInfo } from "node:net";
import type { Server as HttpServer } from "node:http";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { createApp } from "../src/app.js";

let http: HttpServer;
let baseUrl: string;
let client: Client;

/** What client.callTool resolves to (a union including the legacy result shape). */
type McpToolResult = Awaited<ReturnType<Client["callTool"]>>;

/** The JSON payload a tool returned (tools return data only — no prose, no UI). */
function payloadOf(result: McpToolResult): any {
  const content = result.content as Array<{ type: string; text?: string }> | undefined;
  const text = content?.[0]?.text;
  if (typeof text !== "string") throw new Error("tool result had no text content");
  return JSON.parse(text);
}

beforeAll(async () => {
  const app = createApp({
    config: {
      port: 0,
      backendMode: "local",
      inboundAuth: { token: undefined, enforced: false, deliberatelyOpen: false },
    },
  });
  http = app.listen(0);
  await new Promise<void>((resolve) => http.once("listening", () => resolve()));
  baseUrl = `http://127.0.0.1:${(http.address() as AddressInfo).port}`;

  client = new Client({ name: "mcp-tools-smoke-test", version: "0.0.0" });
  await client.connect(new StreamableHTTPClientTransport(new URL(`${baseUrl}/mcp`)));
});

afterAll(async () => {
  await client?.close();
  await new Promise<void>((resolve) => http.close(() => resolve()));
});

describe("MCP over Streamable HTTP", () => {
  it("GET /healthz reports mode, dialect, per-tool adapters, telemetry and the MCP endpoint", async () => {
    const res = await fetch(`${baseUrl}/healthz`);
    expect(res.status).toBe(200);
    // Exact shape, not a subset: /healthz is the operator's view of which
    // adapter set is live, and a field silently disappearing from it is the
    // kind of regression that only shows up during a switchover.
    expect(await res.json()).toEqual({
      ok: true,
      mode: "local",
      tools: 6,
      // The DECLARED names, not just the count: V8.3 reads them from here rather
      // than from tools/list, which sits behind the shared-secret gate (F100).
      toolNames: [
        "query_lakehouse_sql",
        "query_log_analytics",
        "get_github_security",
        "get_defender_posture",
        "get_cost_series",
        "query_compliance",
      ],
      transport: "streamable-http",
      endpoint: "/mcp",
      sqlDialect: "sqlite",
      adapters: {
        query_lakehouse_sql: "LocalLakehouseSqlBackend",
        query_log_analytics: "FixtureLogAnalyticsBackend",
        get_github_security: "FixtureGithubSecurityBackend",
        get_defender_posture: "FixtureDefenderPostureBackend",
        get_cost_series: "LocalCostSeriesBackend",
      },
      telemetry: { enabled: false, exporter: "disabled" },
      // Posture only. A token must never appear on an unauthenticated route.
      auth: { enforced: false, deliberatelyOpen: false },
    });
  });

  it("lists exactly six tools", async () => {
    const { tools } = await client.listTools();
    expect(tools).toHaveLength(6);
    expect(tools.map((t) => t.name).sort()).toEqual([
      "get_cost_series",
      "get_defender_posture",
      "get_github_security",
      "query_compliance",
      "query_lakehouse_sql",
      "query_log_analytics",
    ]);
  });

  it("query_lakehouse_sql returns the real row count: 1200 launches", async () => {
    const result = await client.callTool({
      name: "query_lakehouse_sql",
      arguments: { sql: "SELECT COUNT(*) AS n FROM launches" },
    });
    expect(result.isError).toBeFalsy();

    const payload = payloadOf(result);
    expect(payload.columns).toEqual(["n"]);
    expect(payload.rows[0][0]).toBe(1200);
    // The same data is also offered as structured content for clients that
    // prefer it to parsing the text block.
    expect((result.structuredContent as any).result.rows[0][0]).toBe(1200);
  });

  it("query_lakehouse_sql answers the canonical golden question: Saturday, 309", async () => {
    const result = await client.callTool({
      name: "query_lakehouse_sql",
      arguments: {
        sql: `SELECT CASE strftime('%w', actual_date)
                WHEN '0' THEN 'Sunday' WHEN '1' THEN 'Monday' WHEN '2' THEN 'Tuesday'
                WHEN '3' THEN 'Wednesday' WHEN '4' THEN 'Thursday' WHEN '5' THEN 'Friday'
                ELSE 'Saturday' END AS weekday, COUNT(*) AS n
              FROM launches GROUP BY weekday ORDER BY n DESC, weekday ASC LIMIT 1`,
      },
    });
    expect(result.isError).toBeFalsy();
    expect(payloadOf(result).rows[0]).toEqual(["Saturday", 309]);
  });

  it("get_cost_series returns the Cost Management shape from cost_daily", async () => {
    const result = await client.callTool({
      name: "get_cost_series",
      arguments: { cost_center: "Propulsion" },
    });
    expect(result.isError).toBeFalsy();

    const payload = payloadOf(result);
    expect(payload.type).toBe("Microsoft.CostManagement/query");
    expect(payload.properties.rows.length).toBeGreaterThan(0);
    expect(payload.properties.rows.every((row: unknown[]) => row[1] === "Propulsion")).toBe(true);
  });

  it("get_defender_posture returns the ARM secureScores shape", async () => {
    const result = await client.callTool({ name: "get_defender_posture", arguments: {} });
    expect(result.isError).toBeFalsy();

    const payload = payloadOf(result);
    expect(payload.secure_score.name).toBe("ascScore");
    expect(payload.controls.value.length).toBeGreaterThan(0);
  });

  it("query_compliance answers from the real committed state artifact", async () => {
    const result = await client.callTool({
      name: "query_compliance",
      arguments: { control: "3.1.1" },
    });
    expect(result.isError).toBeFalsy();

    const payload = payloadOf(result);
    expect(payload.controls[0].control).toBe("3.1.1");
    // Whole-estate counts ride along on every answer — see compliance-tool.test.ts
    // for the full honesty-rule coverage, including the no-percentage checks.
    expect(payload.summary.totalRequirements).toBe(110);
  });

  it("GET /mcp is 405 — the endpoint is stateless and POST-only", async () => {
    const res = await fetch(`${baseUrl}/mcp`);
    expect(res.status).toBe(405);
  });
});
