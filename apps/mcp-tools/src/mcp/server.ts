/**
 * The MCP server itself: five tools over the Model Context Protocol.
 *
 * The Copilot Studio agent attaches to this server as a tool source; it — not
 * this process — decides which tool to call and how to render the answer
 * (Adaptive Cards). This layer therefore returns DATA ONLY: the adapter result
 * serialised as JSON. No prose, no UI, no component specs.
 *
 * The low-level `Server` is used deliberately instead of `McpServer`: it takes
 * the hand-written JSON Schemas in src/tools/index.ts verbatim, so what the
 * agent's orchestrator sees is exactly what is written there, with no
 * zod-to-JSON-Schema translation in between.
 */
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  type CallToolResult,
} from "@modelcontextprotocol/sdk/types.js";
import { isAllowedTool, toolDefinitions, ToolRegistry } from "../tools/index.js";

export const SERVER_NAME = "mls-mcp-tools";
export const SERVER_VERSION = "0.1.0";

export const SERVER_INSTRUCTIONS =
  "Meridian Launch Systems operations tools. query_lakehouse_sql answers anything about " +
  "launches, fleet, supply chain, spend history and security findings by running SQL against " +
  "the operations lakehouse; query_log_analytics covers live platform telemetry; " +
  "get_github_security, get_defender_posture and get_cost_series return current security and " +
  "cost state. Every tool is read-only and returns JSON data — no prose and no UI. Prefer one " +
  "aggregate SQL query over many small calls, and cite the numbers the tools return rather " +
  "than estimating.";

/** Serialise an adapter result as an MCP tool result (data only). */
function dataResult(payload: unknown): CallToolResult {
  return {
    content: [{ type: "text", text: JSON.stringify(payload, null, 2) }],
    structuredContent: { result: payload } as Record<string, unknown>,
  };
}

function errorResult(message: string): CallToolResult {
  return { content: [{ type: "text", text: message }], isError: true };
}

/**
 * Build an MCP server bound to a tool registry.
 *
 * One server instance per transport (the HTTP layer runs stateless: a fresh
 * server + transport per request), so this is cheap by design — the expensive
 * state (the loaded lakehouse) lives in the shared backends, not here.
 */
export function createMcpServer(registry: ToolRegistry): Server {
  const server = new Server(
    { name: SERVER_NAME, version: SERVER_VERSION },
    { capabilities: { tools: {} }, instructions: SERVER_INSTRUCTIONS },
  );

  server.setRequestHandler(ListToolsRequestSchema, () => ({ tools: toolDefinitions }));

  server.setRequestHandler(CallToolRequestSchema, async (request): Promise<CallToolResult> => {
    const { name, arguments: args } = request.params;

    // Allowlist gate (audit V8.2): refused BEFORE any adapter runs.
    if (!isAllowedTool(name)) {
      return errorResult(
        `Tool "${name}" is not on the allowlist. This server exposes exactly five tools: ` +
          `${toolDefinitions.map((t) => t.name).join(", ")}.`,
      );
    }

    try {
      return dataResult(await registry.execute(name, args ?? {}));
    } catch (err) {
      // Adapter failures come back as an is_error tool result, not a protocol
      // error: the agent should see the message and correct itself (a bad SQL
      // statement is the common case) rather than have the turn blow up.
      return errorResult(`${name} failed: ${err instanceof Error ? err.message : String(err)}`);
    }
  });

  return server;
}
