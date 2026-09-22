/**
 * The agent's Adaptive Cards arrive in the message TEXT, not in `attachments`.
 *
 * This is pinned against a REAL reply captured from the deployed agent on 2026-09-22
 * (`fixtures/agent-reply-with-text-borne-card.txt`), not against a hand-written
 * approximation of one. That matters: the bug this file exists for was an assumption about
 * the transport, and a fixture written from the same assumption would have reproduced it.
 *
 * What the capture showed, asking "Show me launches by vehicle":
 *
 *     attachments on the wire : 0
 *     text                    : 1007 characters - prose, then {"type":"AdaptiveCard",...}
 *
 * V8.4 had been reading `attachments` and reporting the card capability missing, while the
 * control tower's Ask tab rendered those very cards by parsing the text. The criterion was
 * wrong about the estate in the direction that understates it.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import { extractCardsFromText } from "../evals/directline.js";

const realReply = readFileSync(
  resolve(__dirname, "fixtures/agent-reply-with-text-borne-card.txt"),
  "utf8",
);

describe("text-borne Adaptive Cards", () => {
  it("extracts the card from a real captured agent reply", () => {
    const { cards, text } = extractCardsFromText(realReply);
    expect(cards).toHaveLength(1);
    const card = cards[0] as { type?: string; version?: string; body?: unknown[] };
    expect(card.type).toBe("AdaptiveCard");
    expect(Array.isArray(card.body)).toBe(true);
    // The prose survives, with the JSON lifted out of it.
    expect(text).toContain("Falcon 9 Block 5");
    expect(text).not.toContain("AdaptiveCard");
  });

  it("records the version the agent actually sends, whatever the audit pins", () => {
    // THIS TEST DOES NOT ASSERT 1.5. V8.4 pins 1.5 "so a single payload renders identically
    // in the Web Chat embed and in Teams", and the deployed agent emits 1.6. That is a real
    // discrepancy for a human to settle - move the pin or change what the agent emits - and
    // writing 1.6 in here as the expectation would quietly ratify one answer. The test
    // records what arrives so the disagreement stays visible instead of being absorbed.
    const { cards } = extractCardsFromText(realReply);
    const card = cards[0] as { version?: string };
    expect(typeof card.version).toBe("string");
    expect(card.version).toMatch(/^1\.\d$/);
  });

  it("leaves prose alone when it carries no card", () => {
    const plain = "Saturday has the most Meridian launches, with 309.";
    const { cards, text } = extractCardsFromText(plain);
    expect(cards).toHaveLength(0);
    expect(text).toBe(plain);
  });

  it("does not mistake an ordinary JSON object for a card", () => {
    // Only `"type": "AdaptiveCard"` counts. A tool result or a code sample quoted in the
    // prose must be left where it is, or the answer loses content the reader needs.
    const withJson = 'Here is the row: {"vehicle": "Electron", "launches": 258} - note it.';
    const { cards, text } = extractCardsFromText(withJson);
    expect(cards).toHaveLength(0);
    expect(text).toBe(withJson);
  });

  it("survives malformed JSON in the prose without losing the text", () => {
    const broken = "Counts below { not json at all, and no closing brace";
    const { cards, text } = extractCardsFromText(broken);
    expect(cards).toHaveLength(0);
    expect(text).toBe(broken);
  });

  it("handles a brace inside a string literal in the card", () => {
    // The balanced-brace scan has to respect string literals, or a card whose text contains
    // "{" truncates and fails to parse - silently, back to zero cards.
    const card = '{"type":"AdaptiveCard","version":"1.5","body":[{"type":"TextBlock","text":"a { brace"}]}';
    const { cards } = extractCardsFromText("Prose. " + card);
    expect(cards).toHaveLength(1);
  });
});
