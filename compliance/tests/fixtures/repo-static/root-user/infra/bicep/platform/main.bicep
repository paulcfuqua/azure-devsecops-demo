// Fixture: a platform Bicep template that wires diagnostics and SQL audit the way
// infra/bicep/platform/main.bicep does for real - repo-static's 3.3.1/3.3.2 "pass" fixture.

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law'
  location: 'eastus'
}

resource keyVaultDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'keyVaultDiag'
  scope: keyVault
  properties: {
    workspaceId: logAnalytics.id
    logs: []
    metrics: []
  }
}

module containerAppsDiag 'modules/diag.bicep' = {
  name: 'containerAppsDiag'
  params: {
    diagnosticSettings: [
      {
        workspaceId: logAnalytics.id
      }
    ]
  }
}

module sqlDiag 'modules/diag.bicep' = {
  name: 'sqlDiag'
  params: {
    diagnosticSettings: [
      {
        workspaceId: logAnalytics.id
      }
    ]
  }
}

module storageDiag 'modules/diag.bicep' = {
  name: 'storageDiag'
  params: {
    diagnosticSettings: [
      {
        workspaceId: logAnalytics.id
      }
    ]
  }
}

module keyVaultDiagSettings 'modules/diag.bicep' = {
  name: 'keyVaultDiagSettings'
  params: {
    diagnosticSettings: [
      {
        workspaceId: logAnalytics.id
      }
    ]
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv'
  location: 'eastus'
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    accessPolicies: []
  }
}

resource sqlServer 'Microsoft.Sql/servers@2023-08-01' = {
  name: 'sqlserver'
  location: 'eastus'
  properties: {
    administratorLogin: 'sqladmin'
  }
}

resource sqlAudit 'Microsoft.Sql/servers/auditingSettings@2023-08-01' = {
  parent: sqlServer
  name: 'default'
  properties: {
    state: 'Enabled'
    isAzureMonitorTargetEnabled: true
  }
}
