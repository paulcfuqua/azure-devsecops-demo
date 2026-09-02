import { randomUUID } from "node:crypto";
import { app } from "@azure/functions";
import { exchangeSecretForToken, TokenExchangeError } from "../tokenExchange.mjs";
import { createJwks, verifyUserToken, UserTokenError } from "../userToken.mjs";

// =============================================================================
// POST /api/directline/token
//
// The only endpoint in this function app. `authLevel` is "anonymous" because a
// FUNCTION KEY would be a second credential shipped to a browser; the caller is
// authenticated instead by the Entra token it forwards. Three things guard it:
//
//   * THE USER TOKEN. The control tower sits behind Container Apps Easy Auth, so
//     every browser that can load the Ask tab has already signed in to Entra.
//     The page forwards that token and it is verified here - signature, issuer,
//     audience and expiry - before the Direct Line secret is exchanged. The
//     copilot inherits the app's identity rather than sitting open beside it.
//   * `trustedOrigins` — Direct Line embeds the allowed client domains in the
//     token itself, so a token minted here is only usable from the control
//     tower's own origin.
//   * the origin guard below, which refuses to mint at all when
//     DIRECTLINE_ALLOWED_ORIGINS is unset (500) or the caller sent no Origin
//     or a non-allow-listed one (403).
//
// THE ORIGIN GUARD WAS NEVER ENOUGH ON ITS OWN, and this comment used to say it
// was ("the only thing standing between this endpoint and an open faucet"). It
// stops a browser on someone else's page and nothing else: an `Origin` header is
// a string any direct caller can send, which was demonstrated with a single
// `curl -H "Origin: <control tower>"` that minted a working token and held a
// full conversation with the agent. That was tolerable while the AGENT required
// its own Microsoft sign-in; it stopped being tolerable when the agent moved to
// "No authentication" to work over Direct Line at all (F128), because then
// nothing authenticated the human. Hence the user token above.
//
// There is still no rate limiting: host.json configures none. A leaked token
// expires in ~30 minutes and is scoped to one conversation.
//
// Application settings (all set by L6; the secret is a Key Vault reference, so
// its value never appears in this repo or in a pipeline log):
//
//   DIRECTLINE_SECRET            @Microsoft.KeyVault(...) -> the Direct Line secret
//   DIRECTLINE_ALLOWED_ORIGINS   comma-separated; the control tower's origin(s)
//   DIRECTLINE_DOMAIN            optional; regional Direct Line host
//   DIRECTLINE_USER_TENANT_ID    Entra tenant whose tokens are accepted
//   DIRECTLINE_USER_AUDIENCE     the control tower's Easy Auth client id; a token
//                                minted for a DIFFERENT app is not permission to
//                                use this one, so the audience is checked too
// =============================================================================

// Built once per process, not per request: createRemoteJWKSet caches Entra's
// signing keys and refetches only on an unknown `kid`, so rebuilding it per
// request would turn every token check into a network round trip.
let jwksCache;
function jwksFor(tenantId) {
  if (!jwksCache || jwksCache.tenantId !== tenantId) {
    jwksCache = { tenantId, keys: createJwks(tenantId) };
  }
  return jwksCache.keys;
}

function allowedOrigins() {
  return (process.env.DIRECTLINE_ALLOWED_ORIGINS ?? "")
    .split(",")
    .map((origin) => origin.trim())
    .filter((origin) => origin !== "");
}

function corsHeaders(requestOrigin) {
  const allowed = allowedOrigins();
  const headers = {
    "content-type": "application/json",
    // A token must never be cached by a proxy or the browser.
    "cache-control": "no-store",
    vary: "Origin",
  };
  if (requestOrigin && allowed.includes(requestOrigin)) {
    headers["access-control-allow-origin"] = requestOrigin;
    headers["access-control-allow-methods"] = "POST, OPTIONS";
    headers["access-control-allow-headers"] = "authorization, content-type, accept";
    headers["access-control-max-age"] = "600";
  }
  return headers;
}

export async function directLineToken(request, context) {
  const origin = request.headers.get("origin") ?? undefined;
  const headers = corsHeaders(origin);
  const allowed = allowedOrigins();

  if (request.method === "OPTIONS") {
    return { status: 204, headers };
  }

  if (allowed.length === 0) {
    // Refuse to mint an unbound token when the allow-list was never
    // configured: skipping this would also drop the minted token's own
    // origin binding (trustedOrigins below), not just this guard.
    context.error("DIRECTLINE_ALLOWED_ORIGINS is unset; refusing to mint an unbound token.");
    return {
      status: 500,
      headers,
      jsonBody: { error: "Token endpoint is not configured." },
    };
  }

  if (!origin || !allowed.includes(origin)) {
    context.warn(`Refused a token request from a non-allow-listed origin: ${origin}`);
    return {
      status: 403,
      headers,
      jsonBody: { error: "This origin is not allowed to request a Direct Line token." },
    };
  }

  // The caller's identity, before any credential is touched.
  const tenantId = process.env.DIRECTLINE_USER_TENANT_ID;
  const audience = process.env.DIRECTLINE_USER_AUDIENCE;
  try {
    const user = await verifyUserToken({
      authorization: request.headers.get("authorization") ?? undefined,
      tenantId,
      audience,
      jwks: tenantId ? jwksFor(tenantId) : undefined,
    });
    // An identity, never a token. `oid` is the stable Entra object id.
    context.log(`Minting a Direct Line token for ${user.oid ?? user.sub ?? "an unnamed principal"}.`);
  } catch (error) {
    const status = error instanceof UserTokenError ? error.status : 401;
    context.warn(`Refused a token request: ${error.message}`);
    return {
      status,
      headers,
      jsonBody: {
        error:
          status === 500
            ? "Token endpoint is not configured."
            : "A valid Entra user token is required to request a Direct Line token.",
      },
    };
  }

  try {
    const token = await exchangeSecretForToken({
      secret: process.env.DIRECTLINE_SECRET,
      randomUUID,
      baseUrl: process.env.DIRECTLINE_DOMAIN || undefined,
      // allowed is never empty here: the allow-list guard above already
      // refused the request (500) before this point if it were.
      trustedOrigins: allowed,
    });
    return { status: 200, headers, jsonBody: token };
  } catch (error) {
    const status = error instanceof TokenExchangeError ? error.status : 500;
    // Log the reason server-side; return a message with no upstream detail.
    context.error(`Direct Line token exchange failed: ${error.message}`);
    return {
      status,
      headers,
      jsonBody: {
        error:
          status === 500
            ? "The Direct Line token endpoint is not configured."
            : "The Direct Line token exchange failed.",
      },
    };
  }
}

app.http("directline-token", {
  route: "directline/token",
  methods: ["POST", "OPTIONS"],
  authLevel: "anonymous",
  handler: directLineToken,
});
