/**
 * HTTP surface — deliberately two routes and nothing else:
 *
 *   POST /mcp     the MCP endpoint (Streamable HTTP transport). This is what
 *                 the Copilot Studio agent attaches to. SSE is NOT offered:
 *                 Copilot Studio dropped SSE support after August 2025 and
 *                 Streamable HTTP is the required transport.
 *   GET  /healthz liveness for Container Apps probes: mode + tool count.
 *
 * GET/DELETE on /mcp are answered 405: this server runs STATELESS (no session
 * id, no server-initiated stream), so there is no long-lived stream to resume
 * and no session to delete. Stateless is what lets the container app scale to
 * zero and back without a client noticing.
 */
import express, { type Express } from "express";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { loadConfig, type McpToolsConfig } from "./config.js";
import { createMcpServer } from "./mcp/server.js";
import { createLocalBackends, type Backends } from "./tools/backends.js";
import { toolDefinitions, ToolRegistry } from "./tools/index.js";

export const MCP_PATH = "/mcp";

export interface AppDeps {
  config?: McpToolsConfig;
  backends?: Backends;
}

/** JSON-RPC error body for the methods this endpoint does not implement. */
const METHOD_NOT_ALLOWED = {
  jsonrpc: "2.0" as const,
  error: { code: -32601, message: "Method not allowed: this MCP endpoint is stateless (POST only)." },
  id: null,
};

export function createApp(deps: AppDeps = {}): Express {
  const config = deps.config ?? loadConfig();
  const backends = deps.backends ?? createLocalBackends();
  const registry = new ToolRegistry(backends);

  const app = express();
  app.use(express.json({ limit: "1mb" }));

  app.get("/healthz", (_req, res) => {
    res.json({
      ok: true,
      mode: config.backendMode,
      tools: toolDefinitions.length,
      transport: "streamable-http",
      endpoint: MCP_PATH,
    });
  });

  app.post(MCP_PATH, async (req, res) => {
    // Stateless: a fresh server + transport per request, torn down when the
    // response closes. The expensive state (the loaded lakehouse) lives in the
    // shared backends, so this costs almost nothing.
    const server = createMcpServer(registry);
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
    res.on("close", () => {
      void transport.close();
      void server.close();
    });
    try {
      await server.connect(transport);
      await transport.handleRequest(req, res, req.body);
    } catch (err) {
      console.error(`[mcp-tools] request failed: ${(err as Error).message}`);
      if (!res.headersSent) {
        res.status(500).json({
          jsonrpc: "2.0",
          error: { code: -32603, message: "Internal server error" },
          id: null,
        });
      }
    }
  });

  app.get(MCP_PATH, (_req, res) => res.status(405).json(METHOD_NOT_ALLOWED));
  app.delete(MCP_PATH, (_req, res) => res.status(405).json(METHOD_NOT_ALLOWED));

  return app;
}
