import { describe, expect, it, vi } from "vitest";
import {
  activityToTurn,
  appendTurn,
  assertNoSecretMaterial,
  connectDirectLine,
  createAgentProvider,
  createTokenFetcher,
  DirectLineAgentProvider,
  DirectLineTokenError,
  easyAuthSignInAgainUrl,
  OfflineAgentProvider,
  parseTokenResponse,
  resolveAgentConfig,
  userTurn,
  type DirectLineActivity,
} from "../src/agent";

const DIRECT_LINE_SECRET = "s3cr3t-direct-line-key";

describe("resolveAgentConfig (the Ask tab's mode switch)", () => {
  it("goes offline when no token endpoint is configured", () => {
    const config = resolveAgentConfig({});
    expect(config.mode).toBe("offline");
    if (config.mode !== "offline") throw new Error("expected offline");
    expect(config.reason).toMatch(/VITE_DIRECTLINE_TOKEN_URL/);
  });

  it("goes live when a token endpoint is configured", () => {
    const config = resolveAgentConfig({
      VITE_DIRECTLINE_TOKEN_URL: " https://fn.example/api/directline/token ",
      VITE_DIRECTLINE_DOMAIN: "https://europe.directline.botframework.com",
    });
    expect(config).toEqual({
      mode: "directline",
      tokenUrl: "https://fn.example/api/directline/token",
      baseUrl: "https://europe.directline.botframework.com",
    });
  });

  it("honours an explicit VITE_AGENT_MODE=offline", () => {
    const config = resolveAgentConfig({
      VITE_AGENT_MODE: "offline",
      VITE_DIRECTLINE_TOKEN_URL: "https://fn.example/api/directline/token",
    });
    expect(config.mode).toBe("offline");
  });

  // The security invariant, at the earliest point it can be enforced: Vite
  // inlines every VITE_-prefixed variable into the shipped bundle, so a
  // secret-shaped build variable is a credential leak waiting to be served.
  it.each([
    "VITE_DIRECTLINE_SECRET",
    "VITE_DIRECT_LINE_CLIENT_SECRET",
    "VITE_AGENT_APIKEY",
    "VITE_BOT_PASSWORD",
  ])("refuses to start when %s is present, and says why", (key) => {
    const config = resolveAgentConfig({
      [key]: DIRECT_LINE_SECRET,
      VITE_DIRECTLINE_TOKEN_URL: "https://fn.example/api/directline/token",
    });
    expect(config.mode).toBe("offline");
    if (config.mode !== "offline") throw new Error("expected offline");
    expect(config.reason).toContain(key);
    // The reason is rendered in the UI — it must name the variable, never echo
    // the value it carries.
    expect(config.reason).not.toContain(DIRECT_LINE_SECRET);
  });

  it("ignores an empty secret-shaped variable rather than blocking on it", () => {
    const config = resolveAgentConfig({
      VITE_DIRECTLINE_SECRET: "",
      VITE_DIRECTLINE_TOKEN_URL: "https://fn.example/api/directline/token",
    });
    expect(config.mode).toBe("directline");
  });
});

describe("createAgentProvider", () => {
  it("builds an offline provider that refuses to connect", async () => {
    const provider = createAgentProvider({ mode: "offline", reason: "not deployed." });
    expect(provider).toBeInstanceOf(OfflineAgentProvider);
    expect(provider.available).toBe(false);
    expect(provider.unavailableReason).toBe("not deployed.");
    await expect(provider.connect()).rejects.toThrow(/offline/i);
  });

  it("builds a Direct Line provider without touching the network", () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    const provider = createAgentProvider({
      mode: "directline",
      tokenUrl: "https://fn.example/api/directline/token",
    });
    expect(provider).toBeInstanceOf(DirectLineAgentProvider);
    expect(provider.available).toBe(true);
    expect(provider.source).toMatch(/Direct Line/);
    expect(fetchMock).not.toHaveBeenCalled();
    vi.unstubAllGlobals();
  });
});

describe("the token seam never lets a secret reach the app", () => {
  it("parses the documented token-endpoint response shape", () => {
    const token = parseTokenResponse({
      token: "a-short-lived-token",
      expires_in: 1800,
      conversationId: "conv-1",
      userId: "dl_abc",
    });
    expect(token).toEqual({
      token: "a-short-lived-token",
      expiresInSeconds: 1800,
      conversationId: "conv-1",
      userId: "dl_abc",
    });
  });

  it("drops every field it was not promised, so nothing extra enters app state", () => {
    const token = parseTokenResponse({
      token: "t",
      expires_in: 1800,
      streamUrl: "wss://example/stream",
      internalNote: "do not ship me",
    });
    expect(Object.keys(token).sort()).toEqual([
      "conversationId",
      "expiresInSeconds",
      "token",
      "userId",
    ]);
    expect(JSON.stringify(token)).not.toContain("do not ship me");
  });

  it.each([
    ["secret", { token: "t", secret: DIRECT_LINE_SECRET }],
    ["directLineSecret", { token: "t", directLineSecret: DIRECT_LINE_SECRET }],
    ["client_secret", { token: "t", client_secret: DIRECT_LINE_SECRET }],
    ["apiKey", { token: "t", apiKey: DIRECT_LINE_SECRET }],
    ["a nested secret", { token: "t", channel: { config: { password: DIRECT_LINE_SECRET } } }],
  ])("throws instead of accepting a response carrying %s", (_label, payload) => {
    expect(() => parseTokenResponse(payload)).toThrow(DirectLineTokenError);
    // Failing loudly is the point: a silent drop would leave a leaking token
    // endpoint in production with nothing to notice it.
    expect(() => assertNoSecretMaterial(payload)).toThrow(/never secret material/i);
  });

  it("rejects a response with no token at all", () => {
    expect(() => parseTokenResponse({ expires_in: 1800 })).toThrow(/no `token`/);
    expect(() => parseTokenResponse("nope")).toThrow(/JSON object/);
  });

  it("forwards this session's Easy Auth token to the endpoint", async () => {
    // INVERTED DELIBERATELY. This assertion used to be `not.toContain
    // ("authorization")`: the endpoint was anonymous, guarded only by an Origin
    // allow-list, which stops a browser on another site and no direct caller at
    // all. The page now forwards the Entra token it already holds, and the
    // Function verifies it before exchanging the Direct Line secret.
    const fetchImpl = vi.fn(async (url: string) => {
      if (String(url) === "/.auth/me") {
        return new Response(JSON.stringify([{ id_token: "easy-auth-id-token" }]), { status: 200 });
      }
      return new Response(JSON.stringify({ token: "t", expires_in: 1800, userId: "dl_x" }), {
        status: 200,
      });
    });
    const fetchToken = createTokenFetcher("https://fn.example/api/directline/token", {
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    await fetchToken();

    const calls = fetchImpl.mock.calls as unknown as Array<[string, RequestInit]>;
    const tokenCall = calls.find(
      (call) => String(call[0]) === "https://fn.example/api/directline/token",
    );
    expect(tokenCall).toBeDefined();
    const init = tokenCall![1];
    expect(init.method).toBe("POST");
    const headers = init.headers as Record<string, string>;
    expect(headers.authorization).toBe("Bearer easy-auth-id-token");
    // Still no secret and no cookie: the forwarded token is the only credential.
    expect(init.body).toBeUndefined();
    expect(init.credentials).toBeUndefined();
  });

  it("hands the caller somewhere to GO when the sign-in has expired (F149)", async () => {
    // F142 shipped a retry through /.auth/refresh. That endpoint cannot work on
    // this app: redeeming a refresh token is a confidential-client grant, and the
    // Easy Auth registration has no client secret and no offline_access scope, so
    // no refresh token is ever issued. The retry could not have succeeded on any
    // run - and the message it fell back to said "reload the page", which does
    // nothing either, because the session cookie is still valid and Easy Auth
    // hands back the SAME expired token. That is why Incognito worked and F5 did
    // not.
    const fetchImpl = vi.fn(async (url: string) => {
      const u = String(url);
      if (u === "/.auth/me") {
        return new Response(JSON.stringify([{ id_token: "expired" }]), { status: 200 });
      }
      if (u === "/.auth/refresh") return new Response(null, { status: 401 });
      return new Response("nope", { status: 401 });
    });

    const fetchToken = createTokenFetcher("https://fn.example/api/directline/token", {
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    const error = await fetchToken().catch((e: unknown) => e);
    expect(error).toBeInstanceOf(DirectLineTokenError);
    // The recovery is an ACTION, not an instruction to try the thing that fails -
    // and it is a LOGIN. Pointing it at /.auth/logout (F150) signed the user out
    // and left them on a cached page with no session and no way back in.
    expect((error as DirectLineTokenError).signInUrl).toMatch(/^\/\.auth\/login\/aad\?/);
    expect((error as DirectLineTokenError).signInUrl).not.toMatch(/logout/);
    expect((error as DirectLineTokenError).message).not.toMatch(/[Rr]eload/);
  });

  it("offers no sign-in link for a failure signing in would not fix", async () => {
    // A 500 from the token endpoint is the deployment being wrong, not the
    // caller. Offering "sign in again" there sends someone round a loop that
    // cannot help and hides the real fault.
    const fetchImpl = vi.fn(async (url: string) => {
      const u = String(url);
      if (u === "/.auth/me") {
        return new Response(JSON.stringify([{ id_token: "fine" }]), { status: 200 });
      }
      return new Response("boom", { status: 500 });
    });

    const fetchToken = createTokenFetcher("https://fn.example/api/directline/token", {
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    const error = await fetchToken().catch((e: unknown) => e);
    expect(error).toBeInstanceOf(DirectLineTokenError);
    expect((error as DirectLineTokenError).signInUrl).toBeUndefined();
  });

  it("re-runs the login rather than ending the session (F150)", async () => {
    // THIS TEST USED TO ASSERT THE OPPOSITE, and it passed, because it encoded
    // the same wrong assumption the code did. Sending a stuck user to
    // /.auth/logout gave them an account picker, signed them OUT, and dropped
    // them on a cached page with no session and no way back - strictly worse
    // than the expired token it was meant to repair.
    //
    // /.auth/login/aad re-runs the authorization-code flow while keeping the
    // session, and it is a server endpoint, so it cannot be served from the
    // browser cache the way "/" can. Verified against the deployed app: it
    // answers 302 to login.microsoftonline.com.
    const url = easyAuthSignInAgainUrl("/ask");
    expect(url).toContain("/.auth/login/aad");
    expect(url).not.toContain("logout");
    expect(url).toContain(encodeURIComponent("/ask"));
  });

  it("tells a signed-OUT reader they can sign in (F150)", async () => {
    // /.auth/me answers an unauthenticated caller with a 302 to Entra. Followed,
    // that lands on login.microsoftonline.com where CORS throws, and every
    // failure looks identical - which is how being signed out came to produce
    // "could not read this session's Entra token", true and useless.
    const fetchImpl = vi.fn(async (url: string) => {
      if (String(url) === "/.auth/me") return new Response(null, { status: 302 });
      return new Response("nope", { status: 401 });
    });
    const fetchToken = createTokenFetcher("https://fn.example/api/directline/token", {
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    const error = await fetchToken().catch((e: unknown) => e);
    expect((error as DirectLineTokenError).message).toMatch(/not signed in/i);
    expect((error as DirectLineTokenError).signInUrl).toMatch(/^\/\.auth\/login\/aad\?/);
  });

  it("offers NO sign-in link when the token store is the problem (F135)", async () => {
    // Claims came back, so the session is fine; there is simply no raw token to
    // forward because the token store is off. Signing in again does nothing for
    // that, and offering it would send someone round a loop hiding a deployment
    // fault.
    const fetchImpl = vi.fn(async (url: string) => {
      if (String(url) === "/.auth/me") {
        return new Response(JSON.stringify([{ user_id: "someone@example.com" }]), { status: 200 });
      }
      return new Response("nope", { status: 401 });
    });
    const fetchToken = createTokenFetcher("https://fn.example/api/directline/token", {
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    const error = await fetchToken().catch((e: unknown) => e);
    expect((error as DirectLineTokenError).message).toMatch(/token store/i);
    expect((error as DirectLineTokenError).signInUrl).toBeUndefined();
  });

  it("asks /.auth/me not to follow its own redirect", async () => {
    // The precondition the three-way read depends on. Without redirect:"manual"
    // the 302 is followed and the distinction is unobservable.
    const seen: RequestInit[] = [];
    const fetchImpl = vi.fn(async (url: string, init?: RequestInit) => {
      if (String(url) === "/.auth/me") {
        seen.push(init ?? {});
        return new Response(JSON.stringify([{ id_token: "t" }]), { status: 200 });
      }
      return new Response(JSON.stringify({ token: "x", expires_in: 1800, userId: "dl_1" }), {
        status: 200,
      });
    });
    const fetchToken = createTokenFetcher("https://fn.example/api/directline/token", {
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    await fetchToken();
    expect(seen[0]?.redirect).toBe("manual");
  });

  it("refreshes once and retries when the endpoint says the token expired (F142)", async () => {
    // The id_token is issued at sign-in with about an hour's life and NOTHING was
    // renewing it, so the Ask tab worked for an hour and then locked the user out
    // of their own agent with a 401 that read like an outage.
    let token = "expired-token";
    const seen: string[] = [];
    const fetchImpl = vi.fn(async (url: string, init?: RequestInit) => {
      const u = String(url);
      seen.push(u);
      if (u === "/.auth/me") {
        return new Response(JSON.stringify([{ id_token: token }]), { status: 200 });
      }
      if (u === "/.auth/refresh") {
        token = "fresh-token";
        return new Response(null, { status: 200 });
      }
      const bearer = (init?.headers as Record<string, string>).authorization;
      return bearer === "Bearer fresh-token"
        ? new Response(JSON.stringify({ token: "t", expires_in: 1800, userId: "dl_x" }), {
            status: 200,
          })
        : new Response("nope", { status: 401 });
    });

    const fetchToken = createTokenFetcher("https://fn.example/api/directline/token", {
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    await expect(fetchToken()).resolves.toMatchObject({ token: "t" });
    expect(seen).toContain("/.auth/refresh");
  });

  it("gives up after ONE refresh rather than looping", async () => {
    // A retry that cannot succeed is worse than a clear sentence: the whole point
    // of not navigating to a login endpoint is that a bad session must not become
    // a redirect loop.
    let refreshes = 0;
    const fetchImpl = vi.fn(async (url: string) => {
      const u = String(url);
      if (u === "/.auth/me") {
        return new Response(JSON.stringify([{ id_token: "stale" }]), { status: 200 });
      }
      if (u === "/.auth/refresh") {
        refreshes += 1;
        return new Response(null, { status: 200 });
      }
      return new Response("nope", { status: 401 });
    });

    const fetchToken = createTokenFetcher("https://fn.example/api/directline/token", {
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    await expect(fetchToken()).rejects.toThrow(/sign-in has expired/);
    expect(refreshes).toBe(1);
  });

  it("refuses to call the endpoint at all when Easy Auth yields no token", async () => {
    // Served without Easy Auth in front of it - a local `npm run dev`, or a
    // misconfigured revision - /.auth/me is absent. The tab must say so, not
    // call the token endpoint anonymously and report its 401 as a bot outage.
    const fetchImpl = vi.fn(async () => new Response("nope", { status: 404 }));
    const fetchToken = createTokenFetcher("https://fn.example/api/directline/token", {
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });
    await expect(fetchToken()).rejects.toThrow(/cannot prove who is asking/);
    const attempted = (fetchImpl.mock.calls as unknown as Array<[string]>).some(
      (call) => String(call[0]) === "https://fn.example/api/directline/token",
    );
    expect(attempted).toBe(false);
  });

  it("explains that the Ask tab needs the deployed environment when the endpoint 404s", async () => {
    const fetchToken = createTokenFetcher("https://fn.example/api/directline/token", {
      fetchImpl: (async (url: string) =>
        String(url) === "/.auth/me"
          ? new Response(JSON.stringify([{ id_token: "easy-auth-id-token" }]), { status: 200 })
          : new Response("nope", { status: 404 })) as unknown as typeof fetch,
    });
    await expect(fetchToken()).rejects.toThrow(/deployed environment/);
  });
});

// ---------------------------------------------------------------------------
// Direct Line transport. The WebSocket factory is stubbed to null throughout so
// the tests exercise the documented watermark-polling path and never open a
// socket.
// ---------------------------------------------------------------------------

interface StubRoute {
  status?: number;
  body: unknown;
}

function directLineStub(routes: Record<string, StubRoute | StubRoute[]>) {
  const calls: Array<{ url: string; init?: RequestInit }> = [];
  const queues = new Map<string, StubRoute[]>(
    Object.entries(routes).map(([key, value]) => [
      key,
      Array.isArray(value) ? [...value] : [value],
    ]),
  );

  const impl = async (url: string, init?: RequestInit): Promise<Response> => {
    calls.push({ url, init });
    const method = (init?.method ?? "GET").toUpperCase();
    const path = url.replace(/\?.*$/, "");
    const queue = queues.get(`${method} ${path}`);
    const route = queue && (queue.length > 1 ? queue.shift() : queue[0]);
    if (!route) return new Response("not stubbed", { status: 404 });
    return new Response(JSON.stringify(route.body), { status: route.status ?? 200 });
  };
  return Object.assign(impl as unknown as typeof fetch, { calls });
}

const CARD_ACTIVITY: DirectLineActivity = {
  type: "message",
  id: "act-1",
  from: { id: "mls-agent", role: "bot" },
  text: "Here is the launch posture.",
  attachments: [
    {
      contentType: "application/vnd.microsoft.card.adaptive",
      content: {
        type: "AdaptiveCard",
        version: "1.5",
        body: [{ type: "TextBlock", text: "3 launches this quarter" }],
      },
    },
  ],
};

describe("connectDirectLine (Direct Line 3.0)", () => {
  const base = "https://directline.botframework.com";

  it("starts a conversation with the bearer token and streams activities", async () => {
    const fetchImpl = directLineStub({
      [`POST ${base}/v3/directline/conversations`]: {
        body: { conversationId: "conv-9" },
      },
      [`GET ${base}/v3/directline/conversations/conv-9/activities`]: {
        body: { activities: [CARD_ACTIVITY], watermark: "5" },
      },
      [`POST ${base}/v3/directline/conversations/conv-9/activities`]: {
        body: { id: "act-0" },
      },
    });

    const received: DirectLineActivity[] = [];
    const connection = await connectDirectLine({
      tokenFetcher: async () => ({ token: "tok", userId: "dl_me" }),
      fetchImpl,
      webSocketFactory: () => null,
      pollIntervalMs: 60_000,
    });
    connection.onActivity((activity) => received.push(activity));

    expect(connection.conversationId).toBe("conv-9");
    const start = fetchImpl.calls[0];
    expect(start?.url).toBe(`${base}/v3/directline/conversations`);
    expect((start?.init?.headers as Record<string, string>).authorization).toBe(
      "Bearer tok",
    );

    // The priming poll already ran; the first activity is delivered on subscribe
    // of the next poll, so pull once more to observe it.
    await connection.send("what is our posture?");
    expect(received.map((a) => a.id)).toContain("act-1");

    const posted = fetchImpl.calls.find(
      (c) =>
        c.url.endsWith("/conv-9/activities") &&
        (c.init?.method ?? "GET").toUpperCase() === "POST",
    );
    expect(JSON.parse(String(posted?.init?.body))).toEqual({
      type: "message",
      from: { id: "dl_me" },
      text: "what is our posture?",
    });

    connection.close();
  });

  it("suppresses the echo of the user's own activity", async () => {
    const fetchImpl = directLineStub({
      [`POST ${base}/v3/directline/conversations`]: { body: { conversationId: "c1" } },
      [`GET ${base}/v3/directline/conversations/c1/activities`]: {
        body: {
          activities: [
            { type: "message", id: "echo", from: { id: "dl_me" }, text: "mine" },
            { type: "message", id: "reply", from: { id: "bot" }, text: "theirs" },
          ],
          watermark: "2",
        },
      },
      [`POST ${base}/v3/directline/conversations/c1/activities`]: { body: { id: "posted" } },
    });

    const seen: string[] = [];
    const connection = await connectDirectLine({
      tokenFetcher: async () => ({ token: "tok", userId: "dl_me" }),
      fetchImpl,
      webSocketFactory: () => null,
      pollIntervalMs: 60_000,
    });
    connection.onActivity((a) => seen.push(String(a.id)));
    await connection.send("mine");

    expect(seen).toContain("reply");
    expect(seen).not.toContain("echo");
    connection.close();
  });

  it("translates the documented Direct Line failure codes", async () => {
    const fetchImpl = directLineStub({
      [`POST ${base}/v3/directline/conversations`]: { status: 403, body: {} },
    });
    await expect(
      connectDirectLine({
        tokenFetcher: async () => ({ token: "expired" }),
        fetchImpl,
        webSocketFactory: () => null,
      }),
    ).rejects.toThrow(/TokenExpired/);
  });
});

describe("transcript shaping", () => {
  it("splits Adaptive Card attachments out of a message activity", () => {
    const turn = activityToTurn(CARD_ACTIVITY);
    expect(turn).not.toBeNull();
    expect(turn?.role).toBe("agent");
    expect(turn?.text).toBe("Here is the launch posture.");
    expect(turn?.cards).toHaveLength(1);
    expect(turn?.cards[0]?.type).toBe("AdaptiveCard");
    expect(turn?.otherAttachments).toHaveLength(0);
  });

  it("keeps non-card attachments visible instead of dropping them", () => {
    const turn = activityToTurn({
      type: "message",
      id: "a",
      text: "",
      attachments: [{ contentType: "application/vnd.microsoft.card.hero", content: {} }],
    });
    expect(turn?.cards).toHaveLength(0);
    expect(turn?.otherAttachments).toHaveLength(1);
  });

  // A generative Copilot Studio answer has exactly ONE output channel: the message
  // text. The agent's instructions tell it to emit an Adaptive Card, so it writes the
  // card JSON into that text, and nothing on the Copilot Studio side promotes it to a
  // Direct Line attachment - agent-definition.md section 8 flagged that path as an
  // unresolved gap before any of this shipped. The result on screen is a paragraph of
  // prose followed by a wall of raw JSON. The card is real and valid; only its
  // transport is text, so the transcript lifts it out here.
  const CARD_IN_TEXT =
    'The launches table shows 227 launches in 2021 and 92 in 2026. ' +
    '{ "$schema": "http://adaptivecards.io/schemas/adaptive-card.json", ' +
    '"type": "AdaptiveCard", "version": "1.6", "body": [ { "type": "TextBlock", ' +
    '"text": "Launches by Year", "weight": "Bolder" } ], "actions": [ { "type": ' +
    '"Action.Submit", "title": "Launch Count Details", "data": { "cardId": ' +
    '"launches-by-year" } } ] }';

  it("lifts a card the agent wrote into the message text out of the prose", () => {
    const turn = activityToTurn({ type: "message", id: "t1", text: CARD_IN_TEXT });
    expect(turn?.text).toBe(
      "The launches table shows 227 launches in 2021 and 92 in 2026.",
    );
    expect(turn?.cards).toHaveLength(1);
    expect(turn?.cards[0]?.type).toBe("AdaptiveCard");
    expect(turn?.cards[0]?.version).toBe("1.6");
  });

  it("lifts a card out of a fenced json block", () => {
    const turn = activityToTurn({
      type: "message",
      id: "t2",
      text: 'Here you go.\n```json\n{ "type": "AdaptiveCard", "version": "1.6" }\n```',
    });
    expect(turn?.text).toBe("Here you go.");
    expect(turn?.cards).toHaveLength(1);
  });

  it("leaves JSON that is not an Adaptive Card in the text", () => {
    // Only a card is lifted. An agent quoting a config blob or a tool result is
    // saying something, and silently deleting it from the answer would be worse
    // than the wall of JSON this fixes.
    const turn = activityToTurn({
      type: "message",
      id: "t3",
      text: 'The tool returned { "rows": 12, "table": "launches" } for that query.',
    });
    expect(turn?.cards).toHaveLength(0);
    expect(turn?.text).toBe(
      'The tool returned { "rows": 12, "table": "launches" } for that query.',
    );
  });

  it("does not mistake a brace inside a string literal for the end of the card", () => {
    const turn = activityToTurn({
      type: "message",
      id: "t4",
      text: 'Done. { "type": "AdaptiveCard", "body": [ { "type": "TextBlock", ' +
        '"text": "a } brace and a { brace" } ] }',
    });
    expect(turn?.text).toBe("Done.");
    expect(turn?.cards).toHaveLength(1);
    expect(turn?.cards[0]?.body).toHaveLength(1);
  });

  it("leaves an ordinary prose answer untouched", () => {
    const turn = activityToTurn({
      type: "message",
      id: "t5",
      text: "There are 1,200 launches in the lakehouse.",
    });
    expect(turn?.cards).toHaveLength(0);
    expect(turn?.text).toBe("There are 1,200 launches in the lakehouse.");
  });

  it("prefers a real attachment and does not double-count the same card", () => {
    // If Copilot Studio ever starts sending attachments properly, the text path
    // must not add a second copy of the card beside it.
    const turn = activityToTurn({
      type: "message",
      id: "t6",
      text: CARD_IN_TEXT,
      attachments: [
        {
          contentType: "application/vnd.microsoft.card.adaptive",
          content: { type: "AdaptiveCard", version: "1.6" },
        },
      ],
    });
    expect(turn?.cards).toHaveLength(1);
    expect(turn?.text).toBe(
      "The launches table shows 227 launches in 2021 and 92 in 2026.",
    );
  });

  it("ignores activities the transcript does not show", () => {
    expect(activityToTurn({ type: "typing" })).toBeNull();
    expect(activityToTurn({ type: "conversationUpdate" })).toBeNull();
    expect(activityToTurn({ type: "message", id: "empty" })).toBeNull();
  });

  it("marks the human side from the activity role", () => {
    const turn = activityToTurn({
      type: "message",
      id: "u1",
      from: { id: "dl_me", role: "user" },
      text: "hello",
    });
    expect(turn?.role).toBe("user");
  });

  it("replaces a redelivered activity rather than duplicating it", () => {
    const first = activityToTurn(CARD_ACTIVITY);
    if (!first) throw new Error("expected a turn");
    const once = appendTurn([], first);
    const twice = appendTurn(once, { ...first, text: "revised" });
    expect(twice).toHaveLength(1);
    expect(twice[0]?.text).toBe("revised");
  });

  it("gives locally-authored user turns a unique key", () => {
    expect(userTurn("a").id).not.toBe(userTurn("a").id);
  });
});
