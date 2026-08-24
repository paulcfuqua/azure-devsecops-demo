/**
 * LLM driver seam: the tool-use loop talks to this interface, never to the
 * Anthropic SDK directly. Two implementations:
 *   - LiveLlmDriver (live.ts): Anthropic API, active when ANTHROPIC_API_KEY is
 *     set and MOCK_LLM != 1.
 *   - MockLlmDriver (mock.ts): deterministic replay of recorded tool plans for
 *     the golden questions — the whole pipeline (tools -> SQL -> spec ->
 *     validation) runs without an API key.
 */
import type Anthropic from "@anthropic-ai/sdk";
import type { CopilotConfig } from "../config.js";

/** What the loop needs back from one model turn. */
export interface DriverTurn {
  stopReason: "tool_use" | "end_turn" | string;
  /** Content blocks; passed back verbatim as the assistant message (preserves thinking blocks in live mode). */
  content: Anthropic.ContentBlockParam[];
}

export interface DriverRequest {
  system: string;
  messages: Anthropic.MessageParam[];
  tools: Anthropic.Tool[];
}

export interface LlmDriver {
  complete(req: DriverRequest): Promise<DriverTurn>;
}

/** A driver instance is created per /ask call (mock drivers keep per-question state). */
export type DriverFactory = (config: CopilotConfig) => LlmDriver;
