/**
 * Direct Line 3.0 client — the transport `npm run eval:agent` drives the
 * deployed Copilot Studio agent over.
 *
 * This is the same channel the control tower's Ask tab embeds (L8 playbook §4),
 * which is the point: the eval exercises the surface the demo actually uses, not
 * a side door. What differs is only who holds the credential — the browser gets
 * a short-lived conversation-scoped token from `apps/directline-token`, while
 * this harness runs in CI and starts from the secret itself.
 *
 * ── Protocol ────────────────────────────────────────────────────────────────
 *   1. POST /v3/directline/conversations            (Bearer <secret>)
 *      -> { conversationId, token, expires_in, streamUrl }
 *      The response's `token` is CONVERSATION-SCOPED. Every later call uses it
 *      instead of the secret, so the secret crosses the wire exactly once.
 *   2. POST /v3/directline/conversations/{id}/activities   (Bearer <token>)
 *      { type: "message", from: { id }, text }  -> { id }
 *   3. GET  /v3/directline/conversations/{id}/activities?watermark=<w>
 *      -> { activities: [...], watermark }
 *      Poll from the watermark captured BEFORE the post, so nothing that arrives
 *      between the two calls is missed.
 *
 * ── The settle window ───────────────────────────────────────────────────────
 * A Copilot Studio turn is not one activity. A typical reply is `typing`, then
 * a text message, then a second activity carrying the Adaptive Card — and the
 * card is the thing V8.4 grades. Stopping at the first bot activity would
 * therefore fact-check the prose and miss the card. So the poll continues for a
 * quiet period (`settleMs`) after the first bot activity and returns everything
 * that arrived. `typing` activities are collected but never count as a reply.
 *
 * ── Secrets ─────────────────────────────────────────────────────────────────
 * The secret is held in a private field, used to build one Authorization header,
 * and never logged, never written to the artifact, never put in an error. Errors
 * from this client name the status code and the conversation id only.
 */

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export const DEFAULT_DIRECTLINE_BASE = "https://directline.botframework.com";

/** The Adaptive Card content type Copilot Studio attaches (V8.4 pins schema 1.5). */
export const ADAPTIVE_CARD_CONTENT_TYPE = "application/vnd.microsoft.card.adaptive";

export interface DirectLineActivity {
  id?: string;
  type?: string;
  timestamp?: string;
  from?: { id?: string; name?: string; role?: string };
  text?: string;
  valueType?: string;
  value?: unknown;
  channelData?: Record<string, unknown>;
  attachments?: Array<{ contentType?: string; content?: unknown; name?: string }>;
}

export interface AgentReply {
  /** Every activity the agent produced for this question, in arrival order. */
  activities: DirectLineActivity[];
  /** Text of the agent's message activities. */
  text: string[];
  /** Adaptive Card payloads, in arrival order — what V8.4 validates. */
  cards: unknown[];
  /** Best-effort tool-call names recovered from trace activities (V8.3 runtime half). */
  toolCalls: Array<{ name: string }>;
  /** Direct Line activity -> final agent activity, in seconds (V8.5). */
  latencySeconds: number;
  /** True when the settle window closed without any agent message arriving. */
  timedOut: boolean;
}

export interface DirectLineClientOptions {
  secret: string;
  fetchImpl?: FetchLike;
  baseUrl?: string;
  /** `from.id` on posted activities; also how agent activities are told apart. */
  userId?: string;
  /** Gap between watermark polls. */
  pollIntervalMs?: number;
  /** Quiet period after the first agent activity before the turn is considered done. */
  settleMs?: number;
  /** Hard deadline for one question. */
  timeoutMs?: number;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
}

export class DirectLineError extends Error {
  constructor(
    message: string,
    readonly status?: number,
  ) {
    super(message);
    this.name = "DirectLineError";
  }
}

const realSleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

/**
 * Recover tool-call names from whatever the channel exposes. Copilot Studio's
 * shape here is not contractual, so this is deliberately forgiving and
 * best-effort: the audit's authoritative V8.3 check is static (`tools/list` plus
 * the solution's declared components), and this only enriches the artifact.
 */
export function extractToolCalls(activity: DirectLineActivity): Array<{ name: string }> {
  const found: Array<{ name: string }> = [];
  const push = (name: unknown): void => {
    if (typeof name === "string" && name.trim().length > 0) found.push({ name: name.trim() });
  };

  if (activity.type === "trace") {
    const value = activity.value as Record<string, unknown> | undefined;
    push(value?.["toolName"] ?? value?.["name"] ?? value?.["action"]);
    for (const entry of (value?.["toolCalls"] as Array<Record<string, unknown>>) ?? []) {
      push(entry?.["name"] ?? entry?.["toolName"]);
    }
  }
  const channelTools = activity.channelData?.["toolCalls"] as
    | Array<Record<string, unknown>>
    | undefined;
  for (const entry of channelTools ?? []) push(entry?.["name"] ?? entry?.["toolName"]);
  return found;
}

export class DirectLineClient {
  private readonly secret: string;
  private readonly fetchImpl: FetchLike;
  private readonly baseUrl: string;
  private readonly userId: string;
  private readonly pollIntervalMs: number;
  private readonly settleMs: number;
  private readonly timeoutMs: number;
  private readonly sleep: (ms: number) => Promise<void>;
  private readonly now: () => number;

  private conversationId: string | undefined;
  private token: string | undefined;
  private watermark: string | undefined;

  constructor(options: DirectLineClientOptions) {
    this.secret = options.secret;
    this.fetchImpl = options.fetchImpl ?? ((url, init) => fetch(url, init));
    this.baseUrl = (options.baseUrl ?? DEFAULT_DIRECTLINE_BASE).replace(/\/+$/, "");
    this.userId = options.userId ?? "mls-eval";
    this.pollIntervalMs = options.pollIntervalMs ?? 750;
    this.settleMs = options.settleMs ?? 2_500;
    this.timeoutMs = options.timeoutMs ?? 60_000;
    this.sleep = options.sleep ?? realSleep;
    this.now = options.now ?? (() => Date.now());
  }

  get id(): string | undefined {
    return this.conversationId;
  }

  private async call<T>(
    path: string,
    init: { method: "GET" | "POST"; bearer: string; body?: unknown },
  ): Promise<T> {
    const requestInit: RequestInit = {
      method: init.method,
      headers: {
        authorization: `Bearer ${init.bearer}`,
        accept: "application/json",
        ...(init.body === undefined ? {} : { "content-type": "application/json" }),
      },
    };
    if (init.body !== undefined) requestInit.body = JSON.stringify(init.body);

    let response: Response;
    try {
      response = await this.fetchImpl(`${this.baseUrl}${path}`, requestInit);
    } catch (err) {
      throw new DirectLineError(
        `Direct Line is unreachable (${path}): ${err instanceof Error ? err.message : String(err)}`,
      );
    }
    if (!response.ok) {
      // The body can echo request headers on some gateways; never include it.
      throw new DirectLineError(
        `Direct Line returned ${response.status} for ${path}. ` +
          (response.status === 401 || response.status === 403
            ? "The Direct Line secret was rejected — check that the channel is enabled on the " +
              "PUBLISHED agent and that the secret has not been regenerated."
            : "See the Direct Line channel configuration for the deployed agent."),
        response.status,
      );
    }
    const text = await response.text();
    return (text.length > 0 ? JSON.parse(text) : {}) as T;
  }

  /** Step 1: exchange the secret for a conversation-scoped token. */
  async openConversation(): Promise<string> {
    const opened = await this.call<{ conversationId?: string; token?: string }>(
      "/v3/directline/conversations",
      { method: "POST", bearer: this.secret },
    );
    if (!opened.conversationId || !opened.token) {
      throw new DirectLineError(
        "Direct Line opened a conversation without returning a conversationId and token",
      );
    }
    this.conversationId = opened.conversationId;
    this.token = opened.token;
    this.watermark = undefined;
    return opened.conversationId;
  }

  /** Steps 2-3: post one question and collect the agent's whole turn. */
  async ask(question: string): Promise<AgentReply> {
    if (!this.conversationId || !this.token) {
      throw new DirectLineError("ask() called before openConversation()");
    }
    const conversationPath = `/v3/directline/conversations/${encodeURIComponent(this.conversationId)}`;
    const startedAt = this.now();

    await this.call<{ id?: string }>(`${conversationPath}/activities`, {
      method: "POST",
      bearer: this.token,
      body: { type: "message", from: { id: this.userId }, text: question },
    });

    const activities: DirectLineActivity[] = [];
    const text: string[] = [];
    const cards: unknown[] = [];
    const toolCalls: Array<{ name: string }> = [];
    let firstReplyAt: number | undefined;
    let lastReplyAt: number | undefined;

    for (;;) {
      const elapsed = this.now() - startedAt;
      if (elapsed > this.timeoutMs) break;
      // The turn is done once the agent has spoken and then stayed quiet.
      if (lastReplyAt !== undefined && this.now() - lastReplyAt > this.settleMs) break;

      const query = this.watermark === undefined ? "" : `?watermark=${encodeURIComponent(this.watermark)}`;
      const page = await this.call<{ activities?: DirectLineActivity[]; watermark?: string }>(
        `${conversationPath}/activities${query}`,
        { method: "GET", bearer: this.token },
      );
      if (page.watermark !== undefined) this.watermark = page.watermark;

      for (const activity of page.activities ?? []) {
        // Our own echoed message is not a reply.
        if (activity.from?.id === this.userId) continue;
        activities.push(activity);
        toolCalls.push(...extractToolCalls(activity));

        // `typing` is a keep-alive, not an answer: it must not satisfy the
        // settle window or the harness would grade an empty turn.
        if (activity.type === "typing") continue;

        let carriedContent = false;
        if (typeof activity.text === "string" && activity.text.trim().length > 0) {
          text.push(activity.text);
          carriedContent = true;
        }
        for (const attachment of activity.attachments ?? []) {
          if (attachment.contentType === ADAPTIVE_CARD_CONTENT_TYPE) {
            cards.push(attachment.content);
            carriedContent = true;
          }
        }
        if (carriedContent) {
          firstReplyAt ??= this.now();
          lastReplyAt = this.now();
        }
      }

      if (lastReplyAt === undefined || this.now() - lastReplyAt <= this.settleMs) {
        await this.sleep(this.pollIntervalMs);
      }
    }

    const finishedAt = lastReplyAt ?? this.now();
    return {
      activities,
      text,
      cards,
      toolCalls,
      latencySeconds: Number(((finishedAt - startedAt) / 1000).toFixed(3)),
      timedOut: firstReplyAt === undefined,
    };
  }
}
