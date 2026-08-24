// L7 demo parameters.
//
// Images: GHCR public path ghcr.io/paulcfuqua/azure-devsecops/<app>:<tag>
// ([derived] — free on public repos, anonymous pull, no ACR cost; see README).
// Per-app CI passes the real tag/digest at deploy time via the *_IMAGE
// environment variables; the placeholder default keeps the layer deployable
// before the first app image is published.
using './main.bicep'

param location = readEnvironmentVariable('AZURE_LOCATION', 'eastus2')

param launchOpsImage = readEnvironmentVariable(
  'LAUNCH_OPS_IMAGE',
  'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
)

param controlTowerImage = readEnvironmentVariable(
  'CONTROL_TOWER_IMAGE',
  'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
)

param copilotSvcImage = readEnvironmentVariable(
  'COPILOT_SVC_IMAGE',
  'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
)

// Ports: 80 matches the placeholder hello-world image. The real apps listen on
// 3000 (Node); CI overrides these once the GHCR images are in play.
param launchOpsTargetPort = int(readEnvironmentVariable('LAUNCH_OPS_PORT', '80'))
param controlTowerTargetPort = int(readEnvironmentVariable('CONTROL_TOWER_PORT', '80'))
param copilotSvcTargetPort = int(readEnvironmentVariable('COPILOT_SVC_PORT', '80'))

// copilot-svc is internal-only initially (spec: frontends call it inside the
// Container Apps environment). Flip via COPILOT_EXTERNAL_INGRESS=true.
param copilotExternalIngress = bool(readEnvironmentVariable('COPILOT_EXTERNAL_INGRESS', 'false'))

// Scale-to-zero is non-negotiable (minReplicas=0 is hardcoded in main.bicep);
// only the ceiling is tunable, and raising it is a spend-profile change (G2).
param maxReplicas = 2
