// Fixture: an app-tier Bicep template that leaks a secret-shaped output name -
// repo-static's 3.13.16 "gap" fixture.

output launchOpsFqdn string = 'launch-ops.example.internal'
output sqlAdminSecret string = sqlServer.properties.administratorLoginPassword
output storageConnectionString string = storageAccount.listKeys().keys[0].value
