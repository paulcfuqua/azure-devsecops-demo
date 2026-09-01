/**
 * HTTP surface — deliberately two routes and nothing else:
 *
 *   POST /mcp     the MCP endpoint (Streamable HTTP transport). This is what
 *                 the Copilot Studio agent attaches to. SSE is NOT offered:
 *                 Copilot Studio dropped SSE support after August 2025 and
 *                 Streamable HTTP is the required transport.
 *   GET  /healthz liveness for Container Apps probes, and the one place the
 *                 backend selection is observable from outside the process.
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
import { telemetryStatus } from "./telemetry.js";
import { createLocalBackends, type Backends } from "./tools/backends.js";
import { ToolRegistry } from "./tools/index.js";
import { requireInboundAuth } from "./auth-gate.js";

export const MCP_PATH = "/mcp";

export interface AppDeps {
  config?: McpToolsConfig;
  /**
   * Pre-built backend set. Cloud backends are built asynchronously (a managed
   * identity has to be constructed first), so the entry point resolves them and
   * hands them in; `createApp` stays synchronous and test-friendly.
   */
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

  // The gate is mounted BEFORE the body parser, deliberately: an
  // unauthenticated caller must not be able to make the process parse up to
  // 1MB of JSON before a credential is even checked. /healthz is unaffected —
  // the gate is scoped to MCP_PATH, so GET /healthz never reaches it.
  const gate = requireInboundAuth(config.inboundAuth);
  app.use(MCP_PATH, gate);

  app.use(express.json({ limit: "1mb" }));

  app.get("/healthz", (_req, res) => {
    res.json({
      ok: true,
      mode: config.backendMode,
      tools: registry.definitions.length,
      // The DECLARED tool names, not just the count.
      //
      // /healthz exists so the L7/L8 audits can assert from outside that this
      // endpoint is not open (see `auth` below). V8.3 asserts something adjacent:
      // that the server declares exactly the six allowlisted tools and no more.
      // It was reaching for that over `tools/list`, which is behind the gate, so
      // it got a 401 - an anonymous probe of an authenticated endpoint, which is
      // F89's shape a second time (F100).
      //
      // Publishing the names here is the right fix rather than handing the
      // Verifier `mcp-auth-token`. That token is compared with timingSafeEqual:
      // it IS the capability, so giving it to the auditor would make it a fully
      // authorised caller of the thing it audits - a much larger concession than
      // the criterion is worth. A tool NAME, by contrast, is the one thing an MCP
      // server exists to advertise, the count is already here, and the `adapters`
      // map below already names five of the six. Nothing new is disclosed.
      toolNames: registry.definitions.map((tool) => tool.name),
      transport: "streamable-http",
      endpoint: MCP_PATH,
      // Which SQL dialect the agent is currently being told to write. This is
      // the single most useful field on this route: a `cloud` server still
      // advertising `sqlite` would mean the descriptions and the engine had
      // come apart, and every date question would fail.
      sqlDialect: registry.dialect,
      // Per-tool adapter selection, by implementation class. Makes a partial
      // or mis-wired switchover visible at a glance instead of one tool call
      // at a time.
      adapters: {
        query_lakehouse_sql: backends.lakehouseSql.constructor.name,
        query_log_analytics: backends.logAnalytics.constructor.name,
        get_github_security: backends.githubSecurity.constructor.name,
        get_defender_posture: backends.defenderPosture.constructor.name,
        get_cost_series: backends.costSeries.constructor.name,
      },
      // Whether spans are actually leaving the process. `reason` is deliberately
      // NOT exposed here — /healthz is unauthenticated at the ingress and the
      // reason string can name an Application Insights resource.
      telemetry: {
        enabled: telemetryStatus().enabled,
        exporter: telemetryStatus().exporter,
      },
      // Posture only — never the token, never a prefix of it. This is what lets
      // the L7/L8 audits assert from outside that the endpoint is not open.
      auth: {
        enforced: config.inboundAuth?.enforced ?? false,
        deliberatelyOpen: config.inboundAuth?.deliberatelyOpen ?? false,
      },
    });
  });

  // Everything under MCP_PATH is gated (mounted above, before the body
  // parser); /healthz above stays open because the Container Apps liveness
  // probe calls it and it discloses no secret (note the telemetry `reason` is
  // deliberately withheld there for the same reason).
  app.post(MCP_PATH, async (req, res) => {
    // Stateless: a fresh server + transport per request, torn down when the
    // response closes. The expensive state (the loaded lakehouse) lives in the
    // shared backends, so this costs almost nothing.
    const server = createMcpServer(registry, { backendMode: config.backendMode });
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
