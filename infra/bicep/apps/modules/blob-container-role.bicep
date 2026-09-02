// =============================================================================
// blob-container-role.bicep — grants a principal a built-in role scoped to ONE
// BLOB CONTAINER of an existing storage account, not to the account.
//
// F19 / F13's seventh grant (compliance/findings/2026-08-26-prepublication-review.md#f19,
// #f13). apps/cost-ingest reads Cost Management's daily export out of the
// `cost-exports` container and writes nowhere in that account. The narrowest
// scope Azure RBAC offers for blob data is the container
// (…/blobServices/default/containers/<name>), and that is what this module
// binds to — an account-scoped grant would additionally hand the Function read
// access to every container the account grows later, including the ones the
// Functions host itself would create if the runtime storage were ever
// consolidated here (it deliberately is not — see platform/main.bicep's
// functionRuntimeStorage block).
//
// The same narrowing is already applied to the OTHER principal that touches
// this container: .github/workflows/layer-06-platform.yml grants the Cost
// Management export's system-assigned identity Storage Blob Data Contributor
// with `--scope "${storage_id}/blobServices/default/containers/cost-exports"`
// (F15, Task 17). This module is the Bicep-expressible half of the same
// discipline — the export's principalId only exists after an `az rest` PUT, so
// that one cannot be a Bicep resource; cost-ingest's identity is created by
// this template, so this one can and must be.
//
// GENERIC OVER THE ROLE, like its sibling
// infra/bicep/apps/modules/workload-role-assignments.bicep: the caller passes a
// role definition GUID and names the role in a comment adjacent to the literal.
// That is the F13/F27 ruling — Bicep role assignments carry GUIDs, not names,
// so verification/tests/cost-ingest.Tests.ps1 asserts the GUID and the scope,
// never a comment. A test that goes green because the word "Reader" appears in
// a comment is the exact failure F27 recorded.
//
// RAW RESOURCE, for the same reason its siblings are raw: the storage account
// is deployed by this same template, but AVM's storage-account module scopes
// its own `roleAssignments` parameter to the ACCOUNT — it has no per-container
// grant — and the container sub-resource is not separately addressable through
// that module's outputs. A raw `Microsoft.Authorization/roleAssignments` with
// an `existing` container as its scope is the only way to express the narrower
// grant at all.
// =============================================================================
targetScope = 'resourceGroup'

@description('Name of the existing storage account in this resource group.')
param storageAccountName string

@description('Name of the existing blob container the grant is scoped to. NOT the account: this is the whole point of the module.')
param containerName string

@description('Object (principal) ID of the principal to grant access to. For a user-assigned managed identity this is `principalId`, never `clientId` — the Authorization API silently accepts any GUID and the grant then belongs to nothing.')
param principalId string

@description('Role definition GUID to assign at container scope. Name the role in a comment at the call site — see this file header.')
param roleDefinitionId string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName

  resource blobService 'blobServices' existing = {
    name: 'default'

    resource container 'containers' existing = {
      name: containerName
    }
  }
}

resource containerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount::blobService::container.id, principalId, roleDefinitionId)
  scope: storageAccount::blobService::container
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

@description('The role assignment resource ID.')
output roleAssignmentId string = containerRoleAssignment.id

@description('The container-scoped resource ID the grant was written against, so a caller (and the L6 audit) can assert the scope is the container and not the account.')
output scopeResourceId string = storageAccount::blobService::container.id
