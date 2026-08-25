/**
 * The one HTTP client every cloud adapter goes through.
 *
 * Four upstreams (Azure Monitor, ARM, Cost Management, GitHub) with four
 * different pagination idioms and four different error bodies, but exactly one
 * retry policy, one deadline, one redaction pass and one error taxonomy — kept
 * here so a policy fix lands in all four at once and so the unit tests can drive
 * every adapter through a single injected `fetch`.
 *
 * Retry policy, deliberately narrow:
 *   - 429 and 503 only, plus transport failures (DNS/TLS/socket) and timeouts.
 *   - `Retry-After` (delta-seconds or HTTP-date) is HONOURED when present; only
 *     when it is absent do we fall back to exponential backoff with full jitter.
 *     Azure Monitor, ARM and GitHub all send it, and ignoring it is how a client
 *     turns a throttle into an outage.
 *   - 4xx other than 429 is never retried: the request is wrong, not unlucky.
 *   - A retry budget, not a retry count: `maxElapsedMs` bounds the whole call so
 *     a throttled upstream cannot blow the agent's latency budget (V8.5, p95<20s).
 *
 * `sleep` is injectable purely so tests can assert the retry *decisions* without
 * spending real wall-clock time.
 */
import { AdapterError, kindForStatus, redact } from "./errors.js";

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export interface RetryPolicy {
  /** Attempts including the first. Default 4 (=> up to 3 retries). */
  maxAttempts: number;
  /** Total wall-clock budget across all attempts, ms. Default 15_000. */
  maxElapsedMs: number;
  /** First backoff delay, ms. Doubles each attempt, with full jitter. Default 250. */
  baseDelayMs: number;
  /** Ceiling on any single backoff delay, ms. Default 4_000. */
  maxDelayMs: number;
  /** Per-attempt deadline, ms. Default 20_000. */
  requestTimeoutMs: number;
}

export const DEFAULT_RETRY: RetryPolicy = {
  maxAttempts: 4,
  maxElapsedMs: 15_000,
  baseDelayMs: 250,
  maxDelayMs: 4_000,
  requestTimeoutMs: 20_000,
};

export interface HttpClientOptions {
  /** Upstream label used in error messages and telemetry: "github", "arm", ... */
  service: string;
  fetchImpl?: FetchLike;
  retry?: Partial<RetryPolicy>;
  /** Injected for tests; the default awaits a real timer. */
  sleep?: (ms: number) => Promise<void>;
  /** Injected for tests; the default is Date.now. */
  now?: () => number;
  /** Deterministic jitter for tests; the default is Math.random. */
  random?: () => number;
}

export interface HttpRequest {
  url: string;
  method?: "GET" | "POST";
  headers?: Record<string, string>;
  /** Serialised as JSON when present. */
  body?: unknown;
}

export interface HttpJsonResponse<T> {
  body: T;
  headers: Headers;
  status: number;
  /** How many attempts this call cost — asserted by the retry tests. */
  attempts: number;
}

const realSleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

/** Statuses worth trying again unchanged. Everything else is the caller's problem. */
function isRetryableStatus(status: number): boolean {
  return status === 429 || status === 503;
}

/**
 * `Retry-After: 30` (delta-seconds) or `Retry-After: Wed, 21 Oct 2026 07:28:00 GMT`.
 * Returns ms, or undefined when the header is absent or unparsable.
 */
export function parseRetryAfter(value: string | null, nowMs: number): number | undefined {
  if (value === null) return undefined;
  const trimmed = value.trim();
  if (/^\d+$/.test(trimmed)) return Number(trimmed) * 1000;
  const asDate = Date.parse(trimmed);
  if (Number.isNaN(asDate)) return undefined;
  return Math.max(0, asDate - nowMs);
}

/**
 * Pull a human-usable message out of whichever error envelope the upstream uses.
 * Azure/ARM: { error: { code, message } }. Log Analytics nests innererror.
 * GitHub: { message, documentation_url }. Anything else: the first 300 chars.
 */
export function extractUpstreamMessage(body: unknown, rawText: string): string {
  const asObj = body as Record<string, any> | null;
  const azure = asObj?.error;
  if (azure && typeof azure === "object") {
    let node = azure;
    // Log Analytics buries the useful text (e.g. the KQL syntax error) in
    // error.innererror.innererror.message — walk to the deepest one.
    while (node.innererror && typeof node.innererror === "object") node = node.innererror;
    const code = typeof node.code === "string" ? `${node.code}: ` : "";
    if (typeof node.message === "string") return `${code}${node.message}`;
  }
  if (typeof asObj?.message === "string") return asObj.message;
  return rawText.slice(0, 300);
}

export class HttpClient {
  private readonly service: string;
  private readonly fetchImpl: FetchLike;
  private readonly retry: RetryPolicy;
  private readonly sleep: (ms: number) => Promise<void>;
  private readonly now: () => number;
  private readonly random: () => number;

  constructor(options: HttpClientOptions) {
    this.service = options.service;
    this.fetchImpl = options.fetchImpl ?? ((url, init) => fetch(url, init));
    this.retry = { ...DEFAULT_RETRY, ...options.retry };
    this.sleep = options.sleep ?? realSleep;
    this.now = options.now ?? (() => Date.now());
    this.random = options.random ?? Math.random;
  }

  /** Backoff for attempt N (1-based), full jitter, capped. */
  private backoffMs(attempt: number): number {
    const exponential = Math.min(this.retry.baseDelayMs * 2 ** (attempt - 1), this.retry.maxDelayMs);
    return Math.floor(this.random() * exponential);
  }

  /**
   * One JSON request, with the retry policy applied. Non-2xx becomes a typed
   * AdapterError; the upstream's own message is carried through (redacted) so
   * the agent can act on it — a KQL syntax error is the common case and the
   * agent can fix its own query from the text.
   */
  async requestJson<T>(request: HttpRequest): Promise<HttpJsonResponse<T>> {
    const startedAt = this.now();
    let attempt = 0;
    let lastError: AdapterError | undefined;

    for (;;) {
      attempt += 1;
      const outcome = await this.attempt<T>(request);

      if (outcome.ok) return { ...outcome.response, attempts: attempt };

      lastError = outcome.error;
      const budgetLeft = this.retry.maxElapsedMs - (this.now() - startedAt);
      const attemptsLeft = this.retry.maxAttempts - attempt;
      if (!outcome.retryable || attemptsLeft <= 0 || budgetLeft <= 0) break;

      const delay = Math.min(outcome.retryAfterMs ?? this.backoffMs(attempt), budgetLeft);
      if (delay < 0) break;
      await this.sleep(delay);
    }

    throw lastError ??
      new AdapterError("upstream", `${this.service} request failed`, { service: this.service });
  }

  private async attempt<T>(
    request: HttpRequest,
  ): Promise<
    | { ok: true; response: Omit<HttpJsonResponse<T>, "attempts"> }
    | { ok: false; error: AdapterError; retryable: boolean; retryAfterMs?: number }
  > {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.retry.requestTimeoutMs);
    let response: Response;
    try {
      const init: RequestInit = {
        method: request.method ?? "GET",
        headers: {
          accept: "application/json",
          ...(request.body === undefined ? {} : { "content-type": "application/json" }),
          ...request.headers,
        },
        signal: controller.signal,
      };
      if (request.body !== undefined) init.body = JSON.stringify(request.body);
      response = await this.fetchImpl(request.url, init);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      const aborted = /abort/i.test(message) || (err as Error)?.name === "AbortError";
      return {
        ok: false,
        retryable: true,
        error: new AdapterError(
          aborted ? "timeout" : "upstream",
          aborted
            ? `${this.service} timed out after ${this.retry.requestTimeoutMs}ms`
            : `${this.service} is unreachable: ${message}`,
          { service: this.service, cause: err },
        ),
      };
    } finally {
      clearTimeout(timer);
    }

    const rawText = await response.text();
    let parsed: unknown = undefined;
    if (rawText.length > 0) {
      try {
        parsed = JSON.parse(rawText);
      } catch {
        parsed = undefined;
      }
    }

    if (response.ok) {
      if (rawText.length > 0 && parsed === undefined) {
        return {
          ok: false,
          retryable: false,
          error: new AdapterError(
            "upstream",
            `${this.service} returned a non-JSON body (${response.status})`,
            { service: this.service, status: response.status },
          ),
        };
      }
      return {
        ok: true,
        response: { body: (parsed ?? {}) as T, headers: response.headers, status: response.status },
      };
    }

    const requestId =
      response.headers.get("x-ms-request-id") ??
      response.headers.get("x-ms-correlation-request-id") ??
      response.headers.get("x-github-request-id") ??
      undefined;
    const detail = redact(extractUpstreamMessage(parsed, rawText));
    const kind = kindForStatus(response.status);
    const error = new AdapterError(
      kind,
      `${this.service} returned ${response.status}${detail ? `: ${detail}` : ""}`,
      { service: this.service, status: response.status, requestId },
    );
    const retryAfterMs = parseRetryAfter(response.headers.get("retry-after"), this.now());
    return isRetryableStatus(response.status)
      ? { ok: false, error, retryable: true, ...(retryAfterMs === undefined ? {} : { retryAfterMs }) }
      : { ok: false, error, retryable: false };
  }
}

/* ------------------------------------------------------------------ */
/* Pagination                                                          */
/* ------------------------------------------------------------------ */

/** Hard stop on page-walking; a runaway upstream must not become a runaway tool call. */
export const MAX_PAGES = 20;

/**
 * RFC 8288 `Link: <url>; rel="next", <url>; rel="last"` — GitHub's pagination.
 * Returns the `next` URL or undefined.
 */
export function parseLinkNext(header: string | null): string | undefined {
  if (!header) return undefined;
  for (const part of header.split(",")) {
    const match = /^\s*<([^>]+)>\s*;\s*(.+)$/.exec(part);
    if (!match) continue;
    if (/rel\s*=\s*"?next"?/i.test(match[2] ?? "")) return match[1];
  }
  return undefined;
}

/**
 * Walk a GitHub-style `Link: rel="next"` sequence, concatenating array pages.
 * Stops at `limit` items or MAX_PAGES, whichever comes first.
 */
export async function pageByLinkHeader<T>(
  client: HttpClient,
  first: HttpRequest,
  limit: number,
): Promise<T[]> {
  const items: T[] = [];
  let url: string | undefined = first.url;
  for (let page = 0; page < MAX_PAGES && url !== undefined; page += 1) {
    const res: HttpJsonResponse<T[]> = await client.requestJson<T[]>({ ...first, url });
    if (!Array.isArray(res.body)) {
      throw new AdapterError("upstream", `expected a JSON array page, got ${typeof res.body}`, {
        service: "github",
        status: res.status,
      });
    }
    items.push(...res.body);
    if (items.length >= limit) return items.slice(0, limit);
    url = parseLinkNext(res.headers.get("link"));
  }
  return items.slice(0, limit);
}

/**
 * Walk an ARM-style `{ value: [...], nextLink }` sequence. `nextLink` is an
 * absolute URL that already carries the api-version and continuation token, so
 * it is followed verbatim with the same method/headers.
 */
export async function pageByNextLink<T>(
  client: HttpClient,
  first: HttpRequest,
  limit: number,
): Promise<T[]> {
  const items: T[] = [];
  let request: HttpRequest | undefined = first;
  for (let page = 0; page < MAX_PAGES && request !== undefined; page += 1) {
    const res: HttpJsonResponse<{ value?: T[]; nextLink?: string }> =
      await client.requestJson(request);
    items.push(...(res.body.value ?? []));
    if (items.length >= limit) return items.slice(0, limit);
    const next = res.body.nextLink;
    request = next ? { ...first, url: next } : undefined;
  }
  return items.slice(0, limit);
}
