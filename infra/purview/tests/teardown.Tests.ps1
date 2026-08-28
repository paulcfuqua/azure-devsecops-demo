# Pester tests for infra/purview/teardown.ps1 - S&C cmdlets stubbed + mocked; zero cloud calls.
# Mirrors infra/purview/tests/labels.Tests.ps1's stub convention and
# infra/entra/tests/teardown.Tests.ps1's CI-guard/-WhatIf/order convention.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'

    # ExchangeOnlineManagement is not loaded in tests: define local stand-ins for the
    # four S&C cmdlets this script calls, then Mock them per scenario.
    function Get-Label {
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$Identity)
        throw "stub Get-Label called without a mock (Identity: $Identity)"
    }
    function Get-LabelPolicy {
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$Identity)
        throw "stub Get-LabelPolicy called without a mock (Identity: $Identity)"
    }
    function Remove-Label {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Stand-in for the ExchangeOnlineManagement cmdlet of the same name, which teardown.ps1 calls by that exact name. The stub must keep the real name and signature so Pester can Mock it, and it changes no state at all - the body is deliberately empty.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'The parameter exists to mirror the real S&C cmdlet signature so that teardown.ps1 binds against it and Should -Invoke -ParameterFilter can inspect $Identity. An empty body that uses nothing is the point of the stub.')]
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$Identity)
    }
    function Remove-LabelPolicy {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Stand-in for the ExchangeOnlineManagement cmdlet of the same name, which teardown.ps1 calls by that exact name. The stub must keep the real name and signature so Pester can Mock it, and it changes no state at all - the body is deliberately empty.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'The parameter exists to mirror the real S&C cmdlet signature so that teardown.ps1 binds against it and Should -Invoke -ParameterFilter can inspect $Identity. An empty body that uses nothing is the point of the stub.')]
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$Identity)
    }

    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'teardown.ps1')
    Set-StrictMode -Off

    $script:ExpectedNames = @('Public', 'Internal', 'Confidential', 'Export-Controlled')
    $script:ExpectedPolicyName = 'mls-demo-label-policy'

    function Invoke-TeardownForTest {
        param([switch]$AsWhatIf, [switch]$AsAllowAutomation)
        Invoke-Main -AllowAutomation:$AsAllowAutomation -WhatIf:$AsWhatIf -Confirm:$false
    }
}

AfterAll {
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
}

Describe 'infra/purview/teardown.ps1' {
    BeforeEach {
        Mock Write-Status {}
        Mock Test-IppSession { $true }
        $env:GITHUB_ACTIONS = $null

        # Default: everything exists, so every scenario that cares about "found" is
        # the default and contexts that want "absent" override explicitly.
        Mock Get-Label {
            if ($script:ExpectedNames -contains $Identity) {
                return [pscustomobject]@{ Name = $Identity }
            }
            throw "The Label $Identity doesn't exist"
        }
        Mock Get-LabelPolicy {
            if ($Identity -eq $script:ExpectedPolicyName) {
                return [pscustomobject]@{ Identity = $Identity }
            }
            throw "The label policy $Identity doesn't exist"
        }

        $script:DeleteOrder = [System.Collections.Generic.List[string]]::new()
        Mock Remove-Label { $script:DeleteOrder.Add("label:$Identity") }
        Mock Remove-LabelPolicy { $script:DeleteOrder.Add("policy:$Identity") }
    }

    AfterEach {
        $env:GITHUB_ACTIONS = $null
    }

    Context 'CI guard' {
        It 'refuses to run under GitHub Actions without -AllowAutomation' {
            $env:GITHUB_ACTIONS = 'true'
            { Invoke-TeardownForTest } | Should -Throw '*GITHUB_ACTIONS*'
            Should -Invoke Remove-Label -Exactly -Times 0
            Should -Invoke Remove-LabelPolicy -Exactly -Times 0
        }

        It 'proceeds under GitHub Actions when -AllowAutomation is passed' {
            $env:GITHUB_ACTIONS = 'true'
            { Invoke-TeardownForTest -AsAllowAutomation } | Should -Not -Throw
        }
    }

    Context 'everything exists - full teardown' {
        It 'deletes the label policy and all four labels' {
            $result = Invoke-TeardownForTest
            Should -Invoke Remove-LabelPolicy -Exactly -Times 1 -ParameterFilter { $Identity -eq $script:ExpectedPolicyName }
            Should -Invoke Remove-Label -Exactly -Times 4
            foreach ($name in $script:ExpectedNames) {
                Should -Invoke Remove-Label -Exactly -Times 1 -ParameterFilter { $Identity -eq $name }
                $result.$name | Should -Be 'Deleted'
            }
            $result.LabelPolicy | Should -Be 'Deleted'
        }

        It 'removes the label POLICY before any of the labels - a label scoped by a live policy cannot be deleted' {
            Invoke-TeardownForTest | Out-Null
            $script:DeleteOrder.Count | Should -Be 5
            $script:DeleteOrder[0] | Should -Be "policy:$script:ExpectedPolicyName"
            @($script:DeleteOrder | Select-Object -Skip 1) | ForEach-Object { $_ | Should -BeLike 'label:*' }
        }
    }

    Context 'nothing exists yet - idempotent replay' {
        BeforeEach {
            Mock Get-Label { throw "The Label $Identity doesn't exist" }
            Mock Get-LabelPolicy { throw "The label policy $Identity doesn't exist" }
        }

        It 'treats every already-absent object as a no-op, not an error' {
            { Invoke-TeardownForTest } | Should -Not -Throw
            $result = Invoke-TeardownForTest
            $result.LabelPolicy | Should -Be 'NotFound'
            foreach ($name in $script:ExpectedNames) { $result.$name | Should -Be 'NotFound' }
            Should -Invoke Remove-Label -Exactly -Times 0
            Should -Invoke Remove-LabelPolicy -Exactly -Times 0
        }
    }

    Context 'mixed: policy already gone, labels still present' {
        BeforeEach {
            Mock Get-LabelPolicy { throw "The label policy $Identity doesn't exist" }
        }

        It 'still deletes the four labels, and the policy outcome is NotFound rather than an error' {
            $result = Invoke-TeardownForTest
            $result.LabelPolicy | Should -Be 'NotFound'
            Should -Invoke Remove-Label -Exactly -Times 4
            foreach ($name in $script:ExpectedNames) { $result.$name | Should -Be 'Deleted' }
        }
    }

    Context '-WhatIf makes no mutating calls' {
        It 'deletes nothing even though the policy and every label exist' {
            Invoke-TeardownForTest -AsWhatIf | Out-Null
            Should -Invoke Remove-Label -Exactly -Times 0
            Should -Invoke Remove-LabelPolicy -Exactly -Times 0
        }

        It 'reports every found object as WhatIf rather than Deleted' {
            $result = Invoke-TeardownForTest -AsWhatIf
            $result.LabelPolicy | Should -Be 'WhatIf'
            foreach ($name in $script:ExpectedNames) { $result.$name | Should -Be 'WhatIf' }
        }
    }

    Context 'session guard' {
        It 'fails clearly when Connect-IPPSSession has not been run' {
            Mock Test-IppSession { throw 'Security & Compliance cmdlets not found. Run Connect-IPPSSession first.' }
            { Invoke-TeardownForTest } | Should -Throw '*Connect-IPPSSession*'
            Should -Invoke Remove-Label -Exactly -Times 0
            Should -Invoke Remove-LabelPolicy -Exactly -Times 0
        }
    }

    Context 'confirmation (Critical 1)' {
        It 'Remove-SensitivityLabel and Remove-PublishedLabelPolicy - the only functions that actually call ShouldProcess - declare ConfirmImpact High' {
            # ConfirmImpact does not propagate from a caller to a callee: declaring
            # it only on Invoke-Main (which never calls ShouldProcess itself) left
            # every destructive call running with no confirmation prompt at all
            # under the default $ConfirmPreference of 'High'. This is a
            # metadata/reflection assertion rather than a live-prompt test, because
            # actually triggering $Host.UI's confirmation prompt in a
            # non-interactive Pester run would hang or error rather than
            # demonstrate anything.
            foreach ($functionName in @('Remove-SensitivityLabel', 'Remove-PublishedLabelPolicy')) {
                $attribute = (Get-Item "Function:\$functionName").ScriptBlock.Attributes |
                    Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
                $attribute | Should -Not -BeNullOrEmpty -Because "$functionName should declare CmdletBinding"
                $attribute.SupportsShouldProcess | Should -BeTrue -Because "$functionName should support ShouldProcess"
                $attribute.ConfirmImpact | Should -Be 'High' -Because "$functionName is the function that actually calls ShouldProcess"
            }
        }

        It 'Remove-SensitivityLabel and Remove-PublishedLabelPolicy actually call $PSCmdlet.ShouldProcess in their bodies' {
            $source = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'teardown.ps1') -Raw
            foreach ($functionName in @('Remove-SensitivityLabel', 'Remove-PublishedLabelPolicy')) {
                $body = [regex]::Match($source, "(?sm)^function $functionName \{.*?^\}").Value
                $body | Should -Match '\$PSCmdlet\.ShouldProcess\(' -Because "$functionName must actually call ShouldProcess, not merely declare it"
            }
        }
    }

    Context 'declined confirmation is reported as Declined, never Deleted (Critical 1)' {
        # The review's repro on this script: with every prompt declined, all five
        # outcomes still printed "Deleted ..." while zero Remove-Label /
        # Remove-LabelPolicy calls fired. The bug was that the Remove-* wrappers
        # reported success on BOTH ShouldProcess branches and Invoke-Main inferred
        # the outcome from $WhatIfPreference - which is $false for a declined
        # prompt exactly as it is for a real delete.
        #
        # These two removers call $PSCmdlet.ShouldProcess directly rather than
        # routing through a mockable mutation helper, and -Confirm:$false (used by
        # every other context here, so the suite never blocks on a live prompt)
        # forces ShouldProcess to return $true. Mocking the removers to return the
        # declined shape is therefore the only non-interactive way to exercise
        # Invoke-Main's reporting for this path.
        It 'reports every category as Declined, not Deleted, when every prompt is declined' {
            Mock Remove-PublishedLabelPolicy { @{ Name = $Name; Existed = $true; Confirmed = $false } }
            Mock Remove-SensitivityLabel { @{ Name = $Name; Existed = $true; Confirmed = $false } }

            $outcomes = Invoke-TeardownForTest

            $values = @($outcomes.PSObject.Properties | ForEach-Object { $_.Value })
            $values | Should -Not -Contain 'Deleted' -Because 'a declined prompt deleted nothing'
            @($values | Where-Object { $_ -eq 'Declined' }).Count |
                Should -Be 5 -Because 'the label policy plus all four labels were declined'
        }

        It 'still reports Deleted when the prompt is confirmed - the guard is not simply hard-coded' {
            Mock Remove-PublishedLabelPolicy { @{ Name = $Name; Existed = $true; Confirmed = $true } }
            Mock Remove-SensitivityLabel { @{ Name = $Name; Existed = $true; Confirmed = $true } }

            $outcomes = Invoke-TeardownForTest

            $values = @($outcomes.PSObject.Properties | ForEach-Object { $_.Value })
            $values | Should -Not -Contain 'Declined'
            @($values | Where-Object { $_ -eq 'Deleted' }).Count | Should -Be 5
        }

        It 'a declined delete is distinguished from a dry run - -WhatIf reports WhatIf, not Declined' {
            # Both leave Confirmed $false; only one is a dry run. Conflating them
            # would make a -WhatIf rehearsal look like a refused teardown.
            Mock Remove-PublishedLabelPolicy { @{ Name = $Name; Existed = $true; Confirmed = $false } }
            Mock Remove-SensitivityLabel { @{ Name = $Name; Existed = $true; Confirmed = $false } }

            $outcomes = Invoke-Main -WhatIf

            $values = @($outcomes.PSObject.Properties | ForEach-Object { $_.Value })
            $values | Should -Not -Contain 'Declined'
            @($values | Where-Object { $_ -eq 'WhatIf' }).Count | Should -Be 5
        }
    }

}
