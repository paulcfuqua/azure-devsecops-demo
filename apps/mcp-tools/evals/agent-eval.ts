/**
 * Agent eval harness — the L8 audit instrument for the AGENT layer.
 *
 * `npm run eval` proves the ten golden answers are reachable through the MCP
 * tools. This proves the other half: that the deployed **Copilot Studio agent**
 * — the thing that actually orchestrates — picks the right tool and answers
 * correctly. It drives the agent end to end over Direct Line, the same channel
 * the control-tower app embeds, and fact-checks its Adaptive Cards with the SAME
 * independently-derived expectations and the same `resultContains` walker
 * `npm run eval` uses. An Adaptive Card is JSON, so the walker works on it
 * unchanged — that was the design intent recorded when this file was a stub, and
 * it holds.
 *
 * ── The contract when there is no tenant ────────────────────────────────────
 * No Direct Line secret configured -> print why, make **no network call**, and
 * exit 0. That is the expected pre-L8 state and it must not redden a pipeline.
 * `--require-configured` turns the same refusal into exit 1, which is what L8's
 * own workflow passes once the channel exists. The unconfigured path is proven
 * by a unit test that injects a `fetch` which throws if it is ever called.
 *
 * ── Pass bar ────────────────────────────────────────────────────────────────
 * >= 9/10 (master plan V8.2). Lower than the tool suite's 10/10 on purpose:
 * there is a model in this loop. A warm-up question runs first and is discarded
 * — V8.5 measures p95 with the conversation already open and the MCP replica
 * warm, and the first turn of a scale-to-zero container is neither.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  DirectLineClient,
  type AgentReply,
  type FetchLike,
} from "./directline.js";
import {
  goldenQuestions,
  resultContains,
  scopePayload,
  type ExpectedFact,
} from "./questions.js";

const here = path.dirname(fileURLToPath(import.meta.url));

/** Env vars searched, in order, for the Direct Line channel secret. */
export const SECRET_VARS = ["DIRECTLINE_SECRET", "MLS_DIRECTLINE_SECRET"] as const;

/** Master plan V8.2: the deployed agent must clear 9 of the 10 golden questions. */
export const AGENT_PASS_BAR = 9;

/**
 * A cheap, non-golden question asked and discarded before the timed set, so the
 * first turn's cold start does not land in the p95 sample (V8.5).
 */
export const WARM_UP_QUESTION = "Hello — are your tools available?";

/**
 * Copilot Studio service errors that mean **the agent was never asked**, as
 * opposed to asking and getting it wrong.
 *
 * These arrive as a normal agent *reply* whose text is an error banner, not as a
 * thrown transport error — so without this the harness scores them as ordinary
 * wrong answers. Measured 2026-09-03: the agent answered the first four golden
 * questions correctly from the lakehouse, then the tool planner rate-limited and
 * the remaining six returned `GenAIToolPlannerRateLimitReached` seconds apart.
 * The artifact recorded `4/10` with `missingFacts: ['LC-39A']` and friends,
 * which reads as an agent that does not know its own data. It knew; it was never
 * asked.
 *
 * A grade of zero from a caller that was refused is the error this repository has
 * now recorded in four subsystems (F102, F103, F105, F183). Not scoring it is the
 * whole point: UNOBSERVABLE, never a fail.
 */
export const SERVICE_ERROR_PATTERNS = [
  /RateLimitReached/i,
  /GenAIToolPlanner\w*Error/i,
  /\bthrottl/i,
  /service is unavailable/i,
] as const;

/** True when a reply is the service refusing, rather than the agent answering. */
export function isServiceError(text: readonly string[] | undefined): boolean {
  if (!text || text.length === 0) return false;
  return text.some((t) => SERVICE_ERROR_PATTERNS.some((p) => p.test(t)));
}

/**
 * Pause between golden questions, so ten back-to-back turns do not trip the tool
 * planner's quota in the first place.
 *
 * DECLARED, not inherited (CLAUDE.md: a check declares how long it is willing to
 * wait, and why). Ten questions at this spacing add ~20s to a run that already
 * takes minutes, and it is the difference between measuring the agent and
 * measuring the quota.
 */
export const INTER_QUESTION_DELAY_MS = 2_000;

/**
 * How many times a throttled question is retried before it is called
 * UNOBSERVABLE, and how long the backoff waits. Retrying converts "could not
 * observe" into an observation where the limit is momentary; the cap stops it
 * spending a run's budget insisting.
 */
export const THROTTLE_RETRIES = 2;
export const THROTTLE_BACKOFF_MS = 15_000;

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

export interface AgentEvalOptions {
  argv?: string[];
  env?: NodeJS.ProcessEnv;
  /** Injected by tests. Production uses global fetch via DirectLineClient. */
  fetchImpl?: FetchLike;
  /** Injected by tests to keep polling instant. */
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
  /** Where the artifact is written; defaults to evals/agent-eval-results.json. */
  outPath?: string;
  /** Injected by tests so assertions do not depend on console output. */
  log?: (message: string) => void;
  logError?: (message: string) => void;
  baseUrl?: string;
  pollIntervalMs?: number;
  settleMs?: number;
  timeoutMs?: number;
}

export function findSecret(
  env: NodeJS.ProcessEnv,
): { name: string; value: string } | undefined {
  for (const name of SECRET_VARS) {
    const value = env[name];
    if (typeof value === "string" && value.trim().length > 0) return { name, value: value.trim() };
  }
  return undefined;
}

/**
 * The fact-checkable payload of one agent turn.
 *
 * Text and cards together: a golden fact may land in the card's body, in the
 * sentence beside it, or in both, and the question is whether the agent
 * *answered*, not where it put the number. Ranking questions still narrow to
 * row 0 via `scopePayload` when the payload happens to carry a `rows` array;
 * a card has no `rows`, so it is checked whole — which is exactly what
 * questions.ts documents.
 */
export function replyPayload(reply: AgentReply): unknown {
  return { text: reply.text, cards: reply.cards };
}

/** The unconfigured-refusal text. Exported so the test asserts the real string. */
export function unconfiguredMessage(): string {
  return (
    "SKIPPED — no Direct Line secret configured.\n" +
    `\nSet ${SECRET_VARS[0]} (or ${SECRET_VARS[1]}) to the Direct Line channel secret of the\n` +
    "deployed Copilot Studio agent to run this suite. Until L8 that channel does not\n" +
    "exist yet: Copilot Studio is cloud-only and needs the tenant, a Power Platform\n" +
    "environment and the published agent (amendment 2026-08-24).\n" +
    "\nNo network call was made. The tool layer's own suite is `npm run eval`, which\n" +
    "runs offline and is the gate CI enforces today."
  );
}

/**
 * Run the suite. Returns the process exit code so the CLI wrapper is a one-liner
 * and the whole thing stays unit-testable without spawning a process.
 */
export async function runAgentEval(options: AgentEvalOptions = {}): Promise<number> {
  const argv = options.argv ?? process.argv.slice(2);
  const env = options.env ?? process.env;
  const log = options.log ?? ((m: string) => console.log(m));
  const logError = options.logError ?? ((m: string) => console.error(m));
  const requireConfigured = argv.includes("--require-configured");

  log(
    `mcp-tools eval:agent — Copilot Studio agent over Direct Line, ` +
      `${goldenQuestions.length} golden questions, L8 pass bar ` +
      `${AGENT_PASS_BAR}/${goldenQuestions.length}\n`,
  );

  const secret = findSecret(env);
  if (!secret) {
    // NOTHING above this point touched the network, and nothing below it runs.
    log(unconfiguredMessage());
    return requireConfigured ? 1 : 0;
  }

  const client = new DirectLineClient({
    secret: secret.value,
    ...(options.fetchImpl ? { fetchImpl: options.fetchImpl } : {}),
    ...(options.baseUrl ? { baseUrl: options.baseUrl } : {}),
    ...(options.sleep ? { sleep: options.sleep } : {}),
    ...(options.now ? { now: options.now } : {}),
    ...(options.pollIntervalMs === undefined ? {} : { pollIntervalMs: options.pollIntervalMs }),
    ...(options.settleMs === undefined ? {} : { settleMs: options.settleMs }),
    ...(options.timeoutMs === undefined ? {} : { timeoutMs: options.timeoutMs }),
  });

  let conversationId: string;
  try {
    conversationId = await client.openConversation();
  } catch (err) {
    logError(
      `Direct Line conversation could not be opened: ${err instanceof Error ? err.message : String(err)}`,
    );
    return 1;
  }
  log(`Direct Line conversation ${conversationId} open (secret from ${secret.name}).\n`);

  // Warm-up, discarded: excluded from pass/fail AND from the latency sample.
  try {
    await client.ask(WARM_UP_QUESTION);
    log("OK    warm-up (discarded)\n");
  } catch (err) {
    log(`WARN  warm-up failed, continuing: ${err instanceof Error ? err.message : String(err)}\n`);
  }

  const results = [];
  let passed = 0;
  let unobservable = 0;
  let first = true;
  // Injectable so the unit suite does not actually wait out the pacing and the
  // throttle backoff — the same channel the Direct Line poller already uses.
  const pause = options.sleep ?? sleep;

  for (const question of goldenQuestions) {
    // Expectations are re-derived from the lakehouse with independent SQL, the
    // same way the tool suite does it — the agent is never compared to itself.
    const expected: ExpectedFact[] = await question.expected();

    // Spacing, not politeness: ten back-to-back turns trip the tool planner quota.
    if (!first) await pause(INTER_QUESTION_DELAY_MS);
    first = false;

    let reply: AgentReply | undefined;
    let error: string | undefined;
    let throttled = false;

    for (let attempt = 0; attempt <= THROTTLE_RETRIES; attempt += 1) {
      reply = undefined;
      error = undefined;
      try {
        reply = await client.ask(question.question);
      } catch (err) {
        error = err instanceof Error ? err.message : String(err);
      }
      throttled = error === undefined && isServiceError(reply?.text);
      if (!throttled) break;
      if (attempt < THROTTLE_RETRIES) {
        log(
          `WAIT  ${question.id.padEnd(18)} service throttled the tool planner; ` +
            `retrying in ${(THROTTLE_BACKOFF_MS / 1000).toFixed(0)}s ` +
            `(attempt ${attempt + 2}/${THROTTLE_RETRIES + 1})`,
        );
        await pause(THROTTLE_BACKOFF_MS);
      }
    }

    const payload = reply ? replyPayload(reply) : undefined;
    const scoped = payload === undefined ? undefined : scopePayload(payload, question.factScope);
    const missing =
      scoped === undefined ? expected : expected.filter((fact) => !resultContains(scoped, fact));
    // UNOBSERVABLE IS NOT A FAIL. The agent was never asked, so it cannot be
    // graded — scoring it would report a service quota as ignorance (F186).
    const pass = !throttled && error === undefined && reply?.timedOut !== true && missing.length === 0;
    if (pass) passed += 1;
    if (throttled) unobservable += 1;

    const latencySeconds = reply?.latencySeconds ?? 0;
    log(
      `${pass ? "PASS " : throttled ? "UNOBS" : "FAIL "} ${question.id.padEnd(18)} ${latencySeconds.toFixed(2)}s  ` +
        (pass
          ? `facts: ${expected.map((f) => f.value).join(", ")} (${reply?.cards.length ?? 0} card(s))`
          : throttled
            ? `service refused to plan a tool call, so the agent was never asked: ${(reply?.text ?? []).join(" ").slice(0, 120)}`
            : error
              ? `direct line error: ${error.slice(0, 160)}`
              : reply?.timedOut
                ? "no agent reply before the timeout"
                : `missing facts: ${missing.map((f) => f.value).join(", ")}`),
    );

    results.push({
      id: question.id,
      question: question.question,
      pass,
      // Distinguishes "asked and wrong" from "never asked" (F186). A consumer
      // that treats unobservable as a failure re-introduces the defect.
      unobservable: throttled,
      latencySeconds,
      factScope: question.factScope,
      expectedFacts: expected,
      missingFacts: missing.map((f) => f.value),
      // V8.3's runtime half consumes this; V8.4 validates the cards.
      toolCalls: reply?.toolCalls ?? [],
      cards: reply?.cards ?? [],
      responses: reply?.text ?? [],
      error: error ?? null,
    });
  }

  const latencies = results.map((r) => r.latencySeconds).sort((a, b) => a - b);
  const p95 =
    latencies.length === 0
      ? 0
      : (latencies[Math.ceil(0.95 * latencies.length) - 1] ?? latencies[latencies.length - 1] ?? 0);

  const artifact = {
    mode: "agent",
    transport: "directline",
    // L8 records which path answered so the Verifier's evidence is unambiguous.
    path: env.MLS_AGENT_PATH ?? "unspecified",
    ranAt: new Date().toISOString(),
    conversationId,
    passed,
    unobservable,
    total: goldenQuestions.length,
    passBar: AGENT_PASS_BAR,
    p95LatencySeconds: Number(p95.toFixed(3)),
    questions: results,
  };
  const outPath = options.outPath ?? path.join(here, "agent-eval-results.json");
  fs.writeFileSync(outPath, JSON.stringify(artifact, null, 2));

  log(
    `\n${passed}/${goldenQuestions.length} passed (bar: ${AGENT_PASS_BAR})` +
      (unobservable > 0 ? `, ${unobservable} UNOBSERVABLE (service throttled)` : "") +
      `. p95 ${p95.toFixed(2)}s (V8.5 budget 20s). Artifact: ${outPath}`,
  );
  if (unobservable > 0) {
    log(
      `\n${unobservable} question(s) could not be asked, so this run has NO VERDICT on them. ` +
        `That is not the agent failing — it is the service declining to plan a tool call. ` +
        `Re-run when the quota recovers; do not read the score as an agent grade.`,
    );
  }

  // Unobservable questions cannot count toward the bar, and must not be silently
  // tolerated either: a run that could not ask every question has not cleared it.
  return unobservable === 0 && passed >= AGENT_PASS_BAR ? 0 : 1;
}
