#Requires -Version 7.0
<#
.SYNOPSIS
    L2 Verifier audit - landing zone: management groups, policies, NIST. READ-ONLY.

.DESCRIPTION
    Implements the three master-plan Verify criteria owned by
    docs/runbooks/layers/L02.md section Validation cycle, and nothing else:

      V2.1  az account management-group show mls shows the sub.
      V2.2  Creating an untagged canary RG fails with policy denial (then cleaned up).
      V2.3  az policy state summarize returns NIST compliance data within 30 min of
            assignment.

    V2.2 IS DELIBERATELY HALF-IMPLEMENTED, AND THAT IS THE DESIGN. The criterion needs a
    write attempt, and the Verifier is Reader-only: it must never create a resource group,
    not even one policy is expected to reject. So the deploy workflow
    (.github/workflows/layer-02-landing-zone.yml) performs the untagged `az group create`,
    asserts the RequestDisallowedByPolicy failure and deletes the canary if it somehow
    succeeded; this audit confirms the same facts independently from the Activity Log and
    from `az group exists`. That split is stated in L02.md section Deploy procedure step 1
    and is the reason nothing here mutates.

.EXAMPLE
    ./layer-02-audit.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ManagementGroupName = 'mls',
    [string]$CanaryResourceGroupName = 'mls-rg-canary-untagged',
    [string]$ActivityLogOffset = '2h',
    [string]$NistAssignmentPattern = 'nist',
    [string]$ReportRoot,
    [switch]$NoRetry
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'MlsAudit.psm1') -Force

function Test-ManagementGroupPlacement {
    <# V2.1 - the demo subscription must be a child of MG mls. #>
    param(
        [Parameter(Mandatory)][string]$ManagementGroupName,
        [Parameter(Mandatory)][string]$SubscriptionId
    )
    # NO -AllowFailure, and NO --query. Both were hiding the answer (F59).
    #
    # -AllowFailure turned a denied read into $null, which this function then reported with
    # the same sentence as a genuinely absent child - "does not report the demo subscription
    # as a child (or the MG read was denied)". That disjunction is not a finding, it is two
    # findings the criterion could not tell apart, and it retried the pair for the full
    # thirty-minute window before saying so. Letting az throw instead gives the criterion
    # loop the real stderr, and a permission failure is marked Final there (F57) rather than
    # waited out.
    #
    # --query projected the answer away: on a failure the report could say only that the
    # projection was empty, never what the management group actually contained. The children
    # are filtered here so the observed value can name what WAS found.
    $mg = Invoke-MlsAz -Argument @(
        'account', 'management-group', 'show', '--name', $ManagementGroupName,
        '--expand', '--recurse', '--output', 'json')

    $children = @()
    if ($null -ne $mg -and (Test-MlsHasProperty -InputObject $mg -Name 'children')) {
        $children = @(Get-MlsProperty -InputObject $mg -Name 'children' | Where-Object { $null -ne $_ })
    }
    $found = @($children | Where-Object { "$(Get-MlsProperty -InputObject $_ -Name 'id')" -like "*$SubscriptionId*" })

    if ($found.Count -eq 1) {
        return New-MlsCheckResult -Passed $true -Observed "one child: $(Get-MlsProperty -InputObject $found[0] -Name 'displayName')"
    }
    if ($found.Count -gt 1) {
        return New-MlsCheckResult -Passed $false -Observed "$($found.Count) children matched the subscription id"
    }
    $inventory = if ($children.Count -eq 0) {
        'it lists no children at all'
    }
    else {
        'its children are: ' + (($children | ForEach-Object {
                    "$(Get-MlsProperty -InputObject $_ -Name 'displayName') [$(Get-MlsProperty -InputObject $_ -Name 'type')]"
                }) -join ', ')
    }
    return New-MlsCheckResult -Passed $false -Observed "management group '$ManagementGroupName' does not list the demo subscription as a child - $inventory" `
        -Detail 'A denied MG read no longer reaches here - it throws, carrying az stderr, and is marked Final by the criterion loop (L02.md V2.1).'
}

function Test-CanaryPolicyDenial {
    <# V2.2, read-only half: the deploy workflow made the write attempt; the Verifier
       confirms the denial from the Activity Log and confirms the canary is gone. #>
    param(
        [Parameter(Mandatory)][string]$CanaryResourceGroupName,
        [Parameter(Mandatory)][string]$ActivityLogOffset
    )
    $events = @(Invoke-MlsAz -AllowFailure -Argument @(
            'monitor', 'activity-log', 'list', '--offset', $ActivityLogOffset, '--status', 'Failed',
            '--query', "[?contains(resourceGroupName,'$CanaryResourceGroupName')].{op:operationName.value, sub:subStatus.localizedValue, code:properties.statusMessage}",
            '--output', 'json'
        ))
    $exists = Invoke-MlsAz -AllowFailure -Raw -Argument @('group', 'exists', '--name', $CanaryResourceGroupName)
    $existsValue = "$exists".Trim().ToLowerInvariant()

    $denials = @($events | Where-Object {
            $operation = "$(Get-MlsProperty -InputObject $_ -Name 'op')"
            $message = "$(Get-MlsProperty -InputObject $_ -Name 'code')$(Get-MlsProperty -InputObject $_ -Name 'sub')"
            $operation -like '*resourceGroups/write*' -and $message -match 'RequestDisallowedByPolicy'
        })
    if ($denials.Count -eq 0) {
        return New-MlsCheckResult -Passed $false `
            -Observed "no failed resourceGroups/write event carrying RequestDisallowedByPolicy for '$CanaryResourceGroupName' in the last $ActivityLogOffset (events matched: $($events.Count)); az group exists = $existsValue" `
            -Detail 'If the Activity Log shows the canary SUCCEEDING, the tag-deny assignment had not propagated - the deploy workflow retries it, and this audit polls inside the standard 30-minute window before declaring failure (L02.md V2.2).'
    }
    if ($existsValue -eq 'true') {
        return New-MlsCheckResult -Passed $false `
            -Observed "policy denial observed ($($denials.Count) event(s)) but the canary resource group still exists" `
            -Detail 'L02 failure mode 4: assertion passed, cleanup step did not. Re-run the deploy workflow, which deletes it (RG-scoped delete is gate-free).' -Final
    }
    return New-MlsCheckResult -Passed $true `
        -Observed "$($denials.Count) RequestDisallowedByPolicy event(s) on resourceGroups/write for '$CanaryResourceGroupName'; az group exists = $existsValue" `
        -Detail 'Write attempt performed by the deploy workflow (Verifier is Reader-only); confirmed here from the Activity Log.'
}

function Test-NistComplianceData {
    <# V2.3 - the NIST 800-53 R5 initiative assignment must appear with a results block. #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$NistAssignmentPattern
    )
    $summaries = @(Invoke-MlsAz -AllowFailure -Argument @(
            'policy', 'state', 'summarize', '--subscription', $SubscriptionId,
            '--query', "policyAssignments[?contains(policyAssignmentId,'$NistAssignmentPattern')].{id:policyAssignmentId, nonCompliant:results.nonCompliantResources}",
            '--output', 'json'
        ))
    $matched = @($summaries | Where-Object { $null -ne $_ -and $null -ne (Get-MlsProperty -InputObject $_ -Name 'id') })
    if ($matched.Count -eq 0) {
        return New-MlsCheckResult -Passed $false `
            -Observed "no policy assignment whose id contains '$NistAssignmentPattern' appears in the policy state summary" `
            -Detail 'Explicitly a 30-minute window from assignment (master plan L2). A first evaluation cycle beyond 30 minutes is a criterion failure, not a longer wait.'
    }
    $withResults = @($matched | Where-Object { $null -ne (Get-MlsProperty -InputObject $_ -Name 'nonCompliant') })
    if ($withResults.Count -eq 0) {
        return New-MlsCheckResult -Passed $false `
            -Observed "assignment present ($((Get-MlsProperty -InputObject $matched[0] -Name 'id'))) but no results block has been produced yet"
    }
    $describe = @($withResults | ForEach-Object {
            "$(Get-MlsProperty -InputObject $_ -Name 'id') nonCompliantResources=$(Get-MlsProperty -InputObject $_ -Name 'nonCompliant')"
        })
    return New-MlsCheckResult -Passed $true -Observed ($describe -join ' ; ') `
        -Detail 'Presence of the assignment summary with a populated results block is the pass condition, per the plan wording "returns NIST compliance data".'
}

function Invoke-Main {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Every parameter is consumed inside the criterion scriptblocks; PSSA cannot see through scriptblock closures.')]
    param(
        [string]$SubscriptionId,
        [string]$ManagementGroupName = 'mls',
        [string]$CanaryResourceGroupName = 'mls-rg-canary-untagged',
        [string]$ActivityLogOffset = '2h',
        [string]$NistAssignmentPattern = 'nist',
        [string]$ReportRoot,
        [switch]$NoRetry
    )
    $subscription = Resolve-MlsInput -Name 'SubscriptionId' -Value $SubscriptionId `
        -EnvironmentVariable @('AZURE_SUBSCRIPTION_ID') `
        -Hint 'The demo subscription the landing zone governs; the audit reads it as mls-verifier (Reader).'

    $context = New-MlsAuditContext -Layer 2 -Title 'Landing zone: management groups, policies, NIST' `
        -ScriptName 'verification/layer-02-audit.ps1' -ReportRoot $ReportRoot -NoRetry:$NoRetry
    Add-MlsPreflight -Context $context -Name 'SubscriptionId' -Value $subscription
    Add-MlsPreflight -Context $context -Name 'Management group' -Value $ManagementGroupName
    Add-MlsPreflight -Context $context -Name 'Canary resource group' -Value "$CanaryResourceGroupName (written by the deploy workflow, never by this audit)"

    # -Control @(): confirms subscription placement under the management group, a
    # governance-hierarchy precondition for policy scope (V2.3). Placement alone implements
    # no 800-171 requirement by itself.
    # L02: MG moves propagate in minutes - the long default was never this criterion s need (F59)
    Invoke-MlsCriterion -Context $context -Id 'V2.1' -Control @() `
        -Description 'az account management-group show mls shows the sub' `
        -Command "az account management-group show --name $ManagementGroupName --expand --recurse --output json  # children filtered in-process, so a FAIL can name what WAS there" `
        -Expected 'exactly one child returned - the demo subscription' `
        -RetryWindowMinutes 5 `
        -Test { Test-ManagementGroupPlacement -ManagementGroupName $ManagementGroupName -SubscriptionId $subscription } | Out-Null

    # L02: Activity Log ingestion lag, minutes not tens of minutes
    Invoke-MlsCriterion -Context $context -Id 'V2.2' -Control @('3.4.2') `
        -Description 'Creating an untagged canary RG fails with policy denial (then cleaned up)' `
        -Command "az monitor activity-log list --offset $ActivityLogOffset --status Failed --query `"[?contains(resourceGroupName,'$CanaryResourceGroupName')].{op:operationName.value, sub:subStatus.localizedValue, code:properties.statusMessage}`"`naz group exists --name $CanaryResourceGroupName" `
        -Expected 'at least one Microsoft.Resources/subscriptions/resourceGroups/write event with RequestDisallowedByPolicy; az group exists == false' `
        -RetryWindowMinutes 10 `
        -Test { Test-CanaryPolicyDenial -CanaryResourceGroupName $CanaryResourceGroupName -ActivityLogOffset $ActivityLogOffset } | Out-Null

    Invoke-MlsCriterion -Context $context -Id 'V2.3' -Control @('3.12.1', '3.12.3') `
        -Description 'az policy state summarize returns NIST compliance data within 30 min of assignment' `
        -Command "az policy state summarize --subscription $subscription --query `"policyAssignments[?contains(policyAssignmentId,'$NistAssignmentPattern')].{id:policyAssignmentId, nonCompliant:results.nonCompliantResources}`"" `
        -Expected 'the NIST 800-53 R5 initiative assignment appears with a populated results block' `
        -RetryWindowMinutes 30 `
        -Test { Test-NistComplianceData -SubscriptionId $subscription -NistAssignmentPattern $NistAssignmentPattern } | Out-Null

    return $context
}

if (-not $env:MLS_SKIP_MAIN) {
    try {
        $auditContext = Invoke-Main -SubscriptionId $SubscriptionId -ManagementGroupName $ManagementGroupName `
            -CanaryResourceGroupName $CanaryResourceGroupName -ActivityLogOffset $ActivityLogOffset `
            -NistAssignmentPattern $NistAssignmentPattern -ReportRoot $ReportRoot -NoRetry:$NoRetry
    }
    catch {
        Write-MlsStatus -Message "layer-02-audit could not start: $($_.Exception.Message)" -Color Red
        exit 2
    }
    $reportFile = Write-MlsReport -Context $auditContext
    Write-MlsStatus -Message "report: $($reportFile.MarkdownPath)"
    exit (Get-MlsExitCode -Context $auditContext)
}
