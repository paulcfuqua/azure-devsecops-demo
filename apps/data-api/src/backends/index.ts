/**
 * Backend selection — the one decision `MLS_DATA_BACKENDS` makes, taken once
 * at boot. Nothing above this file ever asks which mode it is in; the routes
 * call the same two methods either way.
 */
import type { DataApiConfig } from "../config.js";
import type { TableStore } from "../contract/allowlist.js";
import { CloudFeedsBackend, CloudTablesBackend } from "./cloud.js";
import { AzureTokenProvider, createCredential } from "./azureAuth.js";
import { LocalFeedsBackend, LocalTablesBackend } from "./local.js";
import { MssqlClient, type SqlClient } from "./sql.js";
import type { Backends } from "./types.js";

export * from "./types.js";

export function createLocalBackends(config: DataApiConfig): Backends {
  const tables = new LocalTablesBackend(config.generatedDataDir);
  const feeds = new LocalFeedsBackend(config.fixturesDir);
  return {
    kind: "local",
    tables,
    feeds,
    describe: () => ({
      tables: "data/generated (Track A generator output)",
      feeds: "committed fixtures shaped like the live upstreams",
    }),
    close: () => Promise.resolve(),
  };
}

export function createCloudBackends(config: DataApiConfig): Backends {
  const cloud = config.cloud;
  if (!cloud) {
    throw new Error("createCloudBackends called without cloud configuration");
  }

  const tokens = new AzureTokenProvider(
    createCredential(cloud.managedIdentityClientId),
  );

  const clients: Record<TableStore, SqlClient> = {
    sql: new MssqlClient(
      {
        store: "sql",
        server: cloud.sqlServer,
        database: cloud.sqlDatabase,
        timeoutMs: cloud.upstreamTimeoutMs,
      },
      tokens,
    ),
    lakehouse: new MssqlClient(
      {
        store: "lakehouse",
        server: cloud.fabricEndpoint,
        database: cloud.fabricDatabase,
        timeoutMs: cloud.upstreamTimeoutMs,
      },
      tokens,
    ),
  };

  const tables = new CloudTablesBackend(clients);
  const feeds = new CloudFeedsBackend({ config: cloud, tokens });

  return {
    kind: "cloud",
    tables,
    feeds,
    // Hostnames and a repo slug only. Subscription and workspace ids are not
    // secrets, but they are also not this endpoint's business to publish.
    describe: () => ({
      sql: `${cloud.sqlServer}/${cloud.sqlDatabase}`,
      lakehouse: `${cloud.fabricEndpoint}/${cloud.fabricDatabase}`,
      github: cloud.githubRepo,
      githubAuth: cloud.githubToken ? "token present" : "MISSING — GitHub feeds fail closed",
      defender: "subscription configured",
      logAnalytics: "workspace configured",
    }),
    close: async () => {
      await Promise.all([clients.sql.close(), clients.lakehouse.close()]);
    },
  };
}

export function createBackends(config: DataApiConfig): Backends {
  return config.backendMode === "cloud"
    ? createCloudBackends(config)
    : createLocalBackends(config);
}
