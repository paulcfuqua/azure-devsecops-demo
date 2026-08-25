/**
 * The control-tower *agent* contract — the L8 wiring boundary.
 *
 * This is the sibling of `providers/types.ts` (`DataProvider`). Where a
 * `DataProvider` turns feed payloads into `@mls/spec-renderer` specs for the
 * Dev/Sec/Ops tabs, an `AgentProvider` turns the Copilot Studio agent into a
 * stream of `AgentTurn`s for the Ask tab. In both cases the React components
 * stay dumb: they never see a transport, a token, or a raw wire payload.
 *
 * Two implementations exist, selected by `createAgentProvider()`:
 *
 * - `OfflineAgentProvider` — local mode. Copilot Studio is cloud-only (see the
 *   2026-08-24 amendment, "Lost capability — stated plainly"), so with no
 *   Direct Line configuration the Ask tab renders a labelled offline state and
 *   never pretends to answer.
 * - `DirectLineAgentProvider` — deployed mode. Talks Direct Line 3.0 to the
 *   published Copilot Studio agent, after exchanging *nothing* for a
 *   short-lived token at a server-side token endpoint.
 *
 * KNOWN PLATFORM LIMITATION, recorded here so it is not mistaken for a bug in
 * this code: when a Copilot Studio agent is combined with a **Fabric connected
 * agent** — which is exactly the amendment's L5 knowledge-source design — Teams
 * is the only *validated* channel. Direct Line is not on that list. The embed
 * below is the sponsor-chosen surface and is expected to work, but if answers
 * degrade once the Fabric data agent is attached, the channel is the first
 * suspect and the amendment's own fallback applies: keep the agent, drop the
 * Fabric knowledge source, and query the lakehouse through the MCP server
 * instead.
 *
 * SECURITY INVARIANT (the reason this seam exists at all): the browser bundle
 * never holds the Direct Line secret. It calls a token endpoint that performs
 * the secret -> token exchange server-side and returns only a short-lived,
 * conversation-scoped token. `resolveAgentConfig` refuses to start if someone
 * tries to inject a secret through Vite env, and `fetchDirectLineToken` refuses
 * a token response that carries anything secret-shaped.
 */

/** Root of an Adaptive Card, as it arrives in a Direct Line attachment. */
export interface AdaptiveCard {
  type: string;
  version?: string;
  body?: AdaptiveElement[];
  actions?: AdaptiveAction[];
  [key: string]: unknown;
}

/*
 * Card element and action shapes stay deliberately open. Adaptive Cards is a
 * versioned, extensible schema and Copilot Studio emits whatever the agent
 * author put in the card, so the renderer handles a documented subset by
 * `type` and reports anything else honestly rather than silently dropping it.
 */
export interface AdaptiveElement {
  type: string;
  [key: string]: unknown;
}

export interface AdaptiveAction {
  type: string;
  title?: string;
  [key: string]: unknown;
}

/** The Adaptive Card attachment content type on the Bot Framework wire. */
export const ADAPTIVE_CARD_CONTENT_TYPE = "application/vnd.microsoft.card.adaptive";

/**
 * The card profile the agent is expected to author against: **schema 1.5, with
 * `Action.Submit`**.
 *
 * Copilot Studio supports Adaptive Cards up to 1.6, but the ceiling that
 * matters is the *host*, and the hosts disagree
 * (https://learn.microsoft.com/en-us/microsoft-copilot-studio/adaptive-cards-overview):
 *
 *   - Bot Framework Web Chat — the default website integration, and the
 *     reference implementation this app's renderer stands in for — supports 1.6
 *     but does **not** support `Action.Execute`.
 *   - Teams caps at 1.5.
 *
 * 1.5 + `Action.Submit` is therefore the one payload that renders on every
 * surface the demo might publish to. The renderer treats it as the contract:
 * `Action.Execute` is reported as out-of-profile rather than rendered, so a
 * card that would break on Teams or Web Chat is visible here instead of
 * shipping and failing somewhere else.
 */
export const ADAPTIVE_CARD_TARGET_VERSION = "1.5";

/** Direct Line 3.0 attachment (subset the Ask tab consumes). */
export interface DirectLineAttachment {
  contentType: string;
  content?: unknown;
  contentUrl?: string;
  name?: string;
}

/**
 * Direct Line 3.0 activity (subset). The full schema is the Bot Framework
 * Activity; the Ask tab only reads what it renders.
 */
export interface DirectLineActivity {
  type: string; // message | typing | event | conversationUpdate | ...
  id?: string;
  timestamp?: string;
  from?: { id: string; name?: string; role?: string };
  text?: string;
  textFormat?: string;
  attachments?: DirectLineAttachment[];
  suggestedActions?: { actions?: AdaptiveAction[] };
  [key: string]: unknown;
}

/** One rendered exchange line in the transcript. */
export interface AgentTurn {
  /** Stable key for React; the Direct Line activity id when there is one. */
  id: string;
  role: "user" | "agent";
  /** Plain/markdown text the agent (or user) sent. May be empty when card-only. */
  text: string;
  /** Adaptive Cards attached to this turn, in wire order. */
  cards: AdaptiveCard[];
  /** Attachments that are not Adaptive Cards, surfaced rather than dropped. */
  otherAttachments: DirectLineAttachment[];
  timestamp?: string;
}

/**
 * A live conversation with the agent. Returned by `AgentProvider.connect()`.
 * Deliberately transport-agnostic: swapping the Direct Line implementation for
 * Microsoft's `botframework-directlinejs` client (or Web Chat's bundled one)
 * means writing a new `connect()` and changing nothing above this line.
 */
export interface AgentConnection {
  readonly conversationId: string;
  /** Send a user message. Resolves once Direct Line has accepted it. */
  send(text: string): Promise<void>;
  /** Subscribe to inbound activities. Returns an unsubscribe function. */
  onActivity(listener: (activity: DirectLineActivity) => void): () => void;
  /** Subscribe to transport errors. Returns an unsubscribe function. */
  onError(listener: (error: Error) => void): () => void;
  /** Tear the transport down. Idempotent. */
  close(): void;
}

/** The Ask tab's data contract — the mirror of `DataProvider`. */
export interface AgentProvider {
  /** Human-readable origin, surfaced in the Ask tab's status line. */
  readonly source: string;
  /** `false` means the Ask tab renders its offline state and never connects. */
  readonly available: boolean;
  /** Why the agent is unavailable. Present exactly when `available` is false. */
  readonly unavailableReason?: string;
  /** Open a conversation. Only ever called when `available` is true. */
  connect(): Promise<AgentConnection>;
}

/**
 * What the token endpoint returns to the browser. This is the ONLY thing the
 * browser is ever allowed to learn about Direct Line credentials: a short-lived
 * token (Microsoft issues these with a 30-minute lifetime) and, optionally, the
 * conversation the token is already bound to.
 */
export interface DirectLineToken {
  token: string;
  /** Seconds until expiry, from Direct Line's `expires_in`. */
  expiresInSeconds?: number;
  conversationId?: string;
  /**
   * The `dl_`-prefixed user id the token endpoint embedded in the token.
   * Direct Line validates that posted activities carry this id, so the client
   * must echo it back on every outbound activity. It is a random opaque
   * identifier, not a credential — see `apps/directline-token/README.md`.
   */
  userId?: string;
}

/** Injectable token source — the unit under test for the security invariant. */
export type TokenFetcher = () => Promise<DirectLineToken>;
