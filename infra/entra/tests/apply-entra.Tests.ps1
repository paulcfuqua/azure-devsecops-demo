# Pester tests for infra/entra/apply-entra.ps1 - every Graph call mocked; zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    $script:ManifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'manifest.json'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'apply-entra.ps1')
    Set-StrictMode -Off

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

    It 'fails clearly when the manifest file does not exist' {
        { Get-Manifest -Path (Join-Path $TestDrive 'nope.json') } | Should -Throw '*not found*'
    }

    It 'fails clearly on malformed JSON' {
        $bad = Join-Path $TestDrive 'bad.json'
        Set-Content -LiteralPath $bad -Value '{ "users": [' -Encoding utf8
        { Get-Manifest -Path $bad } | Should -Throw '*not valid JSON*'
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

        # $script:TenantEmpty toggles between the two idempotency branches.
        $script:TenantEmpty = $true
        Mock Invoke-GraphApi {
            $cleanPath = $Path.Split('?')[0]
            if ($Method -eq 'GET') {
                if ($cleanPath -like 'users/uid-*') {
                    return @{ id = ($cleanPath -split '/')[1] } # propagation probe
                }
                if ($cleanPath -like 'users/*') {
                    if ($script:TenantEmpty) { return $null }
                    return $script:ExistingUsers[$cleanPath]
                }
                if ($cleanPath -like 'groups/*/members') {
                    if ($script:TenantEmpty) { return @{ value = @() } }
                    $gid = ($cleanPath -split '/')[1]
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
                if ($cleanPath -eq 'users') { return @{ id = "uid-$($Body['mailNickname'])" } }
                if ($cleanPath -eq 'groups') { return @{ id = "gid-$($Body['displayName'])" } }
                if ($cleanPath -like 'groups/*/members/*') { return @{} }
                if ($cleanPath -eq 'applications') { return @{ id = "aid-$($Body['displayName'])" } }
                if ($cleanPath -eq 'identity/conditionalAccess/policies') { return @{ id = "cid-$($Body['displayName'])" } }
            }
            return @{}
        }
    }

    Context 'empty tenant - everything is created' {
        It 'creates every user, group, membership, app registration and CA policy' {
            $summary = Invoke-ApplyForTest
            $summary.UsersCreated | Should -Be $script:UserCount
            $summary.GroupsCreated | Should -Be $script:GroupCount
            $summary.MembershipsAdded | Should -Be $script:MembershipCount
            $summary.AppsCreated | Should -Be $script:AppCount
            $summary.CaCreated | Should -Be $script:CaCount
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:UserCount -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'users' }
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:GroupCount -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'groups' }
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:MembershipCount -ParameterFilter { $Method -eq 'POST' -and $Path -like 'groups/*/members/*' }
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:AppCount -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'applications' }
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:CaCount -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'identity/conditionalAccess/policies' }
        }

        It 'creates CA policies in report-only mode exactly as the manifest declares' {
            Invoke-ApplyForTest | Out-Null
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:CaCount -ParameterFilter {
                $Method -eq 'POST' -and $Path -eq 'identity/conditionalAccess/policies' -and
                $Body['state'] -eq 'enabledForReportingButNotEnforced'
            }
        }

        It 'polls for propagation after creating directory objects' {
            Invoke-ApplyForTest | Out-Null
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:UserCount -ParameterFilter {
                $Method -eq 'GET' -and $Path -like 'users/uid-*'
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
