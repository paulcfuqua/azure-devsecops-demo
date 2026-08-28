// Fixture: a platform Bicep template with no diagnostics wired at all - repo-static's
// 3.3.1/3.3.2 "gap" fixture (fixtureRepoWithout).

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
    storageEndpoint: 'https://sqlauditstorage.blob.core.windows.net/'
  }
}
