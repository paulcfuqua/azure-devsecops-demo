// Fixture: app-tier Bicep outputs with nothing secret-shaped - repo-static's 3.13.16
// "clean outputs" pass fixture. keyVaultUri/keyVaultResourceId are the real repo's own
// shape (they end in Uri/Id, not Key/Secret/ConnectionString) and must not false-positive.

output launchOpsFqdn string = 'launch-ops.example.internal'
output keyVaultUri string = 'https://kv.vault.azure.net/'
output keyVaultResourceId string = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv'
output dataApiIdentityClientId string = '00000000-0000-0000-0000-000000000000'
