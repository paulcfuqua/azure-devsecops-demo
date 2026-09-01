// L7 demo parameters.
//
// Images: GHCR public path ghcr.io/paulcfuqua/azure-devsecops-demo/<app>:<tag>
// ([derived] — free on public repos, anonymous pull, no ACR cost; see README).
// Per-app CI passes the real tag/digest at deploy time via the *_IMAGE
// environment variables; the placeholder default keeps the layer deployable
// before the first app image is published.
using './main.bicep'

// ESTATE IDENTITY. naming.bicep holds the defaults and every name derives from
// these two; estate.env (locally) or the `demo` GitHub environment (in CI) is how
// a deployment overrides them. The literal fallbacks below MUST equal
// naming.bicep's defaultCompanyPrefix / defaultEnv - verification/tests asserts
// exactly that, because a bicepparam cannot import a var from the template it
// targets and an unchecked second copy is how two sources of truth start.
//
// empty(...) ? default : value, NOT readEnvironmentVariable's own default argument:
// that default fires only when the variable is UNSET, and an undefined GitHub
// variable expands to the EMPTY STRING (F26). Without this guard a workflow passing
// an unset vars.MLS_COMPANY_PREFIX would name every resource '-rg-platform'.
param companyPrefix = empty(readEnvironmentVariable('MLS_COMPANY_PREFIX', '')) ? 'mls' : readEnvironmentVariable('MLS_COMPANY_PREFIX', '')
param env = empty(readEnvironmentVariable('MLS_ENV_SEGMENT', '')) ? 'demo' : readEnvironmentVariable('MLS_ENV_SEGMENT', '')

param location = readEnvironmentVariable('AZURE_LOCATION', 'eastus')

param launchOpsImage = readEnvironmentVariable(
  'LAUNCH_OPS_IMAGE',
  'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
)

param controlTowerImage = readEnvironmentVariable(
  'CONTROL_TOWER_IMAGE',
  'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
)

// mcp-tools replaced copilot-svc at the 2026-08-24 Copilot Studio amendment.
// MCP_TOOLS_IMAGE is the new variable name; COPILOT_SVC_IMAGE is honoured as a
// transitional fallback because .github/workflows/layer-07-apps.yml still sets
// it (that workflow is outside this change's write scope — see the L8 report's
// reconciliation list).
param mcpToolsImage = readEnvironmentVariable(
  'MCP_TOOLS_IMAGE',
  readEnvironmentVariable('COPILOT_SVC_IMAGE', 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest')
)

// data-api (Phase Q gap Q-4): the serving layer both frontends' ApiProvider
// fetches through their /api same-origin proxy. Provisioned here so
// DATA_API_ORIGIN has something real to point at.
param dataApiImage = readEnvironmentVariable(
  'DATA_API_IMAGE',
  'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
)

// compliance (Task 13/15) — the estate's own NIST compliance board, gated by
// Easy Auth (see main.bicep's compliance app block for the full rationale).
param complianceImage = readEnvironmentVariable(
  'COMPLIANCE_IMAGE',
  'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
)

// Ports: 80 matches the placeholder hello-world image. The real apps listen on
// 8080; CI overrides these once the GHCR images are in play (open item P-1).
param launchOpsTargetPort = int(readEnvironmentVariable('LAUNCH_OPS_PORT', '80'))
param controlTowerTargetPort = int(readEnvironmentVariable('CONTROL_TOWER_PORT', '80'))
param mcpToolsTargetPort = int(
  readEnvironmentVariable('MCP_TOOLS_PORT', readEnvironmentVariable('COPILOT_SVC_PORT', '80'))
)
param dataApiTargetPort = int(readEnvironmentVariable('DATA_API_PORT', '80'))
param complianceTargetPort = int(readEnvironmentVariable('COMPLIANCE_PORT', '80'))

// Image content digests, resolved by layer-07-apps.yml from the registry (or
// read back from the running app) and stamped onto each container as
// MLS_IMAGE_DIGEST. 'unset' is honest: V7.1 then FAILs saying the health payload
// does not carry the deployed digest, instead of passing on liveness alone.
param launchOpsImageDigest = readEnvironmentVariable('LAUNCH_OPS_IMAGE_DIGEST', 'unset')
param controlTowerImageDigest = readEnvironmentVariable('CONTROL_TOWER_IMAGE_DIGEST', 'unset')
param mcpToolsImageDigest = readEnvironmentVariable('MCP_TOOLS_IMAGE_DIGEST', 'unset')
param dataApiImageDigest = readEnvironmentVariable('DATA_API_IMAGE_DIGEST', 'unset')
param complianceImageDigest = readEnvironmentVariable('COMPLIANCE_IMAGE_DIGEST', 'unset')

// Entra application (client) IDs Easy Auth validates sign-ins against, one per
// human-facing app. NOT secrets (see main.bicep's EASY AUTH block) — the same
// non-secret-environment-variable pattern as MLS_GITHUB_REPO / MLS_OWNER.
//
// 'unset' is the sentinel for "no registration yet", but it is NOT the only one
// that matters, and assuming it was is F26: a GitHub Actions `vars.X` expansion
// for an undefined variable produces the EMPTY STRING, which is a variable that
// IS set, so readEnvironmentVariable returns '' and never reaches the default
// below. main.bicep's isEntraClientIdConfigured() therefore treats empty AND
// 'unset' as not-configured, and an app with no client ID deploys INTERNAL
// instead of open (F25). Verified against Bicep CLI 0.46.1: variable unset ->
// "unset"; variable set to the empty string -> "".
param complianceEntraClientId = readEnvironmentVariable('MLS_COMPLIANCE_CLIENT_ID', 'unset')
param launchOpsEntraClientId = readEnvironmentVariable('MLS_LAUNCH_OPS_CLIENT_ID', 'unset')
param controlTowerEntraClientId = readEnvironmentVariable('MLS_CONTROL_TOWER_CLIENT_ID', 'unset')

// data-api backend selection. Empty = decide from whether L5 handed us a Fabric
// SQL analytics endpoint; MLS_DATA_BACKENDS forces it either way.
param dataApiBackendMode = readEnvironmentVariable('MLS_DATA_BACKENDS', '')
param fabricSqlEndpoint = readEnvironmentVariable('MLS_FABRIC_SQL_ENDPOINT', '')
param fabricDatabase = readEnvironmentVariable('MLS_FABRIC_DATABASE', 'mls_operations')
param githubRepository = readEnvironmentVariable('MLS_GITHUB_REPO', '')

// Owner tag. Neutral fallback so a downstream deployment never inherits the
// original author's GitHub handle on every resource group (policy-enforced tag).
param owner = readEnvironmentVariable('MLS_OWNER', 'mls-demo')

// ASSUMPTION (see infra/copilot-studio/README.md): the MCP server serves
// Streamable HTTP at /mcp on the container app's external FQDN. This parameter
// only shapes the mcpToolsEndpoint output; it provisions nothing, so
// reconciling it with apps/mcp-tools/ costs one variable.
param mcpEndpointPath = readEnvironmentVariable('MCP_ENDPOINT_PATH', '/mcp')

// Inbound auth for the public MCP endpoint (F2, infra half — Task 5). There is
// no parameter for it any more: main.bicep resolves mcp-auth-token directly
// from the platform Key Vault via the mcp-tools container app's own
// user-assigned identity (keyVaultUrl + identity, not a value), so the token
// never crosses into this parameter file, the deploy command, ARM deployment
// history or a what-if log, and the layer-07 workflow never reads or exports
// it (hard rule 5). The secret must exist in the vault before this layer
// deploys — see docs/runbooks/g0-bootstrap.md item C11.
//
// The backend set mcp-tools serves IS still a deploy parameter:
param mcpToolsBackendMode = readEnvironmentVariable('MLS_TOOL_BACKENDS', 'local')

// There is no ingress parameter: mcp-tools is external + HTTPS-only by
// requirement, not by configuration (Copilot Studio calls it from outside Azure).

// Scale-to-zero is non-negotiable (minReplicas=0 is hardcoded in main.bicep);
// only the ceiling is tunable, and raising it is a spend-profile change (G2).
param maxReplicas = 2

// GitHub read-only token for data-api's three GitHub feeds (F116).
//
// The NAME of a Key Vault secret, never the token. Container Apps resolves the
// value at runtime with data-api's own managed identity, so nothing here, in
// ARM deployment history, or in a what-if log ever carries it - which matters
// more than usual because this repository is public and what-if output is
// printed into workflow logs GitHub cannot mask.
//
// Empty is a supported deployment and stays the default: the GitHub feeds then
// answer 503 naming what is missing, and Control Tower's Ops tab - which reads
// the lakehouse, not GitHub - is unaffected. Set MLS_GITHUB_TOKEN_SECRET to the
// secret's name (mls-data-api-github-token) once it exists in the vault.
param githubTokenSecretName = readEnvironmentVariable('MLS_GITHUB_TOKEN_SECRET', '')
