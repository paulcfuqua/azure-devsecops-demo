/**
 * `npm run eval:agent` — CLI wrapper.
 *
 * The harness itself is in ./agent-eval.ts, imported here rather than written
 * here so it can be unit-tested without spawning a process: the unconfigured
 * path is asserted by injecting a `fetch` that throws, which proves "no network
 * call" as a fact rather than as a claim in a comment.
 *
 *   npm run eval:agent                        # no secret -> explain, exit 0
 *   npm run eval:agent -- --require-configured # no secret -> explain, exit 1
 *
 * With DIRECTLINE_SECRET (or MLS_DIRECTLINE_SECRET) set it opens one Direct Line
 * conversation against the deployed Copilot Studio agent, asks a discarded
 * warm-up question, then the ten golden questions, fact-checks the Adaptive
 * Cards against independently re-derived expectations, writes
 * evals/agent-eval-results.json and exits non-zero below 9/10.
 */
import { runAgentEval } from "./agent-eval.js";

runAgentEval()
  .then((code) => process.exit(code))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
