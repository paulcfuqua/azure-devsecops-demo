import { describe, expect, it, vi } from "vitest";

import { BlobCostCacheStore, noopCostCacheStore } from "../src/backends/costCacheStore.js";
import type { AzureCostFeed } from "../src/contract/feeds.js";

const CONTAINER = "https://acct.blob.core.windows.net/cost-cache";

const feed: AzureCostFeed = {
  asOf: "2026-09-02T12:00:00.000Z",
  stale: false,
  currency: "USD",
  total: 1.4,
  timeframe: "MonthToDate",
  byService: [],
  byResourceGroup: [],
  daily: [{ date: "2026-09-01", amount: 1.4 }],
} as AzureCostFeed;

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
