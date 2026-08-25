// =============================================================================
// naming.bicep — the single source of naming and tagging for the entire estate.
//
// CLAUDE.md: "Company name and prefix are set once in infra/bicep/naming.bicep —
// do not hardcode 'mls' elsewhere." Every layer template imports this file
// (compile-time import) and builds every resource name and the required tag
// object through the exports below. Nothing outside this file may contain the
// literal company prefix.
//
// Naming convention (CLAUDE.md): mls-<app|role>-<env>-<type>
//   e.g. mls-copilot-demo-ca, mls-ops-demo-sql
// Resource groups are the fixed set:  <prefix>-rg-<purpose>  (no env segment —
//   pinned verbatim in CLAUDE.md as mls-rg-platform|apps|data|ops).
// =============================================================================

// ------------------------------------------------------------------ defaults

@export()
@description('Company prefix. The ONLY place the company short name is defined.')
var defaultCompanyPrefix = 'mls'

@export()
@description('Default environment segment used in resource names and the env tag.')
var defaultEnv = 'demo'

@export()
@description('[derived] Default value for the costCenter tag (demo program).')
var defaultCostCenter = 'demo'

@export()
@description('[derived] Default value for the owner tag — the repo owner GitHub handle.')
var defaultOwner = 'paulcfuqua'

@export()
@description('[derived] Default value for the dataClassification tag; synthetic data only.')
var defaultDataClassification = 'internal'

@export()
@description('Fixed value of the managedBy tag, policy-enforced on every RG.')
var managedByValue = 'iac'

@export()
@description('The six required tag names, deny-enforced on resource groups (CLAUDE.md).')
var requiredTagNames = [
  'env'
  'app'
  'costCenter'
  'owner'
  'dataClassification'
  'managedBy'
]

@export()
@description('[derived] Short app keys used in resource names. mcp-tools shortens to "mcp", giving mls-mcp-demo-ca — the Copilot Studio amendment (2026-08-24) replaced the copilot-svc LLM service (mls-copilot-demo-ca, the CLAUDE.md worked example) with an MCP tool server.')
var appKeys = {
  launchOps: 'launch-ops'
  controlTower: 'control-tower'
  mcpTools: 'mcp'
}

@export()
@description('The four demo resource-group purposes (CLAUDE.md RG layout).')
var rgPurposes = {
  platform: 'platform'
  apps: 'apps'
  data: 'data'
  ops: 'ops'
}

// NOTE (Copilot Studio amendment, 2026-08-24): `anthropicApiKeySecretName` was
// removed from this file. No Anthropic API key exists anywhere in the system, so
// there is no secret name to publish and no Bicep template consumes one. The
// Key Vault itself survives at L6 as the estate's secret store; it currently has
// zero secret consumers in Bicep. See infra/bicep/README.md and
// docs/superpowers/specs/2026-08-24-amendment-copilot-studio.md.

// ------------------------------------------------------------------ tag builder

@export()
@description('Builds the required tag object. managedBy is always iac — the only permitted value.')
func requiredTags(envName string, app string, costCenter string, owner string, dataClassification string) object => {
  env: envName
  app: app
  costCenter: costCenter
  owner: owner
  dataClassification: dataClassification
  managedBy: 'iac'
}

// ------------------------------------------------------------------ name builders
// One function per resource type in use. Functions are self-contained
// (parameters + literals only) so they stay valid compile-time imports.

@export()
@description('Generic name builder: <prefix>-<app|role>-<env>-<type>.')
func resourceName(prefix string, role string, envName string, resourceType string) string =>
  '${prefix}-${role}-${envName}-${resourceType}'

@export()
@description('Management group ID/name — the prefix itself (master plan: MG "mls").')
func managementGroupName(prefix string) string => prefix

@export()
@description('Resource group name: <prefix>-rg-<purpose> (CLAUDE.md fixed set).')
func resourceGroupName(prefix string, purpose string) string => '${prefix}-rg-${purpose}'

@export()
@description('[derived] Log Analytics workspace, role "obs": <prefix>-obs-<env>-law.')
func logAnalyticsWorkspaceName(prefix string, envName string) string => '${prefix}-obs-${envName}-law'

@export()
@description('[derived] Application Insights, role "obs": <prefix>-obs-<env>-appi.')
func appInsightsName(prefix string, envName string) string => '${prefix}-obs-${envName}-appi'

@export()
@description('[derived] Container Apps environment, role "platform": <prefix>-platform-<env>-cae.')
func containerAppsEnvironmentName(prefix string, envName string) string => '${prefix}-platform-${envName}-cae'

@export()
@description('Container app: <prefix>-<appKey>-<env>-ca (CLAUDE.md example: mls-copilot-demo-ca).')
func containerAppName(prefix string, appKey string, envName string) string => '${prefix}-${appKey}-${envName}-ca'

@export()
@description('[derived] User-assigned managed identity: <prefix>-<appKey>-<env>-id.')
func userAssignedIdentityName(prefix string, appKey string, envName string) string => '${prefix}-${appKey}-${envName}-id'

@export()
@description('SQL logical server, role "ops": <prefix>-ops-<env>-sql (pinned by CLAUDE.md example and the L6 playbook).')
func sqlServerName(prefix string, envName string) string => '${prefix}-ops-${envName}-sql'

@export()
@description('[derived] SQL database (per app): <prefix>-<appKey>-<env>-sqldb.')
func sqlDatabaseName(prefix string, appKey string, envName string) string => '${prefix}-${appKey}-${envName}-sqldb'

@export()
@description('[derived] Key Vault, role "sec": <prefix>-sec-<env>-kv (24-char limit respected).')
func keyVaultName(prefix string, envName string) string => '${prefix}-sec-${envName}-kv'

@export()
@description('[derived] Storage account: hyphens stripped to satisfy storage naming (3-24 lowercase alphanumerics), e.g. mlscostdemost.')
func storageAccountName(prefix string, role string, envName string) string =>
  toLower(replace('${prefix}${role}${envName}st', '-', ''))
