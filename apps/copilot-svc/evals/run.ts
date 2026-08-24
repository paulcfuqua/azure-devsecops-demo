/**
 * Golden-question eval harness (`npm run eval`).
 *
 * Modes:
 *   npm run eval        -> MOCK mode (deterministic, no API key, CI path).
 *                          Pass bar: 10/10 — the mock pipeline has no excuse.
 *   npm run eval:live   -> LIVE mode (requires ANTHROPIC_API_KEY). This is the
 *                          L8 audit instrument; pass bar >= 9/10 per the
 *                          master plan (V8.1).
 *
 * Emits evals/eval-results.json: per question — answer facts, spec, SQL
 * executed, latency, tool-call trace (the artifact shape L8's workflow
 * uploads and the Verifier consumes).
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadConfig } from "../src/config.js";
import { MockLlmDriver } from "../src/llm/mock.js";
import { LiveLlmDriver } from "../src/llm/live.js";
import { runAsk } from "../src/loop.js";
import { createLocalBackends } from "../src/tools/backends.js";
import { ALLOWED_TOOL_NAMES, ToolRegistry } from "../src/tools/index.js";
import { goldenQuestions, specContains } from "./questions.js";

const here = path.dirname(fileURLToPath(import.meta.url));

async function main(): Promise<void> {
  const wantLive = process.argv.includes("--live");
  if (wantLive && !process.env.ANTHROPIC_API_KEY) {
    console.error(
      "eval:live requires ANTHROPIC_API_KEY in the environment. " +
        "Run `npm run eval` for the mock-mode suite (no key needed).",
    );
    process.exit(1);
  }
  const mode: "mock" | "live" = wantLive ? "live" : "mock";
  const config = { ...loadConfig(), llmMode: mode };
  const registry = new ToolRegistry(createLocalBackends());
  const passBar = mode === "live" ? 9 : goldenQuestions.length;

  console.log(
    `copilot-svc eval — mode=${mode}${mode === "live" ? ` model=${config.model}` : ""}, ` +
      `${goldenQuestions.length} golden questions, pass bar ${passBar}/${goldenQuestions.length}\n`,
  );

  const results = [];
  let passed = 0;
  const allowlistViolations: string[] = [];

  for (const q of goldenQuestions) {
    const expected = await q.expected();
    const driver = mode === "live" ? new LiveLlmDriver(config) : new MockLlmDriver();
    const started = performance.now();
    const result = await runAsk(q.question, { config, registry, driver });
    const latencySeconds = (performance.now() - started) / 1000;

    for (const t of result.toolTrace ?? []) {
      if (!(ALLOWED_TOOL_NAMES as readonly string[]).includes(t.name)) {
        allowlistViolations.push(`${q.id}: ${t.name}`);
      }
    }

    const missing = result.ok
      ? expected.filter((fact) => !specContains(result.spec, fact))
      : expected;
    const pass = result.ok && missing.length === 0;
    if (pass) passed += 1;

    console.log(
      `${pass ? "PASS" : "FAIL"}  ${q.id.padEnd(18)} ${latencySeconds.toFixed(2)}s  ` +
        (pass
          ? `facts: ${expected.map((f) => f.value).join(", ")}`
          : result.ok
            ? `missing facts: ${missing.map((f) => f.value).join(", ")}`
            : `error: ${result.error} — ${result.message}`),
    );

    results.push({
      id: q.id,
      question: q.question,
      pass,
      latencySeconds: Number(latencySeconds.toFixed(3)),
      expectedFacts: expected,
      missingFacts: missing.map((f) => f.value),
      spec: result.ok ? result.spec : null,
      error: result.ok ? null : { error: result.error, message: result.message },
      sql: result.sql ?? [],
      toolCalls: (result.toolTrace ?? []).map((t) => ({
        name: t.name,
        input: t.input,
        rejected: t.rejected,
        isError: t.isError,
        durationMs: t.durationMs,
      })),
    });
  }

  const artifact = {
    mode,
    model: mode === "live" ? config.model : "mock",
    ranAt: new Date().toISOString(),
    passed,
    total: goldenQuestions.length,
    passBar,
    allowlistViolations,
    questions: results,
  };
  const outPath = path.join(here, "eval-results.json");
  fs.writeFileSync(outPath, JSON.stringify(artifact, null, 2));

  console.log(`\n${passed}/${goldenQuestions.length} passed (bar: ${passBar}). Artifact: ${outPath}`);
  if (allowlistViolations.length > 0) {
    console.error(`ALLOWLIST VIOLATIONS (V8.2): ${allowlistViolations.join("; ")}`);
  }
  if (passed < passBar || allowlistViolations.length > 0) {
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
