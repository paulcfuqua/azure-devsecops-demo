/**
 * One server span per request, built by hand from the attribute allowlist.
 *
 * When telemetry is off this is still on the stack — and costs essentially
 * nothing, because `getTracer()` returns the OTel API's no-op tracer, whose
 * `startSpan` returns a `NonRecordingSpan`. Keeping the middleware
 * unconditional means the traced and untraced code paths are the same code
 * path, which is the only way the untraced one stays correct.
 */
import { SpanKind, SpanStatusCode, context, propagation, trace } from "@opentelemetry/api";
import type { RequestHandler, Response } from "express";
import type { DataApiConfig } from "../config.js";
import type { ApiErrorCode } from "../errors.js";
import { requestAttributes, responseAttributes, spanName } from "./attributes.js";
import { getTracer } from "./otel.js";

/** Per-request state the handlers publish for the span to pick up on finish. */
export interface TelemetryState {
  requestId: string;
  rowCount?: number;
  rowCap?: number;
  truncated?: boolean;
  errorCode?: ApiErrorCode;
}

const STATE_KEY = "mlsTelemetry";

export function telemetryState(res: Response): TelemetryState {
  const locals = res.locals as Record<string, unknown>;
  let state = locals[STATE_KEY] as TelemetryState | undefined;
  if (!state) {
    state = { requestId: "unknown" };
    locals[STATE_KEY] = state;
  }
  return state;
}

/** `/api/tables/launches` + prefix `/api` -> `/tables/launches`. */
export function stripPrefix(pathname: string, prefix: string): string {
  if (prefix === "" || !pathname.startsWith(prefix)) return pathname;
  const rest = pathname.slice(prefix.length);
  if (rest === "") return "/";
  return rest.startsWith("/") ? rest : pathname;
}

export function requestSpanMiddleware(config: DataApiConfig): RequestHandler {
  return (req, res, next) => {
    // Strip the mount prefix before deriving telemetry: a service moved from
    // "/" to "/api" must not become a second, unrelated set of route names in
    // App Insights.
    const pathname = stripPrefix(req.path, config.routePrefix);

    // Continue the browser's trace when one arrives. Both frontends send W3C
    // trace context on their API calls, so a slow tab in the demo can be
    // followed from the click through to the SQL round trip in one App
    // Insights transaction. `extract` reads only traceparent/tracestate/
    // baggage — never an arbitrary header — and falls back to a new root
    // trace when they are absent or malformed.
    const parent = propagation.extract(context.active(), req.headers);

    const span = getTracer().startSpan(
      spanName(req.method, pathname),
      {
        kind: SpanKind.SERVER,
        attributes: requestAttributes({
          method: req.method,
          pathname,
          backendMode: config.backendMode,
        }),
      },
      parent,
    );

    let ended = false;
    const finish = (): void => {
      if (ended) return;
      ended = true;
      const state = telemetryState(res);
      span.setAttributes(
        responseAttributes({
          statusCode: res.statusCode,
          ...(state.rowCount !== undefined ? { rowCount: state.rowCount } : {}),
          ...(state.rowCap !== undefined ? { rowCap: state.rowCap } : {}),
          ...(state.truncated !== undefined ? { truncated: state.truncated } : {}),
          ...(state.errorCode !== undefined ? { errorCode: state.errorCode } : {}),
        }),
      );
      // 4xx is a client mistake, not a service failure: only 5xx sets ERROR,
      // otherwise a bot probing /tables/etc-passwd would light up the SLO.
      if (res.statusCode >= 500) {
        span.setStatus({ code: SpanStatusCode.ERROR });
      }
      span.end();
    };

    res.on("finish", finish);
    res.on("close", finish);

    context.with(trace.setSpan(parent, span), next);
  };
}
