import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { createAgentProvider } from "./agent";
import { App } from "./App";
import { createDataProvider } from "./providers";
import { initBrowserTelemetry } from "./telemetry/browser";

const root = document.getElementById("root");
if (!root) throw new Error("Missing #root element");

// Fire and forget, and deliberately before the first render so a page view is
// recorded even if rendering throws. No-ops when no connection string is
// configured; never rejects (see telemetry/browser.ts).
void initBrowserTelemetry({ cloudRole: "control-tower", env: import.meta.env });

createRoot(root).render(
  <StrictMode>
    <App provider={createDataProvider()} agent={createAgentProvider()} />
  </StrictMode>,
);
