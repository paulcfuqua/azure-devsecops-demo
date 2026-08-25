/**
 * OpenTelemetry instrumentation.
 *
 * Two things are being proven here, and the second matters more than the first:
 *
 *   1. A tool call produces one span and the matching metrics, carrying the
 *      tool name, backend mode, SQL dialect, row count and duration.
 *   2. **It carries nothing else.** Span attributes leave the process and land
 *      in a queryable store. A lakehouse query is business data; a KQL query can
 *      name internal systems; a tool argument can be anything. The test that
 *      asserts the SQL text is absent is the point of this file.
 *
 * The provider here is a hand-rolled in-memory double registered through
 * `@opentelemetry/api`'s global registration — the same door `useAzureMonitor`
 * goes through in production — so this exercises the real instrumentation code
 * path with no exporter and no SDK.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  context,
  metrics,
  trace,
  type Attributes,
  type Context,
  type Span,
  type SpanOptions,
  type Tracer,
} from "@opentelemetry/api";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import {
  ALLOWED_SPAN_ATTRIBUTES,
  assertSafeAttributes,
  initTelemetry,
  resetTelemetryForTests,
  telemetryStatus,
  withToolSpan,
} from "../src/telemetry.js";
import { createMcpServer } from "../src/mcp/server.js";
import { createLocalBackends } from "../src/tools/backends.js";
import { ToolRegistry } from "../src/tools/index.js";

/* ------------------------------------------------------------------ */
/* In-memory OTel doubles                                              */
/* ------------------------------------------------------------------ */

interface RecordedSpan {
  name: string;
  attributes: Attributes;
  status?: { code: number; message?: string };
  ended: boolean;
}

interface RecordedMetric {
  instrument: string;
  value: number;
  attributes: Attributes;
}

const spans: RecordedSpan[] = [];
const measurements: RecordedMetric[] = [];

/** Syntactically valid, entirely fictional — it is never given to a real exporter. */
const CONNECTION_STRING =
  "InstrumentationKey=11111111-2222-3333-4444-555555555555;" +
  "IngestionEndpoint=https://eastus-0.in.applicationinsights.azure.invalid/";

function fakeSpan(record: RecordedSpan): Span {
  const span = {
    setAttribute(key: string, value: unknown) {
      record.attributes[key] = value as never;
      return span;
    },
    setAttributes(attributes: Attributes) {
      Object.assign(record.attributes, attributes);
      return span;
    },
    setStatus(status: { code: number; message?: string }) {
      record.status = status;
      return span;
    },
    end() {
      record.ended = true;
    },
    addEvent: () => span,
    addLink: () => span,
    addLinks: () => span,
    recordException: () => undefined,
    updateName: () => span,
    isRecording: () => true,
    spanContext: () => ({ traceId: "0".repeat(32), spanId: "0".repeat(16), traceFlags: 1 }),
  };
  return span as unknown as Span;
}

const fakeTracer: Tracer = {
  startSpan(name: string, options?: SpanOptions) {
    const record: RecordedSpan = { name, attributes: { ...(options?.attributes ?? {}) }, ended: false };
    spans.push(record);
    return fakeSpan(record);
  },
  startActiveSpan(name: string, ...rest: unknown[]) {
    const options = (typeof rest[0] === "object" ? rest[0] : undefined) as SpanOptions | undefined;
    const fn = rest.find((r) => typeof r === "function") as (span: Span) => unknown;
    const record: RecordedSpan = { name, attributes: { ...(options?.attributes ?? {}) }, ended: false };
    spans.push(record);
    return fn(fakeSpan(record));
  },
} as unknown as Tracer;

function instrument(name: string) {
  return {
    add(value: number, attributes: Attributes = {}) {
      measurements.push({ instrument: name, value, attributes });
    },
    record(value: number, attributes: Attributes = {}) {
      measurements.push({ instrument: name, value, attributes });
    },
  };
}

const fakeMeterProvider = {
  getMeter: () => ({
    createCounter: (name: string) => instrument(name),
    createHistogram: (name: string) => instrument(name),
    createUpDownCounter: (name: string) => instrument(name),
    createObservableGauge: () => ({ addCallback() {}, removeCallback() {} }),
    createObservableCounter: () => ({ addCallback() {}, removeCallback() {} }),
    createObservableUpDownCounter: () => ({ addCallback() {}, removeCallback() {} }),
    addBatchObservableCallback() {},
    removeBatchObservableCallback() {},
  }),
};

const fakeTracerProvider = { getTracer: () => fakeTracer };

beforeEach(() => {
  spans.length = 0;
  measurements.length = 0;
  trace.setGlobalTracerProvider(fakeTracerProvider as never);
  metrics.setGlobalMeterProvider(fakeMeterProvider as never);
  resetTelemetryForTests();
});

afterEach(() => {
  trace.disable();
  metrics.disable();
  resetTelemetryForTests();
});

/* ------------------------------------------------------------------ */

describe("withToolSpan", () => {
  it("opens one span per tool call, named for the tool", async () => {
    await withToolSpan({ toolName: "get_cost_series", backendMode: "cloud", sqlDialect: "tsql" }, async () => ({
      value: "ok",
      rowCount: 42,
    }));
    expect(spans).toHaveLength(1);
    expect(spans[0]?.name).toBe("mcp.tool/get_cost_series");
    expect(spans[0]?.ended).toBe(true);
  });

  it("carries tool name, backend mode, dialect, row count and duration", async () => {
    await withToolSpan(
      { toolName: "query_lakehouse_sql", backendMode: "cloud", sqlDialect: "tsql" },
      async () => ({ value: "ok", rowCount: 309, truncated: false }),
    );
    const attributes = spans[0]!.attributes;
    expect(attributes["mls.tool.name"]).toBe("query_lakehouse_sql");
    expect(attributes["mls.backend.mode"]).toBe("cloud");
    expect(attributes["mls.sql.dialect"]).toBe("tsql");
    expect(attributes["mls.tool.row_count"]).toBe(309);
    expect(attributes["mls.tool.truncated"]).toBe(false);
    expect(attributes["mls.tool.outcome"]).toBe("ok");
    expect(typeof attributes["mls.tool.duration_ms"]).toBe("number");
  });

  it("records a call counter, a duration histogram and a row histogram", async () => {
    await withToolSpan(
      { toolName: "get_defender_posture", backendMode: "local", sqlDialect: "sqlite" },
      async () => ({ value: "ok", rowCount: 5 }),
    );
    const names = measurements.map((m) => m.instrument);
    expect(names).toContain("mls.mcp.tool.calls");
    expect(names).toContain("mls.mcp.tool.duration");
    expect(names).toContain("mls.mcp.tool.rows");
    const calls = measurements.find((m) => m.instrument === "mls.mcp.tool.calls")!;
    expect(calls.value).toBe(1);
    expect(calls.attributes["mls.tool.name"]).toBe("get_defender_posture");
    expect(calls.attributes["mls.tool.outcome"]).toBe("ok");
  });

  it("marks an adapter failure with its KIND and never its message", async () => {
    await withToolSpan(
      { toolName: "query_log_analytics", backendMode: "cloud", sqlDialect: "tsql" },
      async () => ({ value: "error-result", errorKind: "throttled" }),
    );
    expect(spans[0]?.attributes["mls.error.kind"]).toBe("throttled");
    expect(spans[0]?.attributes["mls.tool.outcome"]).toBe("error");
    // The status description is the kind, not the upstream's text.
    expect(spans[0]?.status?.message).toBe("throttled");
  });

  it("still ends the span and records metrics when the callback throws", async () => {
    const boom = Object.assign(new Error("upstream exploded"), { kind: "upstream" });
    await expect(
      withToolSpan({ toolName: "get_cost_series", backendMode: "cloud", sqlDialect: "tsql" }, async () => {
        throw boom;
      }),
    ).rejects.toThrow("upstream exploded");
    expect(spans[0]?.ended).toBe(true);
    expect(spans[0]?.attributes["mls.error.kind"]).toBe("upstream");
    expect(spans[0]?.attributes["mls.tool.outcome"]).toBe("error");
    expect(measurements.some((m) => m.instrument === "mls.mcp.tool.calls")).toBe(true);
  });
});

describe("span attributes are an allowlist, not a convention", () => {
  it("assertSafeAttributes drops anything off the allowlist", () => {
    const filtered = assertSafeAttributes({
      "mls.tool.name": "query_lakehouse_sql",
      "mls.sql.text": "SELECT * FROM launches",
      "db.statement": "SELECT * FROM launches",
      "mls.tool.arguments": "{}",
    } as Attributes);
    expect(filtered).toEqual({ "mls.tool.name": "query_lakehouse_sql" });
  });

  it("the allowlist is exactly this set, so adding to it needs a deliberate edit here", () => {
    // Every entry below is either an enum, a boolean or a number. None can hold
    // free text, which is the property that makes shipping them to a queryable
    // store acceptable. `mls.sql.dialect` is the two-value enum sqlite|tsql.
    expect([...ALLOWED_SPAN_ATTRIBUTES].sort()).toEqual([
      "mls.backend.mode",
      "mls.error.kind",
      "mls.sql.dialect",
      "mls.tool.duration_ms",
      "mls.tool.name",
      "mls.tool.outcome",
      "mls.tool.row_count",
      "mls.tool.truncated",
    ]);
  });

  it("no allowlisted key is a free-text carrier", () => {
    for (const key of ALLOWED_SPAN_ATTRIBUTES) {
      expect(key).not.toMatch(/text|statement|body|argument|param|token|secret|payload|content/i);
    }
  });
});

describe("the SQL text never reaches telemetry — end to end through MCP", () => {
  const SECRET_ISH_SQL =
    "SELECT customer, insurance_value_musd FROM launches WHERE customer = 'Aurora Dynamics'";

  async function callThroughMcp(name: string, args: Record<string, unknown>): Promise<void> {
    const registry = new ToolRegistry(createLocalBackends());
    const server = createMcpServer(registry, { backendMode: "local" });
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: "telemetry-test", version: "0.0.0" });
    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
    await client.callTool({ name, arguments: args });
    await client.close();
  }

  it("records the row count but not one character of the statement", async () => {
    await callThroughMcp("query_lakehouse_sql", { sql: SECRET_ISH_SQL });

    expect(spans).toHaveLength(1);
    const serialised = JSON.stringify(spans[0]);
    expect(serialised).not.toContain("SELECT");
    expect(serialised).not.toContain("Aurora Dynamics");
    expect(serialised).not.toContain("insurance_value_musd");
    // …while still being useful.
    expect(spans[0]?.attributes["mls.tool.name"]).toBe("query_lakehouse_sql");
    expect(typeof spans[0]?.attributes["mls.tool.row_count"]).toBe("number");
    expect(spans[0]?.attributes["mls.sql.dialect"]).toBe("sqlite");
  });

  it("records the KQL query's row count but not the KQL", async () => {
    await callThroughMcp("query_log_analytics", {
      query: "AppRequests | where AppRoleName == 'mls-launch-ops' | take 5",
    });
    const serialised = JSON.stringify(spans[0]);
    expect(serialised).not.toContain("AppRequests");
    expect(serialised).not.toContain("mls-launch-ops");
    expect(spans[0]?.attributes["mls.tool.row_count"]).toBe(10);
  });

  it("records the cost filter's row count but not the cost center argument", async () => {
    await callThroughMcp("get_cost_series", { cost_center: "Propulsion" });
    expect(JSON.stringify(spans[0])).not.toContain("Propulsion");
    expect(spans[0]?.attributes["mls.tool.name"]).toBe("get_cost_series");
  });

  it("a rejected SQL statement is recorded as an error kind, with no statement", async () => {
    await callThroughMcp("query_lakehouse_sql", { sql: "DROP TABLE launches" });
    expect(spans[0]?.attributes["mls.tool.outcome"]).toBe("error");
    expect(JSON.stringify(spans[0])).not.toContain("DROP");
  });

  it("opens no span at all for a name off the allowlist", async () => {
    await callThroughMcp("delete_everything", {});
    // An unknown tool name is not a tool call to measure — and its name is
    // attacker-controlled text that has no business becoming a span name.
    expect(spans).toHaveLength(0);
  });

  it("propagates the backend mode onto the span", async () => {
    const registry = new ToolRegistry(createLocalBackends());
    const server = createMcpServer(registry, { backendMode: "cloud" });
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: "telemetry-test", version: "0.0.0" });
    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
    await client.callTool({ name: "get_defender_posture", arguments: {} });
    await client.close();
    expect(spans[0]?.attributes["mls.backend.mode"]).toBe("cloud");
  });
});

describe("initTelemetry", () => {
  it("no-ops cleanly with no connection string, and says why", async () => {
    const status = await initTelemetry({} as NodeJS.ProcessEnv);
    expect(status.enabled).toBe(false);
    expect(status.exporter).toBe("disabled");
    expect(status.reason).toMatch(/APPLICATIONINSIGHTS_CONNECTION_STRING/);
    expect(telemetryStatus()).toEqual(status);
  });

  it("treats a blank connection string as absent rather than as a broken one", async () => {
    const status = await initTelemetry({
      APPLICATIONINSIGHTS_CONNECTION_STRING: "   ",
    } as NodeJS.ProcessEnv);
    expect(status.enabled).toBe(false);
    expect(status.exporter).toBe("disabled");
  });

  it("registers the Azure Monitor distro when a connection string is present", async () => {
    // The distro loader is injected: no test in this suite may start a real
    // exporter or attempt an egress to an ingestion endpoint.
    const seen: any[] = [];
    const status = await initTelemetry(
      {
        APPLICATIONINSIGHTS_CONNECTION_STRING: CONNECTION_STRING,
        MLS_SERVICE_NAME: "mls-mcp-tools",
      } as NodeJS.ProcessEnv,
      { load: async () => ({ useAzureMonitor: (options) => seen.push(options) }) },
    );
    expect(status).toEqual({ enabled: true, exporter: "azure-monitor" });
    expect(seen).toHaveLength(1);
    expect(seen[0].azureMonitorExporterOptions.connectionString).toBe(CONNECTION_STRING);
    expect(seen[0].resource.attributes["service.name"]).toBe("mls-mcp-tools");
  });

  it("keeps serving when the exporter fails to start, and never echoes the key", async () => {
    // A malformed connection string must degrade to "no traces", never to
    // "no tool server" — the agent losing its tools is the worse outcome.
    const status = await initTelemetry(
      { APPLICATIONINSIGHTS_CONNECTION_STRING: CONNECTION_STRING } as NodeJS.ProcessEnv,
      {
        load: async () => {
          throw new Error(`invalid connection string: ${CONNECTION_STRING}`);
        },
      },
    );
    expect(status.enabled).toBe(false);
    expect(status.exporter).toBe("failed");
    expect(status.reason).toContain("failed to start");
    // The distro loves to quote the connection string back at you.
    expect(status.reason).not.toContain("11111111-2222-3333-4444-555555555555");
    expect(status.reason).toContain("[redacted]");
  });

  it("reports a load failure to /healthz without exposing the reason there", async () => {
    // /healthz is unauthenticated at the ingress; app.ts exposes enabled +
    // exporter only, never `reason`.
    await initTelemetry(
      { APPLICATIONINSIGHTS_CONNECTION_STRING: CONNECTION_STRING } as NodeJS.ProcessEnv,
      { load: async () => { throw new Error("nope"); } },
    );
    expect(telemetryStatus().exporter).toBe("failed");
  });

  it("tool calls keep working whether or not telemetry is registered", async () => {
    trace.disable();
    metrics.disable();
    resetTelemetryForTests();
    // With no provider registered, @opentelemetry/api hands back non-recording
    // spans and no-op instruments. The call must be unaffected.
    const value = await withToolSpan(
      { toolName: "get_cost_series", backendMode: "local", sqlDialect: "sqlite" },
      async () => ({ value: 42, rowCount: 1 }),
    );
    expect(value).toBe(42);
  });
});

describe("context plumbing", () => {
  it("uses startActiveSpan so the span is the active context for the adapter call", async () => {
    // Adapters make HTTP calls; auto-instrumentation only nests them under the
    // tool span if the tool span is ACTIVE, not merely started.
    let sawActiveContext: Context | undefined;
    await withToolSpan(
      { toolName: "get_cost_series", backendMode: "cloud", sqlDialect: "tsql" },
      async () => {
        sawActiveContext = context.active();
        return { value: "ok" };
      },
    );
    expect(sawActiveContext).toBeDefined();
    expect(spans).toHaveLength(1);
  });
});
