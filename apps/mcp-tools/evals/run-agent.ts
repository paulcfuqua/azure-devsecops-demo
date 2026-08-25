/**
 * Agent eval harness (`npm run eval:agent`) — PLACEHOLDER, wired at L8.
 *
 * WHAT IT WILL DO. `npm run eval` proves the ten golden answers are reachable
 * through the MCP tools. This script proves the other half: that the deployed
 * **Copilot Studio agent** — the thing that actually orchestrates — picks the
 * right tool and answers correctly. It drives the agent end to end over the
 * Direct Line channel, the same channel the control-tower app embeds:
 *
 *   1. POST https://directline.botframework.com/v3/directline/conversations
 *      with `Authorization: Bearer <Direct Line secret>` to open a conversation
 *      and exchange the secret for a short-lived token.
 *   2. For each golden question, POST an activity
 *      {type: "message", from: {id: "mls-eval"}, text: <question>} to
 *      /v3/directline/conversations/{id}/activities.
 *   3. Poll GET .../activities?watermark=<w> until the agent's reply arrives
 *      (its Adaptive Card attachment plus any text).
 *   4. Fact-check the reply with the SAME independently derived expectations
 *      and the same `resultContains` used by `npm run eval` — an Adaptive Card
 *      is JSON, so the fact walker works on it unchanged.
 *   5. Write evals/agent-eval-results.json and exit non-zero below the L8 pass
 *      bar (>= 9/10 per master plan V8.1).
 *
 * WHY IT IS NOT IMPLEMENTED YET. Copilot Studio is cloud-only. There is no
 * agent, no Power Platform environment and no Direct Line channel until G0
 * bootstrap and L8 (amendment 2026-08-24, §3 "Lost capability"). Authoring a
 * client against an endpoint that cannot exist yet would be untested code
 * pretending to be tested code.
 *
 * CONTRACT UNTIL THEN. No secret configured -> refuse with an explanation and
 * exit 0 (this is the expected pre-L8 state; it must not redden a pipeline).
 * Pass --require-configured to make that refusal a failure instead, which is
 * what L8's own workflow will do once the channel exists. Either way this
 * script makes NO network call.
 */
import { goldenQuestions } from "./questions.js";

const SECRET_VARS = ["DIRECTLINE_SECRET", "MLS_DIRECTLINE_SECRET"] as const;

function findSecret(env: NodeJS.ProcessEnv): { name: string; value: string } | undefined {
  for (const name of SECRET_VARS) {
    const value = env[name];
    if (typeof value === "string" && value.trim().length > 0) return { name, value };
  }
  return undefined;
}

function main(): void {
  const requireConfigured = process.argv.includes("--require-configured");
  const secret = findSecret(process.env);

  console.log(
    `mcp-tools eval:agent — Copilot Studio agent over Direct Line, ` +
      `${goldenQuestions.length} golden questions, L8 pass bar 9/${goldenQuestions.length}\n`,
  );

  if (!secret) {
    console.log(
      "SKIPPED — no Direct Line secret configured.\n" +
        `\nSet ${SECRET_VARS[0]} (or ${SECRET_VARS[1]}) to the Direct Line channel secret of the\n` +
        "deployed Copilot Studio agent to run this suite. Until L8 that channel does not\n" +
        "exist yet: Copilot Studio is cloud-only and needs the tenant, a Power Platform\n" +
        "environment and the published agent (amendment 2026-08-24).\n" +
        "\nNo network call was made. The tool layer's own suite is `npm run eval`, which\n" +
        "runs offline and is the gate CI enforces today.",
    );
    process.exit(requireConfigured ? 1 : 0);
  }

  console.error(
    `Direct Line secret found in ${secret.name}, but the Direct Line driver is not\n` +
      "implemented yet — it lands at L8 with the deployed agent (see this file's header\n" +
      "for the exact protocol it will speak). Refusing rather than pretending to test.\n" +
      "\nNo network call was made.",
  );
  process.exit(1);
}

main();
