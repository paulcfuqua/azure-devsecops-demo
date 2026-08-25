/**
 * A tiny recording `fetch` double.
 *
 * Every cloud adapter takes an injectable `fetchImpl`, so the entire cloud path
 * is exercised against this and NOTHING in the test suite can reach a network.
 * There is no tenant to reach anyway — that is the point of the seam.
 *
 * Each route holds a QUEUE of replies and repeats the last one once the queue is
 * drained, which is what makes retry and pagination tests read naturally:
 *
 *   mock.on(/\/query/, { status: 429, headers: { "retry-after": "1" } },
 *                      { status: 200, body: page });
 */
export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export interface RecordedCall {
  url: string;
  method: string;
  headers: Record<string, string>;
  /** Parsed JSON body when the request had one. */
  body: any;
  rawBody: string | undefined;
}

export interface MockReply {
  status?: number;
  body?: unknown;
  /** Raw body, for testing non-JSON responses. Wins over `body`. */
  text?: string;
  headers?: Record<string, string>;
  /** Simulate a transport failure (DNS, TLS, socket) rather than an HTTP status. */
  throws?: Error;
}

interface Route {
  test: (url: string, init?: RequestInit) => boolean;
  replies: MockReply[];
}

function toResponse(reply: MockReply): Response {
  const status = reply.status ?? 200;
  const headers = new Headers({
    "content-type": "application/json",
    ...(reply.headers ?? {}),
  });
  if (status === 204) return new Response(null, { status, headers });
  const payload = reply.text ?? (reply.body === undefined ? "" : JSON.stringify(reply.body));
  return new Response(payload, { status, headers });
}

export class MockFetch {
  readonly calls: RecordedCall[] = [];
  private readonly routes: Route[] = [];

  /** Register a route. `test` may be a RegExp on the URL or a predicate. */
  on(
    test: RegExp | ((url: string, init?: RequestInit) => boolean),
    ...replies: MockReply[]
  ): this {
    this.routes.push({
      test: typeof test === "function" ? test : (url: string) => test.test(url),
      replies: [...replies],
    });
    return this;
  }

  /** Calls whose URL matches — for asserting pagination followed the right links. */
  callsMatching(pattern: RegExp): RecordedCall[] {
    return this.calls.filter((c) => pattern.test(c.url));
  }

  readonly fetch: FetchLike = async (url, init) => {
    const headers: Record<string, string> = {};
    const rawHeaders = init?.headers as Record<string, string> | undefined;
    for (const [key, value] of Object.entries(rawHeaders ?? {})) {
      headers[key.toLowerCase()] = String(value);
    }
    const rawBody = typeof init?.body === "string" ? init.body : undefined;
    this.calls.push({
      url,
      method: init?.method ?? "GET",
      headers,
      body: rawBody === undefined ? undefined : JSON.parse(rawBody),
      rawBody,
    });

    const route = this.routes.find((r) => r.test(url, init));
    if (!route) throw new Error(`MockFetch: no route registered for ${init?.method ?? "GET"} ${url}`);
    const reply = route.replies.length > 1 ? route.replies.shift()! : route.replies[0]!;
    if (reply.throws) throw reply.throws;
    return toResponse(reply);
  };
}

/** A `fetch` that fails the test if it is called at all. */
export function forbiddenFetch(label = "network"): FetchLike {
  return async (url) => {
    throw new Error(`${label}: a network call was made to ${url}, but none was allowed`);
  };
}

/** Instant sleep, so retry/backoff tests cost no wall-clock time. */
export const noSleep = async (): Promise<void> => {};
