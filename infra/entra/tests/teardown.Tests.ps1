# Pester tests for infra/entra/teardown.ps1 - every Graph call mocked; zero cloud calls.
# Mirrors infra/entra/tests/apply-entra.Tests.ps1's convention exactly (same
# Invoke-GraphApi choke point, same MLS_SKIP_MAIN dot-source guard).

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    $script:ManifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'manifest.json'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'teardown.ps1')
    Set-StrictMode -Off

    function Get-FreshManifest {
        return Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
    }

    function Invoke-TeardownForTest {
        param([switch]$AsWhatIf, [switch]$AsAllowAutomation)
        Invoke-Main -ManifestPath $script:ManifestPath -Domain 'mls.example' `
            -AllowAutomation:$AsAllowAutomation -WhatIf:$AsWhatIf -Confirm:$false
    }

    $manifest = Get-FreshManifest
    $script:UserCount = @($manifest.users).Count
    $script:GroupCount = @($manifest.groups).Count
    $script:AppCount = @($manifest.appRegistrations).Count
    $script:CaCount = @($manifest.conditionalAccessPolicies).Count
}

AfterAll {
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
}

Describe 'infra/entra/teardown.ps1' {
    BeforeEach {
        Mock Write-Status {}
        Mock Test-GraphConnection { [pscustomobject]@{ TenantId = 'mock-tenant' } }
        $env:GITHUB_ACTIONS = $null

        $domain = 'mls.example'
        $manifest = Get-FreshManifest
        $script:ExistingUsers = @{}
        foreach ($user in $manifest.users) {
            $script:ExistingUsers["users/$($user.userPrincipalNamePrefix)@$domain"] = @{
                id = "uid-$($user.userPrincipalNamePrefix)"; displayName = $user.displayName
            }
        }
        $script:ExistingGroups = @{}
        foreach ($group in $manifest.groups) {
            $script:ExistingGroups[$group.displayName] = @{ id = "gid-$($group.displayName)"; displayName = $group.displayName }
        }
        $script:ExistingApps = @{}
        foreach ($app in $manifest.appRegistrations) {
            $script:ExistingApps[$app.displayName] = @{ id = "aid-$($app.displayName)"; displayName = $app.displayName }
        }
        $script:ExistingCaPolicies = @($manifest.conditionalAccessPolicies | ForEach-Object {
                @{ id = "cid-$($_.displayName)"; displayName = $_.displayName }
            })

        # $script:TenantEmpty toggles whether every lookup finds an existing object.
        $script:TenantEmpty = $false
        $script:DeleteLog = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-GraphApi {
            if ($Method -eq 'DELETE') {
                $script:DeleteLog.Add($Path)
                return $null
            }
            $cleanPath = $Path.Split('?')[0]
            if ($script:TenantEmpty) {
                if ($cleanPath -eq 'identity/conditionalAccess/policies') { return @{ value = @() } }
                if ($cleanPath -in @('groups', 'applications')) { return @{ value = @() } }
                return $null
            }
            if ($cleanPath -like 'users/*') { return $script:ExistingUsers[$cleanPath] }
            if ($cleanPath -eq 'groups') {
                if ($Path -match "eq '([^']+)'") { return @{ value = @($script:ExistingGroups[$Matches[1]]) } }
                return @{ value = @() }
            }
            if ($cleanPath -eq 'applications') {
                if ($Path -match "eq '([^']+)'") { return @{ value = @($script:ExistingApps[$Matches[1]]) } }
                return @{ value = @() }
            }
            if ($cleanPath -eq 'identity/conditionalAccess/policies') { return @{ value = $script:ExistingCaPolicies } }
            return $null
        }
    }

    AfterEach {
        $env:GITHUB_ACTIONS = $null
    }

    Context 'CI guard' {
        It 'refuses to run under GitHub Actions without -AllowAutomation' {
            $env:GITHUB_ACTIONS = 'true'
            { Invoke-TeardownForTest } | Should -Throw '*GITHUB_ACTIONS*'
            Should -Invoke Invoke-GraphApi -Exactly -Times 0
        }

        It 'proceeds under GitHub Actions when -AllowAutomation is passed' {
            $env:GITHUB_ACTIONS = 'true'
            { Invoke-TeardownForTest -AsAllowAutomation } | Should -Not -Throw
        }
    }

    Context 'populated tenant - full teardown' {
        It 'deletes every manifest-listed CA policy, app registration, group and user' {
            $summary = Invoke-TeardownForTest
            $summary.CaDeleted | Should -Be $script:CaCount
            $summary.AppsDeleted | Should -Be $script:AppCount
            $summary.GroupsDeleted | Should -Be $script:GroupCount
            $summary.UsersDeleted | Should -Be $script:UserCount
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:CaCount -ParameterFilter {
                $Method -eq 'DELETE' -and $Path -like 'identity/conditionalAccess/policies/*'
            }
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:AppCount -ParameterFilter {
                $Method -eq 'DELETE' -and $Path -like 'applications/*'
            }
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:GroupCount -ParameterFilter {
                $Method -eq 'DELETE' -and $Path -like 'groups/*'
            }
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:UserCount -ParameterFilter {
                $Method -eq 'DELETE' -and $Path -like 'users/*'
            }
        }

        It 'removes in reverse-dependency order: CA policies, then app registrations, then groups, then users' {
            Invoke-TeardownForTest | Out-Null
            $order = @($script:DeleteLog | ForEach-Object { ($_ -split '/')[0] } | Select-Object -Unique)
            $order -join ',' | Should -Be 'identity,applications,groups,users'
        }

        It 'deletes only what the manifest lists - exactly the user count, no more no less' {
            Invoke-TeardownForTest | Out-Null
            $userDeletes = @($script:DeleteLog | Where-Object { $_ -like 'users/*' })
            $userDeletes.Count | Should -Be $script:UserCount
        }
    }

    Context 'empty tenant - idempotent replay' {
        BeforeEach { $script:TenantEmpty = $true }

        It 'treats every already-absent object as a no-op, not an error' {
            { Invoke-TeardownForTest } | Should -Not -Throw
            $summary = Invoke-TeardownForTest
            $summary.CaNotFound | Should -Be $script:CaCount
            $summary.AppsNotFound | Should -Be $script:AppCount
            $summary.GroupsNotFound | Should -Be $script:GroupCount
            $summary.UsersNotFound | Should -Be $script:UserCount
            Should -Invoke Invoke-GraphApi -Exactly -Times 0 -ParameterFilter { $Method -eq 'DELETE' }
        }
    }

    Context '-WhatIf makes no mutating calls' {
        It 'on a fully populated tenant, deletes nothing' {
            Invoke-TeardownForTest -AsWhatIf | Out-Null
            Should -Invoke Invoke-GraphApi -Exactly -Times 0 -ParameterFilter { $Method -eq 'DELETE' }
        }

        It 'reports every found object as skipped rather than deleted' {
            $summary = Invoke-TeardownForTest -AsWhatIf
            $summary.SkippedInWhatIf | Should -Be ($script:CaCount + $script:AppCount + $script:GroupCount + $script:UserCount)
            $summary.CaDeleted | Should -Be 0
            $summary.AppsDeleted | Should -Be 0
            $summary.GroupsDeleted | Should -Be 0
            $summary.UsersDeleted | Should -Be 0
        }
    }
}
