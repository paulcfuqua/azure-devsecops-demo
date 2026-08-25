/** Service entry point: the serving layer both frontends already fetch from. */
import { createApp } from "./app.js";
import { createBackends } from "./backends/index.js";
import { loadConfig } from "./config.js";
import { FEED_NAMES, TABLE_NAMES } from "./contract/allowlist.js";
import { startTelemetry } from "./telemetry/otel.js";

const config = loadConfig();

// Telemetry first: the tracer provider must be registered before anything that
// might start a span, and its failure mode is "no spans", never "no service".
const telemetry = startTelemetry(config.telemetry);

const backends = createBackends(config);
const app = createApp({ config, backends, telemetry });

const server = app.listen(config.port, () => {
  console.log(
    `[data-api] listening on :${config.port} — backends=${backends.kind}, ` +
      `${TABLE_NAMES.length} tables, ${FEED_NAMES.length} feeds, ` +
      `rowCap=${config.maxRows}, cors=${
        config.allowedOrigins.length === 0
          ? "same-origin only"
          : config.allowedOrigins.join(" ")
      }, tracing=${telemetry.enabled ? "on" : "off"}`,
  );
});

/**
 * Container Apps sends SIGTERM on scale-in, and this app scales to zero
 * between demo clicks. Draining properly means the last spans are flushed and
 * the SQL pools are closed rather than reset by the platform.
 */
let shuttingDown = false;
async function shutdown(signal: string): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`[data-api] ${signal} received — draining.`);
  server.close();
  await backends.close().catch(() => undefined);
  await telemetry.shutdown();
  process.exit(0);
}

process.on("SIGTERM", () => void shutdown("SIGTERM"));
process.on("SIGINT", () => void shutdown("SIGINT"));
