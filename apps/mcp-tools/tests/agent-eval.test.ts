/**
 * `npm run eval:agent` — the Direct Line driver and its unconfigured contract.
 *
 * Two things under test:
 *
 *   1. **The unconfigured path makes no network call.** This is asserted by
 *      injecting a `fetch` that throws if it is called at all, rather than by
 *      trusting a comment. It is the property CI depends on today: there is no
 *      tenant, no Power Platform environment and no published agent, and this
 *      script must not redden a pipeline for saying so.
 *   2. **The protocol.** Conversation open, activity POST, watermark polling
 *      across pages, the settle window, and Adaptive Card fact-checking with the
 *      same `resultContains` assertions `npm run eval` uses.
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import {
  AGENT_PASS_BAR,
  findSecret,
  replyPayload,
  runAgentEval,
  SECRET_VARS,
  WARM_UP_QUESTION,
} from "../evals/agent-eval.js";
import {
  ADAPTIVE_CARD_CONTENT_TYPE,
  DirectLineClient,
  DirectLineError,
  extractToolCalls,
} from "../evals/directline.js";
import { goldenQuestions, resultContains, scopePayload } from "../evals/questions.js";
import { MockFetch, forbiddenFetch, noSleep } from "./helpers/mock-fetch.js";
import { rejection } from "./helpers/rejection.js";

const SECRET = "a-fake-direct-line-secret";
const CONVERSATION = "conv-abc123";

function tempArtifact(): string {
  return path.join(
    fs.mkdtempSync(path.join(os.tmpdir(), "mls-agent-eval-")),
    "agent-eval-results.json",
  );
}

/* ------------------------------------------------------------------ */
/* The unconfigured contract                                           */
/* ------------------------------------------------------------------ */

describe("no Direct Line secret configured", () => {
  it("exits 0 and makes NO network call", async () => {
    const messages: string[] = [];
    const code = await runAgentEval({
      argv: [],
      env: {} as NodeJS.ProcessEnv,
      // Throws on any call. If the harness touches the network, this test fails.
      fetchImpl: forbiddenFetch("eval:agent"),
      log: (m) => messages.push(m),
      logError: (m) => messages.push(m),
    });
    expect(code).toBe(0);
    expect(messages.join("\n")).toContain("SKIPPED — no Direct Line secret configured");
    expect(messages.join("\n")).toContain("No network call was made");
  });

  it("--require-configured turns the same refusal into exit 1", async () => {
    const code = await runAgentEval({
      argv: ["--require-configured"],
      env: {} as NodeJS.ProcessEnv,
      fetchImpl: forbiddenFetch("eval:agent"),
      log: () => {},
      logError: () => {},
    });
    expect(code).toBe(1);
  });

  it("explains that Copilot Studio is cloud-only, so the state is expected", async () => {
    const messages: string[] = [];
    await runAgentEval({
      env: {} as NodeJS.ProcessEnv,
      fetchImpl: forbiddenFetch(),
      log: (m) => messages.push(m),
    });
    const text = messages.join("\n");
    expect(text).toContain("Copilot Studio is cloud-only");
    expect(text).toContain("amendment 2026-08-24");
    expect(text).toContain("npm run eval");
  });

  it("writes no artifact when it refuses", async () => {
    const outPath = tempArtifact();
    await runAgentEval({
      env: {} as NodeJS.ProcessEnv,
      fetchImpl: forbiddenFetch(),
      outPath,
      log: () => {},
    });
    expect(fs.existsSync(outPath)).toBe(false);
  });

  it("treats a whitespace-only secret as absent", async () => {
    const code = await runAgentEval({
      env: { DIRECTLINE_SECRET: "   " } as NodeJS.ProcessEnv,
      fetchImpl: forbiddenFetch(),
      log: () => {},
    });
    expect(code).toBe(0);
  });

  it("finds the secret under either supported variable name", () => {
    expect(SECRET_VARS).toEqual(["DIRECTLINE_SECRET", "MLS_DIRECTLINE_SECRET"]);
    expect(findSecret({ DIRECTLINE_SECRET: "x" } as NodeJS.ProcessEnv)?.name).toBe(
      "DIRECTLINE_SECRET",
    );
    expect(findSecret({ MLS_DIRECTLINE_SECRET: "y" } as NodeJS.ProcessEnv)?.name).toBe(
      "MLS_DIRECTLINE_SECRET",
    );
    expect(findSecret({} as NodeJS.ProcessEnv)).toBeUndefined();
  });

  it("keeps the L8 pass bar at 9 of 10", () => {
    expect(AGENT_PASS_BAR).toBe(9);
    expect(goldenQuestions).toHaveLength(10);
  });
});

/* ------------------------------------------------------------------ */
/* The Direct Line protocol                                            */
/* ------------------------------------------------------------------ */

function card(facts: Array<[string, string]>): unknown {
  return {
    type: "AdaptiveCard",
    version: "1.5",
    body: [
      {
        type: "FactSet",
        facts: facts.map(([title, value]) => ({ title, value })),
      },
    ],
  };
}

/**
 * A scripted Direct Line service. The GET side is stateful — it hands back
 * exactly the activities queued by the most recent POST and advances the
 * watermark — so watermark handling is genuinely exercised rather than stubbed.
 */
function directLineMock(
  options: { reply?: (question: string) => Array<Record<string, unknown>> } = {},
): MockFetch {
  const mock = new MockFetch();
  let pending: Array<Record<string, unknown>> = [];
  let watermark = 0;

  mock.on((url, init) => url.endsWith("/v3/directline/conversations") && init?.method === "POST", {
    status: 201,
    body: { conversationId: CONVERSATION, token: "conv-scoped-token", expires_in: 1800 },
  });
  mock.on((url, init) => url.includes("/activities") && init?.method === "POST", {
    status: 200,
    body: { id: "activity-1" },
  });

  const routed = mock.fetch;
  const stateful = async (url: string, init?: RequestInit): Promise<Response> => {
    if (url.includes("/activities") && init?.method === "POST") {
      const body = JSON.parse(String(init.body));
      pending = options.reply
        ? options.reply(String(body.text))
        : [{ type: "message", from: { id: "bot" }, text: "ok" }];
      return routed(url, init);
    }
    if (url.includes("/activities") && (init?.method ?? "GET") === "GET") {
      const activities = pending;
      pending = [];
      watermark += activities.length;
      mock.calls.push({ url, method: "GET", headers: {}, body: undefined, rawBody: undefined });
      return new Response(JSON.stringify({ activities, watermark: String(watermark) }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }
    return routed(url, init);
  };
  (mock as unknown as { fetch: typeof stateful }).fetch = stateful;
  return mock;
}

describe("DirectLineClient", () => {
  it("exchanges the secret for a conversation-scoped token and uses it thereafter", async () => {
    const mock = directLineMock();
    const client = new DirectLineClient({
      secret: SECRET,
      fetchImpl: mock.fetch,
      sleep: noSleep,
      settleMs: 0,
    });
    const id = await client.openConversation();
    expect(id).toBe(CONVERSATION);

    await client.ask("How many launches?");
    const open = mock.calls.find((c) => c.url.endsWith("/v3/directline/conversations"))!;
    const post = mock.calls.find((c) => c.method === "POST" && c.url.includes("/activities"))!;
    // The secret crosses the wire exactly once.
    expect(open.headers["authorization"]).toBe(`Bearer ${SECRET}`);
    expect(post.headers["authorization"]).toBe("Bearer conv-scoped-token");
    expect(
      mock.calls.filter((c) => c.headers["authorization"] === `Bearer ${SECRET}`),
    ).toHaveLength(1);
  });

  it("posts the documented message activity shape", async () => {
    const mock = directLineMock();
    const client = new DirectLineClient({
      secret: SECRET,
      fetchImpl: mock.fetch,
      sleep: noSleep,
      settleMs: 0,
      userId: "mls-eval",
    });
    await client.openConversation();
    await client.ask("Which day of the week has the most launches?");
    const post = mock.calls.find((c) => c.method === "POST" && c.url.includes("/activities"))!;
    expect(post.url).toBe(
      `https://directline.botframework.com/v3/directline/conversations/${CONVERSATION}/activities`,
    );
    expect(post.body).toEqual({
      type: "message",
      from: { id: "mls-eval" },
      text: "Which day of the week has the most launches?",
    });
  });

  it("collects text AND the Adaptive Card, not just the first activity", async () => {
    // A Copilot Studio turn is typing -> text -> card. Stopping at the first
    // activity would grade the prose and miss the card V8.4 cares about.
    const mock = directLineMock({
      reply: () => [
        { type: "typing", from: { id: "bot" } },
        { type: "message", from: { id: "bot" }, text: "Saturday, with 309 launches." },
        {
          type: "message",
          from: { id: "bot" },
          attachments: [
            { contentType: ADAPTIVE_CARD_CONTENT_TYPE, content: card([["Saturday", "309"]]) },
          ],
        },
      ],
    });
    const client = new DirectLineClient({
      secret: SECRET,
      fetchImpl: mock.fetch,
      sleep: noSleep,
      settleMs: 0,
    });
    await client.openConversation();
    const reply = await client.ask("Which day?");
    expect(reply.text).toEqual(["Saturday, with 309 launches."]);
    expect(reply.cards).toHaveLength(1);
    expect(reply.timedOut).toBe(false);
  });

  it("ignores our own echoed activity", async () => {
    const mock = directLineMock({
      reply: () => [
        { type: "message", from: { id: "mls-eval" }, text: "Which day?" },
        { type: "message", from: { id: "bot" }, text: "Saturday." },
      ],
    });
    const client = new DirectLineClient({
      secret: SECRET,
      fetchImpl: mock.fetch,
      sleep: noSleep,
      settleMs: 0,
    });
    await client.openConversation();
    const reply = await client.ask("Which day?");
    expect(reply.text).toEqual(["Saturday."]);
  });

  it("does not treat a typing indicator as a reply", async () => {
    const mock = directLineMock({ reply: () => [{ type: "typing", from: { id: "bot" } }] });
    const client = new DirectLineClient({
      secret: SECRET,
      fetchImpl: mock.fetch,
      sleep: noSleep,
      settleMs: 0,
      timeoutMs: 20,
      now: (() => {
        let t = 0;
        return () => (t += 10);
      })(),
    });
    await client.openConversation();
    const reply = await client.ask("Which day?");
    expect(reply.timedOut).toBe(true);
    expect(reply.text).toEqual([]);
  });

  it("advances the watermark so an activity is never counted twice", async () => {
    const mock = directLineMock({
      reply: () => [{ type: "message", from: { id: "bot" }, text: "Saturday." }],
    });
    const client = new DirectLineClient({
      secret: SECRET,
      fetchImpl: mock.fetch,
      sleep: noSleep,
      settleMs: 0,
    });
    await client.openConversation();
    await client.ask("first");
    const second = await client.ask("second");
    // Each turn sees only its own reply.
    expect(second.text).toEqual(["Saturday."]);
    const polls = mock.calls.filter((c) => c.method === "GET" && c.url.includes("watermark="));
    expect(polls.length).toBeGreaterThan(0);
  });

  it("refuses to ask before a conversation is open", async () => {
    const client = new DirectLineClient({ secret: SECRET, fetchImpl: forbiddenFetch() });
    await expect(client.ask("hello")).rejects.toThrow(/before openConversation/);
  });

  it("explains a 403 as a secret/publish problem rather than echoing the body", async () => {
    const mock = new MockFetch().on(/conversations/, {
      status: 403,
      body: { error: { message: "Authorization: Bearer leaked-secret-value" } },
    });
    const client = new DirectLineClient({ secret: SECRET, fetchImpl: mock.fetch });
    const failure = await rejection<DirectLineError>(client.openConversation());
    expect(failure).toBeInstanceOf(DirectLineError);
    expect(failure.status).toBe(403);
    expect(failure.message).toContain("PUBLISHED agent");
    expect(failure.message).not.toContain("leaked-secret-value");
  });

  it("fails clearly when the open response is missing the token", async () => {
    const mock = new MockFetch().on(/conversations/, {
      status: 200,
      body: { conversationId: "x" },
    });
    const client = new DirectLineClient({ secret: SECRET, fetchImpl: mock.fetch });
    await expect(client.openConversation()).rejects.toThrow(/conversationId and token/);
  });

  it("recovers tool-call names from trace activities for the V8.3 record", () => {
    expect(extractToolCalls({ type: "trace", value: { toolName: "query_lakehouse_sql" } })).toEqual([
      { name: "query_lakehouse_sql" },
    ]);
    expect(
      extractToolCalls({
        type: "message",
        channelData: { toolCalls: [{ name: "get_cost_series" }] },
      }),
    ).toEqual([{ name: "get_cost_series" }]);
    expect(extractToolCalls({ type: "message", text: "hello" })).toEqual([]);
  });
});

/* ------------------------------------------------------------------ */
/* Fact-checking an Adaptive Card                                      */
/* ------------------------------------------------------------------ */

describe("Adaptive Card fact-checking uses the same assertions as npm run eval", () => {
  it("finds a fact inside a card's FactSet", () => {
    const payload = replyPayload({
      activities: [],
      text: [],
      cards: [
        card([
          ["Busiest weekday", "Saturday"],
          ["Launches", "309"],
        ]),
      ],
      toolCalls: [],
      latencySeconds: 1,
      timedOut: false,
    });
    expect(resultContains(payload, { value: "Saturday" })).toBe(true);
    expect(resultContains(payload, { value: 309 })).toBe(true);
    expect(resultContains(payload, { value: "Tuesday" })).toBe(false);
  });

  it("finds a fact in the prose beside the card", () => {
    const payload = replyPayload({
      activities: [],
      text: ["Saturday is busiest, with 309 launches."],
      cards: [],
      toolCalls: [],
      latencySeconds: 1,
      timedOut: false,
    });
    expect(resultContains(payload, { value: "Saturday" })).toBe(true);
    expect(resultContains(payload, { value: 309 })).toBe(true);
  });

  it("checks a card whole, because a card has no rows to narrow to", () => {
    // questions.ts documents this: scopePayload falls through to the whole
    // payload for anything without a `rows` array.
    const payload = replyPayload({
      activities: [],
      text: [],
      cards: [card([["Busiest weekday", "Saturday"]])],
      toolCalls: [],
      latencySeconds: 1,
      timedOut: false,
    });
    expect(scopePayload(payload, "first-row")).toBe(payload);
  });
});

/* ------------------------------------------------------------------ */
/* The whole harness, against a scripted agent                         */
/* ------------------------------------------------------------------ */

describe("runAgentEval against a scripted agent", () => {
  /** An agent that answers every golden question correctly, in a card. */
  function omniscient(expectedByQuestion: Map<string, string[]>) {
    return (question: string): Array<Record<string, unknown>> => {
      const facts = expectedByQuestion.get(question) ?? [];
      return [
        { type: "typing", from: { id: "bot" } },
        { type: "trace", from: { id: "bot" }, value: { toolName: "query_lakehouse_sql" } },
        {
          type: "message",
          from: { id: "bot" },
          attachments: [
            {
              contentType: ADAPTIVE_CARD_CONTENT_TYPE,
              content: card(facts.map((f) => ["fact", f])),
            },
          ],
        },
      ];
    };
  }

  async function expectationsByQuestion(): Promise<Map<string, string[]>> {
    const map = new Map<string, string[]>();
    for (const question of goldenQuestions) {
      const facts = await question.expected();
      map.set(
        question.question,
        facts.map((f) => String(f.value)),
      );
    }
    return map;
  }

  it("passes 10/10 and exits 0 when the agent answers correctly", async () => {
    const mock = directLineMock({ reply: omniscient(await expectationsByQuestion()) });
    const outPath = tempArtifact();
    const messages: string[] = [];
    const code = await runAgentEval({
      env: { DIRECTLINE_SECRET: SECRET } as NodeJS.ProcessEnv,
      fetchImpl: mock.fetch,
      sleep: noSleep,
      settleMs: 0,
      outPath,
      log: (m) => messages.push(m),
      logError: (m) => messages.push(m),
    });
    expect(code).toBe(0);
    expect(messages.join("\n")).toContain("10/10 passed");

    const artifact = JSON.parse(fs.readFileSync(outPath, "utf-8"));
    expect(artifact.mode).toBe("agent");
    expect(artifact.transport).toBe("directline");
    expect(artifact.passed).toBe(10);
    expect(artifact.passBar).toBe(9);
    expect(artifact.conversationId).toBe(CONVERSATION);
    // The artifact carries what V8.3 and V8.4 consume.
    expect(artifact.questions[0].toolCalls).toContainEqual({ name: "query_lakehouse_sql" });
    expect(artifact.questions[0].cards[0].type).toBe("AdaptiveCard");
    expect(typeof artifact.p95LatencySeconds).toBe("number");
  });

  it("scores a rate-limited reply UNOBSERVABLE, not a failure (F186)", async () => {
    // Measured 2026-09-03: the agent answered four golden questions correctly and
    // the service then rate-limited its tool planner. The harness recorded 4/10
    // with `missingFacts: ['LC-39A']` and friends - reading a service quota as an
    // agent that does not know its own data. It knew; it was never asked.
    const expectations = await expectationsByQuestion();
    const throttleAfter = 4;
    let answered = 0;
    const mock = directLineMock({
      reply: (question: string): Array<Record<string, unknown>> => {
        if (answered >= throttleAfter) {
          return [
            {
              type: "message",
              from: { id: "bot" },
              text:
                "An error has occurred.\nError code: GenAIToolPlannerRateLimitReached\n" +
                "Conversation Id: X-us",
            },
          ];
        }
        answered += 1;
        const facts = expectations.get(question) ?? [];
        return [
          {
            type: "message",
            from: { id: "bot" },
            attachments: [
              {
                contentType: ADAPTIVE_CARD_CONTENT_TYPE,
                content: card(facts.map((f) => ["fact", f])),
              },
            ],
          },
        ];
      },
    });
    const outPath = tempArtifact();
    const messages: string[] = [];
    const code = await runAgentEval({
      env: { DIRECTLINE_SECRET: SECRET } as NodeJS.ProcessEnv,
      fetchImpl: mock.fetch,
      sleep: noSleep,
      settleMs: 0,
      outPath,
      log: (m) => messages.push(m),
      logError: (m) => messages.push(m),
    });

    const artifact = JSON.parse(fs.readFileSync(outPath, "utf-8"));
    const throttled = artifact.questions.filter((q: { unobservable: boolean }) => q.unobservable);

    // The warm-up consumes one answer, so the exact split is not the point; what
    // matters is that throttled turns are NOT counted as wrong answers.
    expect(throttled.length).toBeGreaterThan(0);
    expect(artifact.unobservable).toBe(throttled.length);
    for (const q of throttled) {
      expect(q.pass).toBe(false);
      // The defect being fixed: these used to carry the expected values as
      // "missing", which reads as a wrong answer.
      expect(q.unobservable).toBe(true);
    }
    // No verdict is not a pass.
    expect(code).toBe(1);
    const text = messages.join("\n");
    expect(text).toContain("UNOBSERVABLE");
    expect(text).toContain("NO VERDICT");
  });

  it("retries a throttled question before calling it unobservable", async () => {
    // Retrying converts "could not observe" into an observation where the limit is
    // momentary. A question that recovers on retry must score as a normal PASS.
    const expectations = await expectationsByQuestion();
    const attempts = new Map<string, number>();
    const mock = directLineMock({
      reply: (question: string): Array<Record<string, unknown>> => {
        const n = (attempts.get(question) ?? 0) + 1;
        attempts.set(question, n);
        if (n === 1 && question !== WARM_UP_QUESTION) {
          return [
            {
              type: "message",
              from: { id: "bot" },
              text: "Error code: GenAIToolPlannerRateLimitReached",
            },
          ];
        }
        const facts = expectations.get(question) ?? [];
        return [
          {
            type: "message",
            from: { id: "bot" },
            attachments: [
              {
                contentType: ADAPTIVE_CARD_CONTENT_TYPE,
                content: card(facts.map((f) => ["fact", f])),
              },
            ],
          },
        ];
      },
    });
    const outPath = tempArtifact();
    const code = await runAgentEval({
      env: { DIRECTLINE_SECRET: SECRET } as NodeJS.ProcessEnv,
      fetchImpl: mock.fetch,
      sleep: noSleep,
      settleMs: 0,
      outPath,
      log: () => {},
      logError: () => {},
    });
    const artifact = JSON.parse(fs.readFileSync(outPath, "utf-8"));
    expect(artifact.unobservable).toBe(0);
    expect(artifact.passed).toBe(10);
    expect(code).toBe(0);
  });

  it("asks a discarded warm-up question first, so p95 excludes the cold start", async () => {
    const asked: string[] = [];
    const mock = directLineMock({
      reply: (question) => {
        asked.push(question);
        return [{ type: "message", from: { id: "bot" }, text: "ok" }];
      },
    });
    const outPath = tempArtifact();
    await runAgentEval({
      env: { DIRECTLINE_SECRET: SECRET } as NodeJS.ProcessEnv,
      fetchImpl: mock.fetch,
      sleep: noSleep,
      settleMs: 0,
      outPath,
      log: () => {},
      logError: () => {},
    });
    expect(asked[0]).toBe(WARM_UP_QUESTION);
    expect(asked).toHaveLength(goldenQuestions.length + 1);
    const artifact = JSON.parse(fs.readFileSync(outPath, "utf-8"));
    expect(artifact.questions).toHaveLength(goldenQuestions.length);
    expect(artifact.questions.map((q: any) => q.question)).not.toContain(WARM_UP_QUESTION);
  });

  it("exits 1 and records the missing facts when the agent answers wrongly", async () => {
    const mock = directLineMock({
      reply: () => [{ type: "message", from: { id: "bot" }, text: "I am not sure." }],
    });
    const outPath = tempArtifact();
    const code = await runAgentEval({
      env: { MLS_DIRECTLINE_SECRET: SECRET } as NodeJS.ProcessEnv,
      fetchImpl: mock.fetch,
      sleep: noSleep,
      settleMs: 0,
      outPath,
      log: () => {},
      logError: () => {},
    });
    expect(code).toBe(1);
    const artifact = JSON.parse(fs.readFileSync(outPath, "utf-8"));
    expect(artifact.passed).toBe(0);
    expect(artifact.questions[0].missingFacts.length).toBeGreaterThan(0);
    // The expectations were still re-derived from the lakehouse, independently.
    expect(artifact.questions[0].expectedFacts.length).toBeGreaterThan(0);
  });

  it("exits 1 when the conversation cannot be opened", async () => {
    const mock = new MockFetch().on(/conversations/, { status: 401, body: { message: "no" } });
    const errors: string[] = [];
    const code = await runAgentEval({
      env: { DIRECTLINE_SECRET: SECRET } as NodeJS.ProcessEnv,
      fetchImpl: mock.fetch,
      sleep: noSleep,
      log: () => {},
      logError: (m) => errors.push(m),
    });
    expect(code).toBe(1);
    expect(errors.join("\n")).toContain("conversation could not be opened");
  });

  it("records which path answered, for the L8 audit report", async () => {
    const mock = directLineMock({ reply: omniscient(await expectationsByQuestion()) });
    const outPath = tempArtifact();
    await runAgentEval({
      env: {
        DIRECTLINE_SECRET: SECRET,
        MLS_AGENT_PATH: "mcp-tools-only",
      } as NodeJS.ProcessEnv,
      fetchImpl: mock.fetch,
      sleep: noSleep,
      settleMs: 0,
      outPath,
      log: () => {},
      logError: () => {},
    });
    // L8 §V8.2: the report names the path so the Verifier's evidence is
    // unambiguous — fabric-data-agent or mcp-tools-only.
    expect(JSON.parse(fs.readFileSync(outPath, "utf-8")).path).toBe("mcp-tools-only");
  });
});
