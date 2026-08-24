import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    projects: [
      {
        test: {
          // Renderer + schema tests that need a DOM.
          name: "renderer",
          environment: "jsdom",
          setupFiles: ["./tests/setup.ts"],
          include: ["tests/**/*.test.{ts,tsx}"],
          exclude: ["tests/node/**"],
          server: {
            deps: {
              // Fluent UI v9 pulls in CJS deps (tabster, keyborg) whose named
              // exports Node's ESM loader cannot see; let Vite transform them.
              inline: [/@fluentui\//, "tabster", "keyborg"],
            },
          },
        },
      },
      {
        test: {
          // Deliberately NO jsdom and NO DOM setup file: these tests prove the
          // `@mls/spec-renderer/validate` subpath works in a plain Node
          // process (the copilot-svc case). Adding jsdom here would defeat
          // their purpose.
          name: "node",
          environment: "node",
          setupFiles: [],
          include: ["tests/node/**/*.test.ts"],
        },
      },
    ],
  },
});
