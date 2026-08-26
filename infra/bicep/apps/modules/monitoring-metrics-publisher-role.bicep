// =============================================================================
// monitoring-metrics-publisher-role.bicep — grants a principal 'Monitoring
// Metrics Publisher' on the platform Application Insights component.
//
// F4 (compliance/findings/2026-08-26-prepublication-review.md#f4, Task 8):
// platform/main.bicep now sets `disableLocalAuth: true` on the App Insights
// component, which refuses ingestion authenticated by the instrumentation key
// alone. The Node services that still emit telemetry — mcp-tools and
// data-api — must authenticate with a Microsoft Entra ID token instead, and
// 'Monitoring Metrics Publisher' is the role Microsoft's own docs name for
// that (learn.microsoft.com/azure/azure-monitor/app/azure-ad-authentication):
// "Although the Monitoring Metrics Publisher role says 'metrics,' it
// publishes all telemetry to the Application Insights resource" — so this
// one role covers the trace/log ingestion both apps' OpenTelemetry exporters
// do, not just custom metrics. Its data action is
// `Microsoft.Insights/telemetry/write`, which matches the
// `https://monitor.azure.com//.default` scope the exporter's HTTP sender
// requests once a credential is supplied (@azure/monitor-opentelemetry-
// exporter's platform/nodejs/httpSender.js).
//
// RAW RESOURCE, for the same reason key-vault-secrets-user-role.bicep (this
// module's sibling) is one: AVM's insights/component module exposes no
// roleAssignments property, and the grant's principal — a UAMI created at L7
// — does not exist yet when the component is deployed at L6.
// =============================================================================
targetScope = 'resourceGroup'

@description('Name of the existing Application Insights component in this resource group.')
param appInsightsName string

@description('Object ID of the principal to grant access to.')
param principalId string

// 'Monitoring Metrics Publisher' — publish telemetry; no read/management access (built-in role, stable GUID).
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource metricsPublisherAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appInsights.id, principalId, monitoringMetricsPublisherRoleId)
  scope: appInsights
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

@description('The role assignment resource ID.')
output roleAssignmentId string = metricsPublisherAssignment.id
