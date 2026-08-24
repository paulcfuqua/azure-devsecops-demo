import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import react from "@vitejs/plugin-react";
import type { Connect, Plugin } from "vite";
import { defineConfig } from "vitest/config";

const appDir = path.dirname(fileURLToPath(import.meta.url));
const generatedDir = path.resolve(appDir, "../../data/generated");

// Honour the runbooks' `LOCAL_DATA=1` convention. Vite only injects env vars
// that carry the VITE_ prefix into `import.meta.env`, so mirror it onto the
// prefixed name before the config is consumed. (A `define` would not work here:
// it rewrites literal `import.meta.env.VITE_LOCAL_DATA` occurrences, and
// resolveDataMode reads the key off the env object dynamically.)
process.env.VITE_LOCAL_DATA =
  process.env.LOCAL_DATA ?? process.env.VITE_LOCAL_DATA ?? "";

/**
 * LOCAL_DATA mode support: serves the generator output under /local-data/*.json
 * so the LocalJsonProvider can fetch it in `vite dev` and `vite preview`.
 * The files are gitignored build artifacts — if one is missing the middleware
 * answers 404 with the command that produces them.
 */
function localDataPlugin(): Plugin {
  const handler: Connect.NextHandleFunction = (req, res, next) => {
    const match = /^\/([a-z0-9_]+\.json)(?:\?.*)?$/.exec(req.url ?? "");
    const name = match?.[1];
    if (!name || req.method !== "GET") {
      next();
      return;
    }
    const file = path.join(generatedDir, name);
    if (!existsSync(file)) {
      res.statusCode = 404;
      res.setHeader("content-type", "application/json");
      res.end(
        JSON.stringify({
          error: `${name} not found in data/generated/`,
          hint: "Generate the synthetic data first: run `python -m generators build` from the data/ directory.",
        }),
      );
      return;
    }
    res.statusCode = 200;
    res.setHeader("content-type", "application/json");
    res.end(readFileSync(file));
  };
  return {
    name: "mls-local-data",
    configureServer(server) {
      server.middlewares.use("/local-data", handler);
    },
    configurePreviewServer(server) {
      server.middlewares.use("/local-data", handler);
    },
  };
}

export default defineConfig({
  plugins: [react(), localDataPlugin()],
  resolve: {
    // One React instance even if a stale nested install lingers somewhere.
    dedupe: ["react", "react-dom", "@fluentui/react-components"],
  },
  server: { port: 5173 },
  preview: { port: 4173 },
  build: {
    // Fluent UI + charting is a single large vendor graph; raising the limit
    // keeps the build log signal-only. Size is addressed at L7 CI, not here.
    chunkSizeWarningLimit: 2000,
  },
  test: {
    environment: "jsdom",
    setupFiles: ["./tests/setup.ts"],
    include: ["tests/**/*.test.{ts,tsx}"],
    server: {
      deps: {
        // Fluent UI v9 pulls in CJS deps (tabster, keyborg) whose named
        // exports Node's ESM loader cannot see; let Vite transform them.
        inline: [/@fluentui\//, "tabster", "keyborg"],
      },
    },
  },
});
