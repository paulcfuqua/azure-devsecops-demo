/**
 * The cloud backend set — five Azure-backed adapters plus the compliance
 * reader, one managed identity, one factory. A sixth, AWS-backed adapter
 * (`awsLakehouseSql`, behind `query_aws_lakehouse_sql`) is layered on top,
 * additively, when `deps.aws` is supplied — see the field below.
 *
 * This is the whole of "tenant activation is configuration, not development":
 * `MLS_TOOL_BACKENDS=cloud` plus the six environment variables `loadCloudConfig`
 * validates (the AWS link's seven are separate and orthogonal — see `deps.aws`),
 * and five of the six tools answer from Fabric, Azure Monitor, GitHub,
 * Defender and Cost Management instead of from CSVs and fixtures. Nothing above
 * this file changes — same tool names, same JSON Schemas, same response shapes.
 * `query_compliance` is the sixth: it has no tenant to switch to, so it reads
 * the same bundled state artifact here as it does locally (see compliance.ts).
 *
 * ONE `TokenProvider` IS SHARED BY ALL *AZURE* ADAPTERS. That is deliberate:
 * `DefaultAzureCredential` is not free to construct or call, tokens are per
 * *scope* and live ~24h, and six tools answering one agent turn must not become
 * six token acquisitions.
 *
 * THE AWS ADAPTER GETS ITS OWN, AND THAT IS NOT AN OVERSIGHT — IT IS THE POINT.
 * A shared provider would have been right if the only difference were the scope,
 * and that is what an earlier draft assumed. It is not: the difference is the
 * IDENTITY. The container app carries two user-assigned managed identities, and
 * `config.cloud.azureClientId` (the container's `AZURE_CLIENT_ID`) selects the
 * mcp-tools one. The AWS IAM trust policy's `sub` condition is pinned to the
 * OTHER identity's principal id, so a token minted from the shared credential
 * carries a `sub` AWS does not recognise and `AssumeRoleWithWebIdentity` returns
 * `AccessDenied` — a message that points at the trust policy while the fault is
 * an Azure credential-selection one, in a different cloud. One credential per
 * identity, named explicitly, is what makes that failure impossible rather than
 * merely unlikely. `aws.clientId` is required at boot for the same reason.
 *
 * `credential` and `executor` are injectable for tests. There is no code path
 * here that reaches the network without one of them being supplied or
 * `DefaultAzureCredential` being constructed, which is what lets the unit tests
 * exercise every adapter with zero live calls.
 */
import type { AwsLakehouseConfig, CloudConfig } from "../../config.js";
import { createDefaultCredential, TokenProvider, type TokenCredentialLike } from "../auth.js";
import type { Backends } from "../backends.js";
import { ComplianceStateBackend } from "../compliance.js";
import type { FetchLike, RetryPolicy } from "../http.js";
import { AthenaLakehouseSqlBackend, type AthenaExecutor } from "./athena-sql.js";
import { AzureCostSeriesBackend } from "./cost-series.js";
import { AzureDefenderPostureBackend } from "./defender-posture.js";
import { FabricLakehouseSqlBackend, type TdsExecutor } from "./fabric-sql.js";
import { LiveGithubSecurityBackend } from "./github-security.js";
import { AzureLogAnalyticsBackend } from "./log-analytics.js";

/**
 * How a credential is built from an environment. Production is
 * `createDefaultCredential`; a test substitutes its own so it can assert WHICH
 * identity each credential was asked for — the thing that actually decides
 * whether the AWS exchange succeeds, and the thing no assertion about a
 * constructed backend can see.
 */
export type CredentialFactory = (env: NodeJS.ProcessEnv) => Promise<TokenCredentialLike>;

export interface CloudBackendDeps {
  /** Test seam. Production passes nothing and gets DefaultAzureCredential. */
  credential?: TokenCredentialLike;
  /**
   * Test seam for credential CONSTRUCTION, as distinct from `credential` above,
   * which substitutes the constructed result. Only this one can observe the env
   * each credential is built from, which is where the AWS identity is selected.
   */
  credentialFactory?: CredentialFactory;
  /** Test seam for the four HTTP adapters. */
  fetchImpl?: FetchLike;
  /** Test seam for the TDS adapter. */
  executor?: TdsExecutor;
  retry?: Partial<RetryPolicy>;
  sleep?: (ms: number) => Promise<void>;
  /**
   * `query_aws_lakehouse_sql`'s settings (`config.aws`). Present only when all
   * seven AWS/Glue/Athena env vars validated at boot — see `loadAwsConfig` in
   * config.ts. When present, `awsLakehouseSql` is added to the returned
   * `Backends`; when absent, the field is left undefined, exactly as
   * `createLocalBackends()` leaves it.
   */
  aws?: AwsLakehouseConfig;
  /** Test seam for the Athena adapter, mirroring `executor` for the TDS one. */
  awsExecutor?: AthenaExecutor;
}

export async function createCloudBackends(
  config: CloudConfig,
  deps: CloudBackendDeps = {},
): Promise<Backends> {
  const makeCredential: CredentialFactory = deps.credentialFactory ?? createDefaultCredential;

  const credential =
    deps.credential ??
    (await makeCredential({
      ...(config.azureClientId ? { AZURE_CLIENT_ID: config.azureClientId } : {}),
    } as NodeJS.ProcessEnv));
  const tokens = new TokenProvider(credential);

  // A SECOND credential, bound to a DIFFERENT managed identity — see the header.
  // `deps.credential` is deliberately NOT a fallback here: a test that injects one
  // fake Azure credential must not silently make this path share it, because then
  // the test would pass on exactly the bug this exists to prevent (the two
  // credentials being the same one). Tests that need to substitute it use
  // `credentialFactory`, which is also the only seam that can see the client id
  // being asked for.
  const awsTokens = deps.aws
    ? new TokenProvider(
        await makeCredential({ AZURE_CLIENT_ID: deps.aws.clientId } as NodeJS.ProcessEnv),
      )
    : undefined;

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
    // ADDITIVE, not a replacement for `lakehouseSql` above: a seventh tool,
    // only when the AWS link is configured. It takes `awsTokens`, NOT the
    // `tokens` the five Azure adapters share — a different managed identity,
    // because the AWS trust policy's `sub` is pinned to it. See the header.
    ...(deps.aws && awsTokens
      ? {
          awsLakehouseSql: new AthenaLakehouseSqlBackend({
            roleArn: deps.aws.roleArn,
            audience: deps.aws.audience,
            region: deps.aws.region,
            database: deps.aws.database,
            workgroup: deps.aws.workgroup,
            outputLocation: deps.aws.outputLocation,
            tokens: awsTokens,
            // Carried for the diagnostic only: an STS AccessDenied names neither
            // the identity nor the audience it rejected, so the adapter says which
            // it used rather than leaving a reader to compare three systems.
            identityClientId: deps.aws.clientId,
            ...(deps.awsExecutor ? { executor: deps.awsExecutor } : {}),
          }),
        }
      : {}),
  };
}
