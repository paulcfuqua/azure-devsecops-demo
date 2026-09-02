/**
 * Durable last-good store for the azure-cost feed (F139).
 *
 * WHY THIS EXISTS. `cloud.ts` already serves a cached figure with `stale: true`
 * when Cost Management refuses — that logic is correct and it almost never got
 * to run. The cache was an in-memory field on a container with
 * `minReplicas: 0`, so it died with the process: every scale-to-zero, every
 * deploy. The comment beside the retry budget said "the hour-long cache above is
 * the real fallback", and on a container that idles out that premise was false.
 *
 * The result was the Ops tab answering 502 at exactly the moment a demo starts —
 * a cold container's first request is a cold cache, and Cost Management's
 * throttle lasts minutes.
 *
 * NO NEW DEPENDENCY. Blob is two REST calls, and this repository tracks its own
 * supply chain closely enough (SBOM, Dependabot, Trivy) that adding a storage
 * SDK to read and write one JSON document is a poor trade. The credential is the
 * one every other upstream already uses.
 *
 * NOTHING HERE MAY FAIL A REQUEST. A cache is an optimisation; if the store is
 * unreachable, misconfigured or empty, the feed behaves exactly as it did before
 * this file existed. Every method swallows its errors and reports them to the
 * caller as "no value" rather than throwing.
 */
import type { AzureCostFeed } from "../contract/feeds.js";
import type { TokenProvider } from "./azureAuth.js";
import { SCOPE_STORAGE } from "./azureAuth.js";

/** The one blob. A single document, overwritten in place. */
const BLOB_NAME = "azure-cost-last-good.json";

/** Blob REST API version. Pinned: an unset `x-ms-version` picks a server default. */
const BLOB_API_VERSION = "2021-08-06";

export interface CostCacheStore {
  /** The last good feed, or undefined when there is none or it cannot be read. */
  read(): Promise<AzureCostFeed | undefined>;
  /** Persist a feed. Never throws; a failed write is logged and ignored. */
  write(feed: AzureCostFeed): Promise<void>;
}

/** What the feed gets when no container is configured: the previous behaviour. */
export const noopCostCacheStore: CostCacheStore = {
  read: async () => undefined,
  write: async () => undefined,
};

export interface BlobCostCacheStoreOptions {
  /** Container URI, e.g. https://acct.blob.core.windows.net/cost-cache */
  containerUri: string;
  tokens: TokenProvider;
  fetchImpl?: typeof fetch;
  /** Injected so a failed write is visible in logs without a console dependency. */
  onError?: (message: string) => void;
}

export class BlobCostCacheStore implements CostCacheStore {
  private readonly blobUrl: string;

  constructor(private readonly options: BlobCostCacheStoreOptions) {
    // Tolerate a configured URI with or without a trailing slash: it arrives from
    // a Bicep string concat, and a double slash is a 404 that would look like an
    // empty cache rather than a misconfiguration.
    this.blobUrl = `${options.containerUri.replace(/\/+$/, "")}/${BLOB_NAME}`;
  }

  private get doFetch(): typeof fetch {
    return this.options.fetchImpl ?? globalThis.fetch;
  }

  async read(): Promise<AzureCostFeed | undefined> {
    try {
      const token = await this.options.tokens.getToken(SCOPE_STORAGE);
      const res = await this.doFetch(this.blobUrl, {
        headers: {
          authorization: `Bearer ${token}`,
          "x-ms-version": BLOB_API_VERSION,
        },
      });
      // 404 is the ordinary empty-cache case on a fresh estate, not a fault.
      if (res.status === 404) return undefined;
      if (!res.ok) {
        this.options.onError?.(`cost cache read failed: HTTP ${res.status}`);
        return undefined;
      }
      const body: unknown = await res.json();
      return isAzureCostFeed(body) ? body : undefined;
    } catch (error: unknown) {
      this.options.onError?.(
        `cost cache read failed: ${error instanceof Error ? error.message : String(error)}`,
      );
      return undefined;
    }
  }

  async write(feed: AzureCostFeed): Promise<void> {
    try {
      const token = await this.options.tokens.getToken(SCOPE_STORAGE);
      const res = await this.doFetch(this.blobUrl, {
        method: "PUT",
        headers: {
          authorization: `Bearer ${token}`,
          "x-ms-version": BLOB_API_VERSION,
          "x-ms-blob-type": "BlockBlob",
          "content-type": "application/json",
        },
        // Always written with stale:false. Whether a READER should call it stale
        // depends on when it is read, not on when it was written, and cloud.ts
        // makes that decision.
        body: JSON.stringify({ ...feed, stale: false }),
      });
      if (!res.ok) this.options.onError?.(`cost cache write failed: HTTP ${res.status}`);
    } catch (error: unknown) {
      this.options.onError?.(
        `cost cache write failed: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }
}

/**
 * A shape check, not a schema validation, and deliberately narrow: this reads a
 * document THIS SERVICE wrote, so the risk is a stale format after a deploy, not
 * a hostile payload. The fields checked are the ones a caller would otherwise
 * dereference into `undefined` and render as a blank total.
 */
function isAzureCostFeed(value: unknown): value is AzureCostFeed {
  if (typeof value !== "object" || value === null) return false;
  const feed = value as Partial<AzureCostFeed>;
  return (
    typeof feed.asOf === "string" &&
    typeof feed.currency === "string" &&
    typeof feed.total === "number" &&
    Array.isArray(feed.daily)
  );
}
