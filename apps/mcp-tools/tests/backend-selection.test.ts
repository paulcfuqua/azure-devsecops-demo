/**
 * Backend selection — `MLS_TOOL_BACKENDS=local|cloud`.
 *
 * The claim this file has to support is "tenant activation is CONFIGURATION,
 * not development": setting one environment variable plus six settings switches
 * all five tools from CSVs and fixtures to Fabric, Azure Monitor, GitHub,
 * Defender and Cost Management, with the same tool names, the same schemas and
 * the same response shapes — and with the SQL dialect the agent is told to write
 * following the switch automatically.
 *
 * `cloud` used to throw "not wired yet" at boot. What it must do now is fail
 * fast with the COMPLETE list of what is missing, and otherwise come up.
 *
 * Every cloud construction here injects a fake credential and a mocked `fetch`.
 * Nothing in this file can reach a network.
 */
import type { AddressInfo } from "node:net";
import type { Server as HttpServer } from "node:http";
import { describe, expect, it } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { createApp, MCP_PATH, type AppDeps } from "../src/app.js";
import { loadCloudConfig, loadConfig, type CloudConfig } from "../src/config.js";
import { createCloudBackends } from "../src/tools/cloud/index.js";
import { type TdsExecutor } from "../src/tools/cloud/fabric-sql.js";
import { MockFetch, noSleep } from "./helpers/mock-fetch.js";

const FULL_ENV = {
  MLS_TOOL_BACKENDS: "cloud",
  MLS_FABRIC_SQL_ENDPOINT: "abc123.datawarehouse.fabric.microsoft.com",
  MLS_FABRIC_DATABASE: "mls_operations",
  MLS_LOG_ANALYTICS_WORKSPACE_ID: "11111111-2222-3333-4444-555555555555",
  MLS_GITHUB_REPO: "paulcfuqua/azure-devsecops",
  GITHUB_TOKEN: "ghp_0123456789abcdefghijABCDEFGHIJ",
  AZURE_SUBSCRIPTION_ID: "00000000-1111-2222-3333-444444444444",
} as unknown as NodeJS.ProcessEnv;

const fakeCredential = {
  async getToken() {
    return { token: "fake", expiresOnTimestamp: Date.now() + 3_600_000 };
  },
};

const fakeExecutor: TdsExecutor = {
  async execute(batch) {
    if (batch.includes("@@DATEFIRST")) {
      return { columns: ["datefirst", "seed_date_weekday"], rows: [[7, 7]] };
    }
    return { columns: ["n"], rows: [[1200]] };
  },
  async close() {},
};

async function cloudBackends(config: CloudConfig, mock = new MockFetch()) {
  return createCloudBackends(config, {
    credential: fakeCredential,
    fetchImpl: mock.fetch,
    executor: fakeExecutor,
    sleep: noSleep,
  });
}

describe("MLS_TOOL_BACKENDS=local is unchanged", () => {
  it("defaults to local when the variable is unset", () => {
    expect(loadConfig({} as NodeJS.ProcessEnv)).toEqual({ port: 8080, backendMode: "local" });
  });

  it("honours PORT", () => {
    expect(loadConfig({ PORT: "9000" } as NodeJS.ProcessEnv).port).toBe(9000);
  });

  it("needs no cloud settings at all", () => {
    expect(() => loadConfig({ MLS_TOOL_BACKENDS: "local" } as NodeJS.ProcessEnv)).not.toThrow();
  });

  it("still rejects a value that is neither local nor cloud", () => {
    expect(() => loadConfig({ MLS_TOOL_BACKENDS: "fabric" } as NodeJS.ProcessEnv)).toThrow(
      /must be "local" or "cloud"/,
    );
  });
});

describe("MLS_TOOL_BACKENDS=cloud is real", () => {
  it("no longer refuses at boot", () => {
    const config = loadConfig(FULL_ENV);
    expect(config.backendMode).toBe("cloud");
    expect(config.cloud?.fabricSqlEndpoint).toBe("abc123.datawarehouse.fabric.microsoft.com");
  });

  it("fails fast listing EVERY missing setting, not one per attempt", () => {
    try {
      loadConfig({ MLS_TOOL_BACKENDS: "cloud" } as NodeJS.ProcessEnv);
      expect.unreachable("should have thrown");
    } catch (err) {
      const message = (err as Error).message;
      for (const name of [
        "MLS_FABRIC_SQL_ENDPOINT",
        "MLS_FABRIC_DATABASE",
        "MLS_LOG_ANALYTICS_WORKSPACE_ID",
        "MLS_GITHUB_REPO",
        "GITHUB_TOKEN",
        "AZURE_SUBSCRIPTION_ID",
      ]) {
        expect(message).toContain(name);
      }
      expect(message).toContain("6 required settings");
      // …and it says what each one is for.
      expect(message).toContain("Fabric SQL analytics endpoint FQDN");
      // …and it says that no Azure secret is expected.
      expect(message).toContain("managed identity");
    }
  });

  it("names the one thing that is missing when only one is", () => {
    const { MLS_FABRIC_DATABASE: _omitted, ...partial } = FULL_ENV as Record<string, string>;
    expect(() => loadConfig(partial as NodeJS.ProcessEnv)).toThrow(/1 required setting:/);
    expect(() => loadConfig(partial as NodeJS.ProcessEnv)).toThrow(/MLS_FABRIC_DATABASE/);
  });

  it("accepts MLS_GITHUB_TOKEN as an alias for GITHUB_TOKEN", () => {
    const { GITHUB_TOKEN: token, ...rest } = FULL_ENV as Record<string, string>;
    const config = loadCloudConfig({
      ...rest,
      MLS_GITHUB_TOKEN: token,
    } as unknown as NodeJS.ProcessEnv);
    expect(config.githubToken).toBe(token);
  });

  it("treats a whitespace-only value as missing", () => {
    expect(() =>
      loadConfig({ ...FULL_ENV, MLS_GITHUB_REPO: "   " } as NodeJS.ProcessEnv),
    ).toThrow(/MLS_GITHUB_REPO/);
  });

  it("defaults the cost scope to the subscription and the tag to costCenter", () => {
    const config = loadCloudConfig(FULL_ENV);
    expect(config.costScope).toBe("/subscriptions/00000000-1111-2222-3333-444444444444");
    // CLAUDE.md mandates `costCenter` on every resource group.
    expect(config.costCenterTag).toBe("costCenter");
  });

  it("lets the cost scope be narrowed to a resource group", () => {
    const config = loadCloudConfig({
      ...FULL_ENV,
      MLS_COST_SCOPE: "/subscriptions/abc/resourceGroups/mls-rg-apps",
    } as NodeJS.ProcessEnv);
    expect(config.costScope).toBe("/subscriptions/abc/resourceGroups/mls-rg-apps");
  });

  it("carries AZURE_CLIENT_ID through for a user-assigned managed identity", () => {
    expect(loadCloudConfig(FULL_ENV).azureClientId).toBeUndefined();
    expect(
      loadCloudConfig({ ...FULL_ENV, AZURE_CLIENT_ID: "aaaa-bbbb" } as NodeJS.ProcessEnv)
        .azureClientId,
    ).toBe("aaaa-bbbb");
  });

  it("reads no Azure secret from the environment — hard rule 5", () => {
    const config = loadCloudConfig(FULL_ENV);
    // The only bearer token in the resolved config is GitHub's, which has no
    // managed-identity equivalent.
    const secretish = Object.entries(config).filter(([key]) => /secret|password|key/i.test(key));
    expect(secretish).toEqual([]);
    expect(Object.keys(config).filter((k) => /token/i.test(k))).toEqual(["githubToken"]);
  });
});

describe("createCloudBackends wires all five cloud adapters", () => {
  it("selects the cloud implementation for every tool", async () => {
    const backends = await cloudBackends(loadCloudConfig(FULL_ENV));
    expect(backends.lakehouseSql.constructor.name).toBe("FabricLakehouseSqlBackend");
    expect(backends.logAnalytics.constructor.name).toBe("AzureLogAnalyticsBackend");
    expect(backends.githubSecurity.constructor.name).toBe("LiveGithubSecurityBackend");
    expect(backends.defenderPosture.constructor.name).toBe("AzureDefenderPostureBackend");
    expect(backends.costSeries.constructor.name).toBe("AzureCostSeriesBackend");
  });

  it("switches the declared SQL dialect to T-SQL", async () => {
    const backends = await cloudBackends(loadCloudConfig(FULL_ENV));
    expect(backends.lakehouseSql.dialect).toBe("tsql");
  });

  it("shares one token provider, so five tools do not become five token calls", async () => {
    let acquisitions = 0;
    const mock = new MockFetch()
      .on((url) => url.includes("ascScore") && !url.includes("secureScoreControls"), {
        status: 200,
        body: { name: "ascScore", properties: {} },
      })
      .on(/secureScoreControls/, { status: 200, body: { value: [] } })
      .on(/loganalytics/, { status: 200, body: { tables: [] } });

    const backends = await createCloudBackends(loadCloudConfig(FULL_ENV), {
      credential: {
        async getToken() {
          acquisitions += 1;
          return { token: "fake", expiresOnTimestamp: Date.now() + 3_600_000 };
        },
      },
      fetchImpl: mock.fetch,
      executor: fakeExecutor,
      sleep: noSleep,
    });

    await backends.defenderPosture.getPosture();
    await backends.logAnalytics.query("AppRequests");
    // Two different scopes (ARM and Log Analytics), so two tokens — not four.
    expect(acquisitions).toBe(2);
  });
});

describe("/healthz makes the selection observable", () => {
  async function healthz(
    config: AppDeps["config"],
    backends: AppDeps["backends"],
  ): Promise<any> {
    const app = createApp({ config, backends });
    const http: HttpServer = app.listen(0);
    await new Promise<void>((resolve) => http.once("listening", () => resolve()));
    try {
      const port = (http.address() as AddressInfo).port;
      return await (await fetch(`http://127.0.0.1:${port}/healthz`)).json();
    } finally {
      await new Promise<void>((resolve) => http.close(() => resolve()));
    }
  }

  it("reports cloud mode, the T-SQL dialect and every cloud adapter by name", async () => {
    const config = loadConfig(FULL_ENV);
    const body = await healthz(config, await cloudBackends(config.cloud!));
    expect(body.mode).toBe("cloud");
    expect(body.sqlDialect).toBe("tsql");
    expect(body.adapters).toEqual({
      query_lakehouse_sql: "FabricLakehouseSqlBackend",
      query_log_analytics: "AzureLogAnalyticsBackend",
      get_github_security: "LiveGithubSecurityBackend",
      get_defender_posture: "AzureDefenderPostureBackend",
      get_cost_series: "AzureCostSeriesBackend",
    });
    expect(body.tools).toBe(5);
  });

  it("never echoes a token, a connection string or a workspace id", async () => {
    const config = loadConfig(FULL_ENV);
    const body = JSON.stringify(await healthz(config, await cloudBackends(config.cloud!)));
    expect(body).not.toContain("ghp_0123456789");
    expect(body).not.toContain("11111111-2222-3333-4444-555555555555");
    expect(body).not.toContain("datawarehouse.fabric.microsoft.com");
  });
});

describe("cloud mode end to end over MCP", () => {
  it("advertises T-SQL idioms to the agent and answers a T-SQL query", async () => {
    // This is the whole fix in one assertion: in cloud mode the agent is told to
    // use DATEPART, not strftime, because the engine behind the tool is T-SQL.
    const config = loadConfig(FULL_ENV);
    const app = createApp({ config, backends: await cloudBackends(config.cloud!) });
    const http = app.listen(0);
    await new Promise<void>((resolve) => http.once("listening", () => resolve()));
    const port = (http.address() as AddressInfo).port;

    const client = new Client({ name: "cloud-mode-test", version: "0.0.0" });
    await client.connect(
      new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}${MCP_PATH}`)),
    );
    try {
      const { tools } = await client.listTools();
      expect(tools).toHaveLength(5);
      const sqlTool = tools.find((t) => t.name === "query_lakehouse_sql")!;
      expect(sqlTool.description).toContain("DATEPART(weekday, actual_date)");
      expect(sqlTool.description).toContain("SET DATEFIRST 7");
      expect(sqlTool.description).not.toContain("strftime(");

      const result = await client.callTool({
        name: "query_lakehouse_sql",
        arguments: { sql: "SELECT COUNT(*) AS n FROM launches" },
      });
      expect(result.isError).toBeFalsy();
      const payload = JSON.parse((result.content as any)[0].text);
      expect(payload.rows[0][0]).toBe(1200);
    } finally {
      await client.close();
      await new Promise<void>((resolve) => http.close(() => resolve()));
    }
  });

  it("surfaces a cloud adapter failure as an isError result, not a protocol crash", async () => {
    const config = loadConfig(FULL_ENV);
    const mock = new MockFetch().on(/loganalytics/, {
      status: 429,
      body: { error: { code: "Throttled", message: "too many requests" } },
    });
    const app = createApp({ config, backends: await cloudBackends(config.cloud!, mock) });
    const http = app.listen(0);
    await new Promise<void>((resolve) => http.once("listening", () => resolve()));
    const port = (http.address() as AddressInfo).port;

    const client = new Client({ name: "cloud-error-test", version: "0.0.0" });
    await client.connect(
      new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}${MCP_PATH}`)),
    );
    try {
      const result = await client.callTool({
        name: "query_log_analytics",
        arguments: { query: "AppRequests" },
      });
      // The agent must see the message and be able to act on it.
      expect(result.isError).toBe(true);
      const text = JSON.stringify(result.content);
      expect(text).toContain("query_log_analytics failed");
      expect(text).toContain("429");
    } finally {
      await client.close();
      await new Promise<void>((resolve) => http.close(() => resolve()));
    }
  });

  it("refuses a SQLite idiom in cloud mode with a message the agent can act on", async () => {
    const config = loadConfig(FULL_ENV);
    const failingExecutor: TdsExecutor = {
      async execute(batch) {
        if (batch.includes("@@DATEFIRST")) {
          return { columns: ["datefirst", "seed_date_weekday"], rows: [[7, 7]] };
        }
        throw new Error("Invalid object name 'strftime'.");
      },
      async close() {},
    };
    const backends = await createCloudBackends(config.cloud!, {
      credential: fakeCredential,
      fetchImpl: new MockFetch().fetch,
      executor: failingExecutor,
      sleep: noSleep,
    });
    const app = createApp({ config, backends });
    const http = app.listen(0);
    await new Promise<void>((resolve) => http.once("listening", () => resolve()));
    const port = (http.address() as AddressInfo).port;

    const client = new Client({ name: "cloud-dialect-test", version: "0.0.0" });
    await client.connect(
      new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}${MCP_PATH}`)),
    );
    try {
      const result = await client.callTool({
        name: "query_lakehouse_sql",
        arguments: { sql: "SELECT strftime('%w', actual_date) FROM launches" },
      });
      expect(result.isError).toBe(true);
      expect(JSON.stringify(result.content)).toContain("Invalid object name 'strftime'");
    } finally {
      await client.close();
      await new Promise<void>((resolve) => http.close(() => resolve()));
    }
  });
});
