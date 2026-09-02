import { describe, expect, it, vi } from "vitest";

import { BlobCostCacheStore, noopCostCacheStore } from "../src/backends/costCacheStore.js";
import { CloudFeedsBackend } from "../src/backends/cloud.js";
import type { AzureCostFeed } from "../src/contract/feeds.js";

const CONTAINER = "https://acct.blob.core.windows.net/cost-cache";

// NO CAST. The first version of this fixture used `as AzureCostFeed` over a
// slightly wrong shape (`amount` where the contract says `cost`), and the cast
// hid it - a fixture that does not match the contract tests nothing about the
// contract. CI's typecheck caught it; the fix is the real shape, not a wider cast.
const feed: AzureCostFeed = {
  asOf: "2026-09-02T12:00:00.000Z",
  stale: false,
  currency: "USD",
  total: 1.4,
  timeframe: "MonthToDate",
  byService: [{ name: "Azure Container Apps", cost: 1.1 }],
  byResourceGroup: [{ name: "mls-rg-apps", cost: 1.1 }],
  daily: [{ date: "2026-09-01", cost: 1.4 }],
};

const tokens = { getToken: async () => "a-token" };

function response(body: unknown, status = 200): Response {
  return new Response(status === 204 ? null : JSON.stringify(body), { status });
}

describe("BlobCostCacheStore", () => {
  it("round-trips a feed through the blob", async () => {
    let stored: string | undefined;
    const fetchImpl = vi.fn(async (_url: string, init?: RequestInit) => {
      if (init?.method === "PUT") {
        stored = init.body as string;
        return response(null, 201);
      }
      return stored === undefined ? response(null, 404) : new Response(stored, { status: 200 });
    });
    const store = new BlobCostCacheStore({
      containerUri: CONTAINER,
      tokens,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });

    expect(await store.read()).toBeUndefined();
    await store.write(feed);
    expect(await store.read()).toMatchObject({ total: 1.4, currency: "USD" });
  });

  it("writes stale:false regardless of what it was handed", async () => {
    // Whether a reader should call the figure stale depends on WHEN it is read,
    // not when it was written. Persisting stale:true would make a value that was
    // fresh at write time permanently suspect.
    let stored = "";
    const fetchImpl = vi.fn(async (_url: string, init?: RequestInit) => {
      stored = (init?.body as string) ?? "";
      return response(null, 201);
    });
    const store = new BlobCostCacheStore({
      containerUri: CONTAINER,
      tokens,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });
    await store.write({ ...feed, stale: true });
    expect(JSON.parse(stored).stale).toBe(false);
  });

  it("treats 404 as an empty cache, not an error", async () => {
    const onError = vi.fn();
    const store = new BlobCostCacheStore({
      containerUri: CONTAINER,
      tokens,
      fetchImpl: (async () => response(null, 404)) as unknown as typeof fetch,
      onError,
    });
    expect(await store.read()).toBeUndefined();
    // A fresh estate has no blob yet; reporting that as a fault would train
    // people to ignore the log line that matters.
    expect(onError).not.toHaveBeenCalled();
  });

  it("NEVER throws, whatever the store does", async () => {
    // A cache is an optimisation. If the store is unreachable the feed must
    // behave exactly as it did before this file existed.
    const store = new BlobCostCacheStore({
      containerUri: CONTAINER,
      tokens,
      fetchImpl: (async () => {
        throw new Error("network down");
      }) as unknown as typeof fetch,
    });
    await expect(store.read()).resolves.toBeUndefined();
    await expect(store.write(feed)).resolves.toBeUndefined();
  });

  it("rejects a document that is not a cost feed", async () => {
    // Guards against a stale format after a deploy - the risk here is our own
    // older shape, not a hostile payload.
    const store = new BlobCostCacheStore({
      containerUri: CONTAINER,
      tokens,
      fetchImpl: (async () => response({ hello: "world" })) as unknown as typeof fetch,
    });
    expect(await store.read()).toBeUndefined();
  });

  it("tolerates a container URI with a trailing slash", async () => {
    // It arrives from a Bicep string concat; a double slash is a 404 that would
    // read as an empty cache rather than a misconfiguration.
    const seen: string[] = [];
    const store = new BlobCostCacheStore({
      containerUri: `${CONTAINER}/`,
      tokens,
      fetchImpl: (async (url: string) => {
        seen.push(String(url));
        return response(null, 404);
      }) as unknown as typeof fetch,
    });
    await store.read();
    expect(seen[0]).toBe(`${CONTAINER}/azure-cost-last-good.json`);
  });

  it("the noop store is a working store that holds nothing", async () => {
    expect(await noopCostCacheStore.read()).toBeUndefined();
    await expect(noopCostCacheStore.write(feed)).resolves.toBeUndefined();
  });
});

describe("cost throttle cooldown (F140)", () => {
  // Every page load is a retry. Cost Management throttles per principal and each
  // refusal lengthens the window, so a reader pressing refresh on a 502 was
  // extending the outage they were trying to end. These assert that the feed
  // stops asking, and starts again on its own.
  const config = {
    costCacheSeconds: 3600,
    costThrottleCooldownSeconds: 300,
    costTimeframe: "MonthToDate",
    costSubscriptionId: "sub",
    armBase: "https://management.azure.com",
    upstreamTimeoutMs: 5000,
  };

  function backendWith(fetchImpl: typeof fetch, store?: { read: () => Promise<unknown>; write: () => Promise<void> }) {
    return new CloudFeedsBackend({
      config: config as never,
      tokens: { getToken: async () => "t" },
      fetchImpl: fetchImpl as never,
      ...(store ? { costCacheStore: store as never } : {}),
    } as never);
  }

  const throttled = (async () =>
    new Response(JSON.stringify({ error: { code: "429", message: "Too many requests." } }), {
      status: 429,
    })) as unknown as typeof fetch;

  it("stops calling the upstream after a 429", async () => {
    let calls = 0;
    const counting = (async () => {
      calls += 1;
      return new Response(JSON.stringify({ error: { code: "429" } }), { status: 429 });
    }) as unknown as typeof fetch;
    const backend = backendWith(counting);

    const first = await backend.getFeed("azure-cost" as never).catch((e: unknown) => e);
    // Surface what the feed actually threw, so a mismatch in throttle detection
    // shows here rather than as an opaque call count.
    const detail = (first as { detail?: string }).detail ?? (first as Error).message;
    expect(String(detail)).toMatch(/429/);
    const afterFirst = calls;
    await expect(backend.getFeed("azure-cost" as never)).rejects.toThrow();

    // The second request must not have reached Cost Management at all.
    expect(calls).toBe(afterFirst);
  });

  it("serves the persisted answer as stale during the cooldown", async () => {
    const store = { read: async () => feed, write: async () => undefined };
    const backend = backendWith(throttled, store);

    await expect(backend.getFeed("azure-cost" as never)).resolves.toMatchObject({ stale: true });
    // Still inside the cooldown, still answered, still marked stale.
    await expect(backend.getFeed("azure-cost" as never)).resolves.toMatchObject({
      stale: true,
      total: 1.4,
    });
  });
});
