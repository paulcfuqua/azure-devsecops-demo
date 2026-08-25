/**
 * Token acquisition for every Azure upstream — one credential, three scopes,
 * no stored secret anywhere (hard rule 5).
 *
 * In the container app this resolves to the app's managed identity. On a
 * developer machine `DefaultAzureCredential` falls back to the signed-in
 * Azure CLI, which is why the cloud path is *authorable* pre-tenant even
 * though nothing in this repo may execute it yet.
 *
 * Tokens are cached in-process until five minutes before expiry. Without that,
 * a page load that fans out to eight routes would trigger eight IMDS round
 * trips; with it, one.
 */
import { DefaultAzureCredential, type TokenCredential } from "@azure/identity";
import { ApiError } from "../errors.js";

/** Azure SQL *and* the Fabric SQL analytics endpoint both take this audience. */
export const SCOPE_SQL = "https://database.windows.net/.default";
/** ARM — Microsoft.Security/secureScores lives here. */
export const SCOPE_ARM = "https://management.azure.com/.default";
/** Azure Monitor Log Analytics query API. */
export const SCOPE_LOG_ANALYTICS = "https://api.loganalytics.io/.default";

export interface TokenProvider {
  /** Bearer token for `scope`. Throws a typed ApiError on failure. */
  getToken(scope: string): Promise<string>;
}

interface CacheEntry {
  token: string;
  /** epoch ms at which this entry stops being handed out */
  refreshAt: number;
}

const REFRESH_SKEW_MS = 5 * 60 * 1000;

export class AzureTokenProvider implements TokenProvider {
  private readonly cache = new Map<string, CacheEntry>();
  private readonly inflight = new Map<string, Promise<string>>();

  constructor(private readonly credential: TokenCredential) {}

  async getToken(scope: string): Promise<string> {
    const now = Date.now();
    const cached = this.cache.get(scope);
    if (cached && cached.refreshAt > now) return cached.token;

    // Collapse concurrent misses: eight parallel requests after a cold start
    // should mint one token, not eight.
    const pending = this.inflight.get(scope);
    if (pending) return pending;

    const attempt = this.fetchToken(scope).finally(() => {
      this.inflight.delete(scope);
    });
    this.inflight.set(scope, attempt);
    return attempt;
  }

  private async fetchToken(scope: string): Promise<string> {
    let result: Awaited<ReturnType<TokenCredential["getToken"]>>;
    try {
      result = await this.credential.getToken(scope);
    } catch (err) {
      // The identity SDK's message can quote the IMDS response; keep it server-side.
      throw ApiError.upstream("Entra ID token", err);
    }
    if (!result || !result.token) {
      throw ApiError.upstream(
        "Entra ID token",
        `credential returned no token for scope ${scope}`,
      );
    }
    this.cache.set(scope, {
      token: result.token,
      refreshAt: Math.max(Date.now(), result.expiresOnTimestamp - REFRESH_SKEW_MS),
    });
    return result.token;
  }
}

/**
 * The credential the cloud backends use. A user-assigned identity's client id
 * is configuration, not a secret — it is a GUID that is useless without the
 * identity's own federated trust.
 */
export function createCredential(managedIdentityClientId?: string): TokenCredential {
  return new DefaultAzureCredential(
    managedIdentityClientId ? { managedIdentityClientId } : {},
  );
}
