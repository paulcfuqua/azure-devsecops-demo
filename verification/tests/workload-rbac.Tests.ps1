# =============================================================================
# F13 (compliance/findings/2026-08-26-prepublication-review.md#f13, Task 12):
# the repo contained zero role assignments for its workload identities. This
# guards the seven of F13's grants this layer can actually express in code
# (F13 documents seven in total; the two listed as NOT asserted below are a
# different thing - they have no principalId available to a static test):
#
#   data-api  -> SQL contained-database user   (data/seed/sql/sql-seed.psm1 Set-SeedWorkloadUser)
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
#   cost-ingest -> Storage Blob Data Reader: LANDED (F19, 2026-08-28), but at
#   L6, not here. infra/bicep/platform/main.bicep now provisions the Function
#   App and its user-assigned identity and grants that identity Storage Blob
#   Data Reader scoped to the cost-exports CONTAINER. It is asserted - by role
#   definition GUID and by scope, the same way this file asserts its own -
#   in verification/tests/cost-ingest.Tests.ps1, which is where the rest of
#   that leg (the Flex Consumption plan, the Event Grid trigger wiring, the
#   Fabric write grant) is guarded too. It is not asserted here because
#   infra/bicep/apps/main.bicep, which this file reads, does not express it and
#   should not: the principal is an L6 resource.
#
#   With it, all seven of F13's documented grants are expressed in code.
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
    $script:SqlSeedModulePath = Join-Path -Path $script:RepoRoot -ChildPath 'data' -AdditionalChildPath 'seed', 'sql', 'sql-seed.psm1'
    $script:FabricApiPath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'fabric', 'fabric-api.psm1'
    $script:ProvisionWorkspacePath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'fabric', 'provision-workspace.ps1'
    $script:WorkloadRoleModulePath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'bicep', 'apps', 'modules', 'workload-role-assignments.bicep'
    $script:LawRoleModulePath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'bicep', 'apps', 'modules', 'log-analytics-reader-role.bicep'
    $script:Layer07Path = Join-Path -Path $script:RepoRoot -ChildPath '.github' -AdditionalChildPath 'workflows', 'layer-07-apps.yml'
    $script:Layer07 = Get-Content -LiteralPath $script:Layer07Path -Raw

    # ONE COPY, HOISTED. These two helpers existed TWICE - here and again inside the
    # F24 Describe - and the copies had already diverged. The second had lost the
    # backslash-r-backslash-n in its regex to a pair of literal newline characters,
    # somewhere in an edit that went through a shell; it still matched, by accident, on
    # an LF file. And only the first learned to accept a QUOTED step name, so renaming a
    # step to 'FAILURE: ...' - which YAML requires quoting, because it contains a colon -
    # was found by one copy and thrown by the other. Two copies of one fact with nothing
    # keeping them equal, which is F151's and F163's shape in a test file.
    function Get-JobBody {
        param([string]$JobName, [string]$Source)
        if ($Source -notmatch "(?ms)^  $JobName`:\r?\n(.*?)(?=^  \w\S*:\r?\n|\z)") {
            throw "Could not isolate job '$JobName' in layer-07-apps.yml."
        }
        return $Matches[1]
    }
    function Get-StepBody {
        param([string]$StepName, [string]$JobBody)
        # THE QUOTES ARE OPTIONAL BECAUSE YAML MAKES THEM MANDATORY. A step name
        # containing a colon - 'FAILURE: the F20/F172 ... grant did not complete' -
        # must be quoted or the mapping is ambiguous, so a matcher that only accepts
        # a bare name silently stops finding exactly the steps whose names say the
        # most. It threw here rather than passing, which is the right direction, but
        # a stricter matcher than the format allows is a test of the format.
        $escaped = [regex]::Escape($StepName)
        if ($JobBody -notmatch "(?ms)^\s{6}- name: ['`"]?$escaped['`"]?\r?\n(.*?)(?=^\s{6}- name:|\z)") {
            throw "Could not isolate step '$StepName' in its job body."
        }
        return $Matches[1]
        }


    # COMMENT-STRIPPED copies of every Bicep file these assertions read (F27).
    # Every occurrence of the strings 'Security Reader', 'Log Analytics Reader'
    # and 'Cost Management Reader' in main.bicep is inside a // comment or an
    # @description(); ZERO are executable Bicep, because the real assignments
    # carry only GUIDs. The tests below used to match those strings, so
    # changing a grant to Owner left the comment reading "Security Reader" and
    # the suite green. Roles are asserted by role definition GUID, in code.
    $script:StrippedBicep = @{}
    foreach ($entry in @(
            @{ Key = 'main'; Path = $script:MainBicepPath },
            @{ Key = 'workloadRole'; Path = $script:WorkloadRoleModulePath },
            @{ Key = 'lawRole'; Path = $script:LawRoleModulePath })) {
        $raw = Get-Content -LiteralPath $entry.Path -Raw
        $script:StrippedBicep[$entry.Key] = (
            ($raw -split "`n") |
                Where-Object { $_ -notmatch '^\s*@description\(' } |
                ForEach-Object { $_ -replace '//.*$', '' }
        ) -join "`n"
    }

    # The built-in role definition GUIDs the grants above must carry. These are
    # Azure-wide constants (learn.microsoft.com/azure/role-based-access-control/
    # built-in-roles); a wrong one is a different role, which is the whole point
    # of asserting them rather than a comment.
    $script:RoleGuid = [ordered]@{
        'Security Reader'        = '39bc4728-0917-49c7-9d2c-d95423bc2eb4'
        'Cost Management Reader' = '72fafb9e-0641-4937-9268-a91bfd8191a3'
        'Log Analytics Reader'   = '73c42c96-874c-492b-b04d-ab87d138a893'
        # THE ONE WRITE ROLE, AND IT IS NOT AN EXCEPTION TO THE RULE - it is the rule
        # working. Adding it failed this suite first, which is what a documented set is
        # for: a fourth GUID appearing silently is either an undocumented grant or a
        # privilege escalation, and this one had to be argued for rather than merged.
        #
        # WHY IT IS NEEDED. Container Apps has no built-in Easy Auth token store; unlike
        # App Service it persists each session's token to a blob container, and it
        # WRITES as well as reads - Storage Blob Data Reader is non-functional here. The
        # control tower needs the store because its Ask tab forwards this session's
        # Entra token to the directline-token Function, so the copilot inherits the
        # identity of the app instead of sitting open beside it (F135). Without the
        # store /.auth/me returns claims and no raw token, which is precisely how the
        # gap was found.
        #
        # WHY IT IS STILL LEAST PRIVILEGE. Scoped to ONE storage account that holds
        # nothing but those session tokens, granted to ONE identity that exists only for
        # this purpose, on an account with shared-key access disabled so RBAC is the only
        # way in. It grants no read of the lakehouse, the estate, or any other store.
        'Storage Blob Data Contributor' = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    }
    # Roles nothing in this layer may ever grant a workload identity. Owner and
    # Contributor are the two that would make F13's least-privilege claim false
    # while every surrounding comment still read correctly.
    $script:ForbiddenRoleGuid = [ordered]@{
        'Owner'                    = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
        'Contributor'              = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
        'User Access Administrator' = '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9'
    }
}

Describe 'workload identities have their grants expressed in code' {
    It 'carries the role definition GUID of every documented grant, in executable Bicep' {
        # Security Reader and Cost Management Reader are passed as literals at
        # their call sites in main.bicep; Log Analytics Reader is a var inside
        # its dedicated module. Both are code; neither is a comment.
        $script:StrippedBicep['main'] | Should -Match ([regex]::Escape($script:RoleGuid['Security Reader']))
        $script:StrippedBicep['main'] | Should -Match ([regex]::Escape($script:RoleGuid['Cost Management Reader']))
        $script:StrippedBicep['lawRole'] | Should -Match ([regex]::Escape($script:RoleGuid['Log Analytics Reader']))
    }

    It 'grants Security Reader to BOTH data-api and mcp-tools, by GUID' {
        ([regex]::Matches($script:StrippedBicep['main'], [regex]::Escape($script:RoleGuid['Security Reader'])).Count) |
            Should -BeGreaterOrEqual 2
    }

    It 'invokes the Log Analytics Reader module twice — once per identity' {
        ([regex]::Matches($script:StrippedBicep['main'], [regex]::Escape('modules/log-analytics-reader-role.bicep')).Count) |
            Should -BeGreaterOrEqual 2
    }

    It 'grants no role outside the documented set' {
        # Every roleDefinitionId literal anywhere in this layer's executable Bicep
        # must be one of the four above. A fifth GUID is either a new grant nobody
        # documented or a privilege escalation.
        #
        # This said "read-only set" until F135 needed Easy Auth's token store, which
        # writes. The rename is deliberate rather than cosmetic: three of the four are
        # still read-only and the fourth is argued for at its definition, but a test
        # whose NAME claims read-only while its list contains a writer would be lying
        # in exactly the way this suite exists to prevent.
        $guidPattern = "'([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'"
        $observed = @()
        foreach ($key in @('main', 'workloadRole', 'lawRole')) {
            $observed += @([regex]::Matches($script:StrippedBicep[$key], $guidPattern) |
                    ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() })
        }
        $allowed = @($script:RoleGuid.Values | ForEach-Object { $_.ToLowerInvariant() })
        foreach ($guid in ($observed | Sort-Object -Unique)) {
            $guid | Should -BeIn $allowed -Because 'every role definition GUID in this layer must be one of the four documented roles, three read-only and one write that is argued for where it is defined'
        }
    }

    It 'never grants Owner, Contributor or User Access Administrator' {
        foreach ($name in $script:ForbiddenRoleGuid.Keys) {
            foreach ($key in @('main', 'workloadRole', 'lawRole')) {
                $script:StrippedBicep[$key] | Should -Not -Match ([regex]::Escape($script:ForbiddenRoleGuid[$name])) `
                    -Because "$name must never be granted to a workload identity"
            }
        }
    }

    It 'uses dedicated modules for the subscription- and resource-scoped grants' {
        Test-Path -LiteralPath $script:WorkloadRoleModulePath | Should -BeTrue
        Test-Path -LiteralPath $script:LawRoleModulePath | Should -BeTrue
        $script:MainBicep | Should -Match 'modules/workload-role-assignments\.bicep'
        $script:MainBicep | Should -Match 'modules/log-analytics-reader-role\.bicep'
    }

    It 'creates the SQL contained-database user in the seed, without depending on Microsoft Graph' {
        # THIS TEST USED TO MATCH `FROM EXTERNAL PROVIDER` IN 900-contained-users.sql,
        # AND IT KEPT PASSING AFTER THE STATEMENT WAS DELETED - because the deleted
        # statement is quoted verbatim in the comment explaining its removal. A green
        # check over a capability that has moved out of the file, satisfied by prose
        # describing its own departure. That is F27's class (matching a string that lives
        # only in a comment) and it is exactly why the assertions below strip comments
        # before reading, and assert the mechanism in the module that now owns it.
        Test-Path -LiteralPath $script:ContainedUsersPath | Should -BeTrue

        # Block comments FIRST - PowerShell's <# .SYNOPSIS #> docstrings are where the
        # history of this grant is written, and they are exactly what must not satisfy an
        # assertion about the code. Then whole-line # comments; a trailing '#' inside a
        # string is left alone, because stripping it would corrupt the SQL being asserted.
        $sqlModule = Get-Content -LiteralPath $script:SqlSeedModulePath -Raw
        $sqlModuleCode = [regex]::Replace($sqlModule, '(?s)<#.*?#>', '')
        $sqlModuleCode = (($sqlModuleCode -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

        # The grant exists, and the SID it writes is the identity's client id.
        $sqlModuleCode | Should -Match 'function Set-SeedWorkloadUser'
        $sqlModuleCode | Should -Match 'CREATE USER \[\$PrincipalName\] WITH SID = '
        $sqlModuleCode | Should -Match 'db_datareader'

        # AND IT ASKS GRAPH NOTHING. FROM EXTERNAL PROVIDER resolves the principal through
        # the SQL server's own managed identity, which needs the Entra "Directory Readers"
        # role - a grant bound to a SYSTEM-ASSIGNED identity that teardown destroys with
        # mls-rg-data and rebuilds with a new principal id, so it silently stops existing
        # on the first rebuild (F172). Comments are stripped first precisely so the
        # explanation of that history cannot satisfy this assertion.
        $sqlModuleCode | Should -Not -Match 'FROM EXTERNAL PROVIDER' `
            -Because 'the contained-user grant must not depend on a tenant role assignment a rebuild erases'
        $ddl = (Get-ChildItem -LiteralPath (Split-Path -Path $script:ContainedUsersPath -Parent) -Filter '*.sql' -File)
        foreach ($file in $ddl) {
            $body = Get-Content -LiteralPath $file.FullName -Raw
            # Block comments are the only comment form these files use.
            $code = [regex]::Replace($body, '(?s)/\*.*?\*/', '')
            $code | Should -Not -Match 'FROM EXTERNAL PROVIDER' `
                -Because "$($file.Name) is applied unconditionally by Install-SeedSchema, including during L6 when the identity does not exist yet - a grant there must be allowed to fail, and a grant that must be allowed to fail cannot also report whether it worked"
        }
    }

    It 'provisions the Fabric workspace role-assignment REST path' {
        $psm1 = Get-Content -LiteralPath $script:FabricApiPath -Raw
        $psm1 | Should -Match 'function Add-FabricWorkspaceRoleAssignment'
        $psm1 | Should -Match 'roleAssignments'
    }

    It 'wires the data-api Fabric workspace Viewer grant into provision-workspace.ps1' {
        # The role used to be a hardcoded `-Role Viewer` on a single call, and this
        # test matched that literal. It is now per-principal, because F19's
        # cost-ingest identity needs Contributor to write to OneLake while these two
        # stay read-only - so the assertion moved to the grant TABLE entry, which is
        # the value actually passed to Add-FabricWorkspaceRoleAssignment. Matching
        # `-Role Viewer` anywhere in the file would now be satisfied by the wrong
        # principal's entry, which is exactly the class of weakness F27 recorded.
        $provision = Get-Content -LiteralPath $script:ProvisionWorkspacePath -Raw
        $provision | Should -Match 'DataApiPrincipalId'
        $provision | Should -Match "Label = 'data-api identity';\s*PrincipalId = \`$DataApiPrincipalId;\s*Role = 'Viewer'"
        # And the role that reaches the API is the table's, not a constant.
        $provision | Should -Match '-Role \$grant\.Role'
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

    It 'resolves the Azure SQL server from Azure itself, scoped to the DATA RG, not a hardcoded name' {
        # This test used to assert $env:RG_PLATFORM, and in doing so it PINNED THE BUG.
        # L6 creates the logical server in the data resource group; the grant step searched
        # the platform group, found nothing, and skipped with "L6 has probably not deployed
        # yet" - so the contained-database user was never created and every SQL-backed
        # /api/tables route answered 502 (F109).
        #
        # A test that asserts the current behaviour rather than the required one turns a
        # defect into a specification. This one did that for days, and it would have blocked
        # the fix if nobody had read it. The right assertion is the group that actually holds
        # the server - and the failure-classes sweep now checks the template still puts it
        # there, so the two cannot drift apart silently.
        $script:GrantStep | Should -Match 'az sql server list'
        $script:GrantStep | Should -Match '\$env:RG_DATA'
        $script:GrantStep | Should -Not -Match '\$env:RG_PLATFORM' `
            -Because 'a SQL lookup against the platform group cannot succeed'
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

    It 'surfaces a failed grant in the run summary, and SAYS SO IN THE STEP NAME' {
        # THE RUN'S STEP LIST IS THE SURFACE PEOPLE ACTUALLY READ, and a step called
        # "Report a failed F20 grant pass" showing `success` is indistinguishable at a
        # glance from nothing being wrong. That is how the 2026-09-03 rebuild reported a
        # deploy job as green while its SQL grant had failed: the reporting step existed,
        # fired, and reported success at reporting a failure. The name must say what its
        # PRESENCE means, so a run list that contains it is a run list that says
        # something broke.
        $name = 'FAILURE: the F20/F172 SQL contained-user grant did not complete'
        $reportStep = Get-StepBody -StepName $name -JobBody $script:DeployJob
        $reportStep | Should -Match "steps\.f20_grant\.outcome == 'failure'"
        $reportStep | Should -Match 'GITHUB_STEP_SUMMARY'
        $name | Should -BeLike 'FAILURE:*'
    }
}

Describe 'F24: data-api is granted the Fabric workspace Viewer role after L7 creates its identity' {
    BeforeAll {
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
        $script:F24Step | Should -Not -Match '(?i)\b(Admin|Member|Contributor)\b'
    }

    It 'resolves the identity''s principal (object) id, not its client id' {
        # The Fabric roleAssignments API takes the object id; clientId is what the
        # container app consumes and would silently grant nothing.
        # Assert the value that is PASSED, not merely that the word appears: the
        # JMESPath projection names both keys, so a bare 'principalId' match is
        # satisfied even by `{name:name, principalId:clientId}` - which would hand
        # the container-app client id to the Fabric roleAssignments API, the exact
        # failure this test exists to prevent.
        $script:F24Step | Should -Match 'principalId:principalId'
        $script:F24Step | Should -Not -Match 'principalId:\s*clientId'
        $script:F24Step | Should -Match '\$principalId\s*=\s*\$ids\[0\]\.principalId'
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

    It 'surfaces a failed grant in the run summary, and SAYS SO IN THE STEP NAME' {
        $name = 'FAILURE: the F24 Fabric workspace grant for data-api did not complete'
        $reportStep = Get-StepBody -StepName $name -JobBody $script:F24DeployJob
        $reportStep | Should -Match "steps\.f24_grant\.outcome == 'failure'"
        $reportStep | Should -Match 'GITHUB_STEP_SUMMARY'
        $name | Should -BeLike 'FAILURE:*'
    }
}

