# Pester tests for verification/layer-03-audit.ps1 - every Graph call mocked; zero cloud
# calls. The expected values come from the real infra/entra/manifest.json, exactly as the
# audit reads them, so a manifest change is felt here too.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-03-audit.ps1')
    # No Set-StrictMode -Off: the audit scripts set -Version Latest and CI runs them
    # that way, so the harness must not relax the language mode it is testing (F49).

    $script:ReportRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-l03-$([guid]::NewGuid().ToString('n'))"
    $script:Domain = 'meridianlaunch.onmicrosoft.com'
    $script:ManifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'infra', 'entra', 'manifest.json'
    # Resolved, not raw: the manifest ships tokenised (${prefix}, ${env}) and the audit
    # under test resolves it before comparing a single name. A fixture reading the raw
    # file would assert on strings the code never sees (F90).
    $script:Manifest = Get-MlsJsonFile -Path $script:ManifestPath -Purpose 'L3 manifest (test fixture)' -TokenReplacement @{ '${prefix}' = (Get-MlsEstateNaming).Prefix; '${env}' = (Get-MlsEstateNaming).Env }
    $script:SkuId = '99999999-9999-9999-9999-999999999999'
    # By FLAG, never by name - the audit finds it the same way, so a rename cannot quietly
    # leave the guard asserting nothing.
    # Get-MlsProperty, not $_.breakGlass: only one of the five manifest groups carries
    # the key, and a bare property read on the other four is a terminating error under
    # the StrictMode the audit runs in. This is now literally 'the same way' the audit
    # finds it (layer-03-audit.ps1:145, :249), which the comment below already claimed.
    $script:BreakGlassGroup = @($script:Manifest.groups | Where-Object { Get-MlsProperty -InputObject $_ -Name 'breakGlass' })
    $script:EnforcedDeclared = @($script:Manifest.conditionalAccessPolicies | Where-Object { $_.state -eq 'enabled' })[0]
    $script:DomainVariable = @('MLS_TENANT_DOMAIN', 'TENANT_DOMAIN')
    $script:SavedEnvironment = @{}
    foreach ($name in $script:DomainVariable) { $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }

    function Get-Row {
        param($Context, [string]$Id)
        return @($Context.Criterion | Where-Object { $_.Id -eq $Id })[0]
    }

    function Invoke-AuditForTest {
        param([switch]$NoRetry, [string]$Domain = $script:Domain)
        Invoke-Main -Domain $Domain -ReportRoot $script:ReportRoot -NoRetry:$NoRetry
    }

    function Get-GroupByName {
        param([string]$Name)
        return @($script:Manifest.groups | Where-Object { $_.displayName -eq $Name })[0]
    }

    function New-LiveCaPolicy {
        <# What Graph would return for one manifest policy: the manifest's display-name
           references resolved to the ids Conditional Access actually stores, so the audit
           is exercised against the shape it will really see. Every deviation a test wants
           to make is a $script: toggle rather than a second hand-written policy. #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pure builder: returns an in-memory object and changes no state.')]
        param($Declared)
        $state = if ($Declared.state -eq 'enabled') { $script:EnforcedState } else { $script:CaState }
        $policy = [pscustomobject]@{ displayName = $Declared.displayName; state = $state }
        if ($Declared.state -ne 'enabled') { return $policy }

        $application = $script:EnforcedApplication
        if ($null -eq $application) {
            $application = @($Declared.conditions.applications.includeApplicationsByDisplayName | ForEach-Object { "appid-$_" })
        }
        $excludeGroup = $script:EnforcedExcludeGroup
        if ($null -eq $excludeGroup) {
            $excludeGroup = @($Declared.conditions.users.excludeGroupsByDisplayName | ForEach-Object { "id-$_" })
        }
        return [pscustomobject]@{
            displayName   = $Declared.displayName
            state         = $state
            grantControls = [pscustomobject]@{ operator = 'OR'; builtInControls = $script:EnforcedGrant }
            conditions    = [pscustomobject]@{
                clientAppTypes = @('all')
                users          = [pscustomobject]@{ includeUsers = @('All'); excludeGroups = @($excludeGroup) }
                applications   = [pscustomobject]@{ includeApplications = @($application) }
            }
        }
    }

    function Get-TestManifestPath {
        <# Writes a copy of the real manifest with the per-user "licensed" flags rewritten,
           and returns its path. -Licensed lists the userPrincipalNamePrefix values to flag
           true; everything else is flagged false. -Strip removes the property entirely,
           which is the pre-2026-08-26 manifest shape. #>
        param([string[]]$Licensed = @(), [switch]$Strip, [Parameter(Mandatory)][string]$Name)
        $manifest = Get-MlsJsonFile -Path $script:ManifestPath -Purpose 'L3 manifest (test fixture)' -TokenReplacement @{ '${prefix}' = (Get-MlsEstateNaming).Prefix; '${env}' = (Get-MlsEstateNaming).Env }
        foreach ($user in $manifest.users) {
            if ($Strip) { $user.PSObject.Properties.Remove('licensed'); continue }
            $user.licensed = [bool]($user.userPrincipalNamePrefix -in $Licensed)
        }
        if (-not (Test-Path -LiteralPath $script:ReportRoot)) {
            New-Item -ItemType Directory -Path $script:ReportRoot -Force | Out-Null
        }
        $path = Join-Path -Path $script:ReportRoot -ChildPath "$Name.json"
        $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
        return $path
    }
}

AfterAll {
    foreach ($name in $script:DomainVariable) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnvironment[$name]) }
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:ReportRoot) {
        Remove-Item -LiteralPath $script:ReportRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'layer-03-audit' {
    BeforeEach {
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'

        $script:CaState = 'enabledForReportingButNotEnforced'
        # The enforced dashboard MFA policy, and everything a test might want to break
        # about it. Defaults describe a correctly deployed tenant.
        $script:EnforcedState = 'enabled'
        $script:EnforcedGrant = @('mfa')
        $script:EnforcedApplication = $null
        $script:EnforcedExcludeGroup = $null
        # A real emergency-access account: cloud-only, and not one of the demo personas.
        $script:BreakGlassMember = @([pscustomobject]@{ id = 'bg-1'; userPrincipalName = "emergency.access@$($script:Domain)" })
        # A populated tenant holds these; individual tests may blank it to prove the
        # empty-group failure is real rather than assumed.
        $script:ExternallyManagedMember = @([pscustomobject]@{ id = 'ext-1'; userPrincipalName = "operator@$($script:Domain)" })
        $script:LicenseState = 'Active'
        $script:LicenseError = 'None'
        $script:MissingMember = ''
        $script:ExtraGroupName = ''
        $script:ExtraApplicationName = ''
        # A REAL TENANT HOLDS THE G0 BOOTSTRAP IDENTITIES, so the default fixture does too.
        # They are prefixed app registrations the manifest declares under
        # bootstrapAppRegistrations and apply-entra.ps1 never creates. A fixture omitting
        # them would model a tenant nobody has, and would leave the exemption path - the
        # thing that stopped the 2026-09-03 rebuild - untested by the happy case.
        $script:LiveBootstrapApplication = @($script:Manifest.bootstrapAppRegistrations | ForEach-Object { $_.displayName })
        # $null means "derive the sweep's result from the manifest above". A test that
        # audits a DIFFERENT manifest - the rebranded one - sets these, because the two
        # startswith sweeps are the only Graph calls whose answer depends on the estate's
        # prefix rather than on a name the caller asked for.
        $script:LiveApplicationOverride = $null
        $script:LiveGroupOverride = $null

        Mock Invoke-MlsGraph {
            if ($Uri -like '*subscribedSkus*') {
                return [pscustomobject]@{ value = @([pscustomobject]@{ skuPartNumber = 'EMSPREMIUM'; skuId = $script:SkuId }) }
            }
            if ($Uri -like '*identitySecurityDefaultsEnforcementPolicy*') {
                # V3.3 asks whether MFA is enforced, not whether a CA policy exists, so it
                # reads this too (F78). Default OFF: the existing tests model a tenant that
                # has already moved to Conditional Access.
                return [pscustomobject]@{ isEnabled = $script:SecurityDefaultsOn }
            }
            if ($Uri -like '*conditionalAccess/policies*') {
                return [pscustomobject]@{ value = @($script:Manifest.conditionalAccessPolicies | ForEach-Object { New-LiveCaPolicy -Declared $_ }) }
            }
            if ($Uri -match '/groups/(?<id>[^/]+)/members') {
                $groupName = $Matches['id'] -replace '^id-', ''
                # Break-glass membership is put there by a human, not by the manifest.
                if ($groupName -in @($script:BreakGlassGroup.displayName)) {
                    return [pscustomobject]@{ value = @($script:BreakGlassMember) }
                }
                # Same for every group the manifest flags membershipManagedExternally: the
                # operator who authors the agent, and the human plus deploy service principal
                # that make up the SQL Entra admin. A populated tenant HAS these members, so
                # a fixture returning none would assert the opposite of what V3.2 now checks.
                # $script:ExternallyManagedMember lets a test empty one deliberately.
                $externallyManaged = @($script:Manifest.groups |
                        Where-Object { $_.PSObject.Properties.Name -contains 'membershipManagedExternally' } |
                        ForEach-Object { $_.displayName })
                if ($groupName -in $externallyManaged) {
                    return [pscustomobject]@{ value = @($script:ExternallyManagedMember) }
                }
                $group = Get-GroupByName -Name $groupName
                $member = @($group.members | Where-Object { $_ -ne $script:MissingMember } | ForEach-Object {
                        [pscustomobject]@{ userPrincipalName = "$_@$($script:Domain)" }
                    })
                return [pscustomobject]@{ value = $member }
            }
            if ($Uri -like '*/groups?*startswith*') {
                $names = if ($null -ne $script:LiveGroupOverride) { @($script:LiveGroupOverride) }
                else { @($script:Manifest.groups | ForEach-Object { $_.displayName }) }
                if ($script:ExtraGroupName) { $names += $script:ExtraGroupName }
                return [pscustomobject]@{ value = @($names | ForEach-Object { [pscustomobject]@{ id = "id-$_"; displayName = $_ } }) }
            }
            if ($Uri -match "/groups\?.*displayName eq '(?<name>[^']+)'") {
                $name = $Matches['name']
                return [pscustomobject]@{ value = @([pscustomobject]@{ id = "id-$name"; displayName = $name }) }
            }
            if ($Uri -like '*/applications?*startswith*') {
                $names = if ($null -ne $script:LiveApplicationOverride) { @($script:LiveApplicationOverride) }
                else { @($script:Manifest.appRegistrations | ForEach-Object { $_.displayName }) + @($script:LiveBootstrapApplication) }
                if ($script:ExtraApplicationName) { $names += $script:ExtraApplicationName }
                return [pscustomobject]@{ value = @($names | ForEach-Object {
                            [pscustomobject]@{ id = "id-$_"; displayName = $_ }
                        })
                }
            }
            if ($Uri -match "/applications\?.*displayName eq '(?<name>[^']+)'") {
                # appId as well as id: Conditional Access scopes to the application (client)
                # id, not the directory object id, and V3.3 compares against exactly that.
                return [pscustomobject]@{ value = @([pscustomobject]@{
                            id = "id-$($Matches['name'])"; appId = "appid-$($Matches['name'])"; displayName = $Matches['name']
                        }) }
            }
            if ($Uri -like '*/users/*licenseAssignmentStates*') {
                return [pscustomobject]@{
                    licenseAssignmentStates = @([pscustomobject]@{ skuId = $script:SkuId; state = $script:LicenseState; error = $script:LicenseError })
                }
            }
            if ($Uri -like '*/users/*') {
                return [pscustomobject]@{ id = 'user-object-id'; userPrincipalName = ($Uri -split '/')[-1] }
            }
            throw "unexpected Graph call: $Uri"
        }
    }

    Context 'all criteria pass' {
        It 'records V3.1-V3.4 as PASS and exits 0' {
            $context = Invoke-AuditForTest
            @($context.Criterion).Id | Should -Be @('V3.1', 'V3.2', 'V3.3', 'V3.4')
            @($context.Criterion | Where-Object { $_.Status -ne 'PASS' }) | Should -BeNullOrEmpty
            Get-MlsExitCode -Context $context | Should -Be 0
        }

        It 'expects exactly the manifest counts' {
            # Counts come FROM the manifest, not from literals: F25 added a fourth app
            # registration (mls-compliance-demo-app, for the compliance board's Easy
            # Auth) and this assertion's hardcoded "3 app registrations" was the only
            # thing in the repo that went red for it. The manifest is the source of
            # truth for V3.1, so the test reads it the same way the audit does.
            $context = Invoke-AuditForTest
            $expected = (Get-Row -Context $context -Id 'V3.1').Expected
            $expected | Should -BeLike "*$(@($script:Manifest.users).Count) users*"
            $expected | Should -BeLike "*$(@($script:Manifest.groups).Count) groups*"
            $expected | Should -BeLike "*$(@($script:Manifest.appRegistrations).Count) app registrations*"
            # Guard against the counts silently collapsing to zero if the manifest
            # ever fails to parse: the demo has five users, four groups, four apps.
            @($script:Manifest.appRegistrations).Count | Should -Be 4
        }
    }

    Context 'V3.4 follows the per-user "licensed" flag (seat-cost decision, 2026-08-26)' {
        It 'audits only the flagged users and leaves V3.1 counting all 5' {
            $path = Get-TestManifestPath -Licensed @('dana.reyes', 'miles.okafor') -Name 'two-licensed'
            $context = Invoke-Main -Domain $script:Domain -ManifestPath $path -ReportRoot $script:ReportRoot -NoRetry
            $row = Get-Row -Context $context -Id 'V3.4'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*dana.reyes*'
            $row.Observed | Should -BeLike '*miles.okafor*'
            # The unlicensed three are deliberately absent from V3.4 ...
            $row.Observed | Should -Not -BeLike '*sofia.lindqvist*'
            $row.Observed | Should -Not -BeLike '*marcus.webb*'
            # ... but must still exist and still be counted by V3.1.
            (Get-Row -Context $context -Id 'V3.1').Expected | Should -BeLike '*5 users*'
            (Get-Row -Context $context -Id 'V3.1').Status | Should -Be 'PASS'
        }

        It 'fails when a flagged user is the one missing its assignment' {
            $script:LicenseState = 'Error'
            $script:LicenseError = 'CountViolation'
            $path = Get-TestManifestPath -Licensed @('dana.reyes') -Name 'one-licensed-broken'
            $context = Invoke-Main -Domain $script:Domain -ManifestPath $path -ReportRoot $script:ReportRoot -NoRetry
            $row = Get-Row -Context $context -Id 'V3.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*CountViolation*'
        }

        It 'passes with an explicit note when no user is flagged licensed' {
            $path = Get-TestManifestPath -Licensed @() -Name 'none-licensed'
            $context = Invoke-Main -Domain $script:Domain -ManifestPath $path -ReportRoot $script:ReportRoot -NoRetry
            $row = Get-Row -Context $context -Id 'V3.4'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*no manifest user is flagged licensed*'
        }

        It 'treats a manifest without the flag as fully licensed (backward compatible)' {
            $path = Get-TestManifestPath -Strip -Name 'no-flag'
            $context = Invoke-Main -Domain $script:Domain -ManifestPath $path -ReportRoot $script:ReportRoot -NoRetry
            $row = Get-Row -Context $context -Id 'V3.4'
            $row.Status | Should -Be 'PASS'
            foreach ($prefix in @('dana.reyes', 'miles.okafor', 'priya.natarajan', 'sofia.lindqvist', 'marcus.webb')) {
                $row.Observed | Should -BeLike "*$prefix*"
            }
        }
    }

    Context 'a criterion fails on a realistic wrong value' {
        It 'fails V3.3 immediately when a BROAD CA policy is enforced, and flags the safety risk' {
            # $script:CaState drives only the two All-users/All-applications policies. Those
            # enforced in an adopter's tenant is a lockout; the dashboard MFA policy being
            # enforced is the point of the layer, and the message says which case this is.
            $script:CaState = 'enabled'
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V3.3'
            $row.Status | Should -Be 'FAIL'
            $row.Attempt | Should -Be 1
            $row.Detail | Should -BeLike '*SAFETY FLAG*'
            $row.Observed | Should -BeLike '*mls-ca-require-mfa-admins*'
            Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 0
        }

        It 'fails V3.4 when group licensing reports CountViolation' {
            $script:LicenseState = 'Error'
            $script:LicenseError = 'CountViolation'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V3.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*CountViolation*'
        }

        It 'fails V3.2 when a manifest member is missing from its group' {
            $script:MissingMember = 'marcus.webb'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V3.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*missing*marcus.webb*'
        }

        It 'fails V3.1 on drift - an mls-prefixed group the manifest does not declare' {
            $script:ExtraGroupName = 'mls-shadow-admins'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V3.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*mls-shadow-admins*'
        }
    }

    Context 'V3.1 drift sweep and the G0 bootstrap identities' {
        # The 2026-09-03 rebuild stopped here. mls-purview - the certificate-bearing
        # Security & Compliance identity g0-bootstrap.md step 11c creates BY HAND, because
        # Security & Compliance PowerShell has no federated auth path - was reported as
        # drift, correctly, because nothing in this repository declared it. The exemption
        # list was the literal @('mls-github-deployer', 'mls-verifier') inside the audit:
        # a second source of truth for which identities the estate has, in the one file
        # whose job is to have none, that also hardcoded the company prefix.

        It 'passes with the declared bootstrap identities present, and says it saw them' {
            # The regression test for the blocker itself: mls-purview in the tenant, and
            # V3.1 green because the MANIFEST declares it, not because the audit knows
            # its name.
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V3.1'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike "*bootstrap (not applied by L3) $($script:LiveBootstrapApplication.Count)/$($script:LiveBootstrapApplication.Count) present*"
            foreach ($name in $script:LiveBootstrapApplication) {
                $row.Observed | Should -Not -BeLike "*drift*$name*"
            }
        }

        It 'still fails on an undeclared prefixed app registration' {
            # The control has to keep its teeth. An exemption that swallowed anything
            # prefixed would destroy the only thing this sweep does.
            $script:ExtraApplicationName = 'mls-shadow-app'
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V3.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*drift*mls-shadow-app*'
        }

        It 'exempts by exact name, not by resemblance to a bootstrap identity' {
            # A per-name declaration, never a pattern: an attacker who names their
            # registration after one of ours gets no cover from it.
            $script:ExtraApplicationName = "$($script:LiveBootstrapApplication[0])-2"
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V3.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike "*drift*$($script:LiveBootstrapApplication[0])-2*"
        }

        It 'reports an absent bootstrap identity rather than failing on it' {
            # A clone that has not run g0 step 11c genuinely has no mls-purview, and L4's
            # documented degrade path covers exactly that (F43). Absence is a fact to
            # report, not drift - but it must not be SILENT, because a bootstrap identity
            # is in no count above and a deleted one was invisible to V3.1 before this.
            $absent = $script:LiveBootstrapApplication[-1]
            $script:LiveBootstrapApplication = @($script:LiveBootstrapApplication | Where-Object { $_ -ne $absent })
            $row = Get-Row -Context (Invoke-AuditForTest) -Id 'V3.1'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike "*absent: $absent*"
        }

        It 'fails IMMEDIATELY on drift instead of waiting out the propagation window' {
            # Propagation makes a DECLARED object appear late; it cannot make an EXTRA
            # object disappear, so re-polling can never change this verdict. The run that
            # found the blocker spent 45.9 minutes - the entire window, on the critical
            # path of a rebuild that claims to complete in under an hour - re-asking a
            # question answered at the first poll, while the counts half of the same
            # message already read 5/5, 7/7, 4/4.
            #
            # Deliberately NOT -NoRetry: the retry window is the thing under test.
            $script:ExtraApplicationName = 'mls-shadow-app'
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V3.1'
            $row.Status | Should -Be 'FAIL'
            $row.Attempt | Should -Be 1
            $row.SleptSeconds | Should -Be 0
            Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 0
        }

        It 'derives the exemption from the prefix, so a rebrand does not fail a correct estate' {
            # F90's class. With the old literal list, MLS_COMPANY_PREFIX=acme made the
            # sweep look for acme-prefixed apps, find acme-github-deployer, match neither
            # 'mls-...' literal and fail V3.1 permanently on an estate that was right.
            #
            # Test-DirectoryObjectCount is called directly: Invoke-Main resolves the prefix
            # from naming.bicep for the whole run, and the point here is that NOTHING in
            # the drift sweep carries a prefix of its own.
            $raw = Get-Content -LiteralPath $script:ManifestPath -Raw
            $rebranded = ($raw.Replace('${prefix}', 'acme').Replace('${env}', 'demo')) | ConvertFrom-Json
            $script:LiveApplicationOverride = @($rebranded.appRegistrations | ForEach-Object { $_.displayName }) +
                @($rebranded.bootstrapAppRegistrations | ForEach-Object { $_.displayName })
            $script:LiveGroupOverride = @($rebranded.groups | ForEach-Object { $_.displayName })

            $result = Test-DirectoryObjectCount -Manifest $rebranded -Domain $script:Domain -NamingPrefix 'acme'
            $result.Passed | Should -BeTrue -Because 'every acme-prefixed object is declared, including the three bootstrap identities'
            $result.Observed | Should -BeLike '*bootstrap (not applied by L3) 3/3 present*'
        }
    }

    Context 'V3.3 asserts that MFA is ENFORCED on the dashboards (2026-08-28)' {
        It 'passes only with the dashboard policy enabled and the broad ones report-only' {
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V3.3'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike "*$($script:EnforcedDeclared.displayName)=enabled*"
            $row.Observed | Should -BeLike '*mfa*'
            $row.Observed | Should -BeLike '*break-glass*'
            $row.Expected | Should -BeLike '*State == enabled*'
        }

        It 'fails when the dashboard MFA policy is left report-only' {
            # The regression this whole change exists to prevent: sign-in works, no second
            # factor is ever asked for, and the old V3.3 called that a PASS.
            $script:EnforcedState = 'enabledForReportingButNotEnforced'
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V3.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike "*$($script:EnforcedDeclared.displayName) is 'enabledForReportingButNotEnforced'*"
            $row.Detail | Should -Not -BeLike '*SAFETY FLAG*'
        }

        It 'fails when the enforced policy is widened to every application' {
            $script:EnforcedApplication = @('All')
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V3.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike "*ENFORCED against every application*"
        }

        It 'fails when the enforced policy covers only some of the dashboards' {
            $script:EnforcedApplication = @("appid-$(@($script:EnforcedDeclared.conditions.applications.includeApplicationsByDisplayName)[0])")
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V3.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*application scope missing*'
        }

        It 'fails when the enforced policy no longer grants mfa' {
            $script:EnforcedGrant = @('compliantDevice')
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V3.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*not mfa*'
        }

        It 'fails when the break-glass exclusion is gone' {
            # An enforced policy with nothing excluded is exactly the misconfiguration that
            # locks a tenant owner out of their own tenant.
            $script:EnforcedExcludeGroup = @()
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V3.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*does NOT exclude break-glass group*'
        }

        It 'fails when the break-glass group is excluded but empty' {
            # An exclusion pointing at an empty group only looks like a recovery path.
            $script:SecurityDefaultsOn = $false
        $script:BreakGlassMember = @()
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V3.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*no such group holds a cloud-only emergency-access account*'
        }

        It 'fails when the only break-glass member is one of the fictional demo personas' {
            $script:BreakGlassMember = @([pscustomobject]@{ id = 'p1'; userPrincipalName = "$($script:Manifest.users[0].userPrincipalNamePrefix)@$($script:Domain)" })
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V3.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*emergency-access account*'
        }

        It 'fails when the only break-glass member is synced from on-premises' {
            $script:BreakGlassMember = @([pscustomobject]@{ id = 'bg-1'; userPrincipalName = "emergency.access@$($script:Domain)"; onPremisesSyncEnabled = $true })
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V3.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*emergency-access account*'
        }

        It 'still fails, retryably, when the enforced policy was never created at all' {
            # What the tenant looks like after apply-entra.ps1 REFUSES an enforced policy
            # for want of a break-glass account: the policy is simply absent.
            Mock Invoke-MlsGraph {
                if ($Uri -like '*identitySecurityDefaultsEnforcementPolicy*') {
                # V3.3 asks whether MFA is enforced, not whether a CA policy exists, so it
                # reads this too (F78). Default OFF: the existing tests model a tenant that
                # has already moved to Conditional Access.
                return [pscustomobject]@{ isEnabled = $script:SecurityDefaultsOn }
            }
            if ($Uri -like '*conditionalAccess/policies*') {
                    return [pscustomobject]@{ value = @($script:Manifest.conditionalAccessPolicies |
                                Where-Object { $_.state -ne 'enabled' } | ForEach-Object { New-LiveCaPolicy -Declared $_ }) }
                }
                if ($Uri -like '*subscribedSkus*') { return [pscustomobject]@{ value = @([pscustomobject]@{ skuPartNumber = 'EMSPREMIUM'; skuId = $script:SkuId }) } }
                if ($Uri -like '*/users/*licenseAssignmentStates*') { return [pscustomobject]@{ licenseAssignmentStates = @([pscustomobject]@{ skuId = $script:SkuId; state = 'Active'; error = 'None' }) } }
                if ($Uri -like '*/users/*') { return [pscustomobject]@{ id = 'u' } }
                if ($Uri -match '/groups/(?<id>[^/]+)/members') { return [pscustomobject]@{ value = @() } }
                if ($Uri -like '*/groups?*startswith*') { return [pscustomobject]@{ value = @($script:Manifest.groups | ForEach-Object { [pscustomobject]@{ id = "id-$($_.displayName)"; displayName = $_.displayName } }) } }
                if ($Uri -match "/groups\?.*displayName eq '(?<name>[^']+)'") { return [pscustomobject]@{ value = @([pscustomobject]@{ id = "id-$($Matches['name'])"; displayName = $Matches['name'] }) } }
                if ($Uri -like '*/applications?*startswith*') { return [pscustomobject]@{ value = @($script:Manifest.appRegistrations | ForEach-Object { [pscustomobject]@{ id = 'a'; displayName = $_.displayName } }) } }
                if ($Uri -match "/applications\?.*displayName eq '(?<name>[^']+)'") { return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'a'; appId = "appid-$($Matches['name'])"; displayName = $Matches['name'] }) } }
                throw "unexpected Graph call: $Uri"
            }
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V3.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*manifest CA policies visible*'
            $row.Detail | Should -BeLike '*break-glass*'
        }

        It 'maps to no control, deliberately' {
            # A green V3.3 now proves MFA is enforced for the three dashboards AND, in the
            # same breath, that mls-ca-require-mfa-admins is report-only - so it does not
            # demonstrate 3.5.3, which requires MFA for privileged accounts as well.
            # compliance/assessment/3.5.3.json carries the authored record instead.
            $row = Get-Row -Context (Invoke-AuditForTest) -Id 'V3.3'
            @($row.Control).Count | Should -Be 0
        }
    }

    Context 'a malformed enforced policy is a finding, not a crash' {
        # These two reach for -Version Latest explicitly, from back when this whole file
        # ran Set-StrictMode -Off and could not otherwise see that the audit runs under
        # Latest, where reading a property the manifest does not have THROWS. The -Off
        # is gone now (F49) and the whole file runs in the audit's own mode, so the
        # explicit calls below are redundant - kept because they document the intent of
        # these two cases, which is that mode specifically.
        BeforeEach {
            function New-BrokenManifestPath {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Test fixture: writes one temp file under the suite report root.')]
                param([Parameter(Mandatory)][scriptblock]$Break, [Parameter(Mandatory)][string]$Name)
                $manifest = Get-MlsJsonFile -Path $script:ManifestPath -Purpose 'L3 manifest (test fixture)' -TokenReplacement @{ '${prefix}' = (Get-MlsEstateNaming).Prefix; '${env}' = (Get-MlsEstateNaming).Env }
                $policy = @($manifest.conditionalAccessPolicies | Where-Object { $_.state -eq 'enabled' })[0]
                & $Break $policy
                if (-not (Test-Path -LiteralPath $script:ReportRoot)) {
                    New-Item -ItemType Directory -Path $script:ReportRoot -Force | Out-Null
                }
                $path = Join-Path -Path $script:ReportRoot -ChildPath "$Name.json"
                $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8
                return $path
            }
        }

        It 'names the missing break-glass exclusion instead of throwing on the absent property' {
            $path = New-BrokenManifestPath -Name 'no-exclusion' -Break {
                param($Policy) $Policy.conditions.users.PSObject.Properties.Remove('excludeGroupsByDisplayName')
            }
            Set-StrictMode -Version Latest
            $context = Invoke-Main -Domain $script:Domain -ManifestPath $path -ReportRoot $script:ReportRoot -NoRetry
            $row = Get-Row -Context $context -Id 'V3.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*declares no break-glass group exclusion*'
            $row.Observed | Should -Not -BeLike '*check threw*'
        }

        It 'names an enforced policy that covers no application instead of throwing' {
            $path = New-BrokenManifestPath -Name 'no-applications' -Break {
                param($Policy) $Policy.conditions.applications.PSObject.Properties.Remove('includeApplicationsByDisplayName')
            }
            Set-StrictMode -Version Latest
            $context = Invoke-Main -Domain $script:Domain -ManifestPath $path -ReportRoot $script:ReportRoot -NoRetry
            $row = Get-Row -Context $context -Id 'V3.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*names no application*'
            $row.Observed | Should -Not -BeLike '*check threw*'
        }
    }

    Context 'V3.2 and the break-glass group' {
        It 'does not hold the break-glass group to the manifest membership it deliberately omits' {
            # The account an adopter is REQUIRED to add would otherwise read as an "extra"
            # member and fail V3.2 for doing the right thing.
            $row = Get-Row -Context (Invoke-AuditForTest) -Id 'V3.2'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*membership managed outside the manifest*'
        }
    }

    Context 'membership managed outside the manifest' {
        It 'fails V3.2 when such a group is empty, because an empty group grants nothing' {
            # The flag exempts a group from SET EQUALITY, not from being checked. Declaring
            # members: [] and asserting equality would require the group to be EMPTY - the
            # opposite of what is wanted for the operator who authors the Copilot Studio
            # agent, or the SQL Entra admin (F92). So the assertion becomes non-empty, and
            # this proves it is real rather than a skip wearing a check's name.
            $script:ExternallyManagedMember = @()
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V3.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'grants nothing'
        }

        It 'passes V3.2 without naming the members, when the group is populated' {
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V3.2'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -Match 'managed outside the manifest'
        }
    }

    Context 'retry' {
        It 'retries V3.1 through propagation lag and passes without sleeping the whole window' {
            $script:Calls = 0
            Mock Invoke-MlsGraph {
                if ($Uri -like '*/users/*licenseAssignmentStates*') {
                    return [pscustomobject]@{ licenseAssignmentStates = @([pscustomobject]@{ skuId = $script:SkuId; state = 'Active'; error = 'None' }) }
                }
                if ($Uri -like '*/users/*') {
                    $script:Calls++
                    # First pass: the last user has not replicated yet.
                    if ($script:Calls -eq 5) { return $null }
                    return [pscustomobject]@{ id = 'user-object-id' }
                }
                if ($Uri -like '*subscribedSkus*') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ skuPartNumber = 'EMSPREMIUM'; skuId = $script:SkuId }) }
                }
                if ($Uri -like '*identitySecurityDefaultsEnforcementPolicy*') {
                # V3.3 asks whether MFA is enforced, not whether a CA policy exists, so it
                # reads this too (F78). Default OFF: the existing tests model a tenant that
                # has already moved to Conditional Access.
                return [pscustomobject]@{ isEnabled = $script:SecurityDefaultsOn }
            }
            if ($Uri -like '*conditionalAccess/policies*') {
                    return [pscustomobject]@{ value = @($script:Manifest.conditionalAccessPolicies | ForEach-Object {
                                [pscustomobject]@{ displayName = $_.displayName; state = 'enabledForReportingButNotEnforced' } })
                    }
                }
                if ($Uri -match '/groups/(?<id>[^/]+)/members') {
                    $group = Get-GroupByName -Name ($Matches['id'] -replace '^id-', '')
                    # A group whose membership is managed outside the manifest is populated in
                    # a real tenant; returning the manifest's empty list would make V3.2 fail
                    # and retry, consuming the wait budget this test measures on V3.1.
                    if ($group.PSObject.Properties.Name -contains 'membershipManagedExternally') {
                        return [pscustomobject]@{ value = @($script:ExternallyManagedMember) }
                    }
                    return [pscustomobject]@{ value = @($group.members | ForEach-Object { [pscustomobject]@{ userPrincipalName = "$_@$($script:Domain)" } }) }
                }
                if ($Uri -like '*/groups?*startswith*') {
                    return [pscustomobject]@{ value = @($script:Manifest.groups | ForEach-Object { [pscustomobject]@{ id = "id-$($_.displayName)"; displayName = $_.displayName } }) }
                }
                if ($Uri -match "/groups\?.*displayName eq '(?<name>[^']+)'") {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = "id-$($Matches['name'])"; displayName = $Matches['name'] }) }
                }
                if ($Uri -like '*/applications?*startswith*') {
                    return [pscustomobject]@{ value = @($script:Manifest.appRegistrations | ForEach-Object { [pscustomobject]@{ id = "id-$($_.displayName)"; displayName = $_.displayName } }) }
                }
                if ($Uri -match "/applications\?.*displayName eq '(?<name>[^']+)'") {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = "id-x"; displayName = $Matches['name'] }) }
                }
                throw "unexpected Graph call: $Uri"
            }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V3.1'
            $row.Status | Should -Be 'PASS'
            $row.Attempt | Should -Be 2
            # One poll interval, not the whole window - asserted against the row's own
            # cadence rather than a literal, so right-sizing the defaults (F59) cannot
            # silently turn this into a test of a constant nobody re-checked.
            $row.SleptSeconds | Should -Be $row.PollIntervalSecond
            $row.SleptSeconds | Should -BeLessThan ($row.RetryWindowMinutes * 60)
            Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 1
        }
    }

    Context 'a check that throws' {
        It 'records V3.3 as FAIL and still evaluates the other criteria' {
            Mock Invoke-MlsGraph {
                if ($Uri -like '*identitySecurityDefaultsEnforcementPolicy*') {
                # V3.3 asks whether MFA is enforced, not whether a CA policy exists, so it
                # reads this too (F78). Default OFF: the existing tests model a tenant that
                # has already moved to Conditional Access.
                return [pscustomobject]@{ isEnabled = $script:SecurityDefaultsOn }
            }
            if ($Uri -like '*conditionalAccess/policies*') { throw 'Authorization_RequestDenied: Policy.Read.All is not consented on mls-verifier.' }
                if ($Uri -like '*subscribedSkus*') { return [pscustomobject]@{ value = @([pscustomobject]@{ skuPartNumber = 'EMSPREMIUM'; skuId = $script:SkuId }) } }
                if ($Uri -like '*/users/*licenseAssignmentStates*') { return [pscustomobject]@{ licenseAssignmentStates = @([pscustomobject]@{ skuId = $script:SkuId; state = 'Active'; error = 'None' }) } }
                if ($Uri -like '*/users/*') { return [pscustomobject]@{ id = 'u' } }
                if ($Uri -match '/groups/(?<id>[^/]+)/members') {
                    $group = Get-GroupByName -Name ($Matches['id'] -replace '^id-', '')
                    return [pscustomobject]@{ value = @($group.members | ForEach-Object { [pscustomobject]@{ userPrincipalName = "$_@$($script:Domain)" } }) }
                }
                if ($Uri -like '*/groups?*startswith*') { return [pscustomobject]@{ value = @($script:Manifest.groups | ForEach-Object { [pscustomobject]@{ id = "id-$($_.displayName)"; displayName = $_.displayName } }) } }
                if ($Uri -match "/groups\?.*displayName eq '(?<name>[^']+)'") { return [pscustomobject]@{ value = @([pscustomobject]@{ id = "id-$($Matches['name'])"; displayName = $Matches['name'] }) } }
                if ($Uri -like '*/applications?*startswith*') { return [pscustomobject]@{ value = @($script:Manifest.appRegistrations | ForEach-Object { [pscustomobject]@{ id = 'a'; displayName = $_.displayName } }) } }
                if ($Uri -match "/applications\?.*displayName eq '(?<name>[^']+)'") { return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'a'; displayName = $Matches['name'] }) } }
                throw "unexpected Graph call: $Uri"
            }
            $context = Invoke-AuditForTest -NoRetry
            @($context.Criterion).Count | Should -Be 4
            (Get-Row -Context $context -Id 'V3.3').Status | Should -Be 'FAIL'
            (Get-Row -Context $context -Id 'V3.3').Observed | Should -BeLike '*Authorization_RequestDenied*'
            (Get-Row -Context $context -Id 'V3.4').Status | Should -Be 'PASS'
        }
    }

    Context 'missing input' {
        It 'refuses to run without the tenant domain, because UPNs cannot be composed without it' {
            foreach ($name in $script:DomainVariable) { [Environment]::SetEnvironmentVariable($name, $null) }
            { Invoke-AuditForTest -Domain '' } | Should -Throw '*Domain*'
            { Invoke-AuditForTest -Domain '' } | Should -Throw '*MLS_TENANT_DOMAIN*'
        }

        It 'refuses to run when the manifest is absent' {
            { Invoke-Main -Domain $script:Domain -ManifestPath (Join-Path -Path $script:ReportRoot -ChildPath 'no-manifest.json') -ReportRoot $script:ReportRoot } |
                Should -Throw '*not found*'
        }
    }
}

Describe 'V3.4 matches the licence capability, not the bundle name' {
    # The live tenant runs Microsoft 365 E5 (SPE_E5), which provides every capability EMS
    # Premium does and contains the substring EMSPREMIUM nowhere. V3.4 pinned the bundle
    # name and reported "SKU 'EMSPREMIUM' is not present on the tenant" about a tenant
    # holding 25 seats of a superset licence (F73).

    BeforeAll {
        Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'MlsAudit.psm1') -Force
        $env:MLS_SKIP_MAIN = '1'
        . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-03-audit.ps1')

        function Get-SkuWithPlan {
            param([string]$PartNumber, [string]$Id, [string[]]$Plans)
            return [pscustomobject]@{
                skuPartNumber = $PartNumber
                skuId         = $Id
                servicePlans  = @($Plans | ForEach-Object {
                        [pscustomobject]@{ servicePlanName = $_; provisioningStatus = 'Success' }
                    })
            }
        }
        $script:E5Id = 'e5-sku-id'
        $script:Manifest3 = [pscustomobject]@{
            users = @([pscustomobject]@{ userPrincipalNamePrefix = 'dana.reyes'; licensed = $true })
        }
    }

    It 'accepts Microsoft 365 E5, which is a superset under a different name' {
        Mock Invoke-MlsGraph {
            if ($Uri -like '*subscribedSkus*') {
                return [pscustomobject]@{ value = @(Get-SkuWithPlan -PartNumber 'SPE_E5' -Id $script:E5Id `
                            -Plans @('AAD_PREMIUM', 'AAD_PREMIUM_P2', 'MFA_PREMIUM', 'INTUNE_A')) }
            }
            return [pscustomobject]@{ licenseAssignmentStates = @([pscustomobject]@{ skuId = $script:E5Id; state = 'Active'; error = 'None' }) }
        }

        $result = Test-LicenseAssignment -Manifest $script:Manifest3 -Domain 'contoso.example' -LicenseSkuPartNumber 'EMSPREMIUM'
        $result.Passed | Should -BeTrue -Because 'E5 provides AAD_PREMIUM and MFA_PREMIUM, which is what L3 actually needs'
    }

    It 'still fails when no SKU provides the capability, and names what the tenant does have' {
        Mock Invoke-MlsGraph {
            if ($Uri -like '*subscribedSkus*') {
                return [pscustomobject]@{ value = @(Get-SkuWithPlan -PartNumber 'O365_BUSINESS' -Id 'b-id' -Plans @('EXCHANGE_S_STANDARD')) }
            }
            return [pscustomobject]@{ licenseAssignmentStates = @() }
        }

        $result = Test-LicenseAssignment -Manifest $script:Manifest3 -Domain 'contoso.example' -LicenseSkuPartNumber 'EMSPREMIUM'
        $result.Passed | Should -BeFalse
        $result.Observed | Should -BeLike '*O365_BUSINESS*' -Because 'the operator needs to know what IS there, not only what is missing'
    }

    It 'ignores a plan that is provisioned but not Success' {
        # A pending plan is not a usable capability.
        Mock Invoke-MlsGraph {
            if ($Uri -like '*subscribedSkus*') {
                return [pscustomobject]@{ value = @([pscustomobject]@{
                            skuPartNumber = 'SPE_E5'; skuId = $script:E5Id
                            servicePlans  = @(
                                [pscustomobject]@{ servicePlanName = 'AAD_PREMIUM'; provisioningStatus = 'Success' }
                                [pscustomobject]@{ servicePlanName = 'MFA_PREMIUM'; provisioningStatus = 'PendingActivation' }
                            )
                        }) }
            }
            return [pscustomobject]@{ licenseAssignmentStates = @() }
        }

        $result = Test-LicenseAssignment -Manifest $script:Manifest3 -Domain 'contoso.example' -LicenseSkuPartNumber 'EMSPREMIUM'
        $result.Passed | Should -BeFalse
    }
}

Describe 'V3.3 asserts MFA enforcement, not the mechanism that provides it' {
    # 3.5.3 asks whether multifactor authentication is enforced. Security Defaults enforce
    # it, and Graph refuses an enabled CA policy while they are on - so on a default tenant,
    # which is every new tenant, V3.3 failed against an estate whose MFA was in fact
    # enforced. Making that green by disabling Security Defaults would take baseline MFA
    # from every user to satisfy a test (F75/F78).

    BeforeAll {
        Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'MlsAudit.psm1') -Force
        $env:MLS_SKIP_MAIN = '1'
        . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-03-audit.ps1')
    }

    BeforeEach {
        $script:Declared = [pscustomobject]@{ conditionalAccessPolicies = @(
                [pscustomobject]@{ displayName = 'mls-ca-require-mfa-admins'; state = 'enabledForReportingButNotEnforced' }
                [pscustomobject]@{ displayName = 'mls-ca-block-legacy-auth'; state = 'enabledForReportingButNotEnforced' }
                [pscustomobject]@{ displayName = 'mls-ca-require-mfa-dashboards'; state = 'enabled' }
            ) }
        # Only the report-only policies exist: exactly what Security Defaults permits.
        $script:LivePolicies = @(
            [pscustomobject]@{ displayName = 'mls-ca-require-mfa-admins'; state = 'enabledForReportingButNotEnforced' }
            [pscustomobject]@{ displayName = 'mls-ca-block-legacy-auth'; state = 'enabledForReportingButNotEnforced' }
        )
    }

    It 'PASSES when Security Defaults enforce MFA and only the enforced policy is absent' {
        Mock Invoke-MlsGraph {
            if ($Uri -like '*identitySecurityDefaultsEnforcementPolicy*') { return [pscustomobject]@{ isEnabled = $true } }
            return [pscustomobject]@{ value = $script:LivePolicies }
        }
        $result = Test-ConditionalAccessState -Manifest $script:Declared -Domain 'x.example'
        $result.Passed | Should -BeTrue
        $result.Observed | Should -BeLike '*enforced by Security Defaults*'
        $result.Detail | Should -BeLike '*Do not disable Security Defaults*' -Because 'the obvious remedy is the dangerous one'
    }

    It 'still FAILS when Security Defaults are off and the enforced policy is missing' {
        # No other mechanism is enforcing MFA, so a missing enforced policy is a real gap.
        Mock Invoke-MlsGraph {
            if ($Uri -like '*identitySecurityDefaultsEnforcementPolicy*') { return [pscustomobject]@{ isEnabled = $false } }
            return [pscustomobject]@{ value = $script:LivePolicies }
        }
        (Test-ConditionalAccessState -Manifest $script:Declared -Domain 'x.example').Passed | Should -BeFalse
    }

    It 'still FAILS when a REPORT-ONLY policy is missing, even under Security Defaults' {
        # Security Defaults explain an absent ENFORCED policy. They explain nothing about a
        # report-only one, which Graph accepts happily - that is real drift.
        $script:LivePolicies = @([pscustomobject]@{ displayName = 'mls-ca-require-mfa-admins'; state = 'enabledForReportingButNotEnforced' })
        Mock Invoke-MlsGraph {
            if ($Uri -like '*identitySecurityDefaultsEnforcementPolicy*') { return [pscustomobject]@{ isEnabled = $true } }
            return [pscustomobject]@{ value = $script:LivePolicies }
        }
        (Test-ConditionalAccessState -Manifest $script:Declared -Domain 'x.example').Passed | Should -BeFalse
    }
}
