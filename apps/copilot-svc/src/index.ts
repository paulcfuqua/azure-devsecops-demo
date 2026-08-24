/** Service entry point. */
import { createApp } from "./app.js";
import { loadConfig } from "./config.js";
import { getLakehouseDb } from "./data/lakehouse.js";

const config = loadConfig();
const app = createApp({ config });

// Warm the lakehouse at boot so the first /ask doesn't pay CSV-load latency.
// Failure is non-fatal here: the tool call surfaces the actionable error.
getLakehouseDb().catch((err) => {
  console.warn(`[copilot-svc] lakehouse warm-up failed: ${(err as Error).message}`);
});

app.listen(config.port, () => {
  console.log(
    `[copilot-svc] listening on :${config.port} (llm=${config.llmMode}, model=${config.model})`,
  );
});
