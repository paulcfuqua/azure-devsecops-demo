/**
 * MOCK_LLM=1 driver — a deterministic fake LLM.
 *
 * It replays the recorded tool plan matching the question: first turn emits
 * the plan's tool_use blocks; after the (real) tool results come back it
 * composes the final JSON spec from them. Questions without a recorded plan
 * get a deterministic markdownBlock spec. The __test_* plans additionally
 * exercise the validation gate (invalid spec -> repair -> valid/error).
 */
import type Anthropic from "@anthropic-ai/sdk";
import type { DriverRequest, DriverTurn, LlmDriver } from "./driver.js";
import { BROKEN_SPEC, findPlan, type RecordedPlan } from "./plans.js";

function textTurn(json: unknown): DriverTurn {
  return {
    stopReason: "end_turn",
    content: [{ type: "text", text: JSON.stringify(json, null, 2) }],
  };
}

export class MockLlmDriver implements LlmDriver {
  private plan: RecordedPlan | undefined;
  private phase: "start" | "awaiting_results" | "answered" = "start";
  private toolUseIds: string[] = [];
  private question = "";

  async complete(req: DriverRequest): Promise<DriverTurn> {
    const firstUser = req.messages.find((m) => m.role === "user");
    const question =
      typeof firstUser?.content === "string"
        ? firstUser.content
        : ((firstUser?.content ?? [])
            .filter(
              (b): b is Anthropic.TextBlockParam =>
                typeof b === "object" && b !== null && (b as { type?: string }).type === "text",
            )
            .map((b) => b.text)
            .join("\n") ?? "");

    if (this.phase === "start") {
      this.question = question;
      this.plan = findPlan(question);
      if (this.plan && this.plan.toolCalls.length > 0) {
        this.phase = "awaiting_results";
        this.toolUseIds = this.plan.toolCalls.map((_, i) => `toolu_mock_${i}`);
        return {
          stopReason: "tool_use",
          content: this.plan.toolCalls.map((call, i) => ({
            type: "tool_use",
            id: this.toolUseIds[i]!,
            name: call.name,
            input: call.input,
          })),
        };
      }
      this.phase = "answered";
      return textTurn(this.firstSpec([]));
    }

    if (this.phase === "awaiting_results") {
      this.phase = "answered";
      const results = this.collectResults(req.messages);
      return textTurn(this.firstSpec(results));
    }

    // phase === "answered": the loop came back — this is the repair round.
    if (this.plan?.alwaysInvalid) {
      return textTurn(BROKEN_SPEC);
    }
    const results = this.collectResults(req.messages);
    return textTurn(this.plan ? this.plan.buildSpec(results) : this.fallbackSpec(question));
  }

  private firstSpec(results: unknown[]): unknown {
    if (!this.plan) {
      return this.fallbackSpec(this.question);
    }
    if (this.plan.firstSpecInvalid || this.plan.alwaysInvalid) {
      return BROKEN_SPEC;
    }
    return this.plan.buildSpec(results);
  }

  private fallbackSpec(question: string): unknown {
    return {
      version: "1",
      layout: "stack",
      components: [
        {
          type: "markdownBlock",
          title: "Mock mode",
          markdown:
            "No recorded tool plan matches this question in `MOCK_LLM` mode. " +
            "Ask one of the golden questions, or run with `ANTHROPIC_API_KEY` for live answers." +
            (question ? `\n\nQuestion received: \`${question.slice(0, 200)}\`` : ""),
        },
      ],
    };
  }

  /** Pull tool_result payloads (in tool_use order) out of the conversation. */
  private collectResults(messages: Anthropic.MessageParam[]): unknown[] {
    const byId = new Map<string, unknown>();
    for (const m of messages) {
      if (m.role !== "user" || typeof m.content === "string") continue;
      for (const block of m.content) {
        if (typeof block !== "object" || block === null) continue;
        if ((block as { type?: string }).type !== "tool_result") continue;
        const tr = block as Anthropic.ToolResultBlockParam;
        const raw =
          typeof tr.content === "string"
            ? tr.content
            : (tr.content ?? [])
                .map((b) => ((b as { type?: string }).type === "text" ? (b as Anthropic.TextBlockParam).text : ""))
                .join("");
        if (tr.is_error) {
          byId.set(tr.tool_use_id, { __error: raw });
          continue;
        }
        try {
          byId.set(tr.tool_use_id, JSON.parse(raw));
        } catch {
          byId.set(tr.tool_use_id, raw);
        }
      }
    }
    return this.toolUseIds.map((id) => byId.get(id));
  }
}
