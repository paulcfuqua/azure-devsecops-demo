# Pester tests for infra/entra/teardown.ps1 - every Graph call mocked; zero cloud calls.
# Mirrors infra/entra/tests/apply-entra.Tests.ps1's convention exactly (same
# Invoke-GraphApi choke point, same MLS_SKIP_MAIN dot-source guard).

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    $script:ManifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'manifest.json'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'teardown.ps1')
    # No Set-StrictMode -Off: the script under test sets -Version Latest and CI runs it
    # that way, so the harness must not relax the language mode it is testing (F49).

    function Get-FreshManifest {
        # Get-Manifest, not raw JSON: the manifest is tokenised (${prefix}, ${env}) and
        # teardown.ps1 resolves those before it looks for a single object. A test reading
        # the raw file would assert on '${prefix}-break-glass' while the script searched
        # for 'mls-break-glass' - the harness measuring a different string than the code
        # uses, which is exactly the mirror this suite exists to prevent (F90).
        return Get-Manifest -Path $script:ManifestPath
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

        It 'never targets a G0 bootstrap identity, whatever the manifest gains' {
            # bootstrapAppRegistrations declares the OIDC deployer, the verifier and the
            # certificate-bearing Purview app so L3's V3.1 drift sweep can tell them from
            # an undeclared registration. This teardown reads appRegistrations ONLY, and
            # that has to stay true: deleting the deployer would remove the identity every
            # future deploy authenticates as, and deleting mls-purview would destroy a
            # hand-minted X.509 credential no script in this repository can reissue.
            # Neither is recoverable by re-running anything.
            Invoke-TeardownForTest | Out-Null
            $manifest = Get-FreshManifest
            $bootstrap = @($manifest.bootstrapAppRegistrations)
            $bootstrap.Count | Should -BeGreaterThan 0 -Because 'the guard is vacuous if the manifest declares none'
            foreach ($identity in $bootstrap) {
                $script:DeleteLog | Should -Not -Contain "applications/id-$($identity.displayName)"
                foreach ($deleted in $script:DeleteLog) {
                    $deleted | Should -Not -BeLike "*$($identity.displayName)*" `
                        -Because "$($identity.displayName) is created out of band at G0 and cannot be recreated by any deploy"
                }
            }
        }

        It 'deletes the exact object matching each manifest entry''s identity, not merely the right COUNT' {
            # The missing test class the review named directly: a lookup that
            # returns an arbitrary object of the right count is indistinguishable
            # from correct unless something asserts which specific id was deleted
            # for which specific manifest entry.
            Invoke-TeardownForTest | Out-Null
            $manifest = Get-FreshManifest
            foreach ($policy in $manifest.conditionalAccessPolicies) {
                $expected = "identity/conditionalAccess/policies/cid-$($policy.displayName)"
                ($script:DeleteLog -contains $expected) | Should -BeTrue -Because "CA policy '$($policy.displayName)' should be deleted by its own id"
            }
            foreach ($app in $manifest.appRegistrations) {
                $expected = "applications/aid-$($app.displayName)"
                ($script:DeleteLog -contains $expected) | Should -BeTrue -Because "app registration '$($app.displayName)' should be deleted by its own id"
            }
            foreach ($group in $manifest.groups) {
                $expected = "groups/gid-$($group.displayName)"
                ($script:DeleteLog -contains $expected) | Should -BeTrue -Because "group '$($group.displayName)' should be deleted by its own id"
            }
            foreach ($user in $manifest.users) {
                $expected = "users/uid-$($user.userPrincipalNamePrefix)"
                ($script:DeleteLog -contains $expected) | Should -BeTrue -Because "user '$($user.userPrincipalNamePrefix)' should be deleted by its own id"
            }
        }
    }

    Context 'ambiguous display name - refuses rather than deleting an arbitrary match (Important 5)' {
        It 'Get-CaPolicy throws when two tenant CA policies share the manifest''s displayName' {
            $decoyName = (Get-FreshManifest).conditionalAccessPolicies[0].displayName
            $script:ExistingCaPolicies += @{ id = 'cid-decoy-real-tenant-object'; displayName = $decoyName }
            { Invoke-TeardownForTest } | Should -Throw "*Ambiguous CA policy display name*"
            Should -Invoke Invoke-GraphApi -Exactly -Times 0 -ParameterFilter { $Method -eq 'DELETE' }
        }

        It 'Get-EntraGroup throws when two tenant groups share the manifest''s displayName' {
            $decoyName = (Get-FreshManifest).groups[0].displayName
            $script:ExistingGroups[$decoyName] = @(
                @{ id = "gid-$decoyName"; displayName = $decoyName },
                @{ id = 'gid-decoy-real-tenant-object'; displayName = $decoyName }
            )
            { Invoke-TeardownForTest } | Should -Throw "*Ambiguous group display name*"
        }

        It 'a duplicate GROUP display name causes zero deletes, including the CA policies and app registrations that sort earlier (Minor 6)' {
            # Before the pre-flight pass existed, ambiguity was caught inside each
            # lookup AS the reverse-dependency loop reached it: a duplicate group
            # name correctly refused the run, but only after the 2 CA policies and 3
            # app registrations ahead of groups in manifest order had already been
            # deleted for real. Resolving every manifest lookup up front, before any
            # deletion loop runs at all, means the refusal now happens before ANY
            # category is touched.
            $decoyName = (Get-FreshManifest).groups[0].displayName
            $script:ExistingGroups[$decoyName] = @(
                @{ id = "gid-$decoyName"; displayName = $decoyName },
                @{ id = 'gid-decoy-real-tenant-object'; displayName = $decoyName }
            )
            { Invoke-TeardownForTest } | Should -Throw "*Ambiguous group display name*"
            Should -Invoke Invoke-GraphApi -Exactly -Times 0 -ParameterFilter { $Method -eq 'DELETE' }
        }

        It 'Get-EntraApplication throws when two tenant app registrations share the manifest''s displayName' {
            $decoyName = (Get-FreshManifest).appRegistrations[0].displayName
            $script:ExistingApps[$decoyName] = @(
                @{ id = "aid-$decoyName"; displayName = $decoyName },
                @{ id = 'aid-decoy-real-tenant-object'; displayName = $decoyName }
            )
            { Invoke-TeardownForTest } | Should -Throw "*Ambiguous app registration display name*"
        }
    }

    Context 'confirmation (Critical 1 / Important 6)' {
        # Placed in THIS context on purpose: the 'declined confirmation' context
        # below mocks Invoke-GraphMutation, so an assertion living there would
        # exercise the mock and pass even against a hardcoded Confirmed = $true.
        # Verified by mutation: hardcoding it turns this test red only from here.
        It 'Invoke-GraphMutation derives Confirmed from ShouldProcess - not hardcoded (real function, deliberately not mocked here)' {
            # Every other test in this context mocks Invoke-GraphMutation, which
            # replaces the layer that does the deriving - so a hardcoded
            # Confirmed = $true would ship green. This one calls the REAL helper;
            # -WhatIf is a genuine, non-interactive way to make ShouldProcess
            # return $false (F23 re-review, Important 1).
            $result = Invoke-GraphMutation -Target 'probe' -Action 'Delete probe' -Method DELETE -Path 'users/probe-id' -WhatIf
            $result.Confirmed | Should -BeFalse -Because 'ShouldProcess returns false under -WhatIf'
            $result.Response | Should -BeNullOrEmpty -Because 'a declined mutation must not call Graph at all'
        }

        It 'Invoke-GraphMutation - the only function that actually calls ShouldProcess - declares ConfirmImpact High' {
            # ConfirmImpact does not propagate from a caller to a callee: declaring
            # it only on Invoke-Main (which never calls ShouldProcess itself) left
            # every destructive call running with no confirmation prompt at all
            # under the default $ConfirmPreference of 'High'. This is a
            # metadata/reflection assertion rather than a live-prompt test, because
            # actually triggering $Host.UI's confirmation prompt in a
            # non-interactive Pester run would hang or error rather than
            # demonstrate anything.
            $attribute = (Get-Item Function:\Invoke-GraphMutation).ScriptBlock.Attributes |
                Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
            $attribute | Should -Not -BeNullOrEmpty
            $attribute.SupportsShouldProcess | Should -BeTrue
            $attribute.ConfirmImpact | Should -Be 'High'
        }

        It 'Invoke-GraphMutation actually calls $PSCmdlet.ShouldProcess in its body, not merely declaring the attribute' {
            $source = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'teardown.ps1') -Raw
            $source | Should -Match '(?s)function Invoke-GraphMutation \{.*?\$PSCmdlet\.ShouldProcess\('
        }

        It 'none of the four Remove-* wrapper functions calls ShouldProcess itself - confirmation is delegated entirely to Invoke-GraphMutation' {
            # Guards against reintroducing the redundant second gate an earlier
            # revision had: each wrapper declared AND called its own ShouldProcess
            # on top of Invoke-GraphMutation's, which meant neutering either layer
            # alone left the -WhatIf no-mutate test green - a false sense of
            # coverage (F23 review, Important 6).
            $source = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'teardown.ps1') -Raw
            foreach ($functionName in @('Remove-CaPolicy', 'Remove-EntraApplication', 'Remove-EntraGroup', 'Remove-EntraUser')) {
                $body = [regex]::Match($source, "(?sm)^function $functionName \{.*?^\}").Value
                $body | Should -Not -Match '\$PSCmdlet\.ShouldProcess\(' -Because "$functionName should delegate to Invoke-GraphMutation, not gate itself"
            }
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

    Context 'declined confirmation is reported as Declined, never Deleted (Critical 1)' {
        # The review's own repro: answering 'n' to all 14 prompts printed "Deleted
        # CA policy '...'" x14 and a summary claiming CaDeleted=2 AppsDeleted=3
        # GroupsDeleted=4 UsersDeleted=5, while zero Graph DELETE calls actually
        # fired. The bug was that every Remove-* wrapper returned Existed=$true on
        # BOTH ShouldProcess branches, and Invoke-Main inferred "deleted" from
        # $WhatIfPreference (which is $false for a declined prompt, same as a real
        # delete) rather than from what ShouldProcess itself decided. -Confirm:$false
        # (used by every OTHER context in this file, to avoid a live prompt hanging
        # the suite) makes ShouldProcess always return $true, so it cannot exercise
        # this path at all - mocking Invoke-GraphMutation's own Confirmed return is
        # the only non-interactive way to simulate a declined prompt.
        BeforeEach {
            Mock Invoke-GraphMutation { @{ Confirmed = $false; Response = $null } }
        }

        It 'Remove-CaPolicy reports Existed=$true but Confirmed=$false, not a delete' {
            $policy = (Get-FreshManifest).conditionalAccessPolicies[0]
            $result = Remove-CaPolicy -Policy $policy -Confirm:$false
            $result.Existed | Should -BeTrue
            $result.Confirmed | Should -BeFalse
        }

        It 'Remove-EntraApplication reports Existed=$true but Confirmed=$false, not a delete' {
            $app = (Get-FreshManifest).appRegistrations[0]
            $result = Remove-EntraApplication -App $app -Confirm:$false
            $result.Existed | Should -BeTrue
            $result.Confirmed | Should -BeFalse
        }

        It 'Remove-EntraGroup reports Existed=$true but Confirmed=$false, not a delete' {
            $group = (Get-FreshManifest).groups[0]
            $result = Remove-EntraGroup -Group $group -Confirm:$false
            $result.Existed | Should -BeTrue
            $result.Confirmed | Should -BeFalse
        }

        It 'Remove-EntraUser reports Existed=$true but Confirmed=$false, not a delete' {
            $user = (Get-FreshManifest).users[0]
            $result = Remove-EntraUser -User $user -Domain 'mls.example' -Confirm:$false
            $result.Existed | Should -BeTrue
            $result.Confirmed | Should -BeFalse
        }

        It 'Invoke-Main reports every category as Declined, never Deleted, when every prompt is declined - the review''s exact scenario' {
            $summary = Invoke-TeardownForTest
            $summary.CaDeleted | Should -Be 0
            $summary.AppsDeleted | Should -Be 0
            $summary.GroupsDeleted | Should -Be 0
            $summary.UsersDeleted | Should -Be 0
            $summary.CaDeclined | Should -Be $script:CaCount
            $summary.AppsDeclined | Should -Be $script:AppCount
            $summary.GroupsDeclined | Should -Be $script:GroupCount
            $summary.UsersDeclined | Should -Be $script:UserCount
        }

        It 'fires zero real Graph DELETE calls when every confirmation is declined' {
            Invoke-TeardownForTest | Out-Null
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
