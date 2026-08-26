// =============================================================================
// workload-role-assignments.bicep — grants a principal a built-in role at
// SUBSCRIPTION scope. Generic over the role: callers pass principalId and
// roleDefinitionId; each call site names the role in an adjacent comment next
// to the GUID literal it passes (the F13 remediation ruling: Bicep role
// assignments carry role definition GUIDs, not names, so the name has to live
// somewhere a reviewer — and verification/tests/workload-rbac.Tests.ps1 — can
// actually match it).
//
// F13 (compliance/findings/2026-08-26-prepublication-review.md#f13): the repo
// contained zero role assignments for its workload identities. This module
// closes the two of the seven documented grants that are genuinely
// subscription-scoped:
//   * Security Reader — Defender for Cloud's secure score, recommendations and
//     alerts are subscription-wide constructs, not properties of one resource.
//     apps/main.bicep already injects MLS_DEFENDER_SUBSCRIPTION_ID into both
//     data-api and mcp-tools, confirming the read happens at that scope
//     (apps/data-api/src/config.ts, tools/cloud/defender-posture.ts:18).
//   * Cost Management Reader — same reasoning: mcp-tools reads subscription
//     cost data (tools/auth.ts:92), which has no narrower ARM resource to
//     scope a read to.
// Neither role has a resource to scope down to, so subscription is the
// NARROWEST scope that works for them (the self-review rule this remediation
// is held to) — not a default taken for convenience.
//
// SUBSCRIPTION-SCOPED MODULE, deliberately: `az bicep build` enforces BCP139
// ("a resource's scope must match the scope of the Bicep file") — a plain
// resource inside a resourceGroup-scoped template cannot target subscription
// scope; only a MODULE declared at that scope can, which is why this file's
// targetScope is 'subscription' even though its caller, apps/main.bicep,
// targets 'resourceGroup'. The caller deploys this module with
// `scope: subscription()`.
//
// The narrower, resource-scoped grant this finding also requires — Log
// Analytics Reader, scoped to the platform LAW rather than the subscription —
// is NOT made with this module for the same BCP139 reason: a subscription-
// scope module and a resource-scope module cannot share one file without
// nesting a module inside a module, which would obscure rather than clarify.
// See the sibling log-analytics-reader-role.bicep instead, which follows the
// exact shape of ITS siblings (key-vault-secrets-user-role.bicep,
// monitoring-metrics-publisher-role.bicep).
//
// NOT covered here (F13 stays open on these — see apps/main.bicep's F13
// summary comment):
//   * Cost Management service -> Storage Blob Data Contributor: owned by
//     Task 17 (F15). The export's identity is created by
//     .github/workflows/layer-06-platform.yml's `az costmanagement export
//     create` step (once that step requests one), not by Bicep — there is no
//     principalId available here to grant.
//   * cost-ingest -> Storage Blob Data Reader: blocked on F19 — cost-ingest
//     has no Function App, and therefore no identity, anywhere in this repo's
//     IaC despite infra-up.yml:31 claiming otherwise.
// =============================================================================
targetScope = 'subscription'

@description('Object ID of the principal to grant access to.')
param principalId string

@description('Role definition GUID to assign at subscription scope. Name the role in a comment at the call site — see this file header.')
param roleDefinitionId string

resource subscriptionRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, principalId, roleDefinitionId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

@description('The role assignment resource ID.')
output roleAssignmentId string = subscriptionRoleAssignment.id
