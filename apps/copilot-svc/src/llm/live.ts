/**
 * Live driver — Anthropic Messages API via @anthropic-ai/sdk.
 *
 * Model id comes from committed config (config/copilot.json — currently
 * claude-opus-5 per the claude-api skill's recommendation), never hardcoded
 * here. Adaptive thinking is enabled per the same guidance; thinking blocks
 * are echoed back unchanged by the loop (it replays `content` verbatim).
 */
import Anthropic from "@anthropic-ai/sdk";
import type { CopilotConfig } from "../config.js";
import type { DriverRequest, DriverTurn, LlmDriver } from "./driver.js";

export class LiveLlmDriver implements LlmDriver {
  private readonly client: Anthropic;

  constructor(private readonly config: CopilotConfig) {
    // Zero-arg constructor: resolves ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN /
    // an `ant auth login` profile from the environment.
    this.client = new Anthropic();
  }

  async complete(req: DriverRequest): Promise<DriverTurn> {
    const response = await this.client.messages.create({
      model: this.config.model,
      max_tokens: this.config.maxTokens,
      thinking: { type: "adaptive" },
      system: [
        {
          type: "text",
          text: req.system,
          // The system prompt (contract + schema) is stable across requests —
          // cache it; the per-question content varies after this breakpoint.
          cache_control: { type: "ephemeral" },
        },
      ],
      tools: req.tools,
      messages: req.messages,
    });
    return {
      stopReason: response.stop_reason ?? "end_turn",
      content: response.content as Anthropic.ContentBlockParam[],
    };
  }
}
