// =============================================================================
// key-vault-secrets-user-role.bicep — grants a principal 'Key Vault Secrets
// User' on the platform Key Vault (RBAC-mode vault).
//
// REPURPOSED (Task 5, 2026-08-26 — F2 infra half). This module originally
// existed for `copilot-svc` to resolve its `ANTHROPIC_API_KEY` secret
// reference; both the app and the secret were deleted at the 2026-08-24
// Copilot Studio amendment, and this module went unreferenced with them (see
// infra/bicep/README.md's former "Raw resources" note). It is referenced
// again from infra/bicep/apps/main.bicep (module `mcpKvGrant`), now granting
// the mcp-tools UAMI access to a DIFFERENT secret — `mcp-auth-token`, the MCP
// server's inbound auth token (compliance/findings/2026-08-26-prepublication-
// review.md#f2) — so the container app can resolve it via `keyVaultUrl`
// instead of the token ever passing through a Bicep parameter, ARM deployment
// history, or a what-if log. The module's shape and rationale below are
// unchanged from the original; only its caller and the secret it gates are
// different.
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
