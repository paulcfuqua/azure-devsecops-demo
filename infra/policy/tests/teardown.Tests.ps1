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
    function az {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for the az CLI executable so Invoke-AzCli''s own $LASTEXITCODE handling can be unit-tested without a real az process. $Args is read by name via the automatic variable, not this parameter.')]
        param()
        $global:LASTEXITCODE = $global:MlsTestAzExitCode
        if ($global:MlsTestAzOutput) { return $global:MlsTestAzOutput }
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
        $global:MlsTestAzExitCode = 0
        $global:MlsTestAzOutput = $null
    }

    AfterAll {
        Remove-Variable -Name MlsTestAzExitCode, MlsTestAzOutput -Scope Global -ErrorAction SilentlyContinue
    }

    It 'throws, naming the exit code, when az fails and -AllowFailure is not passed' {
        $global:MlsTestAzExitCode = 1
        { Invoke-AzCli -Arguments @('policy', 'assignment', 'show') } | Should -Throw '*exit code 1*'
    }

    It 'returns $null instead of throwing when az fails and -AllowFailure IS passed' {
        $global:MlsTestAzExitCode = 1
        Invoke-AzCli -Arguments @('policy', 'assignment', 'show') -AllowFailure | Should -BeNullOrEmpty
    }

    It 'parses JSON output on success ($LASTEXITCODE 0)' {
        $global:MlsTestAzExitCode = 0
        $global:MlsTestAzOutput = '{"name":"require-env"}'
        (Invoke-AzCli -Arguments @('policy', 'assignment', 'show')).name | Should -Be 'require-env'
    }
}

Describe 'infra/policy/teardown.ps1 - Invoke-Main' {
    BeforeEach {
        Mock Write-Status {}
        $env:GITHUB_ACTIONS = $null

        $script:AssignmentNames = @(Get-TagPolicyAssignmentName)
        $script:NistName = Get-NistAssignmentName
        $script:MgName = 'mls'
        $script:SubId = '11111111-1111-1111-1111-111111111111'

        # Default: everything exists - the subscription is placed under the MG.
        $script:CallLog = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-AzCli {
            $joined = $Arguments -join ' '
            if ($joined -like 'policy assignment show*') {
                $name = $Arguments[$Arguments.IndexOf('--name') + 1]
                return [pscustomobject]@{ name = $name }
            }
            if ($joined -like 'policy assignment delete*') {
                $script:CallLog.Add('assignment-delete')
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

        It 'removes in order: policy assignments, then the NIST assignment, then the subscription move, then the MG delete' {
            Invoke-TeardownForTest | Out-Null
            $order = @($script:CallLog | Select-Object -Unique)
            $order | Should -Be @('assignment-delete', 'subscription-remove', 'mg-delete')
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
