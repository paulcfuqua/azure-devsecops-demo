/**
 * The span attribute allowlist.
 *
 * Pure functions, no OTel imports beyond the `Attributes` type, so the tests
 * can assert the exact attribute set a request produces without standing up a
 * tracer provider. That is the point: "we never emit user text" is a claim
 * worth testing, and it is only testable if attribute construction is a
 * function rather than a side effect scattered through a middleware.
 *
 * What is deliberately NOT here:
 *   - the raw request path or query string (caller-controlled free text),
 *   - any request or response header, including Origin and Authorization,
 *   - SQL text, KQL text, upstream URLs, or any part of a connection string,
 *   - upstream error messages (they carry connection strings; see errors.ts).
 *
 * `mls.table` and `mls.feed` are the only request-derived values that appear,
 * and they are set from the matched allowlist *literal*, never from the path
 * segment the caller sent.
 */
import type { Attributes } from "@opentelemetry/api";
import {
  ATTR_HTTP_REQUEST_METHOD,
  ATTR_HTTP_RESPONSE_STATUS_CODE,
  ATTR_HTTP_ROUTE,
} from "@opentelemetry/semantic-conventions";
import type { BackendMode } from "../config.js";
import { isAllowedFeed, isAllowedTable } from "../contract/allowlist.js";
import type { ApiErrorCode } from "../errors.js";

/** Low-cardinality route template for a request path. */
export function routeTemplate(pathname: string): string {
  if (pathname === "/healthz") return "/healthz";
  if (pathname === "/tables" || pathname.startsWith("/tables/")) {
    return "/tables/:table";
  }
  if (pathname === "/feeds" || pathname.startsWith("/feeds/")) {
    return "/feeds/:name";
  }
  return "/*";
}

export interface RequestSpanInput {
  readonly method: string;
  readonly pathname: string;
  readonly backendMode: BackendMode;
}

/** Attributes known when the request arrives. */
export function requestAttributes(input: RequestSpanInput): Attributes {
  const attributes: Attributes = {
    [ATTR_HTTP_REQUEST_METHOD]: input.method,
    [ATTR_HTTP_ROUTE]: routeTemplate(input.pathname),
    "mls.backend_mode": input.backendMode,
  };

  const segment = decodeSegment(input.pathname);
  if (segment !== undefined) {
    if (input.pathname.startsWith("/tables/") && isAllowedTable(segment)) {
      attributes["mls.table"] = segment;
    } else if (input.pathname.startsWith("/feeds/") && isAllowedFeed(segment)) {
      attributes["mls.feed"] = segment;
    }
  }

  return attributes;
}

export interface ResponseSpanInput {
  readonly statusCode: number;
  readonly rowCount?: number;
  readonly rowCap?: number;
  readonly truncated?: boolean;
  readonly errorCode?: ApiErrorCode;
}

/** Attributes known once the response is written. */
export function responseAttributes(input: ResponseSpanInput): Attributes {
  const attributes: Attributes = {
    [ATTR_HTTP_RESPONSE_STATUS_CODE]: input.statusCode,
  };
  if (input.rowCount !== undefined) attributes["mls.row_count"] = input.rowCount;
  if (input.rowCap !== undefined) attributes["mls.row_cap"] = input.rowCap;
  if (input.truncated !== undefined) attributes["mls.truncated"] = input.truncated;
  // The *code* is ours (a closed enum). The upstream message never appears.
  if (input.errorCode !== undefined) attributes["error.type"] = input.errorCode;
  return attributes;
}

/** Span name: verb plus route template, so cardinality stays at route count. */
export function spanName(method: string, pathname: string): string {
  return `${method} ${routeTemplate(pathname)}`;
}

function decodeSegment(pathname: string): string | undefined {
  const parts = pathname.split("/");
  const last = parts[2];
  if (last === undefined || last === "") return undefined;
  try {
    return decodeURIComponent(last);
  } catch {
    return undefined;
  }
}
