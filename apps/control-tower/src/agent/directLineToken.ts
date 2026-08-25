import type { DirectLineToken, TokenFetcher } from "./types";

/**
 * The browser half of the Direct Line token exchange.
 *
 * Microsoft's guidance is unambiguous — from "Configure web and Direct Line
 * channel security" (https://learn.microsoft.com/en-us/microsoft-copilot-studio/configure-web-security):
 *
 *   "If you're writing an app where the client runs in a web browser or mobile
 *    app, or otherwise the code might be visible to customers, you must
 *    exchange your secret for a token. [...] Don't expose the secret in any
 *    code that runs in the browser, either hard-coded or transferred through a
 *    network call. Acquiring the token by using the secret in your service code
 *    is the most secure way to protect your Copilot Studio agent."
 *
 * So the split is:
 *
 *   browser  ──POST {tokenUrl}──▶  apps/directline-token (Azure Function)
 *                                        │  holds the Direct Line secret
 *                                        │  (Key Vault / managed identity)
 *                                        ▼
 *                                  POST https://directline.botframework.com
 *                                       /v3/directline/tokens/generate
 *                                  Authorization: Bearer <secret>
 *                                        │
 *   browser  ◀──{token, expires_in, conversationId}──┘
 *
 * The token is conversation-scoped and short-lived (Direct Line issues
 * `expires_in: 1800`, i.e. 30 minutes). Everything below exists to make it
 * structurally impossible for anything else to reach the browser.
 */

/**
 * Response keys that must never appear in a token payload. If the token
 * endpoint is ever misconfigured to proxy Direct Line's *secret* side, we fail
 * loudly instead of quietly handing a long-lived credential to the page.
 */
const SECRET_SHAPED_KEYS = [
  "secret",
  "directlinesecret",
  "directline_secret",
  "apikey",
  "api_key",
  "clientsecret",
  "client_secret",
  "password",
  "connectionstring",
];

export class DirectLineTokenError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DirectLineTokenError";
  }
}

/**
 * Throws if `payload` carries anything secret-shaped, at any depth.
 *
 * Exported because it is the assertion the security test drives: the seam must
 * refuse a leaking endpoint, not merely ignore the extra field.
 */
export function assertNoSecretMaterial(payload: unknown, path = "response"): void {
  if (Array.isArray(payload)) {
    payload.forEach((item, i) => assertNoSecretMaterial(item, `${path}[${i}]`));
    return;
  }
  if (payload === null || typeof payload !== "object") return;

  for (const [key, value] of Object.entries(payload as Record<string, unknown>)) {
    const normalized = key.toLowerCase().replace(/[-\s]/g, "");
    if (SECRET_SHAPED_KEYS.includes(normalized)) {
      throw new DirectLineTokenError(
        `The Direct Line token endpoint returned a '${path}.${key}' field. ` +
          "A token endpoint must return only a short-lived token — never secret " +
          "material. Refusing the response; fix the endpoint before re-enabling " +
          "the Ask tab.",
      );
    }
    assertNoSecretMaterial(value, `${path}.${key}`);
  }
}

/**
 * Narrows an arbitrary token-endpoint response down to the three fields the
 * app is allowed to know. Anything else the endpoint chose to send is dropped
 * here and never enters application state.
 */
export function parseTokenResponse(payload: unknown): DirectLineToken {
  assertNoSecretMaterial(payload);

  if (payload === null || typeof payload !== "object") {
    throw new DirectLineTokenError(
      "The Direct Line token endpoint did not return a JSON object.",
    );
  }
  const raw = payload as Record<string, unknown>;
  const token = raw.token;
  if (typeof token !== "string" || token.length === 0) {
    throw new DirectLineTokenError(
      "The Direct Line token endpoint returned no `token`. Expected the shape " +
        "documented for POST /v3/directline/tokens/generate: " +
        "{ token, expires_in, conversationId }.",
    );
  }

  // Direct Line spells it `expires_in`; accept the camelCase spelling too so a
  // hand-written endpoint that normalised the field still works.
  const expiresRaw = raw.expires_in ?? raw.expiresIn;
  const expiresInSeconds =
    typeof expiresRaw === "number" && Number.isFinite(expiresRaw) ? expiresRaw : undefined;

  const conversationId =
    typeof raw.conversationId === "string" ? raw.conversationId : undefined;

  // Direct Line requires user ids to begin with `dl_` and recommends they be
  // unguessable; the token endpoint mints one and embeds it in the token, so
  // the client has to echo the same value on outbound activities.
  const userId = typeof raw.userId === "string" ? raw.userId : undefined;

  return Object.freeze({ token, expiresInSeconds, conversationId, userId });
}

export interface TokenFetcherOptions {
  /** Injectable for tests; defaults to the global `fetch`. */
  fetchImpl?: typeof fetch;
}

/**
 * Builds the `TokenFetcher` the Direct Line provider uses.
 *
 * Note what is *absent*: no `Authorization` header, no credentials, no secret.
 * The browser authenticates to nothing here — the token endpoint is anonymous
 * by design (it is the thing that holds the credential) and is expected to be
 * rate-limited and origin-restricted server-side. See
 * `apps/directline-token/README.md`.
 */
export function createTokenFetcher(
  tokenUrl: string,
  { fetchImpl }: TokenFetcherOptions = {},
): TokenFetcher {
  return async function fetchDirectLineToken(): Promise<DirectLineToken> {
    const doFetch = fetchImpl ?? globalThis.fetch;
    const res = await doFetch(tokenUrl, {
      method: "POST",
      headers: { accept: "application/json" },
    });
    if (!res.ok) {
      throw new DirectLineTokenError(
        `The Direct Line token endpoint (${tokenUrl}) responded ${res.status}. ` +
          "The Ask tab needs the deployed environment: a published Copilot Studio " +
          "agent, its Direct Line channel, and the token endpoint from " +
          "apps/directline-token.",
      );
    }
    return parseTokenResponse(await res.json());
  };
}
