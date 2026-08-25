import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { createAgentProvider } from "./agent";
import { App } from "./App";
import { createDataProvider } from "./providers";

const root = document.getElementById("root");
if (!root) throw new Error("Missing #root element");

createRoot(root).render(
  <StrictMode>
    <App provider={createDataProvider()} agent={createAgentProvider()} />
  </StrictMode>,
);
