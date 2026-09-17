/**
 * WHICH managed identity the AWS token is minted from (Task 9).
 *
 * The container app carries two user-assigned managed identities.
 * `AZURE_CLIENT_ID` binds `DefaultAzureCredential` to the mcp-tools one for every
 * Azure data plane this server reads. The AWS IAM trust policy's `sub` condition
 * is pinned to the OTHER identity's principal id, so a token minted from the
 * shared credential is refused by STS as `AccessDenied` — a message naming the
 * trust policy while the fault is an Azure credential-selection problem, one
 * cloud away from where anyone would look.
 *
 * Nothing about that is visible in a constructed `Backends`: both shapes have an
 * `awsLakehouseSql` of the same class, with the same options, differing only in
 * which credential sits behind its `TokenProvider`. So these tests assert on the
 * credential FACTORY — the only seam that can see the client id being asked for —
 * rather than on the object it produced. An assertion that cannot distinguish the
 * two states would not be evidence (F162).
 *
 * No network, no AWS SDK, no `@azure/identity`: `credentialFactory` replaces
 * construction entirely.
 */
import { describe, expect, it } from "vitest";
import { loadConfig, type AwsLakehouseConfig } from "../src/config.js";
import { createCloudBackends, type CredentialFactory } from "../src/tools/cloud/index.js";

// Allowlisted synthetic placeholders. Nothing here acquires a token, and a live
// identity id in a fixture is F62's class.
const MCP_IDENTITY = "11111111-1111-1111-1111-111111111111";
const AWS_IDENTITY = "22222222-2222-2222-2222-222222222222";

const CLOUD_ENV = {
  MLS_TOOL_BACKENDS: "cloud",
  MLS_FABRIC_SQL_ENDPOINT: "abc123.datawarehouse.fabric.microsoft.com",
  MLS_FABRIC_DATABASE: "mls_operations",
  MLS_LOG_ANALYTICS_WORKSPACE_ID: "11111111-2222-3333-4444-555555555555",
  MLS_GITHUB_REPO: "paulcfuqua/azure-devsecops-demo",
  // Deliberately NOT shaped like a GitHub token. loadCloudConfig only requires a
  // non-empty string here, and a realistic-looking one is a high-entropy literal
  // that gitleaks correctly refuses on a new file - a scanner that has learned to
  // ignore test fixtures is a scanner nobody reads (.gitleaks.toml's own note).
  GITHUB_TOKEN: "unused-by-this-file-the-github-adapter-is-never-called",
  AZURE_SUBSCRIPTION_ID: "00000000-1111-2222-3333-444444444444",
  AZURE_CLIENT_ID: MCP_IDENTITY,
  MCP_AUTH_TOKEN: "test-inbound-token",
};

const AWS_ENV = {
  MLS_AWS_ROLE_ARN: "arn:aws:iam::1:role/r",
  MLS_AWS_AUDIENCE: "api://a",
  MLS_AWS_REGION: "us-east-1",
  MLS_GLUE_DATABASE: "launch",
  MLS_ATHENA_WORKGROUP: "wg",
  MLS_ATHENA_OUTPUT: "s3://r/",
  MLS_AWS_CLIENT_ID: AWS_IDENTITY,
};

/** Records the env each credential was built from, and hands back a distinct fake. */
function recordingFactory() {
  const asked: Array<string | undefined> = [];
  const factory: CredentialFactory = async (env) => {
    asked.push(env.AZURE_CLIENT_ID);
    const mintedFor = env.AZURE_CLIENT_ID;
    return {
      async getToken() {
        return { token: `token-for:${mintedFor}`, expiresOnTimestamp: Date.now() + 3_600_000 };
      },
    };
  };
  return { asked, factory };
}

describe("the AWS adapter's credential names its own identity", () => {
  it("builds TWO credentials, one per identity, when the AWS link is configured", async () => {
    const config = loadConfig({ ...CLOUD_ENV, ...AWS_ENV } as never);
    const { asked, factory } = recordingFactory();

    await createCloudBackends(config.cloud!, {
      credentialFactory: factory,
      aws: config.aws,
    });

    expect(asked).toEqual([MCP_IDENTITY, AWS_IDENTITY]);
  });

  it("builds only the Azure one when there is no AWS link", async () => {
    const config = loadConfig(CLOUD_ENV as never);
    const { asked, factory } = recordingFactory();

    await createCloudBackends(config.cloud!, { credentialFactory: factory });

    expect(asked).toEqual([MCP_IDENTITY]);
    expect(config.aws).toBeUndefined();
  });

  /**
   * The regression that matters. Before Task 9 the AWS backend shared the Azure
   * `TokenProvider`, so its token carried the mcp-tools identity's `sub` and AWS
   * refused it. Asserting the token's VALUE is what distinguishes the two states:
   * both arrangements produce an `AthenaLakehouseSqlBackend` that looks identical
   * from outside.
   */
  it("mints the AWS-bound token from the AWS identity, not the container default", async () => {
    const config = loadConfig({ ...CLOUD_ENV, ...AWS_ENV } as never);
    const { factory } = recordingFactory();

    let tokenPresentedToAws: string | undefined;
    const backends = await createCloudBackends(config.cloud!, {
      credentialFactory: factory,
      aws: config.aws,
      // The executor is normally where the token is exchanged with STS; here it
      // simply records which one reached it, then answers the dialect probe.
      awsExecutor: {
        async run() {
          tokenPresentedToAws = await (
            backends.awsLakehouseSql as unknown as {
              tokens: { getToken(scope: string): Promise<string> };
            }
          ).tokens.getToken(`${(config.aws as AwsLakehouseConfig).audience}/.default`);
          return { columns: ["seed_date_weekday"], rows: [[6]] };
        },
      },
    });

    await backends.awsLakehouseSql!.query("SELECT 1 AS n");

    expect(tokenPresentedToAws).toBe(`token-for:${AWS_IDENTITY}`);
    expect(tokenPresentedToAws).not.toBe(`token-for:${MCP_IDENTITY}`);
  });

  it("leaves the five Azure adapters on the container's own identity", async () => {
    const config = loadConfig({ ...CLOUD_ENV, ...AWS_ENV } as never);
    const { factory } = recordingFactory();

    const backends = await createCloudBackends(config.cloud!, {
      credentialFactory: factory,
      aws: config.aws,
    });

    const fabricTokens = (
      backends.lakehouseSql as unknown as {
        tokens: { getToken(scope: string): Promise<string> };
      }
    ).tokens;
    await expect(fabricTokens.getToken("https://database.windows.net/.default")).resolves.toBe(
      `token-for:${MCP_IDENTITY}`,
    );
  });
});
