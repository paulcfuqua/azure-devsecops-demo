// =============================================================================
// key-vault-secrets-user-role.bicep — grants a principal 'Key Vault Secrets
// User' on the platform Key Vault (RBAC-mode vault; needed by copilot-svc to
// resolve its ANTHROPIC_API_KEY secret reference).
//
// RAW RESOURCE, deliberately: AVM has no standalone module for a role
// assignment scoped to an EXISTING individual resource. AVM embeds
// roleAssignments inside each resource module, which cannot be used here —
// the vault is deployed at L6, long before the app identity exists at L7.
// (avm/ptn/authorization/role-assignment targets MG/subscription/RG scopes,
// not single-resource scope.)
// =============================================================================
targetScope = 'resourceGroup'

@description('Name of the existing Key Vault in this resource group.')
param keyVaultName string

@description('Object ID of the principal to grant access to.')
param principalId string

// 'Key Vault Secrets User' — read secret contents (built-in role, stable GUID).
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: keyVaultName
}

resource secretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, principalId, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

@description('The role assignment resource ID.')
output roleAssignmentId string = secretsUserAssignment.id
