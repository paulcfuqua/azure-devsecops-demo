// =============================================================================
// storage-account-role.bicep — grants a principal a built-in role scoped to a
// whole storage ACCOUNT.
//
// Deliberately a SEPARATE file from blob-container-role.bicep, which grants at
// container scope, rather than one module with an optional container
// parameter. The scope is the security property under review here: two files
// mean a reviewer (and verification/tests/cost-ingest.Tests.ps1) can tell which
// grants are account-wide just by reading which module a call site invokes,
// instead of having to check whether an optional parameter was passed.
//
// USED ONLY FOR THE FUNCTIONS HOST'S OWN RUNTIME STORAGE ACCOUNT
// (platform/main.bicep's functionRuntimeStorage, named by naming.bicep's
// storageAccountName(prefix, 'func', env)), never for the
// cost-export account. The Azure Functions host needs account-wide blob, queue
// and table access to its `AzureWebJobsStorage` account — it creates and
// manages the `azure-webjobs-hosts` container, singleton lease blobs, the
// poison queue and the diagnostic-events table itself, so a container-scoped
// grant cannot work there (Microsoft's own minimum is documented as Storage
// Blob Data Owner on the account:
// learn.microsoft.com/azure/azure-functions/manage-connections, "Grant
// permissions to an identity" → Host required).
//
// That requirement is exactly WHY the cost-ingest Function does not reuse the
// cost-export storage account for its runtime: consolidating them would force
// this account-wide grant onto the account that holds the Cost Management
// exports, and the container-scoped Storage Blob Data Reader grant F13 asks for
// would then be decorative — the identity would already hold Owner-class blob
// access to the same container by another route. A second, empty Standard_LRS
// account costs cents and keeps the narrow grant meaningful.
//
// GENERIC OVER THE ROLE, same contract as its siblings: the caller passes a
// role definition GUID and names the role in a comment beside the literal
// (the F13/F27 ruling — assertions are on GUIDs, never on comment text).
// =============================================================================
targetScope = 'resourceGroup'

@description('Name of the existing storage account in this resource group.')
param storageAccountName string

@description('Object (principal) ID of the principal to grant access to — `principalId` for a user-assigned managed identity, never `clientId`.')
param principalId string

@description('Role definition GUID to assign at storage-account scope. Name the role in a comment at the call site — see this file header.')
param roleDefinitionId string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource storageAccountRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, principalId, roleDefinitionId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

@description('The role assignment resource ID.')
output roleAssignmentId string = storageAccountRoleAssignment.id
