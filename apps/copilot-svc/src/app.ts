/**
 * HTTP surface: POST /ask { question } -> { spec, sql?, toolTrace } (200),
 * or a structured error (400 bad request, 422 invalid spec, 502 llm error).
 * GET /healthz for liveness.
 */
import express, { type Express } from "express";
import { loadConfig, type CopilotConfig } from "./config.js";
import { runAsk } from "./loop.js";
import type { DriverFactory } from "./llm/driver.js";
import { LiveLlmDriver } from "./llm/live.js";
import { MockLlmDriver } from "./llm/mock.js";
import { createLocalBackends, type Backends } from "./tools/backends.js";
import { ToolRegistry } from "./tools/index.js";

export interface AppDeps {
  config?: CopilotConfig;
  backends?: Backends;
  driverFactory?: DriverFactory;
}

export function defaultDriverFactory(config: CopilotConfig) {
  return config.llmMode === "live" ? new LiveLlmDriver(config) : new MockLlmDriver();
}

export function createApp(deps: AppDeps = {}): Express {
  const config = deps.config ?? loadConfig();
  const backends = deps.backends ?? createLocalBackends();
  const registry = new ToolRegistry(backends);
  const driverFactory = deps.driverFactory ?? defaultDriverFactory;

  const app = express();
  app.use(express.json({ limit: "64kb" }));

  app.get("/healthz", (_req, res) => {
    res.json({ ok: true, mode: config.llmMode, model: config.model });
  });

  app.post("/ask", async (req, res) => {
    const question = (req.body as { question?: unknown } | undefined)?.question;
    if (typeof question !== "string" || question.trim().length === 0) {
      res.status(400).json({
        error: "bad_request",
        message: 'POST /ask requires a JSON body: { "question": "<non-empty string>" }',
      });
      return;
    }

    const result = await runAsk(question, {
      config,
      registry,
      driver: driverFactory(config),
    });

    if (result.ok) {
      const { ok: _ok, ...body } = result;
      res.json(body);
      return;
    }
    const { ok: _ok, ...body } = result;
    res.status(result.error === "invalid_spec" ? 422 : 502).json(body);
  });

  return app;
}
