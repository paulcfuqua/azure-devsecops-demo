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

    const tokenCall = fetchImpl.mock.calls.find(
      ([url]) => String(url) === "https://fn.example/api/directline/token",
    ) as unknown as [string, RequestInit];
    expect(tokenCall).toBeDefined();
    expect(tokenCall[1].method).toBe("POST");
    const headers = tokenCall[1].headers as Record<string, string>;
    expect(headers.authorization).toBe("Bearer easy-auth-id-token");
    // Still no secret and no cookie: the forwarded token is the only credential.
    expect(tokenCall[1].body).toBeUndefined();
    expect(tokenCall[1].credentials).toBeUndefined();
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
    expect(
      fetchImpl.mock.calls.some(
        ([url]) => String(url) === "https://fn.example/api/directline/token",
      ),
    ).toBe(false);
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
