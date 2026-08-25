/**
 * The one HTTP client the cloud feed adapters use.
 *
 * Small on purpose: a timeout (an upstream that hangs must not hold a browser
 * connection open until the platform kills it), a bounded retry for the two
 * failures that are genuinely transient (429 and 5xx), and a hard rule that
 * the response body never becomes an error message. GitHub and ARM both echo
 * request context in error bodies; ARM error bodies have been known to include
 * the full request URI including query parameters.
 */
import { ApiError } from "../errors.js";

export type FetchLike = (
  input: string,
  init?: { method?: string; headers?: Record<string, string>; body?: string; signal?: AbortSignal },
) => Promise<{
  ok: boolean;
  status: number;
  headers: { get(name: string): string | null };
  text(): Promise<string>;
}>;

export interface FetchJsonOptions {
  readonly url: string;
  readonly method?: "GET" | "POST";
  readonly headers?: Record<string, string>;
  readonly body?: unknown;
  readonly timeoutMs: number;
  /** Human label for the upstream, used in the client-facing error. */
  readonly label: string;
  readonly retries?: number;
  /** Test seam. */
  readonly fetchImpl?: FetchLike;
  readonly sleep?: (ms: number) => Promise<void>;
}

const DEFAULT_RETRIES = 2;
const MAX_RETRY_DELAY_MS = 5_000;

function defaultSleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function fetchJson<T>(options: FetchJsonOptions): Promise<T> {
  const doFetch = (options.fetchImpl ?? (globalThis.fetch as unknown as FetchLike));
  const sleep = options.sleep ?? defaultSleep;
  const retries = options.retries ?? DEFAULT_RETRIES;

  let lastDetail: unknown;
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), options.timeoutMs);
    try {
      const response = await doFetch(options.url, {
        method: options.method ?? "GET",
        headers: {
          accept: "application/json",
          ...(options.body === undefined ? {} : { "content-type": "application/json" }),
          ...options.headers,
        },
        ...(options.body === undefined ? {} : { body: JSON.stringify(options.body) }),
        signal: controller.signal,
      });

      if (response.ok) {
        const text = await response.text();
        try {
          return JSON.parse(text) as T;
        } catch (err) {
          throw ApiError.upstream(options.label, err);
        }
      }

      // Body is read but only ever kept as server-side detail.
      const body = await safeText(response);
      lastDetail = `HTTP ${response.status} from ${options.label}: ${body}`;

      if (!isRetryable(response.status) || attempt === retries) {
        throw ApiError.upstream(options.label, lastDetail);
      }
      await sleep(retryDelayMs(response.headers.get("retry-after"), attempt));
    } catch (err) {
      if (err instanceof ApiError) throw err;
      lastDetail = err;
      if (attempt === retries) {
        throw ApiError.upstream(options.label, err);
      }
      await sleep(retryDelayMs(null, attempt));
    } finally {
      clearTimeout(timer);
    }
  }

  /* c8 ignore next */
  throw ApiError.upstream(options.label, lastDetail);
}

function isRetryable(status: number): boolean {
  return status === 429 || status === 408 || (status >= 500 && status <= 599);
}

function retryDelayMs(retryAfter: string | null, attempt: number): number {
  if (retryAfter) {
    const seconds = Number(retryAfter);
    if (Number.isFinite(seconds) && seconds >= 0) {
      return Math.min(seconds * 1000, MAX_RETRY_DELAY_MS);
    }
  }
  return Math.min(250 * 2 ** attempt, MAX_RETRY_DELAY_MS);
}

async function safeText(response: {
  text(): Promise<string>;
}): Promise<string> {
  try {
    const text = await response.text();
    return text.length > 500 ? `${text.slice(0, 500)}…` : text;
  } catch {
    return "<unreadable body>";
  }
}
