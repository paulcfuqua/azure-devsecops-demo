/**
 * OpenTelemetry tracing for data-api.
 *
 * Two states, both first-class:
 *
 *   connection string present -> a NodeTracerProvider is registered globally
 *       and batches spans to Azure Monitor (App Insights) through the official
 *       exporter. This is what makes L7's V7.3 ("OTel spans from a synthetic
 *       request visible in App Insights via KQL") provable.
 *   connection string absent  -> nothing is registered. `trace.getTracer()`
 *       then returns the API's built-in no-op tracer, so every `startSpan` in
 *       this codebase becomes a couple of property writes on a stub object.
 *       No exporter, no batch timer, no network, no error. That is the state
 *       in tests and on a laptop, and it must stay silent.
 *
 * There is deliberately no auto-instrumentation. Auto-instrumentation would
 * capture full request URLs and DB statements by default, and this process
 * handles a connection string and (in cloud mode) a GitHub token. Spans here
 * are hand-built from an allowlist of attributes — see `attributes.ts`.
 */
import { AzureMonitorTraceExporter } from "@azure/monitor-opentelemetry-exporter";
import { trace, type Tracer } from "@opentelemetry/api";
import { resourceFromAttributes } from "@opentelemetry/resources";
import {
  BatchSpanProcessor,
  ParentBasedSampler,
  TraceIdRatioBasedSampler,
  type SpanExporter,
  type SpanProcessor,
} from "@opentelemetry/sdk-trace-base";
import { NodeTracerProvider } from "@opentelemetry/sdk-trace-node";
import {
  ATTR_SERVICE_NAME,
  ATTR_SERVICE_VERSION,
} from "@opentelemetry/semantic-conventions";
import type { TelemetryConfig } from "../config.js";
import { redact } from "../errors.js";

/** Instrumentation scope — the `name` App Insights shows on the span's source. */
export const TRACER_NAME = "@mls/data-api";
export const TRACER_VERSION = "0.1.0";

export function getTracer(): Tracer {
  return trace.getTracer(TRACER_NAME, TRACER_VERSION);
}

export interface Telemetry {
  /** True when spans are actually being exported. Surfaced on /healthz. */
  readonly enabled: boolean;
  /** Flush and stop. Safe to call when disabled, and safe to call twice. */
  shutdown(): Promise<void>;
}

const DISABLED: Telemetry = {
  enabled: false,
  shutdown: () => Promise.resolve(),
};

export interface StartTelemetryOptions {
  /**
   * Test seam. Injecting an exporter turns telemetry on without a connection
   * string; production never passes this.
   */
  readonly exporter?: SpanExporter;
  readonly log?: (message: string) => void;
}

export function startTelemetry(
  config: TelemetryConfig,
  options: StartTelemetryOptions = {},
): Telemetry {
  const log = options.log ?? ((message: string) => console.log(message));

  let exporter = options.exporter;
  if (!exporter) {
    if (!config.connectionString) {
      log(
        "[data-api] APPLICATIONINSIGHTS_CONNECTION_STRING is not set — tracing is off (no-op tracer).",
      );
      return DISABLED;
    }
    try {
      exporter = createAzureMonitorExporter(config.connectionString);
    } catch (err) {
      // A malformed connection string must not take the service down: the API
      // is the product, telemetry is the instrument. Say so loudly and serve.
      log(
        `[data-api] tracing disabled — the Azure Monitor exporter could not start: ${redact(
          err instanceof Error ? err.message : String(err),
        )}`,
      );
      return DISABLED;
    }
  }

  const processor: SpanProcessor = new BatchSpanProcessor(exporter);
  const provider = new NodeTracerProvider({
    resource: resourceFromAttributes({
      [ATTR_SERVICE_NAME]: config.serviceName,
      [ATTR_SERVICE_VERSION]: config.serviceVersion,
    }),
    sampler: new ParentBasedSampler({
      root: new TraceIdRatioBasedSampler(config.sampleRatio),
    }),
    spanProcessors: [processor],
  });
  provider.register();

  log(
    `[data-api] tracing on — service.name=${config.serviceName} sampler=parentbased(${config.sampleRatio}) exporter=azure-monitor`,
  );

  let stopped = false;
  return {
    enabled: true,
    async shutdown() {
      if (stopped) return;
      stopped = true;
      try {
        // forceFlush BEFORE shutdown, and not instead of it. In this SDK
        // version `shutdown()` tears the batch processor down without
        // exporting what it is holding — verified in tests/telemetry.test.ts.
        // On Container Apps this matters constantly: the app scales to zero
        // between demo clicks, so almost every span batch ends its life in a
        // SIGTERM. Flushing first is the difference between "spans in App
        // Insights" and "an empty KQL result at V7.3".
        await provider.forceFlush();
      } catch (err) {
        log(
          `[data-api] telemetry flush failed: ${redact(
            err instanceof Error ? err.message : String(err),
          )}`,
        );
      }
      try {
        await provider.shutdown();
      } catch (err) {
        log(
          `[data-api] telemetry shutdown failed: ${redact(
            err instanceof Error ? err.message : String(err),
          )}`,
        );
      }
    },
  };
}

/**
 * Kept in its own function so the failure mode is contained: a malformed
 * connection string throws in the exporter's constructor, and the caller above
 * turns that into "tracing off", not "service down".
 */
function createAzureMonitorExporter(connectionString: string): SpanExporter {
  return new AzureMonitorTraceExporter({ connectionString });
}
