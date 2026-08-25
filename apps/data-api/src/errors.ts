/**
 * The typed error surface.
 *
 * Every failure leaves this service as the same JSON envelope with a stable
 * machine code, and never carries an upstream message through verbatim. That
 * second half matters more than it looks: the things that fail in CLOUD mode
 * are a TDS driver and three REST clients, and their exception text routinely
 * contains the full connection string, the workspace id, or a bearer token
 * prefix. `ApiError.message` is written by us; the upstream text goes to
 * `detail`, which is logged (redacted) and never serialized to a client.
 */

/** Stable machine codes. Clients may switch on these; the prose may change. */
export type ApiErrorCode =
  | "unknown_table"
  | "unknown_feed"
  | "invalid_request"
  | "not_found"
  | "method_not_allowed"
  | "backend_not_configured"
  | "upstream_unavailable"
  | "internal_error";

export interface ApiErrorBody {
  error: {
    code: ApiErrorCode;
    message: string;
    status: number;
    requestId: string;
  };
}

export class ApiError extends Error {
  readonly code: ApiErrorCode;
  readonly status: number;
  /** Server-side only. Logged redacted; never reaches a response body. */
  readonly detail: string | undefined;

  constructor(
    code: ApiErrorCode,
    status: number,
    message: string,
    detail?: unknown,
  ) {
    super(message);
    this.name = "ApiError";
    this.code = code;
    this.status = status;
    this.detail = detail === undefined ? undefined : describe(detail);
  }

  toBody(requestId: string): ApiErrorBody {
    return {
      error: {
        code: this.code,
        message: this.message,
        status: this.status,
        requestId,
      },
    };
  }

  static unknownTable(allowed: readonly string[]): ApiError {
    return new ApiError(
      "unknown_table",
      404,
      `Unknown table. This API serves exactly: ${allowed.join(", ")}.`,
    );
  }

  static unknownFeed(allowed: readonly string[]): ApiError {
    return new ApiError(
      "unknown_feed",
      404,
      `Unknown feed. This API serves exactly: ${allowed.join(", ")}.`,
    );
  }

  static invalidLimit(max: number): ApiError {
    return new ApiError(
      "invalid_request",
      400,
      `limit must be a positive integer no greater than ${max}.`,
    );
  }

  static notFound(): ApiError {
    return new ApiError(
      "not_found",
      404,
      "No such route. This API serves GET /tables/:table, GET /feeds/:name and GET /healthz.",
    );
  }

  static methodNotAllowed(method: string): ApiError {
    // The method is echoed deliberately: it comes from the HTTP verb line,
    // which Node has already validated as a token, not from a body or header.
    return new ApiError(
      "method_not_allowed",
      405,
      `${method} is not supported. This API is read-only: GET (and HEAD) only.`,
    );
  }

  static upstream(what: string, detail?: unknown): ApiError {
    return new ApiError(
      "upstream_unavailable",
      502,
      `The ${what} upstream did not answer successfully. The failure is recorded in this service's telemetry with the request id below.`,
      detail,
    );
  }

  static notConfigured(what: string, detail?: unknown): ApiError {
    return new ApiError(
      "backend_not_configured",
      503,
      `${what} is not configured on this instance, so the request cannot be served.`,
      detail,
    );
  }

  static internal(detail?: unknown): ApiError {
    return new ApiError(
      "internal_error",
      500,
      "Internal error. The failure is recorded in this service's telemetry with the request id below.",
      detail,
    );
  }
}

/** `unknown` -> a single-line string, without invoking a hostile toString twice. */
function describe(value: unknown): string {
  if (value instanceof Error) {
    return `${value.name}: ${value.message}`;
  }
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value) ?? String(value);
  } catch {
    return "<unserializable>";
  }
}

/**
 * Patterns whose *matched text is a credential*. Applied to everything this
 * service logs. Deliberately blunt: a false positive costs one unreadable log
 * line, a false negative writes a secret to Log Analytics forever.
 */
const REDACTIONS: ReadonlyArray<readonly [RegExp, string]> = [
  // ADO.NET / App Insights connection-string parts, up to the next separator.
  [
    /\b(Server|Data Source|Address|Addr|Network Address|Initial Catalog|Database|User ID|UID|User|Password|Pwd|AccountKey|SharedAccessKey|InstrumentationKey|IngestionEndpoint|LiveEndpoint|ApplicationId)\s*=\s*[^;,\s]+/gi,
    "$1=<redacted>",
  ],
  // Authorization headers and raw bearer tokens.
  [/\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/gi, "Bearer <redacted>"],
  // Any JWT-looking blob, wherever it turns up.
  [/\beyJ[A-Za-z0-9._~+/=-]{20,}/g, "<redacted-jwt>"],
  // GitHub tokens (classic, fine-grained, app, refresh, server-to-server).
  [/\bgh[pousr]_[A-Za-z0-9_]{16,}/g, "<redacted-token>"],
  [/\bgithub_pat_[A-Za-z0-9_]{20,}/g, "<redacted-token>"],
  // SAS signatures and any `...sig=`/`...key=` query parameter.
  [/([?&](?:sig|signature|key|code|token)=)[^&\s]+/gi, "$1<redacted>"],
];

/** Scrub anything credential-shaped out of `text` before it is logged. */
export function redact(text: string): string {
  let out = text;
  for (const [pattern, replacement] of REDACTIONS) {
    out = out.replace(pattern, replacement);
  }
  return out.length > 2000 ? `${out.slice(0, 2000)}…` : out;
}

/** Normalize any thrown value into an ApiError. */
export function toApiError(err: unknown): ApiError {
  return err instanceof ApiError ? err : ApiError.internal(err);
}
