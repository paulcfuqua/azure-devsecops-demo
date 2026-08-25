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
// Apps (spec architecture summary, as amended 2026-08-24):
//   data-api       external ingress   minReplicas=0
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
// It is EXTERNAL ingress. Internal-only would be tighter, but the service is the
// browser's data path through a same-origin proxy, /healthz is the first thing
// anyone checks when a dashboard is blank, and apps/data-api/README.md already
// treats the service as internet-reachable ("This API is reachable from the
// internet and answers with tenant data") when it refuses a wildcard CORS
// origin. It is read-only, allowlisted, row-capped and serves synthetic data.
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
//    Key Vault Secrets User grant are GONE. No Anthropic key exists anywhere in
//    the system, so the whole secret-consuming path is deleted rather than
//    repointed (amendment section 3, "Discarded").
//  * Ingress is **external + HTTPS-only, unconditionally**. Copilot Studio is a
//    SaaS caller outside the Container Apps environment: it must resolve and
//    reach the public FQDN, so the old `copilotExternalIngress` toggle is not a
//    choice any more and has been removed rather than defaulted to true.
//  * The **user-assigned identity survives** (renamed mls-mcp-demo-id) and is
//    justified below.
// ---------------------------------------------------------------------------
//
// [derived] Registry: GitHub Container Registry (GHCR) public path
// ghcr.io/paulcfuqua/azure-devsecops/<app>:<tag> — free on public repos,
// anonymous pull, no ACR resource and no registry credentials to manage
// (see infra/bicep/README.md). Image references are parameters; the
// placeholder default is Microsoft's public hello-world image so the layer is
// deployable before the first app CI run.
//
// Platform resource IDs are DERIVED from naming.bicep (deterministic names),
// not passed as parameters — naming is the single source of truth, so the apps
// layer can locate the L6 environment and App Insights by name.
//
// [derived] WHY THE USER-ASSIGNED IDENTITY STAYS (decision, 2026-08-24)
//
// The old rationale for it — "the Key Vault role grant must exist before the app
// provisions, because the app resolves a secret reference at creation time" — is
// void: there is no secret reference any more. The identity is kept anyway, on a
// different and stronger justification:
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
//      assignment, Cost Management Reader). A user-assigned identity has a
//      deterministic name from naming.bicep and a principalId that is an output
//      of this template, so those grants can be made before or after the app
//      exists. A system-assigned identity only exists once the app does, which
//      re-imposes an ordering dependency on every future grant.
//   3. Its clientId is injected as AZURE_CLIENT_ID so the container's
//      DefaultAzureCredential binds to this identity and not to an ambient one.
//
// What was NOT kept: the 'Key Vault Secrets User' grant. It existed solely to
// read anthropic-api-key, so it goes with the secret. modules/
// key-vault-secrets-user-role.bicep is retained but unreferenced — see the
// README's "Raw resources" note for the conditions under which it returns.
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

@description('owner/repo the data-api Dev/Sec feeds read through the GitHub API.')
param githubRepository string = 'paulcfuqua/azure-devsecops'

@description('[derived] Timespan for data-api\'s app-requests Log Analytics query, ISO-8601.')
param logAnalyticsTimespan string = 'P14D'

@description('[derived] HTTP path the MCP Streamable HTTP endpoint is served on. ASSUMPTION pending reconciliation with apps/mcp-tools/ — see infra/copilot-studio/README.md. Used only to compose the mcpToolsEndpoint output that the Copilot Studio connector consumes; changing it deploys nothing.')
param mcpEndpointPath string = '/mcp'

@description('L10 deployment witness image. A pinned PUBLIC placeholder on purpose: apps/vuln-lab is never containerised (see the vuln-lab block below), so this image contains none of the lab\'s code and none of its deliberately vulnerable dependencies.')
param vulnLabWitnessImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Commit the L10 witness revision attests to. "unset" until a heal merges; .github/workflows/vuln-lab-witness.yml re-stamps it on every push to main that touches apps/vuln-lab/**, which is what creates the revision V10.1 stage 6 / V10.2 stage 5 look for.')
param vulnLabHealCommit string = 'unset'

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

var caeResourceId = resourceId(
  subscription().subscriptionId,
  platformRgName,
  'Microsoft.App/managedEnvironments',
  caeName
)

// No Key Vault reference here any more: the anthropic-api-key secret URL and the
// secret-consuming plumbing were deleted with the Anthropic decision (2026-08-24).

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
var mcpToolsIdentityName = naming.userAssignedIdentityName(companyPrefix, naming.appKeys.mcpTools, env)
var dataApiIdentityName = naming.userAssignedIdentityName(companyPrefix, naming.appKeys.dataApi, env)

var tagsLaunchOps = naming.requiredTags(env, naming.appKeys.launchOps, costCenter, owner, dataClassification)
var tagsControlTower = naming.requiredTags(env, naming.appKeys.controlTower, costCenter, owner, dataClassification)
var tagsMcpTools = naming.requiredTags(env, naming.appKeys.mcpTools, costCenter, owner, dataClassification)
var tagsDataApi = naming.requiredTags(env, naming.appKeys.dataApi, costCenter, owner, dataClassification)
var tagsVulnLab = naming.requiredTags(env, naming.appKeys.vulnLab, costCenter, owner, dataClassification)

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
    ingressExternal: true
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
    ingressExternal: true // frontend: public
    ingressTargetPort: launchOpsTargetPort
    ingressAllowInsecure: false
    scaleSettings: scaleToZero
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
    ingressExternal: true // frontend: public
    ingressTargetPort: controlTowerTargetPort
    ingressAllowInsecure: false
    scaleSettings: scaleToZero
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

module mcpToolsApp 'br/public:avm/res/app/container-app:0.23.0' = {
  name: 'l7-ca-mcp-tools'
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
    // No `secrets` block: nothing in this app reads a secret any more.
    containers: [
      {
        name: naming.appKeys.mcpTools
        image: mcpToolsImage
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
            // Binds DefaultAzureCredential inside the container to the
            // user-assigned identity above rather than to any ambient identity.
            name: 'AZURE_CLIENT_ID'
            value: mcpToolsIdentity.outputs.clientId
          }
          {
            name: 'MLS_IMAGE_DIGEST'
            value: mcpToolsImageDigest
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

@description('Public FQDN of launch-ops.')
output launchOpsFqdn string = launchOpsApp.outputs.fqdn

@description('Public FQDN of control-tower.')
output controlTowerFqdn string = controlTowerApp.outputs.fqdn

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

@description('Container app NAME per app key. verification/layer-07-audit.ps1 addresses apps by name (-AppName), and the L7 workflow builds the V7.1 deploy manifest from these. The L10 witness is deliberately NOT here: it serves nothing, has no image digest to bind an endpoint to, and V7.1 would report it as an app whose /healthz never answers. It is published separately as vulnLabWitnessAppName.')
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
