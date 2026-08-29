// =============================================================================
// landing-zone/main.bicep — L2: management group, governance policies, NIST.
//
// Deployed AT THE LANDING-ZONE management group '<prefix>' (mls) by the L2
// workflow (layer-02-landing-zone.yml):
//
//   az deployment mg create \
//     --management-group-id <prefix> \
//     --location $AZURE_LOCATION \
//     --template-file infra/bicep/landing-zone/main.bicep \
//     --parameters infra/bicep/landing-zone/demo.bicepparam
//
// Creates (all tenant-level — teardown is G3-gated, standard cycle leaves them):
//   * policy assignments at MG scope:
//       - deny RGs missing each required tag (5 x require-tag + managedBy=iac)
//       - modify: inherit each required tag from the RG onto resources (6x)
//       - allowed locations (resources + resource groups)
//   * NIST SP 800-53 Rev. 5 built-in initiative at SUBSCRIPTION scope,
//     enforcementMode DoNotEnforce (audit mode) per the master plan.
//
// NOT deployed at the tenant root, and deliberately so. Creating the MG and
// placing the subscription are the only two root-scope operations L2 needs, and
// the workflow already performs both imperatively (`az account management-group
// create` / `subscription add`) before this template runs. Azure lets any
// directory principal create a management group beneath the root and makes the
// creator its Owner, so the deployer arrives here already owning its own scope:
// no tenant-root RBAC, and no Global Administrator "elevate access" step, for
// anyone cloning this repo. Targeting the root instead would have meant granting
// mls-github-deployer Owner at '/', which is the kind of standing privilege this
// repo exists to catch (F47).
//
// All built-in policy definition IDs are stable GUIDs, commented with their
// display names. Authoring/compile only in Phase P — no deployment happens
// until L2 unblocks (see docs/runbooks/layers/L02.md).
// =============================================================================
targetScope = 'managementGroup'

import * as naming from '../naming.bicep'

// ------------------------------------------------------------------ parameters

@description('Company prefix; the management group name. Single source: naming.bicep.')
param companyPrefix string = naming.defaultCompanyPrefix

@description('Demo subscription ID, supplied from the AZURE_SUBSCRIPTION_ID environment variable at deploy time (never committed). Empty skips the NIST assignment; subscription placement is done by the workflow.')
param demoSubscriptionId string = ''

@description('Region for policy-assignment managed identities. From AZURE_LOCATION at deploy time.')
param location string = deployment().location

@description('Allowed Azure regions enforced by the allowed-locations guardrails. Defaults to the deployment region.')
param allowedLocations array = [location]

// ------------------------------------------------------------------ variables

var mgName = naming.managementGroupName(companyPrefix)

// Built-in policy definitions (stable GUIDs), each commented with its display name.
// 'Require a tag on resource groups'
var requireTagOnRgDefinitionId = tenantResourceId('Microsoft.Authorization/policyDefinitions', '96670d01-0a4d-4649-9c89-2d3abc0a5025')
// 'Require a tag and its value on resource groups'  (used for managedBy=iac)
var requireTagValueOnRgDefinitionId = tenantResourceId('Microsoft.Authorization/policyDefinitions', '8ce3da23-7156-49e4-b145-24f95f9dcb46')
// 'Inherit a tag from the resource group if missing'  (modify effect)
var inheritTagDefinitionId = tenantResourceId('Microsoft.Authorization/policyDefinitions', 'ea3f2387-9b95-492a-a190-fcdc54f7b070')
// 'Allowed locations'
// CORRECTED 2026-08-29 (F52). This read ...-5fbf209ee700, which is not a policy
// definition that exists. Six of the seven ids in this file resolve; this one was
// fabricated - same first four segments as the real value, invented last segment -
// and `az deployment mg what-if` PASSED IT three times, because what-if does not
// resolve policy definition ids. The first real deploy failed on it.
var allowedLocationsDefinitionId = tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e56962a6-4747-49cd-b67b-bf8b01975c4c')
// 'Allowed locations for resource groups'
var allowedLocationsRgDefinitionId = tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e765b5de-1225-4ba3-bd56-1ac6695af988')
// 'NIST SP 800-53 Rev. 5'  (built-in initiative / policy SET definition)
var nistR5InitiativeId = tenantResourceId('Microsoft.Authorization/policySetDefinitions', '179d1daa-458f-4e47-8086-2a68d0d6c38f')

// Built-in role definitions needed by remediation identities.
// 'Tag Contributor' — role required by the inherit-tag modify policy.
var tagContributorRoleId = tenantResourceId('Microsoft.Authorization/roleDefinitions', '4a9ae827-6dc8-4573-8ac7-8239d42aa03f')

// Required tags with short segments for assignment names (MG-scope policy
// assignment names are capped at 24 characters).
var requiredTagSpecs = [
  { tagName: 'env', short: 'env' }
  { tagName: 'app', short: 'app' }
  { tagName: 'costCenter', short: 'costcenter' }
  { tagName: 'owner', short: 'owner' }
  { tagName: 'dataClassification', short: 'dataclass' }
]

// managedBy participates in inherit, but its deny uses require-tag-AND-VALUE.
var inheritTagSpecs = concat(requiredTagSpecs, [{ tagName: 'managedBy', short: 'managedby' }])

// ------------------------------------------------------------------ management group
//
// The MG and the subscription placement are NOT declared here: both are tenant-
// root writes, and this template deploys AT the MG, which cannot create itself.
// layer-02-landing-zone.yml owns them, idempotently, before this runs. Everything
// below assumes MG '<prefix>' exists with the demo subscription already beneath
// it -- the state that workflow step guarantees.

// ------------------------------------------------------------------ tag governance (MG scope)

// Deny RGs missing each required tag: 'Require a tag on resource groups'.
module requireTagOnRg 'br/public:avm/ptn/authorization/policy-assignment:0.5.3' = [
  for spec in requiredTagSpecs: {
    name: 'l2-pa-require-${spec.short}'
    scope: managementGroup(mgName)
    params: {
      name: 'require-${spec.short}' // <= 24 chars (MG-scope limit)
      displayName: 'Require tag ${spec.tagName} on resource groups'
      description: 'Denies creation of resource groups that do not carry the required ${spec.tagName} tag.'
      policyDefinitionId: requireTagOnRgDefinitionId
      parameters: {
        tagName: { value: spec.tagName }
      }
      identity: 'None' // deny effect needs no managed identity
      nonComplianceMessages: [
        { message: 'Resource groups must carry the required tag \'${spec.tagName}\' (see CLAUDE.md tagging rules).' }
      ]
    }
  }
]

// managedBy must equal 'iac': 'Require a tag and its value on resource groups'.
module requireManagedByIac 'br/public:avm/ptn/authorization/policy-assignment:0.5.3' = {
  name: 'l2-pa-require-managedby'
  scope: managementGroup(mgName)
  params: {
    name: 'require-managedby'
    displayName: 'Require tag managedBy=${naming.managedByValue} on resource groups'
    description: 'Denies resource groups whose managedBy tag is missing or not \'${naming.managedByValue}\'.'
    policyDefinitionId: requireTagValueOnRgDefinitionId
    parameters: {
      tagName: { value: 'managedBy' }
      tagValue: { value: naming.managedByValue }
    }
    identity: 'None'
    nonComplianceMessages: [
      { message: 'Resource groups must be created by IaC and tagged managedBy=${naming.managedByValue}.' }
    ]
  }
}

// Modify: resources inherit each required tag from their resource group.
module inheritTags 'br/public:avm/ptn/authorization/policy-assignment:0.5.3' = [
  for spec in inheritTagSpecs: {
    name: 'l2-pa-inherit-${spec.short}'
    scope: managementGroup(mgName)
    params: {
      name: 'inherit-${spec.short}'
      displayName: 'Inherit tag ${spec.tagName} from the resource group'
      description: 'Adds or replaces the ${spec.tagName} tag on resources with the value from the parent resource group when missing.'
      policyDefinitionId: inheritTagDefinitionId
      parameters: {
        tagName: { value: spec.tagName }
      }
      identity: 'SystemAssigned' // modify effect remediates via managed identity
      roleDefinitionIds: [tagContributorRoleId]
      location: location
    }
  }
]

// ------------------------------------------------------------------ location guardrails (MG scope)

module allowedLocationsResources 'br/public:avm/ptn/authorization/policy-assignment:0.5.3' = {
  name: 'l2-pa-allowed-locations'
  scope: managementGroup(mgName)
  params: {
    name: 'allowed-locations'
    displayName: 'Allowed locations for resources'
    description: 'Restricts resource deployments to the approved demo regions.'
    policyDefinitionId: allowedLocationsDefinitionId
    parameters: {
      listOfAllowedLocations: { value: allowedLocations }
    }
    identity: 'None'
  }
}

module allowedLocationsRgs 'br/public:avm/ptn/authorization/policy-assignment:0.5.3' = {
  name: 'l2-pa-allowed-locations-rg'
  scope: managementGroup(mgName)
  params: {
    name: 'allowed-locations-rg'
    displayName: 'Allowed locations for resource groups'
    description: 'Restricts resource group locations to the approved demo regions.'
    policyDefinitionId: allowedLocationsRgDefinitionId
    parameters: {
      listOfAllowedLocations: { value: allowedLocations }
    }
    identity: 'None'
  }
}

// ------------------------------------------------------------------ NIST 800-53 R5 (subscription scope, audit mode)

// Assigned at SUBSCRIPTION scope per the master plan; DoNotEnforce = audit mode.
// The AVM pattern module fans out to subscription scope via subscriptionId.
module nist80053r5 'br/public:avm/ptn/authorization/policy-assignment:0.5.3' = if (!empty(demoSubscriptionId)) {
  name: 'l2-pa-nist-800-53-r5'
  scope: managementGroup(mgName)
  params: {
    name: 'nist-800-53-r5'
    displayName: 'NIST SP 800-53 Rev. 5 (audit)'
    description: 'Built-in NIST SP 800-53 Rev. 5 initiative in audit mode (enforcementMode DoNotEnforce) at demo subscription scope.'
    policyDefinitionId: nistR5InitiativeId
    enforcementMode: 'DoNotEnforce'
    subscriptionId: demoSubscriptionId
    identity: 'SystemAssigned' // required: the initiative contains DINE/modify members
    roleDefinitionIds: [] // No role grants in DoNotEnforce; enabling enforcement later means granting the specific roles the DINE members declare, never Contributor.
    location: location
  }
}

// ------------------------------------------------------------------ outputs

@description('Resource ID of the mls management group.')
output managementGroupResourceId string = managementGroup().id

@description('Name of the mls management group.')
output managementGroupName string = mgName

@description('Name of the NIST 800-53 R5 subscription-scope assignment (empty when no subscription ID was supplied).')
output nistAssignmentName string = !empty(demoSubscriptionId) ? nist80053r5!.outputs.name : ''
