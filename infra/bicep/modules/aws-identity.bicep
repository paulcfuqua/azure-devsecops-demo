// =============================================================================
// modules/aws-identity.bicep — the identity the AWS IAM role trusts, by principal id.
//
// 2026-09-16 aws-lakehouse-link Task 2. Lives OUTSIDE the four resource groups the
// standard teardown deletes by name (`<prefix>-rg-platform|apps|data|ops`), deliberately,
// in its own fifth group: `<prefix>-rg-identity`.
//
// WHY. A managed identity's principal id is destroyed and reissued on every teardown — the
// 2026-09-03 rebuild moved data-api's from 3dadafd7 to ba91c8ea. Task 3 conditions an AWS
// IAM trust policy's `sub` claim on THIS identity's principal id; if the identity lived
// inside one of the four groups, the next rebuild would silently reissue the id and the
// trust policy would start failing with an opaque AccessDenied that reads like an AWS
// problem, not the Azure one it actually is.
//
// SAME MOVE, SAME REASON as the Fabric capacity's `rg-fabric` default (BLOCKER-E,
// scripts/bootstrap/02-fabric-capacity.ps1): a resource whose SURVIVAL is the point cannot
// sit in a group the ordinary kill/rebuild cycle deletes by name.
//
// SUBSCRIPTION SCOPE, self-contained: this module creates its own resource group AND the
// identity inside it, rather than folding into platform/main.bicep's "single owner of RG
// creation" block — which is explicitly scoped to the FOUR demo groups the teardown owns —
// mirroring how the Fabric capacity's resource group is created by its own script rather
// than by that block. verification/tests/failure-classes.Tests.ps1 ("AWS trust identity
// survives teardown") asserts this file never resolves its group to one of the four,
// deriving them from naming.bicep rather than hardcoding them, so a rebrand cannot move
// this identity back inside the blast radius (F90's class).
//
// Idempotent create-if-absent on replay: an `az deployment sub create` against an existing
// rg-identity/identity pair changes nothing, the same discipline the tenant-level teardown
// scripts use (CLAUDE.md), applied here even though this is an RG-scoped object, because
// nothing in the standard kill/rebuild cycle ever deletes it either.
//
// Invoked from platform/main.bicep (L6) as a nested subscription-scope module; its
// principal id is also surfaced there as a top-level deployment output so it can be read
// from the "layer-06" deployment manifest without a separate `az identity show` — though
// the values in this file's own outputs are the ones actually returned by Azure and must be
// read back, never predicted (naming resolves the STRING; only Azure assigns the id).
// =============================================================================
targetScope = 'subscription'

import * as naming from '../naming.bicep'

@description('Company prefix. Single source: naming.bicep.')
param prefix string = naming.defaultCompanyPrefix

@description('Environment segment for the identity name and the env tag.')
param envSegment string = naming.defaultEnv

@description('Region for the resource group and the identity. From AZURE_LOCATION at deploy time.')
param location string = deployment().location

@description('costCenter tag value.')
param costCenter string = naming.defaultCostCenter

@description('owner tag value.')
param owner string = naming.defaultOwner

@description('dataClassification tag value.')
param dataClassification string = naming.defaultDataClassification

// The fifth resource group — deliberately NOT one of naming.bicep's four `rgPurposes`
// (platform/apps/data/ops), the fixed set the standard teardown deletes by name (CLAUDE.md:
// "Demo RGs: ... Teardown = delete these four."). Written directly rather than through
// naming.resourceGroupName(prefix, 'identity') so the literal `rg-identity` name is visible
// in THIS file's own text — the function call would produce the same value but split "rg-"
// and "identity" across two files, which is exactly the kind of thing a rebrand-safety test
// reading this file in isolation cannot see through.
var identityRgName = '${prefix}-rg-identity'

// app tag follows the RG's own purpose word, the same convention platform/main.bicep uses
// for tagsPlatform/tagsApps/tagsData/tagsOps — not the resource's role segment (that pattern
// is for resources INSIDE an RG, e.g. tagsCostIngest there); this tags the RG itself.
var tags = naming.requiredTags(envSegment, 'identity', costCenter, owner, dataClassification)

module identityRg 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'aws-identity-rg'
  params: {
    name: identityRgName
    location: location
    tags: tags
  }
}

// naming.userAssignedIdentityName(prefix, 'aws', env) => '<prefix>-aws-<env>-id'. 'aws' is a
// raw role-segment literal, not an infra/bicep/naming.bicep appKeys entry — matching how
// 'obs', 'ops' and 'cost' are already passed directly to other resourceName()-family
// functions elsewhere in this estate. appKeys exists for container-app-affiliated
// identities, and this identity names no container app.
var identityName = naming.userAssignedIdentityName(prefix, 'aws', envSegment)

module identity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'aws-identity'
  scope: resourceGroup(identityRgName)
  params: {
    name: identityName
    location: location
    tags: tags
  }
  dependsOn: [identityRg]
}

@description('Principal (object) id of the identity. This is what the AWS IAM trust policy\'s `sub` condition is built from (Task 3) — read it from this output or `az identity show`, never predict it: it is destroyed and reissued on every teardown/rebuild.')
output principalId string = identity.outputs.principalId

@description('Client (application) id of the identity. Task 6 requests a token from this specific identity by client id, never from whatever identity a container happens to default to.')
output clientId string = identity.outputs.clientId

@description('ARM resource id of the identity, for a container app\'s userAssignedIdentities.userAssignedResourceIds.')
output resourceId string = identity.outputs.resourceId

@description('Name of the resource group this identity lives in — outside the four the standard teardown deletes.')
output resourceGroupName string = identityRgName
