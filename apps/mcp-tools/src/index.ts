/** Service entry point: the MCP tool server for the Copilot Studio agent. */
import { createApp, MCP_PATH } from "./app.js";
import { loadConfig } from "./config.js";
import { getLakehouseDb } from "./data/lakehouse.js";
import { toolDefinitions } from "./tools/index.js";

const config = loadConfig();
const app = createApp({ config });

// Warm the lakehouse at boot so the first tool call doesn't pay CSV-load
// latency. Failure is non-fatal here: the tool call surfaces the actionable
// error, and the four non-SQL tools stay available.
getLakehouseDb().catch((err) => {
  console.warn(`[mcp-tools] lakehouse warm-up failed: ${(err as Error).message}`);
});

app.listen(config.port, () => {
  console.log(
    `[mcp-tools] MCP server on :${config.port}${MCP_PATH} (streamable-http, stateless) — ` +
      `${toolDefinitions.length} tools, backends=${config.backendMode}`,
  );
});
