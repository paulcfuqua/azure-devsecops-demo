# Pester tests for infra/entra/apply-entra.ps1 - every Graph call mocked; zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    $script:ManifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'manifest.json'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'apply-entra.ps1')
    # No Set-StrictMode -Off: the script under test sets -Version Latest and CI runs it
    # that way, so the harness must not relax the language mode it is testing (F49).

    function Get-FreshManifest {
        return Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
    }

    function Invoke-ApplyForTest {
        # -AsWhatIf, not -WhatIf: a parameter literally named WhatIf on a function that
        # never calls ShouldProcess trips PSUseSupportsShouldProcess, and lint-ci fails
        # on any warning. It is still forwarded to Invoke-Main as -WhatIf.
        param([switch]$AsWhatIf, [string]$Path = $script:ManifestPath)
        Invoke-Main -ManifestPath $Path -Domain 'mls.example' `
            -PropagationTimeoutSeconds 30 -PropagationIntervalSeconds 1 -WhatIf:$AsWhatIf
    }

    # Expected totals straight from the manifest, so tests fail loudly if it changes.
    $manifest = Get-FreshManifest
    $script:UserCount = @($manifest.users).Count
    $script:GroupCount = @($manifest.groups).Count
    $script:AppCount = @($manifest.appRegistrations).Count
    $script:CaCount = @($manifest.conditionalAccessPolicies).Count
    $script:MembershipCount = (@($manifest.groups) | ForEach-Object { @($_.members).Count } | Measure-Object -Sum).Sum

    # The CA policies split by declared state: the two broad All-users/All-applications
    # policies stay report-only, the dashboard MFA policy is enforced. Derived, never
    # counted by hand, so adding a policy to the manifest is felt here.
    $script:ReportOnlyCaCount = @($manifest.conditionalAccessPolicies | Where-Object { $_.state -eq 'enabledForReportingButNotEnforced' }).Count
    $script:EnforcedPolicy = @($manifest.conditionalAccessPolicies | Where-Object { $_.state -eq 'enabled' })
    $script:EnforcedCaCount = $script:EnforcedPolicy.Count
    # Found by FLAG, exactly as apply-entra.ps1 finds it: naming the group here would
    # hard-code the company prefix and would let a rename disarm the guard silently.
    # Get-Field, not $_.breakGlass: only one of the five manifest groups carries the key,
    # and a bare property read on the other four is a terminating error under the
    # Set-StrictMode -Version Latest apply-entra.ps1 sets. This is how the script itself
    # finds them (apply-entra.ps1:228), which is the point of the flag-not-name rule (F49).
    $script:BreakGlassGroupName = @(@($manifest.groups |
                Where-Object { [bool](Get-Field -Object $_ -Name 'breakGlass') }).displayName)
}

AfterAll {
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
}

Describe 'apply-entra manifest schema validation' {
    It 'accepts the shipped manifest' {
        { Assert-ManifestSchema -Manifest (Get-FreshManifest) } | Should -Not -Throw
    }

    It 'names the exact user and field when a required user field is missing' {
        $manifest = Get-FreshManifest
        $manifest.users[0].PSObject.Properties.Remove('mailNickname')
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*missing required field 'mailNickname'*"
    }

    It 'reports a missing top-level key' {
        $manifest = Get-FreshManifest
        $manifest.PSObject.Properties.Remove('groups')
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*missing required key 'groups'*"
    }

    It 'rejects an invalid Conditional Access state' {
        $manifest = Get-FreshManifest
        $manifest.conditionalAccessPolicies[0].state = 'superEnabled'
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*invalid state 'superEnabled'*"
    }

    It 'rejects a group member that matches no user' {
        $manifest = Get-FreshManifest
        $manifest.groups[0].members += 'ghost.user'
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*'ghost.user' does not match any users*"
    }

    It 'rejects a CA policy without grantControls' {
        $manifest = Get-FreshManifest
        $manifest.conditionalAccessPolicies[1].PSObject.Properties.Remove('grantControls')
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*missing required field 'grantControls'*"
    }

    It 'rejects an enforced policy that excludes no break-glass group' {
        # The single most important rule in this file. Microsoft's own guidance is that
        # every enforced CA policy excludes an emergency-access account; without one, a
        # misconfiguration locks the tenant owner out of their own tenant.
        $manifest = Get-FreshManifest
        $policy = @($manifest.conditionalAccessPolicies | Where-Object { $_.state -eq 'enabled' })[0]
        $policy.conditions.users.PSObject.Properties.Remove('excludeGroupsByDisplayName')
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*excludes no break-glass group*"
    }

    It 'rejects an enforced policy whose exclusion names a group that is not flagged breakGlass' {
        $manifest = Get-FreshManifest
        $policy = @($manifest.conditionalAccessPolicies | Where-Object { $_.state -eq 'enabled' })[0]
        # A real group, correctly spelled, just not an emergency-access group.
        $policy.conditions.users.excludeGroupsByDisplayName = @($manifest.groups[0].displayName)
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*excludes no break-glass group*"
    }

    It 'rejects an enforced policy that targets every application' {
        $manifest = Get-FreshManifest
        $policy = @($manifest.conditionalAccessPolicies | Where-Object { $_.state -eq 'enabled' })[0]
        $policy.conditions.applications.includeApplicationsByDisplayName = @('All')
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*targets every application*"
    }

    It 'rejects an enforced policy that names no application at all' {
        $manifest = Get-FreshManifest
        $policy = @($manifest.conditionalAccessPolicies | Where-Object { $_.state -eq 'enabled' })[0]
        $policy.conditions.applications.includeApplicationsByDisplayName = @()
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*names no applications*"
    }

    It 'rejects an application reference that matches no app registration' {
        # A typo here would otherwise resolve to nothing and post a policy scoped WIDER
        # than authored, which is the failure this check exists for.
        $manifest = Get-FreshManifest
        $policy = @($manifest.conditionalAccessPolicies | Where-Object { $_.state -eq 'enabled' })[0]
        $policy.conditions.applications.includeApplicationsByDisplayName = @('no-such-app')
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*'no-such-app' does not match any appRegistrations*"
    }

    It 'rejects a group exclusion that matches no group' {
        $manifest = Get-FreshManifest
        $policy = @($manifest.conditionalAccessPolicies | Where-Object { $_.state -eq 'enabled' })[0]
        $policy.conditions.users.excludeGroupsByDisplayName = @('no-such-group')
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*'no-such-group' does not match any groups*"
    }

    It 'fails clearly when the manifest file does not exist' {
        { Get-Manifest -Path (Join-Path $TestDrive 'nope.json') } | Should -Throw '*not found*'
    }

    It 'fails clearly on malformed JSON' {
        $bad = Join-Path $TestDrive 'bad.json'
        Set-Content -LiteralPath $bad -Value '{ "users": [' -Encoding utf8
        { Get-Manifest -Path $bad } | Should -Throw '*not valid JSON*'
    }
}

Describe 'group membership survives directory replication' {
    # Wait-EntraPropagation confirms each user and group is VISIBLE before this runs. That is
    # a GET, and it is a weaker question than the membership write asks: `POST
    # groups/{id}/members/$ref` needs a replica that can resolve BOTH objects and link them.
    # Both were visible and the write still 404'd, killing L3 on its first membership on the
    # first run that ever reached it (F67).

    BeforeEach {
        Mock Invoke-PropagationDelay {}
    }

    It 'retries a Request_ResourceNotFound and succeeds once replication catches up' {
        $script:PostCalls = 0
        Mock Invoke-GraphApi {
            if ($Method -eq 'GET') { return @{ value = @() } }
            $script:PostCalls++
            if ($script:PostCalls -lt 3) {
                throw "Request_ResourceNotFound: Resource 'g-1' does not exist or one of its queried reference-property objects are not present."
            }
            return @{}
        }

        $added = Initialize-GroupMembership -GroupId 'g-1' -GroupName 'mls-launch-ops' `
            -MemberIds @('u-1') -TimeoutSeconds 60 -IntervalSeconds 1

        $added | Should -Be 1
        $script:PostCalls | Should -Be 3
        Should -Invoke Invoke-PropagationDelay -Exactly -Times 2
    }

    It 'raises any other failure immediately, without waiting' {
        # A 403 does not become a 200 by waiting. Retrying everything would turn a permission
        # problem into a timeout, which is the confusion F57 was about.
        Mock Invoke-GraphApi {
            if ($Method -eq 'GET') { return @{ value = @() } }
            throw 'Authorization_RequestDenied: Insufficient privileges to complete the operation.'
        }

        { Initialize-GroupMembership -GroupId 'g-1' -GroupName 'mls-launch-ops' `
                -MemberIds @('u-1') -TimeoutSeconds 60 -IntervalSeconds 1 } |
            Should -Throw '*Authorization_RequestDenied*'
        Should -Invoke Invoke-PropagationDelay -Exactly -Times 0
    }

    It 'gives up with an error naming replication, not a missing object' {
        # The operator needs to know the difference between "your manifest names a user that
        # does not exist" and "the directory has not caught up".
        Mock Invoke-GraphApi {
            if ($Method -eq 'GET') { return @{ value = @() } }
            throw "Request_ResourceNotFound: Resource 'g-1' does not exist or one of its queried reference-property objects are not present."
        }

        { Initialize-GroupMembership -GroupId 'g-1' -GroupName 'mls-launch-ops' `
                -MemberIds @('u-1') -TimeoutSeconds 0 -IntervalSeconds 1 } |
            Should -Throw '*directory replication rather than a missing object*'
    }

    It 'does not re-add a member the group already has' {
        Mock Invoke-GraphApi {
            if ($Method -eq 'GET') { return @{ value = @(@{ id = 'u-1' }) } }
            throw 'the POST must not be attempted for a member already present'
        }
        Initialize-GroupMembership -GroupId 'g-1' -GroupName 'mls-launch-ops' `
            -MemberIds @('u-1') -TimeoutSeconds 60 -IntervalSeconds 1 | Should -Be 0
    }
}

Describe 'apply-entra propagation polling' {
    BeforeEach {
        Mock Invoke-PropagationDelay {}
    }

    It 'polls (does not blind-sleep) until the object is visible' {
        $script:ProbeCalls = 0
        $probe = {
            $script:ProbeCalls++
            if ($script:ProbeCalls -ge 3) { return @{ id = 'x' } }
            return $null
        }
        $result = Wait-EntraPropagation -Probe $probe -TimeoutSeconds 60 -IntervalSeconds 1 -Description 'test object'
        $result.id | Should -Be 'x'
        $script:ProbeCalls | Should -Be 3
        Should -Invoke Invoke-PropagationDelay -Exactly -Times 2
    }

    It 'throws a clear timeout error when the object never appears' {
        { Wait-EntraPropagation -Probe { $null } -TimeoutSeconds 0 -IntervalSeconds 1 -Description 'ghost' } |
            Should -Throw '*Timed out*ghost*'
    }
}

Describe 'apply-entra idempotency + WhatIf' {
    BeforeEach {
        Mock Write-Status {}
        Mock Test-GraphConnection { [pscustomobject]@{ TenantId = 'mock-tenant' } }
        Mock Invoke-PropagationDelay {}

        # Present-scenario lookup tables, built from the manifest itself.
        $manifest = Get-FreshManifest
        $domain = 'mls.example'
        $script:ExistingUsers = @{}
        foreach ($user in $manifest.users) {
            $script:ExistingUsers["users/$($user.userPrincipalNamePrefix)@$domain"] = @{
                id          = "uid-$($user.userPrincipalNamePrefix)"
                displayName = $user.displayName
                jobTitle    = $user.jobTitle
                department  = $user.department
            }
        }
        $script:ExistingGroups = @{}
        $script:ExistingMembers = @{}
        foreach ($group in $manifest.groups) {
            $script:ExistingGroups[$group.displayName] = @{ id = "gid-$($group.displayName)"; displayName = $group.displayName }
            $script:ExistingMembers["gid-$($group.displayName)"] = @($group.members | ForEach-Object { @{ id = "uid-$_" } })
        }
        $script:ExistingApps = @{}
        foreach ($app in $manifest.appRegistrations) {
            $script:ExistingApps[$app.displayName] = @{
                id = "aid-$($app.displayName)"; appId = "client-$($app.displayName)"
                displayName = $app.displayName; signInAudience = $app.signInAudience
            }
        }
        $script:ExistingCaPolicies = @($manifest.conditionalAccessPolicies | ForEach-Object {
                @{ id = "cid-$($_.displayName)"; displayName = $_.displayName; state = $_.state }
            })

        # Break-glass membership is deliberately NOT in the manifest (the account is a real
        # human credential, never a fictional persona), so tests seed it here. Empty by
        # default, which is the true state of a first-ever apply.
        $script:BreakGlassMember = @()
        $script:BreakGlassUser = @{}
        $script:PostOrder = [System.Collections.Generic.List[string]]::new()
        # The exact bodies that would reach Graph, asserted on directly: a ParameterFilter
        # cannot express set equality over a nested array legibly.
        $script:PostedPolicy = [System.Collections.Generic.List[object]]::new()

        # $script:TenantEmpty toggles between the two idempotency branches.
        $script:TenantEmpty = $true
        Mock Invoke-GraphApi {
            $cleanPath = $Path.Split('?')[0]
            if ($Method -eq 'GET') {
                if ($cleanPath -like 'users/uid-*') {
                    return @{ id = ($cleanPath -split '/')[1] } # propagation probe
                }
                if ($cleanPath -like 'users/*') {
                    # Break-glass members are looked up for onPremisesSyncEnabled: a
                    # break-glass account must be cloud-only.
                    if ($script:BreakGlassUser.ContainsKey($cleanPath)) { return $script:BreakGlassUser[$cleanPath] }
                    if ($script:TenantEmpty) { return $null }
                    return $script:ExistingUsers[$cleanPath]
                }
                if ($cleanPath -like 'groups/*/members') {
                    $gid = ($cleanPath -split '/')[1]
                    # The break-glass group's members are seeded by the test whether or not
                    # the rest of the tenant exists: a human puts them there out of band.
                    if ($gid -in @($script:BreakGlassGroupName | ForEach-Object { "gid-$_" })) {
                        return @{ value = $script:BreakGlassMember }
                    }
                    if ($script:TenantEmpty) { return @{ value = @() } }
                    return @{ value = $script:ExistingMembers[$gid] }
                }
                if ($cleanPath -like 'groups/gid-*') {
                    return @{ id = ($cleanPath -split '/')[1] } # propagation probe
                }
                if ($cleanPath -eq 'groups') {
                    if ($script:TenantEmpty) { return @{ value = @() } }
                    if ($Path -match "eq '([^']+)'") { return @{ value = @($script:ExistingGroups[$Matches[1]]) } }
                    return @{ value = @() }
                }
                if ($cleanPath -eq 'applications') {
                    if ($script:TenantEmpty) { return @{ value = @() } }
                    if ($Path -match "eq '([^']+)'") { return @{ value = @($script:ExistingApps[$Matches[1]]) } }
                    return @{ value = @() }
                }
                if ($cleanPath -eq 'identity/conditionalAccess/policies') {
                    if ($script:TenantEmpty) { return @{ value = @() } }
                    return @{ value = $script:ExistingCaPolicies }
                }
                return $null
            }
            if ($Method -eq 'POST') {
                $script:PostOrder.Add($cleanPath)
                if ($cleanPath -eq 'identity/conditionalAccess/policies') { $script:PostedPolicy.Add($Body) }
                if ($cleanPath -eq 'users') { return @{ id = "uid-$($Body['mailNickname'])" } }
                if ($cleanPath -eq 'groups') { return @{ id = "gid-$($Body['displayName'])" } }
                if ($cleanPath -like 'groups/*/members/*') { return @{} }
                # appId as well as id, because that is what Graph returns and what a CA
                # policy addresses an application by. Without it the dashboard MFA policy
                # could not be scoped to named applications at all.
                if ($cleanPath -eq 'applications') { return @{ id = "aid-$($Body['displayName'])"; appId = "client-$($Body['displayName'])" } }
                if ($cleanPath -eq 'identity/conditionalAccess/policies') { return @{ id = "cid-$($Body['displayName'])" } }
            }
            return @{}
        }
    }

    Context 'empty tenant - everything is created' {
        It 'creates every user, group, membership, app registration and every CA policy it is allowed to' {
            # CaCreated is the REPORT-ONLY count here, not the manifest count. On a
            # first-ever pass the break-glass group has just been created empty, so the
            # enforced dashboard MFA policy is refused rather than created: no emergency
            # account exists to fall back on yet. That is the guard working. The context
            # below covers the pass where the account exists and the policy lands.
            $summary = Invoke-ApplyForTest
            $summary.UsersCreated | Should -Be $script:UserCount
            $summary.GroupsCreated | Should -Be $script:GroupCount
            $summary.MembershipsAdded | Should -Be $script:MembershipCount
            $summary.AppsCreated | Should -Be $script:AppCount
            $summary.CaCreated | Should -Be $script:ReportOnlyCaCount
            $summary.CaBlocked | Should -Be $script:EnforcedCaCount
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:UserCount -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'users' }
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:GroupCount -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'groups' }
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:MembershipCount -ParameterFilter { $Method -eq 'POST' -and $Path -like 'groups/*/members/*' }
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:AppCount -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'applications' }
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:ReportOnlyCaCount -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'identity/conditionalAccess/policies' }
        }

        It 'creates the broad CA policies in report-only mode exactly as the manifest declares' {
            Invoke-ApplyForTest | Out-Null
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:ReportOnlyCaCount -ParameterFilter {
                $Method -eq 'POST' -and $Path -eq 'identity/conditionalAccess/policies' -and
                $Body['state'] -eq 'enabledForReportingButNotEnforced'
            }
        }

        It 'never posts an enforced policy while the break-glass group is empty' {
            Invoke-ApplyForTest | Out-Null
            Should -Invoke Invoke-GraphApi -Exactly -Times 0 -ParameterFilter {
                $Method -eq 'POST' -and $Path -eq 'identity/conditionalAccess/policies' -and
                $Body['state'] -eq 'enabled'
            }
        }

        It 'polls for propagation after creating directory objects' {
            Invoke-ApplyForTest | Out-Null
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:UserCount -ParameterFilter {
                $Method -eq 'GET' -and $Path -like 'users/uid-*'
            }
        }
    }

    Context 'an enforced CA policy lands only once a break-glass account exists' {
        BeforeEach {
            # A real emergency-access account: cloud-only, and not one of the fictional
            # demo personas. The human adds it out of band (g0-bootstrap.md item 13),
            # which is why the manifest declares the group with no members.
            $script:BreakGlassMember = @(@{ id = 'bg-emergency-access' })
        }

        It 'creates the enforced dashboard MFA policy once the account is there' {
            $summary = Invoke-ApplyForTest
            $summary.CaCreated | Should -Be $script:CaCount
            $summary.CaBlocked | Should -Be 0
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:EnforcedCaCount -ParameterFilter {
                $Method -eq 'POST' -and $Path -eq 'identity/conditionalAccess/policies' -and
                $Body['state'] -eq 'enabled'
            }
        }

        It 'grants mfa, scoped to exactly the three dashboard apps and never to All, excluding break-glass' {
            # The whole point of the policy, asserted on the bytes that would go to Graph.
            $expectedAppId = @($script:EnforcedPolicy[0].conditions.applications.includeApplicationsByDisplayName |
                    ForEach-Object { "client-$_" })
            $expectedGroupId = @($script:BreakGlassGroupName | ForEach-Object { "gid-$_" })
            $expectedAppId.Count | Should -Be 3 -Because 'the estate has exactly three human-facing dashboards'

            Invoke-ApplyForTest | Out-Null
            $posted = @($script:PostedPolicy | Where-Object { $_.state -eq 'enabled' })
            $posted.Count | Should -Be 1
            $body = $posted[0]
            $body.grantControls.builtInControls | Should -Contain 'mfa'
            $body.conditions.users.includeUsers | Should -Contain 'All'
            $body.conditions.clientAppTypes | Should -Contain 'all'

            $includeApplication = @($body.conditions.applications.includeApplications)
            $includeApplication | Should -Not -Contain 'All' -Because 'an enforced grant scoped to every application is a tenant-wide lockout risk'
            Compare-Object $includeApplication $expectedAppId | Should -BeNullOrEmpty

            $excludeGroup = @($body.conditions.users.excludeGroups)
            Compare-Object $excludeGroup $expectedGroupId | Should -BeNullOrEmpty -Because 'the break-glass exclusion is the only recovery path from a wrong policy'
        }

        It 'sends Graph object ids, never the manifest display-name keys' {
            Invoke-ApplyForTest | Out-Null
            foreach ($body in $script:PostedPolicy) {
                $body.conditions.applications.ContainsKey('includeApplicationsByDisplayName') | Should -BeFalse
                $body.conditions.users.ContainsKey('excludeGroupsByDisplayName') | Should -BeFalse
            }
        }

        It 'creates the app registrations BEFORE the CA policy that names them' {
            # Ordering is what makes the display-name resolution possible at all: an
            # application has no client id to be scoped by until its registration exists.
            Invoke-ApplyForTest | Out-Null
            $lastApp = $script:PostOrder.LastIndexOf('applications')
            $firstPolicy = $script:PostOrder.IndexOf('identity/conditionalAccess/policies')
            $lastApp | Should -BeGreaterThan -1
            $firstPolicy | Should -BeGreaterThan $lastApp
        }

        It 'refuses when the only break-glass member is one of the fictional demo personas' {
            # A persona is not an emergency-access account: no human holds its credential,
            # and the manifest says out loud that they are all fictional.
            $script:BreakGlassMember = @(@{ id = "uid-$((Get-FreshManifest).users[0].userPrincipalNamePrefix)" })
            $summary = Invoke-ApplyForTest
            $summary.CaBlocked | Should -Be $script:EnforcedCaCount
            Should -Invoke Invoke-GraphApi -Exactly -Times 0 -ParameterFilter {
                $Method -eq 'POST' -and $Path -eq 'identity/conditionalAccess/policies' -and $Body['state'] -eq 'enabled'
            }
        }

        It 'refuses when the only break-glass member is synced from on-premises' {
            $script:BreakGlassMember = @(@{ id = 'bg-synced' })
            $script:BreakGlassUser['users/bg-synced'] = @{ id = 'bg-synced'; onPremisesSyncEnabled = $true }
            $summary = Invoke-ApplyForTest
            $summary.CaBlocked | Should -Be $script:EnforcedCaCount
        }

        It 'refuses to enable a drifted policy that someone turned off, when the account is gone' {
            $script:TenantEmpty = $false
            $script:BreakGlassMember = @()
            $enforcedName = $script:EnforcedPolicy[0].displayName
            @($script:ExistingCaPolicies | Where-Object { $_.displayName -eq $enforcedName })[0].state = 'disabled'
            $summary = Invoke-ApplyForTest
            $summary.CaBlocked | Should -Be 1
            $summary.CaUpdated | Should -Be 0
            Should -Invoke Invoke-GraphApi -Exactly -Times 0 -ParameterFilter { $Method -eq 'PATCH' }
        }

        It 'converges a drifted enforced policy back to enabled when the account is there' {
            $script:TenantEmpty = $false
            $enforcedName = $script:EnforcedPolicy[0].displayName
            @($script:ExistingCaPolicies | Where-Object { $_.displayName -eq $enforcedName })[0].state = 'disabled'
            $summary = Invoke-ApplyForTest
            $summary.CaUpdated | Should -Be 1
            $summary.CaBlocked | Should -Be 0
            Should -Invoke Invoke-GraphApi -Exactly -Times 1 -ParameterFilter {
                $Method -eq 'PATCH' -and $Path -like 'identity/conditionalAccess/policies/cid-*' -and
                $Body['state'] -eq 'enabled'
            }
        }
    }

    Context 'fully-populated tenant - replay no-ops' {
        BeforeEach { $script:TenantEmpty = $false }

        It 'issues zero mutating calls' {
            $summary = Invoke-ApplyForTest
            Should -Invoke Invoke-GraphApi -Exactly -Times 0 -ParameterFilter { $Method -in @('POST', 'PATCH', 'DELETE') }
            $summary.UsersUnchanged | Should -Be $script:UserCount
            $summary.GroupsUnchanged | Should -Be $script:GroupCount
            $summary.MembershipsAdded | Should -Be 0
            $summary.AppsUnchanged | Should -Be $script:AppCount
            $summary.CaUnchanged | Should -Be $script:CaCount
        }

        It 'PATCHes a drifted user in place instead of recreating it' {
            $firstKey = @($script:ExistingUsers.Keys)[0]
            $script:ExistingUsers[$firstKey].jobTitle = 'Former Title'
            $summary = Invoke-ApplyForTest
            $summary.UsersUpdated | Should -Be 1
            $summary.UsersCreated | Should -Be 0
            Should -Invoke Invoke-GraphApi -Exactly -Times 1 -ParameterFilter {
                $Method -eq 'PATCH' -and $Path -like 'users/uid-*' -and $Body['jobTitle']
            }
        }

        It 'PATCHes a drifted CA policy state back to report-only' {
            $script:ExistingCaPolicies[0].state = 'disabled'
            $summary = Invoke-ApplyForTest
            $summary.CaUpdated | Should -Be 1
            Should -Invoke Invoke-GraphApi -Exactly -Times 1 -ParameterFilter {
                $Method -eq 'PATCH' -and $Path -like 'identity/conditionalAccess/policies/cid-*' -and
                $Body['state'] -eq 'enabledForReportingButNotEnforced'
            }
        }

        It 'adds only the missing member when one membership is absent' {
            $gid = "gid-$((Get-FreshManifest).groups[0].displayName)"
            $script:ExistingMembers[$gid] = @($script:ExistingMembers[$gid] | Select-Object -Skip 1)
            $summary = Invoke-ApplyForTest
            $summary.MembershipsAdded | Should -Be 1
            Should -Invoke Invoke-GraphApi -Exactly -Times 1 -ParameterFilter {
                $Method -eq 'POST' -and $Path -like 'groups/*/members/*'
            }
        }
    }

    Context '-WhatIf makes no mutating calls' {
        It 'on an empty tenant performs reads only and reports the skips' {
            $summary = Invoke-ApplyForTest -AsWhatIf
            Should -Invoke Invoke-GraphApi -Exactly -Times 0 -ParameterFilter { $Method -in @('POST', 'PATCH', 'DELETE') }
            $summary.SkippedInWhatIf | Should -Be ($script:UserCount + $script:GroupCount + $script:AppCount + $script:CaCount)
        }

        It 'on a populated tenant with drift still performs reads only' {
            $script:TenantEmpty = $false
            $script:ExistingCaPolicies[0].state = 'disabled'
            Invoke-ApplyForTest -AsWhatIf | Out-Null
            Should -Invoke Invoke-GraphApi -Exactly -Times 0 -ParameterFilter { $Method -in @('POST', 'PATCH', 'DELETE') }
        }
    }

    Context 'validation failures stop everything before any Graph call' {
        It 'invalid manifest -> clear error, zero Graph traffic' {
            $badPath = Join-Path $TestDrive 'broken-manifest.json'
            $manifest = Get-FreshManifest
            $manifest.users[0].PSObject.Properties.Remove('userPrincipalNamePrefix')
            $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $badPath -Encoding utf8
            { Invoke-ApplyForTest -Path $badPath } | Should -Throw '*Manifest validation failed*'
            Should -Invoke Invoke-GraphApi -Exactly -Times 0
        }
    }
}
