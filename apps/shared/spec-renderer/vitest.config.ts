import { defineConfig } from "vitest/config";

export default defineConfig({
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
