/**
 * INBOUND authentication for the MCP endpoint.
 *
 * Not to be confused with `tools/auth.ts`, which is the OUTBOUND half — how this
 * server authenticates to Azure using its managed identity. This module is the
 * other direction: who is allowed to call *us*.
 *
 * ── Why this exists ─────────────────────────────────────────────────────────
 * The container app runs with `ingressExternal: true`, unconditionally and by
 * design: Copilot Studio calls this server from outside Azure over the public
 * internet, so an internal-only ingress would make showpiece #1 impossible.
 * That means the endpoint is reachable by anyone who finds the FQDN, and the
 * five tools behind it read real tenant data — Log Analytics, Defender secure
 * score, Cost Management, GitHub security alerts, and the lakehouse.
 *
 * `query_lakehouse_sql` is already gated read-only (single statement, SELECT or
 * WITH only, forbidden-verb list). That stops writes. It does not stop reads,
 * and it does not stop cost: every call resumes serverless SQL and consumes
 * Fabric CU on a subscription whose entire budget is a 30-day $200 credit. An
 * unauthenticated endpoint is therefore both a disclosure problem and a
 * denial-of-wallet problem.
 *
 * ── Fail closed ─────────────────────────────────────────────────────────────
 * The token is REQUIRED and its absence is a boot failure, not a warning, in
 * EVERY mode — not just `cloud`. This follows the rule the cloud config
 * already set: fail at boot with a complete message, never start and surprise
 * someone mid-demo. The reason enforcement cannot key off `backendMode` is
 * that the risk is the ingress, not the adapter set behind it: the container
 * app runs `ingressExternal: true` unconditionally, and `MLS_TOOL_BACKENDS` is
 * not set anywhere in `infra/` or `.github/`, so `local` is the mode that
 * actually ships. A gate that only armed itself in `cloud` mode was inert in
 * production (finding F2). Running open is still possible but has to be
 * *chosen*, explicitly, via MCP_ALLOW_UNAUTHENTICATED — and it announces
 * itself loudly at boot.
 *
 * `backendMode` is kept as a parameter purely for future message-shaping (a
 * cloud misconfiguration and a laptop with no `.env` are different situations
 * for a human to read about); it must never again be allowed to gate whether
 * enforcement happens. Local development opts out via
 * MCP_ALLOW_UNAUTHENTICATED=true, set by `npm run dev` — see package.json —
 * so the laptop path stays frictionless while the deployed path fails closed.
 *
 * ── Hard rule 5 ─────────────────────────────────────────────────────────────
 * The token is a secret and is treated like one: injected by the platform from
 * Key Vault, held in memory, compared in constant time, and never logged, never
 * echoed in an error, and never reported on /healthz.
 */
import { createHash, timingSafeEqual } from "node:crypto";
import type { NextFunction, Request, Response } from "express";

/** Resolved inbound-auth posture. */
export interface InboundAuth {
  /** The shared secret, or undefined when the gate is off. */
  token: string | undefined;
  /** True when requests must carry a valid credential. */
  enforced: boolean;
  /**
   * Set when the endpoint is deliberately running open — in either mode, not
   * just cloud; enforcement no longer keys off backendMode (F2). Surfaced at
   * boot so an accidental opt-out cannot be silent.
   */
  deliberatelyOpen: boolean;
}

/**
 * Constant-time compare of two secrets of arbitrary length.
 *
 * `timingSafeEqual` throws when the buffers differ in length, and length itself
 * leaks. Hashing both sides first gives two fixed-width (32-byte) digests, so
 * the comparison is both safe to call and free of a length side channel.
 */
export function secretsMatch(supplied: string, expected: string): boolean {
  const a = createHash("sha256").update(supplied, "utf8").digest();
  const b = createHash("sha256").update(expected, "utf8").digest();
  return timingSafeEqual(a, b);
}

/**
 * Pull the presented credential out of a request.
 *
 * Two accepted forms, because the two callers differ: `Authorization: Bearer`
 * is the standard and what a hand-rolled MCP client will send, while `x-api-key`
 * is what a Copilot Studio custom connector emits for API-key auth.
 */
export function presentedCredential(req: Request): string | undefined {
  const header = req.get("authorization");
  if (header) {
    const match = /^Bearer[ \t]+(.+)$/i.exec(header.trim());
    if (match) return match[1].trim();
  }
  const apiKey = req.get("x-api-key");
  if (typeof apiKey === "string" && apiKey.trim().length > 0) return apiKey.trim();
  return undefined;
}

/** JSON-RPC-shaped 401, matching the 405 body this server already returns. */
const UNAUTHORIZED = {
  jsonrpc: "2.0" as const,
  // -32001 is in the JSON-RPC implementation-defined server-error range.
  error: { code: -32001, message: "Unauthorized" },
  id: null,
};

/**
 * Express middleware enforcing `auth`.
 *
 * Deliberately indiscriminate in what it reports: a missing credential and a
 * wrong one produce the identical 401, so the endpoint cannot be used to probe
 * whether a given key exists.
 */
export function requireInboundAuth(auth: InboundAuth) {
  return function inboundAuthGate(req: Request, res: Response, next: NextFunction): void {
    if (!auth.enforced || auth.token === undefined) {
      next();
      return;
    }
    const supplied = presentedCredential(req);
    if (supplied !== undefined && secretsMatch(supplied, auth.token)) {
      next();
      return;
    }
    res.setHeader("WWW-Authenticate", 'Bearer realm="mcp-tools"');
    res.status(401).json(UNAUTHORIZED);
  };
}

/**
 * Resolve the inbound-auth posture from the environment.
 *
 * @param backendMode which adapter set is running. Kept for message-shaping
 *                    only — see the module doc — and must not gate whether a
 *                    token is required: the ingress is external in every
 *                    deployed configuration, `local` included.
 * @throws when there is neither a token nor an explicit opt-out, in any mode.
 */
export function loadInboundAuth(
  env: NodeJS.ProcessEnv,
  backendMode: "local" | "cloud",
): InboundAuth {
  const raw = env.MCP_AUTH_TOKEN;
  const token = typeof raw === "string" && raw.trim().length > 0 ? raw.trim() : undefined;
  const allowOpen = /^(1|true|yes)$/i.test((env.MCP_ALLOW_UNAUTHENTICATED ?? "").trim());

  if (token === undefined && !allowOpen) {
    throw new Error(
      "MCP_AUTH_TOKEN is required.\n" +
        "  This server runs with external ingress in every deployed configuration, so\n" +
        "  without it the five tools are callable by anyone who finds the URL, and every\n" +
        "  call bills the subscription.\n" +
        "  Set MCP_AUTH_TOKEN (the platform injects it from Key Vault), or set\n" +
        "  MCP_ALLOW_UNAUTHENTICATED=true if an open endpoint is genuinely what you intend.",
    );
  }

  return { token, enforced: token !== undefined, deliberatelyOpen: token === undefined && allowOpen };
}

/**
 * One-line boot banner describing the posture. Reports only the posture, never
 * the token or any prefix of it.
 *
 * The final branch below is unreachable from `loadInboundAuth` itself — it
 * throws rather than ever returning `{ enforced: false, deliberatelyOpen:
 * false }` — but `InboundAuth` values can also be built by hand (tests,
 * callers other than `loadInboundAuth`), so this stays a total function over
 * the type rather than assuming its only producer.
 */
export function describeInboundAuth(auth: InboundAuth): string {
  if (auth.enforced) return "inbound auth: ENFORCED (bearer token / x-api-key)";
  if (auth.deliberatelyOpen) {
    return (
      "inbound auth: DISABLED BY MCP_ALLOW_UNAUTHENTICATED — this endpoint is public and " +
      "unauthenticated, and every tool call bills the subscription"
    );
  }
  return "inbound auth: off (no token and no MCP_ALLOW_UNAUTHENTICATED — loadInboundAuth refuses to boot in this state)";
}
