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
#   Cost Management service -> Storage Blob Data Contributor: landed by
#   Task 17 (F15, CLOSED) but still not assertable here — the export's
#   identity is created by .github/workflows/layer-06-platform.yml's `az
#   rest` PUT against the Exports REST API (requesting `identity: {type:
#   SystemAssigned}` explicitly, since the `az costmanagement` CLI has no
#   --identity-type flag), and the grant is an `az role assignment create`
#   in that same workflow, scoped to the cost-exports container by a
#   principalId that only exists at deploy time. There is no principalId
#   available to infra/bicep/apps/main.bicep to grant, in Bicep or in a
#   static test, because nothing here is a Bicep resource.
#
#   cost-ingest -> Storage Blob Data Reader: blocked on F19 — cost-ingest has
#   no Function App, and therefore no identity, anywhere in this repo's IaC,
#   despite .github/workflows/infra-up.yml:31 claiming otherwise.
#
# Two more findings came out of building this layer. Neither is shaped like a
# missing RBAC grant, so neither belongs to this file's main body — but F20's
# wiring is checked here all the same (see the 'F20:' Describe below):
#   F20 - the SQL file below was expressed but nothing re-ran
#         data/seed/seed.ps1 -Target sql after L7 creates the identity, so it
#         never applied in a single infra-up.yml pass. CLOSED (Task 22).
#         Split of coverage: data/seed/tests/sql-seed.Tests.ps1 and
#         data/seed/tests/seed.Tests.ps1 cover -SchemaOnly's behaviour inside
#         the seed scripts; the 'F20:' Describe in THIS file covers the
#         layer-07-apps.yml wiring that invokes it — that the step exists,
#         passes -SchemaOnly rather than -Force, and is ordered after the V7.1
#         manifest steps so a transient failure cannot cost L7 its Verifier
#         sign-off.
#   F21 - mls-verifier's own documented Fabric workspace Viewer grant did not
#         exist either (a different principal than any of the above), which
#         broke the L5 Verifier audit. CLOSED (Task 21).
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
    $script:Layer07Path = Join-Path -Path $script:RepoRoot -ChildPath '.github' -AdditionalChildPath 'workflows', 'layer-07-apps.yml'
    $script:Layer07 = Get-Content -LiteralPath $script:Layer07Path -Raw
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

# =============================================================================
# F20 (compliance/findings/2026-08-26-prepublication-review.md#f20, Task 22):
# the contained-database user above is expressed but, before Task 22, nothing
# re-ran data/seed/seed.ps1 -Target sql after L7 created the data-api identity,
# so the grant never landed in a standard infra-up.yml pass. These tests
# cannot execute layer-07-apps.yml (no tenant connection, per this branch's
# constraints), so they isolate the step Task 22 added and check its actual
# properties - which job it is in, what it runs, how it is gated - rather than
# merely grepping the whole 460-line file for a string that could as easily
# sit in a comment.
# =============================================================================
Describe 'F20: the SQL contained-user grant is re-applied once the identity exists' {
    BeforeAll {
        # Isolate the job bodies and, within the deploy job, the one new step -
        # from its "- name:" header to the next step at the same indent (or end
        # of job). Every assertion below runs against THIS substring, not the
        # whole file, so a grant invocation that leaked into the wrong job or
        # the wrong step would make these tests fail, not merely leave a string
        # sitting somewhere harmless.
        function Get-JobBody {
            param([string]$JobName, [string]$Source)
            if ($Source -notmatch "(?ms)^  $JobName`:\r?\n(.*?)(?=^  \w\S*:\r?\n|\z)") {
                throw "Could not isolate job '$JobName' in layer-07-apps.yml."
            }
            return $Matches[1]
        }
        function Get-StepBody {
            param([string]$StepName, [string]$JobBody)
            $escaped = [regex]::Escape($StepName)
            if ($JobBody -notmatch "(?ms)^\s{6}- name: $escaped\r?\n(.*?)(?=^\s{6}- name:|\z)") {
                throw "Could not isolate step '$StepName' in its job body."
            }
            return $Matches[1]
        }

        $script:DeployJob = Get-JobBody -JobName 'deploy' -Source $script:Layer07
        $script:VerifyJob = Get-JobBody -JobName 'verify' -Source $script:Layer07
        $script:GrantStep = Get-StepBody -StepName 'Apply the SQL contained-database user now that the identity exists (F20)' -JobBody $script:DeployJob
    }

    It 'lives in the deploy job (mls-github-deployer, which can write) - not the Reader-only verify job' {
        $script:DeployJob | Should -Match ([regex]::Escape('Apply the SQL contained-database user now that the identity exists (F20)'))
        $script:VerifyJob | Should -Not -Match ([regex]::Escape('Apply the SQL contained-database user now that the identity exists (F20)'))
    }

    It 'runs after the apps (and therefore the data-api identity) are deployed, not before' {
        $deployAppsIndex = $script:DeployJob.IndexOf('- name: Deploy the apps')
        $grantIndex = $script:DeployJob.IndexOf('Apply the SQL contained-database user now that the identity exists (F20)')
        $deployAppsIndex | Should -BeGreaterThan -1
        $grantIndex | Should -BeGreaterThan $deployAppsIndex
    }

    It 'is skipped on a dry run, same as the deployment step it depends on' {
        $script:GrantStep | Should -Match '(?m)^\s*if:\s*\$\{\{\s*!inputs\.dry_run\s*\}\}\s*$'
    }

    It 'invokes seed.ps1 in -SchemaOnly mode - not a bare re-run, and not -Force' {
        # Isolated to the seed.ps1 invocation itself, not the whole step: the step
        # legitimately passes -Force to an unrelated `Install-Module ... -Force`
        # (re-fetch the SqlServer module), which must not make this test pass by
        # matching the wrong command.
        if ($script:GrantStep -notmatch '(?ms)\./data/seed/seed\.ps1.*?-Confirm:\$false') {
            throw 'Could not isolate the seed.ps1 invocation inside the F20 grant step.'
        }
        $seedInvocation = $Matches[0]
        $seedInvocation | Should -Match '(?m)^\s*-Target sql\s*`?\s*$'
        $seedInvocation | Should -Match '(?m)^\s*-SchemaOnly\s*`?\s*$'
        $seedInvocation | Should -Not -Match '-Force\b'
    }

    It 'resolves the Azure SQL server from Azure itself, scoped to the platform RG, not a hardcoded name' {
        $script:GrantStep | Should -Match 'az sql server list'
        $script:GrantStep | Should -Match '\$env:RG_PLATFORM'
        $script:GrantStep | Should -Not -Match 'mls-ops-demo-sql'
    }

    It 'mints its own Azure SQL access token rather than reusing one from another job' {
        $script:GrantStep | Should -Match 'az account get-access-token'
        $script:GrantStep | Should -Match 'https://database\.windows\.net'
    }

    It 'warns and exits zero, rather than failing the deploy, when no SQL server is found yet' {
        # A standalone L7 dispatch ahead of L6 must not fail the apps deploy over a
        # grant that genuinely has nothing to attach to yet.
        $script:GrantStep | Should -Match '(?m)::warning.*No Azure SQL server found'
        $script:GrantStep | Should -Match '(?m)^\s*exit 0\s*$'
    }

    # ---- Task 22 review, Important #1: placement and failure posture ----------
    # The grant is idempotent remediation. It must not be able to cost L7 its
    # Verifier sign-off, and BOTH of the next two tests are needed for that:
    # ordering alone still reds the job, and continue-on-error alone would let a
    # hard failure skip the manifest steps (they carry no always()).

    It 'runs after the V7.1 manifest is written AND uploaded, so a failure here cannot skip them' {
        $writeIndex = $script:DeployJob.IndexOf('- name: Write the V7.1 deploy manifest for the Verifier')
        $uploadIndex = $script:DeployJob.IndexOf('- name: Upload the V7.1 deploy manifest')
        $grantIndex = $script:DeployJob.IndexOf('Apply the SQL contained-database user now that the identity exists (F20)')

        $writeIndex | Should -BeGreaterThan -1
        $uploadIndex | Should -BeGreaterThan $writeIndex
        $grantIndex | Should -BeGreaterThan $uploadIndex
    }

    It 'carries continue-on-error, so a transient failure cannot red the deploy job and starve the verify job' {
        # verify is `needs: [preflight, deploy]`, which requires deploy to SUCCEED.
        # Without this, moving the step later would still cost the layer its
        # sign-off, and L8 is gated on L7 behind that.
        $script:GrantStep | Should -Match '(?m)^\s*continue-on-error:\s*true\s*$'
    }

    It 'distinguishes an Azure CLI failure from "L6 has not deployed yet"' {
        # Both used to look like an empty string, so a throttled or unauthenticated
        # CLI call silently skipped the grant and F20 recurred with only a warning.
        $script:GrantStep | Should -Match '\$LASTEXITCODE'
        $script:GrantStep | Should -Match '(?m)::error.*Azure CLI call failed'
    }

    It 'refuses to guess when more than one non-master database exists' {
        # `| [0]` would silently land the grant on an arbitrary database the moment
        # this estate holds more than one.
        $script:GrantStep | Should -Not -Match "\[\?name!='master'\]\.name\s*\|\s*\[0\]"
        $script:GrantStep | Should -Match '(?m)::error.*Ambiguous Azure SQL database'
    }

    It 'surfaces a failed grant in the run summary, since continue-on-error keeps the job green' {
        $reportStep = Get-StepBody -StepName 'Report a failed F20 grant pass' -JobBody $script:DeployJob
        $reportStep | Should -Match "steps\.f20_grant\.outcome == 'failure'"
        $reportStep | Should -Match 'GITHUB_STEP_SUMMARY'
    }
}

Describe 'F24: data-api is granted the Fabric workspace Viewer role after L7 creates its identity' {
    BeforeAll {
        function Get-JobBody {
            param([string]$JobName, [string]$Source)
            if ($Source -notmatch "(?ms)^  $JobName`:?
(.*?)(?=^  \w\S*:?
|\z)") {
                throw "Could not isolate job '$JobName' in layer-07-apps.yml."
            }
            return $Matches[1]
        }
        function Get-StepBody {
            param([string]$StepName, [string]$JobBody)
            $escaped = [regex]::Escape($StepName)
            if ($JobBody -notmatch "(?ms)^\s{6}- name: $escaped?
(.*?)(?=^\s{6}- name:|\z)") {
                throw "Could not isolate step '$StepName' in its job body."
            }
            return $Matches[1]
        }
        $script:F24DeployJob = Get-JobBody -JobName 'deploy' -Source $script:Layer07
        $script:F24Step = Get-StepBody -StepName 'Grant data-api the Fabric workspace Viewer role now that the identity exists (F24)' -JobBody $script:F24DeployJob
    }

    It 'lives in the deploy job (mls-github-deployer, which can write) - not the Reader-only verify job' {
        $verifyJob = Get-JobBody -JobName 'verify' -Source $script:Layer07
        $script:F24DeployJob | Should -Match ([regex]::Escape('(F24)'))
        $verifyJob | Should -Not -Match ([regex]::Escape('(F24)'))
    }

    It 'actually passes -DataApiPrincipalId - the parameter that existed unwired since Task 12' {
        # The whole finding was that provision-workspace.ps1 carried this parameter
        # and nothing ever passed it. `git grep DataApiPrincipalId -- .github/`
        # returned only a comment.
        $script:F24Step | Should -Match '-DataApiPrincipalId\s+\$principalId'
    }

    It 'grants Viewer only - never a broader workspace role' {
        # provision-workspace.ps1 hardcodes Viewer for both principals; assert this
        # step does not reach for anything wider.
        $script:F24Step | Should -Not -Match '(?i)(Admin|Member|Contributor)'
    }

    It 'resolves the identity''s principal (object) id, not its client id' {
        # The Fabric roleAssignments API takes the object id; clientId is what the
        # container app consumes and would silently grant nothing.
        $script:F24Step | Should -Match 'principalId'
        $script:F24Step | Should -Not -Match '--query .clientId'
    }

    It 'refuses when more than one data-api identity matches, rather than granting to an arbitrary one' {
        $script:F24Step | Should -Match '(?m)::error.*Ambiguous data-api identity'
    }

    It 'distinguishes an Azure CLI failure from "the identity does not exist yet"' {
        $script:F24Step | Should -Match '\$LASTEXITCODE'
        $script:F24Step | Should -Match '(?m)::error.*Azure CLI call failed'
    }

    It 'runs after the V7.1 manifest is written AND uploaded, so a failure here cannot skip them' {
        $writeIndex = $script:F24DeployJob.IndexOf('- name: Write the V7.1 deploy manifest for the Verifier')
        $uploadIndex = $script:F24DeployJob.IndexOf('- name: Upload the V7.1 deploy manifest')
        $grantIndex = $script:F24DeployJob.IndexOf('Grant data-api the Fabric workspace Viewer role now that the identity exists (F24)')

        $writeIndex | Should -BeGreaterThan -1
        $uploadIndex | Should -BeGreaterThan $writeIndex
        $grantIndex | Should -BeGreaterThan $uploadIndex
    }

    It 'carries continue-on-error, so a transient failure cannot red the deploy job and starve the verify job' {
        $script:F24Step | Should -Match '(?m)^\s*continue-on-error:\s*true\s*$'
    }

    It 'surfaces a failed grant in the run summary, since continue-on-error keeps the job green' {
        $reportStep = Get-StepBody -StepName 'Report a failed F24 grant pass' -JobBody $script:F24DeployJob
        $reportStep | Should -Match "steps\.f24_grant\.outcome == 'failure'"
        $reportStep | Should -Match 'GITHUB_STEP_SUMMARY'
    }
}

