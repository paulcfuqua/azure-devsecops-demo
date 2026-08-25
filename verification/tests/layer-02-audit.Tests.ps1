# Pester tests for verification/layer-02-audit.ps1 - every az call mocked; zero cloud calls.
# V2.2's write attempt belongs to the deploy workflow: these tests prove the audit only
# ever reads the Activity Log and `az group exists`.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-02-audit.ps1')
    Set-StrictMode -Off

    $script:ReportRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-l02-$([guid]::NewGuid().ToString('n'))"
    $script:Subscription = '22222222-2222-2222-2222-222222222222'
    $script:SavedSubscription = [Environment]::GetEnvironmentVariable('AZURE_SUBSCRIPTION_ID')

    function Get-Row {
        param($Context, [string]$Id)
        return @($Context.Criterion | Where-Object { $_.Id -eq $Id })[0]
    }

    function Invoke-AuditForTest {
        param([switch]$NoRetry, [string]$SubscriptionId = $script:Subscription)
        Invoke-Main -SubscriptionId $SubscriptionId -ReportRoot $script:ReportRoot -NoRetry:$NoRetry
    }
}

AfterAll {
    [Environment]::SetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', $script:SavedSubscription)
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:ReportRoot) {
        Remove-Item -LiteralPath $script:ReportRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'layer-02-audit' {
    BeforeEach {
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'

        $script:ManagementGroupChildren = @('mls-demo-subscription')
        $script:CanaryEvents = @(
            [pscustomobject]@{
                op   = 'Microsoft.Resources/subscriptions/resourceGroups/write'
                sub  = 'Forbidden'
                code = "Resource 'mls-rg-canary-untagged' was disallowed by policy. RequestDisallowedByPolicy (policy assignment 'mls-require-tags-rg')"
            }
        )
        $script:CanaryExists = 'false'
        $script:PolicySummary = @(
            [pscustomobject]@{
                id           = "/subscriptions/$($script:Subscription)/providers/Microsoft.Authorization/policyAssignments/mls-nist-800-53-r5"
                nonCompliant = 4
            }
        )

        Mock Invoke-MlsAz {
            $joined = $Argument -join ' '
            if ($joined -like 'account management-group show*') { return $script:ManagementGroupChildren }
            if ($joined -like 'monitor activity-log list*') { return $script:CanaryEvents }
            if ($joined -like 'group exists*') { return $script:CanaryExists }
            if ($joined -like 'policy state summarize*') { return $script:PolicySummary }
            throw "unexpected az call: $joined"
        }
    }

    Context 'all criteria pass' {
        It 'records V2.1-V2.3 as PASS and exits 0' {
            $context = Invoke-AuditForTest
            @($context.Criterion).Id | Should -Be @('V2.1', 'V2.2', 'V2.3')
            @($context.Criterion | Where-Object { $_.Status -ne 'PASS' }) | Should -BeNullOrEmpty
            Get-MlsExitCode -Context $context | Should -Be 0
        }

        It 'confirms the canary denial from the Activity Log and never attempts the write itself' {
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V2.2'
            $row.Observed | Should -BeLike '*RequestDisallowedByPolicy*'
            $row.Detail | Should -BeLike '*performed by the deploy workflow*'
            Should -Invoke Invoke-MlsAz -ParameterFilter { ($Argument -join ' ') -like '*group create*' } -Exactly -Times 0
        }
    }

    Context 'a criterion fails on a realistic wrong value' {
        It 'fails V2.2 when the canary resource group was left behind' {
            $script:CanaryExists = 'true'
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V2.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*still exists*'
            Get-MlsExitCode -Context $context | Should -Be 1
        }

        It 'fails V2.1 when the subscription is not under the management group' {
            $script:ManagementGroupChildren = @()
            $context = Invoke-AuditForTest -NoRetry
            (Get-Row -Context $context -Id 'V2.1').Status | Should -Be 'FAIL'
            (Get-Row -Context $context -Id 'V2.1').Observed | Should -BeLike '*does not report the demo subscription*'
        }

        It 'fails V2.3 when no NIST assignment appears within the pinned 30-minute window' {
            $script:PolicySummary = @()
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V2.3'
            $row.Status | Should -Be 'FAIL'
            $row.RetryWindowMinutes | Should -Be 30
        }
    }

    Context 'retry' {
        It 'retries V2.3 until compliance data appears, without sleeping the whole window' {
            $script:PolicySummary = @()
            $script:Calls = 0
            Mock Invoke-MlsAz {
                $joined = $Argument -join ' '
                if ($joined -like 'account management-group show*') { return @('mls-demo-subscription') }
                if ($joined -like 'monitor activity-log list*') { return $script:CanaryEvents }
                if ($joined -like 'group exists*') { return 'false' }
                if ($joined -like 'policy state summarize*') {
                    $script:Calls++
                    if ($script:Calls -lt 2) { return @() }
                    return @([pscustomobject]@{ id = 'mls-nist-800-53-r5'; nonCompliant = 0 })
                }
                throw "unexpected az call: $joined"
            }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V2.3'
            $row.Status | Should -Be 'PASS'
            $row.Attempt | Should -Be 2
            $row.SleptSeconds | Should -Be 300
            $row.SleptSeconds | Should -BeLessThan (30 * 60)
            Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 1
        }
    }

    Context 'a check that throws' {
        It 'records V2.1 as FAIL and still evaluates V2.2 and V2.3' {
            Mock Invoke-MlsAz {
                $joined = $Argument -join ' '
                if ($joined -like 'account management-group show*') { throw "az account management-group show failed with exit code 3" }
                if ($joined -like 'monitor activity-log list*') { return $script:CanaryEvents }
                if ($joined -like 'group exists*') { return 'false' }
                if ($joined -like 'policy state summarize*') { return $script:PolicySummary }
                throw "unexpected az call: $joined"
            }
            $context = Invoke-AuditForTest -NoRetry
            @($context.Criterion).Count | Should -Be 3
            (Get-Row -Context $context -Id 'V2.1').Status | Should -Be 'FAIL'
            (Get-Row -Context $context -Id 'V2.1').Observed | Should -BeLike '*exit code 3*'
            (Get-Row -Context $context -Id 'V2.3').Status | Should -Be 'PASS'
        }
    }

    Context 'missing input' {
        It 'refuses to run without a subscription id and says how to supply one' {
            [Environment]::SetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', $null)
            { Invoke-AuditForTest -SubscriptionId '' } | Should -Throw '*SubscriptionId*'
            { Invoke-AuditForTest -SubscriptionId '' } | Should -Throw '*AZURE_SUBSCRIPTION_ID*'
        }
    }
}
