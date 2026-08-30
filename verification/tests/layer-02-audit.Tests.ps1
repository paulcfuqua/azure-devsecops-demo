# Pester tests for verification/layer-02-audit.ps1 - every az call mocked; zero cloud calls.
# V2.2's write attempt belongs to the deploy workflow: these tests prove the audit only
# ever reads the Activity Log and `az group exists`.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-02-audit.ps1')
    # No Set-StrictMode -Off: the audit scripts set -Version Latest and CI runs them
    # that way, so the harness must not relax the language mode it is testing (F49).

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

        # ARM's own shape, which nests children under `properties`. It was the CLI's
        # flattened shape until V2.1 stopped using the CLI wrapper - that wrapper
        # register-actions on the subscription before reading, which a Reader cannot do
        # (F60). Before that it was @('mls-demo-subscription'), the old --query projection,
        # which could not even represent "the MG has children, none of them ours" (F59).
        $script:ManagementGroup = [pscustomobject]@{
            name       = 'mls'
            properties = [pscustomobject]@{
                children = @(
                    [pscustomobject]@{
                        id          = '/providers/Microsoft.Management/managementGroups/mls/subscriptions/22222222-2222-2222-2222-222222222222'
                        displayName = 'mls-demo-subscription'
                        type        = 'Microsoft.Management/managementGroups/subscriptions'
                    }
                )
            }
        }
        $script:CanaryEvents = @(
            [pscustomobject]@{
                op   = 'Microsoft.Resources/subscriptions/resourceGroups/write'
                sub  = 'Forbidden'
                code = "Resource 'mls-rg-canary-untagged' was disallowed by policy. RequestDisallowedByPolicy (policy assignment 'mls-require-tags-rg')"
            }
        )
        $script:CanaryExists = 'false'
        # V2.3 asks three questions now: is the initiative ASSIGNED (hard), does the estate
        # hold resources, and has Policy produced a summary. An unassigned initiative is a
        # real L2 failure; an empty estate is not (F61).
        $script:NistAssignments = @(
            [pscustomobject]@{
                id          = "/subscriptions/$($script:Subscription)/providers/Microsoft.Authorization/policyAssignments/mls-nist-800-53-r5"
                displayName = 'NIST SP 800-53 Rev. 5'
            }
        )
        $script:ResourceIds = @("/subscriptions/$($script:Subscription)/resourceGroups/mls-rg-ops/providers/Microsoft.Sql/servers/mls-ops-demo-sql")
        $script:PolicySummary = @(
            [pscustomobject]@{
                id           = "/subscriptions/$($script:Subscription)/providers/Microsoft.Authorization/policyAssignments/mls-nist-800-53-r5"
                nonCompliant = 4
            }
        )

        Mock Invoke-MlsAz {
            $joined = $Argument -join ' '
            if ($joined -like '*managementGroups/*') { return $script:ManagementGroup }
            if ($joined -like 'monitor activity-log list*') { return $script:CanaryEvents }
            if ($joined -like 'group exists*') { return $script:CanaryExists }
            if ($joined -like 'policy assignment list*') { return $script:NistAssignments }
            if ($joined -like 'resource list*') { return $script:ResourceIds }
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
            $script:ManagementGroup = [pscustomobject]@{ name = 'mls'; properties = [pscustomobject]@{ children = @() } }
            $context = Invoke-AuditForTest -NoRetry
            (Get-Row -Context $context -Id 'V2.1').Status | Should -Be 'FAIL'
            (Get-Row -Context $context -Id 'V2.1').Observed | Should -BeLike '*does not list the demo subscription as a child*'
            (Get-Row -Context $context -Id 'V2.1').Observed | Should -BeLike '*lists no children at all*' `
                -Because 'a FAIL must name what WAS there, not only what was missing'
        }

        It 'names the children it DID find when none is the subscription' {
            # The live failure was not "no children" - it was a verdict that could not say
            # which of several causes it meant. A wrong-subscription MG must read differently
            # from an empty one.
            $script:ManagementGroup = [pscustomobject]@{
                name       = 'mls'
                properties = [pscustomobject]@{ children = @(
                    [pscustomobject]@{
                        id          = '/providers/Microsoft.Management/managementGroups/mls/subscriptions/11111111-1111-1111-1111-111111111111'
                        displayName = 'somebody-elses-subscription'
                        type        = 'Microsoft.Management/managementGroups/subscriptions'
                    }
                ) }
            }
            $context = Invoke-AuditForTest -NoRetry
            (Get-Row -Context $context -Id 'V2.1').Status | Should -Be 'FAIL'
            (Get-Row -Context $context -Id 'V2.1').Observed | Should -BeLike '*somebody-elses-subscription*'
        }

        It 'fails V2.3 when no NIST assignment appears within the pinned 30-minute window' {
            $script:PolicySummary = @()
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V2.3'
            $row.Status | Should -Be 'FAIL'
            $row.RetryWindowMinutes | Should -Be 30
        }
    }

    Context 'the estate is fresh' {
        # L2 could not pass on an empty estate, and nothing downstream could run because of
        # it: V2.3 wanted compliance data, compliance data needs resources, resources come
        # from L3-L8, and L3-L8 are gated on this audit. Every run stopped here (F61).

        It 'records V2.3 as SKIP, not FAIL, when the estate holds no resources' {
            $script:ResourceIds = @()
            $script:PolicySummary = @()
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V2.3'
            $row.Status | Should -Be 'SKIP' -Because 'Policy cannot evaluate resources that do not exist'
            $row.Observed | Should -BeLike '*0 resources*'
            $row.Observed | Should -BeLike '*is assigned*' -Because 'the assignment is the part that IS checkable now'
        }

        It 'still exits 0 so the layers that create those resources can run' {
            # The whole point. A SKIP here must not gate L3-L8, or the cycle stays closed.
            $script:ResourceIds = @()
            $script:PolicySummary = @()
            $context = Invoke-AuditForTest
            Get-MlsExitCode -Context $context | Should -Be 0
        }

        It 'FAILs and does not retry when the NIST initiative is not assigned at all' {
            # The assignment is L2's own deliverable and depends on nothing downstream, so
            # its absence is a real failure of this layer - never softened to SKIP.
            $script:NistAssignments = @()
            $script:ResourceIds = @()
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V2.3'
            $row.Status | Should -Be 'FAIL'
            $row.Attempt | Should -Be 1 -Because 'a missing assignment is not a propagation delay'
            $row.Observed | Should -BeLike '*no policy assignment*'
        }

        It 'FAILs when resources exist but Policy has produced no summary' {
            # With something to evaluate, silence from Policy is a real finding again.
            $script:PolicySummary = @()
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V2.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*1 resource*'
        }
    }

    Context 'retry' {
        It 'retries V2.3 until compliance data appears, without sleeping the whole window' {
            $script:PolicySummary = @()
            $script:Calls = 0
            Mock Invoke-MlsAz {
                $joined = $Argument -join ' '
                if ($joined -like '*managementGroups/*') { return $script:ManagementGroup }
                if ($joined -like 'monitor activity-log list*') { return $script:CanaryEvents }
                if ($joined -like 'group exists*') { return 'false' }
                if ($joined -like 'policy assignment list*') { return $script:NistAssignments }
                if ($joined -like 'resource list*') { return $script:ResourceIds }
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
            # One poll interval, not the whole window - asserted against the row's own
            # cadence rather than a literal, so right-sizing the defaults (F59) cannot
            # silently turn this into a test of a constant nobody re-checked.
            $row.SleptSeconds | Should -Be $row.PollIntervalSecond
            $row.SleptSeconds | Should -BeLessThan ($row.RetryWindowMinutes * 60)
            Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 1
        }
    }

    Context 'a check that throws' {
        It 'reports WHY a denied MG read failed, and does not retry it' {
            # The live failure said "does not report the demo subscription as a child (or the
            # MG read was denied)" - one sentence for two causes - and spent the full window
            # reaching it. Dropping -AllowFailure lets az's own stderr through, and the
            # criterion loop marks a permission failure Final (F57/F59).
            Mock Invoke-MlsAz {
                $joined = $Argument -join ' '
                if ($joined -like '*managementGroups/*') {
                    # This mock HONOURS -AllowFailure, returning $null exactly as the real
                    # transport does. A mock that throws either way cannot tell the two code
                    # paths apart, and this test then passes whether the fix is present or
                    # not - it mutation-SURVIVED in that form, which is how it was caught.
                    if ($AllowFailure) { return $null }
                    throw "az rest --method get --url .../managementGroups/mls failed with exit code 1: (AuthorizationFailed) The client does not have authorization to perform action 'Microsoft.Management/managementGroups/read'."
                }
                if ($joined -like 'monitor activity-log list*') { return $script:CanaryEvents }
                if ($joined -like 'group exists*') { return 'false' }
                if ($joined -like 'policy assignment list*') { return $script:NistAssignments }
                if ($joined -like 'resource list*') { return $script:ResourceIds }
                if ($joined -like 'policy state summarize*') { return $script:PolicySummary }
                throw "unexpected az call: $joined"
            }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V2.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*AuthorizationFailed*' -Because 'the reason is the finding'
            $row.Observed | Should -Not -BeLike '*does not list the demo subscription*' `
                -Because 'a denied read is not evidence about the hierarchy'
            $row.Attempt | Should -Be 1 -Because 'waiting cannot turn forbidden into permitted'
        }

        It 'records V2.1 as FAIL and still evaluates V2.2 and V2.3' {
            Mock Invoke-MlsAz {
                $joined = $Argument -join ' '
                if ($joined -like '*managementGroups/*') { throw "az rest --method get --url .../managementGroups/mls failed with exit code 3" }
                if ($joined -like 'monitor activity-log list*') { return $script:CanaryEvents }
                if ($joined -like 'group exists*') { return 'false' }
                if ($joined -like 'policy assignment list*') { return $script:NistAssignments }
                if ($joined -like 'resource list*') { return $script:ResourceIds }
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
