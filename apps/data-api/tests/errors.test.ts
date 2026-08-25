/**
 * Guardrail 3, second half: errors are a typed envelope, and nothing that
 * looks like a credential survives the trip to a client or to a log.
 *
 * The specimens below are the shapes this service actually handles — an
 * ADO.NET connection string, an App Insights connection string, an Entra
 * bearer token, a GitHub PAT, a SAS query parameter. Each is fed through the
 * real error path and the real redactor.
 */
import { describe, expect, it, vi } from "vitest";
import { ApiError, redact, toApiError } from "../src/errors.js";
import type { Backends } from "../src/backends/types.js";
import { startServer, testConfig } from "./helpers.js";

const SQL_CONNECTION_STRING =
  "Server=tcp:mls-ops-demo-sql.database.windows.net,1433;Initial Catalog=mls_ops;" +
  "User ID=svc_reader;Password=hunter2-and-then-some;Encrypt=True;";

const APP_INSIGHTS_CONNECTION_STRING =
  "InstrumentationKey=00000000-1111-2222-3333-444444444444;" +
  "IngestionEndpoint=https://eastus-1.in.applicationinsights.azure.com/;";

const BEARER =
  "Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.eyJhdWQiOiJodHRwczovL2RhdGFiYXNlIn0.c2lnbmF0dXJl";

const GITHUB_PAT = "ghp_abcdefghijklmnopqrstuvwxyz0123456789";

const SAS_URL =
  "https://mlsdemo.blob.core.windows.net/exports/cost.csv?sv=2024-11-04&sig=Zm9vYmFyYmF6cXV4";

const SECRETS = [
  "hunter2-and-then-some",
  "00000000-1111-2222-3333-444444444444",
  "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9",
  GITHUB_PAT,
  "Zm9vYmFyYmF6cXV4",
];

describe("redact", () => {
  it("removes the password and catalog from a SQL connection string", () => {
    const scrubbed = redact(SQL_CONNECTION_STRING);
    expect(scrubbed).not.toContain("hunter2-and-then-some");
    expect(scrubbed).not.toContain("svc_reader");
    expect(scrubbed).toContain("Password=<redacted>");
  });

  it("removes the instrumentation key from an App Insights connection string", () => {
    const scrubbed = redact(APP_INSIGHTS_CONNECTION_STRING);
    expect(scrubbed).not.toContain("00000000-1111-2222-3333-444444444444");
    expect(scrubbed).toContain("InstrumentationKey=<redacted>");
  });

  it("removes bearer tokens and bare JWTs", () => {
    expect(redact(`authorization: ${BEARER}`)).toBe("authorization: Bearer <redacted>");
    expect(redact("token eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9abcdefghij")).toContain(
      "<redacted-jwt>",
    );
  });

  it("removes GitHub tokens in every current format", () => {
    expect(redact(`x-access: ${GITHUB_PAT}`)).toContain("<redacted-token>");
    expect(redact("ghs_0123456789abcdefghijklmnop")).toContain("<redacted-token>");
    expect(redact("github_pat_11ABCDEFG0abcdefghijklmnop")).toContain("<redacted-token>");
  });

  it("removes SAS signatures and secret-shaped query parameters", () => {
    const scrubbed = redact(SAS_URL);
    expect(scrubbed).not.toContain("Zm9vYmFyYmF6cXV4");
    expect(scrubbed).toContain("sig=<redacted>");
  });

  it("caps runaway text so one bad error cannot flood the log", () => {
    expect(redact("x".repeat(9000)).length).toBeLessThanOrEqual(2001);
  });

  it("leaves innocent text alone", () => {
    expect(redact("GET /tables/launches returned 0 rows")).toBe(
      "GET /tables/launches returned 0 rows",
    );
  });
});

describe("ApiError", () => {
  it("serialises a stable envelope and never the detail", () => {
    const error = ApiError.upstream("Azure SQL", new Error(SQL_CONNECTION_STRING));
    const body = error.toBody("req-1");
    expect(body).toEqual({
      error: {
        code: "upstream_unavailable",
        message: expect.stringContaining("Azure SQL"),
        status: 502,
        requestId: "req-1",
      },
    });
    expect(JSON.stringify(body)).not.toContain("hunter2-and-then-some");
  });

  it("wraps an unknown throw as an internal error without exposing it", () => {
    const wrapped = toApiError(new Error(BEARER));
    expect(wrapped.code).toBe("internal_error");
    expect(wrapped.status).toBe(500);
    expect(wrapped.message).not.toContain("eyJ");
    // The original survives server-side, for the log.
    expect(wrapped.detail).toContain("Bearer");
  });

  it("passes an ApiError through unchanged", () => {
    const original = ApiError.notFound();
    expect(toApiError(original)).toBe(original);
  });
});

/** A backends double whose every call fails with a credential-bearing error. */
function leakyBackends(thrown: unknown): Backends {
  return {
    kind: "local",
    tables: {
      kind: "local",
      getTable: () => Promise.reject(thrown),
    },
    feeds: {
      kind: "local",
      getFeed: () => Promise.reject(thrown),
    },
    describe: () => ({ tables: "test double" }),
    close: () => Promise.resolve(),
  };
}

describe("the error path end to end", () => {
  it.each([
    ["a raw driver error", new Error(SQL_CONNECTION_STRING)],
    ["an SDK error object", { message: BEARER, config: { url: SAS_URL } }],
    ["a bare string", GITHUB_PAT],
  ])("turns %s into a typed 500 that leaks nothing", async (_label, thrown) => {
    const log = vi.fn();
    const server = await startServer({ backends: leakyBackends(thrown), log });
    try {
      const response = await fetch(`${server.baseUrl}/tables/launches`);
      expect(response.status).toBe(500);

      const text = await response.text();
      for (const secret of SECRETS) expect(text).not.toContain(secret);

      const body = JSON.parse(text) as { error: Record<string, unknown> };
      expect(body.error.code).toBe("internal_error");
      expect(body.error.status).toBe(500);
      expect(typeof body.error.requestId).toBe("string");
      expect(body.error.requestId).toBe(response.headers.get("x-request-id"));
      // No stack, no cause, no detail field — the envelope has four keys.
      expect(Object.keys(body.error).sort()).toEqual([
        "code",
        "message",
        "requestId",
        "status",
      ]);

      // And the log line, which is the one place detail is allowed, is redacted.
      expect(log).toHaveBeenCalledTimes(1);
      const logged = log.mock.calls[0]?.[0] as string;
      for (const secret of SECRETS) expect(logged).not.toContain(secret);
      expect(logged).toContain("requestId=");
    } finally {
      await server.close();
    }
  });

  it("marks error responses uncacheable", async () => {
    const server = await startServer({
      backends: leakyBackends(new Error("boom")),
      log: () => undefined,
    });
    try {
      const response = await fetch(`${server.baseUrl}/tables/launches`);
      expect(response.headers.get("cache-control")).toBe("no-store");
    } finally {
      await server.close();
    }
  });

  it("passes a backend's typed 502 through with its own status", async () => {
    const server = await startServer({
      backends: leakyBackends(ApiError.upstream("GitHub", new Error(GITHUB_PAT))),
      log: () => undefined,
    });
    try {
      const response = await fetch(`${server.baseUrl}/feeds/workflow-runs`);
      expect(response.status).toBe(502);
      const body = (await response.json()) as { error: { code: string; message: string } };
      expect(body.error.code).toBe("upstream_unavailable");
      expect(body.error.message).toContain("GitHub");
      expect(body.error.message).not.toContain(GITHUB_PAT);
    } finally {
      await server.close();
    }
  });

  it("does not log a 4xx that carries no detail", async () => {
    const log = vi.fn();
    const server = await startServer({ config: testConfig(), log });
    try {
      await fetch(`${server.baseUrl}/tables/nope`);
      expect(log).not.toHaveBeenCalled();
    } finally {
      await server.close();
    }
  });
});
