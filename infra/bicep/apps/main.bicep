// =============================================================================
// apps/main.bicep — L7: the three container apps.
//
// Deployed at RESOURCE GROUP scope into mls-rg-apps (created at L6):
//
//   az deployment group create \
//     --resource-group mls-rg-apps \
//     --template-file infra/bicep/apps/main.bicep \
//     --parameters infra/bicep/apps/demo.bicepparam
//
// Apps (spec architecture summary, as amended 2026-08-24):
//   launch-ops     external ingress   minReplicas=0
//   control-tower  external ingress   minReplicas=0
//   mcp-tools      external ingress   minReplicas=0
//
// minReplicas=0 everywhere: idle cost is $0 by design; a nonzero floor is an
// un-gated spend change and an audit failure (V6.1/V7.5).
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

@description('Container port each app listens on. 80 matches the hello-world placeholder; the real apps override via parameters.')
param launchOpsTargetPort int = 80
param controlTowerTargetPort int = 80
param mcpToolsTargetPort int = 80

@description('[derived] HTTP path the MCP Streamable HTTP endpoint is served on. ASSUMPTION pending reconciliation with apps/mcp-tools/ — see infra/copilot-studio/README.md. Used only to compose the mcpToolsEndpoint output that the Copilot Studio connector consumes; changing it deploys nothing.')
param mcpEndpointPath string = '/mcp'

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

// ------------------------------------------------------------------ names + tags

var launchOpsName = naming.containerAppName(companyPrefix, naming.appKeys.launchOps, env)
var controlTowerName = naming.containerAppName(companyPrefix, naming.appKeys.controlTower, env)
var mcpToolsName = naming.containerAppName(companyPrefix, naming.appKeys.mcpTools, env)
var mcpToolsIdentityName = naming.userAssignedIdentityName(companyPrefix, naming.appKeys.mcpTools, env)

var tagsLaunchOps = naming.requiredTags(env, naming.appKeys.launchOps, costCenter, owner, dataClassification)
var tagsControlTower = naming.requiredTags(env, naming.appKeys.controlTower, costCenter, owner, dataClassification)
var tagsMcpTools = naming.requiredTags(env, naming.appKeys.mcpTools, costCenter, owner, dataClassification)

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

// ------------------------------------------------------------------ container apps

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

@description('Full HTTPS URL of the MCP Streamable HTTP endpoint. This is the value that goes into the Copilot Studio MCP connector host/path (infra/copilot-studio/agent-definition.md) and into the demo environment variable MCP_SERVER_URL.')
output mcpToolsEndpoint string = 'https://${mcpToolsApp.outputs.fqdn}${mcpEndpointPath}'

@description('Client ID of the mcp-tools user-assigned identity — the principal other layers grant SQL / Fabric / Cost Management access to.')
output mcpToolsIdentityClientId string = mcpToolsIdentity.outputs.clientId

@description('Principal (object) ID of the mcp-tools user-assigned identity, for role assignments made outside this template.')
output mcpToolsIdentityPrincipalId string = mcpToolsIdentity.outputs.principalId

@description('Resource IDs of the three container apps.')
output containerAppResourceIds object = {
  launchOps: launchOpsApp.outputs.resourceId
  controlTower: controlTowerApp.outputs.resourceId
  mcpTools: mcpToolsApp.outputs.resourceId
}
