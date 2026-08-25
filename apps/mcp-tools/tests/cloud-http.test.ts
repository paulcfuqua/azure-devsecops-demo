/**
 * The shared HTTP layer every cloud adapter goes through: retry policy,
 * pagination, error taxonomy and redaction.
 *
 * These are asserted once here rather than four times over in the adapter tests,
 * because there is exactly one implementation — which is the reason it exists.
 * `sleep` is injected so a test that proves "waits for Retry-After" costs no
 * wall-clock time and still proves the decision.
 */
import { describe, expect, it, vi } from "vitest";
import {
  DEFAULT_RETRY,
  extractUpstreamMessage,
  HttpClient,
  MAX_PAGES,
  pageByLinkHeader,
  pageByNextLink,
  parseLinkNext,
  parseRetryAfter,
  type HttpJsonResponse,
} from "../src/tools/http.js";
import { AdapterError, kindForStatus, redact } from "../src/tools/errors.js";
import { MockFetch, noSleep } from "./helpers/mock-fetch.js";
import { rejection } from "./helpers/rejection.js";

const URL_UNDER_TEST = "https://example.invalid/v1/thing";

function clientWith(
  mock: MockFetch,
  sleep: (ms: number) => Promise<void> = noSleep,
  retry: Partial<typeof DEFAULT_RETRY> = {},
): HttpClient {
  return new HttpClient({
    service: "test-upstream",
    fetchImpl: mock.fetch,
    sleep,
    retry,
    // Deterministic jitter so backoff assertions are exact.
    random: () => 1,
  });
}

describe("retry policy", () => {
  it("retries 429 and succeeds on the second attempt", async () => {
    const mock = new MockFetch().on(
      /thing/,
      { status: 429, body: { error: { code: "Throttled", message: "slow down" } } },
      { status: 200, body: { ok: true } },
    );
    const result = await clientWith(mock).requestJson<{ ok: boolean }>({ url: URL_UNDER_TEST });
    expect(result.body.ok).toBe(true);
    expect(result.attempts).toBe(2);
    expect(mock.calls).toHaveLength(2);
  });

  it("retries 503 as well", async () => {
    const mock = new MockFetch().on(
      /thing/,
      { status: 503, body: {} },
      { status: 200, body: { ok: true } },
    );
    const result = await clientWith(mock).requestJson<{ ok: boolean }>({ url: URL_UNDER_TEST });
    expect(result.attempts).toBe(2);
  });

  it("honours Retry-After in seconds instead of its own backoff", async () => {
    const sleeps: number[] = [];
    const sleep = async (ms: number): Promise<void> => {
      sleeps.push(ms);
    };
    const mock = new MockFetch().on(
      /thing/,
      { status: 429, headers: { "retry-after": "3" } },
      { status: 200, body: { ok: true } },
    );
    await clientWith(mock, sleep).requestJson({ url: URL_UNDER_TEST });
    // 3 seconds, exactly as instructed — not the 250ms base backoff.
    expect(sleeps).toEqual([3000]);
  });

  it("honours an HTTP-date Retry-After", async () => {
    const sleeps: number[] = [];
    const now = 1_800_000_000_000;
    const mock = new MockFetch().on(
      /thing/,
      { status: 429, headers: { "retry-after": new Date(now + 5000).toUTCString() } },
      { status: 200, body: { ok: true } },
    );
    const client = new HttpClient({
      service: "test-upstream",
      fetchImpl: mock.fetch,
      sleep: async (ms: number) => {
        sleeps.push(ms);
      },
      now: () => now,
      random: () => 1,
    });
    await client.requestJson({ url: URL_UNDER_TEST });
    // Date.toUTCString drops milliseconds, so allow the second-boundary rounding.
    expect(sleeps[0]).toBeGreaterThanOrEqual(4000);
    expect(sleeps[0]).toBeLessThanOrEqual(5000);
  });

  it("backs off exponentially when Retry-After is absent", async () => {
    const sleeps: number[] = [];
    const mock = new MockFetch().on(
      /thing/,
      { status: 429 },
      { status: 429 },
      { status: 200, body: { ok: true } },
    );
    await clientWith(mock, async (ms: number) => {
      sleeps.push(ms);
    }).requestJson({ url: URL_UNDER_TEST });
    // random() === 1 so full jitter resolves to the full exponential delay.
    expect(sleeps).toEqual([DEFAULT_RETRY.baseDelayMs, DEFAULT_RETRY.baseDelayMs * 2]);
  });

  it("gives up after maxAttempts and raises a throttled AdapterError", async () => {
    const mock = new MockFetch().on(/thing/, { status: 429, body: { error: { message: "nope" } } });
    const failure = await rejection<AdapterError>(
      clientWith(mock).requestJson({ url: URL_UNDER_TEST }),
    );
    expect(failure).toBeInstanceOf(AdapterError);
    expect(failure.kind).toBe("throttled");
    expect(failure.retryable).toBe(true);
    expect(mock.calls).toHaveLength(DEFAULT_RETRY.maxAttempts);
  });

  it("stops early when the elapsed budget runs out, whatever the attempt count", async () => {
    let clock = 0;
    const mock = new MockFetch().on(/thing/, { status: 503 });
    const client = new HttpClient({
      service: "test-upstream",
      fetchImpl: mock.fetch,
      sleep: async () => {},
      // Every call to now() advances 10s, so the 15s budget dies early.
      now: () => (clock += 10_000),
      random: () => 1,
      retry: { maxAttempts: 10 },
    });
    await expect(client.requestJson({ url: URL_UNDER_TEST })).rejects.toThrow(AdapterError);
    expect(mock.calls.length).toBeLessThan(10);
  });

  it("never retries a 4xx that is not 429", async () => {
    for (const status of [400, 401, 403, 404]) {
      const mock = new MockFetch().on(/thing/, { status, body: { error: { message: "no" } } });
      await expect(clientWith(mock).requestJson({ url: URL_UNDER_TEST })).rejects.toThrow(
        AdapterError,
      );
      expect(mock.calls).toHaveLength(1);
    }
  });

  it("retries a transport failure, then reports it as upstream", async () => {
    const mock = new MockFetch().on(
      /thing/,
      { throws: new TypeError("fetch failed") },
      { status: 200, body: { ok: true } },
    );
    const result = await clientWith(mock).requestJson<{ ok: boolean }>({ url: URL_UNDER_TEST });
    expect(result.attempts).toBe(2);
  });
});

describe("error mapping", () => {
  it("maps statuses to the kinds the agent needs to tell apart", () => {
    expect(kindForStatus(401)).toBe("auth");
    expect(kindForStatus(403)).toBe("auth");
    expect(kindForStatus(404)).toBe("not_found");
    expect(kindForStatus(408)).toBe("timeout");
    expect(kindForStatus(429)).toBe("throttled");
    expect(kindForStatus(400)).toBe("bad_request");
    expect(kindForStatus(500)).toBe("upstream");
    expect(kindForStatus(503)).toBe("throttled");
  });

  it("carries the upstream's own message through, so the agent can self-correct", async () => {
    const mock = new MockFetch().on(/thing/, {
      status: 400,
      body: {
        error: {
          code: "BadArgumentError",
          message: "outer",
          innererror: {
            code: "SyntaxError",
            innererror: { code: "SYN0002", message: "Query could not be parsed at 'summarise'" },
          },
        },
      },
    });
    const failure = await rejection<AdapterError>(
      clientWith(mock).requestJson({ url: URL_UNDER_TEST }),
    );
    // The deepest innererror is where Log Analytics puts the useful text.
    expect(failure.message).toContain("Query could not be parsed at 'summarise'");
    expect(failure.kind).toBe("bad_request");
    expect(failure.status).toBe(400);
  });

  it("reads GitHub's flat { message } envelope too", () => {
    expect(extractUpstreamMessage({ message: "Bad credentials" }, "")).toBe("Bad credentials");
  });

  it("falls back to raw text when the body is not a recognised envelope", () => {
    expect(extractUpstreamMessage(undefined, "<html>502 Bad Gateway</html>")).toContain("502");
  });

  it("captures an upstream request id when one is offered", async () => {
    const mock = new MockFetch().on(/thing/, {
      status: 500,
      headers: { "x-ms-request-id": "abc-123" },
      body: {},
    });
    const failure = await rejection<AdapterError>(
      clientWith(mock).requestJson({ url: URL_UNDER_TEST }),
    );
    expect(failure.requestId).toBe("abc-123");
  });

  it("rejects a 200 whose body is not JSON rather than guessing", async () => {
    const mock = new MockFetch().on(/thing/, { status: 200, text: "<html>hi</html>" });
    await expect(clientWith(mock).requestJson({ url: URL_UNDER_TEST })).rejects.toThrow(
      /non-JSON body/,
    );
  });

  it("times out an attempt and reports it as timeout", async () => {
    const mock = new MockFetch().on(/thing/, {
      throws: Object.assign(new Error("This operation was aborted"), { name: "AbortError" }),
    });
    const failure = await rejection<AdapterError>(
      clientWith(mock).requestJson({ url: URL_UNDER_TEST }),
    );
    expect(failure.kind).toBe("timeout");
    expect(failure.retryable).toBe(true);
  });
});

describe("redaction — nothing credential-shaped reaches the agent", () => {
  it("strips bearer tokens, JWTs and Authorization headers", () => {
    expect(redact("Authorization: Bearer abcdef1234567890")).toContain("[redacted]");
    expect(redact("used Bearer eyJhbGciOiJIUzI1NiJ9.abcdefghijklmnop.sig")).not.toContain("eyJ");
    expect(redact("token eyJhbGciOiJIUzI1NiJ9abcdefghijklmnopqr")).toContain("[redacted-jwt]");
  });

  it("strips GitHub tokens, classic and fine-grained", () => {
    expect(redact("ghp_0123456789abcdefghijABCDEFGHIJ")).toBe("[redacted-github-token]");
    expect(redact("github_pat_0123456789abcdefghij_ABC")).toBe("[redacted-github-token]");
  });

  it("strips connection-string secrets without destroying the rest of the message", () => {
    const redacted = redact(
      "Server=tcp:abc.datawarehouse.fabric.microsoft.com;Database=mls;Password=hunter2hunter2;",
    );
    expect(redacted).not.toContain("hunter2hunter2");
    expect(redacted).toContain("abc.datawarehouse.fabric.microsoft.com");
  });

  it("strips SAS and token query parameters", () => {
    const redacted = redact("https://x.blob.core.windows.net/c/b?sv=2021&sig=AAAsecretAAA&x=1");
    expect(redacted).not.toContain("AAAsecretAAA");
    expect(redacted).toContain("x=1");
  });

  it("strips the App Insights instrumentation key", () => {
    expect(redact("InstrumentationKey=00000000-1111-2222-3333-444444444444;Ingestion")).toContain(
      "InstrumentationKey=[redacted]",
    );
  });

  it("is applied by the AdapterError constructor, not left to callers", () => {
    const error = new AdapterError("auth", "failed with ghp_0123456789abcdefghijABCDEFGHIJ");
    expect(error.message).not.toContain("ghp_0123456789");
  });
});

describe("pagination", () => {
  it("parses a GitHub Link header's rel=next", () => {
    expect(
      parseLinkNext('<https://api.github.com/x?page=2>; rel="next", <https://x?page=9>; rel="last"'),
    ).toBe("https://api.github.com/x?page=2");
    expect(parseLinkNext('<https://x?page=9>; rel="last"')).toBeUndefined();
    expect(parseLinkNext(null)).toBeUndefined();
  });

  it("walks Link-header pages and concatenates them", async () => {
    const mock = new MockFetch()
      .on((url) => url.includes("page=1") || !url.includes("page="), {
        status: 200,
        body: [{ n: 1 }, { n: 2 }],
        headers: { link: '<https://api.x/items?page=2>; rel="next"' },
      })
      .on((url) => url.includes("page=2"), {
        status: 200,
        body: [{ n: 3 }],
        headers: { link: '<https://api.x/items?page=1>; rel="prev"' },
      });
    const items = await pageByLinkHeader<{ n: number }>(
      clientWith(mock),
      { url: "https://api.x/items" },
      100,
    );
    expect(items.map((i) => i.n)).toEqual([1, 2, 3]);
    expect(mock.calls).toHaveLength(2);
  });

  it("stops at the item limit mid-page", async () => {
    const mock = new MockFetch().on(/items/, {
      status: 200,
      body: [{ n: 1 }, { n: 2 }, { n: 3 }],
      headers: { link: '<https://api.x/items?page=2>; rel="next"' },
    });
    const items = await pageByLinkHeader(clientWith(mock), { url: "https://api.x/items" }, 2);
    expect(items).toHaveLength(2);
    expect(mock.calls).toHaveLength(1);
  });

  it("refuses to page forever", async () => {
    const mock = new MockFetch().on(/items/, {
      status: 200,
      body: [{ n: 1 }],
      headers: { link: '<https://api.x/items?page=next>; rel="next"' },
    });
    const items = await pageByLinkHeader(clientWith(mock), { url: "https://api.x/items" }, 10_000);
    expect(mock.calls).toHaveLength(MAX_PAGES);
    expect(items).toHaveLength(MAX_PAGES);
  });

  it("walks ARM nextLink pages", async () => {
    const mock = new MockFetch()
      .on((url) => !url.includes("skipToken"), {
        status: 200,
        body: { value: [{ name: "a" }], nextLink: "https://arm/x?skipToken=2" },
      })
      .on((url) => url.includes("skipToken"), { status: 200, body: { value: [{ name: "b" }] } });
    const items = await pageByNextLink<{ name: string }>(
      clientWith(mock),
      { url: "https://arm/x" },
      100,
    );
    expect(items.map((i) => i.name)).toEqual(["a", "b"]);
  });

  it("treats a missing value array as an empty page", async () => {
    const mock = new MockFetch().on(/arm/, { status: 200, body: {} });
    expect(await pageByNextLink(clientWith(mock), { url: "https://arm/x" }, 10)).toEqual([]);
  });

  it("refuses a page that is not an array where one was promised", async () => {
    const mock = new MockFetch().on(/items/, { status: 200, body: { unexpected: true } });
    const failure = await rejection<AdapterError>(
      pageByLinkHeader(clientWith(mock), { url: "https://api.x/items" }, 10) as Promise<unknown>,
    );
    expect(failure).toBeInstanceOf(AdapterError);
    expect(failure.message).toContain("expected a JSON array page");
  });
});

describe("parseRetryAfter", () => {
  it("reads delta-seconds", () => {
    expect(parseRetryAfter("30", 0)).toBe(30_000);
  });
  it("reads an HTTP-date relative to now", () => {
    const now = Date.UTC(2026, 7, 22, 12, 0, 0);
    expect(parseRetryAfter(new Date(now + 20_000).toUTCString(), now)).toBeLessThanOrEqual(20_000);
  });
  it("returns undefined for absent or unparsable values", () => {
    expect(parseRetryAfter(null, 0)).toBeUndefined();
    expect(parseRetryAfter("soon", 0)).toBeUndefined();
  });
  it("never returns a negative wait for a past date", () => {
    const now = Date.UTC(2026, 7, 22, 12, 0, 0);
    expect(parseRetryAfter(new Date(now - 60_000).toUTCString(), now)).toBe(0);
  });
});

describe("request construction", () => {
  it("sends JSON bodies with a content-type and no body on GET", async () => {
    const mock = new MockFetch().on(/thing/, { status: 200, body: {} });
    const client = clientWith(mock);
    await client.requestJson({ url: URL_UNDER_TEST, method: "POST", body: { query: "x" } });
    await client.requestJson({ url: URL_UNDER_TEST });
    expect(mock.calls[0]?.headers["content-type"]).toBe("application/json");
    expect(mock.calls[0]?.body).toEqual({ query: "x" });
    expect(mock.calls[1]?.rawBody).toBeUndefined();
    expect(mock.calls[1]?.headers["content-type"]).toBeUndefined();
  });

  it("lets a caller's headers win over the defaults", async () => {
    const mock = new MockFetch().on(/thing/, { status: 200, body: {} });
    await clientWith(mock).requestJson({
      url: URL_UNDER_TEST,
      headers: { accept: "application/vnd.github+json" },
    });
    expect(mock.calls[0]?.headers["accept"]).toBe("application/vnd.github+json");
  });

  it("returns the attempt count so retry behaviour is observable to callers", async () => {
    const mock = new MockFetch().on(/thing/, { status: 200, body: { ok: true } });
    const response: HttpJsonResponse<{ ok: boolean }> = await clientWith(mock).requestJson({
      url: URL_UNDER_TEST,
    });
    expect(response.attempts).toBe(1);
    expect(response.status).toBe(200);
  });

  it("aborts an attempt at the configured deadline", async () => {
    vi.useFakeTimers();
    try {
      const mock = new MockFetch().on(/thing/, {
        throws: Object.assign(new Error("aborted"), { name: "AbortError" }),
      });
      const client = clientWith(mock, noSleep, { requestTimeoutMs: 50, maxAttempts: 1 });
      await expect(client.requestJson({ url: URL_UNDER_TEST })).rejects.toThrow(
        /timed out|aborted/i,
      );
    } finally {
      vi.useRealTimers();
    }
  });
});
