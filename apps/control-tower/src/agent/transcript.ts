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
 * CARDS THAT ARRIVE AS TEXT.
 *
 * A generative Copilot Studio answer has exactly one output channel: the message
 * text. The agent's instructions tell it to emit an Adaptive Card, so it writes
 * valid card JSON into that text, and nothing on the Copilot Studio side promotes
 * it to a Direct Line attachment - `infra/copilot-studio/agent-definition.md`
 * section 8 flagged that path as an unresolved gap before any of this shipped.
 * On screen that is a paragraph of prose followed by a wall of raw JSON.
 *
 * The card is real, valid and declarative; only its TRANSPORT is text. Lifting it
 * out here changes nothing about the governance claim - the agent still emits data
 * and never generated UI code - and it is done in code we own rather than by
 * asking Copilot Studio for a path it does not document.
 */
const ADAPTIVE_CARD_TYPE = "AdaptiveCard";

function isCardLike(value: unknown): value is AdaptiveCard {
  return (
    typeof value === "object" &&
    value !== null &&
    (value as { type?: unknown }).type === ADAPTIVE_CARD_TYPE
  );
}

/**
 * Index just past the JSON object opening at `open`, or -1 if the braces never
 * balance. String literals are skipped, so a `}` inside `"a } brace"` does not
 * close the object - a naive `indexOf("}")` truncates the card and then fails to
 * parse, which would put the wall of JSON back on screen for the one card whose
 * text happens to contain a brace.
 */
function endOfJsonObject(text: string, open: number): number {
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = open; i < text.length; i += 1) {
    const ch = text[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') inString = true;
    else if (ch === "{") depth += 1;
    else if (ch === "}") {
      depth -= 1;
      if (depth === 0) return i + 1;
    }
  }
  return -1;
}

/** Removes the fences and blank runs left behind once a card is lifted out. */
function tidyProse(text: string): string {
  return text
    .replace(/```[a-zA-Z]*\s*```/g, "")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/**
 * Splits any Adaptive Cards the agent wrote into its prose out of that prose.
 * Returns the text unchanged when there is no card to lift: JSON that parses but
 * is not a card stays where it is, because an agent quoting a tool result is
 * saying something and deleting it would be worse than the JSON this fixes.
 */
export function extractCardsFromText(text: string): {
  text: string;
  cards: AdaptiveCard[];
} {
  const cards: AdaptiveCard[] = [];
  let kept = "";
  let cursor = 0;

  while (cursor < text.length) {
    const open = text.indexOf("{", cursor);
    if (open === -1) break;
    const end = endOfJsonObject(text, open);
    if (end === -1) break;

    let parsed: unknown;
    try {
      parsed = JSON.parse(text.slice(open, end));
    } catch {
      // Not JSON at all - keep the brace and carry on past it.
      kept += text.slice(cursor, open + 1);
      cursor = open + 1;
      continue;
    }

    if (isCardLike(parsed)) {
      cards.push(parsed);
      kept += text.slice(cursor, open);
    } else {
      kept += text.slice(cursor, end);
    }
    cursor = end;
  }

  kept += text.slice(cursor);
  if (cards.length === 0) return { text, cards };
  return { text: tidyProse(kept), cards };
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

  // Always clean the prose; only adopt the text-borne cards when the activity
  // carried none as attachments. If Copilot Studio ever starts sending them
  // properly, the attachment is the real transport and this must not add a
  // second copy of the same card beside it.
  const extracted = extractCardsFromText(
    typeof activity.text === "string" ? activity.text : "",
  );
  const text = extracted.text;
  if (cards.length === 0) cards.push(...extracted.cards);

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
