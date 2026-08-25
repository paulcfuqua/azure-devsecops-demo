import type { AgentConnection, DirectLineActivity, TokenFetcher } from "./types";

/**
 * Direct Line 3.0 transport.
 *
 * Protocol reference — "API reference - Direct Line API 3.0"
 * (https://learn.microsoft.com/en-us/azure/bot-service/rest-api/bot-framework-rest-direct-line-3-0-api-reference):
 *
 *   POST {base}/v3/directline/conversations
 *        Authorization: Bearer {token}
 *     -> { conversationId, token, expires_in, streamUrl }
 *
 *   POST {base}/v3/directline/conversations/{id}/activities   (send)
 *   GET  {base}/v3/directline/conversations/{id}/activities?watermark={w}
 *     -> { activities: [...], watermark }                     (poll fallback)
 *
 *   WSS  {streamUrl}  -> ActivitySet frames; empty frames are keep-alives.
 *
 * WHY THIS IS HAND-ROLLED AND NOT `botframework-directlinejs`
 * ----------------------------------------------------------
 * Microsoft ships two clients for this protocol:
 *
 *   * `botframework-webchat` (4.19.1) — the full chat UI. It renders Adaptive
 *     Cards out of the box (it embeds the `adaptivecards` package) but owns the
 *     whole surface, which would put a second, non-Fluent design system inside
 *     the control tower and bypass the app's dumb-component rule.
 *   * `botframework-directlinejs` (0.16.0) — the protocol client for apps that
 *     bring their own UI. That is the natural fit here, and it is what this
 *     module is shaped after (`activity$` -> `onActivity`, `postActivity` ->
 *     `send`, `connectionStatus$` -> `onError`).
 *
 * Adding it would mean adding `rxjs@5.5.12`, `core-js`, `botframework-streaming`
 * and `@babel/runtime` to the app, which requires regenerating the repo-root
 * lockfile — outside this change's write scope. The `AgentConnection` interface
 * is the seam that makes that a one-file swap later: replace this module's
 * `connectDirectLine`, keep everything above it untouched.
 */

/** Global Direct Line endpoint. Regional bots must use their regional host. */
export const DIRECT_LINE_DEFAULT_BASE = "https://directline.botframework.com";

/** Minimal socket surface, so tests (and jsdom) never open a real connection. */
export interface WebSocketLike {
  onMessage(listener: (data: string) => void): void;
  onClose(listener: () => void): void;
  onError(listener: (error: Error) => void): void;
  close(): void;
}

/** Returns `null` to fall back to watermark polling. */
export type WebSocketFactory = (url: string) => WebSocketLike | null;

export interface DirectLineTransportOptions {
  /** Supplies a short-lived token. Never a secret — see `directLineToken.ts`. */
  tokenFetcher: TokenFetcher;
  /** Direct Line host. Override for the `europe.`/`india.` regional endpoints. */
  baseUrl?: string;
  fetchImpl?: typeof fetch;
  webSocketFactory?: WebSocketFactory;
  /** Poll interval used only when no WebSocket is available. */
  pollIntervalMs?: number;
}

interface StartConversationResponse {
  conversationId?: string;
  streamUrl?: string;
}

interface ActivitySet {
  activities?: DirectLineActivity[];
  watermark?: string | null;
}

export class DirectLineTransportError extends Error {
  constructor(
    message: string,
    readonly status?: number,
  ) {
    super(message);
    this.name = "DirectLineTransportError";
  }
}

function defaultWebSocketFactory(url: string): WebSocketLike | null {
  const Ctor = (globalThis as { WebSocket?: typeof WebSocket }).WebSocket;
  if (typeof Ctor !== "function") return null;
  const socket = new Ctor(url);
  return {
    onMessage(listener) {
      socket.addEventListener("message", (event) => {
        listener(typeof event.data === "string" ? event.data : "");
      });
    },
    onClose(listener) {
      socket.addEventListener("close", () => listener());
    },
    onError(listener) {
      socket.addEventListener("error", () =>
        listener(new DirectLineTransportError("The Direct Line stream dropped.")),
      );
    },
    close() {
      socket.close();
    },
  };
}

function describeStatus(status: number): string {
  // Documented Direct Line status semantics, surfaced verbatim so an operator
  // reading the Ask tab knows which knob to turn.
  if (status === 401) return "the Direct Line token was missing or malformed";
  if (status === 403) {
    return "the Direct Line token expired or the agent is unreachable (403 / TokenExpired)";
  }
  if (status === 502) return "the Copilot Studio agent errored or is unavailable";
  return `Direct Line responded ${status}`;
}

/**
 * Opens a Direct Line conversation and returns the transport-agnostic
 * `AgentConnection` the Ask tab consumes.
 */
export async function connectDirectLine(
  options: DirectLineTransportOptions,
): Promise<AgentConnection> {
  const {
    tokenFetcher,
    baseUrl = DIRECT_LINE_DEFAULT_BASE,
    fetchImpl,
    webSocketFactory = defaultWebSocketFactory,
    pollIntervalMs = 1000,
  } = options;

  const doFetch = fetchImpl ?? globalThis.fetch;
  const token = await tokenFetcher();
  const root = baseUrl.replace(/\/+$/, "");

  const authed = async (path: string, init?: RequestInit): Promise<unknown> => {
    const res = await doFetch(`${root}${path}`, {
      ...init,
      headers: {
        ...(init?.headers as Record<string, string> | undefined),
        authorization: `Bearer ${token.token}`,
        accept: "application/json",
      },
    });
    if (!res.ok) {
      throw new DirectLineTransportError(describeStatus(res.status), res.status);
    }
    const text = await res.text();
    return text ? (JSON.parse(text) as unknown) : {};
  };

  const started = (await authed("/v3/directline/conversations", {
    method: "POST",
  })) as StartConversationResponse;

  const conversationId = started.conversationId ?? token.conversationId;
  if (!conversationId) {
    throw new DirectLineTransportError(
      "Direct Line started a conversation but returned no conversationId.",
    );
  }

  const activityListeners = new Set<(activity: DirectLineActivity) => void>();
  const errorListeners = new Set<(error: Error) => void>();
  let closed = false;
  let watermark: string | null = null;
  let poller: ReturnType<typeof setInterval> | undefined;
  let socket: WebSocketLike | null = null;

  const emitActivity = (activity: DirectLineActivity): void => {
    // Direct Line echoes our own posts back on the stream. The transcript
    // already shows them optimistically, so drop the echo rather than
    // double-rendering it.
    if (token.userId && activity.from?.id === token.userId) return;
    for (const listener of activityListeners) listener(activity);
  };

  const emitError = (error: Error): void => {
    for (const listener of errorListeners) listener(error);
  };

  const ingest = (set: ActivitySet): void => {
    if (typeof set.watermark === "string") watermark = set.watermark;
    for (const activity of set.activities ?? []) emitActivity(activity);
  };

  const poll = async (): Promise<void> => {
    if (closed) return;
    const query = watermark ? `?watermark=${encodeURIComponent(watermark)}` : "";
    const set = (await authed(
      `/v3/directline/conversations/${conversationId}/activities${query}`,
    )) as ActivitySet;
    ingest(set);
  };

  if (started.streamUrl) {
    socket = webSocketFactory(started.streamUrl);
  }

  if (socket) {
    socket.onMessage((data) => {
      // Keep-alive frames are empty strings; ignore them.
      if (!data) return;
      try {
        ingest(JSON.parse(data) as ActivitySet);
      } catch {
        emitError(new DirectLineTransportError("Unparseable Direct Line frame."));
      }
    });
    socket.onError(emitError);
    socket.onClose(() => {
      if (!closed) {
        emitError(
          new DirectLineTransportError(
            "The Direct Line stream closed. Reload the Ask tab to start a new conversation.",
          ),
        );
      }
    });
  } else {
    poller = setInterval(() => {
      void poll().catch(emitError);
    }, pollIntervalMs);
    // Prime the transcript immediately rather than after the first interval.
    await poll().catch(emitError);
  }

  return {
    conversationId,

    async send(text: string): Promise<void> {
      await authed(`/v3/directline/conversations/${conversationId}/activities`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          type: "message",
          from: { id: token.userId ?? "dl_control_tower" },
          text,
        }),
      });
      // With no socket, pull the reply on the next tick instead of waiting a
      // whole interval for it.
      if (!socket) await poll().catch(emitError);
    },

    onActivity(listener) {
      activityListeners.add(listener);
      return () => activityListeners.delete(listener);
    },

    onError(listener) {
      errorListeners.add(listener);
      return () => errorListeners.delete(listener);
    },

    close() {
      if (closed) return;
      closed = true;
      if (poller) clearInterval(poller);
      socket?.close();
      activityListeners.clear();
      errorListeners.clear();
    },
  };
}
