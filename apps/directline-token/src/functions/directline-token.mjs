import { randomUUID } from "node:crypto";
import { app } from "@azure/functions";
import { exchangeSecretForToken, TokenExchangeError } from "../tokenExchange.mjs";

// =============================================================================
// POST /api/directline/token
//
// The only endpoint in this function app. It is anonymous by design: it is the
// component that *holds* the credential, so there is nothing for the browser to
// authenticate with. What keeps it from being an open token faucet is:
//
//   * `trustedOrigins` — Direct Line embeds the allowed client domains in the
//     token itself, so a token minted here is only usable from the control
//     tower's own origin.
//   * the CORS allow-list below, which refuses to answer other origins.
//   * Functions' platform rate limiting, plus the fact that a leaked token
//     expires in ~30 minutes and is scoped to one conversation.
//
// Application settings (all set by L6; the secret is a Key Vault reference, so
// its value never appears in this repo or in a pipeline log):
//
//   DIRECTLINE_SECRET            @Microsoft.KeyVault(...) -> the Direct Line secret
//   DIRECTLINE_ALLOWED_ORIGINS   comma-separated; the control tower's origin(s)
//   DIRECTLINE_DOMAIN            optional; regional Direct Line host
// =============================================================================

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
    headers["access-control-allow-headers"] = "content-type, accept";
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

  if (allowed.length > 0 && origin && !allowed.includes(origin)) {
    context.warn(`Refused a token request from a non-allow-listed origin: ${origin}`);
    return {
      status: 403,
      headers,
      jsonBody: { error: "This origin is not allowed to request a Direct Line token." },
    };
  }

  try {
    const token = await exchangeSecretForToken({
      secret: process.env.DIRECTLINE_SECRET,
      randomUUID,
      baseUrl: process.env.DIRECTLINE_DOMAIN || undefined,
      trustedOrigins: allowed.length > 0 ? allowed : undefined,
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
