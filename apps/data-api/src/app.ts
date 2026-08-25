/**
 * The HTTP surface — exactly the routes both frontends' `ApiProvider` already
 * fetches, and nothing else.
 *
 *   GET /tables/:table   launch-ops' `rows<T>(table)` and the control tower's
 *                        `tables/cost_daily` + `tables/telemetry_summary`.
 *                        Answers a bare JSON **array** of rows: the launch-ops
 *                        provider throws if the body is not an array, so the
 *                        envelope that would be nicer to version is not
 *                        available to us. Metadata goes in headers instead.
 *   GET /feeds/:name     the control tower's six feeds, each answering the
 *                        payload shape its provider casts to — three objects,
 *                        two arrays, one Log Analytics result.
 *   GET /healthz         liveness for Container Apps probes, plus which
 *                        backend set is live and whether tracing is exporting.
 *
 * Read-only by construction: no body parser is installed, and anything that is
 * not GET/HEAD/OPTIONS is refused before routing.
 */
import { randomUUID } from "node:crypto";
import express, { type Express, type NextFunction, type Request, type RequestHandler, type Response } from "express";
import type { Backends } from "./backends/index.js";
import { createBackends } from "./backends/index.js";
import { loadConfig, type DataApiConfig } from "./config.js";
import {
  FEED_NAMES,
  TABLE_NAMES,
  isAllowedFeed,
  isAllowedTable,
} from "./contract/allowlist.js";
import { ApiError, redact, toApiError } from "./errors.js";
import { requestSpanMiddleware, telemetryState } from "./telemetry/middleware.js";
import type { Telemetry } from "./telemetry/otel.js";

export interface AppDeps {
  config?: DataApiConfig;
  backends?: Backends;
  telemetry?: Telemetry;
  /** Test seam so a suite can assert on logs without capturing stderr. */
  log?: (message: string) => void;
}

/** Headers a browser may read cross-origin (they are metadata, not data). */
const EXPOSED_HEADERS = [
  "X-Request-Id",
  "X-MLS-Row-Count",
  "X-MLS-Row-Cap",
  "X-MLS-Truncated",
].join(", ");

/**
 * Headers a cross-origin caller may send. Content-Type plus W3C trace context
 * and the App Insights correlation pair — without these on the preflight, the
 * browser SDK's correlation headers would make every cross-origin API call
 * fail CORS, which is a spectacular way to break a demo by adding telemetry.
 * None of them is a credential; there is deliberately no Authorization here.
 */
const ALLOWED_REQUEST_HEADERS = [
  "Content-Type",
  "traceparent",
  "tracestate",
  "baggage",
  "Request-Id",
  "Request-Context",
].join(", ");

export function createApp(deps: AppDeps = {}): Express {
  const config = deps.config ?? loadConfig();
  const backends = deps.backends ?? createBackends(config);
  const telemetry = deps.telemetry;
  const log = deps.log ?? ((message: string) => console.error(message));

  const app = express();
  // Nothing about this service should advertise its framework.
  app.disable("x-powered-by");
  // The row payloads are large and highly repetitive JSON; etag lets a browser
  // revalidate a 400 KB table for a few hundred bytes.
  app.set("etag", "strong");

  app.use(requestIdMiddleware);
  app.use(securityHeaders);
  app.use(corsMiddleware(config));
  app.use(requestSpanMiddleware(config));
  app.use(readOnlyGuard);

  app.get("/healthz", (_req, res) => {
    res.set("Cache-Control", "no-store");
    res.json({
      ok: true,
      service: "data-api",
      // The two facts an operator needs first when a demo misbehaves.
      mode: backends.kind,
      build: config.build,
      telemetry: {
        enabled: telemetry?.enabled ?? false,
        exporter: telemetry?.enabled === true ? "azure-monitor" : "none",
      },
      sources: backends.describe(),
      // Where the data routes actually are. Both frontends' ApiProvider
      // defaults to a "/api" base, so a mismatch here is the single most
      // likely cause of an app that renders its error state against a
      // perfectly healthy service.
      routePrefix: config.routePrefix,
      tables: TABLE_NAMES,
      feeds: FEED_NAMES,
      maxRows: config.maxRows,
      allowedOrigins: config.allowedOrigins,
    });
  });

  // The two data routes live on a router so they can be mounted under a path
  // prefix without their definitions knowing about it. See DataApiConfig.
  const data = express.Router();

  data.get(
    "/tables/:table",
    asyncRoute(async (req, res) => {
      // Express 5 types a path parameter as possibly repeated; only a single
      // segment can ever reach the allowlist.
      const requested = req.params.table;
      if (typeof requested !== "string" || !isAllowedTable(requested)) {
        throw ApiError.unknownTable(TABLE_NAMES);
      }
      const limit = parseLimit(req, config.maxRows);

      const result = await backends.tables.getTable(requested, limit);

      const state = telemetryState(res);
      state.rowCount = result.rows.length;
      state.rowCap = limit;
      state.truncated = result.truncated;

      res.set({
        "Cache-Control": cacheControl(config.tableCacheSeconds),
        "X-MLS-Row-Count": String(result.rows.length),
        "X-MLS-Row-Cap": String(limit),
        "X-MLS-Truncated": String(result.truncated),
      });
      // A bare array: this is the launch-ops ApiProvider's contract.
      res.json(result.rows);
    }),
  );

  data.get(
    "/feeds/:name",
    asyncRoute(async (req, res) => {
      const requested = req.params.name;
      if (typeof requested !== "string" || !isAllowedFeed(requested)) {
        throw ApiError.unknownFeed(FEED_NAMES);
      }

      const payload = await backends.feeds.getFeed(requested);

      res.set("Cache-Control", cacheControl(config.feedCacheSeconds));
      res.json(payload);
    }),
  );

  app.use(config.routePrefix === "" ? "/" : config.routePrefix, data);

  // Anything else, including /tables and /feeds with no segment.
  app.use((_req, _res, next: NextFunction) => {
    next(ApiError.notFound());
  });

  app.use(errorHandler(log));

  return app;
}

/* ------------------------------------------------------------------ */
/* middleware                                                          */
/* ------------------------------------------------------------------ */

const requestIdMiddleware: RequestHandler = (_req, res, next) => {
  // Generated here, never taken from a request header: a caller-supplied id
  // would let anyone forge correlation between their traffic and someone
  // else's trace.
  const requestId = randomUUID();
  telemetryState(res).requestId = requestId;
  res.set("X-Request-Id", requestId);
  next();
};

const securityHeaders: RequestHandler = (_req, res, next) => {
  res.set({
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
  });
  next();
};

/**
 * CORS restricted to configured origins, exact match, no credentials.
 *
 * An unlisted origin gets no `Access-Control-Allow-Origin` header at all —
 * the browser then blocks the read, which is the correct failure. The service
 * still answers 200, because CORS is a browser policy and pretending it is an
 * authorization check would be security theatre.
 */
function corsMiddleware(config: DataApiConfig): RequestHandler {
  const allowed = new Set(config.allowedOrigins);
  return (req, res, next) => {
    res.vary("Origin");
    const origin = req.headers.origin;
    if (typeof origin === "string" && allowed.has(origin)) {
      res.set({
        "Access-Control-Allow-Origin": origin,
        "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
        "Access-Control-Allow-Headers": ALLOWED_REQUEST_HEADERS,
        "Access-Control-Expose-Headers": EXPOSED_HEADERS,
        "Access-Control-Max-Age": "600",
      });
    }
    if (req.method === "OPTIONS") {
      res.status(204).end();
      return;
    }
    next();
  };
}

/** This API reads. Refuse everything else before a route can be matched. */
const readOnlyGuard: RequestHandler = (req, _res, next) => {
  if (req.method === "GET" || req.method === "HEAD") {
    next();
    return;
  }
  next(ApiError.methodNotAllowed(req.method));
};

function errorHandler(
  log: (message: string) => void,
): (err: unknown, req: Request, res: Response, next: NextFunction) => void {
  return (err, _req, res, _next) => {
    const apiError = toApiError(err);
    const state = telemetryState(res);
    state.errorCode = apiError.code;

    if (apiError.status >= 500 || apiError.detail !== undefined) {
      // Redacted, and only ever the detail we chose to keep — never a raw
      // driver or SDK error object.
      log(
        `[data-api] ${apiError.code} (${apiError.status}) requestId=${state.requestId}` +
          (apiError.detail === undefined ? "" : ` detail=${redact(apiError.detail)}`),
      );
    }

    if (res.headersSent) {
      res.end();
      return;
    }
    res.status(apiError.status);
    res.set("Cache-Control", "no-store");
    res.json(apiError.toBody(state.requestId));
  };
}

/* ------------------------------------------------------------------ */
/* helpers                                                             */
/* ------------------------------------------------------------------ */

/**
 * Express 5 forwards a rejected handler promise to the error middleware on its
 * own; this wrapper makes that explicit rather than load-bearing-by-default.
 */
function asyncRoute(
  handler: (req: Request, res: Response) => Promise<void>,
): RequestHandler {
  return (req, res, next) => {
    handler(req, res).catch(next);
  };
}

function parseLimit(req: Request, max: number): number {
  const raw = req.query.limit;
  if (raw === undefined) return max;
  // Plain digits only. `Number()` would happily accept "1e3", " 12" and
  // "0x10"; a row cap that depends on JavaScript's coercion trivia is a
  // guardrail with a soft edge.
  if (typeof raw !== "string" || !/^\d+$/.test(raw)) throw ApiError.invalidLimit(max);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 1) throw ApiError.invalidLimit(max);
  // Over the cap is clamped, not refused: a client asking for more than the
  // service will ever serve should still get the most it can have.
  return Math.min(value, max);
}

function cacheControl(seconds: number): string {
  return seconds <= 0
    ? "no-store"
    : `public, max-age=${seconds}, stale-while-revalidate=${seconds * 5}`;
}
