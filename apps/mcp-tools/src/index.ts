/** Service entry point: the MCP tool server for the Copilot Studio agent. */
import { createApp, MCP_PATH } from "./app.js";
import { loadConfig } from "./config.js";
import { describeInboundAuth } from "./auth-gate.js";
import { getLakehouseDb } from "./data/lakehouse.js";
import { initTelemetry } from "./telemetry.js";
import { createLocalBackends, type Backends } from "./tools/backends.js";
import { createCloudBackends } from "./tools/cloud/index.js";

async function main(): Promise<void> {
  const config = loadConfig();

  // Telemetry first: the Azure Monitor distro patches the runtime, so it has to
  // be registered before anything it should observe starts. No connection
  // string => a clean no-op, and the reason is reported on /healthz.
  const telemetry = await initTelemetry();

  let backends: Backends;
  if (config.backendMode === "cloud") {
    // loadConfig has already validated every required setting, so a failure here
    // is a real environment problem (no managed identity, missing package) and
    // is worth dying on rather than serving five broken tools.
    backends = await createCloudBackends(config.cloud!);
  } else {
    backends = createLocalBackends();
    // Warm the lakehouse at boot so the first tool call doesn't pay CSV-load
    // latency. Failure is non-fatal here: the tool call surfaces the actionable
    // error, and the four non-SQL tools stay available.
    getLakehouseDb().catch((err) => {
      console.warn(`[mcp-tools] lakehouse warm-up failed: ${(err as Error).message}`);
    });
  }

  const app = createApp({ config, backends });

  app.listen(config.port, () => {
    console.log(
      `[mcp-tools] MCP server on :${config.port}${MCP_PATH} (streamable-http, stateless) — ` +
        `5 tools, backends=${config.backendMode}, ` +
        `sql=${backends.lakehouseSql.dialect}, ` +
        `otel=${telemetry.enabled ? telemetry.exporter : `off (${telemetry.reason})`}`,
    );
    // Printed on its own line so an unauthenticated cloud boot cannot be lost in
    // the middle of a longer status string.
    const posture = describeInboundAuth(config.inboundAuth);
    if (config.inboundAuth.deliberatelyOpen) console.warn(`[mcp-tools] ${posture}`);
    else console.log(`[mcp-tools] ${posture}`);
  });
}

main().catch((err) => {
  // Fail fast and loudly: a misconfigured cloud switchover must not present as
  // a healthy server that answers every question with an error.
  console.error(`[mcp-tools] failed to start: ${(err as Error).message}`);
  process.exit(1);
});
