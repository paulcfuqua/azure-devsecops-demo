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
  /**
   * Where the user can recover, when recovery is a thing they can do (F149).
   * Present only for an expired sign-in; absent for every other failure, so the
   * UI cannot offer a sign-in link for a problem signing in would not fix.
   */
  readonly signInUrl?: string;

  constructor(message: string, options?: { signInUrl?: string }) {
    super(message);
    this.name = "DirectLineTokenError";
    if (options?.signInUrl) this.signInUrl = options.signInUrl;
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
 * THE BROWSER FORWARDS ITS OWN IDENTITY. This comment used to say the opposite -
 * "no `Authorization` header, no credentials... the browser authenticates to
 * nothing here" - because the endpoint was anonymous, guarded only by an Origin
 * allow-list. An `Origin` header is a string any direct caller can send, so that
 * guard stopped a browser on another site and nothing else.
 *
 * The control tower already sits behind Container Apps Easy Auth, so this page
 * cannot have loaded without a completed Entra sign-in. `/.auth/me` hands the
 * page that token; it is forwarded here and verified server-side before the
 * Direct Line secret is exchanged. The copilot inherits the identity of the app
 * rather than sitting open beside it, and the user signs in exactly once.
 */
/**
 * This session's Entra id token, from Easy Auth's own endpoint.
 *
 * `/.auth/me` is served by the Easy Auth middleware in front of the container,
 * same-origin and cookie-authenticated, so the page needs no client id, no
 * secret and no MSAL. It returns null rather than throwing when the endpoint is
 * absent or unauthenticated - a local `npm run dev` has no Easy Auth in front of
 * it, and that should surface as the typed error above rather than a stack trace.
 */
/**
 * Three outcomes, not two (F150). "No token" collapsed a signed-OUT session and
 * a signed-in session whose token store holds nothing into one null, and they
 * need opposite advice: the first is fixed by signing in, the second is a
 * deployment fault that signing in will not touch.
 */
type EasyAuthRead =
  | { kind: "token"; token: string }
  | { kind: "signed-out" }
  | { kind: "no-token" };

async function readEasyAuthToken(doFetch: typeof globalThis.fetch): Promise<EasyAuthRead> {
  try {
    // `redirect: "manual"` because /.auth/me answers an unauthenticated caller
    // with a 302 to Entra - verified against the deployed app. Following it
    // lands on login.microsoftonline.com, where CORS throws and every failure
    // looks identical. Held manually, the redirect IS the answer: not signed in.
    const res = await doFetch("/.auth/me", {
      headers: { accept: "application/json" },
      redirect: "manual",
    });
    if (res.type === "opaqueredirect" || res.status === 0) return { kind: "signed-out" };
    if (res.status === 401 || res.status === 403) return { kind: "signed-out" };
    if (res.status >= 300 && res.status < 400) return { kind: "signed-out" };
    if (!res.ok) return { kind: "no-token" };

    const body: unknown = await res.json();
    // Easy Auth returns a single-element array of principals.
    const first = Array.isArray(body) ? body[0] : undefined;
    const token = (first as { id_token?: unknown } | undefined)?.id_token;
    if (typeof token === "string" && token !== "") return { kind: "token", token };
    // Claims came back but no raw token: the token store is off (F135).
    return { kind: "no-token" };
  } catch {
    // A thrown fetch is a local `npm run dev` with no Easy Auth in front of it,
    // or a network fault. Neither is a session problem.
    return { kind: "no-token" };
  }
}

/**
 * Ask Easy Auth to mint a fresh token for this session.
 *
 * THE ID TOKEN EXPIRES AND NOTHING WAS RENEWING IT (F142). It is issued at
 * sign-in with roughly an hour's life, the token store persists exactly what was
 * issued, and the Function verifies expiry - correctly. So the Ask tab worked for
 * an hour after sign-in and then locked the user out of their own agent, with a
 * 401 that read like an outage. Proven by an Incognito window: a fresh sign-in
 * answered immediately.
 *
 * ITS PRECONDITION IS NOT MET ON THIS DEPLOYMENT, AND F142 DID NOT CHECK (F149).
 * Redeeming a refresh token is a confidential-client grant: it needs a client
 * secret AND an `offline_access` scope, and this app's Easy Auth registration
 * has neither, so no refresh token is ever issued and this call can only fail.
 * It is kept because a fork that DOES configure a secret gets a silent renewal
 * from it for free — but it is no longer load-bearing, and
 * `easyAuthSignInAgainUrl` below is the path that works with no credential.
 *
 * Returns true when a refresh plausibly succeeded. NO NAVIGATION happens here on
 * purpose: redirecting to a login endpoint automatically is how a bad session
 * becomes a redirect loop, and a loop is a worse failure than the one being
 * fixed. When this cannot help, the caller says so in words and offers a link.
 */
async function refreshEasyAuthSession(doFetch: typeof globalThis.fetch): Promise<boolean> {
  try {
    const res = await doFetch("/.auth/refresh", { headers: { accept: "application/json" } });
    return res.ok;
  } catch {
    return false;
  }
}

/**
 * Where to send someone whose sign-in has expired (F149).
 *
 * `/.auth/refresh` CANNOT WORK ON THIS APP, and F142 shipped a retry that
 * depended on it. Redeeming a refresh token is a confidential-client grant, so
 * it needs two things this deployment deliberately does not have:
 *
 *   az containerapp auth show ... identityProviders.azureActiveDirectory
 *     registration.clientSecretSettingName : (none)
 *     login (scopes)                       : (none - so no offline_access)
 *
 * No client secret and no `offline_access` means no refresh token is ever
 * issued, so there is nothing for `/.auth/refresh` to redeem. The retry could
 * never have succeeded on any run.
 *
 * Reloading does not help either, and the old message said it did: the session
 * cookie is still valid, so Easy Auth serves the SAME stored token rather than
 * re-authenticating. That is why an Incognito window worked and F5 did not.
 *
 * LOG IN, DO NOT LOG OUT (F150). The first version of this pointed at
 * `/.auth/logout`, on the theory that ending the session would let the app's own
 * `unauthenticatedClientAction: RedirectToLoginPage` start a fresh flow. It made
 * things strictly worse: the user got an account picker, signed OUT, and landed
 * back on a cached copy of the page with no session and no way in - the error
 * then read "could not read this session's Entra token", which is true and
 * useless.
 *
 * `/.auth/login/aad` re-runs the authorization-code flow directly, keeping the
 * session it already has. Verified against the deployed app rather than assumed
 * - every one of these answers 302 to Entra's authorize endpoint:
 *
 *   GET /                                          302 -> login.microsoftonline.com
 *   GET /.auth/me                                  302 -> login.microsoftonline.com
 *   GET /.auth/login/aad?post_login_redirect_uri=/ 302 -> login.microsoftonline.com
 *
 * Because Entra normally still holds a live browser session, that round trip is
 * a redirect rather than a password prompt, and it writes a brand new id_token
 * into the token store. It is also a server endpoint, so it cannot be answered
 * from the browser cache the way `/` can - which is the other half of what went
 * wrong.
 *
 * Exported so the UI renders it as a link the user CLICKS. Navigating
 * automatically on a 401 is what turns one bad token into a redirect loop.
 */
export function easyAuthSignInAgainUrl(currentPath = "/"): string {
  return `/.auth/login/aad?post_login_redirect_uri=${encodeURIComponent(currentPath)}`;
}

export function createTokenFetcher(
  tokenUrl: string,
  { fetchImpl }: TokenFetcherOptions = {},
): TokenFetcher {
  return async function fetchDirectLineToken(): Promise<DirectLineToken> {
    const doFetch = fetchImpl ?? globalThis.fetch;
    const here = globalThis.location?.pathname ?? "/";
    const read = await readEasyAuthToken(doFetch);

    // Signed out is a state the reader can leave; say so and point at the door.
    if (read.kind === "signed-out") {
      throw new DirectLineTokenError(
        "You are not signed in, so the Ask tab cannot prove who is asking.",
        { signInUrl: easyAuthSignInAgainUrl(here) },
      );
    }
    // Signed in, but the token store handed back no raw token. Signing in again
    // does nothing for this - it is the deployment, not the session (F135).
    if (read.kind === "no-token") {
      throw new DirectLineTokenError(
        "Signed in, but Easy Auth returned no token for this session, so the Ask tab " +
          "cannot prove who is asking. The control tower needs Easy Auth's token store " +
          "enabled; without it /.auth/me returns claims and no id_token, and the token " +
          "endpoint will refuse the request.",
      );
    }
    const idToken = read.token;
    const request = (bearer: string): Promise<Response> =>
      doFetch(tokenUrl, {
        method: "POST",
        headers: {
          accept: "application/json",
          authorization: `Bearer ${bearer}`,
        },
      });

    let res = await request(idToken);

    // A 401 here means the token was read but not accepted, and by far the most
    // likely reason is that it expired (F142). One refresh, one retry - never a
    // loop: if the second attempt also fails the caller gets a sentence telling
    // them to sign in again, which is true and actionable, rather than a retry
    // that cannot succeed.
    if (res.status === 401 && (await refreshEasyAuthSession(doFetch))) {
      const renewed = await readEasyAuthToken(doFetch);
      if (renewed.kind === "token" && renewed.token !== idToken) {
        res = await request(renewed.token);
      }
    }

    if (res.status === 401) {
      // Not "reload the page" (F149): a reload sends the same valid session
      // cookie and Easy Auth hands back the same expired token. Re-running the
      // login flow is the part that actually changes anything (F150) - and it
      // is a LOGIN, not a logout, which only removed the way back in.
      throw new DirectLineTokenError(
        "This sign-in has expired, so the Ask tab cannot prove who is asking. " +
          "Sign in again to continue — the agent itself is fine.",
        { signInUrl: easyAuthSignInAgainUrl(here) },
      );
    }
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
