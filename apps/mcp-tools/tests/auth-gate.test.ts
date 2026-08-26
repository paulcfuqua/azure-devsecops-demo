/**
 * Inbound auth gate — the control that stops the public MCP endpoint being
 * callable by anyone who finds the FQDN.
 *
 * The container app runs external ingress by design, so these tests are the
 * difference between "we intended to require a token" and "we require a token".
 *
 * Uses the same harness as mcp-client.test.ts — listen on an ephemeral port and
 * use fetch — rather than adding a test-only HTTP dependency to a repo whose
 * whole subject is supply-chain risk.
 */
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import { createApp, MCP_PATH } from "../src/app.js";
import type { McpToolsConfig } from "../src/config.js";
import { loadConfig } from "../src/config.js";
import {
  loadInboundAuth,
  secretsMatch,
  describeInboundAuth,
  type InboundAuth,
} from "../src/auth-gate.js";

const TOKEN = "s3cret-token-value";
const enforced: InboundAuth = { token: TOKEN, enforced: true, deliberatelyOpen: false };
const open: InboundAuth = { token: undefined, enforced: false, deliberatelyOpen: false };

/** A JSON-RPC body shaped enough to reach the handler if the gate lets it past. */
const RPC = JSON.stringify({ jsonrpc: "2.0", method: "tools/list", id: 1 });
const JSON_HEADERS = { "content-type": "application/json", accept: "application/json" };

async function start(auth: InboundAuth): Promise<{ server: Server; url: string }> {
  const config: McpToolsConfig = { port: 0, backendMode: "local", inboundAuth: auth };
  const server = createApp({ config }).listen(0);
  await new Promise<void>((resolve) => server.once("listening", () => resolve()));
  return { server, url: `http://127.0.0.1:${(server.address() as AddressInfo).port}` };
}

const stop = (server: Server) => new Promise<void>((r) => server.close(() => r()));

describe("the gate actually blocks", () => {
  let server: Server, url: string;
  beforeAll(async () => ({ server, url } = await start(enforced)));
  afterAll(async () => await stop(server));

  const post = (headers: Record<string, string> = {}) =>
    fetch(`${url}${MCP_PATH}`, { method: "POST", headers: { ...JSON_HEADERS, ...headers }, body: RPC });

  it("rejects a request with no credential", async () => {
    const res = await post();
    expect(res.status).toBe(401);
    expect((await res.json()).error.message).toBe("Unauthorized");
  });

  it("rejects a wrong bearer token", async () => {
    expect((await post({ authorization: "Bearer not-the-token" })).status).toBe(401);
  });

  it("rejects a wrong x-api-key", async () => {
    expect((await post({ "x-api-key": "not-the-token" })).status).toBe(401);
  });

  it("gates GET and DELETE too, not just POST", async () => {
    // Both answer 405 once past the gate, so a 405 here would prove the gate
    // was never consulted.
    for (const method of ["GET", "DELETE"]) {
      const res = await fetch(`${url}${MCP_PATH}`, { method });
      expect(res.status).toBe(401);
    }
  });

  it("advertises the scheme so a client knows what to send", async () => {
    expect((await post()).headers.get("www-authenticate")).toMatch(/^Bearer /);
  });

  it("never echoes the expected token", async () => {
    const res = await post({ authorization: "Bearer wrong" });
    const body = await res.text();
    expect(body).not.toContain(TOKEN);
    expect(JSON.stringify([...res.headers])).not.toContain(TOKEN);
  });

  it("cannot be used to probe whether a key exists", async () => {
    // A missing credential and a wrong one must be indistinguishable.
    const missing = await post();
    const wrong = await post({ authorization: "Bearer wrong" });
    expect(missing.status).toBe(wrong.status);
    expect(await missing.text()).toBe(await wrong.text());
  });
});

describe("the gate lets the right caller through", () => {
  let server: Server, url: string;
  beforeAll(async () => ({ server, url } = await start(enforced)));
  afterAll(async () => await stop(server));

  const post = (headers: Record<string, string>) =>
    fetch(`${url}${MCP_PATH}`, { method: "POST", headers: { ...JSON_HEADERS, ...headers }, body: RPC });

  it("accepts the correct bearer token", async () => {
    expect((await post({ authorization: `Bearer ${TOKEN}` })).status).not.toBe(401);
  });

  it("accepts the correct x-api-key (Copilot Studio connector form)", async () => {
    expect((await post({ "x-api-key": TOKEN })).status).not.toBe(401);
  });

  it("is case-insensitive about the Bearer keyword", async () => {
    expect((await post({ authorization: `bearer ${TOKEN}` })).status).not.toBe(401);
  });

  it("keeps /healthz reachable for the Container Apps probe", async () => {
    const res = await fetch(`${url}/healthz`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.ok).toBe(true);
    // Posture is reported; the token is not.
    expect(body.auth).toEqual({ enforced: true, deliberatelyOpen: false });
    expect(JSON.stringify(body)).not.toContain(TOKEN);
  });
});

describe("an ungated server still serves", () => {
  let server: Server, url: string;
  beforeAll(async () => ({ server, url } = await start(open)));
  afterAll(async () => await stop(server));

  it("passes requests through when not enforced", async () => {
    const res = await fetch(`${url}${MCP_PATH}`, {
      method: "POST",
      headers: JSON_HEADERS,
      body: RPC,
    });
    expect(res.status).not.toBe(401);
  });
});

describe("cloud mode fails closed", () => {
  const FULL_CLOUD = {
    MLS_TOOL_BACKENDS: "cloud",
    MLS_FABRIC_SQL_ENDPOINT: "abc.datawarehouse.fabric.microsoft.com",
    MLS_FABRIC_DATABASE: "mls_operations",
    MLS_LOG_ANALYTICS_WORKSPACE_ID: "11111111-2222-3333-4444-555555555555",
    MLS_GITHUB_REPO: "owner/repo",
    GITHUB_TOKEN: "ghs_x",
    AZURE_SUBSCRIPTION_ID: "11111111-2222-3333-4444-555555555555",
  } as unknown as NodeJS.ProcessEnv;

  it("refuses to boot in cloud mode with no token", () => {
    expect(() => loadConfig(FULL_CLOUD)).toThrow(/MCP_AUTH_TOKEN/);
  });

  it("explains why, in terms of exposure and cost", () => {
    try {
      loadConfig(FULL_CLOUD);
      expect.unreachable("should have thrown");
    } catch (err) {
      expect((err as Error).message).toMatch(/external ingress/);
      expect((err as Error).message).toMatch(/bills the subscription/);
    }
  });

  it("boots in cloud mode once the token is set", () => {
    const config = loadConfig({ ...FULL_CLOUD, MCP_AUTH_TOKEN: TOKEN });
    expect(config.inboundAuth.enforced).toBe(true);
    expect(config.inboundAuth.deliberatelyOpen).toBe(false);
  });

  it("allows an OPEN cloud endpoint only when explicitly chosen", () => {
    const config = loadConfig({ ...FULL_CLOUD, MCP_ALLOW_UNAUTHENTICATED: "true" });
    expect(config.inboundAuth.enforced).toBe(false);
    expect(config.inboundAuth.deliberatelyOpen).toBe(true);
    expect(describeInboundAuth(config.inboundAuth)).toMatch(/DISABLED/);
  });

  it("still reports every missing upstream setting first, not the auth error", () => {
    // Regression guard: resolving auth before the cloud config would replace the
    // complete missing-settings list with one unrelated error, reintroducing the
    // one-variable-per-attempt boot loop config.ts exists to avoid.
    try {
      loadConfig({ MLS_TOOL_BACKENDS: "cloud" } as NodeJS.ProcessEnv);
      expect.unreachable("should have thrown");
    } catch (err) {
      expect((err as Error).message).toMatch(/MLS_FABRIC_SQL_ENDPOINT/);
      expect((err as Error).message).toMatch(/AZURE_SUBSCRIPTION_ID/);
    }
  });

  it("leaves local mode open with no ceremony", () => {
    const config = loadConfig({} as NodeJS.ProcessEnv);
    expect(config.inboundAuth.enforced).toBe(false);
    expect(config.inboundAuth.deliberatelyOpen).toBe(false);
  });

  it("enforces in local mode too when a token is set", () => {
    const config = loadConfig({ MCP_AUTH_TOKEN: TOKEN } as unknown as NodeJS.ProcessEnv);
    expect(config.inboundAuth.enforced).toBe(true);
  });
});

describe("secretsMatch", () => {
  it("matches identical secrets and rejects near-misses", () => {
    expect(secretsMatch(TOKEN, TOKEN)).toBe(true);
    expect(secretsMatch(`${TOKEN}x`, TOKEN)).toBe(false);
    expect(secretsMatch("", TOKEN)).toBe(false);
  });

  it("does not throw on differing lengths", () => {
    // timingSafeEqual throws on a length mismatch; hashing both sides first is
    // what makes this safe to call on arbitrary attacker input.
    expect(() => secretsMatch("a", "a-much-longer-secret-value")).not.toThrow();
    expect(secretsMatch("a", "a-much-longer-secret-value")).toBe(false);
  });
});

describe("loadInboundAuth trims and ignores blanks", () => {
  it("treats whitespace-only as unset", () => {
    expect(loadInboundAuth({ MCP_AUTH_TOKEN: "   " } as NodeJS.ProcessEnv, "local").enforced).toBe(
      false,
    );
  });

  it("trims a pasted token", () => {
    const auth = loadInboundAuth({ MCP_AUTH_TOKEN: `  ${TOKEN}\n` } as NodeJS.ProcessEnv, "local");
    expect(auth.token).toBe(TOKEN);
  });
});
