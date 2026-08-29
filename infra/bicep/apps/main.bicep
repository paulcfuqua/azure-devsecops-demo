// =============================================================================
// apps/main.bicep — L7: the four container apps, plus the L10 deployment witness.
//
// Deployed at RESOURCE GROUP scope into mls-rg-apps (created at L6):
//
//   az deployment group create \
//     --resource-group mls-rg-apps \
//     --template-file infra/bicep/apps/main.bicep \
//     --parameters infra/bicep/apps/demo.bicepparam
//
// Apps (spec architecture summary, as amended 2026-08-26 — F1/Task 6):
//   data-api       INTERNAL ingress   minReplicas=0   (was external; see below)
//   launch-ops     external ingress   minReplicas=0
//   control-tower  external ingress   minReplicas=0
//   mcp-tools      external ingress   minReplicas=0
//
// Plus one non-serving resource:
//   vuln-lab       INGRESS DISABLED   minReplicas=0   (L10 deployment witness)
//
// minReplicas=0 everywhere: idle cost is $0 by design; a nonzero floor is an
// un-gated spend change and an audit failure (V6.1/V7.5).
//
// ---------------------------------------------------------------------------
// data-api AND DATA_API_ORIGIN (added 2026-08-24, Phase Q gap Q-4 close-out)
//
// This template was authored before apps/data-api existed, so it provisioned
// three apps and neither frontend had anywhere to send /api. Both frontends'
// `ApiProvider` defaults to the same-origin base URL "/api", and both nginx
// images now proxy `location /api/` to `${DATA_API_ORIGIN}` — a variable whose
// image default is a deliberately unreachable loopback address. Without the
// wiring below, every /api call answers 502 and both dashboards render empty.
//
// So two things happen here that did not before:
//   1. the data-api container app is provisioned (with its own user-assigned
//      identity: it reads Azure SQL, the Fabric SQL analytics endpoint, Defender
//      and Log Analytics with no stored credential), and
//   2. DATA_API_ORIGIN is injected into launch-ops and control-tower, pointing
//      at that app's HTTPS FQDN. The dependency is one-directional and Bicep
//      infers it, so data-api provisions first.
//
// It is INTERNAL-ONLY ingress (F1, Task 6 — was EXTERNAL until 2026-08-26).
// data-api shipped with ingressExternal:true and, by its own source comment
// (src/app.ts:56), "deliberately no Authorization here" in front of a managed
// identity that reads Azure SQL, the Fabric lakehouse, Log Analytics, Defender
// secure score and GitHub security alerts. Both frontends already proxy
// `/api/*` server-side through nginx (control-tower and launch-ops
// nginx.conf.template), so the only legitimate callers live inside this
// Container Apps environment — internal ingress is strictly better than a
// shared token here: nothing to distribute, nothing to rotate, nothing that
// can leak from a static bundle. Azure Container Apps still assigns an FQDN to
// an internal-ingress app, resolvable within the environment, which is what
// DATA_API_ORIGIN below points both frontends at. The old rationale for
// external ingress ("it's the browser's data path", "/healthz is the first
// thing anyone checks when a dashboard is blank") does not survive contact
// with the cost math: one unauthenticated request every 59 minutes, from
// anywhere on the internet, holds `GP_S_Gen5` serverless SQL open against its
// 60s autoPauseDelay — about $188/month against a $200 credit, no flood
// required. /healthz is now reached with `az containerapp exec`, not a browser.
// src/config.ts:159's wildcard-CORS refusal message ("This API is reachable
// from the internet...") is now stale prose on an otherwise-still-useful
// guardrail; out of scope here, left for a docs pass.
//
// MLS_IMAGE_DIGEST is injected into every app for L7 V7.1: the criterion binds
// "endpoint is up" to "endpoint serves the audited build" by comparing the
// health payload's content-hash marker with the digest the deploy run recorded.
// The frontends' nginx templates interpolate it into /healthz; data-api reads it
// as its `build` marker (apps/data-api/src/config.ts).
// ---------------------------------------------------------------------------
//
// ---------------------------------------------------------------------------
// COPILOT STUDIO AMENDMENT (2026-08-24) — what changed in this template
//
//  * `copilot-svc` (mls-copilot-demo-ca), the Anthropic tool-use service, is
//    replaced by the **MCP tool server** (mls-mcp-demo-ca). It hosts the same
//    five Ops/Sec/Cost tool implementations over Streamable HTTP; the LLM loop
//    now lives in a Copilot Studio agent (infra/copilot-studio/).
//  * The Key Vault `anthropic-api-key` secret reference and the app's
//    Key Vault Secrets User grant were deleted here. No Anthropic key exists
//    anywhere in the system, so that secret-consuming path was removed rather
//    than repointed (amendment section 3, "Discarded"). A DIFFERENT Key Vault
//    reference and grant were added back at Task 5 (2026-08-26), for an
//    unrelated secret — see "MCP INBOUND AUTH TOKEN" below. Nothing about the
//    Anthropic removal reverses here.
//  * Ingress is **external + HTTPS-only, unconditionally**. Copilot Studio is a
//    SaaS caller outside the Container Apps environment: it must resolve and
//    reach the public FQDN, so the old `copilotExternalIngress` toggle is not a
//    choice any more and has been removed rather than defaulted to true.
//  * The **user-assigned identity survives** (renamed mls-mcp-demo-id) and is
//    justified below.
// ---------------------------------------------------------------------------
//
// ---------------------------------------------------------------------------
// MCP INBOUND AUTH TOKEN (Task 5, 2026-08-26 — closes finding F2's infra half)
//
// F2 (compliance/findings/2026-08-26-prepublication-review.md#f2): Task 4 made
// apps/mcp-tools fail closed at boot without MCP_AUTH_TOKEN, but nothing ever
// supplied one. The prior secret param was marked secure, defaulting to empty,
// but crossed a module boundary into the AVM container-app module's nested
// deployment, whose own `secrets` parameter is a plain `array` — not secure.
// That risked the token landing in ARM deployment history, readable
// by anything holding Reader on the resource group (mls-verifier holds
// exactly that), and `az deployment group what-if` renders parameter values
// into the workflow log of what is a PUBLIC repository, where GitHub cannot
// mask it because it was never a GitHub secret.
//
// The fix does not route the token through this template at all. mcpToolsApp's
// secret uses `keyVaultUrl` + `identity` instead of `value`: Container Apps
// resolves it directly from the platform Key Vault at runtime using the
// mcp-tools UAMI, which this template grants `Key Vault Secrets User` on that
// vault (mcpKvGrant, below — modules/key-vault-secrets-user-role.bicep,
// repurposed from the deleted copilot-svc/ANTHROPIC_API_KEY path; see that
// file's header). The token therefore never appears in this template,
// demo.bicepparam, ARM deployment history, a what-if diff, or CI — and the
// deployer needs no Key Vault data-plane role to make the grant, only
// Contributor at the scope the role assignment is written to.
//
// The secret named `mcp-auth-token` must exist in the vault BEFORE this layer
// deploys (docs/runbooks/g0-bootstrap.md item C11); this template does not
// create it — writing a secret VALUE is exactly the kind of thing hard rule 5
// keeps out of IaC and CI.
//
// MLS_TOOL_BACKENDS is now set explicitly via the `mcpToolsBackendMode`
// parameter (default 'local') rather than being absent from every workflow,
// which was F2's other half: the enforcement gate itself no longer keys off
// backendMode (Task 4), but an unset MLS_TOOL_BACKENDS was still an omission,
// not a decision.
// ---------------------------------------------------------------------------
//
// [derived] Registry: GitHub Container Registry (GHCR) public path
// ghcr.io/paulcfuqua/azure-devsecops-demo/<app>:<tag> — free on public repos,
// anonymous pull, no ACR resource and no registry credentials to manage
// (see infra/bicep/README.md). Image references are parameters; the
// placeholder default is Microsoft's public hello-world image so the layer is
// deployable before the first app CI run.
//
// Platform resource IDs are DERIVED from naming.bicep (deterministic names),
// not passed as parameters — naming is the single source of truth, so the apps
// layer can locate the L6 environment and App Insights by name.
//
// [derived] WHY THE USER-ASSIGNED IDENTITY STAYS
// (decision, 2026-08-24; grant reinstated 2026-08-26, Task 5)
//
// The 2026-08-24 rationale for it — "the Key Vault role grant must exist before
// the app provisions, because the app resolves a secret reference at creation
// time" — went void when the anthropic-api-key secret was deleted. Task 5
// restored an equivalent dependency for a DIFFERENT secret, mcp-auth-token
// (F2's infra half — see "MCP INBOUND AUTH TOKEN" above), so the identity's
// justification no longer rests on that grant alone; it holds independently on
// three grounds:
//
//   1. The MCP tool server is the ONLY app in the estate that calls Azure data
//      planes on its own behalf — the lakehouse SQL analytics endpoint, the
//      Entra-only Azure SQL database (azureADOnlyAuthentication: true, so no
//      password exists to fall back on), Cost Management and Defender read APIs.
//      Something has to authenticate, and CLAUDE.md hard rule 5 forbids a stored
//      credential. A managed identity is therefore mandatory, not decorative.
//   2. User-assigned rather than system-assigned because the grants those tools
//      need are made by OTHER layers' scripts (a SQL contained-database user via
//      CREATE USER ... FROM EXTERNAL PROVIDER, a Fabric workspace role
//      assignment, Cost Management Reader) as well as this template's own
//      Key Vault Secrets User grant below. A user-assigned identity has a
//      deterministic name from naming.bicep and a principalId that is an output
//      of this template, so those grants can be made before or after the app
//      exists. A system-assigned identity only exists once the app does, which
//      re-imposes an ordering dependency on every future grant.
//   3. Its clientId is injected as AZURE_CLIENT_ID so the container's
//      DefaultAzureCredential binds to this identity and not to an ambient one.
//
// The 'Key Vault Secrets User' grant IS back (mcpKvGrant, below), scoped to
// this identity's principalId on the platform vault. It was deleted with
// anthropic-api-key at the 2026-08-24 amendment and reinstated at Task 5 for
// mcp-auth-token — a different secret, the same module
// (modules/key-vault-secrets-user-role.bicep), now referenced again; see that
// file's header for the corrected rationale.
// =============================================================================
targetScope = 'resourceGroup'

import * as naming from '../naming.bicep'

// ------------------------------------------------------------------ parameters

@description('Company prefix. Single source: naming.bicep.')
param companyPrefix string = naming.defaultCompanyPrefix

@description('Environment segment for names and the env tag.')
param env string = naming.defaultEnv

@description('Region for the apps; defaults to the resource group location.')
param location string = resourceGroup().location

@description('costCenter tag value.')
param costCenter string = naming.defaultCostCenter

@description('owner tag value.')
param owner string = naming.defaultOwner

@description('dataClassification tag value for app resources.')
param dataClassification string = naming.defaultDataClassification

@description('launch-ops container image (GHCR public path at deploy time).')
param launchOpsImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('control-tower container image (GHCR public path at deploy time).')
param controlTowerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('mcp-tools container image (GHCR public path at deploy time).')
param mcpToolsImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('data-api container image (GHCR public path at deploy time).')
param dataApiImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Container port each app listens on. 80 matches the hello-world placeholder; the real apps override via parameters.')
param launchOpsTargetPort int = 80
param controlTowerTargetPort int = 80
param mcpToolsTargetPort int = 80
param dataApiTargetPort int = 80

@description('Image content digest per app, stamped onto the running container as MLS_IMAGE_DIGEST so L7 V7.1 can bind the live endpoint to the audited build. "unset" is the honest placeholder: V7.1 then reports that the health payload does not carry the deployed digest rather than passing on liveness alone.')
param launchOpsImageDigest string = 'unset'
param controlTowerImageDigest string = 'unset'
param mcpToolsImageDigest string = 'unset'
param dataApiImageDigest string = 'unset'

@description('Backend set data-api serves. Empty resolves to "cloud" when a Fabric SQL analytics endpoint is supplied and "local" otherwise — local mode reads data/generated, which is NOT baked into the image, so it answers 503 on every table route and exists only as a test harness.')
@allowed(['', 'local', 'cloud'])
param dataApiBackendMode string = ''

@description('Fabric lakehouse SQL analytics endpoint FQDN (the L5 lakehouse metadata\'s sqlEndpointProperties.connectionString). Not derivable from ARM: Fabric is not an ARM resource here, so this arrives from the L5 outputs at deploy time.')
param fabricSqlEndpoint string = ''

@description('Lakehouse name exposed as a database on that endpoint.')
param fabricDatabase string = 'mls_operations'

@description('Backend set mcp-tools serves. Defaults to "local" so the mode is always an explicit deployment decision rather than an omission — the other half of F2 was that MLS_TOOL_BACKENDS was never set anywhere in infra/ or .github/, so the configuration the enforcement gate\'s own doc comments described was never the one actually shipped.')
@allowed(['local', 'cloud'])
param mcpToolsBackendMode string = 'local'

@description('owner/repo the data-api Dev/Sec feeds read through the GitHub API. No default on purpose: a public reference repo must not ship the upstream repo as a fallback. Supplied via MLS_GITHUB_REPO in demo.bicepparam; empty is valid and simply leaves the GitHub feeds unconfigured, which data-api reports at boot in cloud mode.')
param githubRepository string = ''

@description('[derived] Timespan for data-api\'s app-requests Log Analytics query, ISO-8601.')
param logAnalyticsTimespan string = 'P14D'

@description('[derived] HTTP path the MCP Streamable HTTP endpoint is served on. ASSUMPTION pending reconciliation with apps/mcp-tools/ — see infra/copilot-studio/README.md. Used only to compose the mcpToolsEndpoint output that the Copilot Studio connector consumes; changing it deploys nothing.')
param mcpEndpointPath string = '/mcp'

@description('L10 deployment witness image. A pinned PUBLIC placeholder on purpose: apps/vuln-lab is never containerised (see the vuln-lab block below), so this image contains none of the lab\'s code and none of its deliberately vulnerable dependencies.')
param vulnLabWitnessImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Commit the L10 witness revision attests to. "unset" until a heal merges; .github/workflows/vuln-lab-witness.yml re-stamps it on every push to main that touches apps/vuln-lab/**, which is what creates the revision V10.1 stage 6 / V10.2 stage 5 look for.')
param vulnLabHealCommit string = 'unset'

@description('compliance container image (GHCR public path at deploy time). Task 13/15.')
param complianceImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Container port the compliance app listens on. 80 matches the hello-world placeholder; app-compliance-ci.yml overrides via COMPLIANCE_PORT once the real image is published (open item P-1\'s pattern).')
param complianceTargetPort int = 80

@description('Image content digest for the compliance app, stamped as MLS_IMAGE_DIGEST so V7.1-style build binding is possible even though this app is deliberately outside V7.1\'s own -AppName sweep (see the compliance app block below). "unset" is the honest placeholder.')
param complianceImageDigest string = 'unset'

@description('Entra application (client) ID Easy Auth validates compliance-app sign-ins against. NOT a secret — an OAuth client ID is a public identifier (CLAUDE.md hard rule 5 treats tenant/subscription IDs the same way), and no client secret is ever configured for this provider (see the compliance app block below for why one is not needed). The Entra app registration itself is the Identity workstream\'s to create (L2-L4), not this template\'s. "unset" (and the empty string a GitHub vars.* expansion produces for an undefined variable) means NOT CONFIGURED, and the app then deploys with INTERNAL ingress and no authConfig rather than externally without one — see the EASY AUTH block below (F25/F26).')
param complianceEntraClientId string = 'unset'

@description('Entra application (client) ID Easy Auth validates launch-ops sign-ins against (F25). Same trust class and same not-configured semantics as complianceEntraClientId above: NOT a secret, and "unset"/empty makes launch-ops deploy INTERNAL rather than open to the internet. The registration is mls-launch-ops-demo-app in infra/entra/manifest.json, created at L3.')
param launchOpsEntraClientId string = 'unset'

@description('Entra application (client) ID Easy Auth validates control-tower sign-ins against (F25). Same trust class and same not-configured semantics as complianceEntraClientId above: NOT a secret, and "unset"/empty makes control-tower deploy INTERNAL rather than open to the internet. The registration is mls-control-tower-demo-app in infra/entra/manifest.json, created at L3.')
param controlTowerEntraClientId string = 'unset'

@description('[derived] Replica ceiling — enough for a demo burst, small enough to cap active spend.')
param maxReplicas int = 2

@description('[derived] Smallest consumption CPU slice; demo workloads are tiny.')
param containerCpu string = '0.25'

@description('[derived] Memory paired with 0.25 vCPU on the consumption plan.')
param containerMemory string = '0.5Gi'

// ------------------------------------------------------------------ derived platform references

var platformRgName = naming.resourceGroupName(companyPrefix, naming.rgPurposes.platform)
var caeName = naming.containerAppsEnvironmentName(companyPrefix, env)
var appiName = naming.appInsightsName(companyPrefix, env)
var kvName = naming.keyVaultName(companyPrefix, env)

var caeResourceId = resourceId(
  subscription().subscriptionId,
  platformRgName,
  'Microsoft.App/managedEnvironments',
  caeName
)

// Platform Key Vault from L6. The anthropic-api-key secret reference and its
// consuming plumbing were deleted with the Anthropic decision (2026-08-24);
// this reference returned at Task 5 (2026-08-26) for a different secret,
// mcp-auth-token — see the "MCP INBOUND AUTH TOKEN" header block above.
resource platformKv 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  scope: az.resourceGroup(platformRgName)
  name: kvName
}

// Workspace-based App Insights from L6 — connection string is injected into
// every app so OTel spans land in the shared LAW (V7.3).
resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  scope: az.resourceGroup(platformRgName)
  name: appiName
}

// L6 resources data-api reads in cloud mode. Referenced as `existing` rather
// than passed as parameters for the same reason the ACA environment is derived:
// naming.bicep is the single source of truth, so this layer can find L6's estate
// by name. The Log Analytics CUSTOMER id (a GUID) is what the query API takes —
// apps/data-api/src/config.ts rejects an ARM resource id outright.
var lawName = naming.logAnalyticsWorkspaceName(companyPrefix, env)
var sqlServerResourceName = naming.sqlServerName(companyPrefix, env)
var dataRgName = naming.resourceGroupName(companyPrefix, naming.rgPurposes.data)

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  scope: az.resourceGroup(platformRgName)
  name: lawName
}

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' existing = {
  scope: az.resourceGroup(dataRgName)
  name: sqlServerResourceName
}

// ------------------------------------------------------------------ names + tags

var launchOpsName = naming.containerAppName(companyPrefix, naming.appKeys.launchOps, env)
var controlTowerName = naming.containerAppName(companyPrefix, naming.appKeys.controlTower, env)
var mcpToolsName = naming.containerAppName(companyPrefix, naming.appKeys.mcpTools, env)
var dataApiName = naming.containerAppName(companyPrefix, naming.appKeys.dataApi, env)
var vulnLabName = naming.containerAppName(companyPrefix, naming.appKeys.vulnLab, env)
var complianceName = naming.containerAppName(companyPrefix, naming.appKeys.compliance, env)
var mcpToolsIdentityName = naming.userAssignedIdentityName(companyPrefix, naming.appKeys.mcpTools, env)
var dataApiIdentityName = naming.userAssignedIdentityName(companyPrefix, naming.appKeys.dataApi, env)

var tagsLaunchOps = naming.requiredTags(env, naming.appKeys.launchOps, costCenter, owner, dataClassification)
var tagsControlTower = naming.requiredTags(env, naming.appKeys.controlTower, costCenter, owner, dataClassification)
var tagsMcpTools = naming.requiredTags(env, naming.appKeys.mcpTools, costCenter, owner, dataClassification)
var tagsDataApi = naming.requiredTags(env, naming.appKeys.dataApi, costCenter, owner, dataClassification)
var tagsVulnLab = naming.requiredTags(env, naming.appKeys.vulnLab, costCenter, owner, dataClassification)
var tagsCompliance = naming.requiredTags(env, naming.appKeys.compliance, costCenter, owner, dataClassification)

// Empty means "decide from what L5 handed us": cloud when there is a Fabric SQL
// analytics endpoint to read the three analytical tables from, local otherwise.
// Never silently cloud without the endpoint — apps/data-api/src/config.ts fails
// at BOOT naming the missing variable, which crash-loops the revision instead of
// 502-ing one route, and that is the correct behaviour to preserve.
var dataApiMode = empty(dataApiBackendMode) ? (empty(fabricSqlEndpoint) ? 'local' : 'cloud') : dataApiBackendMode

// Cloud-mode settings, all of them configuration and none of them secret. The
// one credential-shaped input data-api accepts (MLS_GITHUB_TOKEN, a Key Vault
// secret reference) is deliberately NOT set here: without it the three GitHub
// feeds fail closed with a typed error and /healthz says so, which is a better
// default than a half-wired secret path (apps/data-api/README.md).
var dataApiCloudEnv = dataApiMode != 'cloud'
  ? []
  : [
      { name: 'MLS_SQL_SERVER', value: sqlServer.properties.fullyQualifiedDomainName }
      { name: 'MLS_SQL_DATABASE', value: naming.sqlDatabaseName(companyPrefix, naming.appKeys.launchOps, env) }
      { name: 'MLS_FABRIC_SQL_ENDPOINT', value: fabricSqlEndpoint }
      { name: 'MLS_FABRIC_DATABASE', value: fabricDatabase }
      { name: 'MLS_GITHUB_REPO', value: githubRepository }
      { name: 'MLS_DEFENDER_SUBSCRIPTION_ID', value: subscription().subscriptionId }
      { name: 'MLS_LOG_ANALYTICS_WORKSPACE_ID', value: logAnalytics.properties.customerId }
      { name: 'MLS_LOG_ANALYTICS_TIMESPAN', value: logAnalyticsTimespan }
      { name: 'MLS_MANAGED_IDENTITY_CLIENT_ID', value: dataApiIdentity.outputs.clientId }
    ]

// Scale-to-zero settings shared by all three apps.
var scaleToZero = {
  minReplicas: 0
  maxReplicas: maxReplicas
}

// ------------------------------------------------------------------ mcp-tools workload identity

// User-assigned (not system-assigned) — see the header block for the full
// justification. Summary: the tools authenticate to Entra-only SQL, the Fabric
// SQL analytics endpoint and Cost Management with no stored credential, and the
// grants that make that work are issued by other layers against a deterministic
// principal that must be nameable before the app exists.
module mcpToolsIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'l7-mcp-uami'
  params: {
    name: mcpToolsIdentityName
    location: location
    tags: tagsMcpTools
  }
}

// Grants this identity 'Key Vault Secrets User' on the platform vault so the
// container app can resolve mcp-auth-token via keyVaultUrl at runtime — see
// the "MCP INBOUND AUTH TOKEN" header block (Task 5, F2 infra half). Scoped to
// mls-rg-platform, not mls-rg-apps, because that is where the vault lives.
module mcpKvGrant 'modules/key-vault-secrets-user-role.bicep' = {
  name: 'l7-mcp-kv-grant'
  scope: az.resourceGroup(platformRgName)
  params: {
    keyVaultName: platformKv.name
    principalId: mcpToolsIdentity.outputs.principalId
  }
}

// Grants this identity 'Monitoring Metrics Publisher' on the platform App
// Insights component (F4, Task 8 — see platform/main.bicep's appInsights
// module header and modules/monitoring-metrics-publisher-role.bicep). Without
// this, disableLocalAuth:true on that component leaves mcp-tools with no way
// to authenticate telemetry ingestion at all. Scoped to mls-rg-platform,
// where the component lives.
module mcpAppInsightsGrant 'modules/monitoring-metrics-publisher-role.bicep' = {
  name: 'l7-mcp-appi-grant'
  scope: az.resourceGroup(platformRgName)
  params: {
    appInsightsName: appiName
    principalId: mcpToolsIdentity.outputs.principalId
  }
}

// F13 (compliance/findings/2026-08-26-prepublication-review.md#f13,
// Task 12): grants 'Log Analytics Reader' on the platform LAW — mcp-tools
// reads it via tools/cloud/log-analytics.ts:14. Scoped to the workspace
// resource, not the resource group or subscription.
module mcpLawReaderGrant 'modules/log-analytics-reader-role.bicep' = {
  name: 'l7-mcp-law-reader-grant'
  scope: az.resourceGroup(platformRgName)
  params: {
    logAnalyticsWorkspaceName: lawName
    principalId: mcpToolsIdentity.outputs.principalId
  }
}

// F13, Task 12: grants 'Security Reader' at SUBSCRIPTION scope — Defender for
// Cloud posture (tools/cloud/defender-posture.ts:18) is a subscription-wide
// construct with no narrower resource to bind to. See
// modules/workload-role-assignments.bicep's header for why this is a separate
// subscription-scope module rather than a parameter on the resource-scoped
// grants above.
module mcpSecurityReaderGrant 'modules/workload-role-assignments.bicep' = {
  name: 'l7-mcp-security-reader-grant'
  scope: subscription()
  params: {
    principalId: mcpToolsIdentity.outputs.principalId
    // 'Security Reader' — read Defender for Cloud recommendations, alerts and secure score; no write access (built-in role, stable GUID; verified against learn.microsoft.com/azure/role-based-access-control/built-in-roles/security).
    roleDefinitionId: '39bc4728-0917-49c7-9d2c-d95423bc2eb4'
  }
}

// F13, Task 12: grants 'Cost Management Reader' at SUBSCRIPTION scope —
// mcp-tools reads subscription cost data (tools/auth.ts:92), which has no
// narrower resource to scope to.
module mcpCostManagementReaderGrant 'modules/workload-role-assignments.bicep' = {
  name: 'l7-mcp-cost-mgmt-reader-grant'
  scope: subscription()
  params: {
    principalId: mcpToolsIdentity.outputs.principalId
    // 'Cost Management Reader' — view cost data and configuration (exports, budgets); no write access (built-in role, stable GUID; verified against learn.microsoft.com/azure/role-based-access-control/built-in-roles/management-and-governance).
    roleDefinitionId: '72fafb9e-0641-4937-9268-a91bfd8191a3'
  }
}

// ------------------------------------------------------------------ data-api workload identity

// Same reasoning as mcp-tools, for the same reason: data-api is the browser's
// data path and reads Entra-only Azure SQL (no password exists to fall back on),
// the Fabric SQL analytics endpoint, Defender for Cloud and the Log Analytics
// query API. User-assigned so the SQL contained-database user and the Fabric
// workspace role assignment can be granted against a deterministic principal
// before or after the app exists.
module dataApiIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'l7-data-api-uami'
  params: {
    name: dataApiIdentityName
    location: location
    tags: tagsDataApi
  }
}

// Same reason as mcpAppInsightsGrant above: F4 (Task 8) disables local
// (key-based) App Insights ingestion, so data-api's identity needs
// 'Monitoring Metrics Publisher' to authenticate telemetry via Microsoft
// Entra ID instead.
module dataApiAppInsightsGrant 'modules/monitoring-metrics-publisher-role.bicep' = {
  name: 'l7-data-api-appi-grant'
  scope: az.resourceGroup(platformRgName)
  params: {
    appInsightsName: appiName
    principalId: dataApiIdentity.outputs.principalId
  }
}

// F13, Task 12: grants 'Log Analytics Reader' on the platform LAW — data-api
// reads it via MLS_LOG_ANALYTICS_WORKSPACE_ID (dataApiCloudEnv above).
module dataApiLawReaderGrant 'modules/log-analytics-reader-role.bicep' = {
  name: 'l7-data-api-law-reader-grant'
  scope: az.resourceGroup(platformRgName)
  params: {
    logAnalyticsWorkspaceName: lawName
    principalId: dataApiIdentity.outputs.principalId
  }
}

// F13, Task 12: grants 'Security Reader' at SUBSCRIPTION scope — data-api
// reads Defender for Cloud's secure score via MLS_DEFENDER_SUBSCRIPTION_ID
// (dataApiCloudEnv above). Same role, same scope and same reasoning as
// mcpSecurityReaderGrant above; a separate module invocation because each
// Microsoft.Authorization/roleAssignments name is derived per-principal
// (guid(subscription().id, principalId, roleDefinitionId)).
module dataApiSecurityReaderGrant 'modules/workload-role-assignments.bicep' = {
  name: 'l7-data-api-security-reader-grant'
  scope: subscription()
  params: {
    principalId: dataApiIdentity.outputs.principalId
    // 'Security Reader' — read Defender for Cloud recommendations, alerts and secure score; no write access (built-in role, stable GUID; verified against learn.microsoft.com/azure/role-based-access-control/built-in-roles/security).
    roleDefinitionId: '39bc4728-0917-49c7-9d2c-d95423bc2eb4'
  }
}

// ---------------------------------------------------------------------------
// F13 STATUS SUMMARY (compliance/findings/2026-08-26-prepublication-review.md
// #f13, Task 12) — **F13 IS CLOSED as of 2026-08-28.** All seven documented
// workload grants are now expressed in code. Five are in this template; the
// other two are not, for reasons of scope rather than omission, and are listed
// below with where they actually live. Five expressed here:
//
//   * data-api  -> SQL contained-database user   -- data/seed/sql/900-contained-users.sql
//   * data-api  -> Fabric workspace Viewer        -- infra/fabric/provision-workspace.ps1 (-DataApiPrincipalId)
//   * data-api  -> Log Analytics Reader           -- dataApiLawReaderGrant, above
//   * data-api  -> Security Reader                -- dataApiSecurityReaderGrant, above
//   * mcp-tools -> Log Analytics Reader           -- mcpLawReaderGrant, above
//   * mcp-tools -> Security Reader                -- mcpSecurityReaderGrant, above
//   * mcp-tools -> Cost Management Reader         -- mcpCostManagementReaderGrant, above
//
// NOT expressed here — expressed elsewhere, which is a different thing from
// not expressed at all:
//   * Cost Management service -> Storage Blob Data Contributor: owned by
//     Task 17 (F15) — the export's identity is created in
//     .github/workflows/layer-06-platform.yml, not by Bicep, so there is no
//     principalId available to this template to grant.
//   * cost-ingest -> Storage Blob Data Reader: LANDED at L6 (F19, 2026-08-28).
//     This comment used to say "blocked on F19 — cost-ingest has no Function
//     App, and therefore no identity, anywhere in this repo's IaC", and that
//     was true: infra-up.yml:31 claimed a deploy that did not exist. F19 built
//     it. infra/bicep/platform/main.bicep now provisions the Function App on a
//     Flex Consumption plan with its own user-assigned identity and grants that
//     identity Storage Blob Data Reader scoped to the cost-exports CONTAINER
//     (platform/modules/blob-container-role.bicep). It is not in this template
//     because the principal is an L6 resource that lives in mls-rg-ops next to
//     the storage it reads — not because nothing grants it.
//
// Recorded here, fixed elsewhere (different principal, different failure mode
// — see each finding); both are now CLOSED and neither is expressed in this
// template:
//   * F20 — the SQL grant above was expressed but nothing re-ran
//     data/seed/seed.ps1 -Target sql after L7 created the identity, so it
//     never applied in a single infra-up.yml pass. CLOSED by Task 22:
//     .github/workflows/layer-07-apps.yml now runs `seed.ps1 -Target sql
//     -SchemaOnly` after the apps deploy.
//   * F21 — mls-verifier's documented Fabric workspace Viewer grant did not
//     exist either, breaking the L5 Verifier audit. CLOSED by Task 21:
//     infra/fabric/provision-workspace.ps1 grants it via
//     -VerifierPrincipalId. Unrelated to this layer's workload identities.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// EASY AUTH — the three human-facing apps (F25, and F26's enforcement half)
//
// F25 (compliance/findings/2026-08-26-prepublication-review.md#f25). F1 made
// data-api INTERNAL and its own Fix text said "both frontends already proxy
// /api/ server-side" as though that closed the hole. It did not: both frontend
// nginx templates blind-proxy `location /api/ { proxy_pass ${DATA_API_ORIGIN}/; }`
// (apps/control-tower/nginx.conf.template, apps/launch-ops/nginx.conf.template)
// and both apps were EXTERNAL with no authConfig, so
//     GET https://<control-tower-fqdn>/api/feeds/secure-score
// reached data-api with no credential at all — and data-api's identity holds
// Security Reader at SUBSCRIPTION scope plus Log Analytics Reader. An anonymous
// caller read the adopter's real Defender for Cloud secure score. Internal
// ingress on the callee is not a control when a public caller proxies to it.
//
// Token-gating the proxy was considered and REJECTED: nginx would inject the
// token for anonymous callers too, so it protects nothing. The only real fix is
// authenticating the frontends, which is what this block does. THE DEMO'S
// ACCESS MODEL CHANGED as a result — the dashboards are login-gated now, and
// README.md, SECURITY.md and docs/runbooks/g0-bootstrap.md say so.
//
// FAIL-CLOSED, IN THE TEMPLATE, NOT ONLY IN THE WORKFLOW (F26). Each app's
// ingressExternal is now the SAME expression as "does this app have a client ID
// to authenticate against", so there is no reachable combination of parameters
// that publishes one of these three apps to the internet without Easy Auth in
// front of it. A missing client ID costs you a demo you cannot reach from
// outside the environment; it can never cost you an open dashboard.
// .github/workflows/layer-07-apps.yml RESOLVES each client ID from the Entra app
// registration L3 created (F36) rather than demanding it be hand-set, so on the
// normal path all three arrive configured; when one cannot be resolved that
// workflow deploys anyway and says loudly which app is internal-only. This
// template is what makes that safe, and is the only thing that has to be: it is
// the guard, not the belt-and-braces.
// ---------------------------------------------------------------------------

@description('True when an Entra client ID is actually configured. BOTH sentinels matter: readEnvironmentVariable returns its default only when the variable is UNDEFINED, and a GitHub Actions vars.* expansion for an undefined variable produces the EMPTY STRING, which is defined — so the parameter arrives as "" and never as the "unset" default (F26; verified against Bicep CLI 0.46.1: unset -> "unset", empty -> ""). Anything that is neither empty nor the sentinel is treated as configured; the template does not validate GUID shape, ARM does.')
func isEntraClientIdConfigured(clientId string) bool => !empty(clientId) && clientId != 'unset'

@description('[derived] v2.0 issuer, built from environment()/tenant() rather than a hardcoded host — az bicep\'s linter (no-hardcoded-env-urls) refuses a literal login.microsoftonline.com, and this also keeps the template cloud-portable rather than Azure-public-only.')
var easyAuthIssuer = '${environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'

@description('Container Apps built-in authentication (Microsoft.App/containerApps/authConfigs), one shape for all three human-facing apps. It sits IN FRONT of the container at the platform/ingress layer — an unauthenticated request never reaches nginx at all, which is the whole point: these are static SPAs with no server, nowhere to keep a secret and nowhere to enforce a policy of their own. NO CLIENT SECRET ANYWHERE (CLAUDE.md hard rule 5): neither a stored client-secret setting name nor a client-secret certificate thumbprint is configured. Those exist for a CONFIDENTIAL client that calls a downstream API on the signed-in user\'s behalf, or that persists provider tokens in Easy Auth\'s token store for reuse. These apps do neither — each asks exactly one question, "is this caller signed in to our tenant" — and Microsoft documents the Entra provider as fully usable without a client secret for precisely that scenario (learn.microsoft.com/azure/container-apps/authentication). unauthenticatedClientAction is a pinned literal: the platform must never fall through to serving an unauthenticated request. excludedPaths is the ONLY hole, and it is a caller-supplied allowlist rather than a default — see each call site for what it opens and why.')
func entraEasyAuthConfig(clientId string, issuer string, excludedPaths array) object => {
  platform: {
    enabled: true
  }
  globalValidation: {
    unauthenticatedClientAction: 'RedirectToLoginPage'
    redirectToProvider: 'azureactivedirectory'
    excludedPaths: excludedPaths
  }
  identityProviders: {
    azureActiveDirectory: {
      enabled: true
      registration: {
        clientId: clientId
        openIdIssuer: issuer
      }
    }
  }
  login: {
    // No downstream API is ever called on the signed-in user's behalf, so no
    // provider token is worth persisting, and nothing here needs a
    // storage-account-backed token store.
    tokenStore: {
      enabled: false
    }
  }
  httpSettings: {
    requireHttps: true
  }
}

var launchOpsAuthConfigured = isEntraClientIdConfigured(launchOpsEntraClientId)
var controlTowerAuthConfigured = isEntraClientIdConfigured(controlTowerEntraClientId)
var complianceAuthConfigured = isEntraClientIdConfigured(complianceEntraClientId)

// The ONLY paths served without a session, on the two apps V7.1 sweeps.
// /healthz returns `ok <MLS_IMAGE_DIGEST>` and nothing else (see each app's
// nginx.conf.template): it is the build marker V7.1 binds "endpoint is up" to
// "endpoint serves the audited build" with, and V7.1 issues that GET
// unauthenticated from a GitHub-hosted runner. It carries no tenant data and
// reaches no upstream — in particular it is NOT under /api/, so excluding it
// does not re-open the data-api path this whole block exists to close.
var easyAuthExcludedPaths = ['/healthz']

// ------------------------------------------------------------------ container apps

// data-api first: both frontends take DATA_API_ORIGIN from its FQDN, so Bicep
// orders it ahead of them on that reference alone.
module dataApiApp 'br/public:avm/res/app/container-app:0.23.0' = {
  name: 'l7-ca-data-api'
  params: {
    name: dataApiName
    location: location
    tags: tagsDataApi
    environmentResourceId: caeResourceId
    ingressExternal: false // F1 (Task 6): no legitimate caller is outside the CAE
    ingressTargetPort: dataApiTargetPort
    ingressAllowInsecure: false
    scaleSettings: scaleToZero
    managedIdentities: {
      userAssignedResourceIds: [dataApiIdentity.outputs.resourceId]
    }
    containers: [
      {
        name: naming.appKeys.dataApi
        image: dataApiImage
        resources: {
          cpu: json(containerCpu)
          memory: containerMemory
        }
        env: concat(
          [
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: appInsights.properties.ConnectionString
            }
            {
              // Binds DefaultAzureCredential to this app's own identity.
              name: 'AZURE_CLIENT_ID'
              value: dataApiIdentity.outputs.clientId
            }
            {
              name: 'MLS_DATA_BACKENDS'
              value: dataApiMode
            }
            {
              // /healthz build marker (V7.1). config.ts reads MLS_IMAGE_DIGEST
              // first, then CONTAINER_APP_REVISION, then "unknown".
              name: 'MLS_IMAGE_DIGEST'
              value: dataApiImageDigest
            }
          ],
          dataApiCloudEnv
        )
      }
    ]
  }
}

module launchOpsApp 'br/public:avm/res/app/container-app:0.23.0' = {
  name: 'l7-ca-launch-ops'
  params: {
    name: launchOpsName
    location: location
    tags: tagsLaunchOps
    environmentResourceId: caeResourceId
    // EXTERNAL ONLY WHEN EASY AUTH IS CONFIGURED (F25). This is the same
    // expression as authConfig's guard below, deliberately: before Task 26 this
    // read `ingressExternal: true // frontend: public`, and "public" meant
    // anonymous — including anonymous /api/ proxied straight through to
    // data-api's Security-Reader-holding identity. See the EASY AUTH block above.
    ingressExternal: launchOpsAuthConfigured
    ingressTargetPort: launchOpsTargetPort
    ingressAllowInsecure: false
    scaleSettings: scaleToZero
    // null, not an empty object: the AVM module creates the authConfig child
    // resource on `not(empty(authConfig))`, so null is how you say "no auth
    // config" — and it is only ever reachable together with internal ingress.
    authConfig: launchOpsAuthConfigured
      ? entraEasyAuthConfig(launchOpsEntraClientId, easyAuthIssuer, easyAuthExcludedPaths)
      : null
    containers: [
      {
        name: naming.appKeys.launchOps
        image: launchOpsImage
        resources: {
          cpu: json(containerCpu)
          memory: containerMemory
        }
        env: [
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: appInsights.properties.ConnectionString
          }
          {
            // nginx envsubst target. Without it /api/tables/launches falls
            // through to the SPA fallback (or 502s against the image's
            // loopback default) and every view renders empty.
            name: 'DATA_API_ORIGIN'
            value: 'https://${dataApiApp.outputs.fqdn}'
          }
          {
            // Interpolated into the /healthz body by the nginx template, so
            // V7.1 can compare it with the deploy manifest's imageDigest.
            name: 'MLS_IMAGE_DIGEST'
            value: launchOpsImageDigest
          }
        ]
      }
    ]
  }
}

module controlTowerApp 'br/public:avm/res/app/container-app:0.23.0' = {
  name: 'l7-ca-control-tower'
  params: {
    name: controlTowerName
    location: location
    tags: tagsControlTower
    environmentResourceId: caeResourceId
    // EXTERNAL ONLY WHEN EASY AUTH IS CONFIGURED (F25) — same guard as
    // authConfig below. This app is the one F25 was demonstrated against:
    // GET https://<fqdn>/api/feeds/secure-score returned the adopter's live
    // Defender for Cloud posture to any anonymous caller. See the EASY AUTH
    // block above.
    ingressExternal: controlTowerAuthConfigured
    ingressTargetPort: controlTowerTargetPort
    ingressAllowInsecure: false
    scaleSettings: scaleToZero
    authConfig: controlTowerAuthConfigured
      ? entraEasyAuthConfig(controlTowerEntraClientId, easyAuthIssuer, easyAuthExcludedPaths)
      : null
    containers: [
      {
        name: naming.appKeys.controlTower
        image: controlTowerImage
        resources: {
          cpu: json(containerCpu)
          memory: containerMemory
        }
        env: [
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: appInsights.properties.ConnectionString
          }
          {
            // Same-origin proxy target for the Dev/Sec/Ops feeds. The Ask tab's
            // Direct Line token endpoint is a separate service reached by
            // absolute URL and does not go through this proxy.
            name: 'DATA_API_ORIGIN'
            value: 'https://${dataApiApp.outputs.fqdn}'
          }
          {
            name: 'MLS_IMAGE_DIGEST'
            value: controlTowerImageDigest
          }
        ]
      }
    ]
  }
}

// Inbound auth for the MCP endpoint (F2, infra half — Task 5). Unconditional,
// unlike the pre-Task-5 shape: apps/mcp-tools now fails closed at boot without
// MCP_AUTH_TOKEN in every mode (Task 4), so this template must always supply
// one rather than building an OPEN endpoint by omission. The secret is
// resolved directly from the platform Key Vault via this app's own UAMI —
// the token itself never crosses into this template, demo.bicepparam, ARM
// deployment history or a what-if log. See the "MCP INBOUND AUTH TOKEN"
// header block for the full exposure analysis.
var mcpToolsSecrets = [
  {
    name: 'mcp-auth-token'
    keyVaultUrl: '${platformKv.properties.vaultUri}secrets/mcp-auth-token'
    identity: mcpToolsIdentity.outputs.resourceId
  }
]

module mcpToolsApp 'br/public:avm/res/app/container-app:0.23.0' = {
  name: 'l7-ca-mcp-tools'
  // Waits on the Key Vault Secrets User grant: Container Apps resolves a
  // keyVaultUrl secret using the identity's role at the time it needs the
  // value, and nothing in this module's params references mcpKvGrant's
  // output, so Bicep would not otherwise order the grant ahead of the app.
  dependsOn: [mcpKvGrant]
  params: {
    name: mcpToolsName
    location: location
    tags: tagsMcpTools
    environmentResourceId: caeResourceId
    // EXTERNAL, unconditionally. Copilot Studio calls this server from outside
    // Azure over the public internet; an internal-only ingress would make the
    // agent's tools unreachable and is not a supported configuration for this
    // design. There is deliberately no parameter to turn this off.
    ingressExternal: true
    // HTTPS only. Container Apps terminates TLS on the external FQDN; allowing
    // insecure would publish an http:// listener alongside it, which Copilot
    // Studio must never be able to negotiate down to.
    ingressAllowInsecure: false
    ingressTargetPort: mcpToolsTargetPort
    scaleSettings: scaleToZero
    managedIdentities: {
      userAssignedResourceIds: [mcpToolsIdentity.outputs.resourceId]
    }
    // One secret, and only one: the inbound auth token, resolved from Key
    // Vault rather than passed as a value. Every Azure upstream still
    // authenticates with the managed identity above — no cloud credential is
    // stored here, and this secret is never a plain value either.
    secrets: mcpToolsSecrets
    containers: [
      {
        name: naming.appKeys.mcpTools
        image: mcpToolsImage
        resources: {
          cpu: json(containerCpu)
          memory: containerMemory
        }
        env: concat(
          [
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: appInsights.properties.ConnectionString
            }
            {
              // Binds DefaultAzureCredential inside the container to the
              // user-assigned identity above rather than to any ambient identity.
              name: 'AZURE_CLIENT_ID'
              value: mcpToolsIdentity.outputs.clientId
            }
            {
              name: 'MLS_IMAGE_DIGEST'
              value: mcpToolsImageDigest
            }
          ],
          [
            {
              name: 'MCP_AUTH_TOKEN'
              secretRef: 'mcp-auth-token'
            }
            {
              // F2's other half: the backend set is now a deployment decision,
              // not an absence. apps/mcp-tools/src/config.ts reads this and
              // defaults to 'local' itself if it is ever unset again.
              name: 'MLS_TOOL_BACKENDS'
              value: mcpToolsBackendMode
            }
          ]
        )
      }
    ]
  }
}

// ------------------------------------------------------------------ compliance app (Task 13)
//
// mls-compliance-demo-ca — the board that shows the estate's OWN compliance
// posture (design brief section 5.1). Structurally it is a static SPA exactly
// like control-tower/launch-ops (nginx serving a Vite build), and since F25 it
// has the SAME access-control shape as those two rather than a third one:
//   data-api       INTERNAL-ONLY — nothing outside the CAE has any business
//                  calling it (F1/Task 6).
//   launch-ops,
//   control-tower,
//   compliance     EXTERNAL AND EASY-AUTH GATED — human-facing, but the
//                  audience is "someone on this program", not "the internet".
//                  Until F25 the first two were EXTERNAL AND OPEN, and their
//                  nginx /api/ proxy made data-api's internal ingress
//                  meaningless; see the EASY AUTH block above the container
//                  apps section for the full account.
//
// EASY AUTH, NOT AN APPLICATION GATE. The app holds no session, no user store
// and no auth code of its own (apps/compliance has no server — it is nginx
// serving a prebuilt bundle). Container Apps built-in authentication
// (Microsoft.App/containerApps/authConfigs) sits in FRONT of the container at
// the platform/ingress layer, so an unauthenticated request never reaches
// nginx at all — there is nowhere in a static SPA to keep a secret or enforce
// a policy, so the platform enforces it instead. The config itself, and why no
// client secret is configured, now live in entraEasyAuthConfig() above, which
// all three human-facing apps share.
//
// NO IDENTITY, NO RBAC GRANTS. Unlike data-api/mcp-tools this app calls no
// Azure data plane at all — the catalog and every compliance/state/*.json
// snapshot are baked into the JS bundle at image build time
// (apps/compliance/Dockerfile), so there is no credential for a managed
// identity to hold and none is provisioned.
//
// DELIBERATELY EXCLUDED FROM containerAppNames/imageDigests (see those
// outputs below, and complianceAppName's own description). V7.1's
// Test-PublicEndpoint issues an UNAUTHENTICATED GET expecting 200 — the exact
// request Easy Auth exists to intercept and redirect. Folding this app into
// the outputs the job-summary/manifest step reads from would either paint a
// permanently-red-looking manifest entry or, worse, invite a future change to
// loop containerAppNames into a blind health sweep and get every request
// redirected to a login page. Same reasoning L10's vulnLabWitnessApp already
// established for a different reason (see that block below) — a fixed count
// of "the apps V7.1/V7.5 sweep" is not the same set as "every container app
// this template deploys", and conflating them is the mistake to avoid.
module complianceApp 'br/public:avm/res/app/container-app:0.23.0' = {
  name: 'l7-ca-compliance'
  params: {
    name: complianceName
    location: location
    tags: tagsCompliance
    environmentResourceId: caeResourceId
    // EXTERNAL ONLY WHEN EASY AUTH IS CONFIGURED — the same guard as authConfig
    // below, and the fix for F26: before Task 26 this read `ingressExternal:
    // true` unconditionally, and the runbook claimed that leaving
    // MLS_COMPLIANCE_CLIENT_ID unset made "ARM reject the deployment outright".
    // It did not. `${{ vars.MLS_COMPLIANCE_CLIENT_ID }}` for an undefined
    // GitHub variable expands to the EMPTY STRING, so readEnvironmentVariable
    // saw a variable that WAS set, returned '', and never reached its 'unset'
    // default — leaving a NIST control-family board anonymously reachable
    // behind an Easy Auth block with an empty clientId.
    ingressExternal: complianceAuthConfigured
    ingressTargetPort: complianceTargetPort
    ingressAllowInsecure: false
    scaleSettings: scaleToZero
    // Shared with launch-ops and control-tower since F25 — see
    // entraEasyAuthConfig() above for the whole configuration and its rationale.
    // /healthz is excluded there for V7.1's benefit; this app is outside V7.1's
    // sweep (see complianceAppName below) but shares the shape so there is one
    // Easy Auth configuration in this template to review rather than three.
    authConfig: complianceAuthConfigured
      ? entraEasyAuthConfig(complianceEntraClientId, easyAuthIssuer, easyAuthExcludedPaths)
      : null
    // No managed identity, no secrets: this app reads only what was baked
    // into its image at build time and needs no Azure data-plane credential.
    containers: [
      {
        name: naming.appKeys.compliance
        image: complianceImage
        resources: {
          cpu: json(containerCpu)
          memory: containerMemory
        }
        env: [
          {
            // /healthz build marker, same convention as the other frontends
            // (apps/compliance/nginx.conf.template). Not read by V7.1 (see
            // the header comment above) — kept for parity and for anyone
            // curling it by hand, exactly like data-api's `build` marker.
            name: 'MLS_IMAGE_DIGEST'
            value: complianceImageDigest
          }
        ]
      }
    ]
  }
}

// ------------------------------------------------------------------ L10 deployment witness
//
// mls-vuln-lab-demo-ca. verification/layer-10-audit.ps1 reads
// `az containerapp revision list -g <rg-apps> -n mls-vuln-lab-demo-ca` for the deploy
// stage of BOTH healing trails (V10.1 stage 6, V10.2 stage 5): "a new ACA revision
// timestamped after the merge". Nothing created that app, so both criteria failed on a
// resource that did not exist — a pipeline defect wearing an estate defect's clothes.
//
// WHAT THIS IS, STATED PLAINLY. It is a deployment witness, not a fifth serving app, and
// apps/vuln-lab's own code is NOT in it. That is deliberate and non-negotiable:
//
//   1. apps/vuln-lab pins three known-vulnerable packages, one of them CRITICAL
//      (minimist 1.2.5, CVE-2021-44906). Building it into an image would put a CRITICAL
//      finding in front of the L9 Trivy gate — the same gauntlet L10 requires the heal PR
//      to pass green. The Autofix track does not touch the pins, so its heal PR would go
//      red every time, and the only ways out are suppressing the gate (L10 failure mode 3
//      forbids it outright) or shipping known-vulnerable containers into an estate that
//      has Defender for Containers toggled on at L9. Both are worse than the gap.
//   2. The seeds are HTTP server factories for a path traversal and a command injection.
//      apps/vuln-lab/README.md's safety argument is precisely that "no server is ever
//      started" — nothing calls either factory, so the lab holds a live alert without
//      holding a live risk. Deploying them would invalidate that argument.
//   3. The repo-root package.json excludes apps/vuln-lab from the workspaces list so the
//      pins can never resolve to patched versions, and the README's guarantee is that it
//      is "not in any Dockerfile". This app keeps both true: no build, no Dockerfile, no
//      dependency graph.
//
// So the witness runs a pinned public placeholder image and carries the heal's identity
// as configuration. .github/workflows/vuln-lab-witness.yml re-stamps MLS_HEAL_COMMIT (and
// the lab's post-heal advisory count) on every push to main touching apps/vuln-lab/**,
// which is what rolls a revision timestamped after the heal merge. The audit does not
// settle for "some revision appeared": it requires the newest revision after the merge to
// carry THIS heal's commit, so an unrelated redeploy cannot satisfy the stage.
//
// Ingress is DISABLED and minReplicas is 0: the witness never listens, never scales up and
// never serves anyone. Its revisions and their environment are the whole product, and they
// are readable from ARM with Reader — which is all the Verifier holds.
//
// Cost: $0. A container app with no ingress, no scale rule and minReplicas 0 runs zero
// replicas; Container Apps bills active usage only. It dies with mls-rg-apps in down.ps1,
// exactly as docs/runbooks/layers/L10.md's teardown section already says it does.
module vulnLabWitnessApp 'br/public:avm/res/app/container-app:0.23.0' = {
  name: 'l7-ca-vuln-lab-witness'
  params: {
    name: vulnLabName
    location: location
    tags: tagsVulnLab
    environmentResourceId: caeResourceId
    // No ingress at all. Not "internal": there is nothing to reach.
    disableIngress: true
    scaleSettings: scaleToZero
    containers: [
      {
        name: naming.appKeys.vulnLab
        image: vulnLabWitnessImage
        resources: {
          cpu: json(containerCpu)
          memory: containerMemory
        }
        env: [
          {
            // The heal this revision attests to. Rewritten by
            // .github/workflows/vuln-lab-witness.yml on each vuln-lab merge; the L10 audit
            // compares it with the heal PR's merge commit.
            name: 'MLS_HEAL_COMMIT'
            value: vulnLabHealCommit
          }
          {
            // Static, and true of the image rather than of the lab: nothing from
            // apps/vuln-lab is in this container.
            name: 'MLS_WITNESS_ROLE'
            value: 'l10-deployment-witness'
          }
        ]
      }
    ]
  }
}

// ------------------------------------------------------------------ outputs

@description('FQDN of launch-ops. EXTERNAL and Easy-Auth gated when launchOpsEntraClientId is configured; an INTERNAL (in-environment only) FQDN when it is not — see frontendAuthStatus below and the EASY AUTH block above the container apps section (F25).')
output launchOpsFqdn string = launchOpsApp.outputs.fqdn

@description('FQDN of control-tower. EXTERNAL and Easy-Auth gated when controlTowerEntraClientId is configured; an INTERNAL (in-environment only) FQDN when it is not — see frontendAuthStatus below and the EASY AUTH block above the container apps section (F25).')
output controlTowerFqdn string = controlTowerApp.outputs.fqdn

@description('Which human-facing apps actually got Easy Auth, and therefore which ones are externally reachable at all (F25/F26). true = external + Entra sign-in required; false = NO client ID was supplied, so the app deployed INTERNAL to the Container Apps environment and V7.1 will not be able to reach it. .github/workflows/layer-07-apps.yml resolves the client IDs from L3\'s Entra app registrations and deploys regardless (F36), warning and naming each app a false here corresponds to — so a false means that registration does not exist yet, not that something went wrong.')
output frontendAuthStatus object = {
  launchOps: launchOpsAuthConfigured
  controlTower: controlTowerAuthConfigured
  compliance: complianceAuthConfigured
}

@description('Public FQDN of the MCP tool server (always external — Copilot Studio must reach it).')
output mcpToolsFqdn string = mcpToolsApp.outputs.fqdn

@description('Public FQDN of the data-api serving layer.')
output dataApiFqdn string = dataApiApp.outputs.fqdn

@description('Origin injected into both frontends as DATA_API_ORIGIN. Their nginx proxies /api/ here, so /api/tables/launches arrives as /tables/launches (trailing slash on proxy_pass strips the prefix).')
output dataApiOrigin string = 'https://${dataApiApp.outputs.fqdn}'

@description('Backend set data-api will actually serve. "local" means the Fabric SQL analytics endpoint was not supplied, and every table route will answer 503 because data/generated is not in the image.')
output dataApiBackendModeResolved string = dataApiMode

@description('Client ID of the data-api user-assigned identity — the principal that needs the SQL contained-database user, the Fabric workspace Viewer role, Log Analytics Reader and Security Reader.')
output dataApiIdentityClientId string = dataApiIdentity.outputs.clientId

@description('Principal (object) ID of the data-api user-assigned identity, for role assignments made outside this template.')
output dataApiIdentityPrincipalId string = dataApiIdentity.outputs.principalId

@description('Container app NAME per app key. verification/layer-07-audit.ps1 addresses apps by name (-AppName), and the L7 workflow builds the V7.1 deploy manifest from these. Two apps are deliberately NOT here, for different reasons: the L10 witness serves nothing, has no image digest to bind an endpoint to, and V7.1 would report it as an app whose /healthz never answers (published separately as vulnLabWitnessAppName); the compliance app (Task 13) sits behind Easy Auth, and V7.1\'s sweep is an UNAUTHENTICATED GET expecting 200 — exactly what Easy Auth exists to refuse. Folding it in here would either paint a permanently-red manifest entry or invite a future change to loop this output into a blind health sweep (published separately as complianceAppName).')
output containerAppNames object = {
  launchOps: launchOpsName
  controlTower: controlTowerName
  mcpTools: mcpToolsName
  dataApi: dataApiName
}

@description('Name of the L10 deployment witness container app (mls-vuln-lab-demo-ca) — the app verification/layer-10-audit.ps1 reads revisions from and .github/workflows/vuln-lab-witness.yml stamps.')
output vulnLabWitnessAppName string = vulnLabName

@description('Resource ID of the L10 deployment witness.')
output vulnLabWitnessResourceId string = vulnLabWitnessApp.outputs.resourceId

@description('Name of the compliance container app (mls-compliance-demo-ca) — deliberately not in containerAppNames; see that output\'s description. app-compliance-ci.yml\'s deploy job resolves this same name independently via the naming composite action (ca-compliance) rather than reading it from here, the same relationship app-control-tower-ci.yml already has with controlTowerName.')
output complianceAppName string = complianceName

@description('HTTPS FQDN of the compliance app. Reaching it without an authenticated Entra session redirects to login rather than serving the board. INTERNAL to the Container Apps environment when complianceEntraClientId is not configured (F26) — see frontendAuthStatus.')
output complianceFqdn string = complianceApp.outputs.fqdn

@description('MLS_IMAGE_DIGEST as deployed, per app. This is the deploy run\'s record of what each endpoint should be serving; the L7 workflow writes it into the manifest V7.1 compares against /healthz.')
output imageDigests object = {
  launchOps: launchOpsImageDigest
  controlTower: controlTowerImageDigest
  mcpTools: mcpToolsImageDigest
  dataApi: dataApiImageDigest
}

@description('Full HTTPS URL of the MCP Streamable HTTP endpoint. This is the value that goes into the Copilot Studio MCP connector host/path (infra/copilot-studio/agent-definition.md) and into the demo environment variable MCP_SERVER_URL.')
output mcpToolsEndpoint string = 'https://${mcpToolsApp.outputs.fqdn}${mcpEndpointPath}'

@description('Client ID of the mcp-tools user-assigned identity — the principal other layers grant SQL / Fabric / Cost Management access to.')
output mcpToolsIdentityClientId string = mcpToolsIdentity.outputs.clientId

@description('Principal (object) ID of the mcp-tools user-assigned identity, for role assignments made outside this template.')
output mcpToolsIdentityPrincipalId string = mcpToolsIdentity.outputs.principalId

@description('Resource IDs of the four container apps.')
output containerAppResourceIds object = {
  launchOps: launchOpsApp.outputs.resourceId
  controlTower: controlTowerApp.outputs.resourceId
  mcpTools: mcpToolsApp.outputs.resourceId
  dataApi: dataApiApp.outputs.resourceId
}
