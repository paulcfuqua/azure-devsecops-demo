/**
 * V8.2 — tool allowlist enforcement. Exactly six tools are advertised over
 * MCP, and any other tool name is refused without execution.
 *
 * These assertions run against the real MCP server through an in-memory
 * transport pair, so they exercise the same handlers the Copilot Studio agent
 * hits over HTTP, minus the socket.
 */
import { describe, expect, it } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createMcpServer } from "../src/mcp/server.js";
import { createLocalBackends } from "../src/tools/backends.js";
import {
  ALLOWED_TOOL_NAMES,
  isAllowedTool,
  toolDefinitions,
  ToolRegistry,
} from "../src/tools/index.js";

const EXPECTED_NAMES = [
  "get_cost_series",
  "get_defender_posture",
  "get_github_security",
  "query_compliance",
  "query_lakehouse_sql",
  "query_log_analytics",
];

async function connectInMemory(): Promise<Client> {
  const registry = new ToolRegistry(createLocalBackends());
  const server = createMcpServer(registry);
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: "allowlist-test", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  return client;
}

describe("tool allowlist (V8.2)", () => {
  it("declares exactly the six master-plan tools", () => {
    expect(toolDefinitions.map((t) => t.name).sort()).toEqual(EXPECTED_NAMES);
    expect(toolDefinitions).toHaveLength(6);
    expect(ALLOWED_TOOL_NAMES).toHaveLength(6);
  });

  it("isAllowedTool rejects unknown names", () => {
    expect(isAllowedTool("query_lakehouse_sql")).toBe(true);
    expect(isAllowedTool("delete_everything")).toBe(false);
    expect(isAllowedTool("bash")).toBe(false);
    expect(isAllowedTool("")).toBe(false);
  });

  it("registry.execute throws for names off the allowlist", async () => {
    const registry = new ToolRegistry(createLocalBackends());
    await expect(registry.execute("run_shell", {})).rejects.toThrow(/allowlist/);
  });

  it("tools/list advertises six tools with agent-facing descriptions and object schemas", async () => {
    const client = await connectInMemory();
    const { tools } = await client.listTools();

    expect(tools).toHaveLength(6);
    expect(tools.map((t) => t.name).sort()).toEqual(EXPECTED_NAMES);
    for (const tool of tools) {
      // The description is what the agent's orchestrator reasons over — an
      // empty or throwaway one is a defect, not a style nit.
      expect(tool.description ?? "").toMatch(/\S/);
      expect((tool.description ?? "").length).toBeGreaterThan(120);
      expect(tool.inputSchema.type).toBe("object");
    }
    await client.close();
  });

  it("refuses a tools/call for a name off the allowlist, without executing anything", async () => {
    const client = await connectInMemory();
    const result = await client.callTool({ name: "delete_everything", arguments: {} });

    expect(result.isError).toBe(true);
    expect(JSON.stringify(result.content)).toContain("not on the allowlist");
    await client.close();
  });

  it("surfaces an adapter failure as an is_error result, not a protocol crash", async () => {
    const client = await connectInMemory();
    const result = await client.callTool({
      name: "query_lakehouse_sql",
      arguments: { sql: "DROP TABLE launches" },
    });

    expect(result.isError).toBe(true);
    expect(JSON.stringify(result.content)).toMatch(/read-only/i);
    await client.close();
  });
});
