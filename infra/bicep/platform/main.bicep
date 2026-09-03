// =============================================================================
// platform/main.bicep — L6: shared runtime platform (Bicep/AVM).
//
// Deployed at SUBSCRIPTION scope by the L6 workflow (layer-06-platform.yml):
//
//   az deployment sub create \
//     --location $AZURE_LOCATION \
//     --template-file infra/bicep/platform/main.bicep \
//     --parameters infra/bicep/platform/demo.bicepparam
//
// Creates the four demo resource groups (CLAUDE.md RG layout) and, per the
// [derived] placement map (see infra/bicep/README.md):
//   mls-rg-platform : Log Analytics workspace, workspace-based App Insights,
//                     Container Apps environment (wired to LAW), Key Vault
//   mls-rg-data     : Azure SQL logical server + serverless per-app database
//                     (auto-pause 60 min, min 0.5 vCore, max 2 vCore)
//   mls-rg-ops      : storage account for Cost Management daily exports
//   mls-rg-apps     : created empty here; L7 app deployments target it
//
// Everything is scale-to-zero / auto-pause / consumption. Anything that bills
// while idle is a design error (master plan: built-but-parked < $15/month).
//
// KEY VAULT, after the Copilot Studio amendment (2026-08-24): the vault is still
// created here, but it now has **zero secret consumers**. The only secret it was
// ever going to hold — anthropic-api-key — no longer exists anywhere in the
// system, and the L7 app that read it has been rebuilt as an MCP tool server
// that authenticates with a managed identity instead. Nothing in this template
// ever created a secret (Bicep never held the value), so removing the wiring is
// a documentation change here and a real deletion in apps/main.bicep.
//
// The vault is deliberately NOT deleted. Reasons, in order: (1) it costs ~$0
// empty and is inside the agreed idle envelope; (2) the amendment introduces a
// Direct Line channel key as a new G0 item for the embedded control-tower
// surface — that is the next credential this estate will have to hold, and Key
// Vault is where it belongs rather than a GitHub Actions secret; (3) deleting
// and recreating a soft-deleted vault name is exactly the failure mode
// KEY_VAULT_CREATE_MODE=recover exists to absorb, so churning it is a
// self-inflicted rebuild risk. Whether the Direct Line key is stored at all is a
// sponsor decision, not this template's to make.
//
// The Cost Management export definition + ingestion Function are wired by the
// layer-06 workflow (subscription-scope config, not resources of this template).
// =============================================================================
targetScope = 'subscription'

import * as naming from '../naming.bicep'

// ------------------------------------------------------------------ parameters

@description('Company prefix. Single source: naming.bicep.')
param companyPrefix string = naming.defaultCompanyPrefix

@description('Environment segment for names and the env tag.')
param env string = naming.defaultEnv

@description('Region for all platform resources. From AZURE_LOCATION at deploy time.')
param location string = deployment().location

@description('costCenter tag value.')
param costCenter string = naming.defaultCostCenter

@description('owner tag value.')
param owner string = naming.defaultOwner

@description('dataClassification tag value for platform resources.')
param dataClassification string = naming.defaultDataClassification

@description('Entra admin login name for the SQL server (Entra-only auth — no SQL passwords, CLAUDE.md hard rule 5). Supplied from the environment at deploy time.')
param sqlAadAdminLogin string = ''

@description('Entra object ID (sid) of the SQL admin principal. Supplied from the environment at deploy time.')
param sqlAadAdminObjectId string = ''

@allowed(['Application', 'Group', 'User'])
@description('Principal type of the SQL Entra admin.')
param sqlAadAdminPrincipalType string = 'Group'

@description('SQL serverless auto-pause delay in minutes. Pinned to 60 by the master plan; the L6 audit (V6.1) fails on any other value.')
param sqlAutoPauseDelayMinutes int = 60

@description('SQL serverless minimum capacity in vCores. Pinned to 0.5 by the master plan (V6.1).')
param sqlMinCapacity string = '0.5'

@description('SQL serverless maximum capacity in vCores (GP_S_Gen5 SKU capacity).')
param sqlMaxCapacity int = 2

@description('[derived] Point-in-time (short-term) backup retention in days (F16, Task 18 — CP-9). The AVM sql/server module property is backupShortTermRetentionPolicy.retentionDays, not shortTermRetentionPolicy as F16\'s own Fix text assumed (verified against the cached avm/res/sql/server@0.22.0 module schema, which rejects that name with BCP037). 7 is Azure\'s own platform default made explicit rather than left to resolve silently; the data is seeded synthetic data with a deterministic regenerator (data/seed/), so a week of point-in-time recovery is adequate — raise it only if the sponsor decides the demo needs a longer undo window, which this template would then audit (V6.5), not just inherit.')
param sqlBackupRetentionDays int = 7

@allowed(['Local', 'Zone', 'Geo', 'GeoZone'])
@description('[derived] Backup storage redundancy tier (F16, Task 18 — CP-9). Local matches the single-region design (allowedLocations policy, infra/bicep/landing-zone/main.bicep) — Geo/GeoZone would replicate backup data cross-region and quietly widen the residency boundary that policy otherwise pins for live resources. requestedBackupStorageRedundancy is a correctly-named top-level database property in the cached module schema.')
param sqlBackupStorageRedundancy string = 'Local'

@allowed(['default', 'recover'])
@description('Key Vault create mode. Flip to recover when a soft-deleted vault with the target name exists (kill/rebuild replay — L6 playbook rollback note).')
param keyVaultCreateMode string = 'default'

@description('[derived] Log Analytics retention in days. 90 matches the AU-11 assessment convention and DFARS 252.204-7012(e)\'s 90-day preservation obligation (F9, Task 13) — raised from the 30-day free-tier-only default. The per-GB retention charge past the 31-day free window is bounded by dailyQuotaGb, not by this value.')
param lawDataRetentionDays int = 90

@description('[derived] Log Analytics daily ingestion cap in GB — runaway-ingest guard for the idle-cost model. -1 disables the cap.')
param lawDailyQuotaGb string = '1'

@description('[derived] Email receiver for the security/operational action group (F17, Task 19) — reuses the sponsor address scripts/bootstrap/03-budget.ps1 already notifies, so cost and security alerting share one page-out path. Empty disables the email receiver; the action group still deploys (a clean local build stays green, and the resource exists for 03-budget.ps1 to reference by ID once L6 has deployed).')
param alertNotificationEmail string = ''

@description('[derived] Blob container the Cost Management daily export writes into, and the only container the cost-ingest Function is granted any access to (F19 / F13\'s seventh grant). Pinned by the L6 audit\'s V6.3 (verification/layer-06-audit.ps1\'s -CostExportContainerName default) and by layer-06-platform.yml\'s export-definition body; a parameter here so all three read one value rather than three literals that can drift apart.')
param costExportContainerName string = 'cost-exports'

@description('[derived] Blob container in the FUNCTION RUNTIME storage account that Flex Consumption stores the deployment package in. Its own container in its own account, never shared with the export data — see the cost-ingest block below for why the two accounts are separate.')
param functionDeploymentContainerName string = 'deployment-package'

@description('Name of the Key Vault secret holding the Copilot Studio DIRECT LINE SECRET, which the directline-token Function exchanges server-side for a short-lived conversation token. EMPTY IS A SUPPORTED DEPLOYMENT and is the default: the Function still deploys and still answers, with a typed error saying the channel is not configured, which is the honest state before the agent is published. The value never enters this template - it is resolved from Key Vault at runtime by the Function\'s own managed identity.')
param directlineSecretName string = ''

@description('Object id of the DEPLOYER service principal (mls-github-deployer), so L8\'s golden-question eval can read the Direct Line secret and actually evaluate the agent. EMPTY IS SUPPORTED and grants nothing. Why this exists (F183): the eval reads that secret to open a Direct Line conversation, the deployer held no Key Vault data-plane role, and the read returned Forbidden on every run since the vault went RBAC. The step swallowed the error and announced the secret ABSENT, which suppressed its artifact, which made V8.2/V8.4/V8.5 record SKIP - so L8 reported green over a showpiece that answered nothing, and `layer-08-agent-eval` was never once uploaded. The grant is deliberately narrow: Secrets User on this vault only, and only when a Direct Line secret is actually named, because a standing grant for a secret nobody reads is access with no purpose. It is NOT a privilege escalation in substance - the deployer already holds subscription Contributor and could assign itself this role - it is that access made explicit, reviewable in a template, and reproduced by a rebuild rather than applied by hand.')
param deployerPrincipalId string = ''

@description('Origins the directline-token Function will mint a token for, comma-separated. These become the Direct Line trustedOrigins and the CORS allow-list, so a token minted for this estate cannot be replayed from someone else page. LEAVE IT EMPTY: the control tower origin is DERIVED from the Container Apps environment domain and the naming module, so it cannot go stale when the estate is rebuilt (F129). Set it only to add a custom domain or a second origin, and include the control tower itself when you do, because this REPLACES the derived value rather than adding to it. The previous text called this endpoint public and anonymous by design; it is no longer anonymous - it now verifies the caller Easy Auth token before minting.')
param directlineAllowedOrigins string = ''

@description('Entra tenant whose user tokens the directline-token Function accepts. The Function verifies the caller Easy Auth token before exchanging the Direct Line secret, so the copilot inherits the identity of the control tower instead of sitting open beside it. EMPTY MEANS THE FUNCTION REFUSES EVERY REQUEST (500) rather than falling back to anonymous - an optional security control is one nobody turns on.')
param directlineUserTenantId string = ''

@description('The Easy Auth application (client) id of the control tower. The Function checks this as the token AUDIENCE: a signature from the right tenant proves only that SOME Entra app issued the token, and one minted for a different application is not permission to use this one. Empty has the same effect as an empty tenant id - the Function refuses.')
param directlineUserAudience string = ''

@description('[derived] Node runtime major version for the cost-ingest Function (Flex Consumption `functionAppConfig.runtime`). 22 matches apps/cost-ingest/package.json\'s `engines.node: >=22`. Not a free choice: Flex Consumption accepts only the runtime versions it publishes, and one it does not offer fails the deployment rather than degrading.')
param costIngestNodeVersion string = '22'

@description('[derived] Per-instance memory for the cost-ingest Function, in MB. Flex Consumption bills GB-seconds, so the smallest supported size is also the cheapest, and the workload is one CSV parse a day.')
@allowed([512, 2048, 4096])
param costIngestInstanceMemoryMb int = 512

@description('[derived] Maximum Flex Consumption instances for the cost-ingest Function. 40 is the platform floor for this setting, and a scale-out ceiling here is a spend guard rather than a throughput target: the trigger fires roughly once a day. Raising it is a spend-profile change (G2).')
@minValue(40)
@maxValue(1000)
param costIngestMaximumInstanceCount int = 40

@description('[derived] Fabric workspace the cost-ingest Function writes `cost_daily` into (its FABRIC_WORKSPACE app setting — apps/cost-ingest/src/config.ts). EMPTY means "derive it from naming.bicep", which is the normal case and the only way the name follows a changed companyPrefix; a Bicep parameter default cannot reference another parameter, so the derivation is a var below rather than a default here. Set it only to point at a workspace named something other than infra/fabric/provision-workspace.ps1\'s -WorkspaceName default.')
param fabricWorkspace string = ''

@description('[derived] Fabric lakehouse inside that workspace (FABRIC_LAKEHOUSE). Same empty-means-derive contract as fabricWorkspace above. Underscored when derived, matching provision-workspace.ps1\'s -LakehouseName default and its ValidatePattern (letters, digits and underscores only).')
param fabricLakehouse string = ''

@description('[derived] Folder under the lakehouse\'s Files/ that the `cost_daily` Delta table is defined over (LAKEHOUSE_COST_PATH). Set explicitly rather than left to the app\'s own fallback so the table location is declared in one place a reviewer can find.')
param lakehouseCostPath string = 'cost_daily'

// ------------------------------------------------------------------ names + tags

var rgPlatformName = naming.resourceGroupName(companyPrefix, naming.rgPurposes.platform)
var rgAppsName = naming.resourceGroupName(companyPrefix, naming.rgPurposes.apps)
var rgDataName = naming.resourceGroupName(companyPrefix, naming.rgPurposes.data)
var rgOpsName = naming.resourceGroupName(companyPrefix, naming.rgPurposes.ops)

var lawName = naming.logAnalyticsWorkspaceName(companyPrefix, env)
var appiName = naming.appInsightsName(companyPrefix, env)
var caeName = naming.containerAppsEnvironmentName(companyPrefix, env)
var kvName = naming.keyVaultName(companyPrefix, env)
var sqlName = naming.sqlServerName(companyPrefix, env)
var sqlDbName = naming.sqlDatabaseName(companyPrefix, naming.appKeys.launchOps, env)
var exportStorageName = naming.storageAccountName(companyPrefix, 'cost', env)
var alertActionGroupName = naming.resourceName(companyPrefix, 'obs', env, 'ag')
var kvDeniedAccessAlertName = naming.resourceName(companyPrefix, 'kv-denied', env, 'alert')
var sqlFailedLoginAlertName = naming.resourceName(companyPrefix, 'sql-auth', env, 'alert')

// F19 — the cost-ingest FinOps leg. `cost-ingest` is an appKey in naming.bicep,
// not a role segment invented here, even though it names no container app.
var costIngestIdentityName = naming.userAssignedIdentityName(companyPrefix, naming.appKeys.costIngest, env)
var costIngestFunctionAppName = naming.functionAppName(companyPrefix, naming.appKeys.costIngest, env)
var costIngestPlanName = naming.appServicePlanName(companyPrefix, naming.appKeys.costIngest, env)
var directlineIdentityName = naming.userAssignedIdentityName(companyPrefix, naming.appKeys.directlineToken, env)
var directlineFunctionAppName = naming.functionAppName(companyPrefix, naming.appKeys.directlineToken, env)
var directlinePlanName = naming.appServicePlanName(companyPrefix, naming.appKeys.directlineToken, env)
var functionRuntimeStorageName = naming.storageAccountName(companyPrefix, 'func', env)
var costExportSystemTopicName = naming.resourceName(companyPrefix, 'cost', env, 'evgt')

// Empty parameter means "derive from naming.bicep so the name follows
// companyPrefix" — a parameter default cannot reference another parameter, which
// is why the derivation lives here.
var fabricWorkspaceResolved = empty(fabricWorkspace) ? naming.fabricWorkspaceName(companyPrefix) : fabricWorkspace
var fabricLakehouseResolved = empty(fabricLakehouse) ? naming.fabricLakehouseName(companyPrefix) : fabricLakehouse

// app tag values follow the role segment of each resource name (README: derived).
var tagsPlatform = naming.requiredTags(env, 'platform', costCenter, owner, dataClassification)
var tagsApps = naming.requiredTags(env, 'apps', costCenter, owner, dataClassification)
var tagsData = naming.requiredTags(env, 'data', costCenter, owner, dataClassification)
var tagsOps = naming.requiredTags(env, 'ops', costCenter, owner, dataClassification)
var tagsSqlServer = naming.requiredTags(env, 'ops', costCenter, owner, dataClassification)
var tagsSqlDb = naming.requiredTags(env, naming.appKeys.launchOps, costCenter, owner, dataClassification)
var tagsCostStorage = naming.requiredTags(env, 'cost', costCenter, owner, dataClassification)
var tagsCostIngest = naming.requiredTags(env, naming.appKeys.costIngest, costCenter, owner, dataClassification)
var tagsDirectline = naming.requiredTags(env, naming.appKeys.directlineToken, costCenter, owner, dataClassification)

// THE CONTROL TOWER ORIGIN IS DERIVED, NOT STORED, and F129 is why. A Container Apps
// FQDN embeds the ENVIRONMENT's randomly-assigned domain, and Azure picks a new one
// every time the environment is recreated. This value was previously carried in a
// GitHub variable, which meant it named a dead host from the moment the estate was
// rebuilt - the same defect as the Copilot connector's hardcoded host, living in
// configuration instead of a file, where no repository test can see it.
//
// Both halves are already in this template: L6 creates the environment (so it knows
// the domain) and naming.bicep owns the app name. Deriving costs nothing and cannot
// go stale, so the variable is no longer read.
//
// An explicit `directlineAllowedOrigins` still wins, for the case of an extra origin
// or a custom domain. It is additive to nothing - it REPLACES - so a caller setting it
// must include the control tower itself.
var controlTowerOrigin = 'https://${naming.containerAppName(companyPrefix, naming.appKeys.controlTower, env)}.${containerAppsEnvironment.outputs.defaultDomain}'
var directlineOrigins = empty(directlineAllowedOrigins) ? controlTowerOrigin : directlineAllowedOrigins

// ------------------------------------------------------------------ resource groups (all four — single owner of RG creation)

module rgPlatform 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'l6-rg-platform'
  params: {
    name: rgPlatformName
    location: location
    tags: tagsPlatform
  }
}

module rgApps 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'l6-rg-apps'
  params: {
    name: rgAppsName
    location: location
    tags: tagsApps
  }
}

module rgData 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'l6-rg-data'
  params: {
    name: rgDataName
    location: location
    tags: tagsData
  }
}

module rgOps 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'l6-rg-ops'
  params: {
    name: rgOpsName
    location: location
    tags: tagsOps
  }
}

// ------------------------------------------------------------------ observability (mls-rg-platform)

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'l6-law'
  scope: resourceGroup(rgPlatformName)
  params: {
    name: lawName
    location: location
    tags: tagsPlatform
    skuName: 'PerGB2018' // pay-as-you-go: $0 when nothing ingests
    dataRetention: lawDataRetentionDays
    dailyQuotaGb: lawDailyQuotaGb
  }
  dependsOn: [rgPlatform]
}

module appInsights 'br/public:avm/res/insights/component:0.8.0' = {
  name: 'l6-appi'
  scope: resourceGroup(rgPlatformName)
  params: {
    name: appiName
    location: location
    tags: tagsPlatform
    workspaceResourceId: logAnalytics.outputs.resourceId // workspace-based (master plan)
    // F4 (compliance/findings/2026-08-26-prepublication-review.md#f4, Task 8):
    // the AVM default is `false`, which means the ingestion key embedded in
    // the connection string alone authorises telemetry writes from anywhere
    // on the internet — and that connection string used to be a Bicep output
    // that layer-06's workflow put in a public job summary. The output is
    // gone (see the removed `appInsightsConnectionString` output below this
    // module) and local (key-based) ingestion is now refused outright.
    // Ingestion moves to Microsoft Entra ID auth: the two Node services that
    // still send telemetry (mcp-tools, data-api) are granted 'Monitoring
    // Metrics Publisher' on this component from apps/main.bicep (modules
    // mcpAppInsightsGrant / dataApiAppInsightsGrant — their identities are
    // born at L7, after this module deploys at L6), and both apps' telemetry
    // code now presents a Microsoft Entra token when AZURE_CLIENT_ID is set
    // (apps/mcp-tools/src/telemetry.ts, apps/data-api/src/telemetry/otel.ts).
    // Per Microsoft's own docs (learn.microsoft.com/azure/azure-monitor/app/
    // azure-ad-authentication#disable-local-authentication), disabling local
    // auth here is exactly the scenario that role and that code path exist
    // for — "Although the Monitoring Metrics Publisher role says 'metrics,'
    // it publishes all telemetry to the Application Insights resource."
    disableLocalAuth: true
  }
  dependsOn: [rgPlatform]
}

// ------------------------------------------------------------------ Container Apps environment (mls-rg-platform)

module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.15.0' = {
  name: 'l6-cae'
  scope: resourceGroup(rgPlatformName)
  params: {
    name: caeName
    location: location
    tags: tagsPlatform
    // Wired to the Log Analytics workspace (master plan L6).
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    }
    // Consumption-only environment: no workload profiles, no VNet, no
    // zone-redundancy (which would require an infrastructure subnet). The
    // environment itself bills nothing; apps bill only while replicas run.
    zoneRedundant: false
    // AVM defaults publicNetworkAccess to Disabled; the two frontend apps have
    // external ingress by design, so the environment must accept public traffic.
    publicNetworkAccess: 'Enabled'
    // F9 (compliance/findings/2026-08-26-prepublication-review.md#f9, Task 13):
    // appLogsConfiguration above carries container console/system logs, but
    // that is a distinct ACA mechanism from Azure Monitor diagnosticSettings
    // (environment-level audit/operational categories, e.g. RequestResponse).
    // Both now land in the same workspace.
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalytics.outputs.resourceId
      }
    ]
  }
  dependsOn: [rgPlatform]
}

// ------------------------------------------------------------------ Key Vault (mls-rg-platform)

module keyVault 'br/public:avm/res/key-vault/vault:0.14.0' = {
  name: 'l6-kv'
  scope: resourceGroup(rgPlatformName)
  params: {
    name: kvName
    location: location
    tags: tagsPlatform
    sku: 'standard' // [derived] AVM defaults to premium; standard suffices, HSM not needed
    enableRbacAuthorization: true // RBAC mode (Track E requirement)
    enableSoftDelete: true // soft-delete on (Track E requirement)
    softDeleteRetentionInDays: 90
    // [derived] Purge protection off: the G3 full-teardown path must be able to
    // purge, and the standard kill/rebuild cycle recovers the soft-deleted vault
    // via createMode=recover instead (L6 playbook rollback note).
    enablePurgeProtection: false
    createMode: keyVaultCreateMode
    // F9 (compliance/findings/2026-08-26-prepublication-review.md#f9, Task 13):
    // the vault holds the estate's only real credentials — the Direct Line
    // secret and mcp-auth-token — and access to them (AuditEvent) was entirely
    // unlogged. No categories specified: per the AVM diagnosticSettingFullType
    // contract, omitting both logCategoriesAndGroups and metricCategories
    // configures all logs and metrics by default.
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalytics.outputs.resourceId
      }
    ]
  }
  dependsOn: [rgPlatform]
}

// ------------------------------------------------------------------ Azure SQL serverless (mls-rg-data)

module sqlServer 'br/public:avm/res/sql/server:0.22.0' = {
  name: 'l6-sql'
  scope: resourceGroup(rgDataName)
  params: {
    name: sqlName
    location: location
    tags: tagsSqlServer
    // THE CONTAINED-USER GRANT NO LONGER NEEDS THIS IDENTITY, AND THE IDENTITY STAYS
    // ANYWAY (F172). This comment used to say the identity was REQUIRED, because
    // `CREATE USER ... FROM EXTERNAL PROVIDER` makes the SQL engine resolve the principal
    // in Microsoft Graph: a USER running it is impersonated with delegated permissions -
    // which is why it worked by hand and never in CI - while an application cannot
    // impersonate another application, so for a service principal the engine falls back
    // to THE SERVER'S OWN identity, which must then hold directory read (F112).
    //
    // That route was abandoned because the grant behind it could not survive a rebuild.
    // The directory-read assignment was documented as "one assignment, once per tenant",
    // and it is not: L6 creates this server in the data RG, teardown deletes that RG, the
    // SYSTEM-ASSIGNED identity below dies with it and returns under the same NAME with a
    // NEW principal id, and Entra drops the dangling role assignment along with the
    // deleted service principal. Read 2026-09-03 after the re-baseline rebuild: the audit
    // log records the grant at 2026-09-01T12:23:23Z against a principal that no longer
    // exists, the current server identity holds zero directory role assignments, and the
    // Directory Readers role has zero members. data-api answered 502 on every SQL-backed
    // route four layers later and L7's V7.6 is what caught it.
    //
    // The deploy path now supplies the SID explicitly - `Set-SeedWorkloadUser` in
    // data/seed/sql/sql-seed.psm1 issues `CREATE USER ... WITH SID = <the identity's
    // clientId>, TYPE = E` and reads it back - so nothing asks Graph, and no tenant-level
    // privilege is needed anywhere.
    //
    // systemAssigned STAYS TRUE for three reasons, none of them "it is required": a
    // system-assigned identity costs nothing; it is the principal the EXTERNAL PROVIDER
    // fallback documented in docs/runbooks/g0-bootstrap.md step 6 needs, if anyone ever
    // chooses that route for a principal whose clientId they do not have; and removing an
    // identity from a running server is a change with its own blast radius - anything
    // already granted to it stops resolving - which is not worth taking on to delete a
    // line that does no harm.
    managedIdentities: {
      systemAssigned: true
    }
    // Entra-only authentication — no SQL passwords anywhere (CLAUDE.md rule 5).
    administrators: empty(sqlAadAdminObjectId)
      ? null
      : {
          azureADOnlyAuthentication: true
          administratorType: 'ActiveDirectory'
          login: sqlAadAdminLogin
          principalType: sqlAadAdminPrincipalType
          sid: sqlAadAdminObjectId
        }
    minimalTlsVersion: '1.2'
    // [derived] Apps reach SQL over the public endpoint (no VNet in the
    // consumption-only design); 0.0.0.0-0.0.0.0 is the ARM idiom for
    // "allow Azure services" so Container Apps can connect.
    firewallRules: [
      {
        name: 'AllowAllWindowsAzureIps'
        startIpAddress: '0.0.0.0'
        endIpAddress: '0.0.0.0'
      }
    ]
    // F9 (compliance/findings/2026-08-26-prepublication-review.md#f9, Task 13):
    // the AVM default is `{ state: 'Enabled' }` with NEITHER
    // storageAccountResourceId NOR isAzureMonitorTargetEnabled — auditing that
    // is nominally on and writes nowhere, and per AVM's own auditSettingsType
    // doc ("state is Enabled, storageEndpoint or isAzureMonitorTargetEnabled
    // are required") may hard-fail the deployment outright. This is
    // server-level (Microsoft.Sql/servers/auditingSettings), so it covers
    // every database under this server, the one serverless database included.
    auditSettings: {
      state: 'Enabled'
      isAzureMonitorTargetEnabled: true
    }
    databases: [
      {
        name: sqlDbName
        tags: tagsSqlDb
        // Serverless general purpose: auto-pause 60 min, 0.5–2 vCores —
        // values the L6 audit (V6.1) asserts field-for-field.
        sku: {
          name: 'GP_S_Gen5'
          tier: 'GeneralPurpose'
          family: 'Gen5'
          capacity: sqlMaxCapacity
        }
        autoPauseDelay: sqlAutoPauseDelayMinutes
        minCapacity: sqlMinCapacity
        availabilityZone: -1 // no zone pinning in the single-region demo
        zoneRedundant: false
        maxSizeBytes: 34359738368 // 32 GiB
        // F9: diagnostic logs (SQLInsights, QueryStoreRuntimeStatistics,
        // Errors, DatabaseWaitStatistics, Timeouts, Blocks, Deadlocks, ...)
        // are emitted by Microsoft.Sql/servers/databases, not by the server
        // resource — the sql/server@0.22.0 AVM module has no top-level
        // diagnosticSettings param (verified against the cached module
        // schema); databaseType is where it actually lives.
        diagnosticSettings: [
          {
            workspaceResourceId: logAnalytics.outputs.resourceId
          }
        ]
        // F16 (compliance/findings/2026-08-26-prepublication-review.md#f16, Task 18 —
        // CP-9): neither property was set, so both resolved to whatever the platform
        // default happened to be on a given deployment day rather than a decision this
        // template made, documented, or the L6 audit (V6.5) verifies. Azure SQL always
        // takes automated backups regardless; pinning these two makes the retention
        // window and the redundancy tier explicit instead of silently inherited. No
        // backupLongTermRetentionPolicy: the data is seeded synthetic data with a
        // deterministic regenerator (data/seed/), not data an LTR vault needs to protect
        // — an adopter holding real data should make that a deliberate addition, not
        // inherit it from this reference template either.
        backupShortTermRetentionPolicy: {
          retentionDays: sqlBackupRetentionDays
        }
        requestedBackupStorageRedundancy: sqlBackupStorageRedundancy
      }
    ]
  }
  dependsOn: [rgData]
}

// ------------------------------------------------------------------ cost-export storage (mls-rg-ops)

module costExportStorage 'br/public:avm/res/storage/storage-account:0.33.0' = {
  name: 'l6-cost-st'
  scope: resourceGroup(rgOpsName)
  params: {
    name: exportStorageName
    location: location
    tags: tagsCostStorage
    skuName: 'Standard_LRS' // cheapest redundancy; exports are reproducible data
    kind: 'StorageV2'
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    // [derived] Entra/RBAC-only data plane: Cost Management exports write via
    // the export's own system-assigned identity. F15 (Task 17,
    // compliance/findings/2026-08-26-prepublication-review.md#f15): the
    // `az costmanagement` CLI extension has no --identity-type flag and pins an API
    // version that hard-requires shared keys, so layer-06-platform.yml creates the
    // export via `az rest` (api-version 2023-08-01, `identity: {type: SystemAssigned}`
    // in the body) and grants that identity's principalId Storage Blob Data
    // Contributor, scoped to the cost-exports container below, once the PUT returns it.
    // Shared keys stay off either way (L6 playbook failure mode 3 assumes the RBAC path).
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    // F9 (compliance/findings/2026-08-26-prepublication-review.md#f9, Task 13):
    // the storage-account resource type only emits Transaction metrics — blob
    // data-plane logs (StorageRead/StorageWrite/StorageDelete) are emitted by
    // the blob SERVICE sub-resource (verified against the cached
    // storage-account@0.33.0 AVM module schema: the top-level
    // diagnosticSettings param is diagnosticSettingMetricsOnlyType, no
    // logCategoriesAndGroups; blobServices.diagnosticSettings is the full
    // type that carries logs), so both are wired.
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalytics.outputs.resourceId
      }
    ]
    blobServices: {
      diagnosticSettings: [
        {
          workspaceResourceId: logAnalytics.outputs.resourceId
        }
      ]
      containers: [
        {
          name: 'cost-exports' // container name pinned by the L6 audit (V6.3)
          publicAccess: 'None'
        }
      ]
    }
  }
  dependsOn: [rgOps]
}

// ------------------------------------------------------------------ cost-ingest FinOps leg (mls-rg-ops)
//
// F19 (compliance/findings/2026-08-26-prepublication-review.md#f19), and with it
// the SEVENTH and last of F13's documented workload RBAC grants.
//
// WHAT WAS WRONG. `apps/cost-ingest` is a complete, tested Azure Functions app —
// host.json, a blob-triggered handler, 84 unit tests — that appeared in no Bicep
// anywhere. .github/workflows/infra-up.yml:31 said it "deploys inside
// layer-06-platform.yml alongside the export wiring it consumes"; it did not, and
// so it had no Function App, no identity, and no way to be granted the Storage
// Blob Data Reader role F13 lists against it. Three controls (3.1.1, 3.1.2,
// 3.1.5) named that missing grant as their last open contributor. This block is
// the thing that was missing; the workflow steps that publish its code and
// subscribe it to the container are in layer-06-platform.yml, and the Fabric
// grant it needs is in layer-07-apps.yml (see each for why it lives there).
//
// ---------------------------------------------------------------------------
// PLAN CHOICE: FLEX CONSUMPTION (FC1). NOT a taste call — two hard constraints
// intersect on exactly one plan.
//
//  1. NO STORED CREDENTIAL (CLAUDE.md hard rule 5, restated by the app itself in
//     apps/cost-ingest/src/config.ts: "NONE of them is a credential… If a setting
//     ever appears here that looks like a secret, that is the bug"). A Functions
//     host needs an `AzureWebJobsStorage` connection. Microsoft's support matrix
//     (learn.microsoft.com/azure/azure-functions/manage-connections, "Managed
//     identity support for AzureWebJobsStorage varies by hosting plan") gives
//     Flex Consumption "Full support / None (no Azure Files)"; the legacy
//     Consumption and Elastic Premium plans support managed identity for blobs,
//     queues and tables but still require `WEBSITE_AZUREFILESCONNECTIONSTRING` —
//     a shared-key connection string — which their own guidance says to hide in
//     Key Vault. Hiding a credential is not the same as not having one. Flex
//     Consumption uses no Azure Files at all, so there is no such setting.
//  2. ~$0 IDLE against the $200 / 30-day credit. Flex Consumption bills
//     per-execution GB-seconds plus a per-million-execution charge, and bills
//     nothing for an idle app unless `alwaysReady` instances are configured —
//     which is why `scaleAndConcurrency` below carries no `alwaysReady` block at
//     all. One Cost Management export a day is ~30 invocations a month of a few
//     seconds each: comfortably inside the monthly free grant, and $0 on the days
//     nothing lands. The Dedicated (App Service) plan is the only other plan with
//     full managed-identity host storage, and its cheapest usable tier (B1) bills
//     ~$13/month whether or not anything runs — 6.5% of the entire credit,
//     permanently, for 30 executions. Elastic Premium (EP1, ~$150/month) is not
//     in the conversation.
//
// THE COST OF THAT CHOICE, stated rather than buried: the Flex Consumption plan
// supports ONLY the Event Grid-based blob trigger, never the polling one
// (learn.microsoft.com/azure/azure-functions/functions-bindings-storage-blob-trigger:
// "the Flex Consumption plan supports only the event-based Blob storage
// trigger"). apps/cost-ingest/src/functions/cost-ingest.ts therefore declares
// `source: 'EventGrid'`, this template creates the Event Grid system topic on the
// cost-export account below, and layer-06-platform.yml creates the event
// subscription after the app exists. That last step cannot be Bicep: the
// subscription's webhook URL embeds the app's `blobs_extension` system key, which
// only exists once the site does, and resolving it here with `listKeys` would
// (a) fail `az deployment sub what-if` outright on a fresh estate, since the site
// does not exist yet at what-if time, and (b) render a live system key into the
// what-if output of a PUBLIC repository's workflow log — F4's exact failure mode.
// Same shape, same reasoning as the Cost Management export wiring in that
// workflow (F15): configuration whose only input is born at deploy time.
// ---------------------------------------------------------------------------
//
// WHY A SECOND, SEPARATE STORAGE ACCOUNT for the Functions runtime rather than
// reusing costExportStorage above. The Functions host needs ACCOUNT-WIDE blob,
// queue and table access to its AzureWebJobsStorage account (it owns
// `azure-webjobs-hosts`, lease blobs, the poison queue and the diagnostic-events
// table). Consolidating would mean granting the cost-ingest identity Storage Blob
// Data Owner on the account that holds the Cost Management exports — at which
// point the container-scoped Storage Blob Data Reader grant that F13 asks for,
// and that this block makes, would be decorative: the identity would already hold
// Owner-class blob access to the same container by another route. A second empty
// Standard_LRS account is cents a month (a few MB of host bookkeeping plus the
// deployment package; no export data ever lands in it) and is what keeps the
// narrow grant real. It dies with mls-rg-ops like everything else here.

module costIngestIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'l6-cost-ingest-uami'
  scope: resourceGroup(rgOpsName)
  params: {
    name: costIngestIdentityName
    location: location
    tags: tagsCostIngest
  }
  dependsOn: [rgOps]
}

// Runtime/deployment storage for the Functions host — see the block header for
// why this is not costExportStorage. Same hardened posture as that account:
// RBAC-only data plane (allowSharedKeyAccess:false, which Flex Consumption
// supports precisely because it authenticates with the managed identity), no
// public blob access, TLS 1.2 floor, diagnostics to the same workspace.
module functionRuntimeStorage 'br/public:avm/res/storage/storage-account:0.33.0' = {
  name: 'l6-func-st'
  scope: resourceGroup(rgOpsName)
  params: {
    name: functionRuntimeStorageName
    location: location
    tags: tagsCostIngest
    skuName: 'Standard_LRS' // cheapest redundancy; holds no data, only host bookkeeping
    kind: 'StorageV2'
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false // no connection string exists for anything to leak
    minimumTlsVersion: 'TLS1_2'
    // THE FIREWALL ON THIS ACCOUNT BLOCKED ITS OWN FUNCTION DEPLOYMENTS (F119).
    //
    // `networkAcls` was never declared, so the AVM module applied its own secure
    // default - defaultAction: Deny, bypass: AzureServices - and nothing said so.
    // Flex Consumption's package upload is performed by the platform's deployment
    // service against the blob endpoint, and the AzureServices bypass does NOT
    // cover it, so every zip publish to both Function Apps failed:
    //
    //   InaccessibleStorageException: Failed to access storage account for
    //   deployment: BlobUploadFailedException: ... 403
    //
    // invisibly, because both publish steps carry continue-on-error. L6 signed off
    // green while neither Function held any code.
    //
    // RESOURCE INSTANCE RULES WERE TRIED FIRST AND AZURE REFUSED THEM:
    //
    //   InvalidValuesForRequestParameters: Values for request parameters are
    //   invalid: networkAcls.resourceAccessRules[*].resourceId
    //
    // That list does not accept Microsoft.Web/sites. The idea was sound and the
    // platform does not support it, which is recorded here so nobody spends the
    // deploy discovering it a second time.
    //
    // SO: defaultAction Allow, AND THE REASON IT IS DEFENSIBLE IS TWO LINES ABOVE.
    // `allowSharedKeyAccess: false` means no account key exists, for anyone, ever;
    // `allowBlobPublicAccess: false` means nothing is anonymous. Every request to
    // this account must therefore carry an Entra token AND hold an RBAC data role,
    // and exactly four principals do. The network ACL was never the control that
    // protected this account - RBAC is - which is why the operator running this
    // repository is refused today even from an allowed network.
    //
    // BE CLEAR ABOUT WHAT THIS GIVES UP: defence in depth. A stolen token that
    // would previously have needed the right network position now needs only the
    // token. That is a real reduction and it buys the only deployment path Flex
    // Consumption offers without a VNet, private endpoints and a NAT gateway -
    // roughly $40/month of infrastructure for a demo whose entire estate is a
    // fraction of that, and an ungated spend increase (G2) besides.
    //
    // This account holds host bookkeeping and deployment packages. No estate data
    // is here; the lakehouse and Azure SQL hold that, and neither is affected.
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalytics.outputs.resourceId
      }
    ]
    blobServices: {
      diagnosticSettings: [
        {
          workspaceResourceId: logAnalytics.outputs.resourceId
        }
      ]
      containers: [
        {
          // Flex Consumption's deployment package lands here, written by the
          // app's own user-assigned identity (functionAppConfig.deployment
          // below). Created by this template rather than by the platform so the
          // container exists before the first publish and so its access level is
          // declared, not defaulted.
          name: functionDeploymentContainerName
          publicAccess: 'None'
        }
      ]
    }
  }
  dependsOn: [rgOps]
}

module costIngestPlan 'br/public:avm/res/web/serverfarm:0.7.0' = {
  name: 'l6-cost-ingest-plan'
  scope: resourceGroup(rgOpsName)
  params: {
    name: costIngestPlanName
    location: location
    tags: tagsCostIngest
    // FC1 is the Flex Consumption SKU; the AVM module maps it to
    // sku: { name: 'FC1', tier: 'FlexConsumption' } and omits `capacity`, which
    // that tier rejects (verified against the cached
    // avm/res/web/serverfarm@0.7.0 module).
    skuName: 'FC1'
    kind: 'functionapp'
    reserved: true // Flex Consumption is Linux-only; the module's default derives from kind == 'linux', which is not this kind
    zoneRedundant: false // no zone pinning anywhere in this single-region demo
  }
  dependsOn: [rgOps]
}

module costIngestFunctionApp 'br/public:avm/res/web/site:0.24.0' = {
  name: 'l6-cost-ingest-func'
  scope: resourceGroup(rgOpsName)
  params: {
    name: costIngestFunctionAppName
    location: location
    tags: tagsCostIngest
    kind: 'functionapp,linux'
    serverFarmResourceId: costIngestPlan.outputs.resourceId
    httpsOnly: true
    clientAffinityEnabled: false // ARR affinity is meaningless for an event-driven app and is not a Flex Consumption concept
    // USER-ASSIGNED, for the same reason data-api's and mcp-tools' identities are
    // (infra/bicep/apps/main.bicep): the grants this principal needs are issued
    // from three different places — the container grant below, the
    // runtime-account grants below, and a Fabric workspace role assigned over
    // REST from layer-07-apps.yml — so the principal must be nameable and
    // grantable independently of the app's own lifecycle. It is also mandatory
    // here for a second reason a system-assigned identity could not satisfy:
    // Flex Consumption's deployment-storage authentication needs an identity
    // RESOURCE ID at site-creation time, which a system-assigned identity does
    // not have until after the site exists.
    managedIdentities: {
      userAssignedResourceIds: [costIngestIdentity.outputs.resourceId]
    }
    // The module's siteConfig default is { alwaysOn: true, minTlsVersion: '1.2',
    // ftpsState: 'FtpsOnly' }. alwaysOn is invalid on a dynamic plan and is the
    // literal opposite of this estate's scale-to-zero posture, so it is replaced
    // rather than extended. FTP/FTPS publishing is disabled outright: the only
    // deployment path is the identity-authenticated zip push in
    // layer-06-platform.yml, and an enabled FTPS endpoint is a
    // credential-bearing second way in that nothing uses.
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
    }
    // Public network access stays enabled because the Event Grid subscription
    // delivers over the public webhook endpoint (/runtime/webhooks/blobs). There
    // is no HTTP-triggered function in this app, so nothing else is reachable.
    publicNetworkAccess: 'Enabled'
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${functionRuntimeStorage.outputs.primaryBlobEndpoint}${functionDeploymentContainerName}'
          authentication: {
            // NOT a shared key and NOT a SAS: the platform reads the deployment
            // package as this app's own user-assigned identity, which is why
            // functionRuntimeStorage can keep allowSharedKeyAccess:false.
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: costIngestIdentity.outputs.resourceId
          }
        }
      }
      scaleAndConcurrency: {
        // NO `alwaysReady` BLOCK. Always-ready instances are the only thing on
        // Flex Consumption that bills while idle; omitting the block is what
        // makes the idle cost $0, and adding one would be an un-gated spend
        // increase (G2), not a tuning change.
        instanceMemoryMB: costIngestInstanceMemoryMb
        maximumInstanceCount: costIngestMaximumInstanceCount
      }
      runtime: {
        name: 'node'
        version: costIngestNodeVersion
      }
    }
    configs: [
      {
        name: 'appsettings'
        // Emits AzureWebJobsStorage__accountName / __blobServiceUri /
        // __queueServiceUri / __tableServiceUri instead of a connection string.
        // The __credential and __clientId halves that bind those to THIS
        // user-assigned identity are set explicitly below — the module does not
        // emit them, and without them the host would look for a system-assigned
        // identity that does not exist.
        storageAccountResourceId: functionRuntimeStorage.outputs.resourceId
        storageAccountUseIdentityAuthentication: true
        // The template is the whole truth about this app's settings. The
        // module's default is to `list()` the site's current settings and merge
        // them in, which (a) would carry hand-edits forward across deployments —
        // the opposite of what IaC is for — and (b) is a `list()` against a site
        // that does not exist yet on a first deploy.
        retainCurrentAppSettings: false
        properties: {
          // -- host storage: managed identity, no key, no connection string ----
          AzureWebJobsStorage__credential: 'managedidentity'
          AzureWebJobsStorage__clientId: costIngestIdentity.outputs.clientId
          // -- the blob trigger's own identity-based connection ---------------
          // `connection: 'CostExports'` in src/functions/cost-ingest.ts resolves
          // this prefix. It points at the COST-EXPORT account — a different
          // account from AzureWebJobsStorage above — which is the whole reason
          // the trigger names a connection at all instead of defaulting to host
          // storage.
          CostExports__blobServiceUri: costExportStorage.outputs.primaryBlobEndpoint
          CostExports__credential: 'managedidentity'
          CostExports__clientId: costIngestIdentity.outputs.clientId
          // -- application settings (apps/cost-ingest/src/config.ts) ----------
          // None of these is a credential; the app's own header says so, and this
          // template is where that claim has to stay true.
          COST_EXPORT_CONTAINER: costExportContainerName
          FABRIC_WORKSPACE: fabricWorkspaceResolved
          FABRIC_LAKEHOUSE: fabricLakehouseResolved
          LAKEHOUSE_COST_PATH: lakehouseCostPath
          // Binds DefaultAzureCredential — which src/lakehouse.ts uses to mint
          // the OneLake token — to this identity rather than to an ambient one.
          // Same setting, same purpose as apps/main.bicep's AZURE_CLIENT_ID on
          // data-api and mcp-tools.
          AZURE_CLIENT_ID: costIngestIdentity.outputs.clientId
        }
      }
    ]
    // F9's discipline applied to the newest resource in the estate: the
    // Function's own logs go to the same workspace everything else does.
    // Application Insights is deliberately NOT wired: F4 disabled local
    // ingestion auth on that component, so an App Insights connection here would
    // additionally need a Monitoring Metrics Publisher grant on it and an
    // APPLICATIONINSIGHTS_AUTHENTICATION_STRING — a fourth role assignment for an
    // app whose whole output is 30 invocations a month that this diagnostic
    // setting already records.
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalytics.outputs.resourceId
      }
    ]
  }
  dependsOn: [rgOps]
}

// ---- the seventh F13 grant --------------------------------------------------
// CONTAINER SCOPE, NOT ACCOUNT SCOPE. The Function reads the export and writes
// nowhere in this account, so Storage Blob Data Reader on the `cost-exports`
// container is the narrowest grant that works. See
// modules/blob-container-role.bicep for why that needs a raw role assignment.
module costIngestExportReaderGrant 'modules/blob-container-role.bicep' = {
  name: 'l6-cost-ingest-export-reader-grant'
  scope: resourceGroup(rgOpsName)
  params: {
    storageAccountName: costExportStorage.outputs.name
    containerName: costExportContainerName
    principalId: costIngestIdentity.outputs.principalId
    // 'Storage Blob Data Reader' — read and list blobs and containers; no write, no delete, no ACL change (built-in role, stable GUID; verified against learn.microsoft.com/azure/role-based-access-control/built-in-roles/storage).
    roleDefinitionId: '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
  }
}

// ---- Functions host requirements, on the RUNTIME account only ---------------
// Microsoft's documented minimum for an identity-based AzureWebJobsStorage
// connection is Storage Blob Data Owner on the account, plus Storage Queue Data
// Contributor for the blob extension's poison queue and Storage Table Data
// Contributor for the host's diagnostic events
// (learn.microsoft.com/azure/azure-functions/manage-connections → "Grant
// permissions to an identity"). Every one of these binds to
// functionRuntimeStorage — the empty account created above — and NONE of them
// touches the cost-export account. Storage Account Contributor, which that same
// table lists under host-required storage for the blob extension, is deliberately
// NOT granted: it is a control-plane role whose purpose is letting the POLLING
// trigger create containers and queues it does not have, and this app does not
// poll — its trigger is Event Grid-sourced and the one container it deploys into
// is declared in this template.
var costIngestRuntimeStorageGrants = [
  {
    label: 'blob-data-owner'
    // 'Storage Blob Data Owner' — full blob data access including POSIX ACLs; Microsoft's documented minimum for AzureWebJobsStorage with an identity (built-in role, stable GUID).
    roleDefinitionId: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  }
  {
    label: 'queue-data-contributor'
    // 'Storage Queue Data Contributor' — read, write and delete queue messages; the blob extension writes poison-blob receipts to a queue in the host account (built-in role, stable GUID).
    roleDefinitionId: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  }
  {
    label: 'table-data-contributor'
    // 'Storage Table Data Contributor' — read, write and delete table entities; where the host persists diagnostic events when the app cannot start (built-in role, stable GUID).
    roleDefinitionId: '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
  }
]

module costIngestRuntimeStorageGrant 'modules/storage-account-role.bicep' = [
  for grant in costIngestRuntimeStorageGrants: {
    name: 'l6-cost-ingest-rt-${grant.label}'
    scope: resourceGroup(rgOpsName)
    params: {
      storageAccountName: functionRuntimeStorage.outputs.name
      principalId: costIngestIdentity.outputs.principalId
      roleDefinitionId: grant.roleDefinitionId
    }
  }
]

// =============================================================================
// DIRECT LINE TOKEN FUNCTION (F118)
// =============================================================================
//
// The Ask tab's missing link, and it was missing in the most complete sense:
// `apps/directline-token` has a README, a package, source, tests, a workspace
// membership and its own Dependabot entry, and `grep -r directline infra/`
// returned exactly one hit - in a Copilot Studio markdown file. Nothing declared
// it, no workflow built or deployed it, and no environment pointed at it. The
// tab could never have worked, and said so in a message blaming "local mode"
// while running in the deployed estate.
//
// WHAT IT IS. One anonymous HTTP endpoint (`POST /api/directline/token`) that
// exchanges the Copilot Studio Direct Line SECRET for a short-lived,
// conversation-scoped TOKEN. The browser receives the token and never the
// secret. That exchange has to happen server-side or the secret ships to every
// visitor, which is the entire reason this component exists.
//
// WHY ITS OWN FUNCTION rather than a route on mcp-tools: apps/directline-token's
// README argues it at length and the argument holds - folding it in would force
// the tools server public, and the Direct Line secret would then share a blast
// radius with the lakehouse read credentials. Its own site also redeploys when
// the channel rotates without touching the tool layer.
//
// COST: Flex Consumption with no `alwaysReady` block, exactly like cost-ingest.
// Always-ready instances are the only thing on this tier that bills while idle,
// so omitting the block is what keeps idle cost at $0 - and adding one would be
// an ungated spend increase (G2), not a tuning change.
//
// EMPTY SECRET IS A SUPPORTED DEPLOYMENT, and is the default. The agent has not
// been published yet, so there is no Direct Line channel and no secret to point
// at. The Function deploys anyway and answers with a typed error: an endpoint
// that exists and says "not configured" is honest, where a half-wired secret
// reference would fail the whole site at start-up and take the estate with it.
// Same posture, same reasoning, as MLS_GITHUB_TOKEN in the apps layer (F116).
module directlineIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'l6-directline-uami'
  scope: resourceGroup(rgOpsName)
  params: {
    name: directlineIdentityName
    location: location
    tags: tagsDirectline
  }
  dependsOn: [rgOps]
}

module directlinePlan 'br/public:avm/res/web/serverfarm:0.7.0' = {
  name: 'l6-directline-plan'
  scope: resourceGroup(rgOpsName)
  params: {
    name: directlinePlanName
    location: location
    tags: tagsDirectline
    // FC1, and its own plan rather than sharing cost-ingest's: Flex Consumption
    // bills per app on its own scaling profile, so a second plan costs nothing
    // extra while keeping a browser-facing endpoint off the same scaling
    // envelope as a nightly blob-triggered ingest.
    skuName: 'FC1'
    kind: 'functionapp'
    reserved: true // Flex Consumption is Linux-only
    zoneRedundant: false
  }
  dependsOn: [rgOps]
}

// Key Vault Secrets User for the Function's identity, so it can resolve the
// Direct Line secret at runtime. Only deployed when a secret is actually named:
// a standing grant for a secret nobody reads is access with no purpose.
module directlineKvGrant '../apps/modules/key-vault-secrets-user-role.bicep' = if (!empty(directlineSecretName)) {
  name: 'l6-directline-kv-grant'
  scope: resourceGroup(rgPlatformName)
  params: {
    keyVaultName: keyVault.outputs.name
    principalId: directlineIdentity.outputs.principalId
  }
}

// Key Vault Secrets User for the DEPLOYER, so L8's eval can read the Direct Line
// secret and actually evaluate the agent (F183). Same two guards as the grant above:
// only when a secret is named, and only when a principal is supplied. Before this,
// the eval's read returned Forbidden on every run, the step reported the secret
// ABSENT, and V8.2/V8.4/V8.5 skipped on the artifact that was never produced.
module directlineDeployerKvGrant '../apps/modules/key-vault-secrets-user-role.bicep' = if (!empty(directlineSecretName) && !empty(deployerPrincipalId)) {
  name: 'l6-directline-kv-grant-deployer'
  scope: resourceGroup(rgPlatformName)
  params: {
    keyVaultName: keyVault.outputs.name
    principalId: deployerPrincipalId
  }
}

module directlineRuntimeStorageGrant 'modules/storage-account-role.bicep' = [
  for grant in costIngestRuntimeStorageGrants: {
    name: 'l6-directline-rt-${grant.label}'
    scope: resourceGroup(rgOpsName)
    params: {
      storageAccountName: functionRuntimeStorage.outputs.name
      principalId: directlineIdentity.outputs.principalId
      roleDefinitionId: grant.roleDefinitionId
    }
  }
]

module directlineFunctionApp 'br/public:avm/res/web/site:0.24.0' = {
  name: 'l6-directline-func'
  scope: resourceGroup(rgOpsName)
  dependsOn: [rgOps, directlineRuntimeStorageGrant]
  params: {
    name: directlineFunctionAppName
    location: location
    tags: tagsDirectline
    kind: 'functionapp,linux'
    serverFarmResourceId: directlinePlan.outputs.resourceId
    httpsOnly: true
    clientAffinityEnabled: false
    // User-assigned for the same reason cost-ingest's is: Flex Consumption needs
    // an identity RESOURCE ID at site-creation time to authenticate deployment
    // storage, which a system-assigned identity does not have until the site
    // exists.
    managedIdentities: {
      userAssignedResourceIds: [directlineIdentity.outputs.resourceId]
    }
    // WITHOUT THIS LINE THE KEY VAULT REFERENCE BELOW RESOLVES TO NOTHING, AND
    // NOTHING ANYWHERE SAYS SO (F122). A `@Microsoft.KeyVault(...)` app setting is
    // resolved by the platform using the site's SYSTEM-assigned identity unless the
    // site names another one here. This site has only a user-assigned identity - for
    // the Flex Consumption reason directly above - so the platform looked for a
    // system-assigned identity, found none, and left the setting unresolved with
    // `status: MSINotEnabled`.
    //
    // The failure is invisible from every angle a reader would normally check. The
    // app setting is present, spelled correctly, and points at a real secret; the
    // role assignment exists; the identity exists; the deploy is green and so is the
    // whole layer. The Function simply receives an empty DIRECTLINE_SECRET and
    // reports the channel as not configured - which is indistinguishable from the
    // honest "agent not published yet" state this template deliberately supports.
    // Only /config/configreferences/appsettings tells the truth, which is why V6.8
    // reads it: assert that the reference RESOLVES, not that the setting is present.
    keyVaultAccessIdentityResourceId: directlineIdentity.outputs.resourceId
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      // THE PLATFORM OWNS THE PREFLIGHT, AND THAT IS WHY THIS EXISTS NOW (F136).
      //
      // This block used to say: "CORS is enforced in the function itself against
      // DIRECTLINE_ALLOWED_ORIGINS ... Configuring the platform CORS list as well
      // would give two places to be wrong and one of them silent." That reasoning
      // held for exactly as long as the request was a SIMPLE one - a POST with no
      // custom headers never triggers a preflight, so the function's own handler
      // saw every request and its CORS headers were the only ones that mattered.
      //
      // Forwarding the caller's Easy Auth token added an `Authorization` header,
      // which makes the request PREFLIGHTED. The Functions host answers OPTIONS
      // ITSELF, before any function code runs, and with no platform list it replies
      // 204 with no CORS headers at all - so the browser rejected it with "Failed to
      // fetch" while the function's own, correct, allow-list sat one layer below,
      // never consulted. The POST underneath still returned the right headers, which
      // is what made it confusing: CORS worked for every request except the one the
      // browser had to ask permission for first.
      //
      // ONE SOURCE STILL. Both layers read the same derived origin - the platform
      // for the preflight it owns, the function for the response it owns - so the
      // "two places to be wrong" concern is met by making them the same value rather
      // than by leaving one unset.
      cors: {
        allowedOrigins: split(directlineOrigins, ',')
        supportCredentials: false
      }
    }
    // PUBLIC BY NECESSITY, not by oversight: the caller is a browser on the
    // public internet. It is anonymous by design too - the endpoint mints a
    // conversation-scoped token and holds nothing a caller could steal beyond
    // one conversation, which is why the secret never leaves this process.
    publicNetworkAccess: 'Enabled'
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${functionRuntimeStorage.outputs.primaryBlobEndpoint}${functionDeploymentContainerName}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: directlineIdentity.outputs.resourceId
          }
        }
      }
      scaleAndConcurrency: {
        // NO alwaysReady block. See the header: that is the $0 idle guarantee.
        instanceMemoryMB: 512
        maximumInstanceCount: 40
      }
      runtime: {
        name: 'node'
        version: costIngestNodeVersion
      }
    }
    configs: [
      {
        name: 'appsettings'
        storageAccountResourceId: functionRuntimeStorage.outputs.resourceId
        storageAccountUseIdentityAuthentication: true
        retainCurrentAppSettings: false
        properties: union(
          {
            AzureWebJobsStorage__credential: 'managedidentity'
            AzureWebJobsStorage__clientId: directlineIdentity.outputs.clientId
            AZURE_CLIENT_ID: directlineIdentity.outputs.clientId
            DIRECTLINE_ALLOWED_ORIGINS: directlineOrigins
            DIRECTLINE_USER_TENANT_ID: directlineUserTenantId
            DIRECTLINE_USER_AUDIENCE: directlineUserAudience
          },
          // A Key Vault REFERENCE, not a value: the secret is resolved by the
          // platform at start-up using this app's identity, so it never becomes
          // a template parameter, a deployment-history entry, or a what-if log
          // line in what is a public repository.
          empty(directlineSecretName)
            ? {}
            : {
                DIRECTLINE_SECRET: '@Microsoft.KeyVault(SecretUri=${keyVault.outputs.uri}secrets/${directlineSecretName})'
              }
        )
      }
    ]
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalytics.outputs.resourceId
      }
    ]
  }
}

// ---- Event Grid system topic on the cost-export account ---------------------
// The declarative half of the Event Grid-based blob trigger. The SUBSCRIPTION
// that points at the Function's webhook is created by layer-06-platform.yml,
// because its endpoint URL embeds a system key that does not exist until the
// site does — see this block's header for why resolving that key here would both
// break `what-if` and print a live key into a public workflow log. Free at this
// volume: Event Grid's first 100,000 operations a month cost nothing, and one
// daily export is ~30.
module costExportSystemTopic 'br/public:avm/res/event-grid/system-topic:0.7.0' = {
  name: 'l6-cost-evgt'
  scope: resourceGroup(rgOpsName)
  params: {
    name: costExportSystemTopicName
    location: location
    tags: tagsCostIngest
    source: costExportStorage.outputs.resourceId
    topicType: 'Microsoft.Storage.StorageAccounts'
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalytics.outputs.resourceId
      }
    ]
  }
  dependsOn: [rgOps]
}

// ------------------------------------------------------------------ alerting (mls-rg-platform)
//
// F17 (compliance/findings/2026-08-26-prepublication-review.md#f17, Task 19): this is
// the second half of F9 -- collection versus reaction. F9/Task 13 (above) wired
// diagnosticSettings for Key Vault and the SQL database to the Log Analytics
// workspace; nothing was subscribed to any of it. Two rules, not a monitoring suite
// (this task's own scope-discipline instruction), both named verbatim by F17's own
// Fix text ("Key Vault access-denied spikes, SQL failed-login spikes"):
//   - Key Vault AuditEvent denied-result spike: the vault holds the Direct Line
//     secret and mcp-auth-token (F9's own comment above); httpStatusCode_d >= 300 in
//     the AzureDiagnostics table (the destination diagnosticSettings uses by default
//     here -- no logAnalyticsDestinationType override anywhere in this template) is
//     the field Microsoft's own "who's accessing your vault" guidance and Key Vault
//     logging samples both use for denied/failed requests.
//   - Azure SQL failed-login spike: succeeded_s == "false" in SQLSecurityAuditEvents,
//     the field the auditSettings block above (isAzureMonitorTargetEnabled) actually
//     populates, against the Entra-only server F13's workload grants authenticate
//     through.
//
// NOT covered by either rule, and worth being explicit about rather than implying
// broader coverage: F1 (unauthenticated data-api), F2 (inert MCP auth gate) and F3
// (fail-open Direct Line token) are app-layer authentication bypasses -- an
// unauthenticated caller reaches the app, and the app's OWN already-privileged
// managed identity then talks to Key Vault and SQL successfully. There is no
// access-denied event and no failed login in that path; the platform sees a
// legitimate identity doing legitimate things, so neither rule would ever fire for
// it. These two rules detect probing/misconfiguration against Key Vault and SQL
// directly (an unexpected denial, an unexpected failed login) -- a different,
// narrower class of signal than F1-F3's exploit mechanics, justified on its own
// terms by F17's Fix text, not by a claim of covering F1-F3.
//
// Deliberately NOT added, despite being the brief's own suggestion: a third rule for
// Container Apps restart counts. The individual container app resources a meaningful
// restart metric would attach to do not exist at L6 -- they deploy at L7
// (apps/main.bicep) -- so a metricAlert cannot be authored here without an app
// resource id this template never sees, and a log-based proxy at the environment
// scope has no Microsoft-documented column/category contract precise enough to write
// with confidence absent a live workspace to check it against (this task's own
// instruction: ask rather than guess when a rule cannot be expressed without a
// deployed workspace). A cost/usage-spike rule is also deliberately NOT duplicated
// here: Task 17/F15 already added Forecasted (same-day) budget notifications
// precisely to close that gap (scripts/bootstrap/03-budget.ps1); a second,
// KQL-approximated cost alert would be redundant noise against an existing,
// purpose-built mechanism, and an alert nobody tunes is worse than no alert.
//
// Both rules evaluate every 15 minutes. Azure's scheduled-query-rule cost boundary
// sits at 5 minutes -- any evaluation interval >= 5 minutes is flat-priced; only
// sub-5-minute frequencies cost materially more (azure.cn's published price list is
// the clearest public per-tier breakdown). 15 minutes is comfortably inside that
// flat band, not specially discounted within it, and keeps combined cost on the
// order of a dollar or two per month against the $200/30-day credit and the
// workspace's own 1 GB/day ingestion cap (dailyQuotaGb).
//
// The action group's email receiver reuses the same sponsor address
// scripts/bootstrap/03-budget.ps1 already notifies, so cost and security alerting
// share one page-out path -- but 03-budget.ps1 runs at G0, which precedes L6 on every
// infra-up.yml pass, so this action group's resource id does not exist yet at the
// point 03-budget.ps1 first runs. 03-budget.ps1 takes an optional
// -ActionGroupResourceId parameter for exactly this reason: re-running it
// (idempotent) after L6 has deployed adds this action group as a second,
// supplementary contact method on the existing budget notifications, rather than
// this template inventing a same-pass ordering that does not hold.
module alertActionGroup 'br/public:avm/res/insights/action-group:0.3.0' = {
  name: 'l6-alert-ag'
  scope: resourceGroup(rgPlatformName)
  params: {
    name: alertActionGroupName
    groupShortName: 'mlsalerts'
    tags: tagsPlatform
    emailReceivers: empty(alertNotificationEmail)
      ? []
      : [
          {
            name: 'sponsor'
            emailAddress: alertNotificationEmail
            useCommonAlertSchema: true
          }
        ]
  }
  dependsOn: [rgPlatform]
}

module keyVaultDeniedAccessAlert 'br/public:avm/res/insights/scheduled-query-rule:0.3.0' = {
  name: 'l6-alert-kv'
  scope: resourceGroup(rgPlatformName)
  params: {
    name: kvDeniedAccessAlertName
    location: location
    tags: tagsPlatform
    alertDescription: 'F17: Key Vault AuditEvent denied-result spike -- the vault holds the Direct Line secret and mcp-auth-token (F9); unexpected denied responses indicate probing or a misconfigured consumer, not F1-F3-class abuse (those succeed via the app\'s own managed identity and never trip this signal).'
    severity: 2
    enabled: true
    scopes: [logAnalytics.outputs.resourceId]
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    criterias: {
      allOf: [
        {
          query: 'AzureDiagnostics | where ResourceProvider == "MICROSOFT.KEYVAULT" and Category == "AuditEvent" and httpStatusCode_d >= 300'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: [alertActionGroup.outputs.resourceId]
    autoMitigate: true
  }
  dependsOn: [rgPlatform]
}

module sqlFailedLoginAlert 'br/public:avm/res/insights/scheduled-query-rule:0.3.0' = {
  name: 'l6-alert-sql'
  scope: resourceGroup(rgPlatformName)
  params: {
    name: sqlFailedLoginAlertName
    location: location
    tags: tagsPlatform
    alertDescription: 'F17: Azure SQL failed-login spike against the Entra-only server (F13 workload grants) -- succeeded_s == "false" in SQLSecurityAuditEvents.'
    severity: 2
    enabled: true
    scopes: [logAnalytics.outputs.resourceId]
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    criterias: {
      allOf: [
        {
          // columnifexists, not a bare `succeeded_s`: AzureDiagnostics is a dynamic-schema
          // table, so the column does not exist until SQL audit data has actually been
          // ingested. On a fresh workspace ARM rejects the rule at CREATE time with
          // "Failed to resolve column or scalar expression named 'succeeded_s'" - the
          // alert cannot be deployed before the thing it alerts on has happened once,
          // which on a rebuilt estate is always (F52).
          query: 'AzureDiagnostics | where ResourceProvider == "MICROSOFT.SQL" and Category == "SQLSecurityAuditEvents" and columnifexists("succeeded_s", "") == "false"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: [alertActionGroup.outputs.resourceId]
    autoMitigate: true
  }
  dependsOn: [rgPlatform]
}

// ------------------------------------------------------------------ outputs (the L6 layer manifest for the Verifier)
//
// FOUR OUTPUT NAMES BELOW ARE LOAD-BEARING, not cosmetic. verification/layer-06-audit.ps1
// reads `az deployment sub show --name layer-06 --query properties.outputs` and looks the
// manifest up by name:
//
//   sqlDatabaseId             (or sqlDbId / databaseId)                        -> V6.1, V6.4
//   containerAppEnvironmentId (or acaEnvironmentId / managedEnvironmentId)     -> V6.1
//   lawCustomerId             (or logAnalyticsCustomerId / workspaceCustomerId)-> V6.2, and L7's V7.3
//   costExportAccountName     (or exportStorageAccountName / storageAccountName) -> V6.3
//
// The descriptive names this template already published (…ResourceId, …CustomerId,
// costExportStorageResourceId) are NOT in any of those alias lists, so before this block
// existed every one of those criteria resolved to an empty string and failed with "no
// resource id available" — a FAIL caused by the pipeline, not by the estate. Both spellings
// are emitted: the descriptive ones stay because the workflows and the L6 playbook already
// name them, and the four below are what the audit resolves. Renaming either set breaks a
// consumer; add, never rename.

@description('Resource ID of the Log Analytics workspace.')
output logAnalyticsWorkspaceResourceId string = logAnalytics.outputs.resourceId

@description('Log Analytics workspace (customer) ID used by KQL queries (V6.2).')
output logAnalyticsWorkspaceCustomerId string = logAnalytics.outputs.logAnalyticsWorkspaceId

@description('Resource ID of the Container Apps environment (input to L7 app deploys).')
output containerAppsEnvironmentResourceId string = containerAppsEnvironment.outputs.resourceId

@description('Default domain of the Container Apps environment.')
output containerAppsEnvironmentDefaultDomain string = containerAppsEnvironment.outputs.defaultDomain

@description('Key Vault URI. The vault is currently empty — no template or app consumes a secret from it (Copilot Studio amendment, 2026-08-24).')
output keyVaultUri string = keyVault.outputs.uri

@description('Key Vault resource ID.')
output keyVaultResourceId string = keyVault.outputs.resourceId

@description('Fully qualified domain name of the SQL logical server.')
output sqlServerFqdn string = sqlServer.outputs.fullyQualifiedDomainName

@description('Name of the serverless SQL database (V6.1 / V6.4 target).')
output sqlDatabaseName string = sqlDbName

@description('The Ask tab\'s token endpoint. DERIVED from the site name rather than read from the deployed resource, so the control-tower image can be built with it before this Function exists - the build needs the URL at bundle time (VITE_ variables are compile-time), and a value that only appears after deployment could never reach it. Same "derive from naming, do not pass" rule the apps layer uses for platform resource ids.')
output directlineTokenUrl string = 'https://${directlineFunctionAppName}.azurewebsites.net/api/directline/token'

@description('Resource id of the directline-token Function, for the layer-06 workflow to push code to.')
output directlineFunctionAppName string = directlineFunctionAppName

@description('Resource ID of the cost-export storage account.')
output costExportStorageResourceId string = costExportStorage.outputs.resourceId

// --- the four names verification/layer-06-audit.ps1 resolves the manifest by ---

@description('ARM resource ID of the serverless SQL database. V6.1 (`az sql db show --ids`) and V6.4 (auto-pause status) both address the database by id. Composed from naming.bicep rather than read back from the AVM module so the shape is pinned by this template.')
output sqlDatabaseId string = resourceId(
  subscription().subscriptionId,
  rgDataName,
  'Microsoft.Sql/servers/databases',
  sqlName,
  sqlDbName
)

@description('ARM resource ID of the Container Apps environment, under the name V6.1 resolves. Same value as containerAppsEnvironmentResourceId.')
output containerAppEnvironmentId string = containerAppsEnvironment.outputs.resourceId

@description('Log Analytics workspace CUSTOMER id (GUID), under the name V6.2 and L7 V7.3 resolve. Same value as logAnalyticsWorkspaceCustomerId. Not the ARM resource id — `az monitor log-analytics query --workspace` takes the customer id.')
output lawCustomerId string = logAnalytics.outputs.logAnalyticsWorkspaceId

@description('NAME (not resource id) of the cost-export storage account, under the name V6.3 resolves. `az storage blob list --account-name` takes a name; costExportStorageResourceId is the id the export-definition step needs, and the two are not interchangeable.')
output costExportAccountName string = costExportStorage.outputs.name

// --- the cost-ingest FinOps leg (F19), read back by layer-06-platform.yml ---
//
// The workflow resolves every one of these from the deployment manifest rather
// than recomposing them from a prefix, for the same reason the four names above
// exist: "expected values resolve from the Bicep-declared manifest, never from a
// teammate's message" (docs/runbooks/layers/L06.md). None of them is sensitive —
// three resource NAMES and a resource-group name, no ids, no endpoints, no keys.

@description('Name of the cost-ingest Function App. layer-06-platform.yml publishes the zip package to it and builds the Event Grid webhook endpoint from it.')
output costIngestFunctionAppName string = costIngestFunctionApp.outputs.name

@description('Resource group the cost-ingest Function App and its runtime storage live in (mls-rg-ops, alongside the cost-export storage it reads).')
output costIngestResourceGroupName string = rgOpsName

@description('Name of the Event Grid system topic on the cost-export storage account. layer-06-platform.yml adds the blob-created event subscription to it once the Function App exists.')
output costExportSystemTopicName string = costExportSystemTopic.outputs.name

@description('Blob container the Cost Management export writes to and the cost-ingest Function is granted Storage Blob Data Reader on — the subject filter for the event subscription, and the scope of F13\'s seventh grant.')
output costExportContainerName string = costExportContainerName

@description('Names of the four demo resource groups, as created.')
output resourceGroupNames object = {
  platform: rgPlatform.outputs.name
  apps: rgApps.outputs.name
  data: rgData.outputs.name
  ops: rgOps.outputs.name
}
