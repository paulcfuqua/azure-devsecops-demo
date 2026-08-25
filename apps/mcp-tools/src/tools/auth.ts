/**
 * Authentication for the cloud adapters.
 *
 * HARD RULE 5 — no stored credentials. Nothing here reads a password, a client
 * secret or a certificate. Every Azure call authenticates with a **managed
 * identity** token obtained through `@azure/identity`'s `DefaultAzureCredential`:
 * on the Container App that resolves to the app's assigned managed identity; on
 * a developer laptop it resolves to `az login` / VS Code / Azure PowerShell,
 * which is what makes the same code path debuggable without a stored secret.
 * When `AZURE_CLIENT_ID` is set it is passed as `managedIdentityClientId` so a
 * **user-assigned** identity is selected deterministically — an ACA app with
 * more than one identity assigned is otherwise ambiguous.
 *
 * GitHub has no managed identity story, so it uses a token supplied by the
 * environment (`GITHUB_TOKEN`, injected from Key Vault by the platform, never
 * committed). It is read once, held in memory, and never logged: the only thing
 * this module will ever print about a token is its *expiry*.
 *
 * `@azure/identity` is imported LAZILY. The local backend must boot on a laptop
 * with no tenant and no Azure SDK warm-up cost, and `MLS_TOOL_BACKENDS=local`
 * never touches this file's credential path.
 */
import { AdapterError } from "./errors.js";

/**
 * The slice of `@azure/identity`'s `TokenCredential` this service uses.
 * Declared structurally rather than imported as a type so nothing in the local
 * path has a compile-time edge to the Azure SDK, and so tests can inject a fake
 * credential without the package present.
 */
export interface TokenCredentialLike {
  getToken(
    scopes: string | string[],
    options?: unknown,
  ): Promise<{ token: string; expiresOnTimestamp: number } | null>;
}

/** Entra scopes, one per upstream data plane. */
export const SCOPES = {
  /** Azure Resource Manager: Defender secure scores, Cost Management, budgets. */
  arm: "https://management.azure.com/.default",
  /** Azure Monitor Log Analytics query data plane. */
  logAnalytics: "https://api.loganalytics.io/.default",
  /** Fabric / SQL Database TDS endpoint — the SQL analytics endpoint speaks this. */
  sql: "https://database.windows.net/.default",
} as const;

/** Re-acquire this long before actual expiry rather than racing the clock. */
const EXPIRY_SKEW_MS = 5 * 60 * 1000;

/**
 * Caches one token per scope and refreshes it EXPIRY_SKEW_MS before expiry.
 *
 * `DefaultAzureCredential` caches internally too, but it is not free to call on
 * every request and its cache is not observable from a test. This wrapper makes
 * the refresh decision explicit, testable, and shared by all four Azure
 * adapters, so a token is fetched about once an hour rather than once per tool
 * call.
 */
export class TokenProvider {
  private readonly cache = new Map<string, { token: string; expiresOnTimestamp: number }>();
  private readonly inflight = new Map<string, Promise<string>>();

  constructor(
    private readonly credential: TokenCredentialLike,
    private readonly now: () => number = () => Date.now(),
  ) {}

  async getToken(scope: string): Promise<string> {
    const cached = this.cache.get(scope);
    if (cached && cached.expiresOnTimestamp - EXPIRY_SKEW_MS > this.now()) return cached.token;

    // Collapse concurrent misses onto one credential call — five tools calling
    // at once must not become five token requests.
    const existing = this.inflight.get(scope);
    if (existing) return existing;

    const pending = this.acquire(scope).finally(() => this.inflight.delete(scope));
    this.inflight.set(scope, pending);
    return pending;
  }

  private async acquire(scope: string): Promise<string> {
    let result: { token: string; expiresOnTimestamp: number } | null;
    try {
      result = await this.credential.getToken(scope);
    } catch (err) {
      throw new AdapterError(
        "auth",
        `Managed-identity token acquisition failed for ${scope}. Check that the container ` +
          `app has a managed identity assigned and that it holds the required role ` +
          `(Reader / Log Analytics Reader / Cost Management Reader). ` +
          `Cause: ${err instanceof Error ? err.message : String(err)}`,
        { service: "entra", cause: err },
      );
    }
    if (!result?.token) {
      throw new AdapterError(
        "auth",
        `Managed-identity token acquisition returned no token for ${scope}. ` +
          `DefaultAzureCredential found no usable identity in this environment.`,
        { service: "entra" },
      );
    }
    this.cache.set(scope, result);
    return result.token;
  }

  /** `Authorization` header for a scope. Callers never see the raw token. */
  async authHeader(scope: string): Promise<Record<string, string>> {
    return { authorization: `Bearer ${await this.getToken(scope)}` };
  }
}

/**
 * Build a `DefaultAzureCredential`, honouring `AZURE_CLIENT_ID` for a
 * user-assigned managed identity. Lazily imports `@azure/identity` so that the
 * local backend never loads it.
 */
export async function createDefaultCredential(
  env: NodeJS.ProcessEnv = process.env,
): Promise<TokenCredentialLike> {
  let identity: { DefaultAzureCredential: new (options?: unknown) => TokenCredentialLike };
  try {
    identity = (await import("@azure/identity")) as unknown as typeof identity;
  } catch (err) {
    throw new AdapterError(
      "config",
      "MLS_TOOL_BACKENDS=cloud requires the @azure/identity package. " +
        "Run `npm install` in apps/mcp-tools (it is a declared dependency; the local " +
        "backend simply never loads it).",
      { service: "entra", cause: err },
    );
  }
  const clientId = env.AZURE_CLIENT_ID?.trim();
  // managedIdentityClientId disambiguates a user-assigned identity; omitting it
  // entirely (rather than passing undefined) keeps system-assigned the default.
  return new identity.DefaultAzureCredential(
    clientId ? { managedIdentityClientId: clientId } : {},
  );
}

/**
 * The GitHub token, from the environment only. Returns the header, never the
 * value — so no caller can accidentally log it.
 */
export function githubAuthHeader(token: string): Record<string, string> {
  if (!token || token.trim().length === 0) {
    throw new AdapterError(
      "config",
      "get_github_security needs a GitHub token in GITHUB_TOKEN (or MLS_GITHUB_TOKEN) with " +
        "the `security_events` scope. It is supplied by the environment; it is never stored " +
        "in the repo.",
      { service: "github" },
    );
  }
  return {
    authorization: `Bearer ${token.trim()}`,
    accept: "application/vnd.github+json",
    "x-github-api-version": "2022-11-28",
  };
}
