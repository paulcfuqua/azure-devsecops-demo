import { defineConfig } from "tsup";

export default defineConfig({
  // Two entries, two independent bundles:
  //   index    -> the React/Fluent renderer (browser consumers)
  //   validate -> schema validation only, no UI in its import graph
  //               (server consumers, e.g. copilot-svc)
  entry: {
    index: "src/index.ts",
    validate: "src/validate-entry.ts",
  },
  format: ["esm", "cjs"],
  dts: true,
  sourcemap: true,
  clean: true,
  target: "es2021",
  // No shared chunks: dist/validate.js must be self-contained so nothing can
  // silently pull the renderer (and therefore React/Fluent) into a Node
  // process through a common chunk.
  splitting: false,
});
