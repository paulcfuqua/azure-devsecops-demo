// =============================================================================
// log-analytics-reader-role.bicep — grants a principal 'Log Analytics Reader'
// on the platform Log Analytics workspace.
//
// F13 (compliance/findings/2026-08-26-prepublication-review.md#f13): data-api
// and mcp-tools both read the workspace's query API with no grant anywhere
// expressing that access — data-api via MLS_LOG_ANALYTICS_WORKSPACE_ID
// (apps/data-api/src/config.ts), mcp-tools via tools/cloud/log-analytics.ts:14.
// Scoped to the workspace resource itself, not the resource group or
// subscription — the narrowest scope the role permits and the only data
// either app needs to read.
//
// A SEPARATE FILE from workload-role-assignments.bicep (this module's sibling
// in the same directory), not a parameter on it: `az bicep build` enforces
// BCP139 ("a resource's scope must match the scope of the Bicep file"), and
// that module's targetScope is 'subscription' (the correct scope for Security
// Reader and Cost Management Reader, which have no narrower resource to bind
// to). Log Analytics Reader DOES have a narrower resource to bind to, so it
// gets its own resourceGroup-scoped module rather than being forced up to
// subscription scope merely to share a file.
//
// RAW RESOURCE, for the same reason its siblings
// (key-vault-secrets-user-role.bicep, monitoring-metrics-publisher-role.bicep)
// are raw: the workspace is deployed at L6, long before the L7 app identities
// this grants exist, and AVM's operationalinsights/workspace module exposes
// no roleAssignments property that could be wired at creation time anyway.
// =============================================================================
targetScope = 'resourceGroup'

@description('Name of the existing Log Analytics workspace in this resource group.')
param logAnalyticsWorkspaceName string

@description('Object ID of the principal to grant access to.')
param principalId string

// 'Log Analytics Reader' — read query results and workspace configuration, no write access (built-in role, stable GUID; verified against learn.microsoft.com/azure/role-based-access-control/built-in-roles/monitor).
var logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource logAnalyticsReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(logAnalyticsWorkspace.id, principalId, logAnalyticsReaderRoleId)
  scope: logAnalyticsWorkspace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsReaderRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

@description('The role assignment resource ID.')
output roleAssignmentId string = logAnalyticsReaderAssignment.id
