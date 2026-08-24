/**
 * /ask end-to-end in MOCK_LLM mode: HTTP in -> tool loop -> real sql.js SQL /
 * fixture adapters -> spec composition -> schema validation -> HTTP out.
 */
import { describe, expect, it } from "vitest";
import request from "supertest";
import { createApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { ALWAYS_INVALID_QUESTION } from "../src/llm/plans.js";
import { validateSpec } from "../src/validation.js";

const app = createApp({ config: { ...loadConfig(), llmMode: "mock" } });

describe("POST /ask (MOCK_LLM end-to-end)", () => {
  it("answers the canonical golden question with a validated spec + sql + trace", async () => {
    const res = await request(app)
      .post("/ask")
      .send({ question: "Which day of the week has the most launches?" })
      .expect(200);

    expect(validateSpec(res.body.spec).ok).toBe(true);

    const text = JSON.stringify(res.body.spec);
    expect(text).toContain("Saturday");
    expect(text).toContain("309");

    expect(res.body.sql).toHaveLength(1);
    expect(res.body.sql[0]).toMatch(/FROM launches/i);

    expect(res.body.toolTrace).toHaveLength(1);
    expect(res.body.toolTrace[0]).toMatchObject({
      name: "query_lakehouse_sql",
      rejected: false,
      isError: false,
    });
  });

  it("exercises a fixture-backed tool through the pipeline (cost series)", async () => {
    const res = await request(app)
      .post("/ask")
      .send({ question: "Which cost center has the highest total spend?" })
      .expect(200);

    expect(validateSpec(res.body.spec).ok).toBe(true);
    expect(res.body.toolTrace.map((t: { name: string }) => t.name)).toEqual(["get_cost_series"]);
    // No lakehouse SQL was run for this plan.
    expect(res.body.sql).toEqual([]);
  });

  it("answers an unknown question with a deterministic valid fallback spec", async () => {
    const res = await request(app)
      .post("/ask")
      .send({ question: "What is the airspeed velocity of an unladen swallow?" })
      .expect(200);
    expect(validateSpec(res.body.spec).ok).toBe(true);
    expect(JSON.stringify(res.body.spec)).toContain("No recorded tool plan");
  });

  it("returns 400 for a missing/empty question", async () => {
    await request(app).post("/ask").send({}).expect(400);
    await request(app).post("/ask").send({ question: "   " }).expect(400);
    await request(app).post("/ask").send({ question: 42 }).expect(400);
  });

  it("returns 422 with structured errors when no valid spec can be produced", async () => {
    const res = await request(app)
      .post("/ask")
      .send({ question: ALWAYS_INVALID_QUESTION })
      .expect(422);
    expect(res.body.error).toBe("invalid_spec");
    expect(res.body.validationErrors.length).toBeGreaterThan(0);
    expect(res.body.spec).toBeUndefined();
  });

  it("GET /healthz reports mode and pinned model", async () => {
    const res = await request(app).get("/healthz").expect(200);
    expect(res.body.ok).toBe(true);
    expect(res.body.mode).toBe("mock");
    expect(typeof res.body.model).toBe("string");
    expect(res.body.model.length).toBeGreaterThan(0);
  });
});
