import { createRemoteJWKSet, jwtVerify } from "jose";

// =============================================================================
// USER TOKEN VERIFICATION — the copilot inherits the app's identity.
//
// WHY THIS EXISTS. The token endpoint used to be anonymous by design, guarded
// only by an Origin allow-list. That guard is real protection against a browser
// on someone else's page, and none at all against a direct caller: an `Origin`
// header is a string anyone can send. It was demonstrated with one `curl
// -H "Origin: <control tower>"`, which minted a working Direct Line token and
// held a full conversation with the agent.
//
// That was tolerable while the agent required a Microsoft sign-in of its own.
// It stopped being tolerable when the agent moved to "No authentication" (F128)
// to work over Direct Line at all, because then NOTHING authenticated the human
// — in a demo whose entire subject is governance.
//
// WHAT REPLACES IT. The control tower already sits behind Container Apps Easy
// Auth, so every browser that can load the Ask tab has already completed an
// Entra sign-in and holds a validated token. The page forwards that token here,
// and this module verifies it before a Direct Line secret is ever exchanged.
// The copilot therefore inherits the app's identity rather than sitting open
// beside it, and there is no second sign-in for the user.
//
// FAIL CLOSED, LIKE THE ORIGIN GUARD BESIDE IT. Absent configuration is a 500
// and no token, never a quiet downgrade to anonymous. An optional security
// control is one nobody turns on (F120's shape); this one has no off switch.
// =============================================================================

export class UserTokenError extends Error {
  constructor(message, status) {
    super(message);
    this.name = "UserTokenError";
    this.status = status;
  }
}

/**
 * Entra's OIDC signing keys for a tenant. `createRemoteJWKSet` caches the key
 * set and refetches on an unknown `kid`, so key rollover is handled without
 * this function app knowing rollover exists.
 */
export function createJwks(tenantId) {
  return createRemoteJWKSet(
    new URL(`https://login.microsoftonline.com/${tenantId}/discovery/v2.0/keys`),
  );
}

/**
 * Verify the caller's Entra token.
 *
 * Signature, issuer, audience and expiry are all checked — omitting any one of
 * them turns the check into decoration. Audience especially: a signature from
 * the right tenant proves only that SOME Entra app issued it, and a token minted
 * for a different application is not permission to use this one.
 *
 * @returns the verified payload, for the caller to log an identity (never a token).
 */
export async function verifyUserToken({
  authorization,
  tenantId,
  audience,
  jwks,
  clockToleranceSeconds = 60,
}) {
  if (!tenantId || !audience) {
    throw new UserTokenError(
      "DIRECTLINE_USER_TENANT_ID and DIRECTLINE_USER_AUDIENCE must both be set; refusing to mint an unauthenticated token.",
      500,
    );
  }

  const header = (authorization ?? "").trim();
  if (!header) {
    throw new UserTokenError("No Authorization header was sent.", 401);
  }
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) {
    throw new UserTokenError("The Authorization header is not a Bearer token.", 401);
  }

  try {
    const { payload } = await jwtVerify(match[1], jwks, {
      // BOTH issuer forms are accepted because Entra uses them for different
      // token versions: v2.0 tokens carry the /v2.0 suffix, v1.0 tokens do not,
      // and Easy Auth's configuration decides which the app receives. Pinning
      // one silently rejects every token from an app configured for the other.
      issuer: [
        `https://login.microsoftonline.com/${tenantId}/v2.0`,
        `https://sts.windows.net/${tenantId}/`,
      ],
      audience,
      clockTolerance: clockToleranceSeconds,
    });
    return payload;
  } catch (error) {
    // 401, not 403: the caller may retry with a valid token. The reason is
    // returned to the caller in general terms and logged in full server-side —
    // "audience mismatch" tells an attacker which knob to turn.
    throw new UserTokenError(`Token verification failed: ${error.message}`, 401);
  }
}
