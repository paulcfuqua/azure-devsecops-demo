/**
 * Route behaviour: health, caching, row caps, CORS and the read-only guard.
 * Everything here runs against a real listening server over a real socket.
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { FEED_NAMES, TABLE_NAMES } from "../src/contract/allowlist.js";
import { conditionalGet, startServer, testConfig, type TestServer } from "./helpers.js";

const APP_ORIGIN = "https://mls-launch-ops-demo-ca.example.azurecontainerapps.io";
const OTHER_ORIGIN = "https://mls-control-tower-demo-ca.example.azurecontainerapps.io";
const HOSTILE_ORIGIN = "https://evil.example.com";

let server: TestServer;
let capped: TestServer;

beforeAll(async () => {
  server = await startServer({
    config: testConfig({
      MLS_ALLOWED_ORIGINS: `${APP_ORIGIN}, ${OTHER_ORIGIN}/`,
    }),
  });
  capped = await startServer({ config: testConfig({ MLS_MAX_ROWS: "5" }) });
});

afterAll(async () => {
  await Promise.all([server.close(), capped.close()]);
});

describe("GET /healthz", () => {
  it("reports the live backend selection, the allowlists and the telemetry state", async () => {
    const response = await fetch(`${server.baseUrl}/healthz`);
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");

    const body = (await response.json()) as Record<string, unknown>;
    expect(body.ok).toBe(true);
    expect(body.service).toBe("data-api");
    // The point of the route: which adapter set is actually serving.
    expect(body.mode).toBe("local");
    expect(body.tables).toEqual([...TABLE_NAMES]);
    expect(body.feeds).toEqual([...FEED_NAMES]);
    expect(body.maxRows).toBe(10_000);
    expect(body.telemetry).toEqual({ enabled: false, exporter: "none" });
    expect(body.allowedOrigins).toEqual([APP_ORIGIN, OTHER_ORIGIN]);
    expect(body.sources).toMatchObject({ tables: expect.stringContaining("data/generated") });
  });

  it("never echoes a secret-shaped value", async () => {
    const text = await (await fetch(`${server.baseUrl}/healthz`)).text();
    expect(text).not.toMatch(/password|pwd=|AccountKey|InstrumentationKey|Bearer /i);
  });
});

describe("caching and correlation headers", () => {
  it("marks tables cacheable and revalidatable", async () => {
    const response = await fetch(`${server.baseUrl}/tables/vehicles`);
    expect(response.headers.get("cache-control")).toBe(
      "public, max-age=60, stale-while-revalidate=300",
    );
    expect(response.headers.get("etag")).toBeTruthy();
  });

  it("marks feeds cacheable with a shorter life than tables", async () => {
    const response = await fetch(`${server.baseUrl}/feeds/secure-score`);
    expect(response.headers.get("cache-control")).toBe(
      "public, max-age=30, stale-while-revalidate=150",
    );
  });

  it("answers 304 with no body to a matching conditional request", async () => {
    const first = await fetch(`${server.baseUrl}/tables/pads`);
    const etag = first.headers.get("etag") as string;
    await first.text();

    const revalidated = await conditionalGet(server.baseUrl, "/tables/pads", etag);
    expect(revalidated.status).toBe(304);
    expect(revalidated.length).toBe(0);
  });

  it("answers 200 to a conditional request with a stale validator", async () => {
    const stale = await conditionalGet(server.baseUrl, "/tables/pads", '"stale-etag"');
    expect(stale.status).toBe(200);
    expect(stale.length).toBeGreaterThan(0);
  });

  it("stamps a fresh request id on every response", async () => {
    const first = await fetch(`${server.baseUrl}/healthz`);
    const second = await fetch(`${server.baseUrl}/healthz`);
    const a = first.headers.get("x-request-id") as string;
    const b = second.headers.get("x-request-id") as string;
    expect(a).toMatch(/^[0-9a-f-]{36}$/);
    expect(a).not.toBe(b);
  });

  it("ignores a caller-supplied request id", async () => {
    const response = await fetch(`${server.baseUrl}/healthz`, {
      headers: { "x-request-id": "forged-correlation-id" },
    });
    expect(response.headers.get("x-request-id")).not.toBe("forged-correlation-id");
  });
});

describe("row caps", () => {
  it("caps every table at the configured maximum and says so", async () => {
    const response = await fetch(`${capped.baseUrl}/tables/launches`);
    const rows = (await response.json()) as unknown[];
    expect(rows).toHaveLength(5);
    expect(response.headers.get("x-mls-row-count")).toBe("5");
    expect(response.headers.get("x-mls-row-cap")).toBe("5");
    expect(response.headers.get("x-mls-truncated")).toBe("true");
  });

  it("reports truncated=false when a table fits under the cap", async () => {
    const response = await fetch(`${server.baseUrl}/tables/pads`);
    const rows = (await response.json()) as unknown[];
    expect(response.headers.get("x-mls-truncated")).toBe("false");
    expect(response.headers.get("x-mls-row-count")).toBe(String(rows.length));
  });

  it("honours ?limit below the cap", async () => {
    const response = await fetch(`${server.baseUrl}/tables/launches?limit=3`);
    expect((await response.json()) as unknown[]).toHaveLength(3);
    expect(response.headers.get("x-mls-row-cap")).toBe("3");
  });

  it("clamps ?limit above the cap rather than refusing it", async () => {
    const response = await fetch(`${capped.baseUrl}/tables/launches?limit=100000`);
    expect((await response.json()) as unknown[]).toHaveLength(5);
    expect(response.headers.get("x-mls-row-cap")).toBe("5");
  });

  it.each(["0", "-1", "abc", "1.5", "1e3"])(
    "rejects ?limit=%s as a typed 400",
    async (limit) => {
      const response = await fetch(`${server.baseUrl}/tables/launches?limit=${limit}`);
      expect(response.status).toBe(400);
      const body = (await response.json()) as { error: { code: string } };
      expect(body.error.code).toBe("invalid_request");
    },
  );

  it("rejects a repeated ?limit parameter", async () => {
    const response = await fetch(`${server.baseUrl}/tables/launches?limit=1&limit=2`);
    expect(response.status).toBe(400);
  });
});

describe("CORS", () => {
  it("allows a configured origin and exposes the metadata headers to it", async () => {
    const response = await fetch(`${server.baseUrl}/tables/pads`, {
      headers: { origin: APP_ORIGIN },
    });
    expect(response.headers.get("access-control-allow-origin")).toBe(APP_ORIGIN);
    expect(response.headers.get("access-control-expose-headers")).toContain("X-MLS-Row-Count");
    expect(response.headers.get("vary")).toContain("Origin");
  });

  it("normalises a trailing slash in configuration", async () => {
    const response = await fetch(`${server.baseUrl}/tables/pads`, {
      headers: { origin: OTHER_ORIGIN },
    });
    expect(response.headers.get("access-control-allow-origin")).toBe(OTHER_ORIGIN);
  });

  it("sends no allow-origin to an unlisted origin", async () => {
    const response = await fetch(`${server.baseUrl}/tables/pads`, {
      headers: { origin: HOSTILE_ORIGIN },
    });
    expect(response.headers.get("access-control-allow-origin")).toBeNull();
  });

  it("does not allow a prefix or suffix match of a configured origin", async () => {
    for (const origin of [
      `${APP_ORIGIN}.evil.com`,
      `https://evil.com?${APP_ORIGIN}`,
      APP_ORIGIN.replace("https://", "http://"),
    ]) {
      const response = await fetch(`${server.baseUrl}/tables/pads`, { headers: { origin } });
      expect(response.headers.get("access-control-allow-origin")).toBeNull();
    }
  });

  it("answers a preflight with the read-only method set and no credentials", async () => {
    const response = await fetch(`${server.baseUrl}/tables/pads`, {
      method: "OPTIONS",
      headers: {
        origin: APP_ORIGIN,
        "access-control-request-method": "GET",
      },
    });
    expect(response.status).toBe(204);
    expect(response.headers.get("access-control-allow-methods")).toBe("GET, HEAD, OPTIONS");
    expect(response.headers.get("access-control-allow-credentials")).toBeNull();
  });

  it("permits the trace-context headers the browser SDK adds, and no credential header", async () => {
    // Without these on the preflight, turning on browser telemetry would make
    // every cross-origin API call fail CORS.
    const allowed = (
      await fetch(`${server.baseUrl}/tables/pads`, {
        method: "OPTIONS",
        headers: { origin: APP_ORIGIN, "access-control-request-method": "GET" },
      })
    ).headers.get("access-control-allow-headers") as string;

    for (const header of ["traceparent", "tracestate", "Request-Id", "Request-Context"]) {
      expect(allowed).toContain(header);
    }
    expect(allowed.toLowerCase()).not.toContain("authorization");
    expect(allowed.toLowerCase()).not.toContain("cookie");
  });

  it("always varies on Origin, even with no origin header", async () => {
    const response = await fetch(`${server.baseUrl}/tables/pads`);
    expect(response.headers.get("vary")).toContain("Origin");
  });

  it("defaults to same-origin only when nothing is configured", async () => {
    const bare = await startServer();
    try {
      const response = await fetch(`${bare.baseUrl}/tables/pads`, {
        headers: { origin: APP_ORIGIN },
      });
      expect(response.headers.get("access-control-allow-origin")).toBeNull();
    } finally {
      await bare.close();
    }
  });

  it("refuses a wildcard origin configuration outright", () => {
    expect(() => testConfig({ MLS_ALLOWED_ORIGINS: "*" })).toThrow(/exact origins/);
  });

  it("refuses a non-https origin configuration", () => {
    expect(() => testConfig({ MLS_ALLOWED_ORIGINS: "http://app.example.com" })).toThrow(
      /https/,
    );
  });
});

describe("read-only guard", () => {
  it.each(["POST", "PUT", "PATCH", "DELETE"])("refuses %s with a typed 405", async (method) => {
    const response = await fetch(`${server.baseUrl}/tables/launches`, { method });
    expect(response.status).toBe(405);
    const body = (await response.json()) as { error: { code: string; message: string } };
    expect(body.error.code).toBe("method_not_allowed");
    expect(body.error.message).toContain("read-only");
  });

  it("serves HEAD as the GET headers with no body", async () => {
    const response = await fetch(`${server.baseUrl}/tables/pads`, { method: "HEAD" });
    expect(response.status).toBe(200);
    expect(response.headers.get("x-mls-row-count")).toBeTruthy();
    expect(await response.text()).toBe("");
  });
});

describe("route prefix", () => {
  it("mounts the data routes under MLS_ROUTE_PREFIX, keeping /healthz at the root", async () => {
    // Both ApiProviders default to baseUrl "/api", so this is what makes a
    // same-origin `/api/tables/launches` land when a proxy forwards the
    // prefix intact.
    const prefixed = await startServer({
      config: testConfig({ MLS_ROUTE_PREFIX: "/api/" }),
    });
    try {
      const body = (await (await fetch(`${prefixed.baseUrl}/healthz`)).json()) as {
        routePrefix: string;
      };
      expect(body.routePrefix).toBe("/api");

      const rows = await fetch(`${prefixed.baseUrl}/api/tables/pads`);
      expect(rows.status).toBe(200);
      expect(Array.isArray(await rows.json())).toBe(true);

      const feed = await fetch(`${prefixed.baseUrl}/api/feeds/secure-score`);
      expect(feed.status).toBe(200);

      // And not at the root any more — one mount point, not two.
      expect((await fetch(`${prefixed.baseUrl}/tables/pads`)).status).toBe(404);
    } finally {
      await prefixed.close();
    }
  });

  it("defaults to the root", async () => {
    const body = (await (await fetch(`${server.baseUrl}/healthz`)).json()) as {
      routePrefix: string;
    };
    expect(body.routePrefix).toBe("");
  });

  it.each(["api", "/api/:v", "/api/*", "/api/../admin"])(
    "refuses a malformed prefix %j at boot",
    (prefix) => {
      expect(() => testConfig({ MLS_ROUTE_PREFIX: prefix })).toThrow(/MLS_ROUTE_PREFIX/);
    },
  );

  it.each(["/", "//", "/api/", "/api//"])(
    "normalises %j rather than rejecting it",
    (prefix) => {
      // Trailing slashes are a paste artefact, not a configuration mistake.
      const expected = prefix.replace(/\/+$/, "");
      expect(testConfig({ MLS_ROUTE_PREFIX: prefix }).routePrefix).toBe(expected);
    },
  );
});

describe("unknown routes", () => {
  it.each(["/", "/tables", "/feeds", "/admin", "/tables/launches/1"])(
    "answers %s with a typed 404",
    async (routePath) => {
      const response = await fetch(`${server.baseUrl}${routePath}`);
      expect(response.status).toBe(404);
      const body = (await response.json()) as { error: { code: string } };
      expect(["not_found", "unknown_table", "unknown_feed"]).toContain(body.error.code);
    },
  );

  it("does not advertise the framework", async () => {
    const response = await fetch(`${server.baseUrl}/healthz`);
    expect(response.headers.get("x-powered-by")).toBeNull();
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
  });
});
