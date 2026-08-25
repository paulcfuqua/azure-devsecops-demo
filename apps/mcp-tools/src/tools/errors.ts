/**
 * The adapter error surface.
 *
 * Every failure a backend adapter can produce is one of a small, closed set of
 * kinds. The MCP layer turns any thrown error into an `isError` tool result
 * carrying `error.message` verbatim (src/mcp/server.ts), so **the message is
 * agent-facing text**: it is the only thing the Copilot Studio orchestrator sees
 * when a call fails, and it is what it will reason over when deciding whether to
 * retry, reformulate, or give up. Messages are therefore written for that
 * reader — what went wrong, and what a different call would have to look like.
 *
 * SECURITY: an adapter error message may travel to the agent, into the eval
 * artifact, and into App Insights. `redact()` is applied to every message before
 * it leaves this module, and it strips bearer tokens, GitHub tokens, SAS query
 * strings, ADO.NET/ODBC connection strings and `Authorization` header values.
 * Never interpolate a token, a password or a full connection string into an
 * error, even "just for debugging" — hard rule 5.
 */

/** Closed set of adapter failure kinds. `retryable` is decided per kind + status. */
export type AdapterErrorKind =
  /** Missing/!invalid configuration (env var absent, malformed scope). Not retryable. */
  | "config"
  /** Token acquisition or 401/403 from the upstream. Not retryable by the agent. */
  | "auth"
  /** The caller's input was rejected (bad SQL, bad KQL, unparsable date). Retryable by REFORMULATING. */
  | "bad_request"
  /** 404 from the upstream — wrong workspace/repo/subscription. Not retryable. */
  | "not_found"
  /** 429 / 503 after the retry budget was exhausted. Retryable later. */
  | "throttled"
  /** 5xx, malformed response, transport failure. Possibly retryable later. */
  | "upstream"
  /** Client-side deadline hit. Possibly retryable later. */
  | "timeout";

export interface AdapterErrorInit {
  /** Upstream HTTP status, when there was one. */
  status?: number;
  /** Which upstream produced it — "fabric-sql", "log-analytics", "github", "arm". */
  service?: string;
  /** Upstream correlation id (x-ms-request-id / x-github-request-id), safe to surface. */
  requestId?: string;
  cause?: unknown;
}

/**
 * Patterns that must never reach the agent, the eval artifact or App Insights.
 * Ordered most-specific first; each replacement keeps enough shape that the
 * message still reads, e.g. `Authorization: [redacted]`.
 */
const REDACTIONS: Array<[RegExp, string]> = [
  // Authorization / api-key style headers, in any casing.
  [/\b(authorization|x-api-key|api-key|ocp-apim-subscription-key)\b\s*[:=]\s*\S+/gi, "$1: [redacted]"],
  // Bearer tokens wherever they appear (JWTs included).
  [/\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/gi, "Bearer [redacted]"],
  // Bare JWTs (three dot-separated base64url segments).
  [/\beyJ[A-Za-z0-9._~+/=-]{16,}/g, "[redacted-jwt]"],
  // GitHub tokens: classic (ghp_/gho_/ghu_/ghs_/ghr_) and fine-grained (github_pat_).
  [/\bgh[pousr]_[A-Za-z0-9]{16,}\b/g, "[redacted-github-token]"],
  [/\bgithub_pat_[A-Za-z0-9_]{16,}\b/g, "[redacted-github-token]"],
  // ADO.NET / ODBC connection strings: kill the whole string once any secret-ish key appears.
  [/\b(Password|Pwd|AccountKey|SharedAccessKey|InstrumentationKey|IngestionEndpoint)\s*=\s*[^;"'\s]+/gi, "$1=[redacted]"],
  // SAS / token query parameters on a URL.
  [/([?&](?:sig|sv|se|st|code|access_token|token|secret)=)[^&\s"']+/gi, "$1[redacted]"],
];

/** Strip anything credential-shaped from a string bound for an agent-visible surface. */
export function redact(text: string): string {
  let out = text;
  for (const [pattern, replacement] of REDACTIONS) out = out.replace(pattern, replacement);
  return out;
}

/**
 * A backend adapter failure. `message` is agent-facing and already redacted.
 *
 * Instances are also the input to the telemetry layer's `mls.error.kind` span
 * attribute — the *kind* is recorded, never the message, so no upstream text
 * can leak into App Insights through a span attribute.
 */
export class AdapterError extends Error {
  readonly kind: AdapterErrorKind;
  readonly status: number | undefined;
  readonly service: string | undefined;
  readonly requestId: string | undefined;

  constructor(kind: AdapterErrorKind, message: string, init: AdapterErrorInit = {}) {
    super(redact(message), init.cause === undefined ? undefined : { cause: init.cause });
    this.name = "AdapterError";
    this.kind = kind;
    this.status = init.status;
    this.service = init.service;
    this.requestId = init.requestId;
  }

  /** True when waiting and calling again could plausibly succeed unchanged. */
  get retryable(): boolean {
    return this.kind === "throttled" || this.kind === "timeout" || this.kind === "upstream";
  }
}

/** Narrowing helper — cheaper and safer than `instanceof` across module realms. */
export function isAdapterError(err: unknown): err is AdapterError {
  return err instanceof AdapterError || (err as AdapterError)?.name === "AdapterError";
}

/** Map an HTTP status to the kind an adapter should raise for it. */
export function kindForStatus(status: number): AdapterErrorKind {
  if (status === 401 || status === 403) return "auth";
  if (status === 404) return "not_found";
  if (status === 408) return "timeout";
  if (status === 429) return "throttled";
  if (status === 503) return "throttled";
  if (status >= 400 && status < 500) return "bad_request";
  return "upstream";
}

/** The error kind for anything that escaped an adapter without being typed. */
export function toAdapterError(err: unknown, service: string): AdapterError {
  if (isAdapterError(err)) return err;
  const message = err instanceof Error ? err.message : String(err);
  // Node's fetch surfaces DNS/TLS/socket failures as TypeError('fetch failed').
  const kind: AdapterErrorKind = /abort|timeout|timed out/i.test(message) ? "timeout" : "upstream";
  return new AdapterError(kind, `${service} request failed: ${message}`, { service, cause: err });
}
