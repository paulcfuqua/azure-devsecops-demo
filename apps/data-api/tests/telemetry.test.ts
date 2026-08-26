/**
 * OpenTelemetry: the two states, and the attribute allowlist.
 *
 * The interesting assertion is the negative one. A span is emitted per request
 * and it must carry the route template, the backend mode and the outcome — and
 * must not carry the raw path, the query string, the Origin header, or any
 * upstream error text. The test proves that by sending a request whose every
 * caller-controlled field contains a marker string, exporting the span, and
 * searching the whole serialised span for those markers.
 */
import { trace } from "@opentelemetry/api";
import {
  ExportResultCode,
  type ExportResult,
} from "@opentelemetry/core";
import type { ReadableSpan, SpanExporter } from "@opentelemetry/sdk-trace-base";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import {
  requestAttributes,
  responseAttributes,
  routeTemplate,
  spanName,
} from "../src/telemetry/attributes.js";
import { createAzureMonitorExporter, startTelemetry } from "../src/telemetry/otel.js";
import { startServer, testConfig } from "./helpers.js";

/**
 * A span sink that keeps what it received across `shutdown()`.
 *
 * `InMemorySpanExporter` deliberately resets on shutdown, which makes it
 * useless for asserting on what a *shutdown* exported — exactly the case that
 * matters here, because on Container Apps almost every batch is flushed by a
 * SIGTERM. This one also records the order of flush/shutdown calls, so the
 * regression test below can assert that the flush happens first.
 */
class CapturingExporter implements SpanExporter {
  readonly spans: ReadableSpan[] = [];
  readonly calls: string[] = [];

  export(spans: ReadableSpan[], resultCallback: (result: ExportResult) => void): void {
    this.calls.push("export");
    this.spans.push(...spans);
    resultCallback({ code: ExportResultCode.SUCCESS });
  }

  forceFlush(): Promise<void> {
    this.calls.push("forceFlush");
    return Promise.resolve();
  }

  shutdown(): Promise<void> {
    this.calls.push("shutdown");
    return Promise.resolve();
  }
}

/**
 * Everything an exported span would carry to Azure Monitor, as plain JSON.
 * A live span object holds a back-reference to its processor, so it cannot be
 * stringified directly — and the "no caller text anywhere" assertion needs a
 * string to search.
 */
function snapshot(spans: readonly ReadableSpan[]): string {
  return JSON.stringify(
    spans.map((span) => ({
      name: span.name,
      kind: span.kind,
      attributes: span.attributes,
      status: span.status,
      events: span.events,
      links: span.links,
      resource: span.resource.attributes,
      instrumentationScope: span.instrumentationScope,
    })),
  );
}

afterEach(() => {
  // Unregister any global provider so files/tests do not leak into each other.
  trace.disable();
});

afterAll(() => {
  trace.disable();
});

describe("route templates keep span cardinality bounded", () => {
  it.each([
    ["/healthz", "/healthz"],
    ["/tables/launches", "/tables/:table"],
    ["/tables/anything-at-all", "/tables/:table"],
    ["/tables", "/tables/:table"],
    ["/feeds/secure-score", "/feeds/:name"],
    ["/feeds", "/feeds/:name"],
    ["/", "/*"],
    ["/admin/../etc", "/*"],
  ])("%s -> %s", (pathname, expected) => {
    expect(routeTemplate(pathname)).toBe(expected);
  });

  it("names a span by verb and template, never by the raw path", () => {
    expect(spanName("GET", "/tables/launches")).toBe("GET /tables/:table");
    expect(spanName("GET", "/tables/%2e%2e%2fpasswd")).toBe("GET /tables/:table");
  });
});

describe("request attributes", () => {
  it("records an allowlisted table name", () => {
    expect(
      requestAttributes({
        method: "GET",
        pathname: "/tables/launches",
        backendMode: "local",
      }),
    ).toEqual({
      "http.request.method": "GET",
      "http.route": "/tables/:table",
      "mls.backend_mode": "local",
      "mls.table": "launches",
    });
  });

  it("records an allowlisted feed name", () => {
    expect(
      requestAttributes({
        method: "GET",
        pathname: "/feeds/secure-score",
        backendMode: "cloud",
      })["mls.feed"],
    ).toBe("secure-score");
  });

  it.each([
    "/tables/launches;DROP TABLE launches",
    "/tables/%2e%2e%2f%2e%2e%2fetc%2fpasswd",
    "/feeds/../../secrets",
    "/tables/",
  ])("drops a name that is not on an allowlist: %s", (pathname) => {
    const attributes = requestAttributes({ method: "GET", pathname, backendMode: "local" });
    expect(attributes["mls.table"]).toBeUndefined();
    expect(attributes["mls.feed"]).toBeUndefined();
    // Only the fixed three attributes survive.
    expect(Object.keys(attributes).sort()).toEqual([
      "http.request.method",
      "http.route",
      "mls.backend_mode",
    ]);
  });

  it("records an outcome without an upstream message", () => {
    expect(
      responseAttributes({
        statusCode: 502,
        errorCode: "upstream_unavailable",
        rowCount: 0,
      }),
    ).toEqual({
      "http.response.status_code": 502,
      "mls.row_count": 0,
      "error.type": "upstream_unavailable",
    });
  });
});

describe("startTelemetry", () => {
  it("no-ops cleanly when no connection string is present", async () => {
    const log = vi.fn();
    const telemetry = startTelemetry(
      {
        connectionString: undefined,
        serviceName: "data-api",
        serviceVersion: "0.1.0",
        sampleRatio: 1,
        managedIdentityClientId: undefined,
      },
      { log },
    );
    expect(telemetry.enabled).toBe(false);
    expect(log).toHaveBeenCalledWith(expect.stringContaining("tracing is off"));
    // The global tracer stays the API's no-op, so spans cost nothing.
    const span = trace.getTracer("test").startSpan("x");
    expect(span.isRecording()).toBe(false);
    span.end();
    await expect(telemetry.shutdown()).resolves.toBeUndefined();
    await expect(telemetry.shutdown()).resolves.toBeUndefined();
  });

  it("survives a malformed connection string by turning tracing off, not the service off", () => {
    const log = vi.fn();
    const telemetry = startTelemetry(
      {
        connectionString: "this-is-not-a-connection-string",
        serviceName: "data-api",
        serviceVersion: "0.1.0",
        sampleRatio: 1,
        managedIdentityClientId: undefined,
      },
      { log },
    );
    expect(telemetry.enabled).toBe(false);
    expect(log).toHaveBeenCalledWith(expect.stringContaining("tracing disabled"));
  });

  it("exports one server span per request, with only allowlisted attributes", async () => {
    const exporter = new CapturingExporter();
    const telemetry = startTelemetry(
      {
        connectionString: undefined,
        serviceName: "data-api",
        serviceVersion: "9.9.9",
        sampleRatio: 1,
        managedIdentityClientId: undefined,
      },
      { exporter, log: () => undefined },
    );
    expect(telemetry.enabled).toBe(true);

    const server = await startServer({ config: testConfig(), telemetry });
    const marker = "MARKER-DO-NOT-EXPORT";
    try {
      const response = await fetch(
        `${server.baseUrl}/tables/launches?limit=3&note=${marker}`,
        { headers: { origin: `https://${marker}.example.com`, "user-agent": marker } },
      );
      expect(response.status).toBe(200);
    } finally {
      await server.close();
      // Shutdown flushes the batch processor.
      await telemetry.shutdown();
    }

    const spans = exporter.spans;
    expect(spans).toHaveLength(1);
    const span = spans[0];
    expect(span?.name).toBe("GET /tables/:table");
    expect(span?.attributes).toEqual({
      "http.request.method": "GET",
      "http.route": "/tables/:table",
      "mls.backend_mode": "local",
      "mls.table": "launches",
      "http.response.status_code": 200,
      "mls.row_count": 3,
      "mls.row_cap": 3,
      "mls.truncated": true,
    });
    expect(span?.resource.attributes["service.name"]).toBe("data-api");
    expect(span?.resource.attributes["service.version"]).toBe("9.9.9");

    // Nothing the caller controlled reached the exporter.
    expect(snapshot(spans)).not.toContain(marker);
  });

  it("flushes buffered spans before tearing the exporter down", async () => {
    // Regression guard. `provider.shutdown()` on its own tears the batch
    // processor down WITHOUT exporting what it is holding — so a SIGTERM
    // would silently drop the last batch, which on a scale-to-zero container
    // app is most of them. shutdown() must forceFlush first.
    const exporter = new CapturingExporter();
    const telemetry = startTelemetry(
      {
        connectionString: undefined,
        serviceName: "data-api",
        serviceVersion: "0.1.0",
        sampleRatio: 1,
        managedIdentityClientId: undefined,
      },
      { exporter, log: () => undefined },
    );
    const server = await startServer({ config: testConfig(), telemetry });
    await (await fetch(`${server.baseUrl}/healthz`)).text();
    await server.close();

    await telemetry.shutdown();

    expect(exporter.spans).toHaveLength(1);
    expect(exporter.calls.indexOf("export")).toBeLessThan(
      exporter.calls.indexOf("shutdown"),
    );
  });

  it("keeps route names prefix-independent when mounted under /api", async () => {
    const exporter = new CapturingExporter();
    const telemetry = startTelemetry(
      {
        connectionString: undefined,
        serviceName: "data-api",
        serviceVersion: "0.1.0",
        sampleRatio: 1,
        managedIdentityClientId: undefined,
      },
      { exporter, log: () => undefined },
    );
    const server = await startServer({
      config: testConfig({ MLS_ROUTE_PREFIX: "/api" }),
      telemetry,
    });
    try {
      await (await fetch(`${server.baseUrl}/api/tables/pads`)).text();
    } finally {
      await server.close();
      await telemetry.shutdown();
    }

    // Same span name and same mls.table as an unprefixed deployment: moving
    // the mount point must not fork the App Insights route dimension.
    expect(exporter.spans[0]?.name).toBe("GET /tables/:table");
    expect(exporter.spans[0]?.attributes["mls.table"]).toBe("pads");
  });

  it("continues the browser's trace when W3C trace context arrives", async () => {
    // End-to-end correlation: the frontends' App Insights SDK sends
    // `traceparent` on API calls, and the server span must join that trace
    // rather than starting a new root — otherwise the demo's "click to SQL"
    // transaction view is two disconnected halves.
    const exporter = new CapturingExporter();
    const telemetry = startTelemetry(
      {
        connectionString: undefined,
        serviceName: "data-api",
        serviceVersion: "0.1.0",
        sampleRatio: 1,
        managedIdentityClientId: undefined,
      },
      { exporter, log: () => undefined },
    );
    const server = await startServer({ config: testConfig(), telemetry });
    const traceId = "4bf92f3577b34da6a3ce929d0e0e4736";
    const parentSpanId = "00f067aa0ba902b7";
    try {
      await (
        await fetch(`${server.baseUrl}/tables/pads`, {
          headers: { traceparent: `00-${traceId}-${parentSpanId}-01` },
        })
      ).text();
    } finally {
      await server.close();
      await telemetry.shutdown();
    }

    const span = exporter.spans[0];
    expect(span?.spanContext().traceId).toBe(traceId);
    expect(span?.parentSpanContext?.spanId).toBe(parentSpanId);
  });

  it("starts a new root trace when the traceparent is malformed", async () => {
    const exporter = new CapturingExporter();
    const telemetry = startTelemetry(
      {
        connectionString: undefined,
        serviceName: "data-api",
        serviceVersion: "0.1.0",
        sampleRatio: 1,
        managedIdentityClientId: undefined,
      },
      { exporter, log: () => undefined },
    );
    const server = await startServer({ config: testConfig(), telemetry });
    try {
      await (
        await fetch(`${server.baseUrl}/tables/pads`, {
          headers: { traceparent: "not-a-trace-context" },
        })
      ).text();
    } finally {
      await server.close();
      await telemetry.shutdown();
    }

    const span = exporter.spans[0];
    expect(span?.spanContext().traceId).toMatch(/^[0-9a-f]{32}$/);
    expect(span?.parentSpanContext).toBeUndefined();
  });

  it("marks 5xx as an error span and 4xx as ordinary", async () => {
    const exporter = new CapturingExporter();
    const telemetry = startTelemetry(
      {
        connectionString: undefined,
        serviceName: "data-api",
        serviceVersion: "0.1.0",
        sampleRatio: 1,
        managedIdentityClientId: undefined,
      },
      { exporter, log: () => undefined },
    );
    const server = await startServer({
      config: testConfig(),
      telemetry,
      backends: {
        kind: "local",
        tables: { kind: "local", getTable: () => Promise.reject(new Error("boom")) },
        feeds: { kind: "local", getFeed: () => Promise.reject(new Error("boom")) },
        describe: () => ({}),
        close: () => Promise.resolve(),
      },
      log: () => undefined,
    });
    try {
      await fetch(`${server.baseUrl}/tables/nope`); // 404
      await fetch(`${server.baseUrl}/tables/launches`); // 500
    } finally {
      await server.close();
      await telemetry.shutdown();
    }

    const spans = exporter.spans;
    expect(spans).toHaveLength(2);
    const notFound = spans.find((s) => s.attributes["http.response.status_code"] === 404);
    const failed = spans.find((s) => s.attributes["http.response.status_code"] === 500);
    // SpanStatusCode.UNSET === 0, ERROR === 2.
    expect(notFound?.status.code).toBe(0);
    expect(notFound?.attributes["error.type"]).toBe("unknown_table");
    expect(failed?.status.code).toBe(2);
    expect(failed?.attributes["error.type"]).toBe("internal_error");
    // The thrown message never becomes an attribute.
    expect(snapshot(spans)).not.toContain("boom");
  });

  it("reports the tracing state on /healthz", async () => {
    const exporter = new CapturingExporter();
    const telemetry = startTelemetry(
      {
        connectionString: undefined,
        serviceName: "data-api",
        serviceVersion: "0.1.0",
        sampleRatio: 1,
        managedIdentityClientId: undefined,
      },
      { exporter, log: () => undefined },
    );
    const server = await startServer({ config: testConfig(), telemetry });
    try {
      const body = (await (await fetch(`${server.baseUrl}/healthz`)).json()) as {
        telemetry: unknown;
      };
      expect(body.telemetry).toEqual({ enabled: true, exporter: "azure-monitor" });
    } finally {
      await server.close();
      await telemetry.shutdown();
    }
  });
});

describe("createAzureMonitorExporter — Microsoft Entra ID wiring (F4, Task 8)", () => {
  // platform/main.bicep now sets disableLocalAuth:true on the App Insights
  // component, so the exporter must present a credential or ingestion is
  // refused. These assert the option AzureMonitorTraceExporter actually
  // receives, at the function boundary, so no test here talks to
  // @azure/identity or an ingestion endpoint for real.
  // AzureMonitorTraceExporter (export/trace.js) forwards its constructor
  // options to an internal `HttpSender` (platform/nodejs/httpSender.js) as
  // `this.sender.appInsightsClientOptions` — that is the object the sender
  // checks `if (this.appInsightsClientOptions.credential)` against before it
  // will attach an AAD bearer token, so it is what these assert against.
  type ExporterInternals = { sender: { appInsightsClientOptions?: { credential?: unknown } } };

  it("passes no credential option when none is given", () => {
    const exporter = createAzureMonitorExporter(
      "InstrumentationKey=11111111-2222-3333-4444-555555555555",
    ) as unknown as ExporterInternals;
    expect(exporter.sender.appInsightsClientOptions?.credential).toBeUndefined();
  });

  it("passes the given credential through to the exporter", () => {
    const fakeCredential = { getToken: async () => null };
    const exporter = createAzureMonitorExporter(
      "InstrumentationKey=11111111-2222-3333-4444-555555555555",
      fakeCredential as never,
    ) as unknown as ExporterInternals;
    expect(exporter.sender.appInsightsClientOptions?.credential).toBe(fakeCredential);
  });
});
