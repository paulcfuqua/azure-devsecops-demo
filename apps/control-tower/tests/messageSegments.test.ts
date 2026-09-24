import { describe, expect, it } from "vitest";
import { splitMessageSegments } from "../src/agent/messageSegments";

/**
 * The fixtures below are shapes MEASURED from the deployed agent over Direct Line on
 * 2026-09-24, not invented. The agent returns a different format run to run for the same
 * class of question, which is the whole reason this splitter exists.
 */
describe("splitMessageSegments", () => {
  it("leaves ordinary prose as a single prose segment", () => {
    const out = splitMessageSegments("Saturday has the most launches, with 309 launches.");
    expect(out).toEqual([
      { kind: "prose", text: "Saturday has the most launches, with 309 launches." },
    ]);
  });

  it("returns nothing for empty or whitespace-only text", () => {
    expect(splitMessageSegments("")).toEqual([]);
    expect(splitMessageSegments("   \n\n  ")).toEqual([]);
  });

  it("lifts a fenced ASCII table out as a pre segment, keeping its alignment", () => {
    // Measured: the agent answered the technician question with a ```text ASCII table.
    const text = [
      "The 10 technicians are:",
      "",
      "```text",
      "+-------------------+------------------+",
      "| Technician        | Work Order Count |",
      "+-------------------+------------------+",
      "| Yuki Tanabe       | 33               |",
      "+-------------------+------------------+",
      "```",
      "",
      "Source: Meridian's operations lakehouse.",
    ].join("\n");

    const out = splitMessageSegments(text);
    expect(out.map((s) => s.kind)).toEqual(["prose", "pre", "prose"]);
    expect(out[1]).toMatchObject({ kind: "pre", lang: "text" });
    // Alignment is the entire point - the interior must survive byte for byte.
    expect(out[1]?.text).toContain("| Yuki Tanabe       | 33               |");
    expect(out[2]?.text).toContain("Source: Meridian's operations lakehouse.");
  });

  it("renders a markdown pipe table as a pre segment", () => {
    // The shape in the sponsor's screenshot, which collapsed into one paragraph.
    const text = [
      "The technicians are:",
      "| Technician | Work Orders | Defects |",
      "|------------|-------------|---------|",
      "| Marcus Bell | 66 | 4,169 |",
      "| Yuki Tanabe | 63 | 4,093 |",
      "Source: the lakehouse.",
    ].join("\n");

    const out = splitMessageSegments(text);
    expect(out.map((s) => s.kind)).toEqual(["prose", "pre", "prose"]);
    expect(out[1]?.text.split("\n")).toHaveLength(4);
    expect(out[1]?.text).toContain("| Marcus Bell | 66 | 4,169 |");
  });

  it("DROPS the empty fence left behind after a card is extracted", () => {
    // extractCardsFromText lifts the card JSON out of a ```json fence and leaves the
    // fence. Rendering it would put an empty grey box under every successful card.
    const text = "The top scrub causes are led by weather holds.\n\n```json\n\n```\n\nSource: the lakehouse.";
    const out = splitMessageSegments(text);
    expect(out.map((s) => s.kind)).toEqual(["prose", "prose"]);
    expect(out.some((s) => s.kind === "pre")).toBe(false);
    expect(out[0]?.text).toContain("weather holds");
    expect(out[1]?.text).toContain("Source: the lakehouse.");
  });

  it("does not mistake a sentence beginning with a pipe for a table", () => {
    // No delimiter row -> not a table.
    const text = "| this is not a table\nand neither is this";
    const out = splitMessageSegments(text);
    expect(out.map((s) => s.kind)).toEqual(["prose"]);
    expect(out[0]?.text).toContain("| this is not a table");
  });

  it("handles a fence the agent never closed", () => {
    // Truncated generative output is a real case; the tail must still be readable.
    const text = "Here it is:\n\n```json\n{ \"a\": 1 }";
    const out = splitMessageSegments(text);
    expect(out.map((s) => s.kind)).toEqual(["prose", "pre"]);
    expect(out[1]?.text).toContain('{ "a": 1 }');
  });

  it("keeps two fenced blocks separate", () => {
    const text = "one\n\n```\nAAA\n```\n\ntwo\n\n```\nBBB\n```\n\nthree";
    const out = splitMessageSegments(text);
    expect(out.map((s) => s.kind)).toEqual(["prose", "pre", "prose", "pre", "prose"]);
    expect(out[1]?.text).toBe("AAA");
    expect(out[3]?.text).toBe("BBB");
  });

  it("preserves interior blank lines inside a fence", () => {
    const text = "```\nline one\n\nline three\n```";
    const out = splitMessageSegments(text);
    expect(out).toHaveLength(1);
    expect(out[0]?.text).toBe("line one\n\nline three");
  });

  it("never loses the source attribution that follows a table", () => {
    // A regression guard for the whole point of the exercise: the provenance sentence is
    // what makes an answer checkable, and it sits AFTER the table in every measured reply.
    const text = "Rows:\n| a | b |\n|---|---|\n| 1 | 2 |\nSource: Meridian's operations lakehouse.";
    const out = splitMessageSegments(text);
    const prose = out.filter((s) => s.kind === "prose").map((s) => s.text).join(" ");
    expect(prose).toContain("Source: Meridian's operations lakehouse.");
  });
});
