// =============================================================================
// key-vault-secret-role.bicep — grants a principal 'Key Vault Secrets User'
// scoped to ONE SECRET of an existing RBAC-mode Key Vault, not to the vault.
//
// The sibling module in this directory,
// infra/bicep/apps/modules/key-vault-secrets-user-role.bicep, binds the same
// role at VAULT scope. That is right for a workload that owns its secret
// (mcp-tools resolving mcp-auth-token, data-api resolving its GitHub token):
// those identities exist to read that vault. It is wrong for an AUDITOR.
//
// WHY THIS MODULE EXISTS. verification/layer-08-audit.ps1's V8.6 asserts that
// the AWS Athena lakehouse answers through the deployed MCP tool with ROWS
// rather than with a status code, and V8.7 asserts that a denial from it is
// never reported as an empty dataset. Neither question can be answered from
// metadata — a row is only observable by asking for one — and the MCP endpoint
// is behind `mcp-auth-token`. So mls-verifier needs to read exactly that one
// secret and nothing else: the vault also holds the Direct Line secret and
// data-api's GitHub PAT, and an auditor that can read those is a fully
// authorised caller of two more things it audits.
//
// Azure RBAC's narrowest scope for Key Vault data is the individual secret
// (…/vaults/<vault>/secrets/<name>) on a vault with enableRbacAuthorization,
// which the platform vault is — so the narrow grant is expressible and the
// broad one has no excuse.
//
// THE GRANT THIS REPLACES WAS HAND-APPLIED (2026-09-16, sponsor-approved) and
// that is F159's class: configuration that exists only in the estate is a demo
// that works once. The next teardown erases it, the rebuild does not reproduce
// it, and V8.6/V8.7 silently return to SKIP — a criterion that stops asserting
// is indistinguishable from one that never did.
//
// THE SECRET MUST ALREADY EXIST. ARM validates the scope of a role assignment,
// so a grant written against an absent secret fails the deployment rather than
// creating a dangling assignment. That ordering holds by construction here:
// `mcp-auth-token` is created by docs/runbooks/g0-bootstrap.md item C11, which
// runs after L6 creates the vault and BEFORE L7 deploys the apps — the same
// precondition infra/bicep/apps/main.bicep already depends on for the
// container app's own keyVaultUrl secret reference. The caller guards the
// module on a non-empty principal id so an estate with no Verifier configured
// still deploys.
//
// RAW RESOURCE, for the same reason every sibling in this directory is raw:
// AVM has no standalone role-assignment module targeting a single existing
// resource (avm/ptn/authorization/role-assignment targets MG, subscription and
// resource-group scopes), and AVM's key-vault module embeds roleAssignments
// inside the vault resource — which cannot be used here, because the vault is
// deployed at L6 and this principal is resolved at L7.
// =============================================================================
targetScope = 'resourceGroup'

@description('Name of the existing Key Vault in this resource group. The vault must have enableRbacAuthorization; on an access-policy vault a role assignment grants nothing and says nothing.')
param keyVaultName string

@description('Name of the existing secret the grant is scoped to. NOT the vault: this is the whole point of the module.')
param secretName string

@description('Object (principal) ID of the principal to grant access to. For a service principal this is the SP object id, never the application (client) id — the Authorization API accepts any GUID and the grant then belongs to nothing.')
param principalId string

// 'Key Vault Secrets User' — read secret contents. Built-in role, stable GUID,
// identical in every tenant; asserted by GUID and never by a comment (the
// F13/F27 ruling — a test that goes green because the word "Secrets" appears in
// a comment is the failure F27 recorded).
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: keyVaultName

  resource secret 'secrets' existing = {
    name: secretName
  }
}

resource secretRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault::secret.id, principalId, keyVaultSecretsUserRoleId)
  scope: keyVault::secret
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

@description('The role assignment resource ID.')
output roleAssignmentId string = secretRoleAssignment.id

@description('The SECRET-scoped resource ID the grant was written against, so a caller and any audit can assert the scope is the secret and not the vault.')
output scopeResourceId string = keyVault::secret.id
