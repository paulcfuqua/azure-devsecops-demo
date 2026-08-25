// =============================================================================
// The Direct Line secret -> token exchange, as a pure function.
//
// Everything host-specific (Azure Functions bindings, env vars, CORS) lives in
// src/functions/directline-token.mjs. This module has no dependencies, no
// ambient state and an injectable `fetch`, so it can be reasoned about — and
// tested — on its own.
//
// Microsoft's guidance, verbatim, from "Configure web and Direct Line channel
// security"
// (https://learn.microsoft.com/en-us/microsoft-copilot-studio/configure-web-security):
//
//   "If you're writing an app where the client runs in a web browser or mobile
//    app, or otherwise the code might be visible to customers, you must
//    exchange your secret for a token. If you don't use a token, your secret
//    can be compromised... Don't expose the secret in any code that runs in the
//    browser, either hard-coded or transferred through a network call.
//    Acquiring the token by using the secret in your service code is the most
//    secure way to protect your Copilot Studio agent."
//
// Protocol, from "Direct Line Authentication in Azure AI Bot Service"
// (https://learn.microsoft.com/en-us/azure/bot-service/rest-api/bot-framework-rest-direct-line-3-0-authentication):
//
//   POST https://directline.botframework.com/v3/directline/tokens/generate
//   Authorization: Bearer <SECRET>
//   { "user": { "id": "dl_...", "name": "..." }, "trustedOrigins": ["..."] }
//
//   -> { "conversationId": "...", "token": "...", "expires_in": 1800 }
//
// The same page explains why `user.id` is worth sending: "By including these
// values, Direct Line can perform additional security validation of the user ID
// and name, inhibiting tampering of these values by malicious clients." Direct
// Line requires the id to begin with `dl_` and recommends it be unguessable.
// =============================================================================

/** Global Direct Line endpoint. Regional agents need europe./india. instead. */
export const DIRECT_LINE_DEFAULT_BASE = "https://directline.botframework.com";

/** Direct Line requires the `dl_` prefix; the rest must be unguessable. */
export function mintUserId(randomUUID) {
  return `dl_${randomUUID().replace(/-/g, "")}`;
}

export class TokenExchangeError extends Error {
  constructor(message, status) {
    super(message);
    this.name = "TokenExchangeError";
    this.status = status;
  }
}

/**
 * Exchanges the Direct Line secret for a short-lived, conversation-scoped
 * token.
 *
 * @param {object} options
 * @param {string} options.secret          The Direct Line secret. Never returned.
 * @param {() => string} options.randomUUID Injectable id source.
 * @param {typeof fetch} [options.fetchImpl]
 * @param {string} [options.baseUrl]       Direct Line host.
 * @param {string[]} [options.trustedOrigins] Domains allowed to host the client.
 * @param {string} [options.userName]      Optional display name.
 * @returns {Promise<{token: string, expires_in?: number, conversationId?: string, userId: string}>}
 */
export async function exchangeSecretForToken({
  secret,
  randomUUID,
  fetchImpl,
  baseUrl = DIRECT_LINE_DEFAULT_BASE,
  trustedOrigins,
  userName = "Control Tower",
}) {
  if (typeof secret !== "string" || secret.trim() === "") {
    // 500, not 4xx: a missing secret is a deployment fault, not a bad request.
    throw new TokenExchangeError(
      "No Direct Line secret is configured. Set DIRECTLINE_SECRET (a Key Vault reference) on the function app.",
      500,
    );
  }

  const doFetch = fetchImpl ?? globalThis.fetch;
  const userId = mintUserId(randomUUID);

  const body = { user: { id: userId, name: userName } };
  if (Array.isArray(trustedOrigins) && trustedOrigins.length > 0) {
    body.trustedOrigins = trustedOrigins;
  }

  const response = await doFetch(
    `${baseUrl.replace(/\/+$/, "")}/v3/directline/tokens/generate`,
    {
      method: "POST",
      headers: {
        authorization: `Bearer ${secret}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    },
  );

  if (!response.ok) {
    // Deliberately terse. The upstream body can echo request material, and this
    // response is read by a browser.
    throw new TokenExchangeError(
      `Direct Line refused the token request (${response.status}).`,
      502,
    );
  }

  const payload = await response.json();
  const token = payload?.token;
  if (typeof token !== "string" || token === "") {
    throw new TokenExchangeError("Direct Line returned no token.", 502);
  }

  // Allow-list the response. Direct Line does not currently echo the secret,
  // but this endpoint's whole job is to be the boundary the secret cannot
  // cross, so it forwards named fields rather than spreading the upstream body.
  return {
    token,
    expires_in: typeof payload.expires_in === "number" ? payload.expires_in : undefined,
    conversationId:
      typeof payload.conversationId === "string" ? payload.conversationId : undefined,
    userId,
  };
}
