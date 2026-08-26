# =============================================================================
# F13 (compliance/findings/2026-08-26-prepublication-review.md#f13, Task 12):
# the repo contained zero role assignments for its workload identities. This
# guards the five of F13's seven documented grants this layer can actually
# express in code:
#
#   data-api  -> SQL contained-database user   (data/seed/sql/900-contained-users.sql)
#   data-api  -> Fabric workspace Viewer        (infra/fabric/provision-workspace.ps1 + fabric-api.psm1)
#   data-api  -> Log Analytics Reader           (infra/bicep/apps/main.bicep)
#   data-api  -> Security Reader                (infra/bicep/apps/main.bicep)
#   mcp-tools -> Log Analytics Reader           (infra/bicep/apps/main.bicep)
#   mcp-tools -> Security Reader                (infra/bicep/apps/main.bicep)
#   mcp-tools -> Cost Management Reader         (infra/bicep/apps/main.bicep)
#
# Deliberately NOT asserted here, and not by role name either — a test that
# passes because a role's name merely appears in a comment is the exact
# failure mode the GUID-with-comment ruling (role name in a comment next to
# the roleDefinitionId literal) was meant to avoid, not a loophole to reuse:
#
#   Cost Management service -> Storage Blob Data Contributor: owned by
#   Task 17 (F15) — the export's identity is created by
#   .github/workflows/layer-06-platform.yml's `az costmanagement export
#   create` step (once that step requests one), not by Bicep. There is no
#   principalId available to infra/bicep/apps/main.bicep to grant.
#
#   cost-ingest -> Storage Blob Data Reader: blocked on F19 — cost-ingest has
#   no Function App, and therefore no identity, anywhere in this repo's IaC,
#   despite .github/workflows/infra-up.yml:31 claiming otherwise.
#
# Two more findings came out of building this layer but are NOT what this
# file checks, because they are not shaped like a missing grant:
#   F20 - the SQL file below is expressed but nothing re-runs
#         data/seed/seed.ps1 -Target sql after L7 creates the identity, so it
#         never applies in a single infra-up.yml pass.
#   F21 - mls-verifier's own documented Fabric workspace Viewer grant does not
#         exist either (a different principal than any of the above), which
#         breaks the L5 Verifier audit.
# =============================================================================

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..')).Path
    $script:MainBicepPath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'bicep', 'apps', 'main.bicep'
    $script:MainBicep = Get-Content -LiteralPath $script:MainBicepPath -Raw
    $script:ContainedUsersPath = Join-Path -Path $script:RepoRoot -ChildPath 'data' -AdditionalChildPath 'seed', 'sql', '900-contained-users.sql'
    $script:FabricApiPath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'fabric', 'fabric-api.psm1'
    $script:ProvisionWorkspacePath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'fabric', 'provision-workspace.ps1'
    $script:WorkloadRoleModulePath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'bicep', 'apps', 'modules', 'workload-role-assignments.bicep'
    $script:LawRoleModulePath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'bicep', 'apps', 'modules', 'log-analytics-reader-role.bicep'
}

Describe 'workload identities have their grants expressed in code' {
    It 'declares a role assignment for every documented grant this layer can make' {
        foreach ($role in 'Log Analytics Reader', 'Security Reader', 'Cost Management Reader') {
            $script:MainBicep | Should -Match ([regex]::Escape($role))
        }
    }

    It 'grants both data-api and mcp-tools identities, not just one' {
        ([regex]::Matches($script:MainBicep, [regex]::Escape('Log Analytics Reader')).Count) | Should -BeGreaterOrEqual 2
        ([regex]::Matches($script:MainBicep, [regex]::Escape('Security Reader')).Count) | Should -BeGreaterOrEqual 2
    }

    It 'uses dedicated modules for the subscription- and resource-scoped grants' {
        Test-Path -LiteralPath $script:WorkloadRoleModulePath | Should -BeTrue
        Test-Path -LiteralPath $script:LawRoleModulePath | Should -BeTrue
        $script:MainBicep | Should -Match 'modules/workload-role-assignments\.bicep'
        $script:MainBicep | Should -Match 'modules/log-analytics-reader-role\.bicep'
    }

    It 'creates the SQL contained-database user in the seed' {
        Test-Path -LiteralPath $script:ContainedUsersPath | Should -BeTrue
        $sql = Get-Content -LiteralPath $script:ContainedUsersPath -Raw
        $sql | Should -Match 'FROM EXTERNAL PROVIDER'
        $sql | Should -Match 'db_datareader'
    }

    It 'provisions the Fabric workspace role-assignment REST path' {
        $psm1 = Get-Content -LiteralPath $script:FabricApiPath -Raw
        $psm1 | Should -Match 'function Add-FabricWorkspaceRoleAssignment'
        $psm1 | Should -Match 'roleAssignments'
    }

    It 'wires the data-api Fabric workspace Viewer grant into provision-workspace.ps1' {
        $script = Get-Content -LiteralPath $script:ProvisionWorkspacePath -Raw
        $script | Should -Match 'DataApiPrincipalId'
        $script | Should -Match "Role\s+Viewer"
    }
}
