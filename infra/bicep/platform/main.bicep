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

// app tag values follow the role segment of each resource name (README: derived).
var tagsPlatform = naming.requiredTags(env, 'platform', costCenter, owner, dataClassification)
var tagsApps = naming.requiredTags(env, 'apps', costCenter, owner, dataClassification)
var tagsData = naming.requiredTags(env, 'data', costCenter, owner, dataClassification)
var tagsOps = naming.requiredTags(env, 'ops', costCenter, owner, dataClassification)
var tagsSqlServer = naming.requiredTags(env, 'ops', costCenter, owner, dataClassification)
var tagsSqlDb = naming.requiredTags(env, naming.appKeys.launchOps, costCenter, owner, dataClassification)
var tagsCostStorage = naming.requiredTags(env, 'cost', costCenter, owner, dataClassification)

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
          query: 'AzureDiagnostics | where ResourceProvider == "MICROSOFT.SQL" and Category == "SQLSecurityAuditEvents" and succeeded_s == "false"'
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

@description('Names of the four demo resource groups, as created.')
output resourceGroupNames object = {
  platform: rgPlatform.outputs.name
  apps: rgApps.outputs.name
  data: rgData.outputs.name
  ops: rgOps.outputs.name
}
