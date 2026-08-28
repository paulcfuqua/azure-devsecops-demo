/**
 * Golden-question eval harness (`npm run eval`) — the L8 audit instrument for
 * the TOOL layer.
 *
 * It boots the real service in-process, connects the official MCP SDK client
 * over Streamable HTTP (exactly as the Copilot Studio agent will), and for each
 * of the ten golden questions issues the tool call that answers it, checking
 * the returned data against facts re-derived independently from the lakehouse.
 * A pass means: this answer is reachable through the MCP tool surface. Pass bar
 * 10/10 — there is no model in this loop and therefore no excuse.
 *
 * It also asserts the surface itself: tools/list returns exactly the allowlist
 * (audit V8.2), and every tool on it answers a smoke call. The expected set is
 * ALLOWED_TOOL_NAMES itself, never a hardcoded count -- a literal `5` here went
 * red the moment the compliance platform added a sixth tool (query_compliance,
 * 2026-08-26) and made this whole workflow fail for a reason that had nothing to
 * do with the tool surface being wrong.
 *
 * What it deliberately does NOT measure: whether the deployed Copilot Studio
 * agent picks the right tool and renders the right Adaptive Card. That is
 * `npm run eval:agent` (Direct Line), which runs at L8 against the tenant.
 *
 * Emits evals/eval-results.json — per question: pass/fail, the exact tool call,
 * expected and missing facts, the returned payload, latency. That is the
 * artifact CI uploads and the Verifier consumes as claims to re-derive.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { AddressInfo } from "node:net";
import type { Server as HttpServer } from "node:http";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { createApp, MCP_PATH } from "../src/app.js";
import { ALLOWED_TOOL_NAMES } from "../src/tools/index.js";
import {
  goldenQuestions,
  resultContains,
  scopePayload,
  type ExpectedFact,
} from "./questions.js";

const here = path.dirname(fileURLToPath(import.meta.url));

/** Smoke call per tool — proves all five are wired, not just the SQL one. */
const SURFACE_CALLS: Array<{ tool: string; arguments: Record<string, unknown> }> = [
  { tool: "query_lakehouse_sql", arguments: { sql: "SELECT COUNT(*) AS n FROM launches" } },
  { tool: "query_log_analytics", arguments: { query: "AppRequests | take 5", timespan: "P1D" } },
  { tool: "get_github_security", arguments: { alert_type: "all" } },
  { tool: "get_defender_posture", arguments: {} },
  { tool: "get_cost_series", arguments: { cost_center: "Propulsion" } },
  { tool: "query_compliance", arguments: { control: "3.1.1" } },
];

interface McpCallOutcome {
  isError: boolean;
  payload: unknown;
}

/** What client.callTool resolves to (a union including the legacy result shape). */
type McpToolResult = Awaited<ReturnType<Client["callTool"]>>;

function readPayload(result: McpToolResult): McpCallOutcome {
  const content = result.content as Array<{ type: string; text?: string }> | undefined;
  const text = content?.[0]?.text ?? "";
  if (result.isError === true) return { isError: true, payload: text };
  try {
    return { isError: false, payload: JSON.parse(text) };
  } catch {
    return { isError: true, payload: `tool result was not JSON: ${text.slice(0, 200)}` };
  }
}

async function startServer(): Promise<{ http: HttpServer; url: string }> {
  // inboundAuth became a required part of McpToolsConfig when the auth gate was made to
  // fail closed in every mode (finding F2). This harness runs an in-process server with
  // no ingress, so it declares the deliberately-open posture explicitly rather than
  // leaving the field off and relying on a default that no longer exists.
  const app = createApp({
    config: {
      port: 0,
      backendMode: "local",
      inboundAuth: { token: undefined, enforced: false, deliberatelyOpen: true },
    },
  });
  const http = app.listen(0);
  await new Promise<void>((resolve) => http.once("listening", () => resolve()));
  return { http, url: `http://127.0.0.1:${(http.address() as AddressInfo).port}${MCP_PATH}` };
}

async function main(): Promise<void> {
  const { http, url } = await startServer();
  const client = new Client({ name: "mls-golden-eval", version: "0.1.0" });
  await client.connect(new StreamableHTTPClientTransport(new URL(url)));

  console.log(
    `mcp-tools eval — MCP over Streamable HTTP at ${url}\n` +
      `${goldenQuestions.length} golden questions, pass bar ${goldenQuestions.length}/${goldenQuestions.length}\n`,
  );

  /* ---- the tool surface itself (audit V8.2) ---- */
  const listed = (await client.listTools()).tools.map((t) => t.name).sort();
  const surfaceErrors: string[] = [];
  const expected = [...(ALLOWED_TOOL_NAMES as readonly string[])].sort();
  // Set equality against the allowlist, in both directions: an extra tool is a
  // governance failure, and a MISSING one is a regression that a bare "no tool off
  // the allowlist" check would wave through.
  for (const name of listed) {
    if (!expected.includes(name)) {
      surfaceErrors.push(`tools/list advertises a tool off the allowlist: ${name}`);
    }
  }
  for (const name of expected) {
    if (!listed.includes(name)) {
      surfaceErrors.push(`tools/list is missing an allowlisted tool: ${name}`);
    }
  }
  // Every allowlisted tool must also get a smoke call, or a tool could be added and
  // silently never exercised here.
  for (const name of expected) {
    if (!SURFACE_CALLS.some((c) => c.tool === name)) {
      surfaceErrors.push(`no surface smoke call is defined for allowlisted tool: ${name}`);
    }
  }
  const surface = [];
  for (const call of SURFACE_CALLS) {
    const started = performance.now();
    const outcome = readPayload(
      await client.callTool({ name: call.tool, arguments: call.arguments }),
    );
    const ms = performance.now() - started;
    if (outcome.isError) surfaceErrors.push(`${call.tool}: ${String(outcome.payload)}`);
    surface.push({
      tool: call.tool,
      arguments: call.arguments,
      ok: !outcome.isError,
      latencySeconds: Number((ms / 1000).toFixed(3)),
    });
    console.log(
      `${outcome.isError ? "FAIL" : "OK  "}  surface ${call.tool.padEnd(21)} ${(ms / 1000).toFixed(2)}s`,
    );
  }
  console.log("");

  /* ---- the ten golden questions ---- */
  const results = [];
  let passed = 0;

  for (const q of goldenQuestions) {
    const expected: ExpectedFact[] = await q.expected();
    const started = performance.now();
    const outcome = readPayload(
      await client.callTool({ name: q.call.tool, arguments: q.call.arguments }),
    );
    const latencySeconds = (performance.now() - started) / 1000;

    const scoped = outcome.isError ? outcome.payload : scopePayload(outcome.payload, q.factScope);
    const missing = outcome.isError
      ? expected
      : expected.filter((fact) => !resultContains(scoped, fact));
    const pass = !outcome.isError && missing.length === 0;
    if (pass) passed += 1;

    console.log(
      `${pass ? "PASS" : "FAIL"}  ${q.id.padEnd(18)} ${latencySeconds.toFixed(2)}s  ` +
        (pass
          ? `facts: ${expected.map((f) => f.value).join(", ")} (via ${q.call.tool}, ${q.factScope})`
          : outcome.isError
            ? `tool error: ${String(outcome.payload).slice(0, 160)}`
            : `missing facts: ${missing.map((f) => f.value).join(", ")}`),
    );

    results.push({
      id: q.id,
      question: q.question,
      pass,
      latencySeconds: Number(latencySeconds.toFixed(3)),
      toolCall: { name: q.call.tool, arguments: q.call.arguments },
      factScope: q.factScope,
      expectedFacts: expected,
      missingFacts: missing.map((f) => f.value),
      result: outcome.isError ? null : outcome.payload,
      error: outcome.isError ? String(outcome.payload) : null,
    });
  }

  const artifact = {
    mode: "tools",
    transport: "streamable-http",
    ranAt: new Date().toISOString(),
    passed,
    total: goldenQuestions.length,
    passBar: goldenQuestions.length,
    toolsListed: listed,
    surfaceErrors,
    toolSurface: surface,
    questions: results,
  };
  const outPath = path.join(here, "eval-results.json");
  fs.writeFileSync(outPath, JSON.stringify(artifact, null, 2));

  console.log(
    `\n${passed}/${goldenQuestions.length} passed (bar: ${goldenQuestions.length}). ` +
      `Tools advertised: ${listed.length}. Artifact: ${outPath}`,
  );
  if (surfaceErrors.length > 0) {
    console.error(`TOOL SURFACE ERRORS (V8.2): ${surfaceErrors.join("; ")}`);
  }

  await client.close();
  await new Promise<void>((resolve) => http.close(() => resolve()));

  if (passed < goldenQuestions.length || surfaceErrors.length > 0) {
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
