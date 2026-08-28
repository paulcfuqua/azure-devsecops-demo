import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

// No LOCAL_DATA plugin here on purpose. Unlike control-tower and launch-ops,
// this app has no backend and no live data mode to switch between (see
// docs/superpowers/specs/2026-08-26-compliance-platform-design.md section
// 5.1): the catalog and every compliance/state/*.json snapshot are imported
// directly in src/main.tsx and end up as literal objects in the built
// bundle. Vite/Rollup resolve those imports via normal Node module
// resolution regardless of `root` -- no dev-server fs.allow configuration
// is needed for `vite build`, and the workspace-root auto-detection Vite
// performs when it finds this repo's root package.json `workspaces` field
// covers `vite dev`/`vite preview` too.
export default defineConfig({
  plugins: [react()],
  resolve: {
    // One React instance even if a stale nested install lingers somewhere.
    dedupe: ["react", "react-dom", "@fluentui/react-components"],
  },
  // Ports distinct from launch-ops (5173/4173) and control-tower (5174/4174).
  server: { port: 5175 },
  preview: { port: 4175 },
  build: {
    // Fluent UI is a single large vendor graph; raising the limit keeps the
    // build log signal-only. Size is addressed at CI, not here.
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
