import {
  ADAPTIVE_CARD_CONTENT_TYPE,
  type AdaptiveCard,
  type AgentTurn,
  type DirectLineActivity,
  type DirectLineAttachment,
} from "./types";

/**
 * Pure activity -> transcript shaping. The `specs.ts` of the Ask tab: every
 * decision about what the UI shows lives here, so `AskPanel` stays dumb and
 * this stays unit-testable without a DOM.
 */

let counter = 0;

/** Monotonic fallback key for activities Direct Line did not id. */
function nextId(prefix: string): string {
  counter += 1;
  return `${prefix}-${counter}`;
}

/** True for an attachment carrying an Adaptive Card payload. */
export function isAdaptiveCardAttachment(attachment: DirectLineAttachment): boolean {
  return (
    attachment.contentType === ADAPTIVE_CARD_CONTENT_TYPE &&
    attachment.content !== null &&
    typeof attachment.content === "object"
  );
}

/**
 * Turns one Direct Line activity into a transcript turn, or `null` when the
 * activity is not something the transcript shows (typing indicators,
 * conversationUpdate, events, and messages with neither text nor attachments).
 */
export function activityToTurn(activity: DirectLineActivity): AgentTurn | null {
  if (activity.type !== "message") return null;

  const attachments = activity.attachments ?? [];
  const cards: AdaptiveCard[] = [];
  const otherAttachments: DirectLineAttachment[] = [];

  for (const attachment of attachments) {
    if (isAdaptiveCardAttachment(attachment)) {
      cards.push(attachment.content as AdaptiveCard);
    } else {
      otherAttachments.push(attachment);
    }
  }

  const text = typeof activity.text === "string" ? activity.text : "";
  if (!text && cards.length === 0 && otherAttachments.length === 0) return null;

  // Direct Line marks the human side with role "user"; everything else on the
  // wire (the Copilot Studio agent, and any channel-injected message) is the
  // agent as far as the transcript is concerned.
  const role: AgentTurn["role"] = activity.from?.role === "user" ? "user" : "agent";

  return {
    id: activity.id ?? nextId(role),
    role,
    text,
    cards,
    otherAttachments,
    timestamp: activity.timestamp,
  };
}

/** Builds the optimistic local turn for a message the operator just sent. */
export function userTurn(text: string): AgentTurn {
  return {
    id: nextId("local-user"),
    role: "user",
    text,
    cards: [],
    otherAttachments: [],
    timestamp: new Date().toISOString(),
  };
}

/**
 * Appends a turn, replacing any earlier turn with the same id. Direct Line can
 * redeliver an activity (reconnect, watermark replay), and a duplicated answer
 * in the transcript reads as a bug in the agent.
 */
export function appendTurn(turns: readonly AgentTurn[], turn: AgentTurn): AgentTurn[] {
  const existing = turns.findIndex((t) => t.id === turn.id);
  if (existing === -1) return [...turns, turn];
  const next = [...turns];
  next[existing] = turn;
  return next;
}
