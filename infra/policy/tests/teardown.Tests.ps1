# Pester tests for infra/policy/teardown.ps1 - every `az` call mocked; zero cloud calls.
# Mirrors scripts/bootstrap/tests/02-fabric-capacity.Tests.ps1's Invoke-AzCli mocking
# convention and infra/entra/tests/teardown.Tests.ps1's CI-guard/-WhatIf/order convention.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'

    # Stand-in for the `az` CLI itself, used ONLY by the dedicated Invoke-AzCli unit
    # tests below (the repo's stand-in convention: teardown.ps1 is dot-sourced into
    # THIS scope, so Invoke-AzCli's `& az @Arguments` resolves to this function
    # rather than the real executable). Every other test in this file mocks
    # Invoke-AzCli directly, the same way 02-fabric-capacity.Tests.ps1 does, and
    # never reaches this stand-in at all.
    #
    # $global:LASTEXITCODE is genuinely required here - it is the real PowerShell
    # automatic variable Invoke-AzCli reads, and only a native command (or, as
    # here, an explicit assignment standing in for one) can set it meaningfully.
    # $script:MlsTestAz* below are test fixture state, not that variable, so they
    # stay $script: (PSAvoidGlobalVars; F23 review, Important 7).
    function az {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for the az CLI executable so Invoke-AzCli''s own $LASTEXITCODE handling can be unit-tested without a real az process. $Args is read by name via the automatic variable, not this parameter.')]
        param()
        if ($script:MlsTestAzStderr) {
            # Write-Error (not [Console]::Error) so `2>` redirection - which
            # operates on PowerShell's own error stream for a function, the same
            # as it does for a native command's stderr - actually captures this
            # text into Invoke-AzCli's temp file.
            Write-Error -Message $script:MlsTestAzStderr -ErrorAction Continue
        }
        $global:LASTEXITCODE = $script:MlsTestAzExitCode
        if ($script:MlsTestAzOutput) { return $script:MlsTestAzOutput }
    }

    $script:RealNamingFile = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '../bicep/naming.bicep'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'teardown.ps1')
    Set-StrictMode -Off

    function Invoke-TeardownForTest {
        param([switch]$AsWhatIf, [switch]$AsAllowAutomation, [string]$SubscriptionId = '11111111-1111-1111-1111-111111111111')
        Invoke-Main -NamingFile $script:RealNamingFile -SubscriptionId $SubscriptionId `
            -AllowAutomation:$AsAllowAutomation -WhatIf:$AsWhatIf -Confirm:$false
    }
}

AfterAll {
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
}

Describe 'infra/policy/teardown.ps1 - Invoke-AzCli native exit-code handling' {
    BeforeEach {
        $script:MlsTestAzExitCode = 0
        $script:MlsTestAzOutput = $null
        $script:MlsTestAzStderr = $null
    }

    It 'throws, naming the exit code, when az fails and -AllowNotFound is not passed' {
        $script:MlsTestAzExitCode = 1
        $script:MlsTestAzStderr = 'ERROR: something unrelated went wrong'
        { Invoke-AzCli -Arguments @('policy', 'assignment', 'show') } | Should -Throw '*exit code 1*'
    }

    It 'returns $null instead of throwing when az fails with a not-found-shaped error and -AllowNotFound IS passed' {
        $script:MlsTestAzExitCode = 1
        $script:MlsTestAzStderr = 'ERROR: (PolicyAssignmentNotFound) Policy assignment not found.'
        Invoke-AzCli -Arguments @('policy', 'assignment', 'show') -AllowNotFound | Should -BeNullOrEmpty
    }

    It 'STILL THROWS when az fails with a NON-not-found error, even with -AllowNotFound passed (Important 4)' {
        # The exact failure mode the review named: an expired token, throttling, or
        # a transient network error must never be silently read as "already
        # absent" just because -AllowNotFound happens to be set on the call site.
        $script:MlsTestAzExitCode = 1
        $script:MlsTestAzStderr = 'ERROR: AADSTS700082: The refresh token has expired.'
        { Invoke-AzCli -Arguments @('policy', 'assignment', 'show') -AllowNotFound } |
            Should -Throw '*refresh token has expired*'
    }

    It 'STILL THROWS on SubscriptionNotFound even with -AllowNotFound passed, rather than reporting the looked-up object absent (Important 4)' {
        # The exact failure mode the review named: "(SubscriptionNotFound) The
        # subscription '...' could not be found." textually matches the generic
        # not-found regex ("could not be found"), so a stale or typo'd
        # -SubscriptionId / $env:AZURE_SUBSCRIPTION_ID used to make the NIST
        # assignment look-up report NistOutcome='NotFound' - "already absent" -
        # when the real problem is that the SCOPE itself could not be resolved and
        # the assignment's actual existence was never checked at all.
        $script:MlsTestAzExitCode = 1
        $script:MlsTestAzStderr = "ERROR: (SubscriptionNotFound) The subscription '00000000-0000-0000-0000-000000000000' could not be found."
        { Invoke-AzCli -Arguments @('policy', 'assignment', 'show') -AllowNotFound } |
            Should -Throw '*SubscriptionNotFound*'
    }

    It 'parses JSON output on success ($LASTEXITCODE 0)' {
        $script:MlsTestAzExitCode = 0
        $script:MlsTestAzOutput = '{"name":"require-env"}'
        (Invoke-AzCli -Arguments @('policy', 'assignment', 'show')).name | Should -Be 'require-env'
    }
}

Describe 'infra/policy/teardown.ps1 - confirmation (Critical 1)' {
    It 'Invoke-AzMutation - the only function that actually calls ShouldProcess - declares ConfirmImpact High' {
        # ConfirmImpact does not propagate from a caller to a callee: declaring it
        # only on Invoke-Main (which never calls ShouldProcess itself) left every
        # destructive call running with no confirmation prompt at all under the
        # default $ConfirmPreference of 'High'. This is a metadata/reflection
        # assertion rather than a live-prompt test, because actually triggering
        # $Host.UI's confirmation prompt in a non-interactive Pester run would hang
        # or error rather than demonstrate anything.
        $attribute = (Get-Item Function:\Invoke-AzMutation).ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
        $attribute | Should -Not -BeNullOrEmpty
        $attribute.SupportsShouldProcess | Should -BeTrue
        $attribute.ConfirmImpact | Should -Be 'High'
    }

    It 'Invoke-AzMutation actually calls $PSCmdlet.ShouldProcess in its body, not merely declaring the attribute' {
        $source = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'teardown.ps1') -Raw
        $source | Should -Match '(?s)function Invoke-AzMutation \{.*?\$PSCmdlet\.ShouldProcess\('
    }

    It 'Invoke-AzMutation derives Confirmed from ShouldProcess - not hardcoded' {
        # The two assertions above are reflection/source checks; this one runs the
        # real function. Without it, hardcoding Confirmed = $true would reintroduce
        # Critical 1 (a declined delete reported as done) with the suite green
        # (F23 re-review, Important 1). -WhatIf is a genuine, non-interactive way
        # to make ShouldProcess return $false.
        Mock Invoke-AzCli { throw 'Invoke-AzCli must not be reached when ShouldProcess declines' }
        $result = Invoke-AzMutation -Target 'probe' -Action 'Delete probe' -Arguments @('policy', 'assignment', 'delete', '--name', 'probe') -WhatIf
        $result.Confirmed | Should -BeFalse -Because 'ShouldProcess returns false under -WhatIf'
        $result.Response | Should -BeNullOrEmpty -Because 'a declined mutation must not shell out to az at all'
        Should -Invoke Invoke-AzCli -Exactly -Times 0
    }

    It 'Invoke-Main itself does NOT call ShouldProcess - confirmation is delegated entirely to Invoke-AzMutation' {
        # Guards against a future edit re-introducing a second, redundant gate the
        # way infra/entra/teardown.ps1's wrapper functions once did (Important 6) -
        # a double gate is what let a single-layer mutation go undetected there.
        $source = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'teardown.ps1') -Raw
        $mainBody = [regex]::Match($source, '(?s)function Invoke-Main \{.*$').Value
        $mainBody | Should -Not -Match '\$PSCmdlet\.ShouldProcess\('
    }
}

Describe 'infra/policy/teardown.ps1 - Get-ManagementGroupSubscriptionId survives every null-children shape (Critical 3)' {
    # Every test here wraps the call in its own nested scriptblock that turns
    # StrictMode -Version Latest ON - the exact setting teardown.ps1 itself runs
    # under in production - rather than relying on this file's own
    # `Set-StrictMode -Off` (set right after dot-sourcing, above), because that
    # blanket -Off is what hid the original bug from every other test in this
    # file (F23 review, Critical 3). PowerShell's strict-mode setting is
    # dynamically scoped the same way $WhatIfPreference is, so Set-StrictMode
    # inside this nested scriptblock genuinely overrides the file-level -Off for
    # any function called from within it, and reverts the moment the scriptblock
    # returns.

    It 'returns an empty array when children is JSON null' {
        Mock Invoke-AzCli { [pscustomobject]@{ name = 'mls'; children = $null } }
        & {
            Set-StrictMode -Version Latest
            { Get-ManagementGroupSubscriptionId -Name 'mls' } | Should -Not -Throw
            @(Get-ManagementGroupSubscriptionId -Name 'mls') | Should -BeNullOrEmpty
        }
    }

    It 'returns an empty array when the children key is absent entirely' {
        Mock Invoke-AzCli { [pscustomobject]@{ name = 'mls' } }
        & {
            Set-StrictMode -Version Latest
            { Get-ManagementGroupSubscriptionId -Name 'mls' } | Should -Not -Throw
            @(Get-ManagementGroupSubscriptionId -Name 'mls') | Should -BeNullOrEmpty
        }
    }

    It 'skips a child that is missing its own type property, without throwing' {
        Mock Invoke-AzCli { [pscustomobject]@{ name = 'mls'; children = @([pscustomobject]@{ name = 'weird-child-no-type' }) } }
        & {
            Set-StrictMode -Version Latest
            { Get-ManagementGroupSubscriptionId -Name 'mls' } | Should -Not -Throw
            @(Get-ManagementGroupSubscriptionId -Name 'mls') | Should -BeNullOrEmpty
        }
    }

    It 'still finds a real subscription child once type and name are both present' {
        Mock Invoke-AzCli {
            [pscustomobject]@{
                name     = 'mls'
                children = @([pscustomobject]@{ type = 'Microsoft.Management/managementGroups/subscriptions'; name = 'sub-123' })
            }
        }
        & {
            Set-StrictMode -Version Latest
            @(Get-ManagementGroupSubscriptionId -Name 'mls') | Should -Be @('sub-123')
        }
    }

    It 'returns an empty array when the management group itself cannot be found' {
        Mock Invoke-AzCli { $null }
        & {
            Set-StrictMode -Version Latest
            { Get-ManagementGroupSubscriptionId -Name 'mls' } | Should -Not -Throw
            @(Get-ManagementGroupSubscriptionId -Name 'mls') | Should -BeNullOrEmpty
        }
    }
}

Describe 'infra/policy/teardown.ps1 - Invoke-Main' {
    BeforeEach {
        Mock Write-Status {}
        $env:GITHUB_ACTIONS = $null

        $script:AssignmentNames = @(Get-TagPolicyAssignmentName)
        $script:NistName = Get-NistAssignmentName
        $script:MgName = 'mls'
        $script:MgScope = "/providers/Microsoft.Management/managementGroups/$script:MgName"
        $script:SubId = '11111111-1111-1111-1111-111111111111'

        # Default: everything exists - the subscription is placed under the MG.
        # Delete-order log entries are tagged with the assignment NAME (not a
        # generic 'assignment-delete' label) so the order test below can tell the
        # NIST delete apart from the other 14, which a single undifferentiated
        # label could not (F23 review, minor).
        $script:CallLog = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-AzCli {
            $joined = $Arguments -join ' '
            if ($joined -like 'policy assignment show*') {
                $name = $Arguments[$Arguments.IndexOf('--name') + 1]
                return [pscustomobject]@{ name = $name }
            }
            if ($joined -like 'policy assignment delete*') {
                $name = $Arguments[$Arguments.IndexOf('--name') + 1]
                $script:CallLog.Add("assignment-delete:$name")
                return $null
            }
            if ($joined -like 'account management-group show*--expand*') {
                return [pscustomobject]@{
                    name     = $script:MgName
                    children = @([pscustomobject]@{ type = 'Microsoft.Management/managementGroups/subscriptions'; name = $script:SubId })
                }
            }
            if ($joined -like 'account management-group show*') {
                return [pscustomobject]@{ name = $script:MgName }
            }
            if ($joined -like 'account management-group subscription remove*') {
                $script:CallLog.Add('subscription-remove')
                return $null
            }
            if ($joined -like 'account management-group delete*') {
                $script:CallLog.Add('mg-delete')
                return $null
            }
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
            Should -Invoke Invoke-AzCli -Exactly -Times 0
        }

        It 'proceeds under GitHub Actions when -AllowAutomation is passed' {
            $env:GITHUB_ACTIONS = 'true'
            { Invoke-TeardownForTest -AsAllowAutomation } | Should -Not -Throw
        }
    }

    Context 'everything exists - full teardown' {
        It 'reports a declined delete as Declined, never Deleted - the re-review''s exact scenario' {
            # This script had NO decline coverage at all before the F23 re-review
            # (Important 1): deleting Invoke-Main's Declined branches shipped green
            # against the whole suite. Everything still "exists" via this block's
            # Invoke-AzCli harness; only the ShouldProcess answer changes.
            Mock Invoke-AzMutation { @{ Confirmed = $false; Response = $null } }

            $summary = Invoke-TeardownForTest

            $summary.AssignmentsDeleted | Should -Be 0 -Because 'every prompt was declined'
            $summary.AssignmentsDeclined | Should -Be $script:AssignmentNames.Count
            $summary.NistOutcome | Should -Be 'Declined'
            $summary.SubscriptionOutcome | Should -Be 'Declined'
            $summary.ManagementGroupOutcome | Should -Be 'Declined'
            $script:CallLog | Should -BeNullOrEmpty -Because 'a declined delete must not shell out to az'
        }

        It 'deletes every tag/location assignment, the NIST assignment, moves the subscription, then deletes the MG' {
            $summary = Invoke-TeardownForTest
            $summary.AssignmentsDeleted | Should -Be $script:AssignmentNames.Count
            $summary.NistOutcome | Should -Be 'Deleted'
            $summary.SubscriptionOutcome | Should -Be 'Deleted'
            $summary.ManagementGroupOutcome | Should -Be 'Deleted'
            Should -Invoke Invoke-AzCli -Exactly -Times ($script:AssignmentNames.Count + 1) -ParameterFilter {
                ($Arguments -join ' ') -like 'policy assignment delete*'
            }
        }

        It 'deletes each tag/location assignment by its own exact --name and --scope - not just the right count' {
            # The missing test class the review named directly: a lookup/delete
            # returning an arbitrary object of the right COUNT is indistinguishable
            # from correct unless something asserts the exact identity deleted.
            Invoke-TeardownForTest | Out-Null
            foreach ($name in $script:AssignmentNames) {
                Should -Invoke Invoke-AzCli -Exactly -Times 1 -ParameterFilter {
                    ($Arguments -join ' ') -eq "policy assignment delete --name $name --scope $script:MgScope"
                }
            }
        }

        It 'removes in order: policy assignments (tag/location), then NIST specifically, then the subscription move, then the MG delete' {
            Invoke-TeardownForTest | Out-Null
            $order = @($script:CallLog)

            $tagIndices = @($script:AssignmentNames | ForEach-Object { $order.IndexOf("assignment-delete:$_") })
            $nistIndex = $order.IndexOf("assignment-delete:$script:NistName")
            $subIndex = $order.IndexOf('subscription-remove')
            $mgIndex = $order.IndexOf('mg-delete')

            # every tag/location name's delete entry is present (IndexOf found it)
            $tagIndices | Should -Not -Contain -1
            $nistIndex | Should -Not -Be -1

            $lastTagIndex = ($tagIndices | Measure-Object -Maximum).Maximum
            $lastTagIndex | Should -BeLessThan $nistIndex
            $nistIndex | Should -BeLessThan $subIndex
            $subIndex | Should -BeLessThan $mgIndex
        }

        It 'checks the NIST assignment at SUBSCRIPTION scope, not management-group scope' {
            Invoke-TeardownForTest | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 1 -ParameterFilter {
                ($Arguments -join ' ') -like "policy assignment delete --name $script:NistName*" -and
                ($Arguments -join ' ') -like "*--scope /subscriptions/$script:SubId"
            }
        }
    }

    Context 'nothing exists yet - idempotent replay' {
        BeforeEach {
            Mock Invoke-AzCli { $null }
        }

        It 'treats every already-absent object as a no-op, not an error' {
            { Invoke-TeardownForTest } | Should -Not -Throw
            $summary = Invoke-TeardownForTest
            $summary.AssignmentsNotFound | Should -Be $script:AssignmentNames.Count
            $summary.NistOutcome | Should -Be 'NotFound'
            $summary.SubscriptionOutcome | Should -Be 'NotFound'
            $summary.ManagementGroupOutcome | Should -Be 'NotFound'
            Should -Invoke Invoke-AzCli -Exactly -Times 0 -ParameterFilter {
                ($Arguments -join ' ') -match 'delete|remove'
            }
        }
    }

    Context 'subscription cannot be resolved (Important 4)' {
        It 'throws rather than reporting the NIST assignment NotFound when the subscription itself cannot be found' {
            # Stands in for what the real (unmocked) Invoke-AzCli now does given a
            # "(SubscriptionNotFound) The subscription '...' could not be found."
            # stderr at the NIST assignment's subscription scope: it throws instead
            # of returning $null, because the earlier, unqualified -AllowNotFound
            # regex swallowed that message as "policy assignment already absent"
            # (F23 review, Important 4). A stale/typo'd -SubscriptionId must fail
            # loudly, not report NistOutcome='NotFound' as if the teardown had
            # confirmed the assignment itself was gone.
            Mock Invoke-AzCli {
                $joined = $Arguments -join ' '
                if ($joined -like "policy assignment show*--scope /subscriptions/$script:SubId*") {
                    throw "az policy assignment show failed with exit code 1: ERROR: (SubscriptionNotFound) The subscription '$script:SubId' could not be found."
                }
                if ($joined -like 'policy assignment show*') { return [pscustomobject]@{ name = $Arguments[$Arguments.IndexOf('--name') + 1] } }
                return $null
            }
            { Invoke-TeardownForTest } | Should -Throw '*SubscriptionNotFound*'
        }
    }

    Context 'no subscription ID available' {
        It 'skips the NIST assignment and the subscription move, but still tears down the rest' {
            $summary = Invoke-TeardownForTest -SubscriptionId ''
            $summary.NistOutcome | Should -Be 'Skipped'
            $summary.SubscriptionOutcome | Should -Be 'Skipped'
            $summary.AssignmentsDeleted | Should -Be $script:AssignmentNames.Count
            $summary.ManagementGroupOutcome | Should -Be 'Deleted'
        }
    }

    Context '-WhatIf makes no mutating calls' {
        It 'deletes and moves nothing' {
            Invoke-TeardownForTest -AsWhatIf | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 0 -ParameterFilter {
                ($Arguments -join ' ') -match 'delete|remove'
            }
        }

        It 'reports every found object as WhatIf rather than Deleted' {
            $summary = Invoke-TeardownForTest -AsWhatIf
            $summary.NistOutcome | Should -Be 'WhatIf'
            $summary.SubscriptionOutcome | Should -Be 'WhatIf'
            $summary.ManagementGroupOutcome | Should -Be 'WhatIf'
            $summary.AssignmentsDeleted | Should -Be 0
        }
    }
}
