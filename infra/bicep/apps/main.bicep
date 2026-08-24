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
// Apps (spec architecture summary):
//   launch-ops     external ingress   minReplicas=0
//   control-tower  external ingress   minReplicas=0
//   copilot-svc    internal ingress initially (param copilotExternalIngress
//                  flips it)          minReplicas=0
//
// minReplicas=0 everywhere: idle cost is $0 by design; a nonzero floor is an
// un-gated spend change and an audit failure (V6.1/V7.5).
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
// layer can locate the L6 environment, App Insights, and Key Vault by name.
//
// copilot-svc secret wiring: ANTHROPIC_API_KEY resolves from Key Vault via a
// user-assigned identity granted 'Key Vault Secrets User'. The secret VALUE
// arrives at G0 (human bootstrap) and is written by the layer-06 workflow;
// this template only wires the reference.
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

@description('copilot-svc container image (GHCR public path at deploy time).')
param copilotSvcImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Container port each app listens on. 80 matches the hello-world placeholder; the real apps override via parameters.')
param launchOpsTargetPort int = 80
param controlTowerTargetPort int = 80
param copilotSvcTargetPort int = 80

@description('copilot-svc starts internal-only; flip to true to expose it externally (Track E requirement: param-controlled).')
param copilotExternalIngress bool = false

@description('[derived] Replica ceiling — enough for a demo burst, small enough to cap active spend.')
param maxReplicas int = 2

@description('[derived] Smallest consumption CPU slice; demo workloads are tiny.')
param containerCpu string = '0.25'

@description('[derived] Memory paired with 0.25 vCPU on the consumption plan.')
param containerMemory string = '0.5Gi'

// ------------------------------------------------------------------ derived platform references

var platformRgName = naming.resourceGroupName(companyPrefix, naming.rgPurposes.platform)
var caeName = naming.containerAppsEnvironmentName(companyPrefix, env)
var kvName = naming.keyVaultName(companyPrefix, env)
var appiName = naming.appInsightsName(companyPrefix, env)

var caeResourceId = resourceId(
  subscription().subscriptionId,
  platformRgName,
  'Microsoft.App/managedEnvironments',
  caeName
)

// Key Vault secret URL for the Anthropic key (value written at G0/L6, not here).
var anthropicSecretUri = 'https://${kvName}${az.environment().suffixes.keyvaultDns}/secrets/${naming.anthropicApiKeySecretName}'

// Workspace-based App Insights from L6 — connection string is injected into
// every app so OTel spans land in the shared LAW (V7.3).
resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  scope: az.resourceGroup(platformRgName)
  name: appiName
}

// ------------------------------------------------------------------ names + tags

var launchOpsName = naming.containerAppName(companyPrefix, naming.appKeys.launchOps, env)
var controlTowerName = naming.containerAppName(companyPrefix, naming.appKeys.controlTower, env)
var copilotName = naming.containerAppName(companyPrefix, naming.appKeys.copilotSvc, env)
var copilotIdentityName = naming.userAssignedIdentityName(companyPrefix, naming.appKeys.copilotSvc, env)

var tagsLaunchOps = naming.requiredTags(env, naming.appKeys.launchOps, costCenter, owner, dataClassification)
var tagsControlTower = naming.requiredTags(env, naming.appKeys.controlTower, costCenter, owner, dataClassification)
var tagsCopilot = naming.requiredTags(env, naming.appKeys.copilotSvc, costCenter, owner, dataClassification)

// Scale-to-zero settings shared by all three apps.
var scaleToZero = {
  minReplicas: 0
  maxReplicas: maxReplicas
}

// ------------------------------------------------------------------ copilot identity + Key Vault access

// User-assigned identity so the KV role grant can exist BEFORE the app is
// created (a system-assigned identity would need the app first, and the app
// needs the secret at provisioning time — a deadlock).
module copilotIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'l7-copilot-uami'
  params: {
    name: copilotIdentityName
    location: location
    tags: tagsCopilot
  }
}

// Cross-RG: grant 'Key Vault Secrets User' on the L6 vault in mls-rg-platform.
module copilotKvRole 'modules/key-vault-secrets-user-role.bicep' = {
  name: 'l7-copilot-kv-role'
  scope: az.resourceGroup(platformRgName)
  params: {
    keyVaultName: kvName
    principalId: copilotIdentity.outputs.principalId
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

module copilotApp 'br/public:avm/res/app/container-app:0.23.0' = {
  name: 'l7-ca-copilot'
  params: {
    name: copilotName
    location: location
    tags: tagsCopilot
    environmentResourceId: caeResourceId
    // Internal-only inside the Container Apps environment until the param
    // flips it (frontends call it over the internal FQDN).
    ingressExternal: copilotExternalIngress
    ingressTargetPort: copilotSvcTargetPort
    ingressAllowInsecure: false
    scaleSettings: scaleToZero
    managedIdentities: {
      userAssignedResourceIds: [copilotIdentity.outputs.resourceId]
    }
    secrets: [
      {
        name: naming.anthropicApiKeySecretName
        keyVaultUrl: anthropicSecretUri
        identity: copilotIdentity.outputs.resourceId
      }
    ]
    containers: [
      {
        name: naming.appKeys.copilotSvc
        image: copilotSvcImage
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
            name: 'ANTHROPIC_API_KEY'
            secretRef: naming.anthropicApiKeySecretName
          }
        ]
      }
    ]
  }
  // The role grant must exist before the app provisions (it pulls the secret
  // from Key Vault during create).
  dependsOn: [copilotKvRole]
}

// ------------------------------------------------------------------ outputs

@description('Public FQDN of launch-ops.')
output launchOpsFqdn string = launchOpsApp.outputs.fqdn

@description('Public FQDN of control-tower.')
output controlTowerFqdn string = controlTowerApp.outputs.fqdn

@description('FQDN of copilot-svc (internal unless copilotExternalIngress=true).')
output copilotFqdn string = copilotApp.outputs.fqdn

@description('Resource IDs of the three container apps.')
output containerAppResourceIds object = {
  launchOps: launchOpsApp.outputs.resourceId
  controlTower: controlTowerApp.outputs.resourceId
  copilotSvc: copilotApp.outputs.resourceId
}
