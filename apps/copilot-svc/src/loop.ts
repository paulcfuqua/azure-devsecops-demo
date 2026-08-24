/**
 * The tool-use loop — the heart of L8.
 *
 * Contract enforced here:
 *  1. Only the 5 allowlisted tools ever execute; any other tool call is
 *     rejected with an is_error tool_result and recorded in the trace (V8.2).
 *  2. The model's final answer must parse as JSON and validate against the
 *     renderer schema BEFORE it is returned (V8.1 check b). On failure the
 *     model gets exactly ONE repair round with the validation errors; if the
 *     repaired answer is still invalid, a structured error is returned.
 *  3. Generated UI code is never returned — only the validated JSON spec.
 */
import type Anthropic from "@anthropic-ai/sdk";
import type { CopilotConfig } from "./config.js";
import type { LlmDriver } from "./llm/driver.js";
import { repairMessage, SYSTEM_PROMPT } from "./prompt.js";
import { isAllowedTool, type ToolRegistry } from "./tools/index.js";
import type { AskResult, ToolTraceEntry } from "./types.js";
import { tryParseSpecJson, validateSpec } from "./validation.js";

export interface LoopDeps {
  config: CopilotConfig;
  registry: ToolRegistry;
  driver: LlmDriver;
}

export async function runAsk(question: string, deps: LoopDeps): Promise<AskResult> {
  const { config, registry, driver } = deps;
  const messages: Anthropic.MessageParam[] = [{ role: "user", content: question }];
  const toolTrace: ToolTraceEntry[] = [];
  const sql: string[] = [];
  let repairUsed = false;

  // Bound the loop: maxToolRounds tool turns + the answer turn + one repair turn.
  const maxTurns = config.maxToolRounds + 2;
  for (let turn = 0; turn < maxTurns; turn++) {
    let response;
    try {
      response = await driver.complete({
        system: SYSTEM_PROMPT,
        messages,
        tools: registry.definitions,
      });
    } catch (err) {
      return {
        ok: false,
        error: "llm_error",
        message: `LLM request failed: ${err instanceof Error ? err.message : String(err)}`,
        sql,
        toolTrace,
      };
    }

    messages.push({ role: "assistant", content: response.content });

    if (response.stopReason === "tool_use") {
      const results: Anthropic.ToolResultBlockParam[] = [];
      for (const block of response.content) {
        if ((block as { type?: string }).type !== "tool_use") continue;
        const call = block as Anthropic.ToolUseBlockParam;

        if (!isAllowedTool(call.name)) {
          // V8.2: reject anything off the 5-tool allowlist. Never executed.
          toolTrace.push({
            name: call.name,
            input: call.input,
            rejected: true,
            isError: true,
            durationMs: 0,
          });
          results.push({
            type: "tool_result",
            tool_use_id: call.id,
            is_error: true,
            content: `Tool "${call.name}" is not on the allowlist and was not executed. Allowed tools: query_lakehouse_sql, query_log_analytics, get_github_security, get_defender_posture, get_cost_series.`,
          });
          continue;
        }

        const started = performance.now();
        try {
          const output = await registry.execute(call.name, call.input);
          const durationMs = Math.round(performance.now() - started);
          if (call.name === "query_lakehouse_sql") {
            sql.push(String((call.input as { sql?: unknown }).sql ?? ""));
          }
          toolTrace.push({
            name: call.name,
            input: call.input,
            rejected: false,
            isError: false,
            durationMs,
          });
          results.push({
            type: "tool_result",
            tool_use_id: call.id,
            content: JSON.stringify(output),
          });
        } catch (err) {
          const durationMs = Math.round(performance.now() - started);
          toolTrace.push({
            name: call.name,
            input: call.input,
            rejected: false,
            isError: true,
            durationMs,
          });
          results.push({
            type: "tool_result",
            tool_use_id: call.id,
            is_error: true,
            content: err instanceof Error ? err.message : String(err),
          });
        }
      }
      messages.push({ role: "user", content: results });
      continue;
    }

    // Final (non-tool) turn: parse -> validate -> return or repair.
    const text = response.content
      .filter((b): b is Anthropic.TextBlockParam => (b as { type?: string }).type === "text")
      .map((b) => b.text)
      .join("\n");

    const parsed = tryParseSpecJson(text);
    const validation = parsed.ok
      ? validateSpec(parsed.value)
      : {
          ok: false as const,
          errors: [{ path: "/", message: parsed.error, keyword: "parse" }],
        };

    if (parsed.ok && validation.ok) {
      return { ok: true, spec: parsed.value, sql, toolTrace };
    }

    if (!repairUsed) {
      repairUsed = true;
      messages.push({ role: "user", content: repairMessage(validation.errors) });
      continue;
    }

    return {
      ok: false,
      error: "invalid_spec",
      message:
        "The model did not produce a schema-valid component spec (one repair round attempted).",
      validationErrors: validation.errors,
      sql,
      toolTrace,
    };
  }

  return {
    ok: false,
    error: "llm_error",
    message: `Tool-round limit (${config.maxToolRounds}) exceeded without a final answer.`,
    sql,
    toolTrace,
  };
}
