/**
 * OpenTelemetry for the MCP tool server — traces + metrics, exported to Azure
 * Monitor / Application Insights when a connection string is present, and a
 * clean no-op when it is not.
 *
 * WHY: principle #5 is "Microsoft-native and standards-based", and the L6/L7
 * runbooks promise spans in App Insights. Nothing in this service emitted any.
 * A tool call that takes 9 seconds against Fabric is invisible today, and V8.5's
 * p95 < 20 s can only be measured from the eval harness's own stopwatch — which
 * measures the whole Direct Line round trip and cannot attribute it. One span
 * per tool call fixes both.
 *
 * NO-OP BY DEFAULT, DELIBERATELY. `@opentelemetry/api` returns non-recording
 * spans and no-op instruments until a provider is registered, so on a laptop
 * with no connection string this file costs a few object allocations per call
 * and emits nothing. `@azure/monitor-opentelemetry` is imported LAZILY and only
 * when `APPLICATIONINSIGHTS_CONNECTION_STRING` is set, so the local path never
 * loads the Azure Monitor exporter at all.
 *
 * ── What a span may carry, and what it may never carry ──────────────────────
 * ALLOWED:  tool name, backend mode, SQL dialect, row count, truncation flag,
 *           outcome, error KIND, duration.
 * FORBIDDEN: the SQL text, the KQL text, any tool argument value, any result
 *           cell, any token, any connection string. Span attributes leave the
 *           process and land in a queryable store; a lakehouse query is business
 *           data and a KQL query can name internal systems. `assertSafeAttributes`
 *           below is enforced by a unit test, not just by convention.
 */
import {
  metrics,
  SpanStatusCode,
  trace,
  ValueType,
  type Attributes,
  type Histogram,
  type Counter,
  type Span,
  type Tracer,
} from "@opentelemetry/api";
import type { BackendMode } from "./config.js";
import { createDefaultCredential, type TokenCredentialLike } from "./tools/auth.js";
import { redact } from "./tools/errors.js";
import type { SqlDialect } from "./tools/sql-dialect.js";

export const TELEMETRY_SCOPE = "mls-mcp-tools";
export const TELEMETRY_VERSION = "0.1.0";

/** Attribute keys this service is allowed to set. Anything else is a defect. */
export const ALLOWED_SPAN_ATTRIBUTES = [
  "mls.tool.name",
  "mls.tool.outcome",
  "mls.tool.row_count",
  "mls.tool.truncated",
  "mls.tool.duration_ms",
  "mls.backend.mode",
  "mls.sql.dialect",
  "mls.error.kind",
] as const;

export type AllowedSpanAttribute = (typeof ALLOWED_SPAN_ATTRIBUTES)[number];

/**
 * Guard rail with teeth: every attribute set on a tool span goes through here.
 * Keys outside the allowlist are dropped rather than thrown, because losing a
 * span attribute must never fail a tool call — but the unit test asserts the
 * allowlist matches what the code sets, so drift is caught at test time.
 */
export function assertSafeAttributes(attributes: Attributes): Attributes {
  const safe: Attributes = {};
  for (const [key, value] of Object.entries(attributes)) {
    if ((ALLOWED_SPAN_ATTRIBUTES as readonly string[]).includes(key)) safe[key] = value;
  }
  return safe;
}

export interface ToolSpanInput {
  toolName: string;
  backendMode: BackendMode;
  sqlDialect: SqlDialect;
}

export interface ToolSpanOutcome {
  /** Rows the tool returned, when the shape has a row concept. */
  rowCount?: number;
  /** True when the 500-row cap trimmed the result. */
  truncated?: boolean;
  /** Present only on failure — the AdapterError kind, never the message. */
  errorKind?: string;
}

interface Instruments {
  tracer: Tracer;
  calls: Counter;
  duration: Histogram;
  rows: Histogram;
}

let instruments: Instruments | undefined;

function getInstruments(): Instruments {
  if (!instruments) {
    const meter = metrics.getMeter(TELEMETRY_SCOPE, TELEMETRY_VERSION);
    instruments = {
      tracer: trace.getTracer(TELEMETRY_SCOPE, TELEMETRY_VERSION),
      calls: meter.createCounter("mls.mcp.tool.calls", {
        description: "MCP tool calls, by tool, backend mode and outcome",
      }),
      duration: meter.createHistogram("mls.mcp.tool.duration", {
        description: "MCP tool call duration",
        unit: "ms",
        valueType: ValueType.DOUBLE,
      }),
      rows: meter.createHistogram("mls.mcp.tool.rows", {
        description: "Rows returned by an MCP tool call",
        unit: "{row}",
        valueType: ValueType.INT,
      }),
    };
  }
  return instruments;
}

/** Test seam: forget the cached instruments so a newly registered provider is picked up. */
export function resetTelemetryForTests(): void {
  instruments = undefined;
}

/**
 * Run one tool call inside a span, recording the metrics that go with it.
 *
 * The span name is `mcp.tool/<name>` so App Insights groups by tool without a
 * custom query, and the tool name is also an attribute so the metrics and the
 * traces can be joined. Duration is the span's own; it is ALSO recorded as an
 * explicit `mls.tool.duration_ms` attribute because App Insights' dependency
 * duration is rounded and the p95 assertion (V8.5) wants the raw number.
 */
export async function withToolSpan<T>(
  input: ToolSpanInput,
  fn: (span: Span) => Promise<{ value: T } & ToolSpanOutcome>,
): Promise<T> {
  const { tracer, calls, duration, rows } = getInstruments();
  const baseAttributes: Attributes = assertSafeAttributes({
    "mls.tool.name": input.toolName,
    "mls.backend.mode": input.backendMode,
    "mls.sql.dialect": input.sqlDialect,
  });

  return tracer.startActiveSpan(
    `mcp.tool/${input.toolName}`,
    { attributes: baseAttributes },
    async (span) => {
      const startedAt = performance.now();
      let outcome = "ok";
      let errorKind: string | undefined;
      try {
        const result = await fn(span);
        span.setAttributes(
          assertSafeAttributes({
            ...(result.rowCount === undefined ? {} : { "mls.tool.row_count": result.rowCount }),
            ...(result.truncated === undefined ? {} : { "mls.tool.truncated": result.truncated }),
            ...(result.errorKind === undefined ? {} : { "mls.error.kind": result.errorKind }),
          }),
        );
        if (result.errorKind !== undefined) {
          outcome = "error";
          errorKind = result.errorKind;
          // Status description is the KIND, never the upstream message.
          span.setStatus({ code: SpanStatusCode.ERROR, message: result.errorKind });
        }
        if (typeof result.rowCount === "number") {
          rows.record(result.rowCount, { ...baseAttributes });
        }
        return result.value;
      } catch (err) {
        outcome = "error";
        errorKind = (err as { kind?: string })?.kind ?? "unhandled";
        span.setStatus({ code: SpanStatusCode.ERROR, message: errorKind });
        span.setAttributes(assertSafeAttributes({ "mls.error.kind": errorKind }));
        throw err;
      } finally {
        const elapsed = performance.now() - startedAt;
        span.setAttributes(
          assertSafeAttributes({ "mls.tool.outcome": outcome, "mls.tool.duration_ms": elapsed }),
        );
        const metricAttributes: Attributes = { ...baseAttributes, "mls.tool.outcome": outcome };
        if (errorKind !== undefined) metricAttributes["mls.error.kind"] = errorKind;
        calls.add(1, metricAttributes);
        duration.record(elapsed, metricAttributes);
        span.end();
      }
    },
  );
}

/* ------------------------------------------------------------------ */
/* Azure Monitor wiring                                                */
/* ------------------------------------------------------------------ */

export interface TelemetryStatus {
  /** True when an exporter was actually registered. */
  enabled: boolean;
  /** "azure-monitor" | "disabled" | "failed" — surfaced on /healthz. */
  exporter: "azure-monitor" | "disabled" | "failed";
  /** Human-readable reason when not enabled. Never contains the connection string. */
  reason?: string;
}

let status: TelemetryStatus = { enabled: false, exporter: "disabled", reason: "not initialised" };

export function telemetryStatus(): TelemetryStatus {
  return status;
}

/**
 * Register the Azure Monitor OpenTelemetry distro when a connection string is
 * configured. Called once at boot, before the HTTP server starts.
 *
 * Failure is NON-FATAL and explicitly so: an unreachable or malformed
 * Application Insights resource must not take the tool server down — the agent
 * losing its tools is a worse outcome than losing the traces. The failure is
 * reported on `/healthz` so it is still visible.
 *
 * SECURITY: the connection string carries an InstrumentationKey and an ingestion
 * endpoint. It is read from the environment, handed straight to the distro, and
 * never logged, never echoed on /healthz, and never put in an error message.
 *
 * MICROSOFT ENTRA ID INGESTION (F4, Task 8). The platform App Insights
 * component now has `disableLocalAuth: true` (infra/bicep/platform/main.bicep),
 * so the instrumentation key in the connection string above is no longer
 * enough to authorise ingestion — the exporter must also present a Microsoft
 * Entra ID token. `@azure/monitor-opentelemetry-exporter`'s HTTP sender only
 * attaches one when a `credential` is supplied (see the module's
 * platform/nodejs/httpSender.js: `if (this.appInsightsClientOptions.credential)`),
 * so a `disableLocalAuth` flip with no matching `credential` here would
 * silently stop all telemetry from this service. `AZURE_CLIENT_ID` gates it:
 * set, it selects the user-assigned identity the Bicep template grants
 * 'Monitoring Metrics Publisher' (infra/bicep/apps/main.bicep, module
 * mcpAppInsightsGrant) via `createDefaultCredential` — the same helper
 * `tools/cloud/index.ts` already uses for the SQL/Fabric/Cost Management
 * adapters. Unset (a laptop with no managed identity), no credential is
 * built at all: `DefaultAzureCredential` with no `managedIdentityClientId`
 * would otherwise fall through to an ambient `az login` / VS Code session,
 * which is not a choice telemetry should be making on a developer machine
 * that has no connection string to send to anyway.
 */
/** The distro's one entry point, as a type so the loader can be injected. */
export interface AzureMonitorModule {
  useAzureMonitor: (options?: unknown) => void;
}

export interface InitTelemetryDeps {
  /**
   * Test seam. Production uses a dynamic import of `@azure/monitor-opentelemetry`;
   * the unit tests inject a double so no test can ever start a real exporter or
   * attempt an egress to an ingestion endpoint.
   */
  load?: () => Promise<AzureMonitorModule>;
  /**
   * Test seam for the Microsoft Entra ID credential. Production gets a
   * `DefaultAzureCredential` via `createDefaultCredential` (only when
   * `AZURE_CLIENT_ID` is set); tests inject a double so constructing it never
   * touches `@azure/identity` for real.
   */
  credential?: TokenCredentialLike;
}

export async function initTelemetry(
  env: NodeJS.ProcessEnv = process.env,
  deps: InitTelemetryDeps = {},
): Promise<TelemetryStatus> {
  const connectionString = env.APPLICATIONINSIGHTS_CONNECTION_STRING?.trim();
  if (!connectionString) {
    status = {
      enabled: false,
      exporter: "disabled",
      reason: "APPLICATIONINSIGHTS_CONNECTION_STRING is not set",
    };
    return status;
  }
  try {
    const load =
      deps.load ??
      (() => import("@azure/monitor-opentelemetry") as unknown as Promise<AzureMonitorModule>);
    const { useAzureMonitor } = await load();
    // Only built when AZURE_CLIENT_ID is set — see the header comment above
    // for why an unconditional DefaultAzureCredential() is the wrong default
    // here.
    const clientId = env.AZURE_CLIENT_ID?.trim();
    const credential = clientId ? deps.credential ?? (await createDefaultCredential(env)) : undefined;
    useAzureMonitor({
      azureMonitorExporterOptions: {
        connectionString,
        ...(credential ? { credential } : {}),
      },
      resource: {
        attributes: {
          "service.name": env.MLS_SERVICE_NAME ?? "mls-mcp-tools",
          "service.version": TELEMETRY_VERSION,
        },
      },
      // The six tools are the story; HTTP server auto-instrumentation would
      // add a duplicate span per POST /mcp for no extra information.
      instrumentationOptions: { http: { enabled: true } },
    });
    resetTelemetryForTests();
    status = { enabled: true, exporter: "azure-monitor" };
  } catch (err) {
    status = {
      enabled: false,
      exporter: "failed",
      // The message can only come from the distro, but it is the kind of message
      // that quotes the connection string back at you. Same redaction pass the
      // agent-facing errors get.
      reason: redact(
        `Azure Monitor exporter failed to start: ${
          err instanceof Error ? err.message : String(err)
        }`,
      ),
    };
  }
  return status;
}
