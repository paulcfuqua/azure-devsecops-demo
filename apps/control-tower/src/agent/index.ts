import { DirectLineAgentProvider, OfflineAgentProvider } from "./providers";
import type { AgentProvider } from "./types";

export { connectDirectLine, DIRECT_LINE_DEFAULT_BASE, DirectLineTransportError } from "./DirectLineTransport";
export type { WebSocketFactory, WebSocketLike } from "./DirectLineTransport";
export {
  assertNoSecretMaterial,
  createTokenFetcher,
  DirectLineTokenError,
  parseTokenResponse,
} from "./directLineToken";
export { DirectLineAgentProvider, OfflineAgentProvider } from "./providers";
export { activityToTurn, appendTurn, isAdaptiveCardAttachment, userTurn } from "./transcript";
export * from "./types";

export type AgentMode = "offline" | "directline";

export interface AgentEnv {
  VITE_AGENT_MODE?: string;
  /** URL of the server-side token endpoint. Its presence is what turns the tab on. */
  VITE_DIRECTLINE_TOKEN_URL?: string;
  /** Regional Direct Line host, e.g. https://europe.directline.botframework.com */
  VITE_DIRECTLINE_DOMAIN?: string;
  [key: string]: unknown;
}

export type AgentConfig =
  | { mode: "offline"; reason: string }
  | { mode: "directline"; tokenUrl: string; baseUrl?: string };

/**
 * Vite inlines every `VITE_`-prefixed variable into the shipped bundle as a
 * string literal. That makes a mis-named build variable the single most likely
 * way a Direct Line secret ever reaches a browser, so the config resolver
 * treats any secret-shaped variable as a hard stop rather than ignoring it.
 */
const SECRET_SHAPED_ENV = /secret|password|apikey|api_key|client_secret|connectionstring/i;

function findSecretShapedKey(env: AgentEnv): string | undefined {
  for (const [key, value] of Object.entries(env)) {
    if (typeof value !== "string" || value.length === 0) continue;
    if (SECRET_SHAPED_ENV.test(key)) return key;
  }
  return undefined;
}

/**
 * Decides whether the Ask tab is live or offline, mirroring `resolveDataMode`.
 *
 * - `VITE_AGENT_MODE=offline` forces the offline state (useful for demo
 *   rehearsals and for the `vite preview` pass with `LOCAL_DATA=1`).
 * - A secret-shaped build variable forces offline, loudly. The token exchange
 *   belongs on the server (`apps/directline-token`), never in the bundle.
 * - No `VITE_DIRECTLINE_TOKEN_URL` means the agent is simply not deployed yet,
 *   which is the Phase P default and the local-development default.
 */
export function resolveAgentConfig(env: AgentEnv = import.meta.env): AgentConfig {
  const leaked = findSecretShapedKey(env);
  if (leaked) {
    return {
      mode: "offline",
      reason:
        `The build variable \`${leaked}\` looks like secret material, and Vite inlines ` +
        "every VITE_-prefixed variable into the browser bundle. Microsoft's guidance is " +
        "explicit — “don't expose the secret in any code that runs in the browser” — so the " +
        "Ask tab refuses to start. Remove it and point VITE_DIRECTLINE_TOKEN_URL at the " +
        "token endpoint instead.",
    };
  }

  if (env.VITE_AGENT_MODE === "offline") {
    return {
      mode: "offline",
      reason: "VITE_AGENT_MODE=offline was set for this build.",
    };
  }

  const tokenUrl = env.VITE_DIRECTLINE_TOKEN_URL;
  if (typeof tokenUrl !== "string" || tokenUrl.trim() === "") {
    return {
      mode: "offline",
      reason:
        "No VITE_DIRECTLINE_TOKEN_URL is configured, so there is no Direct Line " +
        "channel to talk to.",
    };
  }

  const baseUrl = env.VITE_DIRECTLINE_DOMAIN?.trim();
  return { mode: "directline", tokenUrl: tokenUrl.trim(), baseUrl: baseUrl || undefined };
}

/** Builds the provider the Ask tab consumes. Never throws; never does I/O. */
export function createAgentProvider(
  config: AgentConfig = resolveAgentConfig(),
): AgentProvider {
  if (config.mode === "offline") return new OfflineAgentProvider(config.reason);
  return new DirectLineAgentProvider({
    tokenUrl: config.tokenUrl,
    baseUrl: config.baseUrl,
  });
}
