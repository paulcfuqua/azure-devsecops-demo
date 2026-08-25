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

// mcp-tools replaced copilot-svc at the 2026-08-24 Copilot Studio amendment.
// MCP_TOOLS_IMAGE is the new variable name; COPILOT_SVC_IMAGE is honoured as a
// transitional fallback because .github/workflows/layer-07-apps.yml still sets
// it (that workflow is outside this change's write scope — see the L8 report's
// reconciliation list).
param mcpToolsImage = readEnvironmentVariable(
  'MCP_TOOLS_IMAGE',
  readEnvironmentVariable('COPILOT_SVC_IMAGE', 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest')
)

// Ports: 80 matches the placeholder hello-world image. The real apps listen on
// 8080; CI overrides these once the GHCR images are in play (open item P-1).
param launchOpsTargetPort = int(readEnvironmentVariable('LAUNCH_OPS_PORT', '80'))
param controlTowerTargetPort = int(readEnvironmentVariable('CONTROL_TOWER_PORT', '80'))
param mcpToolsTargetPort = int(
  readEnvironmentVariable('MCP_TOOLS_PORT', readEnvironmentVariable('COPILOT_SVC_PORT', '80'))
)

// ASSUMPTION (see infra/copilot-studio/README.md): the MCP server serves
// Streamable HTTP at /mcp on the container app's external FQDN. This parameter
// only shapes the mcpToolsEndpoint output; it provisions nothing, so
// reconciling it with apps/mcp-tools/ costs one variable.
param mcpEndpointPath = readEnvironmentVariable('MCP_ENDPOINT_PATH', '/mcp')

// There is no ingress parameter: mcp-tools is external + HTTPS-only by
// requirement, not by configuration (Copilot Studio calls it from outside Azure).

// Scale-to-zero is non-negotiable (minReplicas=0 is hardcoded in main.bicep);
// only the ceiling is tunable, and raising it is a spend-profile change (G2).
param maxReplicas = 2
