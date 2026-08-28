/**
 * The cloud backend set — five Azure-backed adapters plus the compliance
 * reader, one managed identity, one factory.
 *
 * This is the whole of "tenant activation is configuration, not development":
 * `MLS_TOOL_BACKENDS=cloud` plus the six environment variables `loadCloudConfig`
 * validates, and five of the six tools answer from Fabric, Azure Monitor, GitHub,
 * Defender and Cost Management instead of from CSVs and fixtures. Nothing above
 * this file changes — same tool names, same JSON Schemas, same response shapes.
 * `query_compliance` is the sixth: it has no tenant to switch to, so it reads
 * the same bundled state artifact here as it does locally (see compliance.ts).
 *
 * ONE `TokenProvider` IS SHARED BY ALL FOUR TOKEN-AUTHENTICATED AZURE ADAPTERS.
 * That is deliberate: `DefaultAzureCredential` is not free to construct or
 * call, tokens are per *scope* and live ~24h, and five tools answering one
 * agent turn must not become five token acquisitions.
 *
 * `credential` and `executor` are injectable for tests. There is no code path
 * here that reaches the network without one of them being supplied or
 * `DefaultAzureCredential` being constructed, which is what lets the unit tests
 * exercise every adapter with zero live calls.
 */
import type { CloudConfig } from "../../config.js";
import { createDefaultCredential, TokenProvider, type TokenCredentialLike } from "../auth.js";
import type { Backends } from "../backends.js";
import { ComplianceStateBackend } from "../compliance.js";
import type { FetchLike, RetryPolicy } from "../http.js";
import { AzureCostSeriesBackend } from "./cost-series.js";
import { AzureDefenderPostureBackend } from "./defender-posture.js";
import { FabricLakehouseSqlBackend, type TdsExecutor } from "./fabric-sql.js";
import { LiveGithubSecurityBackend } from "./github-security.js";
import { AzureLogAnalyticsBackend } from "./log-analytics.js";

export interface CloudBackendDeps {
  /** Test seam. Production passes nothing and gets DefaultAzureCredential. */
  credential?: TokenCredentialLike;
  /** Test seam for the four HTTP adapters. */
  fetchImpl?: FetchLike;
  /** Test seam for the TDS adapter. */
  executor?: TdsExecutor;
  retry?: Partial<RetryPolicy>;
  sleep?: (ms: number) => Promise<void>;
}

export async function createCloudBackends(
  config: CloudConfig,
  deps: CloudBackendDeps = {},
): Promise<Backends> {
  const credential =
    deps.credential ??
    (await createDefaultCredential({
      ...(config.azureClientId ? { AZURE_CLIENT_ID: config.azureClientId } : {}),
    } as NodeJS.ProcessEnv));
  const tokens = new TokenProvider(credential);

  const shared = {
    ...(deps.fetchImpl ? { fetchImpl: deps.fetchImpl } : {}),
    ...(deps.retry ? { retry: deps.retry } : {}),
    ...(deps.sleep ? { sleep: deps.sleep } : {}),
  };

  return {
    lakehouseSql: new FabricLakehouseSqlBackend({
      sqlEndpoint: config.fabricSqlEndpoint,
      database: config.fabricDatabase,
      tokens,
      ...(deps.executor ? { executor: deps.executor } : {}),
    }),
    logAnalytics: new AzureLogAnalyticsBackend({
      workspaceId: config.logAnalyticsWorkspaceId,
      tokens,
      ...(config.logAnalyticsEndpoint ? { endpoint: config.logAnalyticsEndpoint } : {}),
      ...shared,
    }),
    githubSecurity: new LiveGithubSecurityBackend({
      repo: config.githubRepo,
      token: config.githubToken,
      ...shared,
    }),
    defenderPosture: new AzureDefenderPostureBackend({
      subscriptionId: config.subscriptionId,
      tokens,
      ...(config.armEndpoint ? { armEndpoint: config.armEndpoint } : {}),
      ...shared,
    }),
    costSeries: new AzureCostSeriesBackend({
      scope: config.costScope,
      tokens,
      costCenterTag: config.costCenterTag,
      ...(config.armEndpoint ? { armEndpoint: config.armEndpoint } : {}),
      ...shared,
    }),
    // query_compliance has no cloud/local split — it always reads the same
    // bundled, committed state artifact regardless of MLS_TOOL_BACKENDS.
    compliance: new ComplianceStateBackend(),
  };
}
