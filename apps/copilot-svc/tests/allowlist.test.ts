/**
 * V8.2 — tool allowlist enforcement. Exactly five tools are registered; any
 * other tool call is rejected without execution and recorded in the trace.
 */
import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.js";
import { MockLlmDriver } from "../src/llm/mock.js";
import { FORBIDDEN_TOOL_QUESTION } from "../src/llm/plans.js";
import { runAsk } from "../src/loop.js";
import { createLocalBackends } from "../src/tools/backends.js";
import {
  ALLOWED_TOOL_NAMES,
  isAllowedTool,
  toolDefinitions,
  ToolRegistry,
} from "../src/tools/index.js";

const config = { ...loadConfig(), llmMode: "mock" as const };

describe("tool allowlist (V8.2)", () => {
  it("registers exactly the five master-plan tools with the model", () => {
    expect(toolDefinitions.map((t) => t.name).sort()).toEqual(
      [
        "get_cost_series",
        "get_defender_posture",
        "get_github_security",
        "query_lakehouse_sql",
        "query_log_analytics",
      ].sort(),
    );
    expect(toolDefinitions).toHaveLength(5);
    expect(ALLOWED_TOOL_NAMES).toHaveLength(5);
  });

  it("isAllowedTool rejects unknown names", () => {
    expect(isAllowedTool("query_lakehouse_sql")).toBe(true);
    expect(isAllowedTool("delete_everything")).toBe(false);
    expect(isAllowedTool("bash")).toBe(false);
    expect(isAllowedTool("")).toBe(false);
  });

  it("registry.execute throws for names off the allowlist", async () => {
    const registry = new ToolRegistry(createLocalBackends());
    await expect(registry.execute("run_shell", {})).rejects.toThrow(/allowlist/);
  });

  it("the loop rejects a disallowed tool call, never executes it, and still completes", async () => {
    const registry = new ToolRegistry(createLocalBackends());
    const result = await runAsk(FORBIDDEN_TOOL_QUESTION, {
      config,
      registry,
      driver: new MockLlmDriver(),
    });

    // The rejected call is in the trace, marked rejected, with zero execution time.
    const rejected = result.toolTrace?.filter((t) => t.rejected) ?? [];
    expect(rejected).toHaveLength(1);
    expect(rejected[0]?.name).toBe("delete_everything");
    expect(rejected[0]?.isError).toBe(true);
    expect(rejected[0]?.durationMs).toBe(0);

    // The allowed call in the same turn still executed for real.
    const executed = result.toolTrace?.filter((t) => !t.rejected) ?? [];
    expect(executed.map((t) => t.name)).toEqual(["query_lakehouse_sql"]);

    // And the loop still produced a valid spec (rejection is not fatal).
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(JSON.stringify(result.spec)).toContain("1200");
      expect(result.sql).toEqual(["SELECT COUNT(*) AS n FROM launches"]);
    }
  });
});
